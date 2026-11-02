#Requires -Version 5.1
<#
hkuvpn-app.ps1 - windowed frontend for the hkuvpn Windows port.

A proper little VPN window (in the spirit of openconnect-gui, HKU-flavored):
status header, session info (server / account / VPN address / duration /
proxies), inline MFA entry while connecting, a live OpenConnect log view,
and a tray icon with close-to-tray.

It is a pure frontend on the same machinery as 'hkuvpn.ps1 -t':
  - the tunnel runs in a hidden elevated worker (one UAC per connect);
  - markers.log drives the state machine (line cursor, no stale prompts);
  - the MFA code is delivered through the --mfa response file;
  - Disconnect delegates to 'hkuvpn.ps1 --stop' (stop flag, no UAC);
  - closing/exiting the app NEVER kills a running session.
#>

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Script:Launcher     = Join-Path $PSScriptRoot 'hkuvpn.ps1'
$Script:EnvFile      = Join-Path $env:USERPROFILE '.vpn\hku.env'
$Script:TempBase     = Join-Path $env:TEMP 'hkuvpn'
$Script:MarkerFile   = Join-Path $Script:TempBase 'markers.log'
$Script:LogFile      = Join-Path $Script:TempBase 'openconnect.log'
$Script:StateFile    = Join-Path $Script:TempBase 'vpnc-state.txt'
$Script:HbFile       = Join-Path $Script:TempBase 'hb.log'
$Script:PidsFile     = Join-Path $Script:TempBase 'pids.txt'
$Script:ResponseFile = Join-Path $Script:TempBase 'response.txt'
$Script:StopFlagFile = Join-Path $Script:TempBase 'stop.flag'

$Script:State        = 'idle'    # idle | connecting | connected
$Script:Seen         = 0         # marker line cursor
$Script:Retry        = $false
$Script:ConnectedAt  = $null
$Script:LogPos       = 0
$Script:RealExit     = $false

# --- helpers ------------------------------------------------------------------

function Get-WorkerPid {
    if (-not (Test-Path $Script:PidsFile)) { return 0 }
    foreach ($l in (Get-Content $Script:PidsFile -ErrorAction SilentlyContinue)) {
        if ("$l" -like 'WORKER=*') {
            $n = 0
            if ([int]::TryParse(("$l".Substring(6)).Trim(), [ref]$n)) { return $n }
        }
    }
    return 0
}

function Test-WorkerAlive {
    $p = Get-WorkerPid
    if ($p -le 0) { return $false }
    $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
    return ($null -ne $proc -and $proc.ProcessName -match 'powershell')
}

function Test-HeartbeatFresh {
    if (-not (Test-Path $Script:HbFile)) { return $false }
    return (((Get-Date) - (Get-Item $Script:HbFile).LastWriteTime).TotalSeconds -le 15)
}

function Get-StateValue([string]$Key) {
    if (-not (Test-Path $Script:StateFile)) { return $null }
    $line = Get-Content $Script:StateFile -ErrorAction SilentlyContinue |
        Where-Object { $_ -like "$Key=*" } | Select-Object -First 1
    if ($line) { return $line.Substring($Key.Length + 1) }
    return $null
}

function Get-Account {
    if (Test-Path $Script:EnvFile) {
        foreach ($l in (Get-Content $Script:EnvFile -ErrorAction SilentlyContinue)) {
            if ("$l".Trim() -like 'HKU_USER=*') { return ("$l".Trim().Substring(9)) }
        }
    }
    return '(not configured)'
}

function Send-MfaResponse([string]$Code) {
    if ($Code -notmatch '^\d{6}$') { return $false }
    $dir = Split-Path -Parent $Script:ResponseFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = $Script:ResponseFile + '.tmp'
    Set-Content -Path $tmp -Value $Code -NoNewline -ErrorAction Stop
    Move-Item -Path $tmp -Destination $Script:ResponseFile -Force -ErrorAction Stop
    return $true
}

function Write-StopFlag {
    try { Set-Content -Path $Script:StopFlagFile -Value 'stop' -NoNewline } catch {}
}

function Invoke-Connect {
    if (Test-WorkerAlive) { Set-AppState 'connected'; return }
    $parts = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
               '-File', ('"{0}"' -f $Script:Launcher), '"--Worker"')
    try {
        $null = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList ($parts -join ' ') -Verb RunAs -WindowStyle Hidden
        $Script:Seen  = 0
        Set-AppState 'connecting'
    } catch {
        $Script:Status.Text = 'Elevation declined'
        $Script:Status.ForeColor = [System.Drawing.Color]::Firebrick
    }
}

