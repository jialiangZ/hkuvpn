# hkuvpn-watchdog.ps1 - orphan protection for a bare `hkuvpn` (terminal mode).
#
# Started by hkuvpn-connect.ps1 just before the connect flow. The -t mode
# runs the tunnel in a HIDDEN elevated worker and waits for the MFA code in
# the caller's console. If that console dies before the tunnel reports
# HKUVPN_CONNECTED, the worker would otherwise sit in its MFA wait loop
# forever (that loop has no timeout). This watchdog notices the dead console
# and writes the worker's stop flag so it cleans itself up.
#
# "Dead" means the console pid is gone, whatever made it go: closing the
# window, or Ctrl+C at the MFA prompt (the wrapper's finally block writes
# the done file BEFORE the process exits, so on a done file the watchdog
# waits a few seconds for the pid to leave - only a console that stays up
# is a real "finished normally"). A failed connect from the bare command
# also takes the wrapper's process down, so it may leave one stray
# stop.flag behind; the next session's worker deletes a flag that predates
# it, so that flag can never kill a later connect.
#
# It never touches a CONNECTED session: once HKUVPN_CONNECTED is seen it
# exits, so closing the terminal after "Connected" leaves the VPN running.

param(
    [Parameter(Mandatory = $true)][int]$TermPid,
    # Wrapper start time in Unix milliseconds. Not binary ticks: those are
    # negative for modern dates, and PowerShell's command-line parser reads a
    # leading "-" as a parameter name, silently dropping the value.
    [long]$StartTimeMs = 0,
    # Override only for tests; production uses %TEMP%\hkuvpn so the worker,
    # the CLI and this watchdog all agree on where the flag files live.
    [string]$TempBase = ''
)

$ErrorActionPreference = 'SilentlyContinue'

$tempBase = if ($TempBase) { $TempBase } else { Join-Path $env:TEMP 'hkuvpn' }
$marker   = Join-Path $tempBase 'markers.log'
$stop     = Join-Path $tempBase 'stop.flag'
$done     = Join-Path $tempBase 'watchdog.done'

# The wrapper passes its start time so a stale HKUVPN_CONNECTED left by an
# earlier session cannot end this watchdog early. Compare in UTC: the marker's
# LastWriteTime is local, and only ordering matters.
$startUtc = if ($StartTimeMs -gt 0) {
    [DateTimeOffset]::FromUnixTimeMilliseconds($StartTimeMs).UtcDateTime
} else {
    [DateTime]::UtcNow
}

function Test-Connected {
    if (-not (Test-Path $marker)) { return $false }
    $item = Get-Item $marker
    # Invoke-TunnelWorker deletes and recreates markers.log at session start,
    # so a CONNECTED line from *this* run also carries a fresh write time.
    if ($item.LastWriteTimeUtc -le $startUtc) { return $false }
    $text = Get-Content $marker -Raw
    return ($text -match 'HKUVPN_CONNECTED')
}

$deadline = (Get-Date).AddMinutes(20)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    if (Test-Connected) { break }            # tunnel is up: hands off
    $consoleAlive = [bool](Get-Process -Id $TermPid -ErrorAction SilentlyContinue)
    if ((Test-Path $done) -and $consoleAlive) {
        # The wrapper wrote its done file but the process is still there.
        # Ctrl+C writes done in a finally block on the way out, so give the
        # pid a moment to leave; one that stays up is a real shell that
        # finished normally.
        $grace = (Get-Date).AddSeconds(5)
        do {
            Start-Sleep -Milliseconds 250
            $consoleAlive = [bool](Get-Process -Id $TermPid -ErrorAction SilentlyContinue)
        } while ($consoleAlive -and (Get-Date) -lt $grace)
    }
    if ($consoleAlive) {
        if (Test-Path $done) { break }        # normal finish, console still up
        continue
    }
    # The terminal is gone. Wait two seconds in case the worker completes
    # the connection on its own before we judge it.
    Start-Sleep -Seconds 2
    if (Test-Connected) { break }
    Set-Content -Path $stop -Value 'stop' -NoNewline
    break
}
