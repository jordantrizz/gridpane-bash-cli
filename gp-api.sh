#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_FILE="$HOME/.gridpane"
CACHE_DIR="$HOME/.gpbc-cache"
VERSION="$(cat $SCRIPT_DIR/VERSION)"
CACHE_ENABLED="1"
source "$SCRIPT_DIR/gp-inc.sh"
source "$SCRIPT_DIR/gp-inc-api.sh"
[[ -z $DATA_DIR ]] && { DATA_DIR="$SCRIPT_DIR/data"; }

# =======================================
# -- Variables
# =======================================
GP_API_URL="https://my.gridpane.com/oauth/api/v1"
RANDOM_NUM=$((RANDOM % 1000))
REPORT_FILE="$DATA_DIR/$RANDOM_NUM.json"

# =======================================
# -- Usage
# =======================================
function _usage() {
    echo "Usage: $0 -c <command> <action> [options]"
    echo
    echo "Commands:"
    echo
    echo "  API:"
    echo "      api <endpoint>              - Run an API endpoint (GET only)"
    echo "      test-token                  - Test the API token"
    echo
    echo "  Servers:"
    echo "      get-servers                 - Fetch servers with page support and json combine"
    echo "      list-servers                - List servers"
    echo "      list-servers-details        - List servers with details"
    echo "      list-servers-csv            - List servers as CSV (serverid,servername)"
    echo "      list-servers-sites          - List servers with sites"
    echo
    echo "  Sites:"
    echo "      list-sites                  - Fetch sites from the API into cache"
    echo "      list-sites-csv              - Fetch sites from the API and output as CSV"
    echo "      get-site <domain>           - Get site details in formatted table output"
    echo "      get-site-json <domain>      - Fetch details of a specific site by domain (JSON)"
    echo "      get-site-servers <file>     - Get server names for domains listed in file (one per line)"
    echo
    echo " Cache"
    echo "      get-cache-age <endpoint>    - Get the age of the cache"
    echo "      cache-sites                 - Cache sites from the API"
    echo "      cache-servers               - Cache servers from the API"
    echo "      clear-cache                 - Clear the cache"
    echo
    echo "Options:"
    echo "  -h, --help                      - Show this help message"
    echo "  -p, --profile <name>            - Specify the profile to use from .gridpane"
    echo "  -nc,                            - No cache"
    echo "  -d, --debug                     - Enable debug mode"
    echo "  -dapi, --debug-api              - Enable API debug mode"
}



# =============================================================================
# -- Main
# =============================================================================
# -- Process Arguments
_debugf "Processing arguments: $@"
POSITIONAL=()
while [[ $# -gt 0 ]]; do
key="$1"
case $key in
    -c|--command)
    export CMD="$2"
    shift 2
    [[ -n $1 ]] && { export CMD_ACTION="$1"; shift ; }
    _debugf "Command set to: $CMD and action set to: $CMD_ACTION"
    ;;
    -p|--profile)
    PROFILE_NAME="$2"
    shift 2
    ;;
    -nc|--no-cache)
    CACHE_ENABLED="0"
    shift # past argument
    ;;
    -d|--debug)
    DEBUG="1"
    shift # past argument
    ;;
    -dapi|--debug-api)
    DEBUG_API="1"
    shift # past argument
    ;;
    -h|--help)
    _usage
    exit 0
    ;;
    *)    # unknown option
    POSITIONAL+=("$1") # save it in an array for later
    shift # past argument
    ;;
esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

_loading "Loading GridPane Bash CLI - $VERSION"
_pre_flight

# -- Handle profile selection if specified
if [[ -n "$PROFILE_NAME" ]]; then
    _gp_set_profile "$PROFILE_NAME"
fi

# =============================================
# -- API
# =============================================
if [[ $CMD == "api" ]]; then
    [[ -z "$CMD_ACTION" ]] && { echo "Usage: $0 api <action>"; exit 1; }
    gp_api GET "$CMD_ACTION"
    _debugf "API Output: $API_OUTPUT"
    echo "$API_OUTPUT" | jq -r '.'
# -- test-token
elif [[ $CMD == "test-token" ]]; then
    _gp_test_token
# -- gp-servers
# =============================================
# -- Servers Commands
# =============================================
elif [[ $CMD == "get-servers" ]]; then
    _gp_api_get_servers
elif [[ $CMD == "list-servers" ]]; then
    _gp_api_list_servers 0
# -- list-servers-details
elif [[ $CMD == "list-servers-details" ]]; then
    _gp_api_list_servers 1
# -- list-servers-csv
elif [[ $CMD == "list-servers-csv" ]]; then
    _gp_api_list_servers_csv
# -- list-servers-sites
elif [[ $CMD == "list-servers-sites" ]]; then
    _gp_api_list_servers_sites
# ============================================
# -- Sites Commands
# ============================================
elif [[ $CMD == "list-sites" ]]; then
    _gp_api_list_sites
# -- get-domains
elif [[ $CMD == "list-sites-csv" ]]; then
    _gp_api_list_sites 1
# -- get-site (formatted output)
elif [[ $CMD == "get-site" ]]; then
    if [[ -z "$CMD_ACTION" ]]; then
        _usage
        _error "No domain provided for get-site command"
        exit 1
    fi
    _gp_api_get_site_formatted $CMD_ACTION
# -- get-site-json (raw JSON output)
elif [[ $CMD == "get-site-json" ]]; then
    if [[ -z "$CMD_ACTION" ]]; then
        _usage
        _error "No domain provided for get-site-json command"
        exit 1
    fi
    _gp_api_get_site $CMD_ACTION
# -- get-site-servers (bulk domain to server lookup)
elif [[ $CMD == "get-site-servers" ]]; then
    if [[ -z "$CMD_ACTION" ]]; then
        _usage
        _error "No file provided for get-site-servers command"
        exit 1
    fi
    _gp_api_get_site_servers $CMD_ACTION
# ============================================
# -- Cache Commands
# ============================================
elif [[ $CMD == "get-cache-age" ]]; then
    if [[ -z "$CMD_ACTION" ]]; then
        _usage
        _error "Not completed"
        exit 1
    fi
    _gp_api_cache_age "$CMD_ACTION"
elif [[ $CMD == "cache-sites" ]]; then
    _gp_api_cache_sites
elif [[ $CMD == "cache-servers" ]]; then
    _gp_api_cache_servers
elif [[ $CMD == "clear-cache" ]]; then
    _gp_api_clear_cache
elif [[ $CMD == "" ]]; then
    _usage
    _error "No command provided"
    exit 1
else
    _usage
    _error "Unknown command: $CMD"
    exit 1
fi