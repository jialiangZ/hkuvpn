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

## Requirements

- Windows 10 1803+ / Windows 11, 64-bit (`curl.exe` ships with the OS)
- PowerShell 5.1 (built in)
- Administrator rights — hkuvpn.ps1 self-elevates with a UAC prompt for
  connect/stop (the wintun adapter and route changes need it)
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

Then configure — same files and formats as the Docker edition:

```powershell
mkdir $HOME\.vpn
copy $HOME\hkuvpn\windows\examples\hku.env.example $HOME\.vpn\hku.env
notepad $HOME\.vpn\hku.env          # set HKU_USER
Set-Content $HOME\.vpn\hku.pass 'YOUR-STATIC-PORTAL-PIN'
powershell -ExecutionPolicy Bypass -File .\hkuvpn.ps1 --check
```

Optional profile shortcut (add to your `$PROFILE`):

```powershell
function hkuvpn { & "$HOME\hkuvpn\windows\bin\hkuvpn.ps1" @args }
```

## Everyday commands

```powershell
hkuvpn              # smart connect: prompts for the MFA code, waits for the tunnel
hkuvpn              # run again while connected: reports status
hkuvpn --check      # pre-flight check (exit 0 = ready)
hkuvpn -f           # foreground connect, echoes the raw OpenConnect log
hkuvpn -d           # background connect (waits for MFA readiness)
hkuvpn --mfa 123456 # deliver the code to the background worker
hkuvpn --status     # layered health check (exit 0/2/3/4/5)
hkuvpn --logs       # follow the OpenConnect log
hkuvpn --stop       # stop, remove split routes and the NRPT rule
```

Smart mode stays attached to your console: closing the window (or Ctrl+C)
disconnects the VPN, like `hkuvpn -f` in the Docker edition. Use `-d` for a
hidden background worker when you want the terminal back.

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
| UAC | not needed on the Windows side | one UAC prompt per connect/stop |

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
- **Session freezes (no keepalives)** — set `HKU_DTLS=0` in
  `%USERPROFILE%\.vpn\hku.env`, same as the Docker edition.
- **Stale routes after a crash** — run `hkuvpn --stop` (it replays the
  disconnect script and removes the NRPT rule), or check `route print`.
- **`--mfa` says no worker** — the background worker exited early;
  reconnect with plain `hkuvpn` and watch the console output.

## Security notes

- The Portal PIN is read from `%USERPROFILE%\.vpn\hku.pass` and delivered
  to OpenConnect over its stdin pipe; it never appears on a command line.
- Runtime state (log, markers, pid list) lives under `%TEMP%\hkuvpn`.
- The MFA code file exists only for the seconds between `--mfa` and its
  consumption by the worker, then it is deleted.
- Unlike the container edition there is no sandbox around OpenConnect; you
  are trusting the official binaries the same way you trust the Docker
  image.
