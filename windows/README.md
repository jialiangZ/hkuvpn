# hkuvpn — Native Windows port

Run the HKU VPN **directly on Windows** — no WSL, no Docker. This port keeps
the design goal of the main project: your default route and everyday
Internet stay untouched; only the traffic you send through the local proxy
enters the campus network.

> **Status: field-tested, still young.** The pieces are standard (official
> OpenConnect Windows build, official gost release), and a full session has
> been run against a real HKU account on Windows 11 with PowerShell 5.1 —
> connect, routing, licensed-resource routing and a clean shutdown. It is
> still much newer than the container edition, so keep the Docker/WSL
> edition as a fallback. See
> [Known differences](#known-differences-vs-the-wsldocker-edition).

## Get the desktop app

If you only want to use the VPN on Windows, you do not need anything from
this repository beyond the app itself.

1. Download **`HKUVPN-windows-<version>.zip`** from the
   [releases](https://github.com/jialiangZ/hkuvpn/releases).
2. Unpack it anywhere, for example `C:\hkuvpn`.
3. Run `bin\get-tools.ps1` **once**, as administrator. It installs
   OpenConnect (which brings the Wintun adapter) and downloads gost; both
   downloads are checked against pinned SHA-256 hashes.
4. Start `HKUVPN.exe`, type your HKU account and Portal PIN, and press
   Connect.

`START-HERE.md` (English) and `START-HERE.zh-CN.md` are in the archive and
walk through it step by step. Nothing you type leaves your machine, and
the app's own log stays on your disk.

To build it from the source instead, see
[`mygo-app/README.md`](mygo-app/README.md) - that needs Go 1.27 on
Windows.

Working on this port for the first time? Work through the
[validation checklist](VALIDATION.md) — it walks through every step from
`--check` to "nothing left behind on the host", with the expected output of
each command.

## How it works

```
Application ──► 127.0.0.1:1080 (SOCKS5) / :1088 (HTTP) ──► gost
                                                            │
        Windows routing table: on-demand routes ─────────────┴─► tun (wintun) ──► HKU
        everything else ───────────────────────────────────────► your normal NIC
```

| Role | Component |
|---|---|
| VPN client | `openconnect.exe` (official Windows CLI build, Wintun adapter) |
| Auth automation | `hkuvpn.ps1` answers the Portal-PIN prompt, loops on the MFA form |
| Proxy listeners | `gost.exe` (same binary family as the container image) |
| Routing | `etc\vpnc-script-win.js` — custom split-tunnel-only vpnc script |

The critical difference from the stock OpenConnect script: ours **never
installs a default route through the tunnel**. It adds only the subnets the
VPN server pushes (`CISCO_SPLIT_INC_*`) plus your `HKU_EXTRA_ROUTES`, so
Windows keeps using your physical adapter for everything else.

HKU's gateway is a **full-tunnel gateway that pushes no split routes at all**
(`connect done: 0 v4 route(s)` in the log is normal, not a failure). The
gateway carries public destinations through the tunnel, so the native port
routes destinations **on demand** — see below. Campus-only DNS is handled
with an NRPT rule that resolves `*.hku.hk` through the VPN's own resolvers;
the rule is only added when those resolvers are actually reachable through
the tunnel. With HKU they are not, so the rule is skipped on purpose
(`HKUVPN_NRPT_SKIPPED dns-not-routed`) — a rule pointing at an unreachable
resolver would only black-hole the lookups.

## Automatic routing for licensed resources

Windows has no per-process routing, but the native port closes the gap to
the Docker edition with **auto-learned routes** (`HKU_AUTO_ROUTES=1`,
default on):

1. gost runs in debug mode and logs every destination the proxy dials —
   **before** the connection is attempted, so a destination that never
   answers is learned too (that is exactly the case of a resource that is
   only reachable through the campus exit).
2. When a proxied destination is **not** covered by the routes the server
   pushed, its prefix (default `/24`) is routed through the tunnel
   automatically.
3. Learned routes persist in `%USERPROFILE%\.vpn\learned-routes.txt`,
   survive restarts (TTL 14 days, cap 512 entries), and are re-installed
   at the next connect.

So the practical rule is: **send it to the proxy and it goes through
HKU.** A brand-new external resource works from the second request (the
first one triggers the learning — refresh the page); add its domain to
`HKU_PROXY_DOMAINS` if you want even the first request to work. Private,
CGNAT, multicast, and rules-client fake-IP (`198.18.0.0/15`) addresses are
never learned. Inspect with `hkuvpn.ps1 --check`, the `HKUVPN_ROUTE_ADDED`
markers in `%TEMP%\hkuvpn\markers.log`, or `route print -4`; stale entries
can be cleared by deleting `learned-routes.txt`.

Side effect worth knowing: a learned `/24` applies to the whole OS, so
non-proxied apps reaching the same network also egress via HKU (usually
irrelevant — that block belongs to the licensed resource anyway).

## Reaching hosts inside the campus network

The gateway in this deployment pushes a single split route
(`10.64.192.0/20`, the tunnel's own subnet). Nothing else on `10.x` is
routed, and the auto-learner above deliberately never learns RFC1918
addresses — so a lab server on a campus-only subnet is unreachable until
you name that subnet yourself:

```ini
# %USERPROFILE%\.vpn\hku.env
HKU_EXTRA_ROUTES=10.128.0.0/16
```

Rules that save time:

- **Comma-separated list**, e.g. `10.128.0.0/16,10.140.0.0/16`.
- **Reconnect** after editing: routes are installed by the vpnc script at
  connect time (`HKUVPN_AUTOROUTE_ON` / `route print -4` shows them).
- **Keep it narrow.** A `/8` covers your own Wi-Fi LAN block too; a
  `/16` for the lab is enough, and the tunnel's own subnet
  (`10.64.192.0/20`) is already routed.
- The value is the same one `shell\bootstrap.ps1` writes, so a new machine
  can set it in the same step as the account.

Then reach the host directly — `ssh <user>@<lab-host> -p <port>`,
`Test-NetConnection <lab-host> -Port <port>` — not through the proxy:
`HKU_EXTRA_ROUTES` adds an OS route, and the host belongs to the campus
side of the tunnel.

## Keeping an idle session alive

HKU's gateway ends a session 30 minutes after the last data packet crossed
the tunnel (`X-CSTP-Idle-Timeout: 1800`). OpenConnect's DPD/keepalive
packets do **not** reset that timer, so a session that is left alone
disconnects with `Received server disconnect: 'Idle Timeout'` even though
the client is healthy.

The worker sends one tiny proxied request (`https://www.hku.hk/`) every
`HKU_KEEPALIVE` seconds while connected — default **600** (10 minutes),
`0` turns it off. Keep it below 1800, or it cannot beat the gateway's
timer. It runs in every mode (smart, `-t`, `-d`, the app), only
after the tunnel is up, and appends one line per attempt to
`%TEMP%\hkuvpn\keepalive.log` — `... keepalive ping=ok http=200`.
The `ping` half is the one that always crosses the tunnel (its target is
inside the tunnel's own subnet, so no routing-table owner can divert it);
`http` is a second, usage-shaped probe, and `000` there means the proxied
request did not get through. `--check` prints the interval.

```ini
# %USERPROFILE%\.vpn\hku.env
HKU_KEEPALIVE=600
```

## Coexisting with a TUN proxy client (Clash / FlClash / ...)

No rules are needed in the other client. hkuvpn keeps its control channel
out from under a TUN in two ways:

1. The worker scrubs `http_proxy`/`https_proxy`/`all_proxy` (and their
   uppercase forms) from the environment of both children, so a proxy
   exported in the launching terminal — which openconnect would otherwise
   honor, sending the whole VPN through that proxy — cannot capture the
   control connection.
2. At connect time the DoH-resolved control endpoints (`vpn2fa*.hku.hk`,
   so this needs `HKU_AUTO_RESOLVE`, the default) get `/32` host routes
   through the physical NIC's gateway. A host route beats any TUN's
   `0.0.0.0/0` by prefix length alone, so the packets to the VPN gateway
   leave through the real adapter whatever the TUN client does. The pins
   are removed at disconnect, and re-pinned (after a stale delete) at the
   next connect.

Tunnel traffic was never affected to begin with: the pushed split routes
(`10.64.192.0/20`, `HKU_EXTRA_ROUTES`) and the learned `/24`s are all more
specific than a default route.

One case is outside this script's reach: a TUN that intercepts at the
driver level and ignores the routing table. Nothing route-based beats
that; there, a `DIRECT` rule for `147.8.240.0/24` inside the client is
the only answer. The standard Clash/Meta TUN stacks respect the table, so
in practice the pins are enough.

A proxied request is used on purpose: only traffic through the tunnel
resets the gateway's timer, and `www.hku.hk` is already the end-to-end
probe the connect path uses.

## Requirements

- Windows 10 1803+ / Windows 11, 64-bit (`curl.exe` ships with the OS)
- PowerShell 5.1 (built in)
- Administrator rights — hkuvpn.ps1 self-elevates with a UAC prompt for
  connect (the wintun adapter and route changes need it). Stopping a live
  session needs no UAC: the elevated worker tears itself down.
- An HKU account with VPN enabled, your **static Portal PIN**, and a
  **Microsoft Authenticator code** (same as the Docker edition)

## Install

```powershell
cd $HOME\hkuvpn\windows\bin
powershell -ExecutionPolicy Bypass -File .\get-tools.ps1
```

That downloads gost and the OpenConnect installer, verifies **both** against
pinned SHA-256 hashes, and runs the installer if you are elevated. gost is
the official go-gost release; OpenConnect is the official GitLab CI build of
the **v9.21 tag** (its artifacts never expire, unlike the moving `master`
ones) — the same OpenConnect version the Docker image builds. The installer
is deleted once it has run.

Fastest: `shell\bootstrap.ps1` asks for the account and the Portal PIN,
writes both files, and can record the campus subnets you need in the same
step (see below). It never overwrites existing files without `-Force`.

```powershell
powershell -ExecutionPolicy Bypass -File ..\shell\bootstrap.ps1
```

Or do it by hand — same files and formats as the Docker edition:

```powershell
mkdir $HOME\.vpn
copy $HOME\hkuvpn\windows\examples\hku.env.example $HOME\.vpn\hku.env
notepad $HOME\.vpn\hku.env          # set HKU_USER
Set-Content $HOME\.vpn\hku.pass 'YOUR-STATIC-PORTAL-PIN'
powershell -ExecutionPolicy Bypass -File .\hkuvpn.ps1 --check
```

Optional: put `shell` on the user PATH once, so `hkuvpn` is a real command
from cmd, PowerShell, Windows Terminal or anything else (no `$PROFILE`
function to shadow it, no administrator rights needed):

```powershell
powershell -ExecutionPolicy Bypass -File ..\shell\install-path.ps1
```

A bare `hkuvpn` then runs `-t` - the MFA code is typed in the same window, no
second console - and adds one thing `-t` cannot do alone: if that window is
closed (or interrupted with Ctrl+C) *before* the tunnel is up,
`hkuvpn-watchdog.ps1` notices and tells the hidden worker to stop, instead
of leaving it waiting for a code forever. A stop flag that arrives while the
UAC prompt is still up is honored too: the worker refuses to connect rather
than erasing it. A connected session is never touched. `install-path.ps1
-Remove` takes the PATH entry out again.

`shell` is a separate folder from `bin` on purpose: PowerShell runs a `.ps1`
script in preference to a `.cmd` with the same base name, so `hkuvpn.cmd`
next to `hkuvpn.ps1` would make the bare command mean the smart mode in
PowerShell but `-t` in cmd. Keeping them apart keeps one meaning.

## Everyday commands

```powershell
hkuvpn              # smart connect: prompts for the MFA code, waits for the tunnel
                    # (a bare `hkuvpn` on PATH means -t instead - see Install)
hkuvpn              # run again while connected: reports status (elevated window holds 5s)
hkuvpn --check      # pre-flight check (exit 0 = ready)
hkuvpn -f           # foreground connect, echoes the raw OpenConnect log
hkuvpn -t           # terminal connect: hidden elevated worker, MFA typed here,
                    # no second console window
hkuvpn -d           # background connect (waits for MFA readiness)
hkuvpn --mfa 123456 # deliver the code to the background worker
hkuvpn --status     # layered health check (exit 0/2/3/4/5)
hkuvpn --logs       # follow the current session's OpenConnect log
hkuvpn --stop       # stop (live worker cleans up itself, no UAC; force-stopping
                    # a dead session elevates)
```

Each connection starts a fresh `openconnect.log`; the previous sessions'
logs are kept beside it as `openconnect.log.1`, `.2` and `.3`, so logs never
mix runs and the runs before last can still be read. A log that passes two
megabytes is rolled during the session, three generations kept.

`hkuvpn --logs` follows that file and hides one thing: OpenConnect prints
a three-line "Support for Wintun is experimental" warning on every Windows
session, whether or not anything is wrong. The file keeps every raw line;
only the view drops it.

Three long-session modes, by scenario (plus a tray app):

- **Desktop app** (MyGo native UI, `windows\mygo-app`): `HKUVPN.exe` with a
  compact window built from MyGo's official widgets - a status card (state,
  tunnel address, duration, proxy, routes), labeled HKU account and portal
  PIN fields (saved automatically when edited), one primary Connect /
  Cancel / Disconnect button, a Connection log window (per-session log with
  DBG/INF/WRN/ERR tags, a level filter, a search field, Copy and Export),
  a Diagnostics panel (what the worker needs, plus a test of the local
  proxies and the address the traffic leaves with), a Routes panel (the
  learned routes, added and removed by hand), a Settings panel (the
  advanced options of `hku.env`, start with Windows, reconnect) and an MFA
  dialog, plus close-to-tray. The MFA dialog is a gate: the code leads
  on, and closing it (Escape or a click outside) gives the attempt up -
  there is no "enter the code later". The four panels open in windows
  of their own, so a log has the room it needs. The panels are a row of icons under the
  window, each with a tip. The window has one size: it cannot be
  resized and has no maximize button. Built with Go alone (`GOOS=windows go build`, no cgo, no
  webview) - see `windows\mygo-app\build.sh`. The exe is built as a GUI
  app (`-H=windowsgui`), so it never opens a terminal window; its own
  diagnostics go to `%LOCALAPPDATA%\HKUVPN\app.log`. The window and the
  tray carry the HKU crest (`windows\mygo-app\assets\app-icon.png`); the
  tray adds a state badge in grey / green / amber / red, rendered from
  that icon by `make-tray-icons.py`. Disconnect is UAC-free and exiting
  the app never kills a session.
- **Regression script** (`windows\tests\session-flow.ps1`): drives the
  worker and the app through the whole session lifecycle - a stop while
  the MFA dialog is a gate (closing it gives the attempt up), a connect
  and a disconnect - and
  checks the invariants: the teardown marker, no force kill, no leftover
  `gost`/`openconnect`, and the app back at "Disconnected". The steps
  that need a person are the UAC prompt and the MFA code, so run it from
  a PowerShell window (the code is typed in). `-SkipLive` leaves out the
  check that needs a code. The orphan guard has its own run -
  `windows\tests\watchdog.ps1` - with four cases, no UAC prompt and no
  VPN session.
- **Smart mode** (default): the session stays attached to its console;
  closing the window (or Ctrl+C) disconnects, like `hkuvpn -f` in the
  Docker edition. The natural fit for the desktop shortcut.
- **`-t` terminal mode**: the tunnel runs in a hidden elevated worker and
  the MFA code is typed right in the invoking terminal (an empty answer
  or a timeout stops the worker cleanly). Closing the terminal afterwards
  does NOT affect the VPN - the everyday choice from a shell. A window
  closed or interrupted with Ctrl+C *before* that is covered when you
  start from the bare command: `hkuvpn-connect.ps1` runs
  `hkuvpn-watchdog.ps1` beside the launcher, and when the console pid
  disappears before `HKUVPN_CONNECTED` appears, the watchdog writes the
  worker's stop flag. The worker honors such a flag even while the UAC
  prompt delayed its start (a flag newer than the session is a stop
  request, not leftovers). A connected session is left alone, so the same
  command still survives closing the window.
- **`-d` detach mode**: no interaction at start; deliver the code with
  `--mfa`. For scripts.

Two self-healing behaviors on top: connect entry points reap a gost
orphaned by a crashed session (it would otherwise hold 1080/1088 and
fail every later connect at bind; recorded as HKUVPN_ORPHAN_GOST_REAPED),
and every mode writes its fatal errors to markers (HKUVPN_EXITED
error=...) so a flashing window never loses the diagnostic trail.

**Enter the code as soon as you are prompted.** An Authenticator code is
only valid for about 30 seconds, and the gateway rejects an expired one. If
that happens the launcher says so — `The previous MFA code was rejected;
enter the current one` — and asks again, so just type the code that is
showing now. In `-d` mode the same applies to `hkuvpn --mfa <code>`: deliver
the code that is current at that moment, not one you copied earlier.

Use the proxies exactly as in the Docker edition: SOCKS5 `127.0.0.1:1080`,
HTTP `127.0.0.1:1088`, and point Clash Verge / Surge at them with the same
"VPN servers must be DIRECT" rule from the main guide.

## Known differences vs the WSL/Docker edition

| Topic | Docker edition | Native port |
|---|---|---|
| What goes through HKU | **All** proxied traffic (container default route = tun) | Only what you send through the proxy, routed on demand: learned routes (`HKU_AUTO_ROUTES`) + `HKU_EXTRA_ROUTES`. The gateway pushes no split routes, so there is nothing else to route |
| Where the traffic exits | campus exit for everything the container sends | campus exit for the proxied destinations, via routes learned on demand |
| Campus-external HKU-licensed sites (library databases etc.) | work through the proxy | learned automatically, **including when the first attempt fails** (the dial is logged before the connection is attempted); pre-seed via `HKU_PROXY_DOMAINS` |
| `socks5h` DNS resolution | inside the container, via the tunnel | resolved by the proxy through the host resolver; `*.hku.hk` via an NRPT rule — which is only added when the gateway's resolvers are reachable through the tunnel (with HKU they are not, so the rule is skipped) |
| Isolation | container sandbox, cap-dropped | processes run as your elevated user |
| PIN file security | chmod 600 in WSL | file under `%USERPROFILE%\.vpn`; protect with NTFS ACLs if needed |
| Prerequisite | Docker runtime (WSL) | nothing but the tools above; no WSL |
| UAC | not needed on the Windows side | one UAC prompt per connect; disconnecting a live session needs none |

## Troubleshooting

- **`HKUVPN_MFA_RESPONSE_REQUIRED` never appears** — run `hkuvpn --logs`;
  a certificate/TLS failure usually means the pinned cert changed: delete
  `%USERPROFILE%\.vpn\pin-hk.cache` and reconnect. (Windows itself rarely
  has the WSL clock-drift problem.)
- **Tunnel up, e2e check fails for non-campus sites** — under split routing
  only pushed subnets (plus extras and auto-learned routes) traverse the
  VPN. The first request to a new external resource learns its route
  (check `HKUVPN_ROUTE_ADDED` in `%TEMP%\hkuvpn\markers.log`); a retry then
  goes through the tunnel. `route print -4` shows everything installed.
- **Transfers stall, or interactive sessions hang, while short commands
  still work** — the UDP data channel (DTLS) is being throttled on your
  path. Cross-border links often treat UDP — especially UDP/443 — much
  worse than TCP; measure it with `ping -n 100 <campus-host>` through the
  tunnel. DTLS is off by default for exactly this reason; leave it that
  way unless your path is clean. On a network with clean UDP (inside Hong
  Kong, for example) set `HKU_DTLS=1` in `%USERPROFILE%\.vpn\hku.env`:
  round-trips drop to roughly a quarter (measured 44 ms against 192 ms),
  and the worker caps the tunnel MTU at what DTLS carries, so big
  transfers no longer stall.
- **Session freezes (no keepalives)** — same cause and same answer: stay
  on the default TCP channel (no `HKU_DTLS` line at all, or `HKU_DTLS=0`).
- **Stale routes after a crash** — run `hkuvpn --stop` (it replays the
  disconnect script and removes the NRPT rule), or check `route print`.
  A gost orphan holding 1080/1088 is reaped automatically at the next
  connect (HKUVPN_ORPHAN_GOST_REAPED).
- **`--mfa` says no worker** — the background worker exited early;
  reconnect with plain `hkuvpn` and watch the console output.

## Security notes

- The Portal PIN is read from `%USERPROFILE%\.vpn\hku.pass` and delivered
  to OpenConnect over its stdin pipe; it never appears on a command line.
- Runtime state (markers, pid list, heartbeat, the session log) lives under
  `%TEMP%\hkuvpn`; the session log is rolled past two megabytes with three
  generations kept.
- The app's own diagnostics live in `%LOCALAPPDATA%\HKUVPN\app.log`, rolled
  daily with a week kept. That is a durable place: the log is meant to be
  read after a failure, and Windows clears the temporary directory on its
  own schedule.
- The MFA code file exists only for the seconds between `--mfa` and its
  consumption by the worker, then it is deleted.
- Unlike the container edition there is no sandbox around OpenConnect; you
  are trusting the official binaries the same way you trust the Docker
  image.
