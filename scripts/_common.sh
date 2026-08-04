#!/bin/bash

#=================================================
# COMMON VARIABLES AND CUSTOM HELPERS
#=================================================

turn_nginx_conf_path="/etc/nginx/conf.d/$turn_domain.d/$app.conf"

# Map a friendly LiveKit network mode (local|internet|both) to the
# underlying LiveKit rtc.use_external_ip / rtc.advertise_internal_ip booleans.
# Sets the global variables 'use_external_ip' and 'advertise_internal_ip',
# consumed by the livekit.yaml template.
livekit_network_mode_to_vars() {
    case "$1" in
        local)
            use_external_ip=false
            advertise_internal_ip=false
            ;;
        internet)
            use_external_ip=true
            advertise_internal_ip=false
            ;;
        both)
            use_external_ip=true
            advertise_internal_ip=true
            ;;
        *)
            ynh_die "Unknown LiveKit network mode: $1"
            ;;
    esac
}

# Detect the LiveKit network mode currently applied in an existing
# livekit.yaml, so that upgrading from a version before the
# 'livekit_network_mode' setting existed doesn't silently change the
# server's behaviour.
livekit_detect_network_mode() {
    local livekit_config="$install_dir/livekit/livekit.yaml"
    local current_use_external_ip="false"
    local current_advertise_internal_ip="false"

    if [ -e "$livekit_config" ]; then
        current_use_external_ip="$(ynh_read_var_in_file --file="$livekit_config" --key="use_external_ip")"
        current_advertise_internal_ip="$(ynh_read_var_in_file --file="$livekit_config" --key="advertise_internal_ip")"
        [ "$current_use_external_ip" == "YNH_NULL" ] && current_use_external_ip="false"
        [ "$current_advertise_internal_ip" == "YNH_NULL" ] && current_advertise_internal_ip="false"
    fi

    if [ "$current_use_external_ip" == "true" ] && [ "$current_advertise_internal_ip" == "true" ]; then
        echo "both"
    elif [ "$current_use_external_ip" == "true" ]; then
        echo "internet"
    else
        echo "local"
    fi
}

add_nginx_turn_config() {
    local finalnginxconf="${turn_nginx_conf_path}"
    ynh_config_add --template="nginx-turn.conf" --destination="$finalnginxconf"
    ynh_store_file_checksum "$finalnginxconf"
    ynh_systemctl --service=nginx --action=reload
}

setup_dex() {
    # List the Dex apps installed on the system
    dex_apps="$(yunohost app list -f --output-as json | jq -r '[ .apps[] | select(.manifest.id == "dex") ]')"
    dex="${dex:-dex}"

    # If there are no Dex app installed
    if [ $(jq -r '[ .[] | select(.manifest.id == "dex").id ] | length' <<< $dex_apps) -eq 0 ]
    then
        ynh_die "The apps needs at least one Dex instance to be installed. Install or restore one first."
    # Else if the configured Dex app is not in the list, default to the first one and display a warning
    elif [ $(jq --arg dex $dex -r '[ .[] | select(.id == $dex) ] | length' <<< $dex_apps) -ne 1 ]
    then
        dex="$(jq -r 'sort_by(.id) | first.id' <<< $dex_apps)"
        ynh_print_warn "The dex app was not set up, or the one initially set up for $app has not been found. Reconfiguring with $dex"
        ynh_app_setting_set --key=dex --value=$dex
    fi

    # Make sure that the Dex version is compatible
    dex_version=$(yunohost app info $dex --output-as json | jq -r '.version')
    if dpkg --compare-versions "${dex_version#v}" lt "2.42.1~ynh4"; then
        ynh_die "You need to upgrade $dex to v2.42.1~ynh4 and above first."
    fi

    # Prepare the variables
    dex_install_dir="$(ynh_app_setting_get --app $dex --key install_dir)"
    dex_domain="$(ynh_app_setting_get --app $dex --key domain)"
    dex_path="$(ynh_app_setting_get --app $dex --key path)"
    oidc_callback="https://$domain${path%/}/api/v1.0/callback/"

    # Create Dex URIs
    dex_domain_path="${dex_domain}${dex_path}"

    # Doc for the trick below:
    # https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html
    dex_domain_path_no_trailing_slash="${dex_domain_path%/}"

    dex_auth_uri="https://${dex_domain_path_no_trailing_slash}/auth"
    dex_token_uri="https://${dex_domain_path_no_trailing_slash}/token"
    dex_keys_uri="https://${dex_domain_path_no_trailing_slash}/keys"
    dex_user_uri="https://${dex_domain_path_no_trailing_slash}/userinfo"

    # Store the variables
    ynh_app_setting_set         --key=dex_install_dir       --value="$dex_install_dir"
    ynh_app_setting_set         --key=dex_user_uri          --value="$dex_user_uri"
    ynh_app_setting_set         --key=dex_auth_uri          --value="$dex_auth_uri"
    ynh_app_setting_set         --key=dex_keys_uri          --value="$dex_keys_uri"
    ynh_app_setting_set         --key=dex_token_uri         --value="$dex_token_uri"
    ynh_app_setting_set_default --key=oidc_name             --value="$app"
    ynh_app_setting_set         --key=oidc_callback         --value="$oidc_callback"
    ynh_app_setting_set_default --key=oidc_secret           --value="$(ynh_string_random --length=32 --filter='A-F0-9')"

    # Add the configuration file for the app in Dex
    bash "$dex_install_dir/add_config.sh" $app $oidc_name $oidc_callback $oidc_secret
}
