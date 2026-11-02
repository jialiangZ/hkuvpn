#Requires -Version 5.1
<#
hkuvpn-app.ps1 - system-tray frontend for the hkuvpn Windows port.

Run it (or make a shortcut whose target is):
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File hkuvpn-app.ps1

Tray icon states:
  gray    - disconnected
  orange  - connecting (waiting for the MFA code)
  green   - connected, worker heartbeat fresh
  red     - connected but worker not responsive (hb.log stale)

Double-click the icon  - connect (UAC, then an MFA popup appears)
Right-click menu       - Connect / Disconnect / Show status / Stop and exit / Exit

The app is only a frontend. The tunnel runs in the same hidden elevated
worker that 'hkuvpn.ps1 -t' uses, and Disconnect goes through the same
stop-flag path (no UAC). Exiting the app NEVER kills a running session.
#>

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Script:Launcher     = Join-Path $PSScriptRoot 'hkuvpn.ps1'
$Script:TempBase     = Join-Path $env:TEMP 'hkuvpn'
$Script:MarkerFile   = Join-Path $Script:TempBase 'markers.log'
$Script:HbFile       = Join-Path $Script:TempBase 'hb.log'
$Script:PidsFile     = Join-Path $Script:TempBase 'pids.txt'
$Script:ResponseFile = Join-Path $Script:TempBase 'response.txt'
$Script:StopFlagFile = Join-Path $Script:TempBase 'stop.flag'

$Script:State   = 'idle'      # idle | connecting | connected
$Script:Seen    = 0           # marker line cursor
$Script:Retry   = $false

# --- worker helpers (same pids.txt protocol as hkuvpn.ps1) -------------------

