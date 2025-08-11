#!/bin/bash
# =============================================================================
# -- gp-inc.sh --------------------------------------------------------------
# =============================================================================
echo "Loaded gp-inc.sh"
# =====================================
# -- Core Functions
# =====================================
_debugf() { [[ $DEBUG == "1" ]] && echo -e "\e[1;36m*DEBUG* ${@}\e[0m"; }
_debug_file () { [[ $DEBUG == "1" ]] && echo "$@" >> debug.log; }
_error() { echo -e "\e[1;31m$1\e[0m"; }
_warning() { echo -e "\e[1;33m⚠️  Warning: $1\e[0m"; }
_success () { echo -e "\e[1;32m$1\e[0m"; }
# -- Bright yellow background black text
_loading () { echo -e "\e[1;33m\e[7m$1\e[0m"; }
# -- Blue background white text
_loading2 () { echo -e "\e[1;34m\e[7m$1\e[0m"; }
# -- Dark grey text
_loading3 () { echo -e "\e[1;30m$1\e[0m"; }

# =====================================
# -- Helper Functions
# =====================================
# Function to format cache age in human-readable format
_format_cache_age() {
    local age_seconds="$1"
    
    if [[ $age_seconds -lt 60 ]]; then
        echo "${age_seconds} seconds"
    elif [[ $age_seconds -lt 3600 ]]; then
        local minutes=$((age_seconds / 60))
        echo "${minutes} minute(s)"
    elif [[ $age_seconds -lt 86400 ]]; then
        local hours=$((age_seconds / 3600))
        echo "${hours} hour(s)"
    else
        local days=$((age_seconds / 86400))
        echo "${days} day(s)"
    fi
}

# Function to check cache with detailed age info and option to use old cache
_check_cache_with_options() {
    local cache_file="$1"
    local cache_type="${2:-sites}"
    local cache_function="cache-${cache_type}"
    
    if [[ ! -f "$cache_file" ]]; then
        _warning "Cache not found for ${cache_type}."
        echo
        read -p "Would you like to run '${cache_function}' to populate the cache? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            _loading "Running ${cache_function} to populate cache..."
            case "$cache_type" in
                "sites")
                    _gp_api_cache_sites
                    ;;
                "servers")
                    _gp_api_cache_servers
                    ;;
                *)
                    _error "Unknown cache type: ${cache_type}"
                    return 1
                    ;;
            esac
            
            local cache_result=$?
            if [[ $cache_result -eq 0 ]]; then
                # Verify the cache file was actually created
                if [[ -f "$cache_file" ]]; then
                    _success "Cache populated successfully."
                    return 0
                else
                    _error "Cache function succeeded but cache file was not created: $cache_file"
                    return 1
                fi
            else
                _error "Failed to populate cache (exit code: $cache_result)"
                return 1
            fi
        else
            _error "Cache is required. Please run '${cache_function}' first to populate the cache."
            return 1
        fi
    fi
    
    # Cache file exists, check its age
    local cache_age=$(($(date +%s) - $(stat -c %Y "$cache_file")))
    local age_formatted=$(_format_cache_age $cache_age)
    
    # If cache is fresh (less than 1 hour), use it
    if [[ $cache_age -lt 3600 ]]; then
        _success "Cache is fresh (${age_formatted} old)."
        return 0
    fi
    
    # Cache is stale, give options
    _warning "Cache is ${age_formatted} old (considered stale)."
    echo
    echo "Options:"
    echo "  y) Run '${cache_function}' to refresh the cache"
    echo "  n) Use the existing cache (${age_formatted} old)"
    echo
    read -p "Choose option (y/n): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        _loading "Running ${cache_function} to refresh cache..."
        case "$cache_type" in
            "sites")
                _gp_api_cache_sites
                ;;
            "servers")
                _gp_api_cache_servers
                ;;
            *)
                _error "Unknown cache type: ${cache_type}"
                return 1
                ;;
        esac
        
        local cache_result=$?
        if [[ $cache_result -eq 0 ]]; then
            # Verify the cache file was actually created/updated
            if [[ -f "$cache_file" ]]; then
                _success "Cache refreshed successfully."
                return 0
            else
                _error "Cache function succeeded but cache file was not created: $cache_file"
                return 1
            fi
        else
            _error "Failed to refresh cache (exit code: $cache_result)"
            return 1
        fi
    else
        _loading3 "Using existing cache (${age_formatted} old)."
        return 0
    fi
}

