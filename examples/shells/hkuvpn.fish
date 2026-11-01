# Source or copy this file to ~/.config/fish/functions/hkuvpn.fish.
#
# When it is sourced from the repository, the launcher is located relative to
# THIS file, so the repository can live anywhere. When it is copied into
# ~/.config/fish/functions, set HKUVPN_HOME (or keep the default ~/hkuvpn).
set -g __hkuvpn_file (status --current-filename 2>/dev/null)
set -g __hkuvpn_root ""
if test -n "$__hkuvpn_file"
    set -l root (realpath (dirname $__hkuvpn_file)/../.. 2>/dev/null)
    if test -f "$root/docker/bin/hkuvpn"
        set -g __hkuvpn_root $root
    end
end

function hkuvpn --description 'HKU VPN client (hkuvpn)'
    set -l project_dir $HOME/hkuvpn
    if set -q HKUVPN_HOME
        set project_dir $HKUVPN_HOME
    else if set -q DOCKER_VPN_HOME
        set project_dir $DOCKER_VPN_HOME
    else if test -n "$__hkuvpn_root"
        set project_dir $__hkuvpn_root
    end
    set -l launcher $project_dir/docker/bin/hkuvpn
    # Fall back to the pre-v1.1 layout (launcher at the repository root).
    if not test -x $launcher
        set launcher $project_dir/bin/hkuvpn
    end
    "$launcher" $argv
end
