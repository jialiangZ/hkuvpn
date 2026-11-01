# Source this file from ~/.zshrc or ~/.bashrc.
#
# The launcher is located relative to THIS file, so the repository can live
# anywhere (HKUVPN_HOME, or the legacy DOCKER_VPN_HOME, still override it).
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    __hkuvpn_src="${BASH_SOURCE[0]}"
else
    __hkuvpn_src="$0"
fi
__hkuvpn_root="$(cd -- "$(dirname -- "$__hkuvpn_src")/../.." 2>/dev/null && pwd)"

hkuvpn() {
    local project_dir="${HKUVPN_HOME:-${DOCKER_VPN_HOME:-${__hkuvpn_root:-$HOME/hkuvpn}}}"
    local launcher="$project_dir/docker/bin/hkuvpn"
    # Fall back to the pre-v1.1 layout (launcher at the repository root).
    [ -x "$launcher" ] || launcher="$project_dir/bin/hkuvpn"
    "$launcher" "$@"
}
