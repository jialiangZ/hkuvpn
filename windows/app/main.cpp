// HKUVPN.exe - RmlUi desktop frontend for the HKU campus VPN.
//
// Pure frontend: it drives the hidden elevated PowerShell worker
// (windows/bin/hkuvpn.ps1 --Worker) through the marker-file protocol in
// %TEMP%\hkuvpn, exactly like the previous native Win32 frontend.
// UI: RmlUi (RML/RCSS in ui/), Win32 + OpenGL2 backend, statically linked.

#include <windows.h>
#include <shellapi.h>
#include <commctrl.h>
#include <dwmapi.h>
#include <cstdio>
#include <cstdarg>
#include <string>
#include <vector>

#include <RmlUi/Core.h>
#include <RmlUi/Core/Elements/ElementFormControlInput.h>
#include "RmlUi_Backend.h"

// ---------------------------------------------------------------- utils

static std::wstring JoinPath(const std::wstring& a, const std::wstring& b) {
    return a.back() == L'\\' ? a + b : a + L"\\" + b;
}
static bool FileExistsW(const std::wstring& p) {
    return GetFileAttributesW(p.c_str()) != INVALID_FILE_ATTRIBUTES;
}
static bool ReadAllTextW(const std::wstring& path, std::wstring& out) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return false;
    std::string raw;
    char buf[8192]; DWORD n;
    while (ReadFile(h, buf, sizeof(buf), &n, NULL) && n) raw.append(buf, n);
    CloseHandle(h);
    int wl = MultiByteToWideChar(CP_UTF8, 0, raw.c_str(), (int)raw.size(), NULL, 0);
    if (!wl) { out.clear(); return true; }
    out.resize(wl);
    MultiByteToWideChar(CP_UTF8, 0, raw.c_str(), (int)raw.size(), &out[0], wl);
    return true;
}
static std::vector<std::wstring> ReadLinesW(const std::wstring& path) {
    std::wstring all; std::vector<std::wstring> v;
    if (!ReadAllTextW(path, all)) return v;
    size_t start = 0;
    while (start < all.size()) {
        size_t e = all.find(L'\n', start);
        if (e == std::wstring::npos) e = all.size();
        std::wstring l = all.substr(start, e - start);
        if (!l.empty() && l.back() == L'\r') l.pop_back();
        v.push_back(l);
        start = e + 1;
    }
    return v;
}
static bool WriteAllTextW(const std::wstring& path, const std::wstring& text) {
    int nb = WideCharToMultiByte(CP_UTF8, 0, text.c_str(), (int)text.size(), NULL, 0, NULL, NULL);
    std::string raw(nb, 0);
    WideCharToMultiByte(CP_UTF8, 0, text.c_str(), (int)text.size(), &raw[0], nb, NULL, NULL);
    HANDLE h = CreateFileW(path.c_str(), GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return false;
    DWORD n; WriteFile(h, raw.data(), (DWORD)raw.size(), &n, NULL);
    CloseHandle(h);
    return true;
}
static std::wstring Fmt(const wchar_t* fmt, ...) {
    wchar_t b[512];
    va_list ap; va_start(ap, fmt);
    _vsnwprintf(b, 511, fmt, ap);
    va_end(ap); b[511] = 0;
    return b;
}
static std::wstring ExeDir() {
    wchar_t b[MAX_PATH];
    GetModuleFileNameW(NULL, b, MAX_PATH);
    std::wstring p(b);
    return p.substr(0, p.find_last_of(L"\\/"));
}
static std::wstring HomeDir() {
    wchar_t b[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"USERPROFILE", b, MAX_PATH);
    return n ? std::wstring(b) : ExeDir();
}
static std::string Utf8(const std::wstring& w) {
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, NULL, 0, NULL, NULL);
    std::string s(n - 1, 0);
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, &s[0], n, NULL, NULL);
    return s;
}

// ---------------------------------------------------------------- state

enum App_State { APP_IDLE, APP_CONNECTING, APP_CONNECTED };

struct Paths {
    std::wstring base, markers, log, state, hb, pids, response, stop;
};
static Paths P;

static App_State g_state = APP_IDLE;
static int  g_seen = 0;
static bool g_retry = false;
static bool g_disconnecting = false;
static ULONGLONG g_disconnectStart = 0;
static ULONGLONG g_connectedTick = 0;
static long long g_logPos = -1;
static std::wstring g_launcher, g_account = L"-";
static std::wstring g_subOverride;

