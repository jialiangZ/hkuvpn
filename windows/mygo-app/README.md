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

## Develop

    go tool mygo dev    # live reload
    go test             # view tests without a window

## Tray icons

`assets/tray-{gray,green,amber,red}.png` (64px, embedded) encode the
connection state; MyGo scales them for the taskbar. They are rendered
from `assets/tray-icon.svg` (simplified variant: `tray-icon-small.svg`)
with `python3 make-tray-icons.py` - rerun it after editing the SVG.

The app window itself is intentionally icon-less.
