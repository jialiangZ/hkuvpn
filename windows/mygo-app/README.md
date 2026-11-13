# HKU VPN - MyGo desktop app

[简体中文](README.zh-CN.md)

Native UI client for the HKU campus VPN, built with
[MyGo](https://github.com/egoist/mygo) (pure Go, Direct3D 11 on Windows,
no WebView). It drives the same elevated worker as the PowerShell
frontends: `windows/bin/hkuvpn.ps1 --Worker` / `--stop`, with the
protocol files under `%TEMP%\hkuvpn` (markers.log, hb.log, pids.txt,
vpnc-state.txt, response.txt, stop.flag).

## The windows

One size each, no resizing: the app has little to show, and a window
that cannot grow has no empty space in it (`DisableResize` and
`DisableMaximize` in the window options).

The caption is the system's own. Windows 11 keeps drawing the maximize
button even when the window cannot maximize, so it shows greyed out.

The four panels - the log, the diagnostics, the routes and the settings -
open in windows of their own: the main window is small, and a log needs
more room than that. The layout is built from the theme's own spacing
(`t.Space(n)`), so it stays in step with the official widgets.

## Build

    ./build.sh          # GOOS=windows go build -> publish/HKUVPN.exe

Go 1.27+ only; no C toolchain, no frontend build.

The build passes `-H=windowsgui` (and `mygo.production=1`): the exe is a
GUI app, so Windows does not attach a console to it and no terminal
window opens next to the app. `go tool mygo build` adds the same flag on
its own. `go tool mygo dev` is the exception - a dev build keeps the
console for the inspector output.

## Logs

The app has no console, so its own diagnostics go to
`%LOCALAPPDATA%\HKUVPN\app.log` (startup errors also pop a message
box). That is a durable place, not `%TEMP%`: the log is meant to be read
after a failure, and Windows clears the temporary directory on its own
schedule. It is rolled when the day changes or the file passes a
megabyte, and a week of generations is kept.

The VPN session log is a separate file, `%TEMP%\hkuvpn\openconnect.log`,
shown in the Connection log window. The worker writes a new one for every
connection attempt, so two runs are never mixed, and rolls it past two
megabytes with three generations kept.

## Develop

    go tool mygo dev    # live reload
    go test             # view tests without a window

## What the app does

- **Session**: Connect (UAC) -> MFA code dialog (a gate: the code leads
  on, closing it gives the attempt up) -> tunnel up, with the
  VPN address, the uptime, the proxy endpoints and the learned routes on
  the status card. Cancel while connecting watches the worker until it is
  really gone; Disconnect needs no UAC. Closing the window hides it to the
  tray, and exiting the app never kills the session.
- **Diagnostics**: the checks the worker needs (account, PIN, tools, ports,
  certificate pin) and a test of the local SOCKS5 and HTTP proxies,
  including the address the traffic leaves with.
- **Routes**: the learned routes (what goes through the tunnel), with
  adding and removing them.
- **Settings**: the advanced options the worker reads from `hku.env`
  (endpoint, ports, DTLS, auto-routes, DNS rules, proxy domains) and the
  app's own preferences (start with Windows, reconnect, connect at start).
- **Log**: the session log with severity tags, a level filter, a search
  field, copy and export.

The panels sit under the window as a row of icons (`assets/ui/*.svg`,
Lucide-style outlines that take the text color, so they follow the
theme). Each one names itself in a tip.

The app's own state (preferences and the start time of the running
session) lives in `%USERPROFILE%\.vpn\app-state.json`.

While it runs, the app writes what it is doing to
`%TEMP%\hkuvpn\app-status.txt` (state, worker, heartbeat, the pending
code, the VPN address). It is what the regression script reads, and it
answers "what does the app think it is doing?" without the window.

## Icons

`assets/app-icon.png` (256px, transparent) is the app icon: the window,
the taskbar and Alt+Tab show it, and the README header uses the same
artwork rendered at 256px in `docs/images/hkuvpn-icon.png`.

`assets/tray-{gray,green,amber,red}.png` (64px, embedded) carry the same
crest with a badge in the connection-state colour; MyGo scales them for
the taskbar. They are rendered from `assets/app-icon.png` with
`python3 make-tray-icons.py` (Pillow) - rerun it after replacing the
icon.
