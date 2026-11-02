// hkuvpn native desktop app (Win32, C++, no runtime dependencies).
//
// A frontend only: it drives the same hidden elevated worker as
// 'hkuvpn.ps1 -t' (markers.log state machine, response.txt MFA delivery,
// stop.flag disconnect) and displays a live tail of openconnect.log.
// Build: see build.sh (llvm-mingw / x86_64-w64-mingw32-g++).

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <commctrl.h>
#include <shellapi.h>
#include <dwmapi.h>
#include <shlobj.h>
#include <string>
#include <vector>
#include <cstdarg>
#include <cstdio>
#include <cmath>

#pragma comment(lib, "comctl32.lib")

// ---------------------------------------------------------------- palette
// Light theme (Windows 11 style): light gray canvas, white cards,
// blue accent, GitHub-light semantic colors.

static const COLORREF C_BG     = RGB(243, 243, 243);
static const COLORREF C_CARD   = RGB(255, 255, 255);
static const COLORREF C_BORDER = RGB(226, 227, 232);
static const COLORREF C_LOGBG  = RGB(255, 255, 255);
static const COLORREF C_TEXT   = RGB(31, 35, 40);
static const COLORREF C_MUTED  = RGB(110, 119, 129);
static const COLORREF C_ACCENT = RGB(10, 108, 255);
static const COLORREF C_GREEN  = RGB(26, 127, 55);
static const COLORREF C_ORANGE = RGB(154, 103, 0);
static const COLORREF C_RED    = RGB(207, 34, 46);

static HBRUSH gBrBg, gBrCard, gBrLogBg;

// ---------------------------------------------------------------- ids

enum {
    IDC_PANEL_SESSION = 500, IDC_PANEL_MFA = 501, IDC_PANEL_LOG = 502,
    ID_CAP_ACCOUNT = 100, ID_CAP_VPN, ID_CAP_DURATION, ID_CAP_PROXY, ID_CAP_ROUTES,
    ID_VAL_ACCOUNT = 120, ID_VAL_VPN, ID_VAL_DURATION, ID_VAL_PROXY, ID_VAL_ROUTES,
    ID_MFA_TITLE = 130, ID_MFA_NOTE = 131,
    IDC_ED_MFA = 200, IDC_ED_LOG = 201,
    ID_BTN_CONNECT = 300, ID_BTN_DISCONNECT, ID_BTN_MFA, ID_BTN_CLEAR,
    IDC_CHK_TRAY = 400, ID_FOOTER = 401,
};
#define WM_APP_TRAY (WM_APP + 1)

// ---------------------------------------------------------------- state

enum App_State { APP_IDLE, APP_CONNECTING, APP_CONNECTED };

struct Paths {
    std::wstring base, markers, log, state, hb, pids, response, stop;
} P;

static App_State g_state = APP_IDLE;
static int  g_seen = 0;
static bool g_retry = false;
static bool g_realExit = false;
static ULONGLONG g_connectedTick = 0;
static long long g_logPos = -1;
static std::wstring g_launcher, g_account = L"-";
static double g_scale = 1.0;

static HWND hMain, hPanelSession, hPanelMfa, hPanelLog;
static HWND hBtnConnect, hBtnDisconnect, hBtnMfa, hBtnClear;
static HWND hEdMfa, hEdLog, hChkTray;
static HWND hValAccount, hValVpn, hValDuration, hValRoutes;
static HWND hMfaNote, hFooter;

static HFONT gFTitle, gFSub, gFBody, gFMono, gFButton;
static HICON gIcoGray, gIcoGreen, gIcoOrange, gIcoRed, gIcoApp;
static NOTIFYICONDATAW g_nid = {};

static void UpdateTray();   // defined with the tray code below

// ---------------------------------------------------------------- utils

static std::wstring JoinPath(const std::wstring& a, const std::wstring& b) {
    if (a.empty() || a.back() == L'\\') return a + b;
    return a + L"\\" + b;
}

static bool FileExistsW(const std::wstring& p) {
    return GetFileAttributesW(p.c_str()) != INVALID_FILE_ATTRIBUTES;
}

static bool ReadAllTextW(const std::wstring& path, std::wstring& out) {
    out.clear();
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return false;
    char buf[8192];
    DWORD n = 0;
    std::string raw;
    while (ReadFile(h, buf, sizeof(buf), &n, NULL) && n > 0) raw.append(buf, n);
    CloseHandle(h);
    int len = MultiByteToWideChar(CP_UTF8, 0, raw.c_str(), (int)raw.size(), NULL, 0);
    out.resize(len);
    MultiByteToWideChar(CP_UTF8, 0, raw.c_str(), (int)raw.size(), &out[0], len);
    return true;
}

static std::vector<std::wstring> ReadLinesW(const std::wstring& path) {
    std::wstring t;
    if (!ReadAllTextW(path, t)) return {};
    std::vector<std::wstring> lines;
    size_t start = 0;
    for (;;) {
        size_t e = t.find(L'\n', start);
        std::wstring line = (e == std::wstring::npos)
            ? t.substr(start) : t.substr(start, e - start);
        while (!line.empty() && (line.back() == L'\r' || line.back() == L'\n'))
            line.pop_back();
        lines.push_back(line);
        if (e == std::wstring::npos) break;
        start = e + 1;
    }
    return lines;
}

static bool WriteAllTextW(const std::wstring& path, const std::wstring& text) {
    std::wstring tmp = path + L".tmp";
    HANDLE h = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, NULL,
                           CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return false;
    int len = WideCharToMultiByte(CP_UTF8, 0, text.c_str(), (int)text.size(),
                                  NULL, 0, NULL, NULL);
    std::string raw(len, 0);
    WideCharToMultiByte(CP_UTF8, 0, text.c_str(), (int)text.size(),
                        &raw[0], len, NULL, NULL);
    DWORD wrote = 0;
    BOOL ok = WriteFile(h, raw.data(), (DWORD)raw.size(), &wrote, NULL);
    CloseHandle(h);
    if (!ok) return false;
    return MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING) != 0;
}

