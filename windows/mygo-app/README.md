# HKU VPN - MyGo desktop app

Native UI client for the HKU campus VPN, built with
[MyGo](https://github.com/egoist/mygo) (pure Go, Direct3D 11 on Windows,
no WebView). It drives the same elevated worker as the PowerShell
frontends: `windows/bin/hkuvpn.ps1 --Worker` / `--stop`, with the
protocol files under `%TEMP%\hkuvpn` (markers.log, hb.log, pids.txt,
vpnc-state.txt, response.txt, stop.flag).

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
`%TEMP%\hkuvpn\app.log` (startup errors also pop a message box). The
VPN session log is a separate file, `%TEMP%\hkuvpn\openconnect.log`,
shown in the View log sheet.

## Develop

    go tool mygo dev    # live reload
    go test             # view tests without a window

## Tray icons

`assets/tray-{gray,green,amber,red}.png` (64px, embedded) encode the
connection state; MyGo scales them for the taskbar. They are rendered
from `assets/tray-icon.svg` (simplified variant: `tray-icon-small.svg`)
with `python3 make-tray-icons.py` - rerun it after editing the SVG.

The app window itself is intentionally icon-less.
