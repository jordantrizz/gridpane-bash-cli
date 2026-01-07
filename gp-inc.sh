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

# -- Cross-platform file modification time helper
_file_mtime() {
    local target="$1"
    local mtime

    [[ -z "$target" || ! -e "$target" ]] && return 1

    # macOS/BSD stat
    if mtime=$(stat -f %m "$target" 2>/dev/null); then
        echo "$mtime"
        return 0
    fi

    # GNU/coreutils stat
    if mtime=$(stat -c %Y "$target" 2>/dev/null); then
        echo "$mtime"
        return 0
    fi

    # Perl fallback
    if command -v perl >/dev/null 2>&1; then
        if mtime=$(perl -e 'my $f = shift; my @s = stat $f; exit 1 unless @s; print int $s[9];' "$target" 2>/dev/null); then
            echo "$mtime"
            return 0
        fi
    fi

    # Python fallback
    if command -v python3 >/dev/null 2>&1; then
        if mtime=$(python3 - "$target" <<'PY' 2>/dev/null
import os
import sys

try:
    print(int(os.path.getmtime(sys.argv[1])))
except Exception:
    sys.exit(1)
PY
); then
            echo "$mtime"
            return 0
        fi
    fi

    return 1
}

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
    
    if [[ ! -f "$cache_file" ]] || [[ ! -s "$cache_file" ]]; then
        _warning "Cache not found or empty for ${cache_type}."
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
                # Verify the cache file was actually created and not empty
                if [[ -f "$cache_file" ]] && [[ -s "$cache_file" ]]; then
                    _success "Cache populated successfully."
                    return 0
                else
                    _error "Cache function succeeded but cache file was not created or is empty: $cache_file"
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
    
    # Cache file exists and is not empty, check its age
    local cache_mtime
    if ! cache_mtime=$(_file_mtime "$cache_file"); then
        _error "Unable to determine modification time for cache: $cache_file"
        return 1
    fi

    local cache_age=$(( $(date +%s) - cache_mtime ))
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
# -- _gp_set_profile
# -- Set a specific profile from the .gridpane file
# -- Usage: _gp_set_profile <profile_name>
# =====================================
function _gp_set_profile () {
    local profile_name="$1"
    _debugf "${FUNCNAME[0]} called with profile: $profile_name"
    
    if [[ -z "$profile_name" ]]; then
        _error "Error: No profile name provided"
        exit 1
    fi
    
    # Source the .gridpane file
    source "$TOKEN_FILE"
    
    # Check if the profile exists
    local profile_var="GPBC_TOKEN_${profile_name}"
    if [[ -z "${!profile_var}" ]]; then
        _error "Error: Profile '$profile_name' not found in $TOKEN_FILE"
        echo
        echo "Available profiles:"
        grep '^GPBC_TOKEN_' "$TOKEN_FILE" | cut -d= -f1 | sed 's/GPBC_TOKEN_/  - /'
        exit 1
    fi
    
    # Set the token and name
    export GPBC_TOKEN="${!profile_var}"
    export GPBC_TOKEN_NAME="$profile_name"
    _success "Using profile: $profile_name"
    _debugf "GPBC_TOKEN_NAME=$GPBC_TOKEN_NAME"
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
    
    # Check for domain-specific cached profile
    local current_domain=$(_get_current_domain "$CMD" "$CMD_ACTION")
    local cached_profile=""
    if [[ -n "$current_domain" ]]; then
        cached_profile=$(_get_cached_profile_for_domain "$current_domain")
        if [[ -n "$cached_profile" ]]; then
            _debugf "Found cached profile for domain $current_domain: $cached_profile"
            echo
            _loading3 "Previously used profile for domain '$current_domain': $cached_profile"
            read -p "Use this profile? (Y/n): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Nn]$ ]]; then
                _debugf "User declined cached profile, will show selection menu"
            else
                # Use cached profile
                source $TOKEN_FILE
                local profile_var="GPBC_TOKEN_${cached_profile}"
                if [[ -n "${!profile_var}" ]]; then
                    export GPBC_TOKEN="${!profile_var}"
                    export GPBC_TOKEN_NAME="$cached_profile"
                    _success "Using cached profile: $cached_profile"
                    return 0
                else
                    _warning "Cached profile '$cached_profile' not found in .gridpane file, will show selection menu"
                fi
            fi
        fi
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
            
            # Cache the domain-profile mapping for future use
            if [[ -n "$current_domain" ]]; then
                _cache_domain_profile "$current_domain" "$GPBC_TOKEN_NAME"
                _debugf "Cached profile selection for domain: $current_domain -> $GPBC_TOKEN_NAME"
            fi
            
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

# =====================================
# -- Domain-to-Profile Mapping Functions
# =====================================
# Function to get cached profile for a domain
_get_cached_profile_for_domain() {
    local domain="$1"
    local domain_cache_file="$HOME/.gpbc-domain-cache"
    
    if [[ -f "$domain_cache_file" && -n "$domain" ]]; then
        grep "^${domain}=" "$domain_cache_file" 2>/dev/null | cut -d'=' -f2
    fi
}

# Function to cache domain-to-profile mapping
_cache_domain_profile() {
    local domain="$1"
    local profile="$2"
    local domain_cache_file="$HOME/.gpbc-domain-cache"
    
    if [[ -n "$domain" && -n "$profile" ]]; then
        # Remove existing entry for this domain if it exists
        if [[ -f "$domain_cache_file" ]]; then
            grep -v "^${domain}=" "$domain_cache_file" > "${domain_cache_file}.tmp" 2>/dev/null
            mv "${domain_cache_file}.tmp" "$domain_cache_file"
        fi
        # Add new entry
        echo "${domain}=${profile}" >> "$domain_cache_file"
        _debugf "Cached domain-profile mapping: ${domain} -> ${profile}"
    fi
}

# Function to get domain from command context (for domain-specific commands)
_get_current_domain() {
    # Extract domain from common command patterns
    local cmd="$1"
    local action="$2"
    local domain=""
    
    case "$cmd" in
        "get-site"|"get-site-json")
            domain="$action"
            ;;
        "get-site-servers")
            # For file-based commands, extract first domain from file for caching purposes
            if [[ -f "$action" ]]; then
                domain=$(head -n1 "$action" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^#' | head -n1)
            fi
            ;;
        *)
            # For other commands, no specific domain
            echo ""
            return
            ;;
    esac
    
    # Sanitize the domain for consistent caching (silent - no notification)
    if [[ -n "$domain" ]]; then
        local original_domain="$domain"
        
        # Strip leading/trailing whitespace
        domain=$(echo "$domain" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Strip protocols (http://, https://)
        domain=$(echo "$domain" | sed 's|^https\?://||')
        
        # Strip www. prefix
        domain=$(echo "$domain" | sed 's/^www\.//')
        
        # Strip trailing slash and path
        domain=$(echo "$domain" | sed 's|/.*$||')
        
        # Strip port numbers (e.g., :8080)
        domain=$(echo "$domain" | sed 's/:[0-9]*$//')
        
        # Final whitespace cleanup
        domain=$(echo "$domain" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        echo "$domain"
    fi
}

# =====================================
# -- Domain Sanitization Functions
# =====================================
# Function to sanitize domain input by stripping protocols, www, and whitespace
_sanitize_domain() {
    local input_domain="$1"
    local original_domain="$input_domain"
    
    if [[ -z "$input_domain" ]]; then
        echo ""
        return 1
    fi
    
    # Strip leading/trailing whitespace
    input_domain=$(echo "$input_domain" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    # Strip protocols (http://, https://)
    input_domain=$(echo "$input_domain" | sed 's|^https\?://||')
    
    # Strip www. prefix
    input_domain=$(echo "$input_domain" | sed 's/^www\.//')
    
    # Strip trailing slash and path
    input_domain=$(echo "$input_domain" | sed 's|/.*$||')
    
    # Strip port numbers (e.g., :8080)
    input_domain=$(echo "$input_domain" | sed 's/:[0-9]*$//')
    
    # Final whitespace cleanup
    input_domain=$(echo "$input_domain" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    # Notify user if domain was modified (send to stderr to avoid capturing in command substitution)
    if [[ "$original_domain" != "$input_domain" ]]; then
        _loading3 "Domain sanitized: '$original_domain' -> '$input_domain'" >&2
    fi
    
    echo "$input_domain"
    return 0
}

# Function to sanitize domain and validate it's not empty
_sanitize_and_validate_domain() {
    local input_domain="$1"
    local sanitized_domain
    
    sanitized_domain=$(_sanitize_domain "$input_domain")
    
    if [[ -z "$sanitized_domain" ]]; then
        _error "Error: Invalid domain after sanitization"
        return 1
    fi
    
    # Basic domain validation (contains at least one dot and valid characters)
    if [[ ! "$sanitized_domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
        _error "Error: Invalid domain format: '$sanitized_domain'"
        return 1
    fi
    
    echo "$sanitized_domain"
    return 0
}

# =====================================