static std::wstring Fmt(const wchar_t* fmt, ...) {
    wchar_t buf[512];
    va_list ap; va_start(ap, fmt);
    _vsnwprintf_s(buf, 512, _TRUNCATE, fmt, ap);
    va_end(ap);
    return buf;
}

static std::wstring ExeDir() {
    wchar_t buf[MAX_PATH + 1] = {};
    GetModuleFileNameW(NULL, buf, MAX_PATH);
    std::wstring d(buf);
    size_t p = d.find_last_of(L'\\');
    return (p == std::wstring::npos) ? L"." : d.substr(0, p);
}

static std::wstring HomeDir() {
    wchar_t buf[MAX_PATH + 1] = {};
    SHGetFolderPathW(NULL, CSIDL_PROFILE, NULL, 0, buf);
    return buf;
}

// ---------------------------------------------------------------- protocol

static int WorkerPid() {
    for (auto& l : ReadLinesW(P.pids)) {
        if (l.rfind(L"WORKER=", 0) == 0) {
            int n = _wtoi(l.c_str() + 7);
            if (n > 0) return n;
        }
    }
    return 0;
}

static bool WorkerAlive() {
    int pid = WorkerPid();
    if (pid <= 0) return false;
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION |
                           SYNCHRONIZE, FALSE, pid);
    if (!h) return false;
    bool alive = (WaitForSingleObject(h, 0) == WAIT_TIMEOUT);
    CloseHandle(h);
    return alive;
}