static HINSTANCE g_hInst = NULL;
static HWND g_hwnd = NULL;
static HICON gIcoGray, gIcoGreen, gIcoOrange, gIcoRed;
static NOTIFYICONDATAW g_nid = {};

static Rml::Context* g_ctx = nullptr;
static Rml::ElementDocument* g_doc = nullptr;
static bool g_mfaVisible = false;

class FileLog : public Rml::Log {
public:
    static void Write(const char* msg) {
        HANDLE h = CreateFileA("C:\\Users\\Pineapple\\AppData\\Local\\Temp\\hkuvpn\\rmlui.log",
            GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
            OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (h == INVALID_HANDLE_VALUE) return;
        SetFilePointer(h, 0, NULL, FILE_END);
        DWORD n; WriteFile(h, msg, (DWORD)strlen(msg), &n, NULL);
        WriteFile(h, "\r\n", 2, &n, NULL);
        CloseHandle(h);
    }
};
class LogInterface : public Rml::SystemInterface {
public:
    Rml::SystemInterface* base;
    double GetElapsedTime() override { return base->GetElapsedTime(); }
    bool LogMessage(Rml::Log::Type type, const Rml::String& message) override {
        FileLog::Write(message.c_str());
        return true;
    }
};

static Rml::Element* El(const char* id) { return g_doc->GetElementById(id); }
static void SetText(const char* id, const std::wstring& t) {
    if (Rml::Element* e = El(id)) e->SetInnerRML(Utf8(t));
}

// ---------------------------------------------------------------- protocol

static int WorkerPid() {
    for (auto& l : ReadLinesW(P.pids)) {
        if (l.rfind(L"WORKER=", 0) == 0) return _wtoi(l.c_str() + 7);
    }
    return 0;
}
static bool WorkerAlive() {
    int pid = WorkerPid();
    if (!pid) return false;
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h) return false;
    DWORD code = 0;
    GetExitCodeProcess(h, &code);
    CloseHandle(h);
    return code == STILL_ACTIVE;
}
static bool HeartbeatFresh() {
    FILETIME ft;
    WIN32_FILE_ATTRIBUTE_DATA d;
    if (!GetFileAttributesExW(P.hb.c_str(), GetFileExInfoStandard, &d)) return false;
    ft = d.ftLastWriteTime;
    FILETIME now;
    GetSystemTimeAsFileTime(&now);
    ULARGE_INTEGER a, b;
    a.LowPart = ft.dwLowDateTime;  a.HighPart = ft.dwHighDateTime;
    b.LowPart = now.dwLowDateTime; b.HighPart = now.dwHighDateTime;
    return (b.QuadPart - a.QuadPart) < 150000000ULL;   // 15s
}
static std::wstring StateValue(const wchar_t* key) {
    std::wstring k = std::wstring(key) + L"=";
    for (auto& l : ReadLinesW(P.state))
        if (l.rfind(k, 0) == 0) return l.substr(k.size());
    return L"";
}
static int LearnedCount() {
    int n = 0;
    for (auto& l : ReadLinesW(P.state))
        if (l.rfind(L"ROUTE_", 0) == 0) n++;
    return n;
}
static void FindLauncherAndAccount() {
    std::vector<std::wstring> roots;
    std::wstring dir = ExeDir();
    for (int i = 0; i < 6; i++) {
        std::wstring c = JoinPath(dir, L"bin\\hkuvpn.ps1");
        if (FileExistsW(c)) { g_launcher = c; break; }
        size_t p = dir.find_last_of(L"\\/");
        if (p == std::wstring::npos) break;
        dir = dir.substr(0, p);
    }
    if (g_launcher.empty()) {
        std::wstring c = JoinPath(HomeDir(), L"hkuvpn\\windows\\bin\\hkuvpn.ps1");
        if (FileExistsW(c)) g_launcher = c;
    }
    for (auto& l : ReadLinesW(JoinPath(JoinPath(HomeDir(), L".vpn"), L"hku.env")))
        if (l.rfind(L"HKU_USER=", 0) == 0) { g_account = l.substr(9); break; }
}

// ---------------------------------------------------------------- tray

