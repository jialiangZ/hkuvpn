# Source this file from ~/.zshrc or ~/.bashrc.
hkuvpn() {
    "${HKUVPN_HOME:-${DOCKER_VPN_HOME:-$HOME/hkuvpn}}/bin/hkuvpn" "$@"
}
