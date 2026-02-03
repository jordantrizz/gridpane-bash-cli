#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_FILE="$HOME/.gridpane"
CACHE_DIR="$HOME/.gpbc-cache"
VERSION="$(cat $SCRIPT_DIR/VERSION)"
CACHE_ENABLED="1"
source "$SCRIPT_DIR/gp-inc.sh"
source "$SCRIPT_DIR/gp-inc-api.sh"
source "$SCRIPT_DIR/gp-inc-reports.sh"
source "$SCRIPT_DIR/gp-inc-compare.sh"
source "$SCRIPT_DIR/gp-inc-doc.sh"
[[ -z $DATA_DIR ]] && { DATA_DIR="$SCRIPT_DIR/data"; }

# =======================================
# -- Variables
# =======================================
GP_API_URL="https://my.gridpane.com/oauth/api/v1"
GPBC_DEFAULT_PER_PAGE=100
export GPBC_DEFAULT_PER_PAGE
RANDOM_NUM=$((RANDOM % 1000))
REPORT_FILE="$DATA_DIR/$RANDOM_NUM.json"
DEBUG_FILE="0"
DEBUG_FILE_PATH=""
export DEBUG_FILE
export DEBUG_FILE_PATH

# =======================================
# -- Usage
# =======================================
function _usage() {
    echo "Usage: $0 -c <command> <action> [options]"
    echo
    echo "Commands:"
    echo
    echo "  API:"
    echo "      api-stats                   - Display live API statistics (bypasses cache)"
    echo "      api <endpoint>              - Run an API endpoint (GET only)"
    echo "      test-token                  - Test the API token"
    echo
    echo "  Servers:"
    echo "      get-servers                 - Fetch servers with page support and json combine"
    echo "      list-servers                - List servers"
    echo "      list-servers-details        - List servers with details"
    echo "      list-servers-csv            - List servers as CSV (serverid,servername)"
    echo "      list-servers-sites          - List servers with sites"
    echo "      get-server-build <server-id> - Check server build status and progress"
    echo
    echo "  Sites:"
    echo "      list-sites                  - Fetch sites from the API into cache"
    echo "      list-sites-csv              - Fetch sites from the API and output as CSV"
    echo "      get-site <domain>           - Get site details in formatted table output"
    echo "      get-site-live <domain>      - Get live site settings from API (using cached site ID)"
    echo "      get-site-json <domain>      - Fetch details of a specific site by domain (JSON)"
    echo "      compare-sites <domain> <profile1> <profile2> - Compare site settings across profiles"
    echo "      compare-sites-major <domain> <profile1> <profile2> - Compare major site settings (excludes id, server_id, user_id, etc.)"
    echo "      get-site-servers <file>     - Get server names for domains listed in file (one per line)"
    echo "      add-site <domain> <server-id> [php] [pm] [cache] - Add a site to a server"
    echo "                                  Defaults: php=8.1, pm=dynamic, cache=fastcgi"
    echo "      add-site-csv <file> [delay]  - Add multiple sites from CSV file"
    echo "                                  CSV format: domain,server_id,php"
    echo "                                  Delay in seconds between additions (default: 300)"
    echo
    echo "  Reports:"
    echo "      report-server-sites         - Report total sites per server (alphabetically sorted)"
    echo
    echo "  System Users:"
    echo "      get-system-users            - List all system users (formatted)"
    echo "      get-system-users-json       - List all system users (JSON)"
    echo "      get-system-user <id/user>   - Get specific system user by ID or username (formatted)"
    echo "      get-system-user-json <id/user> - Get specific system user by ID or username (JSON)"
    echo
    echo "  Domains:"
    echo "      list-domains                - List all domain URLs"
    echo "      get-domains-json            - Get all domains (JSON)"
    echo "      get-domain <domain>         - Get domain details (formatted)"
    echo "      get-domain-json <domain>    - Get domain details (JSON)"
    echo
    echo "  Cache"
    echo "      cache-stats                 - Display cache statistics (count, size, location)"
    echo "      cache-status-compare        - Compare cache stats with live API stats"
    echo "      get-cache-age <endpoint>    - Get the age of the cache"
    echo "      cache-sites                 - Cache sites from the API"
    echo "      cache-servers               - Cache servers from the API"
    echo "      cache-users                 - Cache system users from the API"
    echo "      cache-domains               - Cache domains from the API"
    echo "      cache-all                   - Cache all data (sites, servers, users, domains)"
    echo "      clear-cache                 - Clear the cache"
    echo
    echo "  Documentation:"
    echo "      doc-api                     - List all API endpoint categories"
    echo "      doc <category>              - List endpoints in a category (e.g., doc server)"
    echo "      doc <category> <endpoint>   - Show full endpoint details (e.g., doc server get-servers)"
    echo
    echo "Options:"
    echo "  -h, --help                      - Show this help message"
    echo "  -p, --profile <name>            - Specify the profile to use from .gridpane"
    echo "  --csv                           - Output as CSV format (for report-server-sites)"
    echo "  -nc,                            - No cache"
    echo "  -d, --debug                     - Enable debug mode"
    echo "  -df, --debug-file <path>        - Enable debug file logging (overwrites file)"
    echo "  -dapi, --debug-api              - Enable API debug mode"
}



