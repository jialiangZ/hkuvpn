<#
.SYNOPSIS
    Regression run for the HKU VPN session lifecycle on Windows.

.DESCRIPTION
    It drives the worker and the app the way a person does and checks the
    invariants that broke before:

      1. a stop while the worker waits for the MFA code tears the worker
         down quickly, with a teardown marker and without the force kill
         that "hkuvpn.ps1 --stop" escalates to,
      2. closing the MFA dialog does not kill the session,
      3. a cancel in the app leads back to idle - the app used to stay on
         "Cancelling - waiting for the worker to exit" forever,
      4. a live session disconnects cleanly.

    The steps that need a human are the UAC prompt and the MFA code: the
    script asks for them and waits. Run it from a PowerShell window, so
    the code can be typed in.

    The app is driven with the keyboard (Tab reaches the primary button),
    so the script does not depend on the window's size or its layout.

.PARAMETER AppExe
    The app to test. Defaults to windows\mygo-app\publish\HKUVPN.exe.

.PARAMETER WorkerOnly
    Only run the worker checks; the app is left alone.

.PARAMETER AppOnly
    Only run the app checks.

.PARAMETER MfaCode
    The 6-digit code to use in the connect check. Without it the script
    asks for one, which needs a console to type in: run it from a
    PowerShell window, not from a scheduled task.

.PARAMETER SkipLive
    Leave out the check that needs a live session (the one that asks for
    an MFA code).

.PARAMETER LiveOnly
    Only run the check that needs a live session.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File windows\tests\session-flow.ps1
#>
[CmdletBinding()]
param(
    [string]$AppExe = '',
    [switch]$WorkerOnly,
    [switch]$AppOnly,
    [switch]$SkipLive,
    [switch]$LiveOnly,
    [string]$MfaCode = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

$WindowsDir = Split-Path -Parent $PSScriptRoot
$RepoDir    = Split-Path -Parent $WindowsDir
$Worker     = Join-Path $WindowsDir 'bin\hkuvpn.ps1'
if (-not $AppExe) {
    $AppExe = Join-Path $WindowsDir 'mygo-app\publish\HKUVPN.exe'
}

$TempBase = Join-Path $env:TEMP 'hkuvpn'
$Markers  = Join-Path $TempBase 'markers.log'
$PidFile  = Join-Path $TempBase 'pids.txt'
$StopFlag = Join-Path $TempBase 'stop.flag'
$Status   = Join-Path $TempBase 'app-status.txt'
$Wedge    = Join-Path $TempBase 'wedge-diagnostics.txt'

$ResultFile = Join-Path $TempBase 'session-flow-result.txt'
$script:Passed = 0
$script:Failed = 0
$script:Results = @()

function Write-Result([string]$Line) {
    $script:Results += $Line
    try {
        Set-Content -Path $ResultFile -Value ($script:Results -join "`r`n") -Encoding UTF8
    } catch {}
}

# ------------------------------------------------------------------ output

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "== $Text" -ForegroundColor Cyan
}

function Write-Note([string]$Text) {
    Write-Host "   $Text" -ForegroundColor DarkGray
    Write-Result ("note  " + $Text)
}

function Check([bool]$Condition, [string]$What, [string]$Detail = '') {
    if ($Condition) {
        $script:Passed++
        Write-Host "   PASS  $What" -ForegroundColor Green
        Write-Result ("PASS  " + $What)
    } else {
        $script:Failed++
        Write-Host "   FAIL  $What" -ForegroundColor Red
        if ($Detail) { Write-Host "         $Detail" -ForegroundColor Red }
        Write-Result ("FAIL  " + $What + $(if ($Detail) { " ($Detail)" } else { '' }))
    }
}

function Write-Summary {
    Write-Host ''
    if ($script:Failed -eq 0) {
        Write-Host "All $($script:Passed) checks passed." -ForegroundColor Green
    } else {
        Write-Host "$($script:Failed) of $($script:Passed + $script:Failed) checks failed." -ForegroundColor Red
    }
    Write-Result ''
    Write-Result ("$($script:Passed) passed, $($script:Failed) failed")
}

# ------------------------------------------------------------- the protocol

# The worker deletes markers.log when it cleans up, so the lines it wrote
# are kept here once they have been seen.
$script:SeenMarkers = @()

function Get-MarkerLines {
    if (Test-Path $Markers) {
        foreach ($l in @(Get-Content $Markers -ErrorAction SilentlyContinue)) {
            if ($script:SeenMarkers -notcontains $l) { $script:SeenMarkers += $l }
        }
    }
    return $script:SeenMarkers
}

