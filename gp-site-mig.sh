#!/usr/bin/env bash
# gp-site-mig.sh - Migrate a site from one GridPane server/account to another
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_FILE="$HOME/.gridpane"
CACHE_DIR="$HOME/.gpbc-cache"
VERSION="$(cat $SCRIPT_DIR/VERSION)"

# Source shared functions
source "$SCRIPT_DIR/gp-inc.sh"
source "$SCRIPT_DIR/gp-inc-api.sh"

# Migration-specific globals
DRY_RUN="0"
VERBOSE="0"
RUN_STEP=""
SITE=""
SOURCE_PROFILE=""
DEST_PROFILE=""
STATE_DIR="$SCRIPT_DIR/state"
LOG_DIR="$SCRIPT_DIR/logs"

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
function _usage() {
    echo "Usage: $0 -s <site> -sp <source-profile> -dp <dest-profile> [options]"
    echo
    echo "Migrate a site from one GridPane server/account to another."
    echo
    echo "Required Arguments:"
    echo "  -s,  --site <domain>            Site domain to migrate (e.g., example.com)"
    echo "  -sp, --source-profile <name>    Source account profile name (from ~/.gridpane)"
    echo "  -dp, --dest-profile <name>      Destination account profile name (from ~/.gridpane)"
    echo
    echo "Options:"
    echo "  -n,  --dry-run                  Show what would be done without executing"
    echo "  -v,  --verbose                  Show detailed output"
    echo "  --step <step>                   Run a specific step only (e.g., 3 or 2.1)"
    echo "  -h,  --help                     Show this help message"
    echo
    echo "Migration Steps:"
    echo "  1     - Validate input (confirm site exists on both profiles)"
    echo "  2     - Server discovery and SSH validation"
    echo "          2.1  Get server IPs from API"
    echo "          2.2  Test SSH connectivity"
    echo "          2.3  Get database name from wp-config.php"
    echo "          2.4  Confirm database exists on both servers"
    echo "          2.5  Confirm site directory paths"
    echo "  3     - Test rsync and migrate files"
    echo "          3.1  Confirm rsync on source"
    echo "          3.2  Confirm rsync on destination"
    echo "          3.3  Rsync htdocs"
    echo "  4     - Migrate database"
    echo "  5     - Migrate nginx config"
    echo "          5.1  Check for custom nginx configs"
    echo "          5.2  Run gp commands for special configs"
    echo "          5.3  Backup and copy nginx files"
    echo "  6     - Copy user-config.php (if exists)"
    echo "  7     - Final steps (clear cache, print summary)"
    echo
    echo "State & Logs:"
    echo "  State files: $STATE_DIR/gp-site-mig-<site>.json"
    echo "  Log files:   $LOG_DIR/gp-site-mig-<site>-<timestamp>.log"
    echo
    echo "Examples:"
    echo "  $0 -s example.com -sp prod-account -dp staging-account"
    echo "  $0 -s example.com -sp prod-account -dp staging-account -n -v"
    echo "  $0 -s example.com -sp prod-account -dp staging-account --step 2.1"
}

# -----------------------------------------------------------------------------
# Pre-flight checks (extended for migration)
# -----------------------------------------------------------------------------
function _pre_flight_mig() {
    local has_error=0

    # Check if jq is installed
    if ! command -v jq &> /dev/null; then
        _error "jq is not installed. Please install jq to use this script."
        has_error=1
    fi

    # Check if curl is installed
    if ! command -v curl &> /dev/null; then
        _error "curl is not installed. Please install curl to use this script."
        has_error=1
    fi

    # Check if ssh is installed
    if ! command -v ssh &> /dev/null; then
        _error "ssh is not installed. Please install ssh to use this script."
        has_error=1
    fi

    # Check if rsync is installed
    if ! command -v rsync &> /dev/null; then
        _error "rsync is not installed. Please install rsync to use this script."
        has_error=1
    fi

    # Check if .gridpane file exists
    if [[ ! -f "$TOKEN_FILE" ]]; then
        _error ".gridpane file not found in $HOME"
        has_error=1
    fi

    # Exit if any checks failed
    if [[ $has_error -eq 1 ]]; then
        exit 1
    fi

    _loading3 "Pre-flight checks passed."
}

# -----------------------------------------------------------------------------
# Verbose output helper
# -----------------------------------------------------------------------------
function _verbose() {
    if [[ "$VERBOSE" == "1" ]]; then
        echo -e "\033[0;36m[VERBOSE]\033[0m $1"
    fi
}

# -----------------------------------------------------------------------------
# Dry-run output helper
# -----------------------------------------------------------------------------
function _dry_run_msg() {
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "\033[0;33m[DRY-RUN]\033[0m $1"
    fi
}

# -----------------------------------------------------------------------------
# Argument Parsing
# -----------------------------------------------------------------------------
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -s|--site)
            if [[ -z "$2" || "$2" == -* ]]; then
                _usage
                _error "No site domain provided after $1 flag"
                exit 1
            fi
            SITE="$2"
            shift 2
            ;;
        -sp|--source-profile)
            if [[ -z "$2" || "$2" == -* ]]; then
                _usage
                _error "No source profile provided after $1 flag"
                exit 1
            fi
            SOURCE_PROFILE="$2"
            shift 2
            ;;
        -dp|--dest-profile)
            if [[ -z "$2" || "$2" == -* ]]; then
                _usage
                _error "No destination profile provided after $1 flag"
                exit 1
            fi
            DEST_PROFILE="$2"
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN="1"
            shift
            ;;
        -v|--verbose)
            VERBOSE="1"
            shift
            ;;
        --step)
            if [[ -z "$2" || "$2" == -* ]]; then
                _usage
                _error "No step number provided after --step flag"
                exit 1
            fi
            RUN_STEP="$2"
            shift 2
            ;;
        -h|--help)
            _usage
            exit 0
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL[@]}"

# -----------------------------------------------------------------------------
# Validate Required Arguments
# -----------------------------------------------------------------------------
if [[ -z "$SITE" || -z "$SOURCE_PROFILE" || -z "$DEST_PROFILE" ]]; then
    _usage
    echo
    _error "Missing required arguments:"
    [[ -z "$SITE" ]] && _error "  -s, --site is required"
    [[ -z "$SOURCE_PROFILE" ]] && _error "  -sp, --source-profile is required"
    [[ -z "$DEST_PROFILE" ]] && _error "  -dp, --dest-profile is required"
    exit 1
fi

# Sanitize site domain
SITE=$(_sanitize_domain "$SITE")

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------
_loading "GridPane Site Migration - $VERSION"
_pre_flight_mig

# Display parsed arguments in verbose mode
_verbose "Site: $SITE"
_verbose "Source Profile: $SOURCE_PROFILE"
_verbose "Destination Profile: $DEST_PROFILE"
_verbose "Dry Run: $DRY_RUN"
_verbose "Verbose: $VERBOSE"
_verbose "Run Step: ${RUN_STEP:-all}"
_verbose "State Dir: $STATE_DIR"
_verbose "Log Dir: $LOG_DIR"

if [[ "$DRY_RUN" == "1" ]]; then
    _dry_run_msg "Dry-run mode enabled - no changes will be made"
fi

if [[ -n "$RUN_STEP" ]]; then
    _loading2 "Running step $RUN_STEP only"
else
    _loading2 "Running all migration steps"
fi

echo
_success "Phase 1 complete - ready for Phase 2 (logging and state management)"
