#!/bin/bash
# =============================================================================
# -- Compare Commands
# =============================================================================

# ======================================
# -- _gp_profile_select
# -- Prompt user to select a profile from available options
# ======================================
function _gp_profile_select () {
    # Source the .gridpane file
    source "$TOKEN_FILE" 2>/dev/null || { _error "Cannot read $TOKEN_FILE"; return 1; }
    
    # Get all variables from the .gridpane starting with GPBC_TOKEN_
    local -a GP_TOKEN_VAR=($(cat "$TOKEN_FILE" | grep '^GPBC_TOKEN_' | cut -d= -f1))
    
    if [[ -z "${GP_TOKEN_VAR[*]}" ]]; then
        _error "No GPBC_TOKEN profiles found in $TOKEN_FILE"
        return 1
    fi
    
    # If only one profile available, use it
    if [[ ${#GP_TOKEN_VAR[@]} -eq 1 ]]; then
        echo "${GP_TOKEN_VAR[0]#GPBC_TOKEN_}"
        return 0
    fi
    
    # Present menu to select - output all to stderr for visibility
    {
        _loading2 "Available profiles:"
        echo
        local i=1
        for profile_var in "${GP_TOKEN_VAR[@]}"; do
            local profile_name="${profile_var#GPBC_TOKEN_}"
            echo "  $i) $profile_name"
            ((i++))
        done
        echo
    } >&2
    
    read -p "Select profile (1-${#GP_TOKEN_VAR[@]}): " selection
    
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -lt 1 ]] || [[ "$selection" -gt ${#GP_TOKEN_VAR[@]} ]]; then
        _error "Invalid selection" >&2
        return 1
    fi
    
    local selected_idx=$((selection - 1))
    local selected_var="${GP_TOKEN_VAR[$selected_idx]}"
    echo "${selected_var#GPBC_TOKEN_}"
    return 0
}

# ======================================
# -- _gp_api_compare_sites $DOMAIN $PROFILE1 $PROFILE2
# -- Compare site settings across two profiles
# ======================================
function _gp_api_compare_sites () {
    local DOMAIN="$1"
    local PROFILE1="$2"
    local PROFILE2="$3"
    
    # Prompt for domain if not provided
    if [[ -z "$DOMAIN" ]]; then
        read -p "Enter domain to compare: " DOMAIN
        if [[ -z "$DOMAIN" ]]; then
            _error "Domain is required"
            return 1
        fi
    fi
    
    # Prompt for profile 1 if not provided
    if [[ -z "$PROFILE1" ]]; then
        echo
        _loading2 "Select first profile:"
        PROFILE1=$(_gp_profile_select) || return 1
    fi
    
    # Prompt for profile 2 if not provided
    if [[ -z "$PROFILE2" ]]; then
        echo
        _loading2 "Select second profile:"
        PROFILE2=$(_gp_profile_select) || return 1
    fi
    
    _loading "Comparing site: $DOMAIN between profiles $PROFILE1 and $PROFILE2"
    echo
    
    # Save current profile
    local saved_token="$GPBC_TOKEN"
    local saved_token_name="$GPBC_TOKEN_NAME"
    
    # Get site data from profile 1
    _gp_set_profile_silent "$PROFILE1" 2>/dev/null || { _error "Profile not found: $PROFILE1"; GPBC_TOKEN="$saved_token"; GPBC_TOKEN_NAME="$saved_token_name"; return 1; }
    local site1_cache="${CACHE_DIR}/${PROFILE1}_site.json"
    
    if [[ ! -f "$site1_cache" ]]; then
        _error "Cache not found for profile $PROFILE1. Run: ./gp-api.sh -p $PROFILE1 -c cache-sites"
        GPBC_TOKEN="$saved_token"
        GPBC_TOKEN_NAME="$saved_token_name"
        return 1
    fi
    
    local site1_data
    site1_data=$(jq --arg domain "$DOMAIN" '.[] | select(.url == $domain) | .' "$site1_cache" 2>/dev/null)
    
    if [[ -z "$site1_data" || "$site1_data" == "null" ]]; then
        _error "Domain not found in profile $PROFILE1: $DOMAIN"
        GPBC_TOKEN="$saved_token"
        GPBC_TOKEN_NAME="$saved_token_name"
        return 1
    fi
    
    # Get site data from profile 2
    _gp_set_profile_silent "$PROFILE2" 2>/dev/null || { _error "Profile not found: $PROFILE2"; GPBC_TOKEN="$saved_token"; GPBC_TOKEN_NAME="$saved_token_name"; return 1; }
    local site2_cache="${CACHE_DIR}/${PROFILE2}_site.json"
    
    if [[ ! -f "$site2_cache" ]]; then
        _error "Cache not found for profile $PROFILE2. Run: ./gp-api.sh -p $PROFILE2 -c cache-sites"
        GPBC_TOKEN="$saved_token"
        GPBC_TOKEN_NAME="$saved_token_name"
        return 1
    fi
    
    local site2_data
    site2_data=$(jq --arg domain "$DOMAIN" '.[] | select(.url == $domain) | .' "$site2_cache" 2>/dev/null)
    
    if [[ -z "$site2_data" || "$site2_data" == "null" ]]; then
        _error "Domain not found in profile $PROFILE2: $DOMAIN"
        GPBC_TOKEN="$saved_token"
        GPBC_TOKEN_NAME="$saved_token_name"
        return 1
    fi
    
    # Restore original profile
    GPBC_TOKEN="$saved_token"
    GPBC_TOKEN_NAME="$saved_token_name"
    
    # Display comparison header
    printf "\n%-30s %-45s %-45s\n" "Setting" "$PROFILE1" "$PROFILE2"
    printf "%-30s %-45s %-45s\n" "$(printf '=%.0s' {1..29})" "$(printf '=%.0s' {1..44})" "$(printf '=%.0s' {1..44})"
    
    # Compare key fields
    local fields=(id url server_id php_version is_ssl ssl_status www root multisites nginx_caching pm_mode pm_max_children pm_start_servers pm_min_spare_servers pm_max_spare_servers pm_process_idle_timeout user_id system_userid)
    
    for field in "${fields[@]}"; do
        local val1 val2 marker
        val1=$(echo "$site1_data" | jq -r ".$field // \"N/A\"" 2>/dev/null)
        val2=$(echo "$site2_data" | jq -r ".$field // \"N/A\"" 2>/dev/null)
        
        # Add marker if values differ
        marker=" "
        if [[ "$val1" != "$val2" ]]; then
            marker="⚠"
        fi
        
        printf "%s %-28s %-45s %-45s\n" "$marker" "$field" "$val1" "$val2"
    done
    
    echo
    _success "Site comparison completed"
    return 0
}
# ======================================
# -- _gp_api_compare_sites_major $DOMAIN $PROFILE1 $PROFILE2
# -- Compare major site settings across two profiles (ignores id, server_id, user_id, system_userid, url, is_ssl, ssl_status, www, root)
# ======================================
function _gp_api_compare_sites_major () {
    local DOMAIN="$1"
    local PROFILE1="$2"
    local PROFILE2="$3"
    
    # Prompt for domain if not provided
    if [[ -z "$DOMAIN" ]]; then
        read -p "Enter domain to compare: " DOMAIN
        if [[ -z "$DOMAIN" ]]; then
            _error "Domain is required"
            return 1
        fi
    fi
    
    # Prompt for profile 1 if not provided
    if [[ -z "$PROFILE1" ]]; then
        echo
        _loading2 "Select first profile:"
        PROFILE1=$(_gp_profile_select) || return 1
    fi
    
    # Prompt for profile 2 if not provided
    if [[ -z "$PROFILE2" ]]; then
        echo
        _loading2 "Select second profile:"
        PROFILE2=$(_gp_profile_select) || return 1
    fi
    
    _loading "Comparing major site settings: $DOMAIN between profiles $PROFILE1 and $PROFILE2"
    echo
    
    # Save current profile
    local saved_token="$GPBC_TOKEN"
    local saved_token_name="$GPBC_TOKEN_NAME"
    
    # Get site data from profile 1
    _gp_set_profile_silent "$PROFILE1" 2>/dev/null || { _error "Profile not found: $PROFILE1"; GPBC_TOKEN="$saved_token"; GPBC_TOKEN_NAME="$saved_token_name"; return 1; }
    local site1_cache="${CACHE_DIR}/${PROFILE1}_site.json"
    
    if [[ ! -f "$site1_cache" ]]; then
        _error "Cache not found for profile $PROFILE1. Run: ./gp-api.sh -p $PROFILE1 -c cache-sites"
        GPBC_TOKEN="$saved_token"
        GPBC_TOKEN_NAME="$saved_token_name"
        return 1
    fi
    
    local site1_data
    site1_data=$(jq --arg domain "$DOMAIN" '.[] | select(.url == $domain) | .' "$site1_cache" 2>/dev/null)
    
    if [[ -z "$site1_data" || "$site1_data" == "null" ]]; then
        _error "Domain not found in profile $PROFILE1: $DOMAIN"
        GPBC_TOKEN="$saved_token"
        GPBC_TOKEN_NAME="$saved_token_name"
        return 1
    fi
    
    # Get site data from profile 2
    _gp_set_profile_silent "$PROFILE2" 2>/dev/null || { _error "Profile not found: $PROFILE2"; GPBC_TOKEN="$saved_token"; GPBC_TOKEN_NAME="$saved_token_name"; return 1; }
    local site2_cache="${CACHE_DIR}/${PROFILE2}_site.json"
    
    if [[ ! -f "$site2_cache" ]]; then
        _error "Cache not found for profile $PROFILE2. Run: ./gp-api.sh -p $PROFILE2 -c cache-sites"
        GPBC_TOKEN="$saved_token"
        GPBC_TOKEN_NAME="$saved_token_name"
        return 1
    fi
    
    local site2_data
    site2_data=$(jq --arg domain "$DOMAIN" '.[] | select(.url == $domain) | .' "$site2_cache" 2>/dev/null)
    
    if [[ -z "$site2_data" || "$site2_data" == "null" ]]; then
        _error "Domain not found in profile $PROFILE2: $DOMAIN"
        GPBC_TOKEN="$saved_token"
        GPBC_TOKEN_NAME="$saved_token_name"
        return 1
    fi
    
    # Restore original profile
    GPBC_TOKEN="$saved_token"
    GPBC_TOKEN_NAME="$saved_token_name"
    
    # Display comparison header
    printf "\n%-30s %-45s %-45s\n" "Setting" "$PROFILE1" "$PROFILE2"
    printf "%-30s %-45s %-45s\n" "$(printf '=%.0s' {1..29})" "$(printf '=%.0s' {1..44})" "$(printf '=%.0s' {1..44})"
    
    # Compare major fields only (excluding id, server_id, user_id, system_userid, url, is_ssl, ssl_status, www, root)
    local fields=(php_version multisites nginx_caching pm_mode pm_max_children pm_start_servers pm_min_spare_servers pm_max_spare_servers pm_process_idle_timeout)
    
    for field in "${fields[@]}"; do
        local val1 val2 marker
        val1=$(echo "$site1_data" | jq -r ".$field // \"N/A\"" 2>/dev/null)
        val2=$(echo "$site2_data" | jq -r ".$field // \"N/A\"" 2>/dev/null)
        
        # Add marker if values differ
        marker=" "
        if [[ "$val1" != "$val2" ]]; then
            marker="⚠"
        fi
        
        printf "%s %-28s %-45s %-45s\n" "$marker" "$field" "$val1" "$val2"
    done
    
    echo
    _success "Site comparison completed"
    return 0
}