function Invoke-Disconnect {
    if (-not (Test-WorkerAlive) -and $Script:State -eq 'idle') { return }
    if ($Script:State -eq 'connecting') {
        # Cancel: ask the fresh worker to stop through the stop flag.
        Write-StopFlag
        Set-AppState 'idle'
        return
    }
    $parts = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
               '-File', ('"{0}"' -f $Script:Launcher), '"--stop"')
    $null = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList ($parts -join ' ') -WindowStyle Hidden
    Set-AppState 'idle'
}

# --- UI state -----------------------------------------------------------------

function Set-AppState([string]$NewState) {
    $Script:State = $NewState
    if ($NewState -eq 'connecting') {
        $Script:Status.Text = 'Connecting...'
        $Script:Status.ForeColor = [System.Drawing.Color]::DarkOrange
        $Script:Dot.BackColor  = [System.Drawing.Color]::DarkOrange
        $Script:BtnConnect.Enabled    = $false
        $Script:BtnDisconnect.Enabled = $true
        $Script:BtnDisconnect.Text    = 'Cancel'
        $Script:GrpInfo.Visible = $false
        $Script:PnlMfa.Visible  = $false
        $Script:Retry = $false
    } elseif ($NewState -eq 'connected') {
        if (-not $Script:ConnectedAt) { $Script:ConnectedAt = Get-Date }
        $Script:GrpInfo.Visible = $true
        $Script:PnlMfa.Visible  = $false
        $Script:BtnConnect.Enabled    = $false
        $Script:BtnDisconnect.Enabled = $true
        $Script:BtnDisconnect.Text    = 'Disconnect'
        $Script:TxtVpn.Text = (Get-StateValue 'IP4')
        if (-not $Script:TxtVpn.Text) { $Script:TxtVpn.Text = '-' }
    } else {
        $Script:Status.Text = 'Disconnected'
        $Script:Status.ForeColor = [System.Drawing.Color]::DimGray
        $Script:Dot.BackColor  = [System.Drawing.Color]::DimGray
        $Script:BtnConnect.Enabled    = $true
        $Script:BtnDisconnect.Enabled = $false
        $Script:BtnDisconnect.Text    = 'Disconnect'
        $Script:GrpInfo.Visible = $false
        $Script:PnlMfa.Visible  = $false
        $Script:ConnectedAt = $null
        $Script:TxtVpn.Text = '-'
    }
    Update-TrayIcon
}

function Show-MfaPanel {
    $Script:PnlMfa.Visible  = $true
    $Script:GrpInfo.Visible = $false
    $Script:LblMfaNote.Visible = $Script:Retry
    $Script:TxtMfa.Text = ''
    $Script:Form.AcceptButton = $Script:BtnMfa
    $null = $Script:TxtMfa.Focus()
}

function Hide-MfaPanel {
    $Script:PnlMfa.Visible = $false
    $Script:Form.AcceptButton = $null
}

# --- tray icon ----------------------------------------------------------------

function New-StateIcon([string]$ColorName) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromName($ColorName))
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 1
    $g.FillEllipse($brush, 3, 3, 10, 10)
    $g.DrawEllipse($pen, 3, 3, 10, 10)
    $g.Dispose()
    $ico = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $ico
}

$Script:IcoGray   = New-StateIcon 'Gray'
$Script:IcoOrange = New-StateIcon 'Orange'
$Script:IcoGreen  = New-StateIcon 'Green'
$Script:IcoRed    = New-StateIcon 'Red'

function Update-TrayIcon {
    switch ($Script:State) {
        'connecting' { $Script:Tray.Icon = $Script:IcoOrange; $Script:Tray.Text = 'HKU VPN: connecting' }
        'connected'  {
            if (Test-HeartbeatFresh) {
                $Script:Tray.Icon = $Script:IcoGreen; $Script:Tray.Text = 'HKU VPN: connected'
            } else {
                $Script:Tray.Icon = $Script:IcoRed;   $Script:Tray.Text = 'HKU VPN: worker unresponsive'
            }
        }
        default      { $Script:Tray.Icon = $Script:IcoGray; $Script:Tray.Text = 'HKU VPN: disconnected' }
    }
}

# --- form ---------------------------------------------------------------------

$Script:Form = New-Object System.Windows.Forms.Form
$Script:Form.Text = 'HKU VPN'
$Script:Form.ClientSize = New-Object System.Drawing.Size(540, 474)
$Script:Form.FormBorderStyle = 'FixedSingle'
$Script:Form.MaximizeBox = $false
$Script:Form.StartPosition = 'CenterScreen'
$Script:Form.Icon = $Script:IcoGray

