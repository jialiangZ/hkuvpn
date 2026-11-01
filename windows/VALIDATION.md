# Windows native port — validation checklist

A step-by-step procedure to verify the native Windows port on a real machine.
Every "expected" block below is copied from the actual implementation, so a
mismatch means something is wrong — not that the expectation is optimistic.

The whole run takes about 10 minutes (most of it is waiting for HKU's MFA
prompt).

Throughout, open **two** PowerShell windows: one runs the launcher, the other
inspects routes, logs, and state.

---

## Step 0 — Prerequisites

| Requirement | How to check |
|---|---|
| Windows 10 1803+ / Windows 11, 64-bit | `winver` |
| PowerShell 5.1 | `$PSVersionTable.PSVersion` (5.1 is the floor) |
| The repository | `git clone https://github.com/jialiangZ/hkuvpn.git $HOME\hkuvpn` |
| OpenConnect + gost | `powershell -ExecutionPolicy Bypass -File $HOME\hkuvpn\windows\bin\get-tools.ps1` |

`get-tools.ps1` must run **elevated** — the OpenConnect installer registers the
Wintun network adapter, which needs administrator rights. Both downloads are
SHA-256 verified: gost against the official go-gost checksums, OpenConnect
against the pinned hash of the official v9.21 **tag** build (the tag pipeline
keeps its artifacts forever; the moving `master` ones expire after a week).
OpenConnect 9.21 is the same version the Docker image builds, and the
installer is removed once it has run.

Verified on Windows 11 (build 26300) with PowerShell 5.1.

Your HKU credentials live outside the repository:

```powershell
mkdir $HOME\.vpn -Force
copy $HOME\hkuvpn\windows\examples\hku.env.example $HOME\.vpn\hku.env
notepad $HOME\.vpn\hku.env          # set HKU_USER=youruid@connect.hku.hk
Set-Content $HOME\.vpn\hku.pass 'YOUR-STATIC-PORTAL-PIN'
```

`hku.pass` holds the **static Portal PIN** (not the rotating six-digit
Authenticator code).

---

## Step 1 — Pre-flight (`--check`)

Does not need administrator rights.

```powershell
cd $HOME\hkuvpn\windows\bin
powershell -ExecutionPolicy Bypass -File .\hkuvpn.ps1 --check
echo $LASTEXITCODE     # expect 0
```

Expected:

```text
admin    : not elevated (connect self-elevates via UAC)
config   : ok (HKU_USER=youruid@connect.hku.hk)
pin file : ok (C:\Users\<you>\.vpn\hku.pass)
openconn.: ok (C:\Program Files\OpenConnect\openconnect.exe)
gost     : ok (C:\Users\<you>\hkuvpn\windows\tools\gost.exe)
script   : ok (etc\vpnc-script-win.js)
curl.exe : ok
ports    : 127.0.0.1:1080 and 1088 free
cert pin : not cached (fetched at connect)
autoroute: on (0 learned route(s) cached; external HKU resources are routed on demand)
result   : ready to connect (hkuvpn.ps1 or hkuvpn.ps1 -d)
```

If a line is red, the message names the fix:

| Line | Meaning |
|---|---|
| `config : HKU_USER missing or still the placeholder` | `hku.env` still says `youruid@…` |
| `openconn.: not found` | `get-tools.ps1` did not finish, or `HKUVPN_OPENCONNECT` points at the wrong path |
| `gost : not found` | `get-tools.ps1` did not download gost, or `HKUVPN_GOST` is wrong |
| `ports : … in use` | Another proxy owns 1080/1088 — set `HKU_SOCKS_PORT` / `HKU_HTTP_PORT` in `hku.env` |
| `result : NOT ready` | Count of failing checks; exit code is 1 |

---

## Step 2 — Connect

```powershell
powershell -ExecutionPolicy Bypass -File .\hkuvpn.ps1
```

A UAC prompt appears (the launcher self-elevates — the Wintun adapter and the
route changes need it). Expected:

```text
Server: vpn2fa.hku.hk
Local proxies: SOCKS5=127.0.0.1:1080 HTTP=127.0.0.1:1088
started openconnect (pid 12345) and gost (pid 12346)
Portal PIN sent; waiting for the MFA prompt...
```

Then enter the current six-digit Authenticator code — the one showing in the
app **now**, because a code is only valid for about 30 seconds. If the
gateway rejects it you will see:

```text
The previous MFA code was rejected; enter the current one.
```

That is not a failure of the port: type the code that is current now and
the session continues. The window stays attached; `Ctrl+C` disconnects.

---

## Step 3 — The routing script ran (most important check)

In the **second** window:

```powershell
Get-Content $env:TEMP\hkuvpn\openconnect.log | Select-String 'connect done'
```

Expected — one line per session:

```text
2026/11/1 18:20:11 [vpnc] connect done: 0 v4 route(s), 0 v6 route(s), dns=[147.8.2.254 147.8.145.254]
```

`0 v4 route(s)` is expected with HKU: its gateway is a full-tunnel gateway
that pushes no split routes, so the native port routes destinations on
demand instead (see the automatic routing section). The DNS servers are
recorded either way.

If this line is missing, the vpnc script never ran. Check that
`--script="…\windows\etc\vpnc-script-win.js"` appears in the OpenConnect
command line and that `cscript.exe` is reachable.

### The default route must NOT change

```powershell
route print -4
```

Expected: new entries for the campus subnets pointing at the Wintun
interface, **and the `0.0.0.0/0` default route still on your physical
adapter**. If a `0.0.0.0/0` entry moved to the tunnel, stop immediately and
report it — that is the property this port is designed to protect.