function Get-WorkerPid {
    if (-not (Test-Path $Script:PidsFile)) { return 0 }
    foreach ($l in (Get-Content $Script:PidsFile -ErrorAction SilentlyContinue)) {
        if ("$l" -like 'WORKER=*') {
            $v = ("$l".Substring(6)).Trim()
            $n = 0
            if ([int]::TryParse($v, [ref]$n)) { return $n }
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

# --- actions ------------------------------------------------------------------

function Send-TrayBalloon([string]$Text, [string]$Kind) {
    $Script:Icon.BalloonTipTitle = 'hkuvpn'
    $Script:Icon.BalloonTipText  = $Text
    $Script:Icon.BalloonTipIcon  = [System.Windows.Forms.ToolTipIcon]$Kind
    $Script:Icon.ShowBalloonTip(4000)
}

function Start-TrayConnect {
    if (Test-WorkerAlive) {
        $Script:State = 'connected'
        Update-TrayIcon
        Send-TrayBalloon 'A session is already running.' 'Info'
        return
    }
    $parts = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
               '-File', ('"{0}"' -f $Script:Launcher), '"--Worker"')
    try {
        $null = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList ($parts -join ' ') -Verb RunAs -WindowStyle Hidden
        $Script:State = 'connecting'
        $Script:Seen  = 0
        $Script:Retry = $false
        Update-TrayIcon
    } catch {
        Send-TrayBalloon ('Elevation declined: ' + $_.Exception.Message) 'Error'
    }
}

function Invoke-TrayDisconnect {
    if (-not (Test-WorkerAlive) -and $Script:State -ne 'connected') {
        Send-TrayBalloon 'Not running.' 'Info'
        return
    }
    # Delegate to hkuvpn.ps1 --stop: healthy worker -> stop flag (no UAC);
    # wedged worker -> it escalates and asks for UAC itself.
    $parts = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
               '-File', ('"{0}"' -f $Script:Launcher), '"--stop"')
    $null = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList ($parts -join ' ') -WindowStyle Hidden
    $Script:State = 'idle'
    Update-TrayIcon
    Send-TrayBalloon 'Disconnect requested.' 'Info'
}

function Read-MfaPopup([bool]$Rejected) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text          = 'hkuvpn - MFA code'
    $f.Size          = New-Object System.Drawing.Size(340, 150)
    $f.StartPosition = 'CenterScreen'
    $f.TopMost       = $true
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox   = $false

    $lbl = New-Object System.Windows.Forms.Label
    if ($Rejected) {
        $lbl.Text = 'The previous code was REJECTED. Enter the code showing NOW:'
    } else {
        $lbl.Text = 'Enter the 6-digit Microsoft Authenticator code:'
    }
    $lbl.SetBounds(12, 12, 300, 20)
    $f.Controls.Add($lbl)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.SetBounds(12, 38, 300, 24)
    $tb.MaxLength = 6
    $f.Controls.Add($tb)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'
    $ok.DialogResult = 'OK'
    $ok.SetBounds(156, 74, 76, 26)
    $f.Controls.Add($ok)
    $f.AcceptButton = $ok

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Abort'
    $cancel.DialogResult = 'Cancel'
    $cancel.SetBounds(238, 74, 76, 26)
    $f.Controls.Add($cancel)
    $f.CancelButton = $cancel

    if ($f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return "$($tb.Text)".Trim()
    }
    return $null
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

# --- icons --------------------------------------------------------------------

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

$Script:IcoGray    = New-StateIcon 'Gray'
$Script:IcoOrange  = New-StateIcon 'Orange'
$Script:IcoGreen   = New-StateIcon 'Green'
$Script:IcoRed     = New-StateIcon 'Red'

function Update-TrayIcon {
    switch ($Script:State) {
        'connecting' { $Script:Icon.Icon = $Script:IcoOrange; $Script:Icon.Text = 'hkuvpn: connecting...' }
        'connected'  {
            if (Test-HeartbeatFresh) {
                $Script:Icon.Icon = $Script:IcoGreen
                $Script:Icon.Text = 'hkuvpn: connected'
            } else {
                $Script:Icon.Icon = $Script:IcoRed
                $Script:Icon.Text = 'hkuvpn: worker not responsive (hku-stop to recover)'
            }
        }
        default      { $Script:Icon.Icon = $Script:IcoGray; $Script:Icon.Text = 'hkuvpn: disconnected' }
    }
}

# --- tray UI ------------------------------------------------------------------

$Script:Icon = New-Object System.Windows.Forms.NotifyIcon
$Script:Icon.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenu

$miConnect = New-Object System.Windows.Forms.MenuItem 'Connect'
$null = $menu.MenuItems.Add($miConnect)
$miDisconnect = New-Object System.Windows.Forms.MenuItem 'Disconnect'
$null = $menu.MenuItems.Add($miDisconnect)
$null = $menu.MenuItems.Add('-')
$miStatus = New-Object System.Windows.Forms.MenuItem 'Show status'
$null = $menu.MenuItems.Add($miStatus)
$null = $menu.MenuItems.Add('-')
$miStopExit = New-Object System.Windows.Forms.MenuItem 'Stop VPN and exit'
$null = $menu.MenuItems.Add($miStopExit)
$miExit = New-Object System.Windows.Forms.MenuItem 'Exit (keep VPN running)'
$null = $menu.MenuItems.Add($miExit)

$Script:Icon.ContextMenu = $menu
Update-TrayIcon

$miConnect.Add_Click({ Start-TrayConnect })
$miDisconnect.Add_Click({ Invoke-TrayDisconnect })
$miStatus.Add_Click({
    if (Test-WorkerAlive) {
        $hb = 'stale'
        if (Test-HeartbeatFresh) { $hb = 'fresh' }
        Send-TrayBalloon ("Worker alive (pid {0}), heartbeat {1}." -f (Get-WorkerPid), $hb) 'Info'
    } else {
        Send-TrayBalloon 'No session is running.' 'Info'
    }
})
$miStopExit.Add_Click({
    if (Test-WorkerAlive) { Invoke-TrayDisconnect }
    $Script:Icon.Visible = $false
    $Script:Context.ExitThread()
})
$miExit.Add_Click({
    $Script:Icon.Visible = $false
    $Script:Context.ExitThread()
})
$Script:Icon.Add_DoubleClick({ Start-TrayConnect })

# --- state machine ------------------------------------------------------------

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    # 1) Consume new marker lines (state transitions from the worker).
    $lines = @()
    if (Test-Path $Script:MarkerFile) {
        try { $lines = @(Get-Content $Script:MarkerFile -ErrorAction Stop) } catch {}
    }
    $new = @()
    if ($lines.Count -gt $Script:Seen) {
        $new = $lines[$Script:Seen .. ($lines.Count - 1)]
        $Script:Seen = $lines.Count
    }
    foreach ($l in $new) {
        if ("$l" -match 'HKUVPN_CONNECTED') {
            $Script:State = 'connected'
            Update-TrayIcon
            Send-TrayBalloon 'Connected - tunnel is up.' 'Info'
        } elseif ("$l" -match 'HKUVPN_MFA_RESPONSE_REQUIRED' -and $Script:State -eq 'connecting') {
            $timer.Stop()
            $code = Read-MfaPopup ([bool]$Script:Retry)
            $timer.Start()
            if ($code -and (Send-MfaResponse $code)) {
                $Script:Retry = $false
            } elseif (-not $code) {
                # Abort: ask the worker to stop through the stop flag.
                try { Set-Content -Path $Script:StopFlagFile -Value 'stop' -NoNewline } catch {}
                $Script:State = 'idle'
                Update-TrayIcon
                Send-TrayBalloon 'Aborted by user; stopping the worker.' 'Warning'
            }
        } elseif ("$l" -match 'HKUVPN_MFA_RETRY') {
            $Script:Retry = $true
        } elseif ("$l" -match 'HKUVPN_EXITED') {
            $wasConnecting = ($Script:State -eq 'connecting')
            $Script:State = 'idle'
            Update-TrayIcon
            if ($wasConnecting) {
                Send-TrayBalloon 'The worker exited early - see %TEMP%\hkuvpn\openconnect.log' 'Error'
            }
        }
    }

    # 2) Connected health: worker gone (stopped elsewhere / crashed)?
    if ($Script:State -eq 'connected' -and -not (Test-WorkerAlive)) {
        $Script:State = 'idle'
        Update-TrayIcon
        Send-TrayBalloon 'Session ended.' 'Info'
    }

    # 3) Refresh icon/tooltip (heartbeat color) at a modest rate.
    if ($Script:State -eq 'connected') { Update-TrayIcon }
})
$timer.Start()

$Script:Context = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($Script:Context)
