# Source this file from ~/.zshrc or ~/.bashrc.
hkuvpn() {
    local project_dir="${HKUVPN_HOME:-${DOCKER_VPN_HOME:-$HOME/hkuvpn}}"
    local launcher="$project_dir/docker/bin/hkuvpn"
    # Fall back to the pre-v1.1 layout (launcher at the repository root).
    [[ -x "$launcher" ]] || launcher="$project_dir/bin/hkuvpn"
    "$launcher" "$@"
}