# =============================================================================
# -- Main
# =============================================================================
# -- Process Arguments
_debugf "Processing arguments: $@"
POSITIONAL=()
CSV_OUTPUT="0"
DEBUG="0"
while [[ $# -gt 0 ]]; do
key="$1"
case $key in
    -c|--command)
    if [[ -z "$2" ]]; then
        _usage
        _error "No command provided after -c flag"
        exit 1
    fi
    export CMD="$2"
    shift 2
    [[ -n $1 && "$1" != -* ]] && { export CMD_ACTION="$1"; shift ; }
    [[ -n $1 && "$1" != -* ]] && { export CMD_ACTION2="$1"; shift ; }
    _debugf "  → Command: $CMD | Action: $CMD_ACTION | Secondary: $CMD_ACTION2"
    ;;
    -p|--profile)
    PROFILE_NAME="$2"
    _debugf "  → Profile: $PROFILE_NAME"
    shift 2
    ;;
    --csv)
    CSV_OUTPUT="1"
    _debugf "  → CSV output enabled"
    shift
    ;;
    -nc|--no-cache)
    CACHE_ENABLED="0"
    _debugf "  → Cache disabled"
    shift # past argument
    ;;
    -d|--debug)
    DEBUG="1"
    _warning "Debug mode enabled"
    _debugf "  → Debug flag set to: $DEBUG"
    shift # past argument
    ;;
    -dapi|--debug-api)
    DEBUG_API="1"
    _debugf "  → API Debug flag set to: $DEBUG_API"
    shift # past argument
    ;;
    -df|--debug-file)
    DEBUG_FILE="1"
    # Check if next argument exists and doesn't start with -
    if [[ -n "$2" && "$2" != -* ]]; then
        DEBUG_FILE_PATH="$2"
        shift 2
    else
        # Use default path
        DEBUG_FILE_PATH="$HOME/tmp/gpbc-debug.log"
        shift
    fi
    _debugf "  → Debug file enabled: $DEBUG_FILE_PATH"
    ;;
    -h|--help)
    _usage
    exit 0
    ;;
    *)    # unknown option
    _debugf "  → Positional argument: $1"
    POSITIONAL+=("$1") # save it in an array for later
    shift # past argument
    ;;
esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters
_debugf "Argument parsing complete. Positional args: ${POSITIONAL[@]}"

# -- Setup debug file if enabled
if [[ $DEBUG_FILE == "1" ]]; then
    # Use default path if not specified
    if [[ -z "$DEBUG_FILE_PATH" ]]; then
        DEBUG_FILE_PATH="$HOME/tmp/gpbc-debug.log"
    fi
    
    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$DEBUG_FILE_PATH")"
    
    # Overwrite the file (empty it)
    > "$DEBUG_FILE_PATH"
    
    # Export for use in sourced files
    export DEBUG_FILE="1"
    export DEBUG_FILE_PATH="$DEBUG_FILE_PATH"
    _debugf "Debug file logging to: $DEBUG_FILE_PATH"
    echo "Debug file logging to: $DEBUG_FILE_PATH"
fi

# Export DEBUG flag for sourced files
export DEBUG="$DEBUG"

_loading "Loading GridPane Bash CLI - $VERSION"
_pre_flight

# -- Handle profile selection if specified
if [[ -n "$PROFILE_NAME" ]]; then
    _gp_set_profile "$PROFILE_NAME"
fi

# =============================================
# -- API
# =============================================
if [[ $CMD == "api-stats" ]]; then
    _gp_api_get_api_stats
elif [[ $CMD == "api" ]]; then
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
# -- get-server-build
elif [[ $CMD == "get-server-build" ]]; then
    if [[ -z "$CMD_ACTION" ]]; then
        _usage
        _error "No server-id provided for get-server-build command"
        exit 1
    fi
    _gp_api_get_server_build_status "$CMD_ACTION"
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
# -- get-site-live (live API data using cached site ID)
elif [[ $CMD == "get-site-live" ]]; then
    if [[ -z "$CMD_ACTION" ]]; then
        _usage
        _error "No domain provided for get-site-live command"
        exit 1
    fi
    _gp_api_get_site_live $CMD_ACTION
# -- get-site-json (raw JSON output)
elif [[ $CMD == "get-site-json" ]]; then
    if [[ -z "$CMD_ACTION" ]]; then
        _usage
        _error "No domain provided for get-site-json command"
        exit 1
    fi
    _gp_api_get_site $CMD_ACTION
# -- compare-sites (compare across profiles)
elif [[ $CMD == "compare-sites" ]]; then
    _gp_api_compare_sites "$CMD_ACTION" "$CMD_ACTION2" "${POSITIONAL[0]}"