# Status header
$Script:Dot = New-Object System.Windows.Forms.Panel
$Script:Dot.SetBounds(16, 24, 16, 16)
$Script:Dot.BackColor = [System.Drawing.Color]::DimGray
$null = $Script:Form.Controls.Add($Script:Dot)

$Script:Status = New-Object System.Windows.Forms.Label
$Script:Status.Text = 'Disconnected'
$Script:Status.ForeColor = [System.Drawing.Color]::DimGray
$Script:Status.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$Script:Status.SetBounds(42, 10, 300, 36)
$null = $Script:Form.Controls.Add($Script:Status)

$Script:LblServer = New-Object System.Windows.Forms.Label
$Script:LblServer.Text = 'vpn2fa.hku.hk'
$Script:LblServer.ForeColor = [System.Drawing.Color]::SteelBlue
$Script:LblServer.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$Script:LblServer.TextAlign = 'MiddleRight'
$Script:LblServer.SetBounds(330, 16, 190, 26)
$null = $Script:Form.Controls.Add($Script:LblServer)

# Session info group
$Script:GrpInfo = New-Object System.Windows.Forms.GroupBox
$Script:GrpInfo.Text = 'Session'
$Script:GrpInfo.SetBounds(10, 56, 520, 124)
$null = $Script:Form.Controls.Add($Script:GrpInfo)

function Add-InfoRow([string]$Name, [int]$Y, [ref]$ValueLabel) {
    $n = New-Object System.Windows.Forms.Label
    $n.Text = $Name
    $n.ForeColor = [System.Drawing.Color]::Gray
    $n.SetBounds(14, $Y, 90, 18)
    $null = $Script:GrpInfo.Controls.Add($n)
    $v = New-Object System.Windows.Forms.Label
    $v.SetBounds(108, $Y, 390, 18)
    $null = $Script:GrpInfo.Controls.Add($v)
    $ValueLabel.Value = $v
}

$ref = [ref]$null
Add-InfoRow 'Account'  26 $ref;  $Script:TxtAccount = $ref.Value
Add-InfoRow 'VPN IP'   48 $ref;  $Script:TxtVpn     = $ref.Value
Add-InfoRow 'DNS'      70 $ref;  $Script:TxtDns     = $ref.Value
Add-InfoRow 'Duration' 92 $ref;  $Script:TxtDur     = $ref.Value
$Script:TxtAccount.Text = Get-Account
$Script:TxtDns.Text = 'socks5://127.0.0.1:1080  ·  http://127.0.0.1:1088'
$Script:TxtVpn.Text = '-'
$Script:TxtDur.Text = '-'

# MFA panel (occupies the same slot as the session group)
$Script:PnlMfa = New-Object System.Windows.Forms.Panel
$Script:PnlMfa.SetBounds(10, 56, 520, 124)
$Script:PnlMfa.Visible = $false
$null = $Script:Form.Controls.Add($Script:PnlMfa)

$Script:LblMfa = New-Object System.Windows.Forms.Label
$Script:LblMfa.Text = 'Enter the 6-digit Microsoft Authenticator code:'
$Script:LblMfa.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$Script:LblMfa.SetBounds(14, 20, 400, 20)
$null = $Script:PnlMfa.Controls.Add($Script:LblMfa)

$Script:LblMfaNote = New-Object System.Windows.Forms.Label
$Script:LblMfaNote.Text = 'The previous code was REJECTED - enter the one showing NOW.'
$Script:LblMfaNote.ForeColor = [System.Drawing.Color]::Firebrick
$Script:LblMfaNote.SetBounds(14, 40, 420, 18)
$Script:LblMfaNote.Visible = $false
$null = $Script:PnlMfa.Controls.Add($Script:LblMfaNote)

$Script:TxtMfa = New-Object System.Windows.Forms.TextBox
$Script:TxtMfa.SetBounds(14, 66, 160, 26)
$Script:TxtMfa.Font = New-Object System.Drawing.Font('Consolas', 12)
$Script:TxtMfa.MaxLength = 6
$Script:TxtMfa.Add_KeyPress({
    if ($_.KeyChar -notmatch '^[\d\b]$') { $_.Handled = $true }
})
$null = $Script:PnlMfa.Controls.Add($Script:TxtMfa)