static HICON MakeDotIcon(COLORREF c) {
    const int S = 32;
    HDC dc = GetDC(NULL);
    HDC mdc = CreateCompatibleDC(dc);
    BITMAPINFO bi = {};
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = S;
    bi.bmiHeader.biHeight = -S;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    void* bits = NULL;
    HBITMAP bmp = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
    HBITMAP ob = (HBITMAP)SelectObject(mdc, bmp);
    HBRUSH br = CreateSolidBrush(c);
    HPEN np = CreatePen(PS_NULL, 0, 0);
    HPEN op = (HPEN)SelectObject(mdc, np);
    HBRUSH obr = (HBRUSH)SelectObject(mdc, br);
    Ellipse(mdc, 2, 2, S - 2, S - 2);
    SelectObject(mdc, op); SelectObject(mdc, obr);
    DeleteObject(np); DeleteObject(br);
    HBITMAP mask = CreateBitmap(S, S, 1, 1, NULL);
    ICONINFO ii = { TRUE, 0, 0, mask, bmp };
    HICON ico = CreateIconIndirect(&ii);
    DeleteObject(bmp); DeleteObject(mask);
    SelectObject(mdc, ob);
    DeleteDC(mdc);
    ReleaseDC(NULL, dc);
    return ico;
}
static HICON StateIcon() {
    switch (g_state) {
        case APP_CONNECTED:  return (WorkerAlive() && HeartbeatFresh())
                                    ? gIcoGreen : gIcoRed;
        case APP_CONNECTING: return gIcoOrange;
        default:             return gIcoGray;
    }
}
static void UpdateTray() {
    if (!g_nid.hWnd) return;
    const wchar_t* tip = L"HKU VPN: disconnected";
    if (g_state == APP_CONNECTED)
        tip = (WorkerAlive() && HeartbeatFresh())
            ? L"HKU VPN: connected" : L"HKU VPN: worker unresponsive";
    else if (g_state == APP_CONNECTING) tip = L"HKU VPN: connecting";
    lstrcpynW(g_nid.szTip, tip, 128);
    g_nid.hIcon = StateIcon();
    Shell_NotifyIconW(NIM_MODIFY, &g_nid);
}
static void ShowFromTray() {
    ShowWindow(g_hwnd, SW_SHOW);
    ShowWindow(g_hwnd, SW_RESTORE);
    SetForegroundWindow(g_hwnd);
}

// ------------------------------------------------------------- ui update

static const char* StateDotColor() {
    if (g_disconnecting) return "#9a6700";
    switch (g_state) {
        case APP_CONNECTED:  return (WorkerAlive() && HeartbeatFresh()) ? "#1a7f37" : "#cf222e";
        case APP_CONNECTING: return "#9a6700";
        default:             return "#95999e";
    }
}
static void SetBtnEnabled(const char* id, bool on) {
    Rml::Element* e = El(id);
    if (!e) return;
    if (on) e->SetClass("disabled", false);
    else    e->SetClass("disabled", true);
}
static bool BtnEnabled(const char* id) {
    Rml::Element* e = El(id);
    return e && !e->IsClassSet("disabled");
}

static void UpdateHeader() {
    std::wstring title, sub;
    bool accentSub = false;
    if (g_disconnecting) title = L"Disconnecting...";
    else switch (g_state) {
        case APP_CONNECTED:
            title = (WorkerAlive() && HeartbeatFresh())
                ? L"Connected" : L"Worker unresponsive"; break;
        case APP_CONNECTING: title = L"Connecting..."; break;
        default:             title = L"Disconnected"; break;
    }
    if (!g_subOverride.empty()) {
        sub = g_subOverride; accentSub = true;
    } else switch (g_state) {
        case APP_CONNECTED:
            sub = (WorkerAlive() && HeartbeatFresh())
                ? L"Tunnel is up - traffic via 127.0.0.1:1080/1088 goes through HKU"
                : L"The worker loop stopped - use Disconnect to recover"; break;
        case APP_CONNECTING: sub = L"Requesting elevation / bringing the tunnel up"; break;
        default:             sub = L"Tunnel is down"; break;
    }
    SetText("status-title", title);
    SetText("status-sub", sub);
    if (Rml::Element* d = El("status-dot")) d->SetProperty("background", StateDotColor());
    if (Rml::Element* s = El("status-sub"))
        s->SetProperty("color", accentSub ? "#0a6cff" : "#697078");
}

