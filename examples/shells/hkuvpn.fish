function hkuvpn --description 'HKU VPN client (hkuvpn)'
    set -l project_dir $HOME/hkuvpn
    if set -q HKUVPN_HOME
        set project_dir $HKUVPN_HOME
    else if set -q DOCKER_VPN_HOME
        set project_dir $DOCKER_VPN_HOME
    end
    set -l launcher $project_dir/docker/bin/hkuvpn
    # Fall back to the pre-v1.1 layout (launcher at the repository root).
    if not test -x $launcher
        set launcher $project_dir/bin/hkuvpn
    end
    "$launcher" $argv
end
