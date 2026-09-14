# Docker-VPN guide

[← README](../Readme.md) · [简体中文](guide.zh-CN.md)

- [Everyday use](#everyday-use)
- [Proxy clients](#add-a-rules-client)
- [SSH and remote desktop](#ssh-and-remote-desktop)
- [Reverse SSH](#reverse-ssh-for-a-campus-computer)
- [Troubleshooting](#troubleshooting)
- [Security and reference](#security)

## Everyday use

### Install the Short `hkuvpn` Command

[Quick Start](../Readme.md#quick-start) calls `~/docker-vpn/bin/hkuvpn` directly. For everyday use, install
the shorter `hkuvpn` command for your shell.

Zsh:

```bash
printf '\nsource ~/docker-vpn/examples/hkuvpn.zsh\n' >> ~/.zshrc
source ~/.zshrc
```

Bash:

```bash
printf '\nsource ~/docker-vpn/examples/hkuvpn.zsh\n' >> ~/.bashrc
source ~/.bashrc
```

Fish:

```fish
mkdir -p ~/.config/fish/functions
cp ~/docker-vpn/examples/hkuvpn.fish ~/.config/fish/functions/hkuvpn.fish
fish -n ~/.config/fish/functions/hkuvpn.fish
```

Do not paste the Zsh function into Fish. Fish does not use `export`,
`VAR=value command`, POSIX `case`, or POSIX function syntax.

If the clone is elsewhere, set `DOCKER_VPN_HOME`:

```bash
export DOCKER_VPN_HOME=/path/to/docker-vpn        # Zsh/Bash
```

```fish
set -Ux DOCKER_VPN_HOME /path/to/docker-vpn      # Fish
```

### Daily Commands

```bash
hkuvpn              # connect to the official vpn2fa.hku.hk server
hkuvpn --status
hkuvpn --stop
hkuvpn --recover    # repair Docker/Colima only; does not request MFA
```

At `Response:`, enter the current six-digit Authenticator code. Keep the
terminal open while using the proxies. `Ctrl+C` stops the foreground container.

All locations use `vpn2fa.hku.hk`. The older `hkuvpn hk` command and
`HKU_ENDPOINT=hk` setting remain accepted for compatibility, but they select
the same official service. If certificate retrieval or TLS fails, inspect the
route selected by your existing proxy client; from mainland China, retrying
later or using another permitted Internet connection may help.

### Use a Proxy Directly

Quick checks from a second terminal:

```bash
curl -x socks5h://127.0.0.1:1080 -I https://www.hku.hk/
curl -x http://127.0.0.1:1088 -I https://www.hku.hk/
```

Use `socks5h`, not `socks5`, when DNS should also be resolved through the proxy.
The published Docker ports are TCP; do not advertise this setup as a general UDP
proxy.

Per-command proxy examples:

```bash
ALL_PROXY=socks5h://127.0.0.1:1080 curl https://lib.hku.hk/   # Zsh/Bash
```

```fish
env ALL_PROXY=socks5h://127.0.0.1:1080 curl https://lib.hku.hk/
# Or limit a variable to the current Fish block:
begin
    set -lx ALL_PROXY socks5h://127.0.0.1:1080
    curl https://lib.hku.hk/
end
```

Change host ports in `~/.vpn/hku.env` if they conflict:

```ini
HKU_SOCKS_PORT=11080
HKU_HTTP_PORT=11088
```

### Add a Rules Client

Docker-VPN only provides the local HKU upstream. A rules client is optional and
may be Clash Verge Rev, Surge, sing-box, Quantumult X, Loon, or another client
that supports a local SOCKS5/HTTP outbound and ordered rules. Start `hkuvpn` and
confirm that `1080/1088` are listening before enabling these entries.

Every client must preserve the same order:

1. Keep the HKU VPN control endpoint outside the local HKU upstream. Otherwise
   the connection tries to enter its own tunnel before that tunnel exists.
2. Send only exact campus subnets and HKU services to the HKU policy.
3. Leave all non-HKU rules and the final rule under the existing profile.

#### Clash Verge Rev / Mihomo

Clash Verge Rev uses the Mihomo core and supports Merge configurations. Create
a Merge/extension configuration for the active profile, add the contents of
[examples/clash-verge.yaml](../examples/clash-verge.yaml), then re-enable that
configuration after editing it. Do not edit the downloaded subscription file;
subscription refreshes may replace it. See the official
[Clash Verge Rev Merge guide](https://clashvergerev.com/en/guide/merge) and
[Mihomo SOCKS](https://wiki.metacubex.one/en/config/proxies/socks/) and
[HTTP](https://wiki.metacubex.one/en/config/proxies/http/) outbound syntax.

The minimal Merge configuration is:

```yaml
prepend-proxies:
  - name: HKU-SOCKS5
    type: socks5
    server: 127.0.0.1
    port: 1080
    udp: false
  - name: HKU-HTTP
    type: http
    server: 127.0.0.1
    port: 1088

prepend-proxy-groups:
  - name: HKU
    type: select
    proxies: [HKU-SOCKS5, HKU-HTTP, DIRECT]
  - name: HKU-CONTROL
    type: select
    proxies: [DIRECT]

prepend-rules:
  - DOMAIN,vpn2fa.hku.hk,HKU-CONTROL
  - DOMAIN,vpn2fa-a.hku.hk,HKU-CONTROL
  - DOMAIN,vpn2fa-b.hku.hk,HKU-CONTROL
  # - IP-CIDR,192.0.2.0/24,HKU,no-resolve
  - DOMAIN-SUFFIX,hku.hk,HKU
  - DOMAIN-SUFFIX,hku.edu.hk,HKU
```

`prepend-rules` is important because rules inserted after an existing `MATCH`
rule never run. The commented `192.0.2.0/24` entry is TEST-NET-1 documentation
space; replace it with the smallest campus subnet you actually need before
enabling it. If the official HKUVPN server is not directly reachable, add the
exact name of a working existing policy to `HKU-CONTROL`.

#### Surge

Merge [examples/surge.conf](../examples/surge.conf) into the existing profile; do
not replace the whole profile. The equivalent minimal fragment is:

```ini
[Proxy]
HKU-SOCKS5 = socks5, 127.0.0.1, 1080
HKU-HTTP = http, 127.0.0.1, 1088

[Proxy Group]
HKU = select, HKU-SOCKS5, HKU-HTTP, EXISTING-PROXY, DIRECT
HKU-CONTROL = select, DIRECT, EXISTING-PROXY

[Rule]
DOMAIN,vpn2fa.hku.hk,HKU-CONTROL
DOMAIN,vpn2fa-a.hku.hk,HKU-CONTROL
DOMAIN,vpn2fa-b.hku.hk,HKU-CONTROL
# IP-CIDR,<exact-campus-subnet>,HKU,no-resolve
DOMAIN-SUFFIX,hku.hk,HKU
DOMAIN-SUFFIX,hku.edu.hk,HKU
```

Replace `EXISTING-PROXY` with the exact policy-group name from the current
profile. Choose `DIRECT` in `HKU-CONTROL` when the official server is directly
reachable; choose the existing policy only when that route is required and
works. Never select `HKU-SOCKS5` or `HKU-HTTP` for the control group. Do not
replace the commented campus example with all of `10.0.0.0/8`: home, office,
and container networks commonly use that RFC 1918 range.

## Remote Access

### SSH and Remote Desktop

For a campus host that is reachable only through HKU, merge and edit
[examples/ssh_config.example](../examples/ssh_config.example). The address
`192.0.2.10` below belongs to RFC 5737 TEST-NET-1 and cannot be a real campus
host; replace it with the exact IP assigned to the computer you use.

```sshconfig
Host campus-host
  HostName 192.0.2.10
  User yourname
  ProxyCommand nc -X 5 -x 127.0.0.1:1080 %h %p
  ServerAliveInterval 30
  ServerAliveCountMax 3
```

Then connect normally:

```bash
ssh campus-host
```

For remote desktop, route the exact campus destination IP through the HKU group
in the rules client's TUN/enhanced mode, or use a remote-desktop client with
SOCKS support. A process-name rule is optional and platform-specific; an exact
destination rule is more predictable.

### Reverse SSH for a Campus Computer

This is useful when a coding agent runs on a school computer but your paid proxy
subscription is usable only from the mainland client where the rules client is
running.

#### Traffic Direction

![Reverse SSH proxy path from a campus coding agent to the client proxy](images/reverse-proxy-flow-en.png)

Although the option is named `RemoteForward`, the SSH control connection still
starts on the client. `-R` creates a listener on the remote computer and carries
each accepted connection back to a destination visible from the client.

#### One-Time SSH Configuration

```sshconfig
Host campus-host-tunnel
  HostName 192.0.2.10
  User yourname
  ProxyCommand nc -X 5 -x 127.0.0.1:1080 %h %p
  RemoteForward 127.0.0.1:8152 127.0.0.1:6152
  ExitOnForwardFailure yes
  ServerAliveInterval 30
  ServerAliveCountMax 3
```

The explicit remote `127.0.0.1` bind is intentional. OpenSSH also binds remote
forwarding to loopback by default, but writing it explicitly prevents this proxy
from becoming a campus-wide open proxy if server settings later change.

Start and verify:

```bash
ssh -N campus-host-tunnel
ssh campus-host 'curl -x http://127.0.0.1:8152 -I https://www.apple.com/'
```

On the remote computer, scope proxy variables to the agent when possible:

```bash
HTTP_PROXY=http://127.0.0.1:8152 \
HTTPS_PROXY=http://127.0.0.1:8152 \
NO_PROXY=localhost,127.0.0.1 \
codex
```

Fish equivalent:

```fish
begin
    set -lx HTTP_PROXY http://127.0.0.1:8152
    set -lx HTTPS_PROXY http://127.0.0.1:8152
    set -lx NO_PROXY localhost,127.0.0.1
    codex
end
```

Browser-only ChatGPT or Claude usage normally belongs on the local browser and
does not require remote forwarding. Use the tunnel when the process itself runs
on the campus computer, as with remote Codex, Copilot, package managers, or Git.

#### Keep the Tunnel Alive

```bash
brew install autossh
autossh -M 0 -N campus-host-tunnel
```

`-M 0` uses OpenSSH's own keepalives from the host block. For unattended macOS
use, place that command in a user LaunchAgent. A running `autossh` process is not
proof that the forward is healthy; verify remote `127.0.0.1:8152` with `curl`.

This design does not help if the SSH client and proxy client are also in Hong
Kong while the subscription accepts connections only from mainland China. The
proxy ingress remains the machine running port `6152`. In that topology, run the
proxy client on a reachable mainland machine/VPS or buy a supported ingress.

## Operations and Troubleshooting

### Advanced Reliability

#### OpenConnect Reconnects

The entrypoint uses verbose timestamps and a 30-minute reconnect window. Recent
failures can still end with `CSTP Dead Peer Detection detected dead peer`, TLS
read errors, `Host is unreachable`, or a rejected cookie.

A `401 Unauthorized`, a rejected cookie, or a TLS failure after the initial
redirect can mean that DNS selected a different HKU backend. Advanced users
can pin the entry point and both official redirect backends for the session:

```ini
HKU_RESOLVE=vpn2fa.hku.hk:REAL_IP,vpn2fa-a.hku.hk:REAL_IP,vpn2fa-b.hku.hk:REAL_IP
```

Use only IPs learned from real DNS or the proxy client's real DNS cache. Do not
use `198.18.0.0/15` fake-IP results from enhanced mode. The container entrypoint
expands the comma-separated mappings into separate `--resolve` entries. Re-check every address
when HKU changes infrastructure; a stale pin prevents connection.

#### Colima Recovery Levels

1. `docker info`: verify the host socket, not only `colima status`.
2. `hkuvpn --recover`: start/restart Colima without requesting a new MFA code.
3. `colima ssh -- docker info`: distinguish a healthy guest daemon from broken
   host socket forwarding.
4. Inspect `~/.colima/_lima/colima/ha.stderr.log` for VZ or disk-attachment
   failures.
5. Use `colima stop --force` only when the control plane is stuck. macOS may need
   one or more minutes to release the VZ disk before a restart succeeds.

Deleting the Colima VM is a last resort because it removes local images and
containers. It is not the first troubleshooting command.

#### Rules-Client Independence

Client-specific automatic reload and policy switching are intentionally not in
the portable launcher. Users of any rules client, or no rules client, must still
be able to use Docker-VPN. If you automate a client, keep these rules:

- On HKU tunnel failure, move HKU traffic to an explicit fallback such as
  `DIRECT` or an existing Hong Kong route.
- Never send `vpn2fa.hku.hk`, `vpn2fa-a.hku.hk`, or `vpn2fa-b.hku.hk` into
  `HKU-SOCKS5`.
- Restore the HKU group only after the local `1080/1088` listener and tunnel are
  confirmed healthy.

### Troubleshooting

#### No tmux/Terminal Session Remains

Check Docker first. A launcher can exit before the VPN prompt if the Colima host
socket is unavailable:

```bash
docker info
colima status
hkuvpn --recover
```

#### Certificate Retrieval Fails

Check that `vpn2fa.hku.hk` and its `vpn2fa-a` / `vpn2fa-b` redirect backends use
the control policy rather than the local HKU proxy. After verifying the servers
and routes, remove only the certificate cache:

```bash
rm ~/.vpn/pin-hk.cache
```

#### Port Already in Use

```bash
lsof -nP -iTCP:1080 -sTCP:LISTEN
```

Select different host ports in `~/.vpn/hku.env` and update the proxy-client
entries to match.

#### Container Is Running but a Service Fails

Test each layer separately:

```bash
docker ps --filter name=vpn-hku
hkuvpn --status
curl -x socks5h://127.0.0.1:1080 -I https://www.hku.hk/
ssh -G campus-host | grep -E 'proxycommand|hostname|port'
```

Do not treat `autossh` or `colima status` alone as an end-to-end health check.

### Security

- Proxies bind to host loopback only. Do not publish them on `0.0.0.0` without
  authentication and a firewall.
- Reverse forwarding also binds to remote loopback only. Do not enable
  `GatewayPorts yes` for this use case.
- `~/.vpn/hku.pass` is plaintext. Set mode `600` and enable disk encryption.
- Docker environment variables can be inspected by a user with Docker access.
  Treat Docker access as privileged.
- The container needs `NET_ADMIN` and `/dev/net/tun`. Review changes before
  rebuilding and do not use untrusted images.
- Keep private hostnames, campus IPs, account names, certificate caches, logs,
  subscription URLs, and SSH keys out of issues and commits.

## Project Reference

### How It Works

1. Run `hkuvpn` first. The container establishes the OpenConnect tunnel and
   exposes the loopback SOCKS5 and HTTP listeners.
2. After the listeners are ready, enter one of those addresses in an
   application, SSH configuration, browser, or optional rules client.
3. During use, requests selected by that configuration reach `1080` or `1088`,
   enter the container, and travel through the HKU AnyConnect tunnel.
4. A rules client can simultaneously send every non-HKU request to `DIRECT`, an
   existing proxy or VPN, or another policy. Those paths do not pass through
   Docker-VPN unless the user explicitly selects the HKU upstream for them.

Cisco AnyConnect is the server protocol in this design. The official Cisco
desktop client is not started for this connection; OpenConnect runs inside the
container so it cannot replace the host default route.

### Compatibility and Versions

| Area | Current support |
|---|---|
| macOS container runtime | Colima or Docker Desktop |
| Linux container runtime | Docker Engine |
| Windows | Docker Desktop with WSL2; community-tested |
| Shell | Zsh, Bash, and Fish |
| Rule-based proxy clients | Clash Verge Rev/Mihomo and Surge examples included; the same routing model applies to sing-box and similar clients |
| OpenConnect in the current `alpine:3.23` image | 9.21 |

OpenConnect runs inside the image, so a Homebrew OpenConnect installation on the
host is not used. Because Alpine 3.23 still packages an older release, the
Dockerfile builds OpenConnect 9.21 from the official release tarball. The build
checks both the pinned SHA-256 digest and the upstream PGP signature against the
documented OpenConnect release-key fingerprint before compiling. Check the
[official OpenConnect releases](https://gitlab.com/openconnect/openconnect/-/releases)
when investigating version-specific behavior or preparing a version bump.

Confirm the version actually installed in a locally built image:

```bash
docker run --rm --entrypoint openconnect local/vpn --version
```

### Portable Core and Optional Automation

The launcher, shell wrappers, routing examples, and container entrypoint are the
portable core of Docker-VPN. They do not require a rules client, tmux, or a
particular terminal application.

Users who need unattended or long-running operation can add proxy-client CLI
automation, tmux monitoring, system services such as a macOS LaunchAgent, and
diagnostic logs under `~/.vpn/logs/`. These integrations should remain optional
and machine-specific so the basic HKU proxy continues to work with other proxy
clients and Docker environments.

### Credits and Licensing

Derived from [ethack/docker-vpn](https://github.com/ethack/docker-vpn) and
adapted for HKU, OpenConnect MFA, and loopback proxy export.

This repository currently has no explicit `LICENSE` file. Do not assume that a
fork automatically grants a license. The maintainer should select a compatible
license and add the complete license text before inviting redistribution or
outside contributions.
