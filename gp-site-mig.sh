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
# Logging function - writes timestamped entries to log file
# -----------------------------------------------------------------------------
function _log() {
    # Ensure log directory exists
    mkdir -p "$LOG_DIR"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# State Management Functions
# -----------------------------------------------------------------------------

# Check if state file exists for current site
function _state_exists() {
    [[ -f "$STATE_FILE" ]]
}

# Create new state file with initial data
function _state_init() {
    mkdir -p "$STATE_DIR"
    
    jq -n \
        --arg site "$SITE" \
        --arg source_profile "$SOURCE_PROFILE" \
        --arg dest_profile "$DEST_PROFILE" \
        --arg started "$(date -Iseconds)" \
        '{
            site: $site,
            source_profile: $source_profile,
            dest_profile: $dest_profile,
            started: $started,
            last_updated: $started,
            completed_steps: [],
            data: {}
        }' > "$STATE_FILE"
    
    _log "STATE: Initialized state file: $STATE_FILE"
    _verbose "State file created: $STATE_FILE"
}

# Read a value from state file by jq path
# Usage: _state_read ".data.source_site_id"
function _state_read() {
    local jq_path="$1"
    if [[ ! -f "$STATE_FILE" ]]; then
        echo ""
        return 1
    fi
    jq -r "$jq_path // empty" "$STATE_FILE"
}

# Update state file value by jq path (preserves existing data)
# Usage: _state_write ".data.source_site_id" "12345"
function _state_write() {
    local jq_path="$1"
    local value="$2"
    
    if [[ ! -f "$STATE_FILE" ]]; then
        _error "State file does not exist: $STATE_FILE"
        return 1
    fi
    
    local tmp_file="${STATE_FILE}.tmp"
    local timestamp
    timestamp=$(date -Iseconds)
    
    jq --arg val "$value" --arg ts "$timestamp" \
        "$jq_path = \$val | .last_updated = \$ts" "$STATE_FILE" > "$tmp_file" \
        && mv "$tmp_file" "$STATE_FILE"
    
    _log "STATE: Updated $jq_path = $value"
    _verbose "State updated: $jq_path = $value"
}

# Append step to completed_steps array
# Usage: _state_add_completed_step "1" or _state_add_completed_step "2.1"
function _state_add_completed_step() {
    local step="$1"
    
    if [[ ! -f "$STATE_FILE" ]]; then
        _error "State file does not exist: $STATE_FILE"
        return 1
    fi
    
    local tmp_file="${STATE_FILE}.tmp"
    local timestamp
    timestamp=$(date -Iseconds)
    
    jq --arg step "$step" --arg ts "$timestamp" \
        '.completed_steps += [$step] | .last_updated = $ts' "$STATE_FILE" > "$tmp_file" \
        && mv "$tmp_file" "$STATE_FILE"
    
    _log "STATE: Marked step $step as complete"
    _verbose "Step $step marked complete"
}

# Check if step already completed
# Usage: if _state_is_step_completed "2.1"; then echo "Skip"; fi
function _state_is_step_completed() {
    local step="$1"
    
    if [[ ! -f "$STATE_FILE" ]]; then
        return 1  # No state file = not completed
    fi
    
    jq -e --arg step "$step" '.completed_steps | index($step) != null' "$STATE_FILE" >/dev/null 2>&1
}

# Check for existing state and prompt for resume/restart
function _check_resume() {
    if _state_exists && [[ -z "$RUN_STEP" ]]; then
        local completed_count
        completed_count=$(jq '.completed_steps | length' "$STATE_FILE" 2>/dev/null || echo "0")
        local last_updated
        last_updated=$(_state_read ".last_updated")
        local completed_list
        completed_list=$(jq -r '.completed_steps | join(", ")' "$STATE_FILE" 2>/dev/null || echo "none")
        
        echo
        _warning "Found existing migration state for '$SITE'"
        _loading3 "  Completed steps: $completed_list"
        _loading3 "  Last updated: $last_updated"
        echo
        read -p "Resume previous migration? (Y/n): " -n 1 -r
        echo
        
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            _loading3 "Starting fresh migration..."
            rm -f "$STATE_FILE"
            _state_init
            _log "Migration restarted (user chose not to resume)"
        else
            _success "Resuming migration..."
            _log "Resuming migration from state file"
        fi
    elif [[ ! -f "$STATE_FILE" ]]; then
        _state_init
    fi
    # If --step is specified with existing state, just continue (state already exists)
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

# Define state and log file paths (must be after SITE is set)
STATE_FILE="${STATE_DIR}/gp-site-mig-${SITE}.json"
LOG_FILE="${LOG_DIR}/gp-site-mig-${SITE}-$(date +%Y%m%d_%H%M%S).log"

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------
_loading "GridPane Site Migration - $VERSION"
_pre_flight_mig

# Initialize logging
mkdir -p "$LOG_DIR"
_log "=========================================="
_log "Migration started for site: $SITE"
_log "Source profile: $SOURCE_PROFILE"
_log "Destination profile: $DEST_PROFILE"
_log "Dry run: $DRY_RUN"
_log "Run step: ${RUN_STEP:-all}"
_log "=========================================="

# Display parsed arguments in verbose mode
_verbose "Site: $SITE"
_verbose "Source Profile: $SOURCE_PROFILE"
_verbose "Destination Profile: $DEST_PROFILE"
_verbose "Dry Run: $DRY_RUN"
_verbose "Verbose: $VERBOSE"
_verbose "Run Step: ${RUN_STEP:-all}"
_verbose "State File: $STATE_FILE"
_verbose "Log File: $LOG_FILE"

if [[ "$DRY_RUN" == "1" ]]; then
    _dry_run_msg "Dry-run mode enabled - no changes will be made"
    _log "DRY-RUN MODE ENABLED"
fi

# Handle --step flag: require existing state file
if [[ -n "$RUN_STEP" ]]; then
    if [[ ! -f "$STATE_FILE" ]]; then
        _error "Cannot run step $RUN_STEP: No state file found for '$SITE'"
        _error "Run a full migration first to create the state file."
        exit 1
    fi
    _loading2 "Running step $RUN_STEP only"
    _log "Running specific step: $RUN_STEP"
else
    # Check for resume or initialize state (only for full migrations)
    _check_resume
    _loading2 "Running all migration steps"
fi

echo
_success "Phase 2 complete - logging and state management ready"
_verbose "Log file: $LOG_FILE"
_verbose "State file: $STATE_FILE"
