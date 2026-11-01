# Copy this file to ~/.config/fish/functions/hkuvpn.fish.
function hkuvpn --description 'HKU VPN client (hkuvpn)'
    set -l project_dir $HOME/hkuvpn
    if set -q HKUVPN_HOME
        set project_dir $HKUVPN_HOME
    else if set -q DOCKER_VPN_HOME
        set project_dir $DOCKER_VPN_HOME
    end
    "$project_dir/bin/hkuvpn" $argv
end