static bool HeartbeatFresh() {
    HANDLE h = CreateFileW(P.hb.c_str(), GENERIC_READ,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return false;
    FILETIME ft = {}; GetFileTime(h, NULL, NULL, &ft);
    CloseHandle(h);
    ULARGE_INTEGER u = { ft.dwLowDateTime, ft.dwHighDateTime };
    ULONGLONG now125 = GetTickCount64() * 10000ULL + 116444736000000000ULL;
    // Compare against system time instead: simpler via GetSystemTimeAsFileTime.
    FILETIME nowFt; GetSystemTimeAsFileTime(&nowFt);
    ULARGE_INTEGER nowU = { nowFt.dwLowDateTime, nowFt.dwHighDateTime };
    (void)now125;
    return (nowU.QuadPart - u.QuadPart) <= 15ULL * 10000000ULL;
}

static std::wstring StateValue(const wchar_t* key) {
    std::wstring pre(key); pre += L'=';
    for (auto& l : ReadLinesW(P.state))
        if (l.rfind(pre, 0) == 0) return l.substr(pre.size());
    return L"";
}

static int LearnedCount() {
    int n = 0;
    for (auto& l : ReadLinesW(JoinPath(JoinPath(HomeDir(), L".vpn"),
                                       L"learned-routes.txt")))
        if (!l.empty()) n++;
    return n;
}

static void FindLauncherAndAccount() {
    std::wstring exeDir = ExeDir(), home = HomeDir();
    std::wstring candidates[] = {
        JoinPath(exeDir, L"..\\bin\\hkuvpn.ps1"),
        JoinPath(exeDir, L"..\\..\\..\\bin\\hkuvpn.ps1"),
        JoinPath(JoinPath(home, L"hkuvpn"), L"windows\\bin\\hkuvpn.ps1"),
    };
    for (auto& c : candidates)
        if (FileExistsW(c)) { g_launcher = c; break; }
    for (auto& l : ReadLinesW(JoinPath(JoinPath(home, L".vpn"), L"hku.env"))) {
        if (l.rfind(L"HKU_USER=", 0) == 0) { g_account = l.substr(9); break; }
    }
}

// ---------------------------------------------------------------- theming

static LRESULT CALLBACK PanelProc(HWND, UINT, WPARAM, LPARAM);

static void RegisterPanelClass(HINSTANCE hInst) {
    WNDCLASSW wc = {};
    wc.lpfnWndProc = PanelProc;
    wc.hInstance = hInst;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = NULL;
    wc.lpszClassName = L"HkuPanel";
    RegisterClassW(&wc);
}

struct PanelStyle {
    COLORREF bg, border;
    int radius;
};

static HBRUSH BrushFor(COLORREF c) {
    return CreateSolidBrush(c);
}

// Styled flat button (owner-draw) --------------------------------------------

struct BtnStyle { COLORREF fill, border, hoverFill, text; };

static const BtnStyle gBsConnect  = { RGB(10,108,255),  RGB(9,105,218),   RGB(56,139,253),  RGB(255,255,255) };
static const BtnStyle gBsDanger   = { RGB(255,255,255), RGB(207,34,46),   RGB(255,240,240), RGB(207,34,46) };
static const BtnStyle gBsNeutral  = { RGB(245,245,245), RGB(209,213,218), RGB(233,236,239), RGB(31,35,40) };

static LRESULT CALLBACK BtnSubProc(HWND h, UINT m, WPARAM w, LPARAM l,
                                   UINT_PTR id, DWORD_PTR ref) {
    if (m == WM_MOUSEMOVE && !GetPropW(h, L"hov")) {
        SetPropW(h, L"hov", (HANDLE)1);
        InvalidateRect(h, NULL, TRUE);
        TRACKMOUSEEVENT t = { sizeof(t), TME_LEAVE, h, 0 };
        _TrackMouseEvent(&t);
    } else if (m == WM_MOUSELEAVE) {
        RemovePropW(h, L"hov");
        InvalidateRect(h, NULL, TRUE);
    }
    return DefSubclassProc(h, m, w, l);
}

static void DrawStyledButton(DRAWITEMSTRUCT* dis, const BtnStyle* st,
                             const wchar_t* text, HFONT font) {
    RECT r = dis->rcItem;
    HDC dc = dis->hDC;
    bool hover = GetPropW(dis->hwndItem, L"hov") != NULL;
    bool disabled = (dis->itemState & ODS_DISABLED) != 0;
    COLORREF fill = hover ? st->hoverFill : st->fill;
    if (disabled) fill = RGB(235, 236, 238);
    SetDCBrushColor(dc, fill);
    HPEN pen = CreatePen(PS_SOLID, 1, disabled ? RGB(70, 72, 77) : st->border);
    HBRUSH br = (HBRUSH)GetStockObject(DC_BRUSH);
    HPEN oldPen = (HPEN)SelectObject(dc, pen);
    HBRUSH oldBr = (HBRUSH)SelectObject(dc, br);
    HRGN clip = CreateRoundRectRgn(r.left, r.top, r.right + 1, r.bottom + 1, 8, 8);
    SelectClipRgn(dc, clip);
    RoundRect(dc, r.left, r.top, r.right, r.bottom, 8, 8);
    SelectClipRgn(dc, NULL);
    DeleteObject(clip);
    SelectObject(dc, oldPen);
    SelectObject(dc, oldBr);
    DeleteObject(pen);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, disabled ? RGB(168, 172, 178) : st->text);
    HFONT of = (HFONT)SelectObject(dc, font);
    RECT tr = r;
    DrawTextW(dc, text, -1, &tr, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    SelectObject(dc, of);
    if (dis->itemState & ODS_FOCUS) {
        DrawFocusRect(dc, &r);
    }
}

// ---------------------------------------------------------------- icons

static HICON MakeDotIcon(COLORREF c) {
    HDC screen = GetDC(NULL);
    HDC dc = CreateCompatibleDC(screen);
    BITMAPV5HEADER bi = {};
    bi.bV5Size = sizeof(bi);
    bi.bV5Width = 16; bi.bV5Height = 16;
    bi.bV5Planes = 1; bi.bV5BitCount = 32;
    bi.bV5Compression = BI_BITFIELDS;
    bi.bV5RedMask = 0x00FF0000; bi.bV5GreenMask = 0x0000FF00; bi.bV5BlueMask = 0x000000FF;
    bi.bV5AlphaMask = 0xFF000000;
    void* bits = NULL;
    HBITMAP color = CreateDIBSection(screen, (BITMAPINFO*)&bi, DIB_RGB_COLORS,
                                     &bits, NULL, 0);
    unsigned int* px = (unsigned int*)bits;
    for (int y = 0; y < 16; y++) {
        for (int x = 0; x < 16; x++) {
            double dx = x - 7.5, dy = y - 7.5;
            double d = sqrt(dx * dx + dy * dy);
            unsigned int a;
            if (d <= 5.0) a = 255;
            else if (d <= 6.0) a = 160;         // soft edge
            else a = 0;
            unsigned int rgb = (unsigned int)c & 0xFFFFFF;
            px[(15 - y) * 16 + x] = (a << 24) | rgb;
        }
    }
    HBITMAP mask = CreateBitmap(16, 16, 1, 1, NULL);
    ICONINFO ii = { TRUE, 0, 0, mask, color };
    HICON ico = CreateIconIndirect(&ii);
    DeleteObject(color); DeleteObject(mask);
    DeleteDC(dc);
    ReleaseDC(NULL, screen);
    return ico;
}

// ---------------------------------------------------------------- header paint

static COLORREF HeaderColor() {
    switch (g_state) {
        case APP_CONNECTED:  return WorkerAlive() && HeartbeatFresh()
                                    ? C_GREEN : C_RED;
        case APP_CONNECTING: return C_ORANGE;
        default:            return C_MUTED;
    }
}

static void PaintHeader(HDC dc, const RECT& rc) {
    int s = (int)(g_scale * 96) / 96; (void)s;
    // State dot
    HBRUSH dot = CreateSolidBrush(HeaderColor());
    int dotSz = (int)(20 * g_scale);
    RECT dr = { (int)(20 * g_scale), (int)(22 * g_scale),
                (int)(20 * g_scale) + dotSz, (int)(22 * g_scale) + dotSz };
    HBRUSH ob = (HBRUSH)SelectObject(dc, dot);
    HPEN np = CreatePen(PS_NULL, 0, 0);
    HPEN op = (HPEN)SelectObject(dc, np);
    Ellipse(dc, dr.left, dr.top, dr.right, dr.bottom);
    SelectObject(dc, op); SelectObject(dc, ob);
    DeleteObject(dot); DeleteObject(np);

    SetBkMode(dc, TRANSPARENT);

    // Title + subtitle
    const wchar_t* title;
    switch (g_state) {
        case APP_CONNECTED:
            title = (WorkerAlive() && HeartbeatFresh())
                ? L"Connected" : L"Worker unresponsive"; break;
        case APP_CONNECTING: title = L"Connecting..."; break;
        default:            title = L"Disconnected"; break;
    }
    SetTextColor(dc, HeaderColor());
    HFONT of = (HFONT)SelectObject(dc, gFTitle);
    TextOutW(dc, (int)(52 * g_scale), (int)(14 * g_scale), title, (int)wcslen(title));
    SelectObject(dc, gFSub);
    SetTextColor(dc, C_MUTED);
    const wchar_t* sub;
    switch (g_state) {
        case APP_CONNECTED:
            sub = (WorkerAlive() && HeartbeatFresh())
                ? L"Tunnel is up - traffic via 127.0.0.1:1080/1088 goes through HKU"
                : L"The worker loop stopped - use Disconnect to recover"; break;
        case APP_CONNECTING: sub = L"Requesting elevation / bringing the tunnel up"; break;
        default:            sub = L"Tunnel is down"; break;
    }
    TextOutW(dc, (int)(52 * g_scale), (int)(46 * g_scale), sub, (int)wcslen(sub));
    SelectObject(dc, of);

    // Server, right aligned
    RECT right = { rc.right - (int)(200 * g_scale), (int)(16 * g_scale),
                   rc.right - (int)(20 * g_scale), rc.bottom };
    SetTextColor(dc, C_ACCENT);
    SelectObject(dc, gFSub);
    RECT r1 = right; DrawTextW(dc, L"HKU Portal VPN", -1, &r1,
                               DT_RIGHT | DT_SINGLELINE | DT_NOCLIP);
    SetTextColor(dc, C_MUTED);
    RECT r2 = { right.left, right.top + (int)(18 * g_scale), right.right, 0 };
    DrawTextW(dc, L"vpn2fa.hku.hk", -1, &r2, DT_RIGHT | DT_SINGLELINE | DT_NOCLIP);
    SelectObject(dc, of);
}

// ---------------------------------------------------------------- panel proc

static LRESULT CALLBACK PanelProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
        case WM_PAINT: {
            PAINTSTRUCT ps;
            HDC dc = BeginPaint(h, &ps);
            RECT r; GetClientRect(h, &r);
            PanelStyle* st = (PanelStyle*)GetWindowLongPtrW(h, GWLP_USERDATA);
            HBRUSH br = CreateSolidBrush(st ? st->bg : C_CARD);
            HPEN pen = CreatePen(PS_SOLID, 1, st ? st->border : C_BORDER);
            HBRUSH ob = (HBRUSH)SelectObject(dc, br);
            HPEN op = (HPEN)SelectObject(dc, pen);
            RoundRect(dc, 0, 0, r.right, r.bottom,
                      st ? st->radius : 8, st ? st->radius : 8);
            SelectObject(dc, op); SelectObject(dc, ob);
            DeleteObject(br); DeleteObject(pen);
            EndPaint(h, &ps);
            return 0;
        }
        case WM_CTLCOLORSTATIC:
        case WM_CTLCOLOREDIT: {
            HDC dc = (HDC)w;
            int id = GetDlgCtrlID((HWND)l);
            SetBkMode(dc, TRANSPARENT);
            if (id == IDC_ED_LOG) {
                SetTextColor(dc, RGB(36, 41, 47));
                return (LRESULT)gBrLogBg;
            }
            if (id == IDC_ED_MFA) {
                SetBkMode(dc, OPAQUE);
                SetBkColor(dc, C_LOGBG);
                SetTextColor(dc, C_TEXT);
                return (LRESULT)gBrLogBg;
            }
            PanelStyle* st = (PanelStyle*)GetWindowLongPtrW(h, GWLP_USERDATA);
            SetBkColor(dc, st ? st->bg : C_CARD);
            if (id == ID_MFA_TITLE)      SetTextColor(dc, C_ORANGE);
            else if (id == ID_MFA_NOTE)  SetTextColor(dc, C_RED);
            else if (id >= 100 && id < 120) SetTextColor(dc, C_MUTED);
            else                          SetTextColor(dc, C_TEXT);
            HBRUSH br = CreateSolidBrush(st ? st->bg : C_CARD);
            // Caller deletes returned brush? No - must keep. Use cached static.
            static HBRUSH sBr = NULL; static COLORREF sCol = 0;
            if (sBr && sCol == (st ? st->bg : C_CARD)) { DeleteObject(br); return (LRESULT)sBr; }
            if (sBr) DeleteObject(sBr);
            sBr = br; sCol = st ? st->bg : C_CARD;
            return (LRESULT)sBr;
        }
        case WM_DRAWITEM: {
            DRAWITEMSTRUCT* dis = (DRAWITEMSTRUCT*)l;
            switch (dis->CtlID) {
                case ID_BTN_MFA:
                    DrawStyledButton(dis, &gBsConnect, L"Submit", gFButton);
                    return TRUE;
                case ID_BTN_CLEAR:
                    DrawStyledButton(dis, &gBsNeutral, L"Clear", gFSub);
                    return TRUE;
            }
            break;
        }
    }
    return DefWindowProcW(h, m, w, l);
}