static void SetState(App_State s) {
    g_state = s;
    g_subOverride.clear();
    SetBtnEnabled("btn-connect", s == APP_IDLE);
    SetBtnEnabled("btn-disconnect", s != APP_IDLE);
    SetText("btn-disconnect", s == APP_CONNECTING ? L"Cancel" : L"Disconnect");
    if (s == APP_CONNECTED) {
        g_connectedTick = g_connectedTick ? g_connectedTick : GetTickCount64();
        std::wstring ip = StateValue(L"IP4");
        SetText("val-vpn", ip.empty() ? L"-" : ip);
    } else {
        g_connectedTick = 0;
        SetText("val-vpn", L"-");
        SetText("val-duration", L"-");
        SetText("val-routes", L"-");
    }
    UpdateHeader();
    UpdateTray();
}

// ---------------------------------------------------------------- mfa

static void CloseMfa() {
    if (!g_mfaVisible) return;
    g_mfaVisible = false;
    if (Rml::Element* o = El("mfa-overlay")) o->SetClass("visible", false);
}
static void OpenMfa(bool rejected) {
    if (Rml::Element* o = El("mfa-overlay")) o->SetClass("visible", true);
    g_mfaVisible = true;
    SetText("mfa-note", rejected
        ? L"The previous code was REJECTED - enter the one showing NOW." : L"");
    if (auto* in = static_cast<Rml::ElementFormControlInput*>(El("mfa-code"))) {
        in->SetValue("");
        in->Focus();
    }
}
static void SubmitMfa() {
    auto* in = static_cast<Rml::ElementFormControlInput*>(El("mfa-code"));
    if (!in) return;
    std::string v = in->GetValue();
    if (v.size() != 6) {
        SetText("mfa-note", L"The code must be exactly 6 digits.");
        return;
    }
    if (WriteAllTextW(P.response, std::wstring(v.begin(), v.end()))) {
        g_subOverride = L"MFA code accepted - establishing tunnel (DTLS handshake + route learning can take ~30s)...";
        CloseMfa();
        UpdateHeader();
    } else {
        SetText("mfa-note", L"Could not deliver the code.");
    }
}
static void CancelMfa() {
    if (g_state != APP_CONNECTED) {
        WriteAllTextW(P.stop, L"stop");
        SetState(APP_IDLE);
    }
    CloseMfa();
}

// ---------------------------------------------------------------- actions

static std::wstring GetInputValue(const char* id) {
    auto* in = static_cast<Rml::ElementFormControlInput*>(El(id));
    if (!in) return L"";
    std::string v = in->GetValue();
    int n = MultiByteToWideChar(CP_UTF8, 0, v.c_str(), (int)v.size(), NULL, 0);
    std::wstring w(n, 0);
    MultiByteToWideChar(CP_UTF8, 0, v.c_str(), (int)v.size(), &w[0], n);
    return w;
}
static void SetInputValue(const char* id, const std::wstring& v) {
    auto* in = static_cast<Rml::ElementFormControlInput*>(El(id));
    if (in) in->SetValue(Utf8(v));
}

static bool PersistCredentials() {
    std::wstring account = GetInputValue("account"), pin = GetInputValue("pin");
    auto trim = [](std::wstring& s) {
        while (!s.empty() && (s.front() == L' ' || s.front() == L'\t')) s.erase(0, 1);
        while (!s.empty() && (s.back() == L' ' || s.back() == L'\t' ||
                              s.back() == L'\r' || s.back() == L'\n')) s.pop_back();
    };
    trim(account); trim(pin);
    if (account.empty()) {
        MessageBoxW(g_hwnd, L"Enter your HKU account first (e.g. u1234567@connect.hku.hk).",
                    L"HKU VPN", MB_ICONWARNING);
        return false;
    }
    std::wstring vpnDir = JoinPath(HomeDir(), L".vpn");
    CreateDirectoryW(vpnDir.c_str(), NULL);

    std::wstring envPath = JoinPath(vpnDir, L"hku.env");
    std::vector<std::wstring> lines = ReadLinesW(envPath);
    std::wstring body;
    bool found = false, first = true;
    for (auto& l : lines) {
        if (l.rfind(L"HKU_USER=", 0) == 0) {
            body += L"HKU_USER=" + account + L"\r\n";
            found = true;
        } else {
            if (!first) body += L"\r\n";
            body += l + L"\r\n";
        }
        first = false;
    }
    if (!found) {
        if (!body.empty() && body.back() != L'\n') body += L"\r\n";
        body = L"HKU_USER=" + account + L"\r\n" + body;
    }
    WriteAllTextW(envPath, body);
    if (!pin.empty()) WriteAllTextW(JoinPath(vpnDir, L"hku.pass"), pin);
    g_account = account;
    return true;
}

