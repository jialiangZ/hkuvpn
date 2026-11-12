#Requires -Version 5.1
<#
install-path.ps1 - put this folder on the user PATH once.

After this, a bare `hkuvpn` works from any terminal: it runs the launcher in
terminal mode (-t) with the orphan guard, so the MFA code is typed in the
same window and closing that window after "Connected" leaves the VPN up.

The PATH entry is per user (HKCU\Environment), so no administrator rights are
needed and nothing outside your account changes. Re-running is harmless, and
-Remove takes the entry out again. Other entries are copied through byte for
byte - never re-sorted, de-duplicated or reformatted - and so is the registry
value kind: a stock Windows profile keeps Path as REG_EXPAND_SZ holding
%USERPROFILE% entries, and a rewrite as REG_SZ would turn those into dead
text that nothing expands.

Usage:
  powershell -ExecutionPolicy Bypass -File install-path.ps1
  powershell -ExecutionPolicy Bypass -File install-path.ps1 -Remove
#>
param(
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

function Get-UserPathRaw {
    # Not [Environment]::GetEnvironmentVariable('Path','User'): it EXPANDS
    # REG_EXPAND_SZ values, so "%USERPROFILE%\..." would silently come back
    # as the expanded text and a write-back would replace it.
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    if (-not $key) { return '' }
    try {
        $v = $key.GetValue('Path', $null, 'DoNotExpandEnvironmentNames')
        if ($null -eq $v) { return '' }
        return [string]$v
    } finally {
        $key.Close()
    }
}

function Set-UserPathRaw {
    param([string]$Value)
    # Not [Environment]::SetEnvironmentVariable: it writes REG_SZ (verified:
    # the kind flips from ExpandString to String), which leaves
    # "%USERPROFILE%\..." entries unexpanded. Write with the kind the value
    # already has - ExpandString on a stock profile - and broadcast
    # WM_SETTINGCHANGE ourselves, the way SetEnvironmentVariable would have.
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if (-not $key) { throw 'cannot open HKCU\Environment for writing' }
    try {
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        try { $kind = $key.GetValueKind('Path') } catch {}
        $key.SetValue('Path', $Value, $kind)
    } finally {
        $key.Close()
    }
    if (-not ('Win32.NativeEnv' -as [type])) {
        Add-Type -Namespace Win32 -Name NativeEnv -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg,
    UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout,
    out UIntPtr lpdwResult);
'@
    }
    $result = [UIntPtr]::Zero
    # HWND_BROADCAST, WM_SETTINGCHANGE "Environment", SMTO_ABORTIFHUNG.
    $null = [Win32.NativeEnv]::SendMessageTimeout(
        [IntPtr]0xFFFF, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
}

$shellDir = (Split-Path -Parent $MyInvocation.MyCommand.Path).TrimEnd('\')
$raw = Get-UserPathRaw

# Compare the way Windows does: case-insensitively, ignoring a trailing
# backslash and surrounding spaces.
$parts = @($raw -split ';')
$found = @($parts | Where-Object { $_.Trim().TrimEnd('\') -ieq $shellDir })

if ($Remove) {
    if ($found.Count -eq 0) {
        Write-Host ("hkuvpn: {0} is not on the user PATH; nothing to remove." -f $shellDir)
        exit 0
    }
    $kept = @($parts | Where-Object { $_.Trim().TrimEnd('\') -ine $shellDir })
    Set-UserPathRaw -Value ($kept -join ';')
    Write-Host ("hkuvpn: removed {0} from the user PATH." -f $shellDir)
    Write-Host 'Open a new terminal for the change to take effect.'
    exit 0
}

if (-not (Test-Path (Join-Path $shellDir '..\bin\hkuvpn.ps1'))) {
    Write-Host ("hkuvpn: {0} has no ..\bin\hkuvpn.ps1 - run this from the " -f $shellDir) -ForegroundColor Red
    Write-Host 'shell folder of a checkout or release bundle.' -ForegroundColor Red
    exit 1
}

if ($found.Count -gt 0) {
    Write-Host ("hkuvpn: {0} is already on the user PATH." -f $shellDir)
} else {
    $sep = if ($raw -and -not $raw.EndsWith(';')) { ';' } else { '' }
    Set-UserPathRaw -Value ($raw + $sep + $shellDir)
    Write-Host ("hkuvpn: added {0} to the user PATH." -f $shellDir)
}

Write-Host ''
Write-Host 'Open a NEW terminal (the current one keeps its old PATH), then:'
Write-Host '  hkuvpn --check      # pre-flight: config, PIN file, tools, ports'
Write-Host '  hkuvpn              # connect; type the MFA code when asked'
Write-Host '  hkuvpn --stop       # stop'

$cfgDir = if ($env:HKU_CONFIG_DIR) { $env:HKU_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.vpn' }
if (-not (Test-Path (Join-Path $cfgDir 'hku.env'))) {
    Write-Host ''
    Write-Host ("No configuration yet in {0} - run shell\bootstrap.ps1 first:" -f $cfgDir)
    Write-Host '  it asks for the HKU account, the Portal PIN and any campus subnets.'
}
