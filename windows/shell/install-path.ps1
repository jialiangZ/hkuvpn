#Requires -Version 5.1
<#
install-path.ps1 - put this folder on the user PATH once.

After this, a bare `hkuvpn` works from any terminal: it runs the launcher in
terminal mode (-t) with the orphan guard, so the MFA code is typed in the
same window and closing that window after "Connected" leaves the VPN up.

The PATH entry is per user (HKCU\Environment), so no administrator rights are
needed and nothing outside your account changes. Re-running is harmless, and
-Remove takes the entry out again. Other entries are copied through byte for
byte: this script never re-sorts, de-duplicates or reformats your PATH.

Usage:
  powershell -ExecutionPolicy Bypass -File install-path.ps1
  powershell -ExecutionPolicy Bypass -File install-path.ps1 -Remove
#>
param(
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$shellDir = (Split-Path -Parent $MyInvocation.MyCommand.Path).TrimEnd('\')
$raw = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($null -eq $raw) { $raw = '' }

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
    [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
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
    [Environment]::SetEnvironmentVariable('Path', ($raw + $sep + $shellDir), 'User')
    Write-Host ("hkuvpn: added {0} to the user PATH." -f $shellDir)
}

Write-Host ''
Write-Host 'Open a NEW terminal (the current one keeps its old PATH), then:'
Write-Host '  hkuvpn --check      # pre-flight: config, PIN file, tools, ports'
Write-Host '  hkuvpn              # connect; type the MFA code when asked'
Write-Host '  hkuvpn --stop       # stop'
