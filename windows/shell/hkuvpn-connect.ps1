# hkuvpn-connect.ps1 - the body of a bare `hkuvpn` invocation.
#
# Runs hkuvpn.ps1 in terminal mode (-t): the tunnel lives in a hidden elevated
# worker, the MFA prompt stays in this console, and closing the terminal after
# "Connected" does not stop the VPN. A watchdog is started first so that
# closing the terminal *before* the tunnel is up cannot leave an orphaned
# worker waiting for a code forever.
#
# hkuvpn.ps1 is taken from ..\bin beside this folder - the checkout's
# windows\bin, or bin\ in an unpacked release bundle. Set HKUVPN_PS1 to the
# full path of another copy if this folder lives somewhere else on its own.
#
# This folder exists because PowerShell prefers a .ps1 script to a .cmd with
# the same base name: hkuvpn.cmd next to hkuvpn.ps1 would make the bare
# command mean the smart mode in PowerShell but -t in cmd.

$ErrorActionPreference = 'Continue'

$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$upstream = if ($env:HKUVPN_PS1) { $env:HKUVPN_PS1 } else { Join-Path $here '..\bin\hkuvpn.ps1' }
$upstream = [IO.Path]::GetFullPath($upstream)
$watchdog = Join-Path $here 'hkuvpn-watchdog.ps1'
$tempBase = Join-Path $env:TEMP 'hkuvpn'
$doneFile = Join-Path $tempBase 'watchdog.done'

foreach ($f in @($upstream, $watchdog)) {
    if (-not (Test-Path $f)) {
        Write-Host ("hkuvpn: missing {0}" -f $f) -ForegroundColor Red
        if ($f -eq $upstream) {
            Write-Host ('Set HKUVPN_PS1 to the full path of hkuvpn.ps1, or keep ' +
                        'this shell folder beside bin\.') -ForegroundColor Red
        }
        exit 1
    }
}

if (-not (Test-Path $tempBase)) {
    New-Item -ItemType Directory -Path $tempBase -Force | Out-Null
}
# A leftover "done" from a previous run must never stop this watchdog early.
Remove-Item $doneFile -Force -ErrorAction SilentlyContinue

$null = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', ('"{0}"' -f $watchdog),
    '-TermPid', $PID,
    # Unix milliseconds: always positive, so the command line never shows it
    # as a "-parameter" token (binary ticks are negative for modern dates).
    '-StartTimeMs', ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
)

$code = 0
try {
    & $upstream -t
    $code = $LASTEXITCODE
} finally {
    Set-Content -Path $doneFile -Value 'done' -NoNewline -ErrorAction SilentlyContinue
}

exit $code