static void DoConnect() {
    if (!PersistCredentials()) return;
    if (WorkerAlive()) { SetState(APP_CONNECTED); return; }
    if (g_launcher.empty()) {
        MessageBoxW(g_hwnd,
            L"hkuvpn.ps1 was not found. Place HKUVPN.exe inside the hkuvpn "
            L"repo (windows\\app\\publish) or clone the repo to "
            L"%USERPROFILE%\\hkuvpn.",
            L"HKU VPN", MB_ICONERROR);
        return;
    }
    std::wstring args = L"-NoProfile -ExecutionPolicy Bypass -File \"" +
                        g_launcher + L"\" \"--Worker\"";
    HINSTANCE hi = ShellExecuteW(g_hwnd, L"runas", L"powershell.exe",
                                 args.c_str(), NULL, SW_HIDE);
    if ((INT_PTR)hi > 32) {
        g_seen = 0;
        g_retry = false;
        SetState(APP_CONNECTING);
        if (IsIconic(g_hwnd)) ShowWindow(g_hwnd, SW_RESTORE);
        SetForegroundWindow(g_hwnd);
        if (GetForegroundWindow() != g_hwnd) {
            ShowWindow(g_hwnd, SW_MINIMIZE);
            ShowWindow(g_hwnd, SW_RESTORE);
            SetForegroundWindow(g_hwnd);
        }
    } else if ((INT_PTR)hi == SE_ERR_ACCESSDENIED) {
        MessageBoxW(g_hwnd, L"Elevation was declined.", L"HKU VPN", MB_ICONWARNING);
    } else {
        MessageBoxW(g_hwnd, Fmt(L"Could not start the worker (ShellExecute=%d).",
                               (int)(INT_PTR)hi).c_str(), L"HKU VPN", MB_ICONERROR);
    }
}

static void DoDisconnect() {
    if (g_state == APP_CONNECTING) {
        WriteAllTextW(P.stop, L"stop");
        SetState(APP_IDLE);
        return;
    }
    if (g_state != APP_CONNECTED) return;
    g_disconnecting = true;
    g_disconnectStart = GetTickCount64();
    g_subOverride = L"Disconnecting - waiting for the worker to clean up...";
    SetBtnEnabled("btn-connect", false);
    SetBtnEnabled("btn-disconnect", false);
    UpdateHeader();
    std::wstring args = L"-NoProfile -ExecutionPolicy Bypass -File \"" +
                        g_launcher + L"\" \"--stop\"";
    ShellExecuteW(g_hwnd, NULL, L"powershell.exe", args.c_str(), NULL, SW_HIDE);
}

