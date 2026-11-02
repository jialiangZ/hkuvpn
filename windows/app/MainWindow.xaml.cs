using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using WinForms = System.Windows.Forms;

namespace Hkuvpn.App
{
    public partial class MainWindow : Window
    {
        // ---- state protocol (same files hkuvpn.ps1 uses) -------------------
        private static readonly string TempBase =
            Path.Combine(Path.GetTempPath(), "hkuvpn");
        private static readonly string MarkerFile   = Path.Combine(TempBase, "markers.log");
        private static readonly string OcLogFile    = Path.Combine(TempBase, "openconnect.log");
        private static readonly string StateFile    = Path.Combine(TempBase, "vpnc-state.txt");
        private static readonly string HbFile       = Path.Combine(TempBase, "hb.log");
        private static readonly string PidsFile     = Path.Combine(TempBase, "pids.txt");
        private static readonly string ResponseFile = Path.Combine(TempBase, "response.txt");
        private static readonly string StopFlagFile = Path.Combine(TempBase, "stop.flag");
        private static readonly string EnvFile =
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                         ".vpn", "hku.env");
        private static readonly string LearnedFile =
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                         ".vpn", "learned-routes.txt");

        private enum AppState { Idle, Connecting, Connected }

        private AppState _state = AppState.Idle;
        private int _seen;                 // marker line cursor
        private bool _retry;               // previous MFA code was rejected
        private DateTime? _connectedAt;
        private long _logPos;
        private bool _realExit;
        private string _launcher;
        private string _account = "-";

        private readonly DispatcherTimer _tick = new DispatcherTimer();
        private readonly DispatcherTimer _logTick = new DispatcherTimer();
        private WinForms.NotifyIcon _tray;

        public MainWindow()
        {
            InitializeComponent();
            FindLauncher();
            ReadAccount();
            _logPos = -1;   // first tail starts near the end of any existing log

            _tick.Interval = TimeSpan.FromMilliseconds(400);
            _tick.Tick += Tick;
            _tick.Start();

            _logTick.Interval = TimeSpan.FromMilliseconds(600);
            _logTick.Tick += (s, e) => TailLog();
            _logTick.Start();

            TxtMfa.PreviewTextInput += (s, e) =>
                e.Handled = !e.Text.All(char.IsDigit);

            Loaded += (s, e) =>
            {
                if (WorkerAlive()) { _seen = 0; SetState(AppState.Connected); }
            };
        }

        // ---- launcher discovery --------------------------------------------

        private void FindLauncher()
        {
            string exeDir = AppDomain.CurrentDomain.BaseDirectory;
            string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string[] candidates =
            {
                Path.Combine(exeDir, "..", "bin", "hkuvpn.ps1"),                    // windows\app\publish
                Path.Combine(exeDir, "..", "..", "..", "bin", "hkuvpn.ps1"),       // windows\app\bin\...
                Path.Combine(home, "hkuvpn", "windows", "bin", "hkuvpn.ps1"),
            };
            _launcher = candidates.FirstOrDefault(File.Exists);
        }

        private void ReadAccount()
        {
            try
            {
                if (File.Exists(EnvFile))
                {
                    foreach (string l in File.ReadAllLines(EnvFile))
                    {
                        string t = l.Trim();
                        if (t.StartsWith("HKU_USER=", StringComparison.OrdinalIgnoreCase))
                        {
                            _account = t.Substring(9);
                            break;
                        }
                    }
                }
            }
            catch { }
            ValAccount.Text = _account;
        }

        // ---- actions --------------------------------------------------------

        private void BtnConnect_Click(object sender, RoutedEventArgs e)
        {
            if (_launcher == null)
            {
                SetHeader("Launcher not found",
                          "Put HKUVPN.exe inside the hkuvpn repo (windows\\app\\publish) or clone the repo to %USERPROFILE%\\hkuvpn",
                          Brushes.Red);
                return;
            }
            if (WorkerAlive()) { SetState(AppState.Connected); return; }

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + _launcher + "\" \"--Worker\"",
                Verb = "runas",
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Hidden,
            };
            try
            {
                Process.Start(psi);
                _seen = 0;
                _retry = false;
                SetState(AppState.Connecting);
            }
            catch (Win32Exception ex)
            {
                SetHeader("Elevation declined", ex.Message, Brushes.Red);
            }
            catch (Exception ex)
            {
                SetHeader("Could not start the worker", ex.Message, Brushes.Red);
            }
        }

        private void BtnDisconnect_Click(object sender, RoutedEventArgs e)
        {
            if (_state == AppState.Connecting)
            {
                try { File.WriteAllText(StopFlagFile, "stop"); } catch { }
                SetState(AppState.Idle);
                return;
            }
            if (_state != AppState.Connected) return;

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + _launcher + "\" \"--stop\"",
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Hidden,
            };
            try { Process.Start(psi); } catch { }
            SetState(AppState.Idle);
        }

        private void BtnMfaSubmit_Click(object sender, RoutedEventArgs e)
        {
            string code = TxtMfa.Text.Trim();
            if (code.Length != 6 || !code.All(char.IsDigit))
            {
                LblMfaNote.Text = "The code must be exactly 6 digits.";
                LblMfaNote.Visibility = Visibility.Visible;
                return;
            }
            try
            {
                string dir = Path.GetDirectoryName(ResponseFile);
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                string tmp = ResponseFile + ".tmp";
                File.WriteAllText(tmp, code);
                File.Move(tmp, ResponseFile, true);
                MfaPanel.Visibility = Visibility.Collapsed;
                SetHeader("Connecting...", "MFA code accepted - waiting for the tunnel",
                          Brushes.Orange);
            }
            catch (Exception ex)
            {
                LblMfaNote.Text = "Could not deliver the code: " + ex.Message;
                LblMfaNote.Visibility = Visibility.Visible;
            }
        }

        private void BtnClearLog_Click(object sender, RoutedEventArgs e)
        {
            LogBox.Clear();
            _logPos = -1;
        }

        // ---- state machine --------------------------------------------------

        private void Tick(object sender, EventArgs e)
        {
            string[] lines = Array.Empty<string>();
            try
            {
                if (File.Exists(MarkerFile)) lines = File.ReadAllLines(MarkerFile);
            }
            catch { }

            if (lines.Length > _seen)
            {
                for (int i = _seen; i < lines.Length; i++)
                {
                    string l = lines[i];
                    if (l.Contains("HKUVPN_CONNECTED"))
                    {
                        _connectedAt = DateTime.Now;
                        SetState(AppState.Connected);
                    }
                    else if (l.Contains("HKUVPN_MFA_RESPONSE_REQUIRED") && _state == AppState.Connecting)
                    {
                        MfaPanel.Visibility = Visibility.Visible;
                        CardSession.Visibility = Visibility.Collapsed;
                        LblMfaNote.Visibility = _retry ? Visibility.Visible : Visibility.Collapsed;
                        if (_retry) LblMfaNote.Text = "The previous code was REJECTED - enter the one showing NOW.";
                        TxtMfa.Clear();
                        TxtMfa.Focus();
                    }
                    else if (l.Contains("HKUVPN_MFA_RETRY"))
                    {
                        _retry = true;
                    }
                    else if (l.Contains("HKUVPN_EXITED"))
                    {
                        if (_state == AppState.Connecting)
                        {
                            SetHeader("Connection failed", "The worker exited - see the log below",
                                      Brushes.Red);
                            MfaPanel.Visibility = Visibility.Collapsed;
                            CardSession.Visibility = Visibility.Visible;
                            BtnConnect.IsEnabled = true;
                            BtnDisconnect.IsEnabled = false;
                        }
                    }
                }
                _seen = lines.Length;
            }

            if (_state == AppState.Connected)
            {
                if (WorkerAlive())
                {
                    bool fresh = HeartbeatFresh();
                    SetHeader(fresh ? "Connected" : "Worker unresponsive",
                              fresh ? "Tunnel is up - traffic through 127.0.0.1:1080/1088 goes via HKU"
                                    : "The worker loop stopped - use Disconnect to recover",
                              fresh ? Brushes.Green : Brushes.Red);
                    string ip = StateValue("IP4");
                    if (!string.IsNullOrEmpty(ip)) ValVpn.Text = ip;
                    if (_connectedAt.HasValue)
                    {
                        TimeSpan el = DateTime.Now - _connectedAt.Value;
                        ValDuration.Text = string.Format("{0:00}:{1:00}:{2:00}",
                            (int)el.TotalHours, el.Minutes, el.Seconds);
                    }
                    ValRoutes.Text = string.Format("{0} learned route{1}, heartbeat {2}",
                        LearnedCount(), LearnedCount() == 1 ? "" : "s",
                        fresh ? "OK" : "STALE");
                }
                else
                {
                    SetState(AppState.Idle);
                }
            }

            if (_state == AppState.Connecting && !WorkerAlive())
            {
                bool exited = false;
                try
                {
                    exited = File.Exists(MarkerFile) &&
                             File.ReadAllText(MarkerFile).Contains("HKUVPN_EXITED");
                }
                catch { }
                if (exited)
                {
                    MfaPanel.Visibility = Visibility.Collapsed;
                    CardSession.Visibility = Visibility.Visible;
                    SetState(AppState.Idle);
                    SetHeader("Connection failed", "The worker exited - see the log below", Brushes.Red);
                }
            }
        }

        private void SetState(AppState s)
        {
            _state = s;
            switch (s)
            {
                case AppState.Connecting:
                    SetHeader("Connecting...", "Requesting elevation / bringing the tunnel up",
                              Brushes.Orange);
                    BtnConnect.IsEnabled = false;
                    BtnDisconnect.IsEnabled = true;
                    BtnDisconnect.Content = "Cancel";
                    CardSession.Visibility = Visibility.Collapsed;
                    MfaPanel.Visibility = Visibility.Collapsed;
                    _retry = false;
                    break;
                case AppState.Connected:
                    if (_connectedAt == null) _connectedAt = DateTime.Now;
                    SetHeader("Connected", "Tunnel is up", Brushes.Green);
                    BtnConnect.IsEnabled = false;
                    BtnDisconnect.IsEnabled = true;
                    BtnDisconnect.Content = "Disconnect";
                    CardSession.Visibility = Visibility.Visible;
                    MfaPanel.Visibility = Visibility.Collapsed;
                    string ip = StateValue("IP4");
                    ValVpn.Text = string.IsNullOrEmpty(ip) ? "-" : ip;
                    break;
                default:
                    SetHeader("Disconnected", "Tunnel is down",
                              (Brush)FindResource("BrushMuted"));
                    BtnConnect.IsEnabled = true;
                    BtnDisconnect.IsEnabled = false;
                    BtnDisconnect.Content = "Disconnect";
                    CardSession.Visibility = Visibility.Visible;
                    MfaPanel.Visibility = Visibility.Collapsed;
                    _connectedAt = null;
                    ValVpn.Text = "-";
                    ValDuration.Text = "-";
                    ValRoutes.Text = "-";
                    break;
            }
            UpdateTray();
        }

        private void SetHeader(string title, string sub, Brush color)
        {
            LblStatus.Text = title;
            LblSub.Text = sub;
            LblStatus.Foreground = color;
            DotStatus.Fill = color;
        }

        // ---- file protocol helpers ------------------------------------------

        private static int WorkerPid()
        {
            try
            {
                if (!File.Exists(PidsFile)) return 0;
                foreach (string l in File.ReadAllLines(PidsFile))
                {
                    if (l.StartsWith("WORKER=", StringComparison.Ordinal) &&
                        int.TryParse(l.Substring(7).Trim(), out int n))
                        return n;
                }
            }
            catch { }
            return 0;
        }

        private static bool WorkerAlive()
        {
            int pid = WorkerPid();
            if (pid <= 0) return false;
            try
            {
                Process p = Process.GetProcessById(pid);
                return p != null && p.ProcessName.IndexOf("powershell",
                           StringComparison.OrdinalIgnoreCase) >= 0;
            }
            catch { return false; }
        }

        private static bool HeartbeatFresh()
        {
            try
            {
                return File.Exists(HbFile) &&
                       (DateTime.Now - File.GetLastWriteTime(HbFile)).TotalSeconds <= 15;
            }
            catch { return false; }
        }

        private static string StateValue(string key)
        {
            try
            {
                if (!File.Exists(StateFile)) return null;
                foreach (string l in File.ReadAllLines(StateFile))
                {
                    if (l.StartsWith(key + "=", StringComparison.Ordinal))
                        return l.Substring(key.Length + 1);
                }
            }
            catch { }
            return null;
        }

        private static int LearnedCount()
        {
            try
            {
                if (!File.Exists(LearnedFile)) return 0;
                return File.ReadAllLines(LearnedFile).Count(x => x.Trim().Length > 0);
            }
            catch { return 0; }
        }

        // ---- log tail --------------------------------------------------------

        private void TailLog()
        {
            if (!File.Exists(OcLogFile)) return;
            try
            {
                using (FileStream fs = new FileStream(OcLogFile, FileMode.Open,
                           FileAccess.Read, FileShare.ReadWrite))
                {
                    if (_logPos < 0)
                        _logPos = Math.Max(0, fs.Length - 4096);   // start at the tail
                    if (fs.Length < _logPos) _logPos = 0;          // truncated/rotated
                    if (fs.Length <= _logPos) return;
                    fs.Seek(_logPos, SeekOrigin.Begin);
                    using (StreamReader sr = new StreamReader(fs))
                    {
                        string txt = sr.ReadToEnd();
                        _logPos = fs.Length;
                        LogBox.AppendText(txt);
                        if (LogBox.Text.Length > 80000)
                            LogBox.Text = LogBox.Text.Substring(LogBox.Text.Length - 40000);
                        LogBox.CaretIndex = LogBox.Text.Length;
                        LogBox.ScrollToEnd();
                    }
                }
            }
            catch { }
        }

        private void LogBox_TextChanged(object sender, System.Windows.Controls.TextChangedEventArgs e)
        {
            // Auto-scroll only when the user is already at the bottom.
            LogBox.ScrollToEnd();
        }

        // ---- tray ------------------------------------------------------------

        protected override void OnSourceInitialized(EventArgs e)
        {
            base.OnSourceInitialized(e);
            _tray = new WinForms.NotifyIcon
            {
                Icon = BuildIcon(System.Drawing.Color.Gray),
                Visible = true,
                Text = "HKU VPN",
            };
            var menu = new WinForms.ContextMenuStrip();
            menu.Items.Add("Show window", null, (s, ev) => ShowFromTray());
            menu.Items.Add(new WinForms.ToolStripSeparator());
            menu.Items.Add("Exit (VPN keeps running)", null, (s, ev) =>
            {
                _realExit = true;
                _tray.Visible = false;
                Close();
            });
            _tray.ContextMenuStrip = menu;
            _tray.DoubleClick += (s, ev) => ShowFromTray();
        }

        private void ShowFromTray()
        {
            Show();
            WindowState = WindowState.Normal;
            Activate();
        }

        private System.Drawing.Icon _icoGreen, _icoOrange, _icoRed, _icoGray;

        private System.Drawing.Icon BuildIcon(System.Drawing.Color c)
        {
            using (var bmp = new System.Drawing.Bitmap(16, 16))
            {
                using (var g = System.Drawing.Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                    using (var b = new System.Drawing.SolidBrush(c))
                        g.FillEllipse(b, 3, 3, 10, 10);
                    using (var p = new System.Drawing.Pen(System.Drawing.Color.White, 1f))
                        g.DrawEllipse(p, 3, 3, 10, 10);
                }
                return System.Drawing.Icon.FromHandle(bmp.GetHicon());
            }
        }

        private void UpdateTray()
        {
            if (_tray == null) return;
            if (_icoGreen == null)
            {
                _icoGray   = BuildIcon(System.Drawing.Color.Gray);
                _icoGreen  = BuildIcon(System.Drawing.Color.ForestGreen);
                _icoOrange = BuildIcon(System.Drawing.Color.DarkOrange);
                _icoRed    = BuildIcon(System.Drawing.Color.Firebrick);
            }
            switch (_state)
            {
                case AppState.Connecting:
                    _tray.Icon = _icoOrange; _tray.Text = "HKU VPN: connecting"; break;
                case AppState.Connected:
                    bool fresh = HeartbeatFresh();
                    _tray.Icon = fresh ? _icoGreen : _icoRed;
                    _tray.Text = fresh ? "HKU VPN: connected" : "HKU VPN: worker unresponsive";
                    break;
                default:
                    _tray.Icon = _icoGray; _tray.Text = "HKU VPN: disconnected"; break;
            }
        }

        protected override void OnClosing(CancelEventArgs e)
        {
            if (!_realExit && ChkTray.IsChecked == true)
            {
                e.Cancel = true;
                Hide();
                return;
            }
            if (_tray != null) _tray.Visible = false;
            base.OnClosing(e);
        }
    }
}