# =====================================
# -- Cache Helper Functions
# =====================================
# Function to handle cache not found with prompt to run appropriate cache command
_handle_cache_not_found() {
    local cache_type="${1:-sites}"  # Default to sites for backward compatibility
    local cache_file="${2:-}"  # Optional cache file path
    
    # If cache file is provided, use the new detailed checking
    if [[ -n "$cache_file" ]]; then
        _check_cache_with_options "$cache_file" "$cache_type"
        return $?
    fi
    
    # Legacy behavior for backward compatibility
    local cache_function="cache-${cache_type}"
    local get_function="_gp_api_get_${cache_type}"
    
    _warning "Cache not found or disabled for ${cache_type}."
    echo
    read -p "Would you like to run '${cache_function}' to populate the cache? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        _loading "Running ${cache_function} to populate cache..."
        
        # Call the appropriate get function
        case "$cache_type" in
            "sites")
                _gp_api_get_sites
                ;;
            "servers")
                _gp_api_get_servers
                ;;
            *)
                _error "Unknown cache type: ${cache_type}"
                return 1
                ;;
        esac
        
        local get_result=$?
        if [[ $get_result -eq 0 ]]; then
            _success "Cache populated successfully. Retrying your request..."
            return 0
        else
            _error "Failed to populate cache. Please run '${cache_function}' manually."
            return 1
        fi
    else
        _error "Cache is required. Please run '${cache_function}' first to populate the cache."
        return 1
    fi
}

# =====================================
# -- _pre_flight
# =====================================
function _pre_flight () {
    # Check if jq is installed
    if ! command -v jq &> /dev/null; then
        _error "Error: jq is not installed. Please install jq to use this script."
        exit 1
    fi

    # Check if curl is installed
    if ! command -v curl &> /dev/null; then
        _error "Error: curl is not installed. Please install curl to use this script."
        exit 1
    fi

    # Check if .gridpane file exists
    if [[ ! -f "$HOME/.gridpane" ]]; then
        _error "Error: .gridpane file not found in $HOME"
        exit 1
    fi
    _loading3 "Pre-flight checks passed. All required tools are installed and .gridpane file exists."

}

# =====================================
# -- _gp_select_token
# -- Select a GridPane API token from the .gridpane file
# =====================================
function _gp_select_token () {
    _debugf "${FUNCNAME[0]} called"
    
    # If token is already set, don't prompt again
    if [[ -n "$GPBC_TOKEN" && -n "$GPBC_TOKEN_NAME" ]]; then
        _debugf "Token already selected: GPBC_TOKEN_NAME=$GPBC_TOKEN_NAME"
        return 0
    fi
    
    # Source the .gridpane file
    source $TOKEN_FILE
    _debugf "Loaded API credentials from $HOME/.gridpane"

    # Get all variables from the .gridpane starting with GP_TOKEN
    local GP_TOKEN_VAR=($(cat $TOKEN_FILE | grep '^GPBC_TOKEN_' | cut -d= -f1))
    _debugf "Found GPBC_TOKEN variables: ${GP_TOKEN_VAR[@]}"
    if [[ -z "${GP_TOKEN_VAR[*]}" ]]; then
        _error "Error: No GPBC_TOKEN variable found in $HOME/.gridpane"
        exit 1
    fi

    # List all GPBC_TOKEN variables
    _loading2 "GPBC_TOKEN variables found, please choose:"
    echo
    select profile in "${GP_TOKEN_VAR[@]}"; do
        if [[ -n "$profile" ]]; then
            _debugf "Selected profile: $profile"
            export GPBC_TOKEN="${!profile}"
            # Name is after GPBC_TOKEN_
            export GPBC_TOKEN_NAME="${profile#GPBC_TOKEN_}"
            _debugf "Using GPBC_TOKEN:$GPBC_TOKEN_NAME GPBC_TOKEN:$GPBC_TOKEN"
            break
        else
            _error "Invalid selection. Please try again."
        fi
    done

    # Check if GPBC_TOKEN is set and not empty
    if [[ -z "${GPBC_TOKEN+x}" ]]; then
        _error "Error: GPBC_TOKEN variable is not defined"
        _error "Please check your .gridpane file and ensure the selected token profile exists"
        exit 1
    elif [[ -z "$GPBC_TOKEN" ]]; then
        _error "Error: GPBC_TOKEN is defined but empty"
        _error "Please check your .gridpane file and ensure the token value is not blank"
        exit 1
    fi
    _debugf "GPBC_TOKEN is set to: $GPBC_TOKEN"
}