$Script:BtnMfa = New-Object System.Windows.Forms.Button
$Script:BtnMfa.Text = 'Submit'
$Script:BtnMfa.SetBounds(184, 65, 90, 28)
$null = $Script:PnlMfa.Controls.Add($Script:BtnMfa)
$Script:BtnMfa.Add_Click({
    $code = "$($Script:TxtMfa.Text)".Trim()
    if (Send-MfaResponse $code) {
        Hide-MfaPanel
        $Script:Status.Text = 'Connecting... (code accepted, wait)'
    }
})

# Buttons
$Script:BtnConnect = New-Object System.Windows.Forms.Button
$Script:BtnConnect.Text = 'Connect'
$Script:BtnConnect.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$Script:BtnConnect.SetBounds(10, 188, 160, 34)
$null = $Script:Form.Controls.Add($Script:BtnConnect)
$Script:BtnConnect.Add_Click({ Invoke-Connect })

$Script:BtnDisconnect = New-Object System.Windows.Forms.Button
$Script:BtnDisconnect.Text = 'Disconnect'
$Script:BtnDisconnect.Enabled = $false
$Script:BtnDisconnect.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$Script:BtnDisconnect.SetBounds(178, 188, 160, 34)
$null = $Script:Form.Controls.Add($Script:BtnDisconnect)
$Script:BtnDisconnect.Add_Click({ Invoke-Disconnect })

# Log group
$Script:GrpLog = New-Object System.Windows.Forms.GroupBox
$Script:GrpLog.Text = 'OpenConnect log (live)'
$Script:GrpLog.SetBounds(10, 228, 520, 206)
$null = $Script:Form.Controls.Add($Script:GrpLog)

$Script:LogBox = New-Object System.Windows.Forms.TextBox
$Script:LogBox.Multiline = $true
$Script:LogBox.ReadOnly = $true
$Script:LogBox.ScrollBars = 'Vertical'
$Script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$Script:LogBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$Script:LogBox.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$Script:LogBox.SetBounds(10, 20, 500, 146)
$null = $Script:GrpLog.Controls.Add($Script:LogBox)

$Script:BtnClearLog = New-Object System.Windows.Forms.Button
$Script:BtnClearLog.Text = 'Clear view'
$Script:BtnClearLog.SetBounds(438, 172, 72, 24)
$null = $Script:GrpLog.Controls.Add($Script:BtnClearLog)
$Script:BtnClearLog.Add_Click({
    $Script:LogBox.Clear()
    $Script:LogPos = -1      # force full re-read on next tick
})

# Close-to-tray checkbox
$Script:ChkTray = New-Object System.Windows.Forms.CheckBox
$Script:ChkTray.Text = 'Close button minimizes to tray'
$Script:ChkTray.Checked = $true
$Script:ChkTray.SetBounds(10, 440, 240, 22)
$null = $Script:Form.Controls.Add($Script:ChkTray)

# Tray icon
$Script:Tray = New-Object System.Windows.Forms.NotifyIcon
$Script:Tray.Visible = $true
$trayMenu = New-Object System.Windows.Forms.ContextMenu
$miShow = New-Object System.Windows.Forms.MenuItem 'Show window'
$null = $trayMenu.MenuItems.Add($miShow)
$null = $trayMenu.MenuItems.Add('-')
$miExit = New-Object System.Windows.Forms.MenuItem 'Exit (VPN keeps running)'
$null = $trayMenu.MenuItems.Add($miExit)
$Script:Tray.ContextMenu = $trayMenu
$miShow.Add_Click({ $Script:Form.Show(); $Script:Form.WindowState = 'Normal'; $null = $Script:Form.Activate() })
$miExit.Add_Click({ $Script:RealExit = $true; $Script:Tray.Visible = $false; $Script:Form.Close() })
$Script:Tray.Add_DoubleClick({ $Script:Form.Show(); $Script:Form.WindowState = 'Normal'; $null = $Script:Form.Activate() })

$Script:Form.Add_FormClosing({
    if (-not $Script:RealExit -and $Script:ChkTray.Checked) {
        $_.Cancel = $true
        $Script:Form.Hide()
    } else {
        $Script:Tray.Visible = $false
    }
})

# --- timers -------------------------------------------------------------------

