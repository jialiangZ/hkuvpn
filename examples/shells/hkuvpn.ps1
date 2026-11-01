# hkuvpn PowerShell wrapper for Windows hosts.
#
# Install:
#   1. Save this file anywhere on Windows (e.g. $HOME\hkuvpn-win\hkuvpn.ps1)
#   2. Add to your PowerShell profile (notepad $PROFILE):
#        . "$HOME\hkuvpn-win\hkuvpn.ps1"
#
# Requires the hkuvpn repo at ~/hkuvpn inside the WSL distro and ncat
# (nmap package) for the SSH example. Interactive MFA entry works because
# wsl.exe forwards the terminal.

$HkuvpnDistro  = "Ubuntu"                  # list with: wsl.exe -l -v
$HkuvpnCommand = "~/hkuvpn/docker/bin/hkuvpn" # path inside the distro

function hkuvpn {
    wsl.exe --distribution $HkuvpnDistro -- $HkuvpnCommand @args
}

function hku-status { hkuvpn --status }
function hku-stop   { hkuvpn --stop }

# Usage from Windows:
#   hkuvpn                 # smart connect: prompts for the MFA code, waits for the tunnel
#   hkuvpn                 # run again while connected: reports status
#   hkuvpn -f              # classic foreground connect
#   hkuvpn -d              # background; deliver the code with 'hkuvpn --mfa 123456'
#   hkuvpn --check         # pre-flight only (docker/config/PIN/image/ports/clock)
#   hku-status             # layered health check
#                          # $LASTEXITCODE: 0 ok, 1 docker, 2 container,
#                          # 3 tunnel, 4 proxy, 5 end-to-end
#   hkuvpn --logs          # follow the container logs
#   hku-stop