### Persisted state

```powershell
Get-Content $env:TEMP\hkuvpn\vpnc-state.txt
```

Expected:

```text
TIME=2026/11/1 18:20:11
TUNIDX=23
IP4=147.8.x.y
MASK=255.255.255.0
DNS=147.8.4.4 147.8.80.4
ROUTE=147.8.0.0/16
…
```

---

## Step 4 — Campus DNS (NRPT rule)

```powershell
Get-DnsClientNrptRule | Format-List
```

Expected: one rule with `Comment = hkuvpn` and `NameServers` set to the VPN's
own resolvers, so `*.hku.hk` names resolve through the tunnel.

If there is no rule, check the markers:

```powershell
Get-Content $env:TEMP\hkuvpn\markers.log
```

`HKUVPN_NRPT_SKIPPED dns-not-routed` is **normal** — it means the VPN's DNS
servers are not inside the pushed subnets, so the rule would be useless.
`HKUVPN_NRPT_DISABLED` means `HKU_NRPT=0` in `hku.env`.

---

## Step 5 — Layered health check (`--status`)

```powershell
powershell -ExecutionPolicy Bypass -File .\hkuvpn.ps1 --status
echo $LASTEXITCODE
```

Expected:

```text
process  : up
tunnel   : up (split routes active)
proxy    : ok (127.0.0.1:1080)
e2e      : ok (https://www.hku.hk -> HTTP 200 through the HKU tunnel)
```

Exit code `0`. The layers are ordered, so the first failing layer tells you
where to look:

| Exit | Layer | Typical cause |
|---|---|---|
| 2 | `process : not running` | The tunnel died — read `--logs` |
| 3 | `tunnel : down` | OpenConnect has not finished authenticating, or the session failed |
| 4 | `proxy : down` | gost is not listening — check `%TEMP%\hkuvpn\gost.log` |
| 5 | `e2e : failed` | `www.hku.hk` is outside the pushed split routes; expected in some networks |

Exit code 5 is often **not** a bug: this port routes only what the server
pushes, so a public site that is not in the campus ranges cannot be reached
through the tunnel. Verify with a genuinely campus-hosted host instead.

---

## Step 6 — The proxies work

```powershell
curl.exe -x socks5h://127.0.0.1:1080 -I https://www.hku.hk/
curl.exe -x http://127.0.0.1:1088     -I https://www.hku.hk/
```

Use `socks5h` so DNS is resolved through the proxy as well.

---

## Step 7 — Auto-learned routes for licensed external resources

This is the feature that closes the gap to the Docker edition. Pick an
HKU-licensed resource that lives on an external network (a library database):

```powershell
curl.exe -x socks5h://127.0.0.1:1080 -I https://<licensed-host>/
```

The **first** request may fail — the route is learned from that request. Send
it again; the second request succeeds.

Confirm what was learned:

```powershell
Get-Content $env:TEMP\hkuvpn\markers.log | Select-String 'HKUVPN_ROUTE_ADDED'
Get-Content $env:USERPROFILE\.vpn\learned-routes.txt
route print -4 | Select-String '<the learned prefix>'
```

Expected: a `HKUVPN_ROUTE_ADDED <base>/24 <- <label>` marker, a matching
`base/24|<epoch>|<host>` line in `learned-routes.txt`, and a route for that
prefix on the tunnel interface.

The learned route is **persisted**, so the next session works immediately.
To forget it, delete `learned-routes.txt`.

---

## Step 8 — Stop and verify nothing is left behind

```powershell
powershell -ExecutionPolicy Bypass -File .\hkuvpn.ps1 --stop
```

Then confirm the host is clean:

```powershell
route print -4                      # campus routes gone; 0.0.0.0/0 still physical
Get-DnsClientNrptRule               # no rule with Comment = hkuvpn
Get-Process openconnect,gost -ErrorAction SilentlyContinue   # no output
```

Nothing else should have changed: no WSL, no Docker, no service, no scheduled
task. The only files the port creates are:

| Path | Content | Remove it? |
|---|---|---|
| `%TEMP%\hkuvpn\` | Logs, markers, pid list, state | Safe to delete any time |
| `%USERPROFILE%\.vpn\hku.env`, `hku.pass` | Your credentials | Keep (0600-style ACLs) |
| `%USERPROFILE%\.vpn\pin-hk.cache` | Cached certificate pin | Safe to delete |
| `%USERPROFILE%\.vpn\learned-routes.txt` | Learned routes | Safe to delete |

---

## Step 9 — Detached mode with `--mfa` (optional)

```powershell
# window 1: start in the background; it waits for the code
powershell -ExecutionPolicy Bypass -File .\hkuvpn.ps1 -d

# window 2: deliver the current code
powershell -ExecutionPolicy Bypass -File .\hkuvpn.ps1 --mfa 123456

# window 2: confirm
powershell -ExecutionPolicy Bypass -File .\hkuvpn.ps1 --status
```

`-d` never prompts; the code must be delivered separately. The worker waits
30 seconds for it and then exits (`HKUVPN_EXITED` in the marker log).

---

## Report template

Paste this back with the results if something fails:

```text
Windows build:      10.0.19045 / 11.x
PowerShell:         5.1.x
OpenConnect:        <output of `openconnect.exe --version`>
--check result:     <the red lines, if any>
--status result:    <output>   exit code: <n>
openconnect.log:    <lines around 'connect done' or the last error>
markers.log:        <full content>
route print -4:     <the 0.0.0.0/0 line and any campus entries>
```