// ---------------------------------------------------------------- actions

static void SetState(App_State s) {
    g_state = s;
    bool busy = (s != APP_IDLE);
    EnableWindow(hBtnConnect, s == APP_IDLE);
    EnableWindow(hBtnDisconnect, busy);
    SetWindowTextW(hBtnDisconnect, s == APP_CONNECTING ? L"Cancel" : L"Disconnect");
    ShowWindow(hPanelSession, s == APP_CONNECTED ? SW_SHOW : SW_HIDE);
    ShowWindow(hPanelMfa, SW_HIDE);
    if (s == APP_CONNECTED) {
        g_connectedTick = g_connectedTick ? g_connectedTick : GetTickCount64();
        std::wstring ip = StateValue(L"IP4");
        SetWindowTextW(hValVpn, ip.empty() ? L"-" : ip.c_str());
    } else {
        g_connectedTick = 0;
        SetWindowTextW(hValVpn, L"-");
        SetWindowTextW(hValDuration, L"-");
        SetWindowTextW(hValRoutes, L"-");
    }
    InvalidateRect(hMain, NULL, TRUE);
    UpdateTray();
}

static void DoConnect() {
    if (!g_launcher.empty() && WorkerAlive()) { SetState(APP_CONNECTED); return; }
    if (g_launcher.empty()) return;
    std::wstring args = L"-NoProfile -ExecutionPolicy Bypass -File \"" +
                        g_launcher + L"\" \"--Worker\"";
    HINSTANCE hi = ShellExecuteW(hMain, L"runas", L"powershell.exe",
                                 args.c_str(), NULL, SW_HIDE);
    if ((INT_PTR)hi > 32) {
        g_seen = 0;
        g_retry = false;
        SetState(APP_CONNECTING);
    } else if ((INT_PTR)hi == SE_ERR_ACCESSDENIED) {
        MessageBoxW(hMain, L"Elevation was declined.", L"HKU VPN", MB_ICONWARNING);
    } else {
        MessageBoxW(hMain, Fmt(L"Could not start the worker (ShellExecute=%d).",
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
    std::wstring args = L"-NoProfile -ExecutionPolicy Bypass -File \"" +
                        g_launcher + L"\" \"--stop\"";
    ShellExecuteW(hMain, NULL, L"powershell.exe", args.c_str(), NULL, SW_HIDE);
    SetState(APP_IDLE);
}

static void DoMfaSubmit() {
    wchar_t code[8] = {};
    GetWindowTextW(hEdMfa, code, 8);
    if (wcslen(code) != 6) {
        SetWindowTextW(hMfaNote, L"The code must be exactly 6 digits.");
        ShowWindow(hMfaNote, SW_SHOW);
        return;
    }
    if (WriteAllTextW(P.response, code)) {
        ShowWindow(hPanelMfa, SW_HIDE);
    } else {
        SetWindowTextW(hMfaNote, L"Could not deliver the code.");
        ShowWindow(hMfaNote, SW_SHOW);
    }
}

// ---------------------------------------------------------------- state machine

static void Tick() {
    auto lines = ReadLinesW(P.markers);
    if ((int)lines.size() > g_seen) {
        for (int i = g_seen; i < (int)lines.size(); i++) {
            const std::wstring& l = lines[i];
            if (l.find(L"HKUVPN_CONNECTED") != std::wstring::npos) {
                g_connectedTick = GetTickCount64();
                SetState(APP_CONNECTED);
            } else if (l.find(L"HKUVPN_MFA_RESPONSE_REQUIRED") != std::wstring::npos &&
                       g_state == APP_CONNECTING) {
                ShowWindow(hPanelSession, SW_HIDE);
                SetWindowTextW(hMfaNote, g_retry
                    ? L"The previous code was REJECTED - enter the one showing NOW."
                    : L"");
                ShowWindow(hMfaNote, g_retry ? SW_SHOW : SW_HIDE);
                SetWindowTextW(hEdMfa, L"");
                ShowWindow(hPanelMfa, SW_SHOW);
                SetFocus(hEdMfa);
            } else if (l.find(L"HKUVPN_MFA_RETRY") != std::wstring::npos) {
                g_retry = true;
            } else if (l.find(L"HKUVPN_EXITED") != std::wstring::npos) {
                if (g_state == APP_CONNECTING) {
                    SetState(APP_IDLE);
                    ShowWindow(hPanelMfa, SW_HIDE);
                }
            }
        }
        g_seen = (int)lines.size();
    }

    if (g_state == APP_CONNECTED) {
        if (WorkerAlive()) {
            std::wstring ip = StateValue(L"IP4");
            if (!ip.empty()) SetWindowTextW(hValVpn, ip.c_str());
            if (g_connectedTick) {
                ULONGLONG el = (GetTickCount64() - g_connectedTick) / 1000;
                SetWindowTextW(hValDuration, Fmt(L"%02d:%02d:%02d",
                    (int)(el / 3600), (int)((el / 60) % 60), (int)(el % 60)).c_str());
            }
            SetWindowTextW(hValRoutes, Fmt(L"%d learned route%s, heartbeat %s",
                LearnedCount(), LearnedCount() == 1 ? L"" : L"s",
                HeartbeatFresh() ? L"OK" : L"STALE").c_str());
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

    // repaint the header occasionally (state colors)
    InvalidateRect(hMain, NULL, FALSE);
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
    if (len.QuadPart < g_logPos) g_logPos = 0;     // rotated/truncated
    if (len.QuadPart > g_logPos) {
        LARGE_INTEGER mv = { 0 }; mv.QuadPart = g_logPos;
        SetFilePointerEx(h, mv, NULL, FILE_BEGIN);
        std::string raw;
        char buf[16384];
        DWORD n = 0;
        while (ReadFile(h, buf, sizeof(buf), &n, NULL) && n > 0) {
            raw.append(buf, n);
            if (raw.size() > 65536) break;   // don't pull the whole file at once
        }
        g_logPos += (long long)raw.size();
        if (!raw.empty()) {
            int wl = MultiByteToWideChar(CP_UTF8, 0, raw.c_str(),
                                         (int)raw.size(), NULL, 0);
            std::wstring w(wl, 0);
            MultiByteToWideChar(CP_UTF8, 0, raw.c_str(), (int)raw.size(),
                                &w[0], wl);
            int cur = GetWindowTextLengthW(hEdLog);
            if (cur > 120000) {                          // trim old content
                SendMessageW(hEdLog, EM_SETSEL, 0, 60000);
                SendMessageW(hEdLog, EM_REPLACESEL, FALSE, (LPARAM)L"");
            }
            SendMessageW(hEdLog, EM_SETSEL, -1, -1);
            SendMessageW(hEdLog, EM_REPLACESEL, FALSE, (LPARAM)w.c_str());
            SendMessageW(hEdLog, EM_SCROLLCARET, 0, 0);
        }
    }
    CloseHandle(h);
}

// ---------------------------------------------------------------- tray

static HICON StateIcon() {
    switch (g_state) {
        case APP_CONNECTED:  return (WorkerAlive() && HeartbeatFresh())
                                    ? gIcoGreen : gIcoRed;
        case APP_CONNECTING: return gIcoOrange;
        default:            return gIcoGray;
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
    ShowWindow(hMain, SW_SHOW);
    ShowWindow(hMain, SW_RESTORE);
    SetForegroundWindow(hMain);
}

// ---------------------------------------------------------------- layout

static HWND MkStatic(HWND parent, int id, DWORD style, const wchar_t* txt) {
    return CreateWindowExW(0, L"STATIC", txt,
        WS_CHILD | WS_VISIBLE | SS_NOPREFIX | style,
        0, 0, 10, 10, parent, (HMENU)(INT_PTR)id, NULL, NULL);
}

static void ScaleFonts() {
    UINT dpi = GetDpiForWindow(hMain);
    auto mk = [&](int pt, int weight) {
        return CreateFontW(-MulDiv(pt, dpi, 72), 0, 0, 0, weight, FALSE,
                           FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                           CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                           DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
    };
    if (gFTitle) DeleteObject(gFTitle);
    if (gFSub)   DeleteObject(gFSub);
    if (gFBody)  DeleteObject(gFBody);
    if (gFButton) DeleteObject(gFButton);
    if (gFMono) {
        DeleteObject(gFMono);
    }
    gFTitle  = mk(20, FW_SEMIBOLD);
    gFSub    = mk(9,  FW_NORMAL);
    gFBody   = mk(9,  FW_NORMAL);
    gFButton = mk(11, FW_SEMIBOLD);
    UINT mdpi = dpi;
    gFMono   = CreateFontW(-MulDiv(10, mdpi, 72), 0, 0, 0, FW_NORMAL, FALSE,
                           FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                           CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                           FIXED_PITCH | FF_MODERN, L"Cascadia Mono");
}

static void Move(HWND h, int x, int y, int w, int ht) {
    MoveWindow(h, (int)(x * g_scale), (int)(y * g_scale),
               (int)(w * g_scale), (int)(ht * g_scale), TRUE);
}

static void LayoutAll() {
    int W = 720, H = 640;
    RECT rc; GetClientRect(hMain, &rc);
    W = rc.right; H = rc.bottom;
    (void)W; (void)H;

    int cardW = 720 - 40;
    Move(hPanelSession, 20, 92, cardW, 152);
    Move(hPanelMfa,     20, 92, cardW, 152);

    int capIds[] = { ID_CAP_ACCOUNT, ID_CAP_VPN, ID_CAP_DURATION,
                     ID_CAP_PROXY, ID_CAP_ROUTES };
    int valIds[] = { ID_VAL_ACCOUNT, ID_VAL_VPN, ID_VAL_DURATION,
                     ID_VAL_PROXY, ID_VAL_ROUTES };
    for (int i = 0; i < 5; i++) {
        HWND cap = GetDlgItem(hPanelSession, capIds[i]);
        HWND val = GetDlgItem(hPanelSession, valIds[i]);
        SendMessageW(cap, WM_SETFONT, (WPARAM)gFSub, TRUE);
        SendMessageW(val, WM_SETFONT, (WPARAM)gFBody, TRUE);
        Move(cap, 18, 16 + i * 27, 120, 20);
        Move(val, 148, 16 + i * 27, cardW - 170, 20);
    }

    // MFA panel content
    SendMessageW(GetDlgItem(hPanelMfa, ID_MFA_TITLE), WM_SETFONT, (WPARAM)gFSub, TRUE);
    Move(GetDlgItem(hPanelMfa, ID_MFA_TITLE), 18, 16, 400, 20);
    SendMessageW(hMfaNote, WM_SETFONT, (WPARAM)gFSub, TRUE);
    Move(hMfaNote, 18, 40, cardW - 36, 18);
    SendMessageW(hEdMfa, WM_SETFONT, (WPARAM)gFMono, TRUE);
    Move(hEdMfa, 18, 64, 200, 38);
    SendMessageW(hBtnMfa, WM_SETFONT, (WPARAM)gFButton, TRUE);
    Move(hBtnMfa, 234, 64, 110, 38);

    // Buttons
    SendMessageW(hBtnConnect, WM_SETFONT, (WPARAM)gFButton, TRUE);
    SendMessageW(hBtnDisconnect, WM_SETFONT, (WPARAM)gFButton, TRUE);
    Move(hBtnConnect, 20, 262, 170, 40);
    Move(hBtnDisconnect, 206, 262, 170, 40);

    // Log panel
    Move(hPanelLog, 20, 318, cardW, 640 - 318 - 64);
    SendMessageW(GetDlgItem(hPanelLog, 0), WM_SETFONT, (WPARAM)gFSub, TRUE);
    Move(GetDlgItem(hPanelLog, 0), 18, 10, 300, 20);
    Move(hBtnClear, cardW - 94, 8, 76, 26);
    SendMessageW(hBtnClear, WM_SETFONT, (WPARAM)gFSub, TRUE);
    SendMessageW(hEdLog, WM_SETFONT, (WPARAM)gFMono, TRUE);
    Move(hEdLog, 14, 42, cardW - 28, 640 - 318 - 64 - 56);

    // Footer
    SendMessageW(hChkTray, WM_SETFONT, (WPARAM)gFSub, TRUE);
    Move(hChkTray, 20, 640 - 42, 300, 20);
    SendMessageW(hFooter, WM_SETFONT, (WPARAM)gFSub, TRUE);
    Move(hFooter, 720 - 200, 640 - 42, 180, 20);

    InvalidateRect(hMain, NULL, TRUE);
}

// ---------------------------------------------------------------- wndproc

static LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
        case WM_CREATE: {
            BOOL dark = FALSE;   // light title bar to match the light theme
            DwmSetWindowAttribute(h, 20, &dark, sizeof(dark));
            return 0;
        }
        case WM_PAINT: {
            PAINTSTRUCT ps;
            HDC dc = BeginPaint(h, &ps);
            RECT rc; GetClientRect(h, &rc);
            PaintHeader(dc, rc);
            EndPaint(h, &ps);
            return 0;
        }
        case WM_ERASEBKGND:
            return 1;   // class brush handles it; avoid flicker
        case WM_CTLCOLORSTATIC: {
            HDC dc = (HDC)w;
            int id = GetDlgCtrlID((HWND)l);
            SetBkMode(dc, TRANSPARENT);
            if (id == IDC_CHK_TRAY || id == ID_FOOTER) {
                SetTextColor(dc, C_MUTED);
                return (LRESULT)gBrBg;
            }
            break;
        }
        case WM_CTLCOLOREDIT:
            if (GetDlgCtrlID((HWND)l) == IDC_ED_LOG) {
                HDC dc = (HDC)w;
                SetBkColor(dc, C_LOGBG);
                SetTextColor(dc, RGB(36, 41, 47));
                return (LRESULT)gBrLogBg;
            }
            break;
        case WM_DRAWITEM: {
            DRAWITEMSTRUCT* dis = (DRAWITEMSTRUCT*)l;
            if (dis->CtlID == ID_BTN_CONNECT) {
                DrawStyledButton(dis, &gBsConnect, L"Connect", gFButton);
                return TRUE;
            }
            if (dis->CtlID == ID_BTN_DISCONNECT) {
                DrawStyledButton(dis, &gBsDanger,
                    g_state == APP_CONNECTING ? L"Cancel" : L"Disconnect",
                    gFButton);
                return TRUE;
            }
            break;
        }
        case WM_COMMAND: {
            int id = LOWORD(w);
            if (id == ID_BTN_CONNECT && HIWORD(w) == BN_CLICKED) DoConnect();
            else if (id == ID_BTN_DISCONNECT && HIWORD(w) == BN_CLICKED) DoDisconnect();
            else if (id == ID_BTN_MFA && HIWORD(w) == BN_CLICKED) DoMfaSubmit();
            else if (id == ID_BTN_CLEAR && HIWORD(w) == BN_CLICKED) {
                SetWindowTextW(hEdLog, L"");
                g_logPos = -1;
            }
            return 0;
        }
        case WM_TIMER:
            if (w == 1) Tick();
            else if (w == 2) TailLog();
            return 0;
        case WM_DPICHANGED: {
            UINT dpi = HIWORD(w);
            g_scale = dpi / 96.0;
            RECT* r = (RECT*)l;
            SetWindowPos(h, NULL, r->left, r->top,
                         r->right - r->left, r->bottom - r->top,
                         SWP_NOZORDER | SWP_NOACTIVATE);
            ScaleFonts();
            LayoutAll();
            return 0;
        }
        case WM_SIZE:
            LayoutAll();
            return 0;
        case WM_APP_TRAY: {
            if (l == WM_RBUTTONUP || l == WM_CONTEXTMENU) {
                POINT pt; GetCursorPos(&pt);
                HMENU menu = CreatePopupMenu();
                AppendMenuW(menu, MF_STRING, 1, L"Show window");
                AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
                AppendMenuW(menu, MF_STRING, 2, L"Exit (VPN keeps running)");
                SetForegroundWindow(h);
                int cmd = TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_RETURNCMD,
                                         pt.x, pt.y, 0, h, NULL);
                DestroyMenu(menu);
                if (cmd == 1) ShowFromTray();
                else if (cmd == 2) { g_realExit = true; DestroyWindow(h); }
            } else if (l == WM_LBUTTONDBLCLK) {
                ShowFromTray();
            }
            return 0;
        }
        case WM_CLOSE:
            if (!g_realExit && SendMessageW(hChkTray, BM_GETCHECK, 0, 0) == BST_CHECKED) {
                ShowWindow(h, SW_HIDE);
                return 0;
            }
            DestroyWindow(h);
            return 0;
        case WM_DESTROY:
            if (g_nid.hWnd) Shell_NotifyIconW(NIM_DELETE, &g_nid);
            PostQuitMessage(0);
            return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

// ---------------------------------------------------------------- winmain

int WINAPI wWinMain(HINSTANCE hInst, HINSTANCE, LPWSTR, int nCmd) {
    InitCommonControls();
    SetProcessDPIAware();

    // Paths
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

    gBrBg     = CreateSolidBrush(C_BG);
    gBrCard   = CreateSolidBrush(C_CARD);
    gBrLogBg  = CreateSolidBrush(C_LOGBG);
    gIcoGray   = MakeDotIcon(RGB(150, 153, 158));
    gIcoGreen  = MakeDotIcon(C_GREEN);
    gIcoOrange = MakeDotIcon(C_ORANGE);
    gIcoRed    = MakeDotIcon(C_RED);
    gIcoApp    = (HICON)LoadImageW(hInst, MAKEINTRESOURCEW(1),
                                   IMAGE_ICON, 0, 0, LR_DEFAULTSIZE);

    RegisterPanelClass(hInst);

    WNDCLASSW wc = {};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInst;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = gBrBg;
    wc.hIcon = gIcoApp;
    wc.lpszClassName = L"HkuMain";
    RegisterClassW(&wc);

    hMain = CreateWindowExW(0, L"HkuMain", L"HKU VPN",
        WS_OVERLAPPEDWINDOW & ~(WS_MAXIMIZEBOX | WS_THICKFRAME),
        CW_USEDEFAULT, CW_USEDEFAULT, 720, 640, NULL, NULL, hInst, NULL);
    {
        UINT dpi = GetDpiForWindow(hMain);
        g_scale = dpi / 96.0;
        RECT adj = { 0, 0, (int)(720 * g_scale), (int)(640 * g_scale) };
        AdjustWindowRectEx(&adj,
            WS_OVERLAPPEDWINDOW & ~(WS_MAXIMIZEBOX | WS_THICKFRAME), FALSE, 0);
        SetWindowPos(hMain, NULL, CW_USEDEFAULT, CW_USEDEFAULT,
                     adj.right - adj.left, adj.bottom - adj.top,
                     SWP_NOZORDER | SWP_NOMOVE);
    }

    ScaleFonts();

    // Session panel
    static PanelStyle stCard = { C_CARD, C_BORDER, 10 };
    hPanelSession = CreateWindowExW(0, L"HkuPanel", NULL, WS_CHILD | WS_VISIBLE,
                                    0, 0, 10, 10, hMain, NULL, hInst, NULL);
    SetWindowLongPtrW(hPanelSession, GWLP_USERDATA, (LONG_PTR)&stCard);
    MkStatic(hPanelSession, ID_CAP_ACCOUNT, 0, L"Account");
    MkStatic(hPanelSession, ID_CAP_VPN, 0, L"VPN address");
    MkStatic(hPanelSession, ID_CAP_DURATION, 0, L"Duration");
    MkStatic(hPanelSession, ID_CAP_PROXY, 0, L"Local proxy");
    MkStatic(hPanelSession, ID_CAP_ROUTES, 0, L"Routes");
    hValAccount = MkStatic(hPanelSession, ID_VAL_ACCOUNT, 0, g_account.c_str());
    hValVpn     = MkStatic(hPanelSession, ID_VAL_VPN, 0, L"-");
    hValDuration= MkStatic(hPanelSession, ID_VAL_DURATION, 0, L"-");
    MkStatic(hPanelSession, ID_VAL_PROXY, 0,
             L"socks5://127.0.0.1:1080   http://127.0.0.1:1088");
    hValRoutes  = MkStatic(hPanelSession, ID_VAL_ROUTES, 0, L"-");

    // MFA panel
    static PanelStyle stMfa = { C_CARD, RGB(223, 196, 120), 10 };
    hPanelMfa = CreateWindowExW(0, L"HkuPanel", NULL, WS_CHILD,
                                0, 0, 10, 10, hMain, NULL, hInst, NULL);
    SetWindowLongPtrW(hPanelMfa, GWLP_USERDATA, (LONG_PTR)&stMfa);
    MkStatic(hPanelMfa, ID_MFA_TITLE, 0, L"Multi-factor authentication");
    hMfaNote = MkStatic(hPanelMfa, ID_MFA_NOTE, 0, L"");
    hEdMfa = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
        WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL | ES_NUMBER | ES_CENTER,
        0, 0, 10, 10, hPanelMfa, (HMENU)IDC_ED_MFA, hInst, NULL);
    SendMessageW(hEdMfa, EM_SETLIMITTEXT, 6, 0);
    hBtnMfa = CreateWindowExW(0, L"BUTTON", L"Submit",
        WS_CHILD | WS_VISIBLE | BS_OWNERDRAW | BS_DEFPUSHBUTTON,
        0, 0, 10, 10, hPanelMfa, (HMENU)ID_BTN_MFA, hInst, NULL);

    // Main buttons
    hBtnConnect = CreateWindowExW(0, L"BUTTON", L"Connect",
        WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
        0, 0, 10, 10, hMain, (HMENU)ID_BTN_CONNECT, hInst, NULL);
    hBtnDisconnect = CreateWindowExW(0, L"BUTTON", L"Disconnect",
        WS_CHILD | WS_VISIBLE | BS_OWNERDRAW | WS_DISABLED,
        0, 0, 10, 10, hMain, (HMENU)ID_BTN_DISCONNECT, hInst, NULL);
    SetWindowSubclass(hBtnConnect, BtnSubProc, 1, 0);
    SetWindowSubclass(hBtnDisconnect, BtnSubProc, 2, 0);
    SetWindowSubclass(hBtnMfa, BtnSubProc, 3, 0);
    SetWindowSubclass(hBtnClear, BtnSubProc, 4, 0);

    // Log panel
    static PanelStyle stLog = { C_CARD, C_BORDER, 10 };
    hPanelLog = CreateWindowExW(0, L"HkuPanel", NULL, WS_CHILD | WS_VISIBLE,
                                0, 0, 10, 10, hMain, NULL, hInst, NULL);
    SetWindowLongPtrW(hPanelLog, GWLP_USERDATA, (LONG_PTR)&stLog);
    MkStatic(hPanelLog, 0, 0, L"OpenConnect log  \u00B7  live");
    hBtnClear = CreateWindowExW(0, L"BUTTON", L"Clear",
        WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
        0, 0, 10, 10, hPanelLog, (HMENU)ID_BTN_CLEAR, hInst, NULL);
    hEdLog = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
        WS_CHILD | WS_VISIBLE | WS_VSCROLL | WS_HSCROLL | ES_MULTILINE |
        ES_READONLY | ES_AUTOVSCROLL | ES_AUTOHSCROLL,
        0, 0, 10, 10, hPanelLog, (HMENU)IDC_ED_LOG, hInst, NULL);

    // Footer
    hChkTray = CreateWindowExW(0, L"BUTTON", L"Close button minimizes to tray",
        WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX,
        0, 0, 10, 10, hMain, (HMENU)IDC_CHK_TRAY, hInst, NULL);
    SendMessageW(hChkTray, BM_SETCHECK, BST_CHECKED, 0);
    hFooter = MkStatic(hMain, ID_FOOTER, SS_RIGHT, L"hkuvpn desktop (native) 1.0");

    LayoutAll();

    // Tray
    g_nid.cbSize = sizeof(g_nid);
    g_nid.hWnd = hMain;
    g_nid.uID = 1;
    g_nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    g_nid.uCallbackMessage = WM_APP_TRAY;
    g_nid.hIcon = gIcoGray;
    lstrcpynW(g_nid.szTip, L"HKU VPN: disconnected", 128);
    Shell_NotifyIconW(NIM_ADD, &g_nid);

    // Timers + boot state
    SetTimer(hMain, 1, 400, NULL);
    SetTimer(hMain, 2, 600, NULL);
    if (WorkerAlive()) { g_seen = 0; }
    SetState(WorkerAlive() ? APP_CONNECTED : APP_IDLE);

    ShowWindow(hMain, nCmd);
    UpdateWindow(hMain);

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        if (!IsDialogMessageW(hMain, &msg)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    return (int)msg.wParam;
}
