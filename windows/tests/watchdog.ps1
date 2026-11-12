<#
.SYNOPSIS
    Checks the orphan guard that a bare `hkuvpn` starts before connecting.

.DESCRIPTION
    hkuvpn-connect.ps1 runs the tunnel in a hidden elevated worker and keeps
    the MFA prompt in the caller's console. The worker's MFA wait loop has no
    timeout, so a console that dies before "Connected" would leave the worker
    waiting forever. hkuvpn-watchdog.ps1 exists to stop exactly that case and
    nothing else.

    Four-plus-one cases, each in a throw-away folder passed as -TempBase so
    the real %TEMP%\hkuvpn state is never touched. A sleeping powershell
    acts as the caller's console, because what matters is that its pid
    disappears.

      1. console dies before the tunnel is up  -> stop.flag written
      2. HKUVPN_CONNECTED from this run        -> hands off, no stop.flag
      3. wrapper finished, console alive       -> no stop.flag
      4. stale HKUVPN_CONNECTED from last time -> ignored, stop.flag written
      5. console dies with a done file present -> stop.flag written: the
         pid, not the done file, is the authority (Ctrl+C writes done too)

    No administrator rights and no VPN session are needed.
#>

$ErrorActionPreference = 'Stop'

$script:Watchdog = Join-Path (Split-Path -Parent $PSScriptRoot) 'shell\hkuvpn-watchdog.ps1'
if (-not (Test-Path $script:Watchdog)) {
    Write-Host "watchdog not found: $($script:Watchdog)" -ForegroundColor Red
    exit 1
}

$script:Passed = 0
$script:Failed = 0

function Write-Case {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    if ($Ok) {
        $script:Passed++
        Write-Host ("PASS  {0}" -f $Name) -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host ("FAIL  {0}  ({1})" -f $Name, $Detail) -ForegroundColor Red
    }
}

function New-CaseDir {
    $dir = Join-Path (Join-Path $env:TEMP 'hkuvpn-watchdog-test') ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Start-FakeConsole {
    # Any long-lived process will do; the watchdog only asks whether the pid
    # still exists.
    return Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-Command', 'Start-Sleep -Seconds 60'
    )
}

function Start-Watchdog {
    param([string]$Dir, [int]$TermPid, [datetime]$Start)
    return Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $script:Watchdog),
        '-TermPid', $TermPid,
        '-StartTimeMs', (([DateTimeOffset]$Start).ToUnixTimeMilliseconds()),
        '-TempBase', ('"{0}"' -f $Dir)
    )
}

function Wait-File {
    param([string]$Path, [int]$Seconds)
    $limit = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $limit) {
        if (Test-Path $Path) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return (Test-Path $Path)
}

function Wait-Exit {
    param($Process, [int]$Seconds)
    if (-not $Process.WaitForExit($Seconds * 1000)) {
        try { $Process.Kill() } catch {}
        return $false
    }
    return $true
}

function Stop-Quietly {
    param($Process)
    try { if ($Process -and -not $Process.HasExited) { $Process.Kill() } } catch {}
}

$cases = @()

# --- 1. console dies before the tunnel is up --------------------------------
$dir = New-CaseDir
$console = Start-FakeConsole
$start = Get-Date
$wd = Start-Watchdog -Dir $dir -TermPid $console.Id -Start $start
Start-Sleep -Seconds 2
Stop-Quietly $console
$stopped = Wait-File (Join-Path $dir 'stop.flag') 15
$exited = Wait-Exit $wd 10
Write-Case 'console dies before connect -> stop.flag written' ($stopped -and $exited) `
    ("stop.flag={0} exited={1}" -f $stopped, $exited)
$cases += $dir

# --- 2. connected from this run: the watchdog must hands off ----------------
$dir = New-CaseDir
$console = Start-FakeConsole
$start = Get-Date
$markerPath = Join-Path $dir 'markers.log'
Set-Content -Path $markerPath -Value '2026-01-01T00:00:00 HKUVPN_CONNECTED' -NoNewline
# Stamp it explicitly: two writes in the same clock tick can otherwise make
# "just written" and "start time" compare arbitrarily.
(Get-Item $markerPath).LastWriteTime = $start.AddSeconds(2)
$wd = Start-Watchdog -Dir $dir -TermPid $console.Id -Start $start
$exited = Wait-Exit $wd 15
Stop-Quietly $console
$stopped = Test-Path (Join-Path $dir 'stop.flag')
Write-Case 'connected -> no stop.flag, watchdog exits' ((-not $stopped) -and $exited) `
    ("stop.flag={0} exited={1}" -f $stopped, $exited)
$cases += $dir

# --- 3. wrapper finished normally ------------------------------------------
$dir = New-CaseDir
$console = Start-FakeConsole
$start = Get-Date
Set-Content -Path (Join-Path $dir 'watchdog.done') -Value 'done' -NoNewline
$wd = Start-Watchdog -Dir $dir -TermPid $console.Id -Start $start
$exited = Wait-Exit $wd 15
Stop-Quietly $console
$stopped = Test-Path (Join-Path $dir 'stop.flag')
Write-Case 'normal finish (console alive) -> no stop.flag' ((-not $stopped) -and $exited) `
    ("stop.flag={0} exited={1}" -f $stopped, $exited)
$cases += $dir

# --- 5. console dies with a done file present -------------------------------
# Ctrl+C writes the done file on the way out; the dead pid must still win.
$dir = New-CaseDir
$console = Start-FakeConsole
$start = Get-Date
Set-Content -Path (Join-Path $dir 'watchdog.done') -Value 'done' -NoNewline
$wd = Start-Watchdog -Dir $dir -TermPid $console.Id -Start $start
Start-Sleep -Seconds 2
Stop-Quietly $console
$stopped = Wait-File (Join-Path $dir 'stop.flag') 15
$exited = Wait-Exit $wd 10
Write-Case 'console dies with done present -> stop.flag written' ($stopped -and $exited) `
    ("stop.flag={0} exited={1}" -f $stopped, $exited)
$cases += $dir

# --- 4. a CONNECTED left by the previous session must not count ------------
$dir = New-CaseDir
$console = Start-FakeConsole
$start = Get-Date
$markerPath = Join-Path $dir 'markers.log'
Set-Content -Path $markerPath -Value '2026-01-01T00:00:00 HKUVPN_CONNECTED' -NoNewline
(Get-Item $markerPath).LastWriteTime = $start.AddSeconds(-5)
$wd = Start-Watchdog -Dir $dir -TermPid $console.Id -Start $start
Start-Sleep -Seconds 2
Stop-Quietly $console
$stopped = Wait-File (Join-Path $dir 'stop.flag') 15
$exited = Wait-Exit $wd 10
Write-Case 'stale CONNECTED is ignored -> stop.flag written' ($stopped -and $exited) `
    ("stop.flag={0} exited={1}" -f $stopped, $exited)
$cases += $dir

foreach ($d in $cases) {
    Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failed -eq 0) {
    Write-Host ("All {0} checks passed." -f $script:Passed) -ForegroundColor Green
    exit 0
}
Write-Host ("{0} of {1} checks failed." -f $script:Failed, ($script:Passed + $script:Failed)) -ForegroundColor Red
exit 1
