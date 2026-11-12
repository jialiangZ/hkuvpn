# HKU VPN for Windows - start here

You need:

- **Windows 10 1803+ or Windows 11**, 64-bit
- an **HKU account with VPN enabled**
- your **static Portal PIN** (the one from the HKU portal, not a code)
- **Microsoft Authenticator** on your phone, for the six-digit code

## 1. Unpack

Extract `HKUVPN-windows-<version>.zip` anywhere you like, for example
`C:\hkuvpn`. The folder should look like this:

```
HKUVPN.exe               the app
bin\hkuvpn.ps1           the worker it drives
bin\get-tools.ps1        fetches the two dependencies (step 2)
shell\hkuvpn.cmd         one-word command from a shell
shell\hkuvpn-connect.ps1 the bare-command flow and its orphan guard
shell\hkuvpn-watchdog.ps1
shell\bootstrap.ps1      writes the account and PIN config (optional)
shell\install-path.ps1   puts shell on the PATH (optional)
etc\vpnc-script-win.js   the routing script
examples\hku.env.example the configuration template
START-HERE.md            this file
```

## 2. Install the two dependencies (once)

Open PowerShell in that folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\bin\get-tools.ps1
```

Approve the UAC prompt. It installs **OpenConnect** (which brings the
Wintun network adapter) and downloads **gost**, the local proxy. Both
downloads are checked against pinned SHA-256 hashes; if a hash does not
match, nothing is installed.

## 3. Start the app

```powershell
.\HKUVPN.exe
```

The window shows the state of the session, two fields, and a button.

1. Fill in **HKU account** (`youruid@connect.hku.hk`) and **Portal PIN**.
   Both are saved as you type - there is no save button, and nothing
   leaves your machine.
2. Press **Connect**. A UAC prompt appears; approve it.
3. When the **Verification code** dialog appears, type the six digits
   from Authenticator and press Enter. The code is only good for about
   30 seconds, so type the one showing now.
4. The tunnel comes up in about half a minute. The card then shows the
   tunnel address and the uptime.

The proxies are on `127.0.0.1:1080` (SOCKS5) and `127.0.0.1:1088` (HTTP).
Point a browser, an SSH session or a rules client at them.

### Prefer a terminal?

```powershell
powershell -ExecutionPolicy Bypass -File .\shell\bootstrap.ps1      # account, PIN, campus subnets
powershell -ExecutionPolicy Bypass -File .\shell\install-path.ps1   # once, then open a new terminal
hkuvpn
```

The first command writes `%USERPROFILE%\.vpn\hku.env` and `hku.pass`
(it asks for both; existing files are kept unless you add `-Force`). The
second puts `shell` on your user PATH once (no administrator rights).
`hkuvpn` then connects with the MFA code typed in that window - no second
console - and closing the window after "Connected" leaves the tunnel up. A
window closed, or a Ctrl+C, before that is cleaned up by the guard, so
nothing is left waiting for a code. `hkuvpn --status`, `--stop` and
`--logs` work from any terminal too.

If the machine has to reach a campus-only host such as a lab server, give
the subnet when `bootstrap.ps1` asks (e.g. `10.128.0.0/16`): that is the
`HKU_EXTRA_ROUTES` value, and it is what makes `10.x` reachable at all.

## 4. When you are done

Press **Disconnect** - no UAC prompt this time. Closing the window keeps
the tunnel running in the tray; the tray icon is also the way back to the
window. Right-click it and pick **Exit** to leave the app (the tunnel
keeps running until you disconnect it).

## If something goes wrong

- **Diagnostics** (the second icon under the window) checks what the app
  needs and tests the local proxies.
- **Settings** (the last icon) holds the advanced options, and a switch
  to start the app with Windows.
- The app's own log is at `%LOCALAPPDATA%\HKUVPN\app.log`; the session
  log is at `%TEMP%\hkuvpn\openconnect.log`.

Please report what happened at
<https://github.com/jialiangZ/hkuvpn/issues> - the form asks for the
pre-flight output and the log lines, which is what makes a bug fixable.