function Update-LogTail {
    if (-not (Test-Path $Script:LogFile)) { return }
    try {
        if ($Script:LogPos -lt 0) {
            # Fresh view: start from the last 4 KB of the log.
            $init = [IO.File]::Open($Script:LogFile, 'Open', 'Read', 'ReadWrite')
            $start = [Math]::Max(0, $init.Length - 4096)
            $init.Close()
            $Script:LogPos = $start
        }
        $fs = [IO.File]::Open($Script:LogFile, 'Open', 'Read', 'ReadWrite')
        $len = $fs.Length
        if ($len -lt $Script:LogPos) { $Script:LogPos = 0 }
        if ($len -gt $Script:LogPos) {
            $fs.Seek($Script:LogPos, 'Begin') | Out-Null
            $sr = New-Object IO.StreamReader($fs)
            $txt = $sr.ReadToEnd()
            $sr.Close()
            $Script:LogPos = $len
            $Script:LogBox.AppendText($txt)
            if ($Script:LogBox.TextLength -gt 80000) {
                $Script:LogBox.Text = $Script:LogBox.Text.Substring($Script:LogBox.TextLength - 40000)
            }
            $Script:LogBox.SelectionStart = $Script:LogBox.TextLength
            $Script:LogBox.ScrollToCaret()
        } else {
            $fs.Close()
        }
    } catch {}
}

$tick = New-Object System.Windows.Forms.Timer
$tick.Interval = 500
$tick.Add_Tick({
    # 1) Consume new marker lines.
    $lines = @()
    if (Test-Path $Script:MarkerFile) {
        try { $lines = @(Get-Content $Script:MarkerFile -ErrorAction Stop) } catch {}
    }
    if ($lines.Count -gt $Script:Seen) {
        $new = $lines[$Script:Seen .. ($lines.Count - 1)]
        $Script:Seen = $lines.Count
        foreach ($l in $new) {
            if ("$l" -match 'HKUVPN_CONNECTED') {
                $Script:ConnectedAt = Get-Date
                Set-AppState 'connected'
                $Script:Status.Text = 'Connected'
                $Script:Status.ForeColor = [System.Drawing.Color]::ForestGreen
                $Script:Dot.BackColor = [System.Drawing.Color]::ForestGreen
            } elseif ("$l" -match 'HKUVPN_MFA_RESPONSE_REQUIRED' -and $Script:State -eq 'connecting') {
                Show-MfaPanel
            } elseif ("$l" -match 'HKUVPN_MFA_RETRY') {
                $Script:Retry = $true
            } elseif ("$l" -match 'HKUVPN_EXITED') {
                if ($Script:State -eq 'connecting') {
                    $Script:Status.Text = 'Failed - see log below'
                    $Script:Status.ForeColor = [System.Drawing.Color]::Firebrick
                    $Script:Dot.BackColor = [System.Drawing.Color]::Firebrick
                    Hide-MfaPanel
                    $Script:BtnConnect.Enabled = $true
                    $Script:BtnDisconnect.Enabled = $false
                }
            }
        }
    }

    # 2) Connected health + live fields.
    if ($Script:State -eq 'connected') {
        if (Test-WorkerAlive) {
            if (Test-HeartbeatFresh) {
                $Script:Status.Text = 'Connected'
                $Script:Status.ForeColor = [System.Drawing.Color]::ForestGreen
                $Script:Dot.BackColor = [System.Drawing.Color]::ForestGreen
            } else {
                $Script:Status.Text = 'Worker unresponsive - use Disconnect'
                $Script:Status.ForeColor = [System.Drawing.Color]::Firebrick
                $Script:Dot.BackColor = [System.Drawing.Color]::Firebrick
            }
            $ip = Get-StateValue 'IP4'
            if ($ip) { $Script:TxtVpn.Text = $ip }
            if ($Script:ConnectedAt) {
                $el = (Get-Date) - $Script:ConnectedAt
                $Script:TxtDur.Text = ('{0:00}:{1:00}:{2:00}' -f [int]$el.TotalHours, $el.Minutes, $el.Seconds)
            }
        } else {
            Set-AppState 'idle'
        }
        Update-TrayIcon
    }

    # 3) While connecting with no worker left (crashed pre-MFA): recover.
    if ($Script:State -eq 'connecting' -and -not (Test-WorkerAlive) -and
        (Test-Path $Script:MarkerFile)) {
        $all = ''
        try { $all = Get-Content $Script:MarkerFile -Raw } catch {}
        if ($all -match 'HKUVPN_EXITED') { Set-AppState 'idle' }
    }
})
$tick.Start()

$logTick = New-Object System.Windows.Forms.Timer
$logTick.Interval = 800
$logTick.Add_Tick({ Update-LogTail })
$logTick.Start()

# --- boot ---------------------------------------------------------------------

Set-AppState 'idle'
if (Test-WorkerAlive) {
    Set-AppState 'connected'
    $Script:Status.Text = 'Connected'
    $Script:Status.ForeColor = [System.Drawing.Color]::ForestGreen
    $Script:Dot.BackColor = [System.Drawing.Color]::ForestGreen
}
$null = $Script:Form.ShowDialog()