# -- compare-sites-major (compare major settings only)
elif [[ $CMD == "compare-sites-major" ]]; then
    _gp_api_compare_sites_major "$CMD_ACTION" "$CMD_ACTION2" "${POSITIONAL[0]}"
# -- get-site-servers (bulk domain to server lookup)
elif [[ $CMD == "get-site-servers" ]]; then
    if [[ -z "$CMD_ACTION" ]]; then
        _usage
        _error "No file provided for get-site-servers command"
        exit 1
    fi
    _gp_api_get_site_servers $CMD_ACTION
# -- add-site (add a site to a server)
elif [[ $CMD == "add-site" ]]; then
    if [[ -z "$CMD_ACTION" ]] || [[ -z "$CMD_ACTION2" ]]; then
        _usage
        _error "Domain and Server ID are required for add-site command"
        exit 1
    fi
    # Arguments: domain, server-id, php (optional), pm (optional), cache (optional)
    _gp_api_add_site "$CMD_ACTION" "$CMD_ACTION2" "${POSITIONAL[0]:-}" "${POSITIONAL[1]:-}" "${POSITIONAL[2]:-}"
# -- add-site-csv (add multiple sites from CSV file)
elif [[ $CMD == "add-site-csv" ]]; then
    if [[ -z "$CMD_ACTION" ]]; then
        _usage
        _error "CSV file path is required for add-site-csv command"
        exit 1
    fi
    if [[ ! -f "$CMD_ACTION" ]]; then
        _error "File not found: $CMD_ACTION"
        exit 1
    fi
    if [[ ! -r "$CMD_ACTION" ]]; then
        _error "File is not readable: $CMD_ACTION"
        exit 1
    fi
    DELAY="${CMD_ACTION2:-300}"
    if ! [[ "$DELAY" =~ ^[0-9]+$ ]]; then
        _error "Delay must be a number (seconds)"
        exit 1
    fi
    _gp_csv_add_sites "$CMD_ACTION" "$DELAY"
# ============================================
# -- Reports Commands
# ============================================
elif [[ $CMD == "report-server-sites" ]]; then
    _gp_report_sites_per_server "$CSV_OUTPUT"
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
elif [[ $CMD == "cache-stats" ]]; then
    _gp_api_cache_stats
elif [[ $CMD == "cache-status-compare" ]]; then
    _gp_api_cache_status_compare
elif [[ $CMD == "cache-sites" ]]; then
    _gp_api_cache_sites
elif [[ $CMD == "cache-servers" ]]; then
    _gp_api_cache_servers
elif [[ $CMD == "cache-users" ]]; then
    _gp_api_cache_users
elif [[ $CMD == "cache-domains" ]]; then
    _gp_api_cache_domains
elif [[ $CMD == "cache-all" ]]; then
    _gp_api_cache_all
elif [[ $CMD == "list-domains" ]]; then
    _gp_api_list_domains
elif [[ $CMD == "get-domains-json" ]]; then
    _gp_api_get_domains
elif [[ $CMD == "get-domain" ]]; then
    if [[ -z "$CMD_ACTION" ]]; then
        _usage
        _error "Domain URL is required for get-domain command"
        exit 1
    fi
    _gp_api_get_domain_formatted "$CMD_ACTION"
elif [[ $CMD == "get-domain-json" ]]; then
    if [[ -z "$CMD_ACTION" ]]; then
        _usage
        _error "Domain URL is required for get-domain-json command"
        exit 1
    fi
    _gp_api_get_domain "$CMD_ACTION"
elif [[ $CMD == "get-system-users" ]]; then
    _gp_api_list_system_users_formatted
elif [[ $CMD == "get-system-users-json" ]]; then
    _gp_api_get_users
elif [[ $CMD == "get-system-user" ]]; then
    if [[ -z "$CMD_ACTION" ]]; then
        _usage
        _error "User ID or username is required for get-system-user command"
        exit 1
    fi
    _gp_api_get_system_user_formatted "$CMD_ACTION"
elif [[ $CMD == "get-system-user-json" ]]; then
    if [[ -z "$CMD_ACTION" ]]; then
        _usage
        _error "User ID or username is required for get-system-user-json command"
        exit 1
    fi
    _gp_api_get_user "$CMD_ACTION"
elif [[ $CMD == "clear-cache" ]]; then
    _gp_api_clear_cache
# ============================================
# -- Documentation Commands
# ============================================
elif [[ $CMD == "doc-api" ]]; then
    _gp_doc_list_categories
elif [[ $CMD == "doc" ]]; then
    if [[ -z "$CMD_ACTION" ]]; then
        _gp_doc_list_categories
    elif [[ -z "$CMD_ACTION2" ]]; then
        _gp_doc_list_endpoints "$CMD_ACTION"
    else
        _gp_doc_show_endpoint "$CMD_ACTION" "$CMD_ACTION2"
    fi
elif [[ $CMD == "" ]]; then
    _usage
    _error "No command provided"
    exit 1
else
    _usage
    _error "Unknown command: $CMD"
    exit 1
fi