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
_success () { echo -e "\e[1;32m$1\e[0m"; }
# -- Bright yellow background black text
_loading () { echo -e "\e[1;33m\e[7m$1\e[0m"; }
# -- Blue background white text
_loading2 () { echo -e "\e[1;34m\e[7m$1\e[0m"; }
# -- Dark grey text
_loading3 () { echo -e "\e[1;30m$1\e[0m"; }

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
# =============================================================================
function _gp_select_token () {
    _debugf "${FUNCNAME[0]} called"
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
            GPBC_TOKEN="${!profile}"
            # Name is after GPBC_TOKEN_
            GPBC_TOKEN_NAME="${profile#GPBC_TOKEN_}"
            _debugf "Using GPBC_TOKEN:$GPBC_TOKEN_NAME GPBC_TOKEN:$GPBC_TOKEN"
            break
        else
            _error "Invalid selection. Please try again."
        fi
    done

    # Check if GPBC_TOKEN is set
    if [[ -z $GPBC_TOKEN ]]; then
        _error "Error: GPBC_TOKEN is not set"
        exit 1
    fi
    _debugf "GPBC_TOKEN is set to: $GPBC_TOKEN"
}