static void ClearLog() {
    SetText("log-content", L"");
    // Seek the cursor to the CURRENT end: -1 would re-read the last 4KB.
    g_logPos = 0;
    HANDLE lh = CreateFileW(P.log.c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (lh != INVALID_HANDLE_VALUE) {
        LARGE_INTEGER len;
        if (GetFileSizeEx(lh, &len)) g_logPos = len.QuadPart;
        CloseHandle(lh);
    }
}

// ---------------------------------------------------------------- events

class UiEvents : public Rml::EventListener {
public:
    void ProcessEvent(Rml::Event& ev) override {
        Rml::String id = ev.GetTargetElement()->GetId();
        if (ev.GetType() == "click") {
            if (id == "btn-connect" && BtnEnabled("btn-connect")) DoConnect();
            else if (id == "btn-disconnect" && BtnEnabled("btn-disconnect")) DoDisconnect();
            else if (id == "btn-clear") ClearLog();
            else if (id == "btn-mfa") SubmitMfa();
        } else if (ev.GetType() == "keydown") {
            int key = ev.GetParameter<int>("key_identifier", 0);
            if (id == "mfa-code") {
                if (key == Rml::Input::KI_RETURN) { SubmitMfa(); ev.StopPropagation(); }
                else if (key == Rml::Input::KI_ESCAPE) { CancelMfa(); ev.StopPropagation(); }
            }
        } else if (ev.GetType() == "submit") {
            if (id == "mfa-code") SubmitMfa();
        }
    }
};
static UiEvents g_events;

// ---------------------------------------------------------------- tick

static void Tick() {
    auto lines = ReadLinesW(P.markers);
    if ((int)lines.size() > g_seen) {
        for (int i = g_seen; i < (int)lines.size(); i++) {
            const std::wstring& l = lines[i];
            if (l.find(L"HKUVPN_CONNECTED") != std::wstring::npos) {
                CloseMfa();
                g_connectedTick = GetTickCount64();
                SetState(APP_CONNECTED);
            } else if (l.find(L"HKUVPN_MFA_RESPONSE_REQUIRED") != std::wstring::npos &&
                       g_state == APP_CONNECTING) {
                OpenMfa(g_retry);
                g_retry = false;
            } else if (l.find(L"HKUVPN_MFA_RETRY") != std::wstring::npos) {
                g_retry = true;
            } else if (l.find(L"HKUVPN_EXITED") != std::wstring::npos) {
                if (g_state == APP_CONNECTING) {
                    CloseMfa();
                    SetState(APP_IDLE);
                }
            }
        }
        g_seen = (int)lines.size();
    }

    if (g_state == APP_CONNECTED) {
        if (WorkerAlive()) {
            std::wstring ip = StateValue(L"IP4");
            if (!ip.empty()) SetText("val-vpn", ip);
            if (g_connectedTick) {
                ULONGLONG el = (GetTickCount64() - g_connectedTick) / 1000;
                SetText("val-duration", Fmt(L"%02d:%02d:%02d",
                    (int)(el / 3600), (int)((el / 60) % 60), (int)(el % 60)));
            }
            SetText("val-routes", Fmt(L"%d learned route%s, heartbeat %s",
                LearnedCount(), LearnedCount() == 1 ? L"" : L"s",
                HeartbeatFresh() ? L"OK" : L"STALE"));
        } else {
            SetState(APP_IDLE);
        }
    }

    if (g_state == APP_CONNECTING && !WorkerAlive()) {
        std::wstring all;
        if (ReadAllTextW(P.markers, all) &&
            all.find(L"HKUVPN_EXITED") != std::wstring::npos) {
            SetState(APP_IDLE);
        }
    }

    // Reconciliation against a deleted/rewritten markers file.
    if (g_state == APP_CONNECTING && WorkerAlive()) {
        std::wstring all2;
        if (ReadAllTextW(P.markers, all2) &&
            all2.find(L"HKUVPN_CONNECTED") != std::wstring::npos) {
            int nl = 1;
            for (wchar_t c : all2) if (c == L'\n') nl++;
            g_seen = nl;
            g_connectedTick = GetTickCount64();
            CloseMfa();
            SetState(APP_CONNECTED);
        }
    }

    if (g_disconnecting) {
        if (!WorkerAlive()) {
            g_disconnecting = false;
            SetState(APP_IDLE);
        } else if (GetTickCount64() - g_disconnectStart > 30000) {
            g_disconnecting = false;
            SetState(APP_CONNECTED);
            g_subOverride = L"Disconnect timed out - the worker is still running; retry.";
        }
    }
    UpdateHeader();
}

// ---------------------------------------------------------------- log tail

static void TailLog() {
    HANDLE h = CreateFileW(P.log.c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    LARGE_INTEGER len;
    if (!GetFileSizeEx(h, &len)) { CloseHandle(h); return; }
    if (g_logPos < 0) g_logPos = len.QuadPart > 4096 ? len.QuadPart - 4096 : 0;
    if (len.QuadPart < g_logPos) g_logPos = 0;
    if (len.QuadPart > g_logPos) {
        LARGE_INTEGER mv = { 0 }; mv.QuadPart = g_logPos;
        SetFilePointerEx(h, mv, NULL, FILE_BEGIN);
        std::string raw;
        char buf[16384];
        DWORD n = 0;
        while (ReadFile(h, buf, sizeof(buf), &n, NULL) && n > 0) {
            raw.append(buf, n);
            if (raw.size() > 65536) break;
        }
        g_logPos += (long long)raw.size();
        CloseHandle(h);
        if (raw.empty()) return;
        // openconnect writes plain ASCII; strip control characters and
        // treat any of \r, \n, \r\n as a line break (progress output uses
        // bare \r to redraw a line - each redraw becomes its own line).
        std::string clean;
        clean.reserve(raw.size());
        for (size_t i = 0; i < raw.size(); i++) {
            char c = raw[i];
            if (c == '\r') {
                if (i + 1 < raw.size() && raw[i + 1] == '\n') i++;   // \r\n
                clean.push_back('\n');
            } else if (c == '\n' || (c >= 32 && c < 127)) {
                clean.push_back(c);
            }
        }
        Rml::Element* content = El("log-content");
        Rml::Element* view = El("log-view");
        if (!content || !view) return;
        // Append each log line as its own block <div> - RmlUi treats bare
        // text + <br/> inconsistently for preformatted console output.
        std::string cur = content->GetInnerRML();
        if (cur.size() > 160000) cur = cur.substr(cur.size() - 80000);
        std::string line;
        std::string html;
        auto flush = [&]() {
            if (line.empty()) { html += "<div>&nbsp;</div>"; return; }
            std::string esc;
            esc.reserve(line.size());
            for (char c : line) {
                if (c == '&') esc += "&amp;";
                else if (c == '<') esc += "&lt;";
                else if (c == '>') esc += "&gt;";
                else esc.push_back(c);
            }
            html += "<div>" + esc + "</div>";
            line.clear();
        };
        for (char c : clean) {
            if (c == '\n') flush();
            else line.push_back(c);
        }
        if (!line.empty()) flush();
        content->SetInnerRML(cur + html);
        view->SetScrollTop(view->GetScrollHeight());
        return;
    }
    CloseHandle(h);
}

// ---------------------------------------------------------------- winmain

static bool TrayProc(MSG& msg) {
    if (msg.message == WM_APP + 1 && msg.hwnd == g_hwnd) {
        UINT ev = LOWORD(msg.lParam);
        if (ev == WM_LBUTTONUP || ev == NIN_SELECT || ev == NIN_KEYSELECT) {
            ShowFromTray();
            return true;
        }
        if (ev == WM_RBUTTONUP) {
            POINT pt; GetCursorPos(&pt);
            HMENU menu = CreatePopupMenu();
            AppendMenuW(menu, MF_STRING, 1, L"Open HKU VPN");
            AppendMenuW(menu, MF_STRING, 2, L"Exit");
            SetForegroundWindow(g_hwnd);
            int cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY,
                                     pt.x, pt.y, 0, g_hwnd, NULL);
            DestroyMenu(menu);
            if (cmd == 1) ShowFromTray();
            if (cmd == 2) PostQuitMessage(0);
            return true;
        }
    }
    return false;
}

int WINAPI wWinMain(HINSTANCE hInst, HINSTANCE, LPWSTR, int nCmd) {
    (void)nCmd;
    g_hInst = hInst;
    InitCommonControls();
    // DPI awareness comes from the manifest (PerMonitorV2); do NOT call
    // SetProcessDPIAware here - it would downgrade the process to
    // system-DPI-aware and the backend would misread the window DPI.

    wchar_t tmp[MAX_PATH + 1] = {};
    GetTempPathW(MAX_PATH, tmp);
    P.base     = JoinPath(tmp, L"hkuvpn");
    P.markers  = JoinPath(P.base, L"markers.log");
    P.log      = JoinPath(P.base, L"openconnect.log");
    P.state    = JoinPath(P.base, L"vpnc-state.txt");
    P.hb       = JoinPath(P.base, L"hb.log");
    P.pids     = JoinPath(P.base, L"pids.txt");
    P.response = JoinPath(P.base, L"response.txt");
    P.stop     = JoinPath(P.base, L"stop.flag");
    FindLauncherAndAccount();

    gIcoGray   = MakeDotIcon(RGB(150, 153, 158));
    gIcoGreen  = MakeDotIcon(RGB(26, 127, 55));
    gIcoOrange = MakeDotIcon(RGB(154, 103, 0));
    gIcoRed    = MakeDotIcon(RGB(207, 34, 46));

    if (!Backend::Initialize("HKU VPN", 860, 640, true)) return 1;
    g_hwnd = FindWindowW(L"HKU VPN", NULL);
    if (!g_hwnd) {
        // Window class name == window title in the stock backend.
        g_hwnd = GetForegroundWindow();
    }

    // Application icon on the window itself.
    HICON appIco = (HICON)LoadImageW(hInst, MAKEINTRESOURCEW(1),
                                     IMAGE_ICON, 0, 0, LR_DEFAULTSIZE);
    SendMessageW(g_hwnd, WM_SETICON, ICON_BIG, (LPARAM)appIco);
    SendMessageW(g_hwnd, WM_SETICON, ICON_SMALL, (LPARAM)appIco);
    BOOL dark = FALSE;
    DwmSetWindowAttribute(g_hwnd, 20, &dark, sizeof(dark));

    Rml::SetSystemInterface(Backend::GetSystemInterface());
    Rml::SetRenderInterface(Backend::GetRenderInterface());
    static LogInterface logIf;
    logIf.base = Backend::GetSystemInterface();
    Rml::SetSystemInterface(&logIf);
    Rml::Initialise();

    g_ctx = Rml::CreateContext("main", Rml::Vector2i(860, 640));
    if (!g_ctx) return 1;

    // Fonts from the Windows font directory.
    std::wstring fonts = L"C:\\Windows\\Fonts\\";
    Rml::LoadFontFace(Utf8(fonts + L"segoeui.ttf").c_str());
    Rml::LoadFontFace(Utf8(fonts + L"segoeuib.ttf").c_str());
    Rml::LoadFontFace(Utf8(fonts + L"CascadiaMono.ttf").c_str());
    Rml::LoadFontFace(Utf8(fonts + L"consola.ttf").c_str());

    g_doc = g_ctx->LoadDocument(Utf8(JoinPath(ExeDir(), L"ui\\app.rml")).c_str());
    if (!g_doc) {
        MessageBoxW(g_hwnd, L"Could not load ui\\app.rml - keep the ui folder next to HKUVPN.exe.",
                    L"HKU VPN", MB_ICONERROR);
        return 1;
    }
    g_doc->Show();

    // Event wiring.
    for (const char* id : { "btn-connect", "btn-disconnect", "btn-clear", "btn-mfa" })
        El(id)->AddEventListener("click", &g_events);
    El("mfa-code")->AddEventListener("keydown", &g_events);

    // Prefill credentials.
    SetInputValue("account", g_account == L"-" ? L"" : g_account);
    {
        std::wstring pin;
        if (ReadAllTextW(JoinPath(JoinPath(HomeDir(), L".vpn"), L"hku.pass"), pin)) {
            while (!pin.empty() && (pin.back() == L'\r' || pin.back() == L'\n' ||
                                    pin.back() == L' ')) pin.pop_back();
            SetInputValue("pin", pin);
        }
    }

    // Tray icon.
    g_nid.cbSize = sizeof(g_nid);
    g_nid.hWnd = g_hwnd;
    g_nid.uID = 1;
    g_nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    g_nid.uCallbackMessage = WM_APP + 1;
    g_nid.hIcon = gIcoGray;
    lstrcpynW(g_nid.szTip, L"HKU VPN: disconnected", 128);
    Shell_NotifyIconW(NIM_ADD, &g_nid);

    // Boot state: adopt a running session.
    if (WorkerAlive()) g_seen = 0;
    SetState(WorkerAlive() ? APP_CONNECTED : APP_IDLE);
    {
        std::wstring all;
        if ((g_state == APP_CONNECTING || WorkerAlive()) && ReadAllTextW(P.markers, all)) {
            size_t need = all.rfind(L"HKUVPN_MFA_RESPONSE_REQUIRED");
            size_t conn = all.rfind(L"HKUVPN_CONNECTED");
            if (need != std::wstring::npos && (conn == std::wstring::npos || need > conn))
                OpenMfa(false);
        }
    }

    ULONGLONG lastTick = 0, lastLog = 0;
    bool running = true;
    while (running) {
        running = Backend::ProcessEvents(g_ctx);

        // Pump tray messages (the backend only forwards its own handlers).
        MSG msg;
        while (PeekMessage(&msg, NULL, WM_APP, WM_APP + 10, PM_REMOVE)) {
            TrayProc(msg);
        }
        if (msg.message == WM_QUIT) running = false;

        ULONGLONG now = GetTickCount64();
        if (now - lastTick >= 400) { lastTick = now; Tick(); }
        if (now - lastLog >= 600) { lastLog = now; TailLog(); }

        g_ctx->Update();
        Backend::BeginFrame();
        g_ctx->Render();
        Backend::PresentFrame();
        Sleep(8);
    }

    Shell_NotifyIconW(NIM_DELETE, &g_nid);
    g_doc->Close();
    Rml::Shutdown();
    Backend::Shutdown();
    return 0;
}