function Wait-ForMarker([string]$Pattern, [int]$Seconds) {
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        if ((Get-MarkerLines) -match $Pattern) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Get-WorkerPid {
    if (-not (Test-Path $PidFile)) { return 0 }
    foreach ($line in @(Get-Content $PidFile -ErrorAction SilentlyContinue)) {
        if ($line -like 'WORKER=*') {
            $n = 0
            if ([int]::TryParse(($line -replace '^WORKER=', ''), [ref]$n)) { return $n }
        }
    }
    return 0
}

function Test-WorkerAlive {
    # $pid is a read-only automatic variable in PowerShell.
    $workerPid = Get-WorkerPid
    if ($workerPid -le 0) { return $false }
    return $null -ne (Get-Process -Id $workerPid -ErrorAction SilentlyContinue)
}

function Test-ChildrenLeft {
    $left = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -in @('openconnect', 'gost') })
    return $left.Count
}

function Get-AppStatus {
    $h = @{}
    if (Test-Path $Status) {
        foreach ($line in @(Get-Content $Status -ErrorAction SilentlyContinue)) {
            if ($line -match '^([^=]+)=(.*)$') { $h[$matches[1]] = $matches[2] }
        }
    }
    return $h
}

function Wait-AppStatus([hashtable]$Want, [int]$Seconds) {
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        $h = Get-AppStatus
        $ok = $true
        foreach ($k in $Want.Keys) {
            if ([string]$h[$k] -ne [string]$Want[$k]) { $ok = $false; break }
        }
        if ($ok) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Get-WedgeStamp {
    if (-not (Test-Path $Wedge)) { return '' }
    return (Get-Item $Wedge).LastWriteTimeUtc.Ticks
}

# ------------------------------------------------------------------- the UI

if (-not ('HKUTest' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class HKUTest {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    public static IntPtr Find(uint target) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid == target && IsWindowVisible(h)) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@
}

function Get-AppWindow {
    $p = Get-Process HKUVPN -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) { return [IntPtr]::Zero }
    return [HKUTest]::Find([uint32]$p.Id)
}

function Focus-App {
    $h = Get-AppWindow
    if ($h -eq [IntPtr]::Zero) { return $false }
    [HKUTest]::ShowWindow($h, 9) | Out-Null
    # AppActivate brings the window forward without touching the keyboard
    # focus inside it, so the Tab order stays where the app put it.
    try {
        $ws = New-Object -ComObject WScript.Shell
        if ($ws.AppActivate('HKU VPN')) {
            Start-Sleep -Milliseconds 400
            return $true
        }
    } catch {}
    [HKUTest]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds 400
    return $true
}

function Send-Keys([string]$Keys) {
    try {
        [System.Windows.Forms.SendKeys]::SendWait($Keys)
    } catch {
        # The secure desktop (a UAC prompt) does not take keys.
        Start-Sleep -Milliseconds 500
        return
    }
    Start-Sleep -Milliseconds 250
}

function Wait-NoConsent([int]$Seconds = 240) {
    # The UAC prompt lives on the secure desktop, where keys do not
    # reach the app: wait until it has been answered.
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        if (@(Get-Process consent -ErrorAction SilentlyContinue).Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# The app answers Ctrl+Enter with its main action: connect, cancel,
# disconnect. That is the same key a person would press, and it does not
# depend on where the focus happens to be.
function Press-AppMain {
    if (-not (Focus-App)) { return $false }
    Send-Keys '^({ENTER})'
    Start-Sleep -Milliseconds 800
    return $true
}

function Stop-App {
    Get-Process HKUVPN -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

function Start-App {
    if (-not (Test-Path $AppExe)) { return $false }
    Start-Process $AppExe | Out-Null
    $end = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $end) {
        if ((Get-AppStatus).ContainsKey('state')) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# ------------------------------------------------------------- the commands

function Start-WorkerElevated {
    $workerArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Worker`"", '--Worker')
    Start-Process -FilePath 'powershell.exe' -ArgumentList $workerArgs -Verb RunAs -WindowStyle Hidden | Out-Null
}

function Request-Stop {
    # What the app does on a cancel: ask the worker to stop and leave the
    # flag behind, so a worker that is still starting sees it too.
    Set-Content -Path $StopFlag -Value 'stop' -NoNewline
    $stopArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Worker`"", '--stop')
    Start-Process -FilePath 'powershell.exe' -ArgumentList $stopArgs -WindowStyle Hidden | Out-Null
}

function Clear-SessionFiles {
    foreach ($f in @($StopFlag, $Markers, $PidFile, $Status)) {
        Remove-Item $f -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- the checks

Write-Host ''
Write-Host 'HKU VPN - session lifecycle regression' -ForegroundColor White
Write-Host ("worker : {0}" -f $Worker)
Write-Host ("app    : {0}" -f $AppExe)

# --- preflight -------------------------------------------------------------

Write-Step 'Preflight'
if (-not (Test-Path $Worker)) {
    Check $false 'the worker script exists' $Worker
    Write-Summary
    exit 1
}
Check $true 'the worker script exists'

$envFile = Join-Path $env:USERPROFILE '.vpn\hku.env'
$passFile = Join-Path $env:USERPROFILE '.vpn\hku.pass'
$user = ''
if (Test-Path $envFile) {
    foreach ($line in @(Get-Content $envFile)) {
        if ($line -like 'HKU_USER=*') { $user = ($line -replace '^HKU_USER=', '').Trim() }
    }
}
Check ($user -ne '' -and $user -notlike 'youruid@*') 'the account is configured' $user
$pin = ''
if (Test-Path $passFile) { $pin = (Get-Content $passFile -Raw).Trim() }
Check ($pin -ne '') 'the Portal PIN is stored'

if (-not $WorkerOnly) {
    if (Check (Test-Path $AppExe) 'the app is built' $AppExe) {
        Write-Note ("app    : {0}" -f $AppExe)
    } else {
        Write-Note 'Build it with windows\mygo-app\build.sh, or pass -AppExe.'
    }
}

# --- a session must not be running yet -------------------------------------

if (Test-WorkerAlive) {
    Write-Step 'Stopping the session that is running'
    Request-Stop
    $end = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $end -and (Test-WorkerAlive)) { Start-Sleep -Milliseconds 500 }
    Check (-not (Test-WorkerAlive)) 'the session that was running is gone'
}

# --- 1. the worker: a stop while it waits for the code ----------------------

if (-not $AppOnly -and -not $LiveOnly) {
    Write-Step 'Worker: a stop while it waits for the MFA code'
    Clear-SessionFiles
    $wedgeBefore = Get-WedgeStamp

    Write-Note 'Approve the UAC prompt - the worker starts elevated.'
    Start-WorkerElevated
    $got = Wait-ForMarker 'HKUVPN_MFA_RESPONSE_REQUIRED' 120
    Check $got 'the worker asks for the MFA code' (Get-MarkerLines | Select-Object -Last 1)
    Check (Test-WorkerAlive) 'the worker is running'

    Request-Stop
    $torn = Wait-ForMarker 'HKUVPN_TEARDOWN' 20
    Check $torn 'the worker writes the teardown marker' (Get-MarkerLines | Select-Object -Last 1)

    $end = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $end -and (Test-WorkerAlive)) { Start-Sleep -Milliseconds 500 }
    Check (-not (Test-WorkerAlive)) 'the worker is gone'
    Check ((Get-WedgeStamp) -eq $wedgeBefore) 'no force kill was needed' 'wedge-diagnostics.txt was written'
    Check ((Test-ChildrenLeft) -eq 0) 'no openconnect or gost is left' ((Test-ChildrenLeft).ToString() + ' left')
    Clear-SessionFiles
}

# --- 2. the app: closing the MFA dialog, then a cancel ----------------------

if (-not $WorkerOnly -and -not $LiveOnly) {
    Write-Step 'App: closing the MFA dialog, then cancelling'
    Clear-SessionFiles
    Stop-App
    if (-not (Start-App)) {
        Check $false 'the app starts' $AppExe
    } else {
        Check $true 'the app starts'
        $wedgeBefore = Get-WedgeStamp

        Write-Note 'Approve the UAC prompt - the app starts the worker.'
        Press-AppMain | Out-Null
        Wait-NoConsent | Out-Null
        $got = Wait-ForMarker 'HKUVPN_MFA_RESPONSE_REQUIRED' 120
        Check $got 'the app gets the MFA request' (Get-MarkerLines | Select-Object -Last 1)
        Check (Wait-AppStatus @{ state = 'connecting' } 20) 'the app is connecting'
        Check (Wait-AppStatus @{ mfa = 'true' } 20) 'the app knows a code is needed'

        # Closing the dialog must not kill the session. The first Escape
        # closes it; the app's status file says whether it did.
        $closed = $false
        for ($i = 0; $i -lt 4 -and -not $closed; $i++) {
            Focus-App | Out-Null
            Send-Keys '{ESC}'
            Start-Sleep -Milliseconds 800
            $closed = ((Get-AppStatus)['mfaOpen'] -ne 'true')
        }
        Check $closed 'the MFA dialog closes on Escape'
        $h = Get-AppStatus
        Check ($h['state'] -eq 'connecting') 'closing the dialog keeps the session' ("state=" + $h['state'])
        Check (Test-WorkerAlive) 'the worker is still waiting for the code'

        # Cancel: another Escape gives up the attempt. The app may be
        # done with it before the next look, so the check is the outcome:
        # the app is idle and the worker is gone.
        Focus-App | Out-Null
        Send-Keys '{ESC}'
        Wait-NoConsent | Out-Null
        $end = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $end) {
            $h = Get-AppStatus
            if ($h['state'] -eq 'idle' -and -not (Test-WorkerAlive)) { break }
            Start-Sleep -Milliseconds 500
        }
        Check (-not (Test-WorkerAlive)) 'the worker is gone after the cancel'

        $end = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $end) {
            $h = Get-AppStatus
            if ($h['state'] -eq 'idle') { break }
            Start-Sleep -Milliseconds 500
        }
        $h = Get-AppStatus
        Check ($h['state'] -eq 'idle') 'the app is idle again' ("state=" + $h['state'])
        Check ($h['cancelling'] -eq 'false') 'the app is not stuck cancelling' ("cancelling=" + $h['cancelling'])
        Check (Wait-ForMarker 'HKUVPN_TEARDOWN' 20) 'the worker tears the session down'
        Check ((Get-WedgeStamp) -eq $wedgeBefore) 'no force kill was needed' 'wedge-diagnostics.txt was written'
        Check ((Test-ChildrenLeft) -eq 0) 'no openconnect or gost is left' ((Test-ChildrenLeft).ToString() + ' left')
    }
    Clear-SessionFiles
}

# --- 3. the app: a live session, then a disconnect -------------------------

if (-not $WorkerOnly -and -not $SkipLive) {
    Write-Step 'App: a live session and a disconnect'
    Stop-App
    if (-not (Start-App)) {
        Check $false 'the app starts' $AppExe
    } else {
        $wedgeBefore = Get-WedgeStamp
        Write-Note 'Approve the UAC prompt - the app starts the worker.'
        Press-AppMain | Out-Null
        Wait-NoConsent | Out-Null
        $got = Wait-ForMarker 'HKUVPN_MFA_RESPONSE_REQUIRED' 120
        Check $got 'the app gets the MFA request' (Get-MarkerLines | Select-Object -Last 1)

        if (-not $MfaCode) {
            # The code is asked for here, with the MFA dialog waiting for
            # it: it is only good for about 30 seconds, so it cannot be
            # asked for earlier. This needs a console to type in.
            Write-Note 'Type the code from your Authenticator now (it is valid for about 30 seconds).'
            $MfaCode = Read-Host '   MFA code'
        }
        if ($MfaCode -notmatch '^\d{6}$') {
            Check $false 'the MFA code is six digits' $MfaCode
        } else {
            # The code field of the dialog has the focus.
            Focus-App | Out-Null
            Send-Keys $MfaCode
            Send-Keys '{ENTER}'
            $up = Wait-ForMarker 'HKUVPN_CONNECTED' 90
            Check $up 'the tunnel comes up' (Get-MarkerLines | Select-Object -Last 1)
            Check (Wait-AppStatus @{ state = 'connected' } 30) 'the app shows the session'
            $h = Get-AppStatus
            Check ($h['address'] -match '^\d+\.\d+\.\d+\.\d+$') 'the app shows the VPN address' ("address=" + $h['address'])

            # The disconnect button is the primary one now.
            Press-AppMain | Out-Null
            $end = (Get-Date).AddSeconds(60)
            while ((Get-Date) -lt $end) {
                $h = Get-AppStatus
                if ($h['state'] -eq 'idle') { break }
                Start-Sleep -Milliseconds 500
            }
            $h = Get-AppStatus
            Check ($h['state'] -eq 'idle') 'the app is idle after the disconnect' ("state=" + $h['state'])
            Check (Wait-ForMarker 'HKUVPN_TEARDOWN' 20) 'the worker tears the session down'
            Check ((Get-WedgeStamp) -eq $wedgeBefore) 'no force kill was needed' 'wedge-diagnostics.txt was written'
            Check ((Test-ChildrenLeft) -eq 0) 'no openconnect or gost is left' ((Test-ChildrenLeft).ToString() + ' left')
        }
    }
    Clear-SessionFiles
}

Write-Summary
if ($script:Failed -gt 0) { exit 1 }
exit 0
