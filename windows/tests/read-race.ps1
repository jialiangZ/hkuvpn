param([int]$Lines = 120, [int]$LineSize = 8000)

# Does the worker's read pattern lose or duplicate data?
#
# The pattern in hkuvpn.ps1 is: wait for the pending ReadAsync to
# finish, take the count, arm the NEXT read into the same buffer, and
# only then copy the bytes out. The copy races with the new read, which
# owns the buffer from the moment it is armed - and because the
# StreamReader often has data ready, the new read completes right away
# and the copy picks up the NEW bytes under the OLD count.
#
# The child writes numbered lines. Every number must arrive exactly once.

function Start-Child {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -Command `"for (`$i = 0; `$i -lt $Lines; `$i++) { Write-Output ('L' + `$i + ':' + ('x' * $LineSize)) }`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    return [System.Diagnostics.Process]::Start($psi)
}

function New-PendingRead {
    param($Reader)
    $buf = New-Object char[] 8192
    return @{
        Reader = $Reader
        Buf    = $buf
        Task   = $Reader.ReadAsync($buf, 0, $buf.Length)
        Eof    = $false
    }
}

function Read-PendingChars-Old {
    param($Pending, [System.Text.StringBuilder]$Buffer)
    if (-not $Pending -or $Pending.Eof) { return }
    if (-not $Pending.Task.IsCompleted) { return }
    try { $n = $Pending.Task.Result } catch { $Pending.Eof = $true; return }
    if ($n -le 0) { $Pending.Eof = $true; return }
    # The bug: the next read is armed into the same buffer before the
    # bytes are copied out.
    $Pending.Task = $Pending.Reader.ReadAsync($Pending.Buf, 0, $Pending.Buf.Length)
    $chunk = New-Object System.Text.StringBuilder
    [void]$chunk.Append($Pending.Buf, 0, $n)
    [void]$Buffer.Append($chunk.ToString())
}

function Read-PendingChars-New {
    param($Pending, [System.Text.StringBuilder]$Buffer)
    if (-not $Pending -or $Pending.Eof) { return }
    if (-not $Pending.Task.IsCompleted) { return }
    try { $n = $Pending.Task.Result } catch { $Pending.Eof = $true; return }
    if ($n -le 0) { $Pending.Eof = $true; return }
    # The fix: copy the bytes out first, then arm the next read.
    $chunk = New-Object System.Text.StringBuilder
    [void]$chunk.Append($Pending.Buf, 0, $n)
    $Pending.Task = $Pending.Reader.ReadAsync($Pending.Buf, 0, $Pending.Buf.Length)
    [void]$Buffer.Append($chunk.ToString())
}

function Measure-Pattern {
    param([scriptblock]$Reader, [string]$Name)
    $child = Start-Child
    $pending = New-PendingRead $child.StandardOutput
    $buf = New-Object System.Text.StringBuilder
    $deadline = (Get-Date).AddSeconds(60)
    while (-not $child.HasExited -and (Get-Date) -lt $deadline) {
        & $Reader $pending $buf
        Start-Sleep -Milliseconds 2
    }
    while (-not $pending.Eof) {
        & $Reader $pending $buf
        if ($pending.Task.IsCompleted) { continue }
        break
    }
    $text = $buf.ToString()

    $counts = @{}
    foreach ($m in ([regex]::Matches($text, '(?m)^L(\d+):'))) {
        $k = $m.Groups[1].Value
        if ($counts.ContainsKey($k)) { $counts[$k] += 1 } else { $counts[$k] = 1 }
    }
    $lost = @()
    $duped = @()
    for ($i = 0; $i -lt $Lines; $i++) {
        $k = "$i"
        $n = if ($counts.ContainsKey($k)) { $counts[$k] } else { 0 }
        if ($n -eq 0) { $lost += $i }
        elseif ($n -gt 1) { $duped += "$i(x$n)" }
    }
    $lostTxt = if ($lost.Count) { ($lost | Select-Object -First 8) -join ',' } else { 'none' }
    $dupTxt = if ($duped.Count) { ($duped | Select-Object -First 8) -join ',' } else { 'none' }
    [Console]::WriteLine(("{0,-4} lines received {1,5}   lost {2,-5}   duplicated {3}" -f `
        $Name, $counts.Count, $lost.Count, $dupTxt))
    if ($lost.Count -gt 0) { [Console]::WriteLine("       lost lines: $lostTxt") }
    return ($lost.Count -eq 0 -and $duped.Count -eq 0)
}

[Console]::WriteLine("child writes $Lines lines of $LineSize chars")
[Console]::WriteLine('')
$oldOk = Measure-Pattern -Reader ${function:Read-PendingChars-Old} -Name 'old'
$newOk = Measure-Pattern -Reader ${function:Read-PendingChars-New} -Name 'new'
[Console]::WriteLine('')
if ($oldOk) { [Console]::WriteLine('old: clean this time (the race is timing-dependent)') }
else { [Console]::WriteLine('old: DATA LOST OR DUPLICATED') }
if ($newOk) { [Console]::WriteLine('new: every line arrived exactly once') }
else { [Console]::WriteLine('new: STILL BROKEN - the fix is wrong') }
