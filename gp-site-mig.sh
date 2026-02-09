#!/usr/bin/env bash
# gp-site-mig.sh - Migrate a site from one GridPane server/account to another
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_FILE="$HOME/.gridpane"
CACHE_DIR="$HOME/.gpbc-cache"
VERSION="$(cat $SCRIPT_DIR/VERSION)"
GP_API_URL="https://my.gridpane.com/oauth/api/v1"

# Source shared functions
source "$SCRIPT_DIR/gp-inc.sh"
source "$SCRIPT_DIR/gp-inc-api.sh"

# Migration-specific globals
DRY_RUN="0"
VERBOSE="0"
DEBUG="0"
RUN_STEP=""
RSYNC_LOCAL="0"
DB_FILE="0"
FORCE_DB="0"
SKIP_DB="0"
DNS_INTEGRATION_ID=""
DNS_INTEGRATION_SKIP="0"
SITE=""
SOURCE_PROFILE=""
DEST_PROFILE=""
STATE_DIR="$SCRIPT_DIR/state"
LOG_DIR="$SCRIPT_DIR/logs"
DATA_FILE=""
DATA_FORMAT=""

# ----------------------------------------------------------------------------
# Step message context
# Append the domain being migrated to the end of step messages: "... (domain.com)"
# ----------------------------------------------------------------------------
if declare -F _loading >/dev/null 2>&1; then
    eval "$(declare -f _loading | sed '1s/^_loading/_gpbc_loading_orig/')"
    _loading() {
        local msg="$1"
        if [[ -n "${SITE:-}" && "$msg" == Step* && "$msg" != *" (${SITE})" ]]; then
            msg+=" (${SITE})"
        fi
        _gpbc_loading_orig "$msg"
    }
fi

if declare -F _success >/dev/null 2>&1; then
    eval "$(declare -f _success | sed '1s/^_success/_gpbc_success_orig/')"
    _success() {
        local msg="$1"
        if [[ -n "${SITE:-}" && "$msg" == Step* && "$msg" != *" (${SITE})" ]]; then
            msg+=" (${SITE})"
        fi
        _gpbc_success_orig "$msg"
    }
fi

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
    echo "  -d,  --debug                    Enable debug output"
    echo "  --rsync-local                    If server-to-server rsync fails, relay via local machine"
    echo "  --db-file                       Use file-based DB migration (dump to file, gzip, transfer, import)"
    echo "  --force-db                      Force database migration even if marker exists on destination"
    echo "  --skip-db                       Skip database migration if marker already exists (continue to next step)"
    echo "  --step <step>                   Run a specific step only (e.g., 3 or 2.1)"
    echo "  --json <file>                   Load site data from JSON file (bypasses API)"
    echo "  --csv <file>                    Load site data from CSV file (bypasses API)"
    echo "  --dns-integration <id>          Specify destination DNS integration ID (for Step 1.3)"
    echo "  --dns-integration-skip          Skip destination DNS integration lookup in Step 1.3"
    echo "  --list-states                   List all migration state files"
    echo "  --clear-state                   Clear state file for the specified site (-s required)"
    echo "  --fix-state                     Deduplicate completed_steps in state file (-s required)"
    echo "  -h,  --help                     Show this help message"
    echo
    echo "Migration Steps:"
    echo "  1     - Validate input (confirm site exists on both profiles)"
    echo "          1.1  Validate system users"
    echo "          1.2  Get domain routing (none/www/root)"
    echo "          1.3  Get SSL status and DNS integration"
    echo "  2     - Server discovery and SSH validation"
    echo "          2.1  Get server IPs from API"
    echo "          2.2  Test SSH connectivity"
    echo "          2.3  Get database name from wp-config.php"
    echo "          2.4  Confirm database exists on both servers"
    echo "          2.5  Confirm site directory paths"
    echo "  3     - Test rsync and migrate files"
    echo "          3.1  Confirm rsync on source"
    echo "          3.2  Confirm rsync on destination"
    echo "          3.3  Authorize destination SSH key on source (remote rsync prereq)"
    echo "          3.4  Rsync htdocs"
    echo "  4     - Migrate database"
    echo "  5     - Migrate nginx config"
    echo "          5.1  Check for custom nginx configs"
    echo "          5.2  Run gp commands for special configs"
    echo "          5.3  Backup and copy nginx files"
    echo "  6     - Copy user-configs.php (if exists)"
    echo "  7     - Sync domain route (none/www/root)"
    echo "  8     - Enable DNS integration on destination (Cloudflare/DNSME)"
    echo "  9     - Enable SSL on destination (if source has SSL)"
    echo "  10    - Final steps (cyber.html, gp fix cached, wp cache flush)"
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
# Debug output helper
# -----------------------------------------------------------------------------
function _debug() {
    if [[ "$DEBUG" == "1" ]]; then
        echo -e "\033[0;35m[DEBUG]\033[0m $1" >&2
    fi
}

function _debug_cmd() {
    local label="$1"
    shift
    if [[ "$DEBUG" == "1" ]]; then
        # Print as a single shell-ish line for copy/paste.
        _debug "$label: $*"
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
# Error logging function - writes timestamped entries to separate error log file
# Used for non-fatal errors/warnings that should be tracked but don't stop migration
# -----------------------------------------------------------------------------
function _error_log() {
    # Ensure log directory exists
    mkdir -p "$LOG_DIR"
    local msg="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$ERROR_LOG_FILE"
    # Also write to main log for completeness
    _log "ERROR: $msg"
    # Display warning to user
    _warning "$msg"
}

# -----------------------------------------------------------------------------
# Load site data from JSON or CSV file (bypasses API)
# Usage: _load_data_from_file "$SITE"
# Populates state file with source and dest data from file
# -----------------------------------------------------------------------------
function _load_data_from_file() {
    local site_domain="$1"
    _debug "Loading data from $DATA_FORMAT file: $DATA_FILE for site: $site_domain"
    
    if [[ ! -f "$DATA_FILE" ]]; then
        _error "Data file not found: $DATA_FILE"
        return 1
    fi
    
    local site_data
    
    if [[ "$DATA_FORMAT" == "json" ]]; then
        # Load from JSON file - find site by url field
        site_data=$(jq --arg domain "$site_domain" '.sites[] | select(.url == $domain)' "$DATA_FILE" 2>/dev/null)
        
        if [[ -z "$site_data" || "$site_data" == "null" ]]; then
            _error "Site '$site_domain' not found in JSON file"
            _error "Available sites: $(jq -r '.sites[].url' "$DATA_FILE" 2>/dev/null | tr '\n' ' ')"
            return 1
        fi
        
        # Extract source data
        local source_site_id source_site_url source_server_id source_server_label source_server_ip
        local source_system_user_id source_system_user_name
        source_site_id=$(echo "$site_data" | jq -r '.source.site_id // "0"')
        source_site_url=$(echo "$site_data" | jq -r '.url')
        source_server_id=$(echo "$site_data" | jq -r '.source.server_id // "0"')
        source_server_label=$(echo "$site_data" | jq -r '.source.server_label // "unknown"')
        source_server_ip=$(echo "$site_data" | jq -r '.source.server_ip')
        source_system_user_id=$(echo "$site_data" | jq -r '.source.system_user_id // "0"')
        source_system_user_name=$(echo "$site_data" | jq -r '.source.system_user_name // "unknown"')
        
        # Extract dest data
        local dest_site_id dest_site_url dest_server_id dest_server_label dest_server_ip
        local dest_system_user_id dest_system_user_name
        dest_site_id=$(echo "$site_data" | jq -r '.dest.site_id // "0"')
        dest_site_url=$(echo "$site_data" | jq -r '.url')
        dest_server_id=$(echo "$site_data" | jq -r '.dest.server_id // "0"')
        dest_server_label=$(echo "$site_data" | jq -r '.dest.server_label // "unknown"')
        dest_server_ip=$(echo "$site_data" | jq -r '.dest.server_ip')
        dest_system_user_id=$(echo "$site_data" | jq -r '.dest.system_user_id // "0"')
        dest_system_user_name=$(echo "$site_data" | jq -r '.dest.system_user_name // "unknown"')
        
    elif [[ "$DATA_FORMAT" == "csv" ]]; then
        # Load from CSV file
        # Expected format: url,source_site_id,source_server_id,source_server_label,source_server_ip,source_system_user_id,source_system_user_name,dest_site_id,dest_server_id,dest_server_label,dest_server_ip,dest_system_user_id,dest_system_user_name
        local csv_line
        csv_line=$(grep "^${site_domain}," "$DATA_FILE" | head -1)
        
        if [[ -z "$csv_line" ]]; then
            _error "Site '$site_domain' not found in CSV file"
            return 1
        fi
        
        # Parse CSV line (simple approach - assumes no commas in values)
        IFS=',' read -r source_site_url source_site_id source_server_id source_server_label source_server_ip source_system_user_id source_system_user_name dest_site_id dest_server_id dest_server_label dest_server_ip dest_system_user_id dest_system_user_name <<< "$csv_line"
        dest_site_url="$source_site_url"
    else
        _error "Unknown data format: $DATA_FORMAT"
        return 1
    fi
    
    # Validate required fields
    if [[ -z "$source_server_ip" || "$source_server_ip" == "null" ]]; then
        _error "Source server IP is required"
        return 1
    fi
    if [[ -z "$dest_server_ip" || "$dest_server_ip" == "null" ]]; then
        _error "Destination server IP is required"
        return 1
    fi
    
    # Display loaded data
    _success "Loaded site data from file: $source_site_url"
    _loading3 "  Source: $source_server_label ($source_server_ip) - user: $source_system_user_name"
    _loading3 "  Dest:   $dest_server_label ($dest_server_ip) - user: $dest_system_user_name"
    
    # Write to state file
    _state_write ".data.source_site_id" "$source_site_id"
    _state_write ".data.source_site_url" "$source_site_url"
    _state_write ".data.source_server_id" "$source_server_id"
    _state_write ".data.source_server_label" "$source_server_label"
    _state_write ".data.source_server_ip" "$source_server_ip"
    _state_write ".data.source_system_user_id" "$source_system_user_id"
    _state_write ".data.source_system_user_name" "$source_system_user_name"
    _state_write ".data.dest_site_id" "$dest_site_id"
    _state_write ".data.dest_site_url" "$dest_site_url"
    _state_write ".data.dest_server_id" "$dest_server_id"
    _state_write ".data.dest_server_label" "$dest_server_label"
    _state_write ".data.dest_server_ip" "$dest_server_ip"
    _state_write ".data.dest_system_user_id" "$dest_system_user_id"
    _state_write ".data.dest_system_user_name" "$dest_system_user_name"
    _state_write ".data_source" "file:$DATA_FILE"
    
    # Mark step 1 as complete (data loaded from file replaces API validation)
    _state_add_completed_step "1"
    
    _log "STEP 1: Site data loaded from file: $DATA_FILE"
    return 0
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

# Append step to completed_steps array (only if not already present)
# Usage: _state_add_completed_step "1" or _state_add_completed_step "2.1"
function _state_add_completed_step() {
    local step="$1"
    
    if [[ ! -f "$STATE_FILE" ]]; then
        _error "State file does not exist: $STATE_FILE"
        return 1
    fi
    
    # Check if step already in completed_steps
    local already_completed
    already_completed=$(jq --arg step "$step" '.completed_steps // [] | index($step)' "$STATE_FILE" 2>/dev/null)
    if [[ "$already_completed" != "null" && -n "$already_completed" ]]; then
        _verbose "Step $step already marked complete, skipping"
        return 0
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

# =============================================================================
# Migration Step Functions
# =============================================================================

function _server_cache_file_for_profile() {
    local profile_name="$1"
    echo "${CACHE_DIR}/${profile_name}_server.json"
}

function _resolve_server_label_for_profile() {
    local profile_name="$1"
    local server_id="$2"

    local cache_file
    cache_file=$(_server_cache_file_for_profile "$profile_name")

    if [[ -z "$server_id" || "$server_id" == "null" ]]; then
        echo "UNKNOWN"
        return 0
    fi

    if [[ ! -f "$cache_file" ]]; then
        echo "UNKNOWN"
        return 0
    fi

    jq --arg server_id "$server_id" -r '.[] | select(.id == (($server_id | tonumber)? // -1)) | .label // empty' "$cache_file" 2>/dev/null | head -n1
}

function _resolve_server_ip_for_profile() {
    local profile_name="$1"
    local server_id="$2"

    local cache_file
    cache_file=$(_server_cache_file_for_profile "$profile_name")

    if [[ -z "$server_id" || "$server_id" == "null" ]]; then
        echo "UNKNOWN"
        return 0
    fi

    if [[ ! -f "$cache_file" ]]; then
        echo "UNKNOWN"
        return 0
    fi

    jq --arg server_id "$server_id" -r '.[] | select(.id == (($server_id | tonumber)? // -1)) | .ip // empty' "$cache_file" 2>/dev/null | head -n1
}

function _system_user_cache_file_for_profile() {
    local profile_name="$1"
    echo "${CACHE_DIR}/${profile_name}_system-user.json"
}

function _resolve_system_user_name_for_profile() {
    local profile_name="$1"
    local system_user_id="$2"

    local cache_file
    cache_file=$(_system_user_cache_file_for_profile "$profile_name")

    if [[ -z "$system_user_id" || "$system_user_id" == "null" ]]; then
        echo "UNKNOWN"
        return 0
    fi

    if [[ ! -f "$cache_file" ]]; then
        echo "UNKNOWN"
        return 0
    fi

    jq --arg user_id "$system_user_id" -r '.[] | select(.id == (($user_id | tonumber)? // -1)) | .username // empty' "$cache_file" 2>/dev/null | head -n1
}

# -----------------------------------------------------------------------------
# Step 1 - Validate Input
# Confirm site exists on both source and destination profiles via API
# Stores: source_site_id, source_server_id, source_system_user_id,
#         dest_site_id, dest_server_id, dest_system_user_id
# -----------------------------------------------------------------------------
function _step_1() {
    _loading "Step 1: Validating input"
    _log "STEP 1: Starting input validation"
    
    # Save current profile state
    local saved_token="$GPBC_TOKEN"
    local saved_token_name="$GPBC_TOKEN_NAME"
    
    # --- Source Profile ---
    _loading2 "Checking source profile: $SOURCE_PROFILE"
    _debug "Switching to source profile: $SOURCE_PROFILE"
    
    if ! _gp_set_profile_silent "$SOURCE_PROFILE"; then
        _error "Source profile not found: $SOURCE_PROFILE"
        _log "STEP 1 FAILED: Source profile not found: $SOURCE_PROFILE"
        return 1
    fi
    
    # Check for site cache
    local source_cache="${CACHE_DIR}/${SOURCE_PROFILE}_site.json"
    _debug "Source cache file: $source_cache"
    
    if [[ ! -f "$source_cache" ]]; then
        _error "Site cache not found for source profile '$SOURCE_PROFILE'"
        _error "Run: ./gp-api.sh -p $SOURCE_PROFILE -c cache-sites"
        _log "STEP 1 FAILED: Source site cache not found"
        GPBC_TOKEN="$saved_token"
        GPBC_TOKEN_NAME="$saved_token_name"
        return 1
    fi
    
    # Find site in source cache
    local source_site_data
    source_site_data=$(jq --arg domain "$SITE" '.[] | select(.url == $domain)' "$source_cache" 2>/dev/null)
    
    if [[ -z "$source_site_data" || "$source_site_data" == "null" ]]; then
        _error "Site '$SITE' not found in source profile '$SOURCE_PROFILE'"
        _log "STEP 1 FAILED: Site not found in source profile"
        GPBC_TOKEN="$saved_token"
        GPBC_TOKEN_NAME="$saved_token_name"
        return 1
    fi
    
    # Extract source site data
    local source_site_id source_site_url source_server_id source_system_user_id
    source_site_id=$(echo "$source_site_data" | jq -r '.id')
    source_site_url=$(echo "$source_site_data" | jq -r '.url')
    source_server_id=$(echo "$source_site_data" | jq -r '.server_id')
    source_system_user_id=$(echo "$source_site_data" | jq -r '.system_user_id // "null"')

    local source_server_label source_server_ip source_system_user_name
    source_server_label=$(_resolve_server_label_for_profile "$SOURCE_PROFILE" "$source_server_id")
    source_server_ip=$(_resolve_server_ip_for_profile "$SOURCE_PROFILE" "$source_server_id")
    source_system_user_name=$(_resolve_system_user_name_for_profile "$SOURCE_PROFILE" "$source_system_user_id")

    if [[ "$source_server_label" == "UNKNOWN" ]]; then
        _warning "Server cache missing for '$SOURCE_PROFILE' (cannot resolve server label)."
        _loading3 "Run: ./gp-api.sh -p $SOURCE_PROFILE -c cache-servers"
        _log "STEP 1: Server cache missing for profile $SOURCE_PROFILE"
    fi

    if [[ "$source_system_user_name" == "UNKNOWN" || -z "$source_system_user_name" ]]; then
        _error "System user cache missing for '$SOURCE_PROFILE' (cannot resolve system user name)."
        _loading3 "Run: ./gp-api.sh -p $SOURCE_PROFILE -c cache-users"
        _log "STEP 1 FAILED: System user cache missing for profile $SOURCE_PROFILE"
        GPBC_TOKEN="$saved_token"
        GPBC_TOKEN_NAME="$saved_token_name"
        return 1
    fi
    
    _debug "Source site_id: $source_site_id"
    _debug "Source site_url: $source_site_url"
    _debug "Source server_id: $source_server_id"
    _debug "Source server_label: $source_server_label"
    _debug "Source server_ip: $source_server_ip"
    _debug "Source system_user_id: $source_system_user_id"
    _debug "Source system_user_name: $source_system_user_name"
    
    _success "Found site on source: $source_site_url (site_id=$source_site_id)"
    _loading3 "  Source server: $source_server_label (server_id=$source_server_id, ip=$source_server_ip)"
    _loading3 "  Source system user: $source_system_user_name (id=$source_system_user_id)"
    _log "Source site found: url=$source_site_url, id=$source_site_id, server_id=$source_server_id, server_label=$source_server_label, server_ip=$source_server_ip, system_user_id=$source_system_user_id, system_user_name=$source_system_user_name"
    
    # --- Destination Profile ---
    _loading2 "Checking destination profile: $DEST_PROFILE"
    _debug "Switching to destination profile: $DEST_PROFILE"
    
    if ! _gp_set_profile_silent "$DEST_PROFILE"; then
        _error "Destination profile not found: $DEST_PROFILE"
        _log "STEP 1 FAILED: Destination profile not found: $DEST_PROFILE"
        GPBC_TOKEN="$saved_token"
        GPBC_TOKEN_NAME="$saved_token_name"
        return 1
    fi
    
    # Check for site cache
    local dest_cache="${CACHE_DIR}/${DEST_PROFILE}_site.json"
    _debug "Destination cache file: $dest_cache"
    
    if [[ ! -f "$dest_cache" ]]; then
        _error "Site cache not found for destination profile '$DEST_PROFILE'"
        _error "Run: ./gp-api.sh -p $DEST_PROFILE -c cache-sites"
        _log "STEP 1 FAILED: Destination site cache not found"
        GPBC_TOKEN="$saved_token"
        GPBC_TOKEN_NAME="$saved_token_name"
        return 1
    fi
    
    # Find site in destination cache
    local dest_site_data
    dest_site_data=$(jq --arg domain "$SITE" '.[] | select(.url == $domain)' "$dest_cache" 2>/dev/null)
    
    if [[ -z "$dest_site_data" || "$dest_site_data" == "null" ]]; then
        _error "Site '$SITE' not found in destination profile '$DEST_PROFILE'"
        _log "STEP 1 FAILED: Site not found in destination profile"
        GPBC_TOKEN="$saved_token"
        GPBC_TOKEN_NAME="$saved_token_name"
        return 1
    fi
    
    # Extract destination site data
    local dest_site_id dest_site_url dest_server_id dest_system_user_id
    dest_site_id=$(echo "$dest_site_data" | jq -r '.id')
    dest_site_url=$(echo "$dest_site_data" | jq -r '.url')
    dest_server_id=$(echo "$dest_site_data" | jq -r '.server_id')
    dest_system_user_id=$(echo "$dest_site_data" | jq -r '.system_user_id // "null"')

    local dest_server_label dest_server_ip dest_system_user_name
    dest_server_label=$(_resolve_server_label_for_profile "$DEST_PROFILE" "$dest_server_id")
    dest_server_ip=$(_resolve_server_ip_for_profile "$DEST_PROFILE" "$dest_server_id")
    dest_system_user_name=$(_resolve_system_user_name_for_profile "$DEST_PROFILE" "$dest_system_user_id")

    if [[ "$dest_server_label" == "UNKNOWN" ]]; then
        _warning "Server cache missing for '$DEST_PROFILE' (cannot resolve server label)."
        _loading3 "Run: ./gp-api.sh -p $DEST_PROFILE -c cache-servers"
        _log "STEP 1: Server cache missing for profile $DEST_PROFILE"
    fi

    if [[ "$dest_system_user_name" == "UNKNOWN" || -z "$dest_system_user_name" ]]; then
        _error "System user cache missing for '$DEST_PROFILE' (cannot resolve system user name)."
        _loading3 "Run: ./gp-api.sh -p $DEST_PROFILE -c cache-users"
        _log "STEP 1 FAILED: System user cache missing for profile $DEST_PROFILE"
        GPBC_TOKEN="$saved_token"
        GPBC_TOKEN_NAME="$saved_token_name"
        return 1
    fi
    
    _debug "Dest site_id: $dest_site_id"
    _debug "Dest site_url: $dest_site_url"
    _debug "Dest server_id: $dest_server_id"
    _debug "Dest server_label: $dest_server_label"
    _debug "Dest server_ip: $dest_server_ip"
    _debug "Dest system_user_id: $dest_system_user_id"
    _debug "Dest system_user_name: $dest_system_user_name"
    
    _success "Found site on destination: $dest_site_url (site_id=$dest_site_id)"
    _loading3 "  Dest server: $dest_server_label (server_id=$dest_server_id, ip=$dest_server_ip)"
    _loading3 "  Dest system user: $dest_system_user_name (id=$dest_system_user_id)"
    _log "Destination site found: url=$dest_site_url, id=$dest_site_id, server_id=$dest_server_id, server_label=$dest_server_label, server_ip=$dest_server_ip, system_user_id=$dest_system_user_id, system_user_name=$dest_system_user_name"
    
    # Restore original profile
    GPBC_TOKEN="$saved_token"
    GPBC_TOKEN_NAME="$saved_token_name"
    
    # --- Update State ---
    _verbose "Updating state file with site data..."
    _state_write ".data.source_site_id" "$source_site_id"
    _state_write ".data.source_site_url" "$source_site_url"
    _state_write ".data.source_server_id" "$source_server_id"
    _state_write ".data.source_server_label" "$source_server_label"
    _state_write ".data.source_server_ip" "$source_server_ip"
    _state_write ".data.source_system_user_id" "$source_system_user_id"
    _state_write ".data.source_system_user_name" "$source_system_user_name"
    _state_write ".data.dest_site_id" "$dest_site_id"
    _state_write ".data.dest_site_url" "$dest_site_url"
    _state_write ".data.dest_server_id" "$dest_server_id"
    _state_write ".data.dest_server_label" "$dest_server_label"
    _state_write ".data.dest_server_ip" "$dest_server_ip"
    _state_write ".data.dest_system_user_id" "$dest_system_user_id"
    _state_write ".data.dest_system_user_name" "$dest_system_user_name"
    
    # Mark step complete
    _state_add_completed_step "1"
    
    _success "Step 1 complete: Input validation passed"
    _log "STEP 1 COMPLETE: Input validation passed"
    echo
    return 0
}

# -----------------------------------------------------------------------------
# Step 1.1 - Get system user usernames from system-user API
# Queries the system-user API using system_user_id from site data
# Stores: source_system_user (username), dest_system_user (username)
# Note: This is largely redundant now as Step 1 already resolves usernames
#       from cache, but kept for API-based validation if needed
# -----------------------------------------------------------------------------
function _step_1_1() {
    _loading "Step 1.1: Validate system users"
    _log "STEP 1.1: Starting system user validation"

    # Read system user data from state (captured in Step 1)
    local source_system_user_id source_system_user_name
    local dest_system_user_id dest_system_user_name
    source_system_user_id=$(_state_read ".data.source_system_user_id")
    source_system_user_name=$(_state_read ".data.source_system_user_name")
    dest_system_user_id=$(_state_read ".data.dest_system_user_id")
    dest_system_user_name=$(_state_read ".data.dest_system_user_name")

    if [[ -z "$source_system_user_id" || "$source_system_user_id" == "null" ]]; then
        _error "Source system user ID not found in state. Run Step 1 first."
        _log "STEP 1.1 FAILED: source_system_user_id not in state"
        return 1
    fi

    if [[ -z "$dest_system_user_id" || "$dest_system_user_id" == "null" ]]; then
        _error "Destination system user ID not found in state. Run Step 1 first."
        _log "STEP 1.1 FAILED: dest_system_user_id not in state"
        return 1
    fi

    _loading2 "Source system user: $source_system_user_name (id=$source_system_user_id)"
    _loading2 "Destination system user: $dest_system_user_name (id=$dest_system_user_id)"

    # Validate that usernames were resolved
    if [[ -z "$source_system_user_name" || "$source_system_user_name" == "UNKNOWN" || "$source_system_user_name" == "null" ]]; then
        _error "Source system user name not resolved. Check system-user cache for $SOURCE_PROFILE"
        _loading3 "Run: ./gp-api.sh -p $SOURCE_PROFILE -c cache-users"
        _log "STEP 1.1 FAILED: source_system_user_name not resolved"
        return 1
    fi

    if [[ -z "$dest_system_user_name" || "$dest_system_user_name" == "UNKNOWN" || "$dest_system_user_name" == "null" ]]; then
        _error "Destination system user name not resolved. Check system-user cache for $DEST_PROFILE"
        _loading3 "Run: ./gp-api.sh -p $DEST_PROFILE -c cache-users"
        _log "STEP 1.1 FAILED: dest_system_user_name not resolved"
        return 1
    fi

    _state_add_completed_step "1.1"
    _success "Step 1.1 complete: System users validated"
    _log "STEP 1.1 COMPLETE: source_user=$source_system_user_name, dest_user=$dest_system_user_name"
    echo
    return 0
}

# -----------------------------------------------------------------------------
# Step 1.2 - Get domain routing for source and destination
# Gets the primary domain for source/dest sites from domains cache
# Reads the route field (none, www, root) for both
# Stores: source_domain_id, source_route, dest_domain_id, dest_route
# -----------------------------------------------------------------------------
function _step_1_2() {
    _loading "Step 1.2: Get domain routing"
    _log "STEP 1.2: Starting domain routing lookup"

    # Read site IDs from state
    local source_site_id dest_site_id
    source_site_id=$(_state_read ".data.source_site_id")
    dest_site_id=$(_state_read ".data.dest_site_id")

    if [[ -z "$source_site_id" || "$source_site_id" == "null" ]]; then
        _error "Source site ID not found in state. Run Step 1 first."
        _log "STEP 1.2 FAILED: source_site_id not in state"
        return 1
    fi

    if [[ -z "$dest_site_id" || "$dest_site_id" == "null" ]]; then
        _error "Destination site ID not found in state. Run Step 1 first."
        _log "STEP 1.2 FAILED: dest_site_id not in state"
        return 1
    fi

    # --- Source Domain ---
    _loading2 "Looking up source domain for site_id=$source_site_id"
    local source_domain_cache="${CACHE_DIR}/${SOURCE_PROFILE}_domain.json"
    
    if [[ ! -f "$source_domain_cache" ]]; then
        _error "Domain cache not found for source profile '$SOURCE_PROFILE'"
        _loading3 "Run: ./gp-api.sh -p $SOURCE_PROFILE -c cache-domains"
        _log "STEP 1.2 FAILED: Source domain cache not found"
        return 1
    fi

    # Find primary domain for source site (flatten handles nested arrays from pagination)
    # Use jq -s to slurp results into array and select first match
    local source_domain_data
    source_domain_data=$(jq --arg site_id "$source_site_id" \
        '[flatten | .[] | select(.site_id == ($site_id | tonumber) and .type == "primary")] | .[0]' \
        "$source_domain_cache" 2>/dev/null)
    
    if [[ -z "$source_domain_data" || "$source_domain_data" == "null" ]]; then
        _error "Primary domain not found for source site_id=$source_site_id"
        _log "STEP 1.2 FAILED: Source primary domain not found"
        return 1
    fi

    local source_domain_id source_domain_url source_route
    source_domain_id=$(echo "$source_domain_data" | jq -r '.id')
    source_domain_url=$(echo "$source_domain_data" | jq -r '.url')
    source_route=$(echo "$source_domain_data" | jq -r '.route // "none"')

    _loading3 "Source primary domain: $source_domain_url (id=$source_domain_id, route=$source_route)"
    _debug "Source domain data: $source_domain_data"

    # --- Destination Domain ---
    _loading2 "Looking up destination domain for site_id=$dest_site_id"
    local dest_domain_cache="${CACHE_DIR}/${DEST_PROFILE}_domain.json"
    
    if [[ ! -f "$dest_domain_cache" ]]; then
        _error "Domain cache not found for destination profile '$DEST_PROFILE'"
        _loading3 "Run: ./gp-api.sh -p $DEST_PROFILE -c cache-domains"
        _log "STEP 1.2 FAILED: Destination domain cache not found"
        return 1
    fi

    # Find primary domain for destination site
    local dest_domain_data
    dest_domain_data=$(jq --arg site_id "$dest_site_id" \
        '[flatten | .[] | select(.site_id == ($site_id | tonumber) and .type == "primary")] | .[0]' \
        "$dest_domain_cache" 2>/dev/null)
    
    if [[ -z "$dest_domain_data" || "$dest_domain_data" == "null" ]]; then
        _error "Primary domain not found for destination site_id=$dest_site_id"
        _log "STEP 1.2 FAILED: Destination primary domain not found"
        return 1
    fi

    local dest_domain_id dest_domain_url dest_route
    dest_domain_id=$(echo "$dest_domain_data" | jq -r '.id')
    dest_domain_url=$(echo "$dest_domain_data" | jq -r '.url')
    dest_route=$(echo "$dest_domain_data" | jq -r '.route // "none"')

    _loading3 "Destination primary domain: $dest_domain_url (id=$dest_domain_id, route=$dest_route)"
    _debug "Destination domain data: $dest_domain_data"

    # Compare routes
    if [[ "$source_route" == "$dest_route" ]]; then
        _loading3 "Routes match: $source_route"
    else
        _warning "Routes differ: source=$source_route, destination=$dest_route"
        _loading3 "Step 7 will sync the route from source to destination"
    fi

    # Store to state
    _state_write ".data.source_domain_id" "$source_domain_id"
    _state_write ".data.source_domain_url" "$source_domain_url"
    _state_write ".data.source_route" "$source_route"
    _state_write ".data.dest_domain_id" "$dest_domain_id"
    _state_write ".data.dest_domain_url" "$dest_domain_url"
    _state_write ".data.dest_route" "$dest_route"

    _state_add_completed_step "1.2"
    _success "Step 1.2 complete: Domain routing captured"
    _log "STEP 1.2 COMPLETE: source_route=$source_route, dest_route=$dest_route"
    echo
    return 0
}

# -----------------------------------------------------------------------------
# Step 1.3 - Get SSL status and DNS integration for source
# Reads: is_ssl, ssl_status, is_wildcard from source primary domain
# Reads: user_dns.integration_name, user_dns.provider.name, dns_management_id
# Queries destination DNS integrations via GET /user/integration
# Stores: source_is_ssl, source_ssl_status, source_is_wildcard, source_dns_provider,
#         source_dns_integration_id, dest_dns_integration_id
# -----------------------------------------------------------------------------
function _step_1_3() {
    _loading "Step 1.3: Get SSL and DNS integration info"
    _log "STEP 1.3: Starting SSL and DNS integration lookup"

    # Read site/domain IDs from state
    local source_site_id source_domain_id
    source_site_id=$(_state_read ".data.source_site_id")
    source_domain_id=$(_state_read ".data.source_domain_id")

    if [[ -z "$source_domain_id" || "$source_domain_id" == "null" ]]; then
        _error "Source domain ID not found in state. Run Step 1.2 first."
        _log "STEP 1.3 FAILED: source_domain_id not in state"
        return 1
    fi

    # --- Source Domain SSL and DNS Info ---
    _loading2 "Reading SSL and DNS info for source domain_id=$source_domain_id"
    local source_domain_cache="${CACHE_DIR}/${SOURCE_PROFILE}_domain.json"
    
    local source_domain_data
    source_domain_data=$(jq --arg domain_id "$source_domain_id" \
        '[flatten | .[] | select(.id == ($domain_id | tonumber))] | .[0]' \
        "$source_domain_cache" 2>/dev/null)
    
    if [[ -z "$source_domain_data" || "$source_domain_data" == "null" ]]; then
        _error "Domain not found in cache for domain_id=$source_domain_id"
        _log "STEP 1.3 FAILED: Source domain not found in cache"
        return 1
    fi

    # Extract SSL info
    local source_is_ssl source_ssl_status source_is_wildcard
    source_is_ssl=$(echo "$source_domain_data" | jq -r '.is_ssl // false')
    source_ssl_status=$(echo "$source_domain_data" | jq -r '.ssl_status // "null"')
    source_is_wildcard=$(echo "$source_domain_data" | jq -r '.is_wildcard // false')

    _loading3 "SSL: enabled=$source_is_ssl, status=$source_ssl_status, wildcard=$source_is_wildcard"

    # Extract DNS integration info
    local source_dns_management_id source_dns_integration_name source_dns_provider_name
    source_dns_management_id=$(echo "$source_domain_data" | jq -r '.dns_management_id // "null"')
    source_dns_integration_name=$(echo "$source_domain_data" | jq -r '.user_dns.integration_name // "none"')
    source_dns_provider_name=$(echo "$source_domain_data" | jq -r '.user_dns.provider.name // "none"')

    _loading3 "DNS: provider=$source_dns_provider_name, integration=$source_dns_integration_name (id=$source_dns_management_id)"
    _debug "Source domain full data: $source_domain_data"

    # --- Destination DNS Integrations ---
    if [[ "$DNS_INTEGRATION_SKIP" == "1" ]]; then
        _loading2 "Skipping destination DNS integration lookup (--dns-integration-skip)"
        _state_write ".data.dest_dns_integration_id" "skipped"
        _log "STEP 1.3: DNS integration lookup skipped by user"
    elif [[ -n "$DNS_INTEGRATION_ID" ]]; then
        # User specified DNS integration ID - use it directly without API query
        _loading2 "Using specified DNS integration: $DNS_INTEGRATION_ID (--dns-integration)"
        _state_write ".data.dest_dns_integration_id" "$DNS_INTEGRATION_ID"
        _log "STEP 1.3: Using user-specified DNS integration ID: $DNS_INTEGRATION_ID"
    else
    _loading2 "Querying destination DNS integrations..."
    
    # Save current profile and switch to destination
    local saved_token="$GPBC_TOKEN"
    local saved_token_name="$GPBC_TOKEN_NAME"
    
    if ! _gp_set_profile_silent "$DEST_PROFILE"; then
        _error "Failed to switch to destination profile: $DEST_PROFILE"
        _log "STEP 1.3 FAILED: Could not switch to destination profile"
        return 1
    fi

    # Query integrations API
    local integrations_output
    _debug "Fetching integrations with profile: $GPBC_TOKEN_NAME"
    if ! gp_api GET "/user/integrations"; then
        _error "Failed to fetch integrations from destination profile"
        _error "API Error: $API_ERROR"
        _debug "API Output: $API_OUTPUT"
        _log "STEP 1.3 FAILED: Could not fetch destination integrations - $API_ERROR"
        GPBC_TOKEN="$saved_token"
        GPBC_TOKEN_NAME="$saved_token_name"
        return 1
    fi
    integrations_output="$API_OUTPUT"
    _debug "Integrations response: $integrations_output"

    # Restore original profile
    GPBC_TOKEN="$saved_token"
    GPBC_TOKEN_NAME="$saved_token_name"

    # Filter for DNS integrations (cloudflare, dnsme, etc.)
    local dns_integrations dns_integration_count
    dns_integrations=$(echo "$integrations_output" | jq '[.integrations[] | select(.integrated_service == "cloudflare" or .integrated_service == "dnsme")]')
    dns_integration_count=$(echo "$dns_integrations" | jq 'length')

    _debug "Found $dns_integration_count DNS integrations on destination"
    _debug "DNS integrations: $dns_integrations"

    local dest_dns_integration_id=""

    if [[ "$dns_integration_count" -eq 0 ]]; then
        _loading3 "No DNS integrations found on destination profile"
        _log "STEP 1.3: No DNS integrations on destination"
        dest_dns_integration_id="none"
    elif [[ "$dns_integration_count" -eq 1 ]]; then
        # Single integration - use it automatically
        dest_dns_integration_id=$(echo "$dns_integrations" | jq -r '.[0].id')
        local dest_dns_integration_name dest_dns_service
        dest_dns_integration_name=$(echo "$dns_integrations" | jq -r '.[0].integration_name')
        dest_dns_service=$(echo "$dns_integrations" | jq -r '.[0].integrated_service')
        _loading3 "Using destination DNS integration: $dest_dns_integration_name ($dest_dns_service, id=$dest_dns_integration_id)"
        _log "STEP 1.3: Auto-selected destination DNS integration: $dest_dns_integration_name (id=$dest_dns_integration_id)"
    else
        # Multiple integrations - check if --dns-integration was provided
        if [[ -n "$DNS_INTEGRATION_ID" ]]; then
            # Verify the provided ID exists
            local valid_id
            valid_id=$(echo "$dns_integrations" | jq --arg id "$DNS_INTEGRATION_ID" '[.[] | select(.id == ($id | tonumber))] | length')
            if [[ "$valid_id" -eq 1 ]]; then
                dest_dns_integration_id="$DNS_INTEGRATION_ID"
                local dest_dns_integration_name
                dest_dns_integration_name=$(echo "$dns_integrations" | jq -r --arg id "$DNS_INTEGRATION_ID" '.[] | select(.id == ($id | tonumber)) | .integration_name')
                _loading3 "Using specified DNS integration: $dest_dns_integration_name (id=$dest_dns_integration_id)"
                _log "STEP 1.3: Using specified destination DNS integration: $dest_dns_integration_name (id=$dest_dns_integration_id)"
            else
                _error "Specified DNS integration ID '$DNS_INTEGRATION_ID' not found on destination"
                _log "STEP 1.3 FAILED: Invalid DNS integration ID specified"
                return 1
            fi
        else
            # Multiple integrations and no --dns-integration flag
            _error "Multiple DNS integrations found on destination profile. Please specify one with --dns-integration <id>"
            echo
            echo "Available DNS integrations on $DEST_PROFILE:"
            echo "$dns_integrations" | jq -r '.[] | "  ID: \(.id) - \(.integration_name) (\(.integrated_service))"'
            echo
            _log "STEP 1.3 FAILED: Multiple DNS integrations, none specified"
            return 1
        fi
    fi

    # Store dest_dns_integration_id to state
    _state_write ".data.dest_dns_integration_id" "$dest_dns_integration_id"
    fi  # End of DNS_INTEGRATION_SKIP check

    # Store to state
    _state_write ".data.source_is_ssl" "$source_is_ssl"
    _state_write ".data.source_ssl_status" "$source_ssl_status"
    _state_write ".data.source_is_wildcard" "$source_is_wildcard"
    _state_write ".data.source_dns_management_id" "$source_dns_management_id"
    _state_write ".data.source_dns_integration_name" "$source_dns_integration_name"
    _state_write ".data.source_dns_provider" "$source_dns_provider_name"

    _state_add_completed_step "1.3"
    _success "Step 1.3 complete: SSL and DNS integration info captured"
    _log "STEP 1.3 COMPLETE: ssl=$source_is_ssl, dns_provider=$source_dns_provider_name, dest_dns_id=$dest_dns_integration_id"
    echo
    return 0
}

# -----------------------------------------------------------------------------
# Run a specific step or check if it should be skipped
# Usage: _run_step "1" _step_1
# -----------------------------------------------------------------------------
function _run_step() {
    local step_num="$1"
    local step_func="$2"
    
    # If running a specific step, only run if it matches
    if [[ -n "$RUN_STEP" ]]; then
        if [[ "$RUN_STEP" == "$step_num" ]]; then
            _debug "Running requested step: $step_num"
            $step_func
            local result=$?
            if [[ $result -eq 0 ]]; then
                _loading3 "Step $step_num completed successfully"
                _state_add_completed_step "$step_num"
                echo
                _loading2 "Finished: Step $RUN_STEP completed"
                exit 0
            else
                _error "Step $step_num failed"
                return $result
            fi
        elif [[ "$RUN_STEP" != *.* && "$step_num" == "$RUN_STEP."* ]]; then
            _debug "Running requested step group: $RUN_STEP (executing $step_num)"
            $step_func
            return $?
        else
            _debug "Skipping step $step_num (running step $RUN_STEP only)"
            return 0
        fi
    fi
    
    # Check if step already completed (for resume)
    if _state_is_step_completed "$step_num"; then
        _loading3 "Step $step_num already completed, skipping..."

        if [[ "$step_num" == "1" ]]; then
            local source_site_id source_site_url source_server_id source_server_label source_server_ip
            local dest_site_id dest_site_url dest_server_id dest_server_label dest_server_ip

            source_site_id=$(_state_read ".data.source_site_id")
            source_site_url=$(_state_read ".data.source_site_url")
            source_server_id=$(_state_read ".data.source_server_id")
            source_server_label=$(_state_read ".data.source_server_label")
            source_server_ip=$(_state_read ".data.source_server_ip")

            dest_site_id=$(_state_read ".data.dest_site_id")
            dest_site_url=$(_state_read ".data.dest_site_url")
            dest_server_id=$(_state_read ".data.dest_server_id")
            dest_server_label=$(_state_read ".data.dest_server_label")
            dest_server_ip=$(_state_read ".data.dest_server_ip")

            [[ -z "$source_site_url" ]] && source_site_url="$SITE"
            [[ -z "$dest_site_url" ]] && dest_site_url="$SITE"
            [[ -z "$source_site_id" ]] && source_site_id="UNKNOWN"
            [[ -z "$dest_site_id" ]] && dest_site_id="UNKNOWN"
            [[ -z "$source_server_id" ]] && source_server_id="UNKNOWN"
            [[ -z "$dest_server_id" ]] && dest_server_id="UNKNOWN"
            [[ -z "$source_server_label" ]] && source_server_label="UNKNOWN"
            [[ -z "$dest_server_label" ]] && dest_server_label="UNKNOWN"
            [[ -z "$source_server_ip" ]] && source_server_ip="UNKNOWN"
            [[ -z "$dest_server_ip" ]] && dest_server_ip="UNKNOWN"

            if [[ "$source_server_label" == "UNKNOWN" || "$source_server_ip" == "UNKNOWN" ]]; then
                local source_server_cache
                source_server_cache=$(_server_cache_file_for_profile "$SOURCE_PROFILE")
                if [[ ! -f "$source_server_cache" ]]; then
                    _loading3 "  Hint: ./gp-api.sh -p $SOURCE_PROFILE -c cache-servers"
                fi
            fi

            if [[ "$dest_server_label" == "UNKNOWN" || "$dest_server_ip" == "UNKNOWN" ]]; then
                local dest_server_cache
                dest_server_cache=$(_server_cache_file_for_profile "$DEST_PROFILE")
                if [[ ! -f "$dest_server_cache" ]]; then
                    _loading3 "  Hint: ./gp-api.sh -p $DEST_PROFILE -c cache-servers"
                fi
            fi

            _loading3 "  Source: $source_site_url (site_id=$source_site_id)"
            _loading3 "    Server: $source_server_label (server_id=$source_server_id, ip=$source_server_ip)"
            _loading3 "  Dest:   $dest_site_url (site_id=$dest_site_id)"
            _loading3 "    Server: $dest_server_label (server_id=$dest_server_id, ip=$dest_server_ip)"
        fi

        _log "Step $step_num skipped (already completed)"
        return 0
    fi
    
    # Run the step
    $step_func
    return $?
}

# -----------------------------------------------------------------------------
# Step 2.1 - Get server IPs from cache
# Requires Step 1 (server IDs) and profile server caches
# Stores: source_server_ip, dest_server_ip (and re-stores labels if available)
# -----------------------------------------------------------------------------
function _step_2_1() {
    _loading "Step 2.1: Resolving server IPs"
    _log "STEP 2.1: Resolving server IPs"

    local source_server_id dest_server_id
    source_server_id=$(_state_read ".data.source_server_id")
    dest_server_id=$(_state_read ".data.dest_server_id")

    if [[ -z "$source_server_id" || -z "$dest_server_id" ]]; then
        _error "Missing server IDs in state. Run Step 1 first."
        _log "STEP 2.1 FAILED: Missing server IDs in state"
        return 1
    fi

    local source_server_cache dest_server_cache
    source_server_cache=$(_server_cache_file_for_profile "$SOURCE_PROFILE")
    dest_server_cache=$(_server_cache_file_for_profile "$DEST_PROFILE")

    if [[ ! -f "$source_server_cache" ]]; then
        _error "Server cache not found for source profile '$SOURCE_PROFILE'"
        _error "Run: ./gp-api.sh -p $SOURCE_PROFILE -c cache-servers"
        _log "STEP 2.1 FAILED: Missing source server cache"
        return 1
    fi

    if [[ ! -f "$dest_server_cache" ]]; then
        _error "Server cache not found for destination profile '$DEST_PROFILE'"
        _error "Run: ./gp-api.sh -p $DEST_PROFILE -c cache-servers"
        _log "STEP 2.1 FAILED: Missing destination server cache"
        return 1
    fi

    local source_server_label source_server_ip dest_server_label dest_server_ip
    source_server_label=$(_resolve_server_label_for_profile "$SOURCE_PROFILE" "$source_server_id")
    source_server_ip=$(_resolve_server_ip_for_profile "$SOURCE_PROFILE" "$source_server_id")
    dest_server_label=$(_resolve_server_label_for_profile "$DEST_PROFILE" "$dest_server_id")
    dest_server_ip=$(_resolve_server_ip_for_profile "$DEST_PROFILE" "$dest_server_id")

    if [[ -z "$source_server_ip" || "$source_server_ip" == "UNKNOWN" ]]; then
        _error "Could not resolve source server IP (server_id=$source_server_id)"
        _log "STEP 2.1 FAILED: Could not resolve source server IP"
        return 1
    fi

    if [[ -z "$dest_server_ip" || "$dest_server_ip" == "UNKNOWN" ]]; then
        _error "Could not resolve destination server IP (server_id=$dest_server_id)"
        _log "STEP 2.1 FAILED: Could not resolve destination server IP"
        return 1
    fi

    _success "Resolved source server: ${source_server_label:-UNKNOWN} ($source_server_ip)"
    _success "Resolved dest server:   ${dest_server_label:-UNKNOWN} ($dest_server_ip)"

    _state_write ".data.source_server_ip" "$source_server_ip"
    _state_write ".data.dest_server_ip" "$dest_server_ip"
    [[ -n "$source_server_label" ]] && _state_write ".data.source_server_label" "$source_server_label"
    [[ -n "$dest_server_label" ]] && _state_write ".data.dest_server_label" "$dest_server_label"

    _state_add_completed_step "2.1"
    _log "STEP 2.1 COMPLETE: Server IPs resolved"
    echo
    return 0
}

# -----------------------------------------------------------------------------
# Step 2.2 - Test SSH connectivity
# Requires Step 2.1 (server IPs)
# -----------------------------------------------------------------------------
function _step_2_2() {
    _loading "Step 2.2: Testing SSH connectivity"
    _log "STEP 2.2: Testing SSH connectivity"

    local source_server_ip dest_server_ip
    source_server_ip=$(_state_read ".data.source_server_ip")
    dest_server_ip=$(_state_read ".data.dest_server_ip")

    if [[ -z "$source_server_ip" || -z "$dest_server_ip" ]]; then
        _error "Missing server IPs in state. Run Step 2.1 first."
        _log "STEP 2.2 FAILED: Missing server IPs in state"
        return 1
    fi

    local ssh_user
    ssh_user="${GPBC_SSH_USER:-root}"
    local known_hosts_file
    known_hosts_file="${STATE_DIR}/gp-site-mig-${SITE}-known_hosts"
    mkdir -p "$STATE_DIR"
    local ssh_opts
    ssh_opts=( -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known_hosts_file" )

    _loading2 "Testing SSH to source: $ssh_user@$source_server_ip"
    local ssh_err
    local ssh_rc
    ssh_err=$(ssh "${ssh_opts[@]}" "$ssh_user@$source_server_ip" "echo ok" 2>&1 >/dev/null)
    ssh_rc=$?
    if [[ $ssh_rc -ne 0 ]]; then
        if echo "$ssh_err" | grep -qi "Bad configuration option"; then
            _debug "SSH client does not support accept-new; retrying with StrictHostKeyChecking=no"
            ssh_opts=( -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="$known_hosts_file" )
            ssh_err=$(ssh "${ssh_opts[@]}" "$ssh_user@$source_server_ip" "echo ok" 2>&1 >/dev/null)
            ssh_rc=$?
        fi
    fi

    if [[ $ssh_rc -ne 0 ]]; then
        _error "SSH failed to source server: $ssh_user@$source_server_ip"
        _loading3 "Hint: verify auth with 'ssh $ssh_user@$source_server_ip'"
        _debug "SSH error (source): $ssh_err"
        _log "STEP 2.2 FAILED: SSH to source failed"
        return 1
    fi
    [[ -n "$ssh_err" ]] && _debug "SSH stderr (source): $ssh_err"
    _success "SSH OK: source ($source_server_ip)"

    _loading2 "Testing SSH to destination: $ssh_user@$dest_server_ip"
    ssh_err=$(ssh "${ssh_opts[@]}" "$ssh_user@$dest_server_ip" "echo ok" 2>&1 >/dev/null)
    ssh_rc=$?
    if [[ $ssh_rc -ne 0 ]]; then
        if echo "$ssh_err" | grep -qi "Bad configuration option"; then
            _debug "SSH client does not support accept-new; retrying with StrictHostKeyChecking=no"
            ssh_opts=( -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="$known_hosts_file" )
            ssh_err=$(ssh "${ssh_opts[@]}" "$ssh_user@$dest_server_ip" "echo ok" 2>&1 >/dev/null)
            ssh_rc=$?
        fi
    fi

    if [[ $ssh_rc -ne 0 ]]; then
        _error "SSH failed to destination server: $ssh_user@$dest_server_ip"
        _loading3 "Hint: verify auth with 'ssh $ssh_user@$dest_server_ip'"
        _debug "SSH error (dest): $ssh_err"
        _log "STEP 2.2 FAILED: SSH to destination failed"
        return 1
    fi
    [[ -n "$ssh_err" ]] && _debug "SSH stderr (dest): $ssh_err"
    _success "SSH OK: destination ($dest_server_ip)"

    _state_write ".data.ssh_user" "$ssh_user"
    _state_add_completed_step "2.2"
    _log "STEP 2.2 COMPLETE: SSH connectivity validated"
    echo
    return 0
}

function _ssh_run() {
    local host_ip="$1"
    local remote_cmd="$2"

    local ssh_user
    ssh_user="${GPBC_SSH_USER:-$(_state_read ".data.ssh_user")}";
    [[ -z "$ssh_user" ]] && ssh_user="root"

    local known_hosts_file
    known_hosts_file="${STATE_DIR}/gp-site-mig-${SITE}-known_hosts"
    mkdir -p "$STATE_DIR"

    local ssh_opts
    ssh_opts=( -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known_hosts_file" )

    _debug_cmd "SSH" ssh ${ssh_opts[*]} "$ssh_user@$host_ip" "$remote_cmd"

    ssh "${ssh_opts[@]}" "$ssh_user@$host_ip" "$remote_cmd"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        # Fallback for older SSH clients that don't support accept-new
        local out
        out=$(ssh "${ssh_opts[@]}" "$ssh_user@$host_ip" "$remote_cmd" 2>&1 >/dev/null)
        if echo "$out" | grep -qi "Bad configuration option"; then
            ssh_opts=( -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="$known_hosts_file" )
            _debug_cmd "SSH (fallback StrictHostKeyChecking=no)" ssh ${ssh_opts[*]} "$ssh_user@$host_ip" "$remote_cmd"
            ssh "${ssh_opts[@]}" "$ssh_user@$host_ip" "$remote_cmd"
            return $?
        fi
    fi
    return $rc
}

function _ssh_capture() {
    local host_ip="$1"
    local remote_cmd="$2"

    local ssh_user
    ssh_user="${GPBC_SSH_USER:-$(_state_read ".data.ssh_user")}";
    [[ -z "$ssh_user" ]] && ssh_user="root"

    local known_hosts_file
    known_hosts_file="${STATE_DIR}/gp-site-mig-${SITE}-known_hosts"
    mkdir -p "$STATE_DIR"

    local ssh_opts
    ssh_opts=( -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known_hosts_file" )

    local tmp_err
    tmp_err=$(mktemp)
    local out err rc

    _debug_cmd "SSH (capture)" ssh ${ssh_opts[*]} "$ssh_user@$host_ip" "$remote_cmd"
    out=$(ssh "${ssh_opts[@]}" "$ssh_user@$host_ip" "$remote_cmd" 2>"$tmp_err")
    rc=$?
    err=$(cat "$tmp_err" || true)

    if echo "$err" | grep -qi "Bad configuration option"; then
        ssh_opts=( -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="$known_hosts_file" )
        _debug_cmd "SSH (capture fallback StrictHostKeyChecking=no)" ssh ${ssh_opts[*]} "$ssh_user@$host_ip" "$remote_cmd"
        out=$(ssh "${ssh_opts[@]}" "$ssh_user@$host_ip" "$remote_cmd" 2>"$tmp_err")
        rc=$?
        err=$(cat "$tmp_err" || true)
    fi

    rm -f "$tmp_err" || true
    [[ -n "$err" ]] && _debug "SSH stderr ($ssh_user@$host_ip): $err"

    printf "%s" "$out"
    return $rc
}

function _remote_find_wp_config() {
    local host_ip="$1"
    local site_domain="$2"

    local cmd
        cmd=$(cat <<'EOF'
bash -lc 'set -euo pipefail
site="$1"
dbg="$2"

for f in \
    "/var/www/${site}/htdocs/wp-config.php" \
    "/var/www/${site}/wp-config.php" \
    "/var/www/www.${site}/htdocs/wp-config.php" \
    "/var/www/www.${site}/wp-config.php" \
    "/home"/*"/sites/${site}/htdocs/wp-config.php" \
    "/home"/*"/sites/${site}/wp-config.php" \
    "/home"/*"/sites/www.${site}/htdocs/wp-config.php" \
    "/home"/*"/sites/www.${site}/wp-config.php" \
    ; do
    if [[ -f "$f" ]]; then
        echo "$f"
        exit 0
    fi
done

# Bounded find fallback (avoid scanning entire filesystem)
found=$(find /var/www -maxdepth 5 -type f -name wp-config.php -path "*/${site}/*" 2>/dev/null | head -n1 || true)
if [[ -n "$found" && -f "$found" ]]; then
    echo "$found"
    exit 0
fi

found=$(find /home -maxdepth 6 -type f -name wp-config.php -path "*/${site}/*" 2>/dev/null | head -n1 || true)
if [[ -n "$found" && -f "$found" ]]; then
    echo "$found"
    exit 0
fi

if [[ "$dbg" == "1" ]]; then
    echo "--- DEBUG: wp-config not found for site='$site' ---"
    echo "PWD: $(pwd)"
    echo "HOSTNAME: $(hostname)"
    echo "Dirs in /var/www (top 100):"
    ls -1 /var/www 2>/dev/null | head -n 100 | sed "s/^/  /" || true
    echo "Find wp-config.php under /var/www (top 30):"
    find /var/www -maxdepth 6 -type f -name wp-config.php 2>/dev/null | head -n 30 | sed "s/^/  /" || true
    echo "Find wp-config.php under /home (top 30):"
    find /home -maxdepth 8 -type f -name wp-config.php 2>/dev/null | head -n 30 | sed "s/^/  /" || true
    echo "--- END DEBUG ---"
fi

exit 1' --
EOF
)
        cmd="${cmd%$'\n'}"

        # Append args for the remote script
        cmd="$cmd '$site_domain' '$DEBUG'"

    _ssh_capture "$host_ip" "$cmd"
    return $?
}

# -----------------------------------------------------------------------------
# Step 2.5 - Confirm site paths (source and destination)
# Finds wp-config.php, derives htdocs + site path, stores them in state.
# -----------------------------------------------------------------------------
function _step_2_5() {
    _loading "Step 2.5: Confirming site directory paths"
    _log "STEP 2.5: Confirming site directory paths"

    local source_server_ip dest_server_ip
    source_server_ip=$(_state_read ".data.source_server_ip")
    dest_server_ip=$(_state_read ".data.dest_server_ip")

    if [[ -z "$source_server_ip" || -z "$dest_server_ip" ]]; then
        _error "Missing server IPs in state. Run Step 2.1 first."
        _log "STEP 2.5 FAILED: Missing server IPs in state"
        return 1
    fi

    _loading2 "Locating wp-config.php on source..."
    local source_wp_config source_wp_rc
    source_wp_config=$(_remote_find_wp_config "$source_server_ip" "$SITE")
    source_wp_rc=$?
    if [[ $source_wp_rc -ne 0 ]]; then
        [[ -n "$source_wp_config" ]] && _debug "Source wp-config debug:\n$source_wp_config"
        _error "Could not locate wp-config.php on source server ($source_server_ip)"
        _log "STEP 2.5 FAILED: wp-config not found on source"
        return 1
    fi

    # Safety check: ensure output looks like a wp-config path
    if [[ "$source_wp_config" != /*wp-config.php ]]; then
        _debug "Unexpected source wp-config output: $source_wp_config"
        _error "Unexpected output while locating wp-config.php on source"
        _log "STEP 2.5 FAILED: Unexpected source wp-config output"
        return 1
    fi

    _loading2 "Locating wp-config.php on destination..."
    local dest_wp_config dest_wp_rc
    dest_wp_config=$(_remote_find_wp_config "$dest_server_ip" "$SITE")
    dest_wp_rc=$?
    if [[ $dest_wp_rc -ne 0 ]]; then
        [[ -n "$dest_wp_config" ]] && _debug "Dest wp-config debug:\n$dest_wp_config"
        _error "Could not locate wp-config.php on destination server ($dest_server_ip)"
        _log "STEP 2.5 FAILED: wp-config not found on destination"
        return 1
    fi

    if [[ "$dest_wp_config" != /*wp-config.php ]]; then
        _debug "Unexpected dest wp-config output: $dest_wp_config"
        _error "Unexpected output while locating wp-config.php on destination"
        _log "STEP 2.5 FAILED: Unexpected dest wp-config output"
        return 1
    fi

    local source_htdocs_path source_site_path dest_htdocs_path dest_site_path

    # GridPane structure: wp-config.php is always in site root, htdocs is site_path/htdocs
    # e.g., /var/www/site/wp-config.php -> site_path=/var/www/site, htdocs=/var/www/site/htdocs
    source_site_path=$(dirname "$source_wp_config")
    source_htdocs_path="${source_site_path}/htdocs"

    dest_site_path=$(dirname "$dest_wp_config")
    dest_htdocs_path="${dest_site_path}/htdocs"

    _success "Source wp-config: $source_wp_config"
    _loading3 "  Source htdocs: $source_htdocs_path"
    _loading3 "  Source site:   $source_site_path"
    _success "Dest wp-config:   $dest_wp_config"
    _loading3 "  Dest htdocs:   $dest_htdocs_path"
    _loading3 "  Dest site:     $dest_site_path"

    _state_write ".data.source_wp_config_path" "$source_wp_config"
    _state_write ".data.source_htdocs_path" "$source_htdocs_path"
    _state_write ".data.source_site_path" "$source_site_path"
    _state_write ".data.dest_wp_config_path" "$dest_wp_config"
    _state_write ".data.dest_htdocs_path" "$dest_htdocs_path"
    _state_write ".data.dest_site_path" "$dest_site_path"

    _state_add_completed_step "2.5"
    _log "STEP 2.5 COMPLETE: Site paths confirmed"
    echo
    return 0
}

# -----------------------------------------------------------------------------
# Step 2.3 - Get database name from wp-config.php
# Requires Step 2.5 (wp-config path)
# Stores: source_db_name, dest_db_name, db_name (canonical)
# -----------------------------------------------------------------------------
function _step_2_3() {
    _loading "Step 2.3: Reading DB_NAME from wp-config.php"
    _log "STEP 2.3: Reading DB_NAME from wp-config.php"

    local source_server_ip dest_server_ip
    source_server_ip=$(_state_read ".data.source_server_ip")
    dest_server_ip=$(_state_read ".data.dest_server_ip")
    local source_wp_config dest_wp_config
    source_wp_config=$(_state_read ".data.source_wp_config_path")
    dest_wp_config=$(_state_read ".data.dest_wp_config_path")

    if [[ -z "$source_wp_config" || -z "$dest_wp_config" ]]; then
        _error "Missing wp-config paths in state. Run Step 2.5 first."
        _log "STEP 2.3 FAILED: Missing wp-config paths"
        return 1
    fi

    local cmd
    cmd=$(cat <<'EOF'
bash -lc 'set -euo pipefail
f="$1"
dbg="${2:-0}"
db=""

# Extract $table_prefix (e.g. $table_prefix = 'wp_';)
prefix=$(sed -n "s/^[[:space:]]*\$table_prefix[[:space:]]*=[[:space:]]*['\"]\([^'\"]*\)['\"][[:space:]]*;.*/\1/p" "$f" 2>/dev/null | head -n1)

# Extract DB_NAME from define(DB_NAME, value) lines (single- or double-quoted).
sq=$(printf "%b" "\\047")
dq=$(printf "%b" "\\042")
line=$(grep -m1 "DB_NAME" "$f" 2>/dev/null || true)
if [[ -n "$line" ]]; then
    if [[ "$dbg" == "1" ]]; then
        echo "DBG: line=$line" >&2
        echo -n "DBG: sq bytes:" >&2
        printf "%s" "$sq" | od -An -t u1 >&2 || true
        echo -n "DBG: dq bytes:" >&2
        printf "%s" "$dq" | od -An -t u1 >&2 || true
    fi
    if echo "$line" | grep -q "$sq"; then
        [[ "$dbg" == "1" ]] && echo "DBG: using sq cut" >&2
        db=$(printf "%s" "$line" | cut -d"$sq" -f4)
    elif echo "$line" | grep -q "$dq"; then
        [[ "$dbg" == "1" ]] && echo "DBG: using dq cut" >&2
        db=$(printf "%s" "$line" | cut -d"$dq" -f4)
    else
        [[ "$dbg" == "1" ]] && echo "DBG: no quote delimiter matched" >&2
    fi
    [[ "$dbg" == "1" ]] && echo "DBG: extracted db=$db" >&2
fi

printf "%s|%s" "$db" "$prefix"' --
EOF
)
    cmd="${cmd%$'\n'}"

    local source_db dest_db source_table_prefix dest_table_prefix
    local source_tuple dest_tuple
    source_tuple=$(_ssh_capture "$source_server_ip" "$cmd '$source_wp_config' '$DEBUG'")
    IFS='|' read -r source_db source_table_prefix <<< "$source_tuple"
    if [[ -z "$source_db" ]]; then
        if [[ "$DEBUG" == "1" ]]; then
            local dbg_cmd dbg_out
            dbg_cmd=$(cat <<'EOF'
bash -lc 'set -euo pipefail
f="$1"
echo "--- DEBUG: source wp-config DB_NAME extraction ---"
ls -la "$f" || true
echo "--- grep DB_NAME (top 30) ---"
grep -n "DB_NAME" "$f" 2>/dev/null | head -n 30 || true
echo "--- grep define (top 30) ---"
grep -n "define" "$f" 2>/dev/null | head -n 30 || true
echo "--- END DEBUG ---"' --
EOF
)
            dbg_cmd="${dbg_cmd%$'\n'}"
            dbg_out=$(_ssh_capture "$source_server_ip" "$dbg_cmd '$source_wp_config'")
            [[ -n "$dbg_out" ]] && _debug "$dbg_out"
        fi
        _error "Could not extract DB_NAME from source wp-config ($source_wp_config)"
        _log "STEP 2.3 FAILED: Could not extract source DB_NAME"
        return 1
    fi

    dest_tuple=$(_ssh_capture "$dest_server_ip" "$cmd '$dest_wp_config' '$DEBUG'")
    IFS='|' read -r dest_db dest_table_prefix <<< "$dest_tuple"
    if [[ -z "$dest_db" ]]; then
        if [[ "$DEBUG" == "1" ]]; then
            local dbg_cmd dbg_out
            dbg_cmd=$(cat <<'EOF'
bash -lc 'set -euo pipefail
f="$1"
echo "--- DEBUG: destination wp-config DB_NAME extraction ---"
ls -la "$f" || true
echo "--- grep DB_NAME (top 30) ---"
grep -n "DB_NAME" "$f" 2>/dev/null | head -n 30 || true
echo "--- grep define (top 30) ---"
grep -n "define" "$f" 2>/dev/null | head -n 30 || true
echo "--- END DEBUG ---"' --
EOF
)
            dbg_cmd="${dbg_cmd%$'\n'}"
            dbg_out=$(_ssh_capture "$dest_server_ip" "$dbg_cmd '$dest_wp_config'")
            [[ -n "$dbg_out" ]] && _debug "$dbg_out"
        fi
        _error "Could not extract DB_NAME from destination wp-config ($dest_wp_config)"
        _log "STEP 2.3 FAILED: Could not extract destination DB_NAME"
        return 1
    fi

    _success "Source DB_NAME: $source_db"
    _success "Dest DB_NAME:   $dest_db"
    if [[ "$source_db" != "$dest_db" ]]; then
        _warning "DB_NAME differs between source and destination"
    fi

    _state_write ".data.source_db_name" "$source_db"
    _state_write ".data.dest_db_name" "$dest_db"
    _state_write ".data.db_name" "$source_db"

    [[ -z "$source_table_prefix" || "$source_table_prefix" == "null" ]] && source_table_prefix="wp_"
    [[ -z "$dest_table_prefix" || "$dest_table_prefix" == "null" ]] && dest_table_prefix="wp_"
    _state_write ".data.source_table_prefix" "$source_table_prefix"
    _state_write ".data.dest_table_prefix" "$dest_table_prefix"
    _state_write ".data.table_prefix" "$source_table_prefix"

    _state_add_completed_step "2.3"
    _log "STEP 2.3 COMPLETE: DB_NAME extracted"
    echo
    return 0
}

# -----------------------------------------------------------------------------
# Step 2.4 - Confirm database exists on both servers
# Requires Step 2.3
# -----------------------------------------------------------------------------
function _step_2_4() {
    _loading "Step 2.4: Confirming database exists"
    _log "STEP 2.4: Confirming database exists"

    local source_server_ip dest_server_ip
    source_server_ip=$(_state_read ".data.source_server_ip")
    dest_server_ip=$(_state_read ".data.dest_server_ip")
    local source_db dest_db
    source_db=$(_state_read ".data.source_db_name")
    dest_db=$(_state_read ".data.dest_db_name")

    if [[ -z "$source_db" || -z "$dest_db" ]]; then
        _error "Missing DB names in state. Run Step 2.3 first."
        _log "STEP 2.4 FAILED: Missing DB names"
        return 1
    fi

    local check_cmd
    check_cmd=$(cat <<'EOF'
bash -lc 'set -euo pipefail
db="$1"
if ! command -v mysql >/dev/null 2>&1; then
  echo "NO_MYSQL"
  exit 2
fi

# Build query with single quotes without embedding literal single quotes in this script.
sq=$(printf "%b" "\\047")
q="SHOW DATABASES LIKE ${sq}${db}${sq}"
mysql -N -e "$q" 2>/dev/null | head -n1' --
EOF
)
    check_cmd="${check_cmd%$'\n'}"

    local out
    _loading2 "Checking source DB exists: $source_db"
    out=$(_ssh_capture "$source_server_ip" "$check_cmd '$source_db'")
    if [[ "$out" == "NO_MYSQL" ]]; then
        _error "mysql client not found on source server"
        _log "STEP 2.4 FAILED: mysql client not found on source"
        return 1
    fi
    if [[ "$out" != "$source_db" ]]; then
        _error "Database not found on source server: $source_db"
        _log "STEP 2.4 FAILED: Source DB missing"
        return 1
    fi
    _success "Source DB exists"

    _loading2 "Checking destination DB exists: $dest_db"
    out=$(_ssh_capture "$dest_server_ip" "$check_cmd '$dest_db'")
    if [[ "$out" == "NO_MYSQL" ]]; then
        _error "mysql client not found on destination server"
        _log "STEP 2.4 FAILED: mysql client not found on destination"
        return 1
    fi
    if [[ "$out" != "$dest_db" ]]; then
        _error "Database not found on destination server: $dest_db"
        _log "STEP 2.4 FAILED: Destination DB missing"
        return 1
    fi
    _success "Destination DB exists"

    _state_add_completed_step "2.4"
    _log "STEP 2.4 COMPLETE: Databases exist"
    echo
    return 0
}

# -----------------------------------------------------------------------------
# Step 2 - Wrapper that calls all sub-steps
# This can be called directly or each sub-step can be run individually
# -----------------------------------------------------------------------------
function _step_2() {
    _loading "Step 2: Server Discovery and SSH Validation"
    _log "STEP 2: Starting server discovery and SSH validation"

    _step_2_1 || return 1
    _step_2_2 || return 1
    _step_2_5 || return 1
    _step_2_3 || return 1
    _step_2_4 || return 1

    _state_add_completed_step "2"
    _log "STEP 2 COMPLETE: Server discovery and SSH validation done"
    return 0
}

function _normalize_htdocs_path() {
    local host_ip="$1"
    local current_path="$2"
    local state_key="$3"

    if [[ -z "$host_ip" || -z "$current_path" ]]; then
        return 1
    fi

    # Already looks like an htdocs path.
    if [[ "$current_path" == */htdocs ]]; then
        echo "$current_path"
        return 0
    fi

    local candidate
    candidate="${current_path%/}/htdocs"

    # Prefer the common GridPane layout: <site_root>/htdocs
    local has_candidate
    has_candidate=$(_ssh_capture "$host_ip" "test -d '$candidate' && echo yes || echo no")
    if [[ "$has_candidate" == "yes" ]]; then
        _warning "State htdocs path looks like site root: '$current_path'"
        _loading3 "Using detected htdocs: '$candidate'"
        if [[ -n "$state_key" ]]; then
            _state_write "$state_key" "$candidate"
        fi
        echo "$candidate"
        return 0
    fi

    # Fallback: if the current path itself appears to be a WordPress docroot, accept it.
    local looks_like_wp_root
    looks_like_wp_root=$(_ssh_capture "$host_ip" "test -d '$current_path/wp-admin' -a -d '$current_path/wp-includes' && echo yes || echo no")
    if [[ "$looks_like_wp_root" == "yes" ]]; then
        echo "$current_path"
        return 0
    fi

    _error "Could not determine htdocs directory from '$current_path' on $host_ip"
    _log "HTDOCS NORMALIZE FAILED: current_path='$current_path', host='$host_ip'"
    return 1
}

# -----------------------------------------------------------------------------
# Step 3.1 - Confirm rsync is installed on source server
# Requires Step 2.1 (server IPs)
# -----------------------------------------------------------------------------
function _step_3_1() {
    _loading "Step 3.1: Verifying rsync on source server"
    _log "STEP 3.1: Verifying rsync on source server"

    local source_server_ip
    source_server_ip=$(_state_read ".data.source_server_ip")

    if [[ -z "$source_server_ip" ]]; then
        _error "Missing source server IP in state. Run Step 2.1 first."
        _log "STEP 3.1 FAILED: Missing source server IP"
        return 1
    fi

    local rsync_path
    rsync_path=$(_ssh_capture "$source_server_ip" "which rsync 2>/dev/null || command -v rsync 2>/dev/null")

    if [[ -z "$rsync_path" ]]; then
        _error "rsync not found on source server ($source_server_ip)"
        _loading3 "Install rsync: apt-get install rsync"
        _log "STEP 3.1 FAILED: rsync not found on source"
        return 1
    fi

    _success "rsync found on source: $rsync_path"
    _state_write ".data.source_rsync_path" "$rsync_path"
    _state_add_completed_step "3.1"
    _log "STEP 3.1 COMPLETE: rsync verified on source"
    echo
    return 0
}

# -----------------------------------------------------------------------------
# Step 3.2 - Confirm rsync is installed on destination and htdocs is writable
# Requires Step 2.1, 2.5 (server IPs and htdocs path)
# -----------------------------------------------------------------------------
function _step_3_2() {
    _loading "Step 3.2: Verifying rsync on destination server"
    _log "STEP 3.2: Verifying rsync on destination server"

    local dest_server_ip dest_htdocs_path
    dest_server_ip=$(_state_read ".data.dest_server_ip")
    dest_htdocs_path=$(_state_read ".data.dest_htdocs_path")

    if [[ -z "$dest_server_ip" ]]; then
        _error "Missing destination server IP in state. Run Step 2.1 first."
        _log "STEP 3.2 FAILED: Missing destination server IP"
        return 1
    fi

    if [[ -z "$dest_htdocs_path" ]]; then
        _error "Missing destination htdocs path in state. Run Step 2.5 first."
        _log "STEP 3.2 FAILED: Missing destination htdocs path"
        return 1
    fi

    dest_htdocs_path=$(_normalize_htdocs_path "$dest_server_ip" "$dest_htdocs_path" ".data.dest_htdocs_path") || return 1

    # Verify rsync is installed
    local rsync_path
    rsync_path=$(_ssh_capture "$dest_server_ip" "which rsync 2>/dev/null || command -v rsync 2>/dev/null")

    if [[ -z "$rsync_path" ]]; then
        _error "rsync not found on destination server ($dest_server_ip)"
        _loading3 "Install rsync: apt-get install rsync"
        _log "STEP 3.2 FAILED: rsync not found on destination"
        return 1
    fi

    _success "rsync found on destination: $rsync_path"

    # Verify htdocs directory is writable
    _loading2 "Verifying htdocs is writable on destination..."
    local write_test
    write_test=$(_ssh_capture "$dest_server_ip" "test -w '$dest_htdocs_path' && echo 'writable' || echo 'not_writable'")

    if [[ "$write_test" != "writable" ]]; then
        _error "htdocs not writable on destination: $dest_htdocs_path"
        _log "STEP 3.2 FAILED: htdocs not writable on destination"
        return 1
    fi

    _success "htdocs is writable on destination"
    _state_write ".data.dest_rsync_path" "$rsync_path"
    _state_add_completed_step "3.2"
    _log "STEP 3.2 COMPLETE: rsync verified on destination, htdocs writable"
    echo
    return 0
}

# -----------------------------------------------------------------------------
# Step 3.3 - Ensure destination server SSH key is authorized on source server
#
# Remote rsync runs ON the destination server, pulling FROM the source server.
# That requires destination->source SSH auth (root user only).
#
# This step:
#   3.3.1 - Test if destination can already SSH to source (skip if yes)
#   3.3.2 - Fetch destination /root/.ssh/id_rsa.pub
#   3.3.3 - Validate source /root/.ssh/authorized_keys exists
#   3.3.4 - Append destination pubkey to source authorized_keys (if not present)
#   3.3.5 - Prime known_hosts on destination for source
# -----------------------------------------------------------------------------
function _step_3_3() {
    _loading "Step 3.3: Authorizing destination SSH key on source"
    _log "STEP 3.3: Authorizing destination SSH key on source"

    local source_server_ip dest_server_ip
    source_server_ip=$(_state_read ".data.source_server_ip")
    dest_server_ip=$(_state_read ".data.dest_server_ip")

    if [[ -z "$source_server_ip" || -z "$dest_server_ip" ]]; then
        _error "Missing server IPs in state. Run Step 2.1 first."
        _log "STEP 3.3 FAILED: Missing server IPs"
        return 1
    fi

    # -------------------------------------------------------------------------
    # 3.3.1 - Test if destination can already SSH to source
    # -------------------------------------------------------------------------
    _loading2 "3.3.1: Testing if destination can SSH to source..."
    local ssh_test_result ssh_test_rc
    ssh_test_result=$(_ssh_capture "$dest_server_ip" "ssh -o ConnectTimeout=5 -o BatchMode=yes root@$source_server_ip 'echo ok' 2>&1")
    ssh_test_rc=$?

    if [[ $ssh_test_rc -eq 0 && "$ssh_test_result" == "ok" ]]; then
        _success "Destination already has SSH access to source, skipping key setup"
        _log "STEP 3.3.1: Destination already authorized on source"
        _state_add_completed_step "3.3"
        _log "STEP 3.3 COMPLETE: Destination already authorized on source"
        echo
        return 0
    fi
    _debug "3.3.1: SSH test failed (rc=$ssh_test_rc), proceeding with key setup"

    # -------------------------------------------------------------------------
    # 3.3.2 - Fetch destination public key
    # -------------------------------------------------------------------------
    _loading2 "3.3.2: Fetching destination public key (/root/.ssh/id_rsa.pub)..."
    local dest_pubkey
    dest_pubkey=$(_ssh_capture "$dest_server_ip" "cat /root/.ssh/id_rsa.pub 2>/dev/null")
    local fetch_rc=$?
    dest_pubkey="$(echo "$dest_pubkey" | head -n 1 | tr -d '\r')"

    if [[ $fetch_rc -ne 0 || -z "$dest_pubkey" ]]; then
        _error "Failed to fetch destination public key: root@$dest_server_ip:/root/.ssh/id_rsa.pub"
        _loading3 "Fix: generate a key on destination (e.g., ssh-keygen -t rsa -N '' -f /root/.ssh/id_rsa)"
        _log "STEP 3.3.2 FAILED: Could not fetch destination id_rsa.pub"
        return 1
    fi

    _debug "3.3.2: Destination public key: $dest_pubkey"
    _success "Fetched destination public key"

    # -------------------------------------------------------------------------
    # 3.3.3 - Validate source authorized_keys exists
    # -------------------------------------------------------------------------
    _loading2 "3.3.3: Checking if source /root/.ssh/authorized_keys exists..."
    _ssh_capture "$source_server_ip" "test -f /root/.ssh/authorized_keys" >/dev/null 2>&1
    local test_rc=$?

    if [[ $test_rc -ne 0 ]]; then
        _error "Source /root/.ssh/authorized_keys does not exist"
        _loading3 "Fix: create the file on source (e.g., touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys)"
        _log "STEP 3.3.3 FAILED: Source authorized_keys does not exist"
        return 1
    fi
    _success "Source authorized_keys exists"

    # -------------------------------------------------------------------------
    # 3.3.4 - Append destination pubkey to source authorized_keys
    # Note: This runs even in dry-run mode (SSH key setup is safe and required)
    # -------------------------------------------------------------------------
    _loading2 "3.3.4: Appending destination key to source authorized_keys..."

    # Check if key already present
    local key_b64
    key_b64=$(printf "%s" "$dest_pubkey" | base64 -w0 2>/dev/null || printf "%s" "$dest_pubkey" | base64 2>/dev/null | tr -d '\n')

    local check_and_append_cmd
    check_and_append_cmd="pubkey=\$(echo '$key_b64' | base64 -d 2>/dev/null || echo '$key_b64' | base64 --decode 2>/dev/null); if grep -qxF \"\$pubkey\" /root/.ssh/authorized_keys; then echo ALREADY_PRESENT; else printf '%s\n' \"\$pubkey\" >> /root/.ssh/authorized_keys && echo ADDED; fi"

    local append_result append_rc
    append_result=$(_ssh_capture "$source_server_ip" "$check_and_append_cmd")
    append_rc=$?

    if [[ $append_rc -ne 0 ]]; then
        _error "Failed to append key to source authorized_keys"
        _log "STEP 3.3.4 FAILED: Could not append key"
        return 1
    fi

    if [[ "$append_result" == "ALREADY_PRESENT" ]]; then
        _success "Destination key already present on source"
    else
        _success "Destination key added to source authorized_keys"
    fi

    # -------------------------------------------------------------------------
    # 3.3.5 - Prime known_hosts on destination for source
    # -------------------------------------------------------------------------
    _loading2 "3.3.5: Priming destination known_hosts for source..."
    if [[ "$DRY_RUN" == "1" ]]; then
        _dry_run_msg "Would prime known_hosts on destination for source"
    else
        _ssh_capture "$dest_server_ip" "ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@$source_server_ip 'echo ok' >/dev/null 2>&1 || true" >/dev/null
        _success "Known hosts primed"
    fi

    _state_add_completed_step "3.3"
    _log "STEP 3.3 COMPLETE: Destination key authorized on source"
    echo
    return 0
}

# -----------------------------------------------------------------------------
# Step 3.4 - Rsync htdocs from source to destination
# Requires Step 3.1, 3.2, 3.3, 2.5
# Uses SSH tunneling: rsync from source to local, pipe to destination
# Or direct rsync if source can reach destination
# -----------------------------------------------------------------------------
function _step_3_4() {
    _loading "Step 3.4: Syncing htdocs from source to destination"
    _log "STEP 3.4: Syncing htdocs from source to destination"

    local source_server_ip dest_server_ip source_htdocs_path dest_htdocs_path
    source_server_ip=$(_state_read ".data.source_server_ip")
    dest_server_ip=$(_state_read ".data.dest_server_ip")
    source_htdocs_path=$(_state_read ".data.source_htdocs_path")
    dest_htdocs_path=$(_state_read ".data.dest_htdocs_path")

    if [[ -z "$source_server_ip" || -z "$dest_server_ip" ]]; then
        _error "Missing server IPs in state. Run Step 2.1 first."
        _log "STEP 3.4 FAILED: Missing server IPs"
        return 1
    fi

    if [[ -z "$source_htdocs_path" || -z "$dest_htdocs_path" ]]; then
        _error "Missing htdocs paths in state. Run Step 2.5 first."
        _log "STEP 3.4 FAILED: Missing htdocs paths"
        return 1
    fi

    source_htdocs_path=$(_normalize_htdocs_path "$source_server_ip" "$source_htdocs_path" ".data.source_htdocs_path") || return 1
    dest_htdocs_path=$(_normalize_htdocs_path "$dest_server_ip" "$dest_htdocs_path" ".data.dest_htdocs_path") || return 1

    local ssh_user
    ssh_user=$(_state_read ".data.ssh_user")
    [[ -z "$ssh_user" ]] && ssh_user="${GPBC_SSH_USER:-root}"

    local known_hosts_file
    known_hosts_file="${STATE_DIR}/gp-site-mig-${SITE}-known_hosts"

    # Build SSH options for rsync
    local ssh_opts="ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$known_hosts_file"

    # Build rsync command
    # --archive: -rlptgoD (recursive, links, permissions, times, group, owner, devices)
    # --compress: compress during transfer
    # --verbose: increase verbosity
    # --progress: show progress during transfer
    # --delete: delete extraneous files from destination
    # --exclude: common exclusions for WordPress
    local rsync_excludes=(
        "--exclude=.DS_Store"
        "--exclude=wp-config.php"
        "--exclude=.htaccess"
    )

    local rsync_opts="-avz --progress --delete ${rsync_excludes[*]}"

    # Add --dry-run if DRY_RUN is enabled
    if [[ "$DRY_RUN" == "1" ]]; then
        rsync_opts="$rsync_opts --dry-run"
        _dry_run_msg "rsync will run in dry-run mode"
    fi

    _loading2 "Source: $ssh_user@$source_server_ip:$source_htdocs_path/"
    _loading2 "Dest:   $ssh_user@$dest_server_ip:$dest_htdocs_path/"
    _verbose "rsync options: $rsync_opts"

    # Method: Use rsync with SSH to pull from source to destination
    # We run rsync from the local machine, connecting to both servers
    # rsync -e ssh source:path/ -e ssh dest:path/ doesn't work directly
    # Instead, we rsync from source to dest by running rsync ON the destination server
    # pulling from the source server.

    # First, check whether destination can SSH to source.
    # By default we STOP if this is not possible.
    # The relay fallback (pull to local, push to dest) is opt-in via --rsync-local.

    _loading2 "Checking if destination can reach source (required for remote rsync)..."
    local can_reach
    can_reach=$(_ssh_capture "$dest_server_ip" "ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new $ssh_user@$source_server_ip 'echo ok' 2>/dev/null || echo 'CANNOT_REACH'")

    if [[ "$can_reach" == "ok" ]]; then
        # Destination can SSH to source - run rsync on destination pulling from source
        _loading2 "Direct rsync: destination will pull from source"
        _log "RSYNC: Direct mode - destination pulling from source"

        local remote_rsync_cmd
        remote_rsync_cmd="rsync $rsync_opts -e 'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' $ssh_user@$source_server_ip:$source_htdocs_path/ $dest_htdocs_path/"

        _debug "Remote rsync command: $remote_rsync_cmd"

        # Run rsync on destination server
        local rsync_output rsync_rc
        rsync_output=$(_ssh_capture "$dest_server_ip" "$remote_rsync_cmd" 2>&1)
        rsync_rc=$?

        # Log the output
        _log "RSYNC OUTPUT START"
        echo "$rsync_output" | while IFS= read -r line; do
            _log "  $line"
        done
        _log "RSYNC OUTPUT END (exit code: $rsync_rc)"

        # Show truncated output to user
        local line_count
        line_count=$(echo "$rsync_output" | wc -l)
        if [[ $line_count -gt 20 ]]; then
            echo "$rsync_output" | head -10
            _loading3 "... ($((line_count - 20)) more lines) ..."
            echo "$rsync_output" | tail -10
        else
            echo "$rsync_output"
        fi

        if [[ $rsync_rc -ne 0 ]]; then
            _error "rsync failed with exit code $rsync_rc"
            _log "STEP 3.4 FAILED: rsync exit code $rsync_rc"
            return 1
        fi
    else
        _warning "Destination cannot SSH to source directly"

        if [[ "$RSYNC_LOCAL" != "1" ]]; then
            _error "Remote rsync requires destination->source SSH access"
            _loading3 "Fix: allow SSH from destination to source (keys/known_hosts/firewall)"
            _loading3 "Or re-run with --rsync-local to relay via local machine"
            _log "STEP 3.4 FAILED: Destination cannot SSH to source; RSYNC_LOCAL=0"
            return 1
        fi

        # Relay method through local machine (opt-in)
        _loading2 "Relay rsync (--rsync-local): local machine will relay files"
        _log "RSYNC: Relay mode - local machine relaying files"
        _loading3 "This is slower but works without dest->source SSH"

        # Create a temporary directory for relay
        local tmp_dir
        tmp_dir=$(mktemp -d -t gp-site-mig-rsync-XXXXXX)
        _verbose "Temp directory: $tmp_dir"

        # Step 1: rsync from source to local temp
        _loading2 "Pulling from source to local..."
        local pull_cmd
        pull_cmd="rsync $rsync_opts -e \"$ssh_opts\" $ssh_user@$source_server_ip:$source_htdocs_path/ $tmp_dir/"

        _debug "Pull command: $pull_cmd"

        local pull_output pull_rc
        pull_output=$(eval "$pull_cmd" 2>&1)
        pull_rc=$?

        _log "RSYNC PULL OUTPUT START"
        echo "$pull_output" | while IFS= read -r line; do
            _log "  $line"
        done
        _log "RSYNC PULL OUTPUT END (exit code: $pull_rc)"

        if [[ $pull_rc -ne 0 ]]; then
            _error "rsync pull from source failed with exit code $pull_rc"
            rm -rf "$tmp_dir"
            _log "STEP 3.4 FAILED: rsync pull exit code $pull_rc"
            return 1
        fi

        _success "Pulled files from source"

        # Step 2: rsync from local temp to destination
        _loading2 "Pushing to destination..."
        local push_cmd
        push_cmd="rsync $rsync_opts -e \"$ssh_opts\" $tmp_dir/ $ssh_user@$dest_server_ip:$dest_htdocs_path/"

        _debug "Push command: $push_cmd"

        local push_output push_rc
        push_output=$(eval "$push_cmd" 2>&1)
        push_rc=$?

        _log "RSYNC PUSH OUTPUT START"
        echo "$push_output" | while IFS= read -r line; do
            _log "  $line"
        done
        _log "RSYNC PUSH OUTPUT END (exit code: $push_rc)"

        # Cleanup temp directory
        rm -rf "$tmp_dir"

        if [[ $push_rc -ne 0 ]]; then
            _error "rsync push to destination failed with exit code $push_rc"
            _log "STEP 3.4 FAILED: rsync push exit code $push_rc"
            return 1
        fi

        _success "Pushed files to destination"
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        _dry_run_msg "No files were actually transferred (dry-run mode)"
    else
        _success "Files synced successfully"
    fi

    _state_add_completed_step "3.4"
    _log "STEP 3.4 COMPLETE: htdocs synced"
    echo
    return 0
}

# -----------------------------------------------------------------------------
# Step 3 - Wrapper that calls all sub-steps
# Test rsync and migrate files
# -----------------------------------------------------------------------------
function _step_3() {
    _loading "Step 3: Test Rsync and Migrate Files"
    _log "STEP 3: Starting rsync and file migration"

    _run_step "3.1" _step_3_1 || return 1
    _run_step "3.2" _step_3_2 || return 1
    _run_step "3.3" _step_3_3 || return 1
    _run_step "3.4" _step_3_4 || return 1

    _state_add_completed_step "3"
    _log "STEP 3 COMPLETE: File migration done"
    return 0
}

# -----------------------------------------------------------------------------
# Step 4 - Migrate Database
# Export database from source using mysqldump, pipe to mysql on destination via SSH
# Requires Step 2.1 (server IPs), Step 2.3 (database names)
# -----------------------------------------------------------------------------
function _step_4() {
    _loading "Step 4: Migrating database"
    _log "STEP 4: Starting database migration"

    local source_server_ip dest_server_ip source_db dest_db
    source_server_ip=$(_state_read ".data.source_server_ip")
    dest_server_ip=$(_state_read ".data.dest_server_ip")
    source_db=$(_state_read ".data.source_db_name")
    dest_db=$(_state_read ".data.dest_db_name")

    if [[ -z "$source_server_ip" || -z "$dest_server_ip" ]]; then
        _loading2 "Missing server IPs, running Step 2.1..."
        if ! _step_2_1; then
            _error "Failed to run prerequisite Step 2.1"
            _log "STEP 4 FAILED: Prerequisite Step 2.1 failed"
            return 1
        fi
        source_server_ip=$(_state_read ".data.source_server_ip")
        dest_server_ip=$(_state_read ".data.dest_server_ip")
    fi

    if [[ -z "$source_db" || -z "$dest_db" ]]; then
        # Step 2.3 requires Step 2.5 (site paths) first
        local source_htdocs_path dest_htdocs_path
        source_htdocs_path=$(_state_read ".data.source_htdocs_path")
        dest_htdocs_path=$(_state_read ".data.dest_htdocs_path")
        if [[ -z "$source_htdocs_path" || -z "$dest_htdocs_path" ]]; then
            _loading2 "Missing site paths, running Step 2.5..."
            if ! _step_2_5; then
                _error "Failed to run prerequisite Step 2.5"
                _log "STEP 4 FAILED: Prerequisite Step 2.5 failed"
                return 1
            fi
        fi
        _loading2 "Missing DB names, running Step 2.3..."
        if ! _step_2_3; then
            _error "Failed to run prerequisite Step 2.3"
            _log "STEP 4 FAILED: Prerequisite Step 2.3 failed"
            return 1
        fi
        source_db=$(_state_read ".data.source_db_name")
        dest_db=$(_state_read ".data.dest_db_name")
    fi

    local ssh_user
    ssh_user=$(_state_read ".data.ssh_user")
    [[ -z "$ssh_user" ]] && ssh_user="${GPBC_SSH_USER:-root}"

    local known_hosts_file
    known_hosts_file="${STATE_DIR}/gp-site-mig-${SITE}-known_hosts"

    # Build SSH options array for proper argument handling
    local ssh_opts_array=(-o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$known_hosts_file")

    _loading2 "Source DB: $source_db on $ssh_user@$source_server_ip"
    _loading2 "Dest DB:   $dest_db on $ssh_user@$dest_server_ip"

    # Validate database names to prevent command injection
    # Database names in MySQL can contain alphanumeric, underscore, and some special chars
    # Check for presence of dangerous shell metacharacters
    if [[ "$source_db" =~ [\$\;\|\&\`\<\>\(\)] ]]; then
        _error "Source database name contains potentially unsafe characters: $source_db"
        _log "STEP 4 FAILED: Unsafe source database name"
        return 1
    fi
    
    if [[ "$dest_db" =~ [\$\;\|\&\`\<\>\(\)] ]]; then
        _error "Destination database name contains potentially unsafe characters: $dest_db"
        _log "STEP 4 FAILED: Unsafe destination database name"
        return 1
    fi

    # Build mysqldump command for source
    # --single-transaction: for InnoDB tables, consistent backup without locking
    # --quick: retrieve rows one at a time rather than all at once
    # --lock-tables=false: don't lock tables (use with single-transaction)
    # --routines: dump stored procedures and functions
    # --triggers: dump triggers
    # Note: GridPane servers typically have MySQL configured with defaults-file or socket auth
    # If credentials are needed, they should be in ~/.my.cnf on the respective servers
    
    # Use printf to safely escape database name
    local safe_source_db safe_dest_db
    safe_source_db=$(printf '%q' "$source_db")
    safe_dest_db=$(printf '%q' "$dest_db")
    
    local mysqldump_cmd="mysqldump --single-transaction --quick --lock-tables=false --routines --triggers $safe_source_db"
    local mysql_cmd="mysql $safe_dest_db"

    local source_table_prefix dest_table_prefix
    source_table_prefix=$(_state_read ".data.source_table_prefix")
    dest_table_prefix=$(_state_read ".data.dest_table_prefix")
    [[ -z "$source_table_prefix" || "$source_table_prefix" == "null" ]] && source_table_prefix="wp_"
    [[ -z "$dest_table_prefix" || "$dest_table_prefix" == "null" ]] && dest_table_prefix="$source_table_prefix"

    local source_options_table="${source_table_prefix}options"
    local dest_options_table="${dest_table_prefix}options"

    # Check if migration marker already exists in destination database
    _loading2 "Checking for existing migration marker in destination..."
    local existing_marker_sql="SELECT option_value FROM ${dest_options_table} WHERE option_name='wp_miggp';"
    local existing_marker existing_marker_rc
    existing_marker=$(ssh "${ssh_opts_array[@]}" "$ssh_user@$dest_server_ip" "mysql -N $safe_dest_db -e \"$existing_marker_sql\"" 2>&1)
    existing_marker_rc=$?

    if [[ $existing_marker_rc -ne 0 && "$dest_options_table" != "$source_options_table" ]]; then
        existing_marker_sql="SELECT option_value FROM ${source_options_table} WHERE option_name='wp_miggp';"
        existing_marker=$(ssh "${ssh_opts_array[@]}" "$ssh_user@$dest_server_ip" "mysql -N $safe_dest_db -e \"$existing_marker_sql\"" 2>&1)
        existing_marker_rc=$?
    fi

    if [[ $existing_marker_rc -eq 0 && -n "$existing_marker" && "$existing_marker" == gpbc_mig_* ]]; then
        _warning "Migration marker already exists in destination database!"
        _warning "  Existing marker: $existing_marker"
        _log "Existing migration marker found: $existing_marker"
        
        if [[ "$SKIP_DB" == "1" ]]; then
            _warning "Skipping database migration (--skip-db is set)"
            _log "STEP 4 SKIPPED: Existing marker found, --skip-db set"
            _mark_step_complete 4
            return 0
        elif [[ "$FORCE_DB" != "1" ]]; then
            _error "Database migration aborted to prevent overwriting existing migration."
            _error "Use --force-db to override this check and migrate anyway."
            _error "Use --skip-db to skip database migration and continue."
            _log "STEP 4 ABORTED: Existing marker found, --force-db not set"
            return 1
        else
            _warning "Proceeding with database migration (--force-db is set)"
            _log "Proceeding despite existing marker (--force-db enabled)"
        fi
    else
        _verbose "No existing migration marker found in destination"
    fi

    # Generate a unique migration marker ID to verify the migration
    local migration_marker_id
    migration_marker_id="gpbc_mig_$(date +%s)_$$_$RANDOM"
    _loading2 "Inserting migration marker: $migration_marker_id"
    _log "Migration marker ID: $migration_marker_id"

    # Insert marker into source database {prefix}options table
    local marker_insert_sql="INSERT INTO ${source_options_table} (option_name, option_value, autoload) VALUES ('wp_miggp', '$migration_marker_id', 'no') ON DUPLICATE KEY UPDATE option_value='$migration_marker_id';"
    local marker_output marker_rc
    marker_output=$(ssh "${ssh_opts_array[@]}" "$ssh_user@$source_server_ip" "mysql $safe_source_db -e \"$marker_insert_sql\"" 2>&1)
    marker_rc=$?

    if [[ $marker_rc -ne 0 ]]; then
        _error "Failed to insert migration marker into source database"
        [[ -n "$marker_output" ]] && _error "Output: $marker_output"
        _log "STEP 4 FAILED: Could not insert migration marker"
        return 1
    fi
    _verbose "Migration marker inserted into source database"

    # Store marker ID in state for verification
    _state_write ".data.migration_marker_id" "$migration_marker_id"

    # Check if file-based migration is requested
    if [[ "$DB_FILE" == "1" ]]; then
        _loading2 "Using file-based database migration (dump, gzip, transfer, import)"
        
        # Generate unique filename with timestamp
        local timestamp
        timestamp=$(date '+%Y%m%d-%H%M%S')
        local db_filename="${source_db}_${timestamp}.sql.gz"
        local source_db_path="/tmp/${db_filename}"
        local dest_db_path="/tmp/${db_filename}"
        
        _verbose "Database file: $db_filename"
        _verbose "Source path: $source_db_path"
        _verbose "Dest path: $dest_db_path"
        
        if [[ "$DRY_RUN" == "1" ]]; then
            _dry_run_msg "Would execute file-based database migration:"
            _dry_run_msg "  1. ssh $ssh_user@$source_server_ip \"$mysqldump_cmd | gzip > $source_db_path\""
            _dry_run_msg "  2. scp $ssh_user@$source_server_ip:$source_db_path $ssh_user@$dest_server_ip:$dest_db_path"
            _dry_run_msg "  3. ssh $ssh_user@$dest_server_ip \"gunzip < $dest_db_path | $mysql_cmd\""
            _dry_run_msg "  4. Cleanup temp files on both servers"
            _log "STEP 4 DRY-RUN: Would migrate database via file"
            _state_add_completed_step "4"
            echo
            return 0
        fi
        
        _loading2 "Step 1/4: Dumping database on source and compressing..."
        local dump_output dump_rc
        dump_output=$(ssh "${ssh_opts_array[@]}" "$ssh_user@$source_server_ip" "$mysqldump_cmd | gzip > $source_db_path" 2>&1)
        dump_rc=$?
        
        _log "DATABASE DUMP OUTPUT: $dump_output"
        
        if [[ $dump_rc -ne 0 ]]; then
            _error "Database dump failed (exit code: $dump_rc)"
            [[ -n "$dump_output" ]] && _error "Output: $dump_output"
            _log "STEP 4 FAILED: Database dump error (rc=$dump_rc)"
            return 1
        fi
        _success "Database dumped and compressed on source"
        
        _loading2 "Step 2/4: Transferring compressed database file..."
        local transfer_output transfer_rc
        transfer_output=$(ssh "${ssh_opts_array[@]}" "$ssh_user@$source_server_ip" "cat $source_db_path" 2>&1 | ssh "${ssh_opts_array[@]}" "$ssh_user@$dest_server_ip" "cat > $dest_db_path" 2>&1)
        transfer_rc=$?
        
        _log "DATABASE TRANSFER OUTPUT: $transfer_output"
        
        if [[ $transfer_rc -ne 0 ]]; then
            _error "Database file transfer failed (exit code: $transfer_rc)"
            [[ -n "$transfer_output" ]] && _error "Output: $transfer_output"
            _log "STEP 4 FAILED: Database transfer error (rc=$transfer_rc)"
            # Cleanup source file
            ssh "${ssh_opts_array[@]}" "$ssh_user@$source_server_ip" "rm -f $source_db_path" 2>/dev/null || true
            return 1
        fi
        _success "Database file transferred to destination"
        
        _loading2 "Step 3/4: Importing database on destination..."
        local import_output import_rc
        import_output=$(ssh "${ssh_opts_array[@]}" "$ssh_user@$dest_server_ip" "gunzip < $dest_db_path | $mysql_cmd" 2>&1)
        import_rc=$?
        
        _log "DATABASE IMPORT OUTPUT START"
        _log "$import_output"
        _log "DATABASE IMPORT OUTPUT END"
        
        if [[ $import_rc -ne 0 ]]; then
            _error "Database import failed (exit code: $import_rc)"
            if [[ -n "$import_output" ]]; then
                _error "Error output:"
                echo "$import_output" | while IFS= read -r line; do
                    _error "  $line"
                done
            fi
            _log "STEP 4 FAILED: Database import error (rc=$import_rc)"
            # Cleanup files on both servers
            ssh "${ssh_opts_array[@]}" "$ssh_user@$source_server_ip" "rm -f $source_db_path" 2>/dev/null || true
            ssh "${ssh_opts_array[@]}" "$ssh_user@$dest_server_ip" "rm -f $dest_db_path" 2>/dev/null || true
            return 1
        fi
        _success "Database imported successfully"
        
        _loading2 "Step 4/4: Cleaning up temporary files..."
        ssh "${ssh_opts_array[@]}" "$ssh_user@$source_server_ip" "rm -f $source_db_path" 2>/dev/null || true
        ssh "${ssh_opts_array[@]}" "$ssh_user@$dest_server_ip" "rm -f $dest_db_path" 2>/dev/null || true
        _success "Temporary files cleaned up"
        
        # Check if there were any warnings in the import output
        if echo "$import_output" | grep -Ei "^(warning|error|failed|cannot|denied)" | grep -qv "0 warnings"; then
            _warning "Database migration completed but with warnings:"
            echo "$import_output" | grep -Ei "^(warning|error|failed|cannot|denied)" | grep -v "0 warnings" | while IFS= read -r line; do
                _loading3 "  $line"
            done
        fi
        
        _success "Database migrated successfully via file transfer"
        _loading3 "  Exported from: $source_db"
        _loading3 "  Imported to:   $dest_db"
        _loading3 "  Method: File-based (gzipped)"
    else
        # Original direct piping method
        _loading2 "Using direct pipe database migration"
        
        _verbose "Database migration command:"
        _verbose "  ssh ${ssh_opts_array[*]} $ssh_user@$source_server_ip \"$mysqldump_cmd\""
        _verbose "  | ssh ${ssh_opts_array[*]} $ssh_user@$dest_server_ip \"$mysql_cmd\""

        if [[ "$DRY_RUN" == "1" ]]; then
            _dry_run_msg "Would execute database migration:"
            _dry_run_msg "  ssh ${ssh_opts_array[*]} $ssh_user@$source_server_ip \"$mysqldump_cmd\""
            _dry_run_msg "  | ssh ${ssh_opts_array[*]} $ssh_user@$dest_server_ip \"$mysql_cmd\""
            _log "STEP 4 DRY-RUN: Would migrate database"
            _state_add_completed_step "4"
            echo
            return 0
        fi

        _loading2 "Exporting database from source and importing to destination..."
        _loading3 "This may take several minutes depending on database size..."

        # Execute the database migration with error handling
        # Use command arrays to avoid eval and properly handle arguments
        local db_output db_rc
        db_output=$(ssh "${ssh_opts_array[@]}" "$ssh_user@$source_server_ip" "$mysqldump_cmd" 2>&1 | ssh "${ssh_opts_array[@]}" "$ssh_user@$dest_server_ip" "$mysql_cmd" 2>&1)
        db_rc=$?

        # Log the output
        _log "DATABASE MIGRATION OUTPUT START"
        _log "$db_output"
        _log "DATABASE MIGRATION OUTPUT END"

        if [[ $db_rc -ne 0 ]]; then
            _error "Database migration failed (exit code: $db_rc)"
            if [[ -n "$db_output" ]]; then
                _error "Error output:"
                echo "$db_output" | while IFS= read -r line; do
                    _error "  $line"
                done
            fi
            _log "STEP 4 FAILED: Database migration error (rc=$db_rc)"
            return 1
        fi

        # Check if there were any warnings in the output
        # Look for actual MySQL warnings/errors, not just the words in general text
        if echo "$db_output" | grep -Ei "^(warning|error|failed|cannot|denied)" | grep -qv "0 warnings"; then
            _warning "Database migration completed but with warnings:"
            echo "$db_output" | grep -Ei "^(warning|error|failed|cannot|denied)" | grep -v "0 warnings" | while IFS= read -r line; do
                _loading3 "  $line"
            done
        fi

        _success "Database migrated successfully"
        _loading3 "  Exported from: $source_db"
        _loading3 "  Imported to:   $dest_db"
    fi

    # Verify migration by checking for the marker in destination database
    _loading2 "Verifying migration marker in destination database..."
    local verify_sql="SELECT option_value FROM ${source_options_table} WHERE option_name='wp_miggp';"
    local verify_output verify_rc
    verify_output=$(ssh "${ssh_opts_array[@]}" "$ssh_user@$dest_server_ip" "mysql -N $safe_dest_db -e \"$verify_sql\"" 2>&1)
    verify_rc=$?

    if [[ $verify_rc -ne 0 ]]; then
        _warning "Could not verify migration marker (query failed)"
        [[ -n "$verify_output" ]] && _warning "Output: $verify_output"
        _log "Migration verification query failed: $verify_output"
    elif [[ "$verify_output" == "$migration_marker_id" ]]; then
        _success "Migration verified: marker found in destination database"
        _loading3 "  Marker: $migration_marker_id"
        _log "Migration verification SUCCESS: marker '$migration_marker_id' found"
    else
        _warning "Migration marker mismatch!"
        _warning "  Expected: $migration_marker_id"
        _warning "  Found:    $verify_output"
        _log "Migration verification WARNING: marker mismatch (expected=$migration_marker_id, found=$verify_output)"
    fi

    # Clean up marker from source database (optional, keep it for audit trail)
    # Uncomment the following to remove the marker:
    # ssh "${ssh_opts_array[@]}" "$ssh_user@$source_server_ip" "mysql $safe_source_db -e \"DELETE FROM wp_options WHERE option_name='wp_miggp';\"" 2>/dev/null || true

    _state_add_completed_step "4"
    _log "STEP 4 COMPLETE: Database migration successful"
    echo
    return 0
}

# -----------------------------------------------------------------------------
# Step 5.1 - Check for custom nginx config files
# Lists nginx configs in /var/www/{site}/nginx/, filters out standard ones,
# stores custom config list to state for later steps
# -----------------------------------------------------------------------------
function _step_5_1() {
    _loading "Step 5.1: Checking for custom nginx config files"
    _log "STEP 5.1: Checking for custom nginx config files"

    local source_server_ip source_site_path
    source_server_ip=$(_state_read ".data.source_server_ip")
    source_site_path=$(_state_read ".data.source_site_path")

    if [[ -z "$source_server_ip" || -z "$source_site_path" ]]; then
        _error "Missing source server IP or site path. Run Step 2.1 and 2.5 first."
        _log "STEP 5.1 FAILED: Missing prerequisite data"
        return 1
    fi

    local nginx_dir="${source_site_path}/nginx"
    _loading2 "Checking nginx directory: $nginx_dir"

    # List all files in nginx directory
    local list_cmd="ls -1 '$nginx_dir' 2>/dev/null || echo ''"
    local nginx_files nginx_rc
    nginx_files=$(_ssh_capture "$source_server_ip" "$list_cmd")
    nginx_rc=$?

    if [[ $nginx_rc -ne 0 || -z "$nginx_files" ]]; then
        _loading3 "No nginx directory or no files found at $nginx_dir"
        _log "STEP 5.1: No nginx configs found at $nginx_dir"
        _state_write ".data.nginx_custom_configs" ""
        _state_write ".data.nginx_special_configs" ""
        _state_add_completed_step "5.1"
        _success "Step 5.1 complete: No custom nginx configs found"
        echo
        return 0
    fi

    _verbose "Found nginx files: $(echo "$nginx_files" | tr '\n' ' ')"

    # Standard files to filter out (these are auto-generated by GridPane)
    # Pattern: {site}-headers-csp.conf, {site}-sockfile.conf
    local standard_pattern="${SITE}-headers-csp\.conf|${SITE}-sockfile\.conf"

    # Special configs that need gp commands
    local special_configs=()
    local custom_configs=()

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue

        # Check if it's a standard file to skip
        if echo "$file" | grep -qE "$standard_pattern"; then
            _verbose "Skipping standard config: $file"
            continue
        fi

        # Check if it's a special config needing gp command
        case "$file" in
            disable-xmlrpc-main-context.conf)
                special_configs+=("$file")
                _loading3 "  Found special config: $file → gp site $SITE -disable-xmlrpc"
                ;;
            disable-wp-trackbacks-main-context.conf)
                special_configs+=("$file")
                _loading3 "  Found special config: $file → gp site $SITE -block-wp-trackbacks.php"
                ;;
            disable-wp-links-opml-main-context.conf)
                special_configs+=("$file")
                _loading3 "  Found special config: $file → gp site $SITE -block-wp-links-opml.php"
                ;;
            disable-wp-comments-post-main-context.conf)
                special_configs+=("$file")
                _loading3 "  Found special config: $file → gp site $SITE -block-wp-comments-post.php"
                ;;
            *)
                custom_configs+=("$file")
                _loading3 "  Found custom config: $file"
                ;;
        esac
    done <<< "$nginx_files"

    # Store to state as comma-separated lists
    local special_list custom_list
    special_list=$(IFS=','; echo "${special_configs[*]}")
    custom_list=$(IFS=','; echo "${custom_configs[*]}")

    _state_write ".data.nginx_special_configs" "$special_list"
    _state_write ".data.nginx_custom_configs" "$custom_list"

    _log "STEP 5.1: Special configs: $special_list"
    _log "STEP 5.1: Custom configs: $custom_list"

    local total_count=$((${#special_configs[@]} + ${#custom_configs[@]}))
    if [[ $total_count -eq 0 ]]; then
        _loading3 "No custom nginx configs found (only standard files)"
    else
        _loading3 "Found ${#special_configs[@]} special config(s) and ${#custom_configs[@]} custom config(s)"
    fi

    _state_add_completed_step "5.1"
    _success "Step 5.1 complete: Nginx config check done"
    _log "STEP 5.1 COMPLETE"
    echo
    return 0
}

# -----------------------------------------------------------------------------
# Step 5.2 - Run gp commands for special nginx configs
# Maps special config files to gp CLI commands and executes on destination
# Non-fatal errors are logged and migration continues
# -----------------------------------------------------------------------------
function _step_5_2() {
    _loading "Step 5.2: Running gp commands for special nginx configs"
    _log "STEP 5.2: Running gp commands for special nginx configs"

    local dest_server_ip special_configs
    dest_server_ip=$(_state_read ".data.dest_server_ip")
    special_configs=$(_state_read ".data.nginx_special_configs")

    if [[ -z "$dest_server_ip" ]]; then
        _error "Missing destination server IP. Run Step 2.1 first."
        _log "STEP 5.2 FAILED: Missing dest_server_ip"
        return 1
    fi

    if [[ -z "$special_configs" ]]; then
        _loading3 "No special configs to process"
        _log "STEP 5.2: No special configs to process"
        _state_add_completed_step "5.2"
        _success "Step 5.2 complete: No special configs to process"
        echo
        return 0
    fi

    # Get destination site path for checking existing configs
    local dest_site_path
    dest_site_path=$(_state_read ".data.dest_site_path")
    local dest_nginx_dir="${dest_site_path}/nginx"

    # Convert comma-separated list to array
    IFS=',' read -ra config_array <<< "$special_configs"

    local success_count=0
    local skip_count=0
    local error_count=0

    for config in "${config_array[@]}"; do
        [[ -z "$config" ]] && continue

        local gp_cmd=""
        case "$config" in
            disable-xmlrpc-main-context.conf)
                gp_cmd="gp site $SITE -disable-xmlrpc"
                ;;
            disable-wp-trackbacks-main-context.conf)
                gp_cmd="gp site $SITE -block-wp-trackbacks.php"
                ;;
            disable-wp-links-opml-main-context.conf)
                gp_cmd="gp site $SITE -block-wp-links-opml.php"
                ;;
            disable-wp-comments-post-main-context.conf)
                gp_cmd="gp site $SITE -block-wp-comments-post.php"
                ;;
            *)
                _verbose "Unknown special config: $config (skipping)"
                continue
                ;;
        esac

        # Check if config file already exists on destination
        local check_cmd="test -f '${dest_nginx_dir}/${config}' && echo 'exists' || echo 'missing'"
        local exists_check
        exists_check=$(_ssh_capture "$dest_server_ip" "$check_cmd" 2>/dev/null)

        if [[ "$exists_check" == "exists" ]]; then
            _loading3 "  Skipping: $config (already exists on destination)"
            _log "STEP 5.2: Skipping $config - already exists on destination"
            ((skip_count++))
            continue
        fi

        _loading2 "Executing: $gp_cmd"

        if [[ "$DRY_RUN" == "1" ]]; then
            _dry_run_msg "Would execute on destination: $gp_cmd"
            ((success_count++))
            continue
        fi

        local cmd_output cmd_rc
        cmd_output=$(_ssh_capture "$dest_server_ip" "$gp_cmd" 2>&1)
        cmd_rc=$?

        if [[ $cmd_rc -ne 0 ]]; then
            _error_log "Step 5.2: Failed to execute '$gp_cmd' on destination (exit code: $cmd_rc)"
            [[ -n "$cmd_output" ]] && _error_log "  Output: $cmd_output"
            ((error_count++))
        else
            _success "  Command succeeded: $gp_cmd"
            _log "STEP 5.2: Successfully executed: $gp_cmd"
            [[ -n "$cmd_output" ]] && _verbose "  Output: $cmd_output"
            ((success_count++))
        fi
    done

    # Always disable XML-RPC on destination (security measure) unless already set
    local xmlrpc_config="disable-xmlrpc-main-context.conf"
    local check_dest_cmd="test -f '${dest_nginx_dir}/${xmlrpc_config}' && echo 'exists' || echo 'missing'"
    local dest_xmlrpc_check
    dest_xmlrpc_check=$(_ssh_capture "$dest_server_ip" "$check_dest_cmd" 2>/dev/null)

    if [[ "$dest_xmlrpc_check" == "exists" ]]; then
        _loading3 "  Skipping: XML-RPC already disabled on destination"
        _log "STEP 5.2: XML-RPC already disabled on destination"
        ((skip_count++))
    elif [[ "$DRY_RUN" == "1" ]]; then
        _dry_run_msg "Would execute on destination: gp site $SITE -disable-xmlrpc"
        ((success_count++))
    else
        _loading2 "Disabling XML-RPC on destination"
        local gp_cmd="gp site $SITE -disable-xmlrpc"
        local cmd_output cmd_rc
        cmd_output=$(_ssh_capture "$dest_server_ip" "$gp_cmd" 2>&1)
        cmd_rc=$?

        if [[ $cmd_rc -ne 0 ]]; then
            _error_log "Step 5.2: Failed to disable XML-RPC on destination (exit code: $cmd_rc)"
            [[ -n "$cmd_output" ]] && _error_log "  Output: $cmd_output"
            ((error_count++))
        else
            _success "  Command succeeded: $gp_cmd"
            _log "STEP 5.2: Successfully disabled XML-RPC on destination"
            [[ -n "$cmd_output" ]] && _verbose "  Output: $cmd_output"
            ((success_count++))
        fi
    fi

    local summary_parts=()
    [[ $success_count -gt 0 ]] && summary_parts+=("$success_count executed")
    [[ $skip_count -gt 0 ]] && summary_parts+=("$skip_count skipped")
    [[ $error_count -gt 0 ]] && summary_parts+=("$error_count failed")
    local summary_msg
    summary_msg=$(IFS=', '; echo "${summary_parts[*]}")

    if [[ $error_count -gt 0 ]]; then
        _warning "Step 5.2 completed with errors ($summary_msg) - see error log"
        _log "STEP 5.2 COMPLETE: $summary_msg"
    else
        _success "Step 5.2 complete: $summary_msg"
        _log "STEP 5.2 COMPLETE: $summary_msg"
    fi

    _state_add_completed_step "5.2"
    echo
    return 0
}

# -----------------------------------------------------------------------------
# Step 5.3 - Backup and copy nginx files to destination
# Creates tar archive of source nginx directory and places it on destination
# as a backup file (outside the nginx dir) for reference
# -----------------------------------------------------------------------------
function _step_5_3() {
    _loading "Step 5.3: Backup and copy nginx files"
    _log "STEP 5.3: Backup and copy nginx files"

    local source_server_ip dest_server_ip source_site_path dest_site_path
    source_server_ip=$(_state_read ".data.source_server_ip")
    dest_server_ip=$(_state_read ".data.dest_server_ip")
    source_site_path=$(_state_read ".data.source_site_path")
    dest_site_path=$(_state_read ".data.dest_site_path")

    if [[ -z "$source_server_ip" || -z "$dest_server_ip" || -z "$source_site_path" || -z "$dest_site_path" ]]; then
        _error "Missing required state data. Run Steps 2.1 and 2.5 first."
        _log "STEP 5.3 FAILED: Missing prerequisite data"
        return 1
    fi

    local source_nginx_dir="${source_site_path}/nginx"
    local tar_filename="nginx-${SITE}-src-backup.tar.gz"
    local source_tar_path="/tmp/${tar_filename}"
    # Place backup in site root directory (outside nginx dir)
    local dest_backup_path="${dest_site_path}/${tar_filename}"

    # Check if source nginx directory exists and has files
    local check_cmd="test -d '$source_nginx_dir' && ls -1 '$source_nginx_dir' 2>/dev/null | wc -l || echo '0'"
    local file_count
    file_count=$(_ssh_capture "$source_server_ip" "$check_cmd")
    file_count=$(echo "$file_count" | tr -d '[:space:]')

    if [[ "$file_count" == "0" ]]; then
        _loading3 "No nginx files to backup (directory empty or missing)"
        _log "STEP 5.3: No nginx files to backup"
        _state_add_completed_step "5.3"
        _success "Step 5.3 complete: No files to backup"
        echo
        return 0
    fi

    _loading2 "Found $file_count file(s) in source nginx directory"

    if [[ "$DRY_RUN" == "1" ]]; then
        _dry_run_msg "Would create tar archive: $tar_filename"
        _dry_run_msg "Would transfer to destination: $dest_backup_path"
        _state_add_completed_step "5.3"
        _success "Step 5.3 complete (dry-run)"
        echo
        return 0
    fi

    # Step 1: Create tar archive on source
    _loading2 "Creating tar archive on source..."
    local tar_cmd="cd '$source_site_path' && tar -czf '$source_tar_path' nginx/"
    local tar_output tar_rc
    tar_output=$(_ssh_capture "$source_server_ip" "$tar_cmd" 2>&1)
    tar_rc=$?

    if [[ $tar_rc -ne 0 ]]; then
        _error "Failed to create tar archive on source (exit code: $tar_rc)"
        [[ -n "$tar_output" ]] && _error "Output: $tar_output"
        _log "STEP 5.3 FAILED: tar creation failed"
        return 1
    fi
    _verbose "Tar archive created: $source_tar_path"

    # Step 2: Transfer archive from source to destination (as backup file in site root)
    _loading2 "Transferring archive to destination as backup..."

    local ssh_user
    ssh_user=$(_state_read ".data.ssh_user")
    [[ -z "$ssh_user" ]] && ssh_user="${GPBC_SSH_USER:-root}"

    local known_hosts_file="${STATE_DIR}/gp-site-mig-${SITE}-known_hosts"
    local ssh_opts=(-o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$known_hosts_file")

    # Use SSH pipe to transfer (source -> local -> dest) directly to final location
    local transfer_output transfer_rc
    transfer_output=$(ssh "${ssh_opts[@]}" "$ssh_user@$source_server_ip" "cat '$source_tar_path'" 2>&1 | ssh "${ssh_opts[@]}" "$ssh_user@$dest_server_ip" "cat > '$dest_backup_path'" 2>&1)
    transfer_rc=$?

    if [[ $transfer_rc -ne 0 ]]; then
        _error "Failed to transfer tar archive (exit code: $transfer_rc)"
        [[ -n "$transfer_output" ]] && _error "Output: $transfer_output"
        # Cleanup source tar
        _ssh_capture "$source_server_ip" "rm -f '$source_tar_path'" 2>/dev/null || true
        _log "STEP 5.3 FAILED: transfer failed"
        return 1
    fi
    _verbose "Archive transferred to destination: $dest_backup_path"

    # Step 3: Set ownership to destination system user
    local dest_system_user_name
    dest_system_user_name=$(_state_read ".data.dest_system_user_name")
    if [[ -n "$dest_system_user_name" && "$dest_system_user_name" != "UNKNOWN" && "$dest_system_user_name" != "null" ]]; then
        _loading2 "Setting ownership to $dest_system_user_name..."
        _ssh_capture "$dest_server_ip" "chown '$dest_system_user_name:$dest_system_user_name' '$dest_backup_path'" 2>/dev/null || true
        _verbose "Ownership set to $dest_system_user_name"
    else
        _verbose "Skipping chown (dest_system_user_name not set - re-run Step 1 with cache-users)"
    fi

    # Step 4: Cleanup source tar file (keep backup on destination)
    _loading2 "Cleaning up temporary files on source..."
    _ssh_capture "$source_server_ip" "rm -f '$source_tar_path'" 2>/dev/null || true
    _verbose "Source tar file cleaned up"

    _state_add_completed_step "5.3"
    _success "Step 5.3 complete: Nginx backup saved to $dest_backup_path"
    _log "STEP 5.3 COMPLETE: $file_count file(s) backed up to $dest_backup_path"
    echo
    return 0
}

# -----------------------------------------------------------------------------
# Step 5 - Migrate Nginx Config (wrapper)
# Calls sub-steps 5.1, 5.2, 5.3
# -----------------------------------------------------------------------------
function _step_5() {
    _loading "Step 5: Migrate Nginx Config"
    _log "STEP 5: Starting nginx config migration"

    _run_step "5.1" _step_5_1 || return 1
    _run_step "5.2" _step_5_2 || return 1
    _run_step "5.3" _step_5_3 || return 1

    _state_add_completed_step "5"
    _log "STEP 5 COMPLETE: Nginx config migration done"
    return 0
}

# -----------------------------------------------------------------------------
# Step 6 - Copy user-configs.php
# Checks for user-configs.php on source, backs up existing on destination,
# then copies from source to destination
# -----------------------------------------------------------------------------
function _step_6() {
    _loading "Step 6: Copy user-configs.php"
    _log "STEP 6: Starting user-configs.php migration"

    local source_server_ip dest_server_ip source_site_path dest_site_path
    source_server_ip=$(_state_read ".data.source_server_ip")
    dest_server_ip=$(_state_read ".data.dest_server_ip")
    source_site_path=$(_state_read ".data.source_site_path")
    dest_site_path=$(_state_read ".data.dest_site_path")

    if [[ -z "$source_server_ip" || -z "$dest_server_ip" || -z "$source_site_path" || -z "$dest_site_path" ]]; then
        _error "Missing required state data. Run Steps 2.1 and 2.5 first."
        _log "STEP 6 FAILED: Missing prerequisite data"
        return 1
    fi

    local source_user_config="${source_site_path}/user-configs.php"
    local dest_user_config="${dest_site_path}/user-configs.php"

    # Check if user-configs.php exists on source
    _loading2 "Checking for user-configs.php on source..."
    local check_cmd="test -f '$source_user_config' && echo 'exists' || echo 'missing'"
    local source_check
    source_check=$(_ssh_capture "$source_server_ip" "$check_cmd")
    source_check=$(echo "$source_check" | tr -d '[:space:]')

    if [[ "$source_check" != "exists" ]]; then
        _loading3 "No user-configs.php found on source server"
        _log "STEP 6: No user-configs.php on source, skipping"
        _state_add_completed_step "6"
        _success "Step 6 complete: No user-configs.php to copy"
        echo
        return 0
    fi

    _loading2 "Found user-configs.php on source"

    if [[ "$DRY_RUN" == "1" ]]; then
        _dry_run_msg "Would backup destination user-configs.php (if exists)"
        _dry_run_msg "Would copy user-configs.php from source to destination"
        _state_add_completed_step "6"
        _success "Step 6 complete (dry-run)"
        echo
        return 0
    fi

    local ssh_user
    ssh_user=$(_state_read ".data.ssh_user")
    [[ -z "$ssh_user" ]] && ssh_user="${GPBC_SSH_USER:-root}"

    local known_hosts_file="${STATE_DIR}/gp-site-mig-${SITE}-known_hosts"
    local ssh_opts=(-o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$known_hosts_file")

    # Check if user-configs.php exists on destination (for backup)
    _loading2 "Checking for existing user-configs.php on destination..."
    local dest_check
    dest_check=$(_ssh_capture "$dest_server_ip" "test -f '$dest_user_config' && echo 'exists' || echo 'missing'")
    dest_check=$(echo "$dest_check" | tr -d '[:space:]')

    if [[ "$dest_check" == "exists" ]]; then
        # Show diff between source and destination
        _loading2 "Comparing source and destination user-configs.php..."
        local source_content dest_content
        source_content=$(ssh "${ssh_opts[@]}" "$ssh_user@$source_server_ip" "cat '$source_user_config'" 2>/dev/null)
        dest_content=$(ssh "${ssh_opts[@]}" "$ssh_user@$dest_server_ip" "cat '$dest_user_config'" 2>/dev/null)

        if [[ "$source_content" == "$dest_content" ]]; then
            _loading3 "Files are identical, no changes needed"
            _log "STEP 6: user-configs.php files are identical, skipping"
            _state_add_completed_step "6"
            _success "Step 6 complete: user-configs.php already in sync"
            echo
            return 0
        fi

        echo
        echo "--- Differences between source and destination user-configs.php ---"
        diff --color=auto <(echo "$dest_content") <(echo "$source_content") || true
        echo "--- End of diff (destination <- source) ---"
        echo

        # Backup existing file
        local backup_file="${dest_site_path}/user-config-src-backup.php"

        _loading2 "Backing up existing user-configs.php to: user-config-src-backup.php"
        local backup_cmd="cp '$dest_user_config' '$backup_file'"
        local backup_output backup_rc
        backup_output=$(_ssh_capture "$dest_server_ip" "$backup_cmd" 2>&1)
        backup_rc=$?

        if [[ $backup_rc -ne 0 ]]; then
            _error "Failed to backup existing user-configs.php (exit code: $backup_rc)"
            [[ -n "$backup_output" ]] && _error "Output: $backup_output"
            _log "STEP 6 WARNING: backup failed, continuing with copy"
            _error_log "Step 6: Failed to backup user-configs.php - $backup_output"
        else
            _verbose "Backup created: $backup_file"
            # Set ownership to destination system user
            local dest_system_user_name
            dest_system_user_name=$(_state_read ".data.dest_system_user_name")
            if [[ -n "$dest_system_user_name" && "$dest_system_user_name" != "UNKNOWN" && "$dest_system_user_name" != "null" ]]; then
                _loading2 "Setting backup ownership to $dest_system_user_name..."
                _ssh_capture "$dest_server_ip" "chown '$dest_system_user_name:$dest_system_user_name' '$backup_file'" 2>/dev/null || true
                _verbose "Backup ownership set to $dest_system_user_name"
            else
                _verbose "Skipping chown (dest_system_user_name not set)"
            fi
        fi
    else
        _verbose "No existing user-configs.php on destination, skipping backup"
    fi

    # Copy user-configs.php from source to destination
    _loading2 "Copying user-configs.php from source to destination..."
    local transfer_output transfer_rc
    transfer_output=$(ssh "${ssh_opts[@]}" "$ssh_user@$source_server_ip" "cat '$source_user_config'" 2>&1 | \
        ssh "${ssh_opts[@]}" "$ssh_user@$dest_server_ip" "cat > '$dest_user_config'" 2>&1)
    transfer_rc=$?

    if [[ $transfer_rc -ne 0 ]]; then
        _error "Failed to copy user-configs.php (exit code: $transfer_rc)"
        [[ -n "$transfer_output" ]] && _error "Output: $transfer_output"
        _log "STEP 6 FAILED: copy failed"
        return 1
    fi

    _state_add_completed_step "6"
    _success "Step 6 complete: user-configs.php copied successfully"
    _log "STEP 6 COMPLETE: user-configs.php migrated"
    echo
    return 0
}

# -----------------------------------------------------------------------------
# Step 7 - Sync Domain Route
# Compares source and destination domain routes, updates destination if different
# Route values: none, www, root
# -----------------------------------------------------------------------------
function _step_7() {
    _loading "Step 7: Sync Domain Route"
    _log "STEP 7: Starting domain route sync"

    # Read route data from state (captured in Step 1.2)
    local source_route dest_route source_domain_id dest_domain_id
    source_route=$(_state_read ".data.source_route")
    dest_route=$(_state_read ".data.dest_route")
    source_domain_id=$(_state_read ".data.source_domain_id")
    dest_domain_id=$(_state_read ".data.dest_domain_id")

    # Check if route data exists in state
    if [[ -z "$source_route" || "$source_route" == "null" ]]; then
        _warning "Source route not found in state. Run Step 1.2 first or route data not captured."
        _log "STEP 7 WARNING: source_route not in state"
        _state_add_completed_step "7"
        _success "Step 7 complete: Skipped (no route data)"
        echo
        return 0
    fi

    if [[ -z "$dest_route" || "$dest_route" == "null" ]]; then
        _warning "Destination route not found in state. Run Step 1.2 first or route data not captured."
        _log "STEP 7 WARNING: dest_route not in state"
        _state_add_completed_step "7"
        _success "Step 7 complete: Skipped (no route data)"
        echo
        return 0
    fi

    if [[ -z "$dest_domain_id" || "$dest_domain_id" == "null" ]]; then
        _warning "Destination domain ID not found in state. Run Step 1.2 first."
        _log "STEP 7 WARNING: dest_domain_id not in state"
        _state_add_completed_step "7"
        _success "Step 7 complete: Skipped (no domain ID)"
        echo
        return 0
    fi

    _loading2 "Source route: $source_route"
    _loading2 "Destination route: $dest_route"

    # Compare routes
    if [[ "$source_route" == "$dest_route" ]]; then
        _loading3 "Routes already match ($source_route)"
        _log "STEP 7: Routes already match ($source_route), skipping update"
        _state_write ".data.route_updated" "false"
        _state_add_completed_step "7"
        _success "Step 7 complete: Routes already in sync"
        echo
        return 0
    fi

    _loading2 "Routes differ, updating destination route from '$dest_route' to '$source_route'"

    if [[ "$DRY_RUN" == "1" ]]; then
        _dry_run_msg "Would update destination domain route via PUT /domain/$dest_domain_id with {\"routing\": \"$source_route\"}"
        _state_add_completed_step "7"
        _success "Step 7 complete (dry-run)"
        echo
        return 0
    fi

    # Switch to destination profile for API call
    local saved_token="$GPBC_TOKEN"
    local saved_token_name="$GPBC_TOKEN_NAME"
    
    if ! _gp_set_profile_silent "$DEST_PROFILE"; then
        _error "Failed to switch to destination profile: $DEST_PROFILE"
        _log "STEP 7 FAILED: Could not switch to destination profile"
        GPBC_TOKEN="$saved_token"
        GPBC_TOKEN_NAME="$saved_token_name"
        return 1
    fi

    # Make PUT request to update domain route
    local endpoint="/domain/${dest_domain_id}"
    local payload="{\"routing\": \"$source_route\"}"
    
    _loading2 "Sending PUT request to update domain route..."
    _debug "Endpoint: $endpoint"
    _debug "Payload: $payload"

    local curl_output curl_http_code curl_exit_code api_output
    curl_output=$(mktemp)
    curl_http_code="$(curl -s \
        --output "$curl_output" \
        -w "%{http_code}\n" \
        --request PUT \
        --url "${GP_API_URL}${endpoint}" \
        -H "Authorization: Bearer $GPBC_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload")"
    curl_exit_code="$?"
    curl_http_code=${curl_http_code%%$'\n'*}
    api_output=$(<"$curl_output")
    rm -f "$curl_output"

    _debug "HTTP Code: $curl_http_code, Exit Code: $curl_exit_code"
    _debug "API Output: $api_output"

    # Restore original profile
    GPBC_TOKEN="$saved_token"
    GPBC_TOKEN_NAME="$saved_token_name"

    # Check for success (HTTP 200 for update)
    if [[ $curl_http_code -eq 200 ]]; then
        _verbose "API Response: $api_output"
        _state_write ".data.route_updated" "true"
        _state_add_completed_step "7"
        _success "Step 7 complete: Domain route updated from '$dest_route' to '$source_route'"
        _log "STEP 7 COMPLETE: Domain route updated from '$dest_route' to '$source_route'"
        echo
        return 0
    else
        _error "Failed to update domain route. HTTP Code: $curl_http_code"
        if [[ -n "$api_output" ]]; then
            local error_msg
            error_msg=$(echo "$api_output" | jq -r '.message // .error // empty' 2>/dev/null)
            [[ -n "$error_msg" ]] && _error "API Error: $error_msg"
            _verbose "Full response: $api_output"
        fi
        _log "STEP 7 FAILED: API returned HTTP $curl_http_code - $api_output"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Step 8 - Cloudflare DNS Integration
# Enables DNS integration on destination domain if configured
# Uses dest_dns_integration_id from state (captured in Step 1.3)
# -----------------------------------------------------------------------------
function _step_8() {
    _loading "Step 8: Enable DNS Integration on Destination"
    _log "STEP 8: Starting DNS integration setup"

    # Check if DNS integration skip flag is set (for resumed migrations)
    if [[ "$DNS_INTEGRATION_SKIP" == "1" ]]; then
        _loading2 "DNS integration skipped via --dns-integration-skip flag"
        _log "STEP 8: DNS integration skipped by user flag (resume)"
        _state_write ".data.dns_integration_enabled" "skipped"
        _state_add_completed_step "8"
        _success "Step 8 complete: DNS integration skipped"
        echo
        return 0
    fi

    # Read DNS integration data from state
    local dest_dns_integration_id dest_domain_id source_dns_provider
    dest_dns_integration_id=$(_state_read ".data.dest_dns_integration_id")
    dest_domain_id=$(_state_read ".data.dest_domain_id")
    source_dns_provider=$(_state_read ".data.source_dns_provider")

    # Check if DNS integration was skipped (state value from Step 1.3)
    if [[ "$dest_dns_integration_id" == "skipped" ]]; then
        _loading2 "DNS integration was skipped via --dns-integration-skip flag"
        _log "STEP 8: DNS integration skipped by user flag"
        _state_write ".data.dns_integration_enabled" "skipped"
        _state_add_completed_step "8"
        _success "Step 8 complete: DNS integration skipped"
        echo
        return 0
    fi

    # Check if DNS integration exists
    if [[ -z "$dest_dns_integration_id" || "$dest_dns_integration_id" == "null" || "$dest_dns_integration_id" == "none" ]]; then
        _loading2 "No DNS integration configured for destination"
        _log "STEP 8: No DNS integration configured, skipping"
        _state_write ".data.dns_integration_enabled" "false"
        _state_add_completed_step "8"
        _success "Step 8 complete: No DNS integration to enable"
        echo
        return 0
    fi

    if [[ -z "$dest_domain_id" || "$dest_domain_id" == "null" ]]; then
        _error "Destination domain ID not found in state. Run Step 1.2 first."
        _log "STEP 8 FAILED: dest_domain_id not in state"
        return 1
    fi

    # Determine dns_management type based on source provider (default to cloudflare_full)
    local dns_management_type="cloudflare_full"
    if [[ "$source_dns_provider" == "dnsme" ]]; then
        dns_management_type="dnsme_full"
    elif [[ "$source_dns_provider" == "cloudflare" ]]; then
        dns_management_type="cloudflare_full"
    fi

    _loading2 "Enabling DNS integration on destination domain_id=$dest_domain_id"
    _loading3 "DNS Management Type: $dns_management_type"
    _loading3 "DNS Integration ID: $dest_dns_integration_id"

    if [[ "$DRY_RUN" == "1" ]]; then
        _dry_run_msg "Would enable DNS integration via PUT /domain/$dest_domain_id with {\"dns_management\": \"$dns_management_type\", \"dns_integration_id\": $dest_dns_integration_id}"
        _state_add_completed_step "8"
        _success "Step 8 complete (dry-run)"
        echo
        return 0
    fi

    # Switch to destination profile for API call
    local saved_token="$GPBC_TOKEN"
    local saved_token_name="$GPBC_TOKEN_NAME"
    
    if ! _gp_set_profile_silent "$DEST_PROFILE"; then
        _error "Failed to switch to destination profile: $DEST_PROFILE"
        _log "STEP 8 FAILED: Could not switch to destination profile"
        GPBC_TOKEN="$saved_token"
        GPBC_TOKEN_NAME="$saved_token_name"
        return 1
    fi

    # Make PUT request to enable DNS integration with rate limit retry
    local endpoint="/domain/${dest_domain_id}"
    local payload="{\"dns_management\": \"$dns_management_type\", \"dns_integration_id\": $dest_dns_integration_id}"
    
    _loading2 "Sending PUT request to enable DNS integration..."
    _debug "Endpoint: $endpoint"
    _debug "Payload: $payload"

    local curl_output curl_http_code curl_exit_code api_output
    local retry_count=0
    local max_retries=3
    local rate_limit_delay=15
    
    while [[ $retry_count -lt $max_retries ]]; do
        curl_output=$(mktemp)
        curl_http_code="$(curl -s \
            --output "$curl_output" \
            -w "%{http_code}\n" \
            --request PUT \
            --url "${GP_API_URL}${endpoint}" \
            -H "Authorization: Bearer $GPBC_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$payload")"
        curl_exit_code="$?"
        curl_http_code=${curl_http_code%%$'\n'*}
        api_output=$(<"$curl_output")
        rm -f "$curl_output"

        _debug "HTTP Code: $curl_http_code, Exit Code: $curl_exit_code"
        _debug "API Output: $api_output"
        
        # Handle rate limiting (429)
        if [[ $curl_http_code -eq 429 ]]; then
            ((retry_count++))
            if [[ $retry_count -lt $max_retries ]]; then
                local current_delay=$((rate_limit_delay * retry_count))
                _warning "Rate limited (429). Retry ${retry_count}/${max_retries} after ${current_delay}s..."
                _log "STEP 8: Rate limited (429) - Retry ${retry_count}/${max_retries}"
                sleep "$current_delay"
                continue
            else
                _error "Rate limited (429) after ${max_retries} retries."
                _log "STEP 8 FAILED: Rate limited (429) after ${max_retries} retries"
                GPBC_TOKEN="$saved_token"
                GPBC_TOKEN_NAME="$saved_token_name"
                return 1
            fi
        fi
        
        # Break out of retry loop on non-429 response
        break
    done

    # Restore original profile
    GPBC_TOKEN="$saved_token"
    GPBC_TOKEN_NAME="$saved_token_name"

    # Check for success (HTTP 200 for update)
    if [[ $curl_http_code -eq 200 ]]; then
        _verbose "API Response: $api_output"
        _state_write ".data.dns_integration_enabled" "true"
        _state_add_completed_step "8"
        _success "Step 8 complete: DNS integration enabled ($dns_management_type)"
        _log "STEP 8 COMPLETE: DNS integration enabled, type=$dns_management_type, integration_id=$dest_dns_integration_id"
        
        # Pause to allow DNS integration to propagate before SSL
        if [[ "$DRY_RUN" != "1" ]]; then
            _loading2 "Waiting 30 seconds for DNS integration to propagate..."
            sleep 30
        fi
        echo
        return 0
    else
        _error "Failed to enable DNS integration. HTTP Code: $curl_http_code"
        if [[ -n "$api_output" ]]; then
            local error_msg error_details
            error_msg=$(echo "$api_output" | jq -r '.message // .error // empty' 2>/dev/null)
            # Extract detailed errors from the errors object (flatten all error arrays)
            error_details=$(echo "$api_output" | jq -r '.errors // {} | to_entries | map(.value | if type == "array" then .[] else . end) | .[]' 2>/dev/null)
            [[ -n "$error_msg" ]] && _error "API Error: $error_msg"
            if [[ -n "$error_details" ]]; then
                while IFS= read -r detail; do
                    _error "  → $detail"
                done <<< "$error_details"
            fi
            _verbose "Full response: $api_output"
        fi
        _log "STEP 8 FAILED: API returned HTTP $curl_http_code - $api_output"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Step 9 - Enable SSL on Destination
# Enables SSL on destination domain via PUT /domain/{id} if source has SSL
# -----------------------------------------------------------------------------
function _step_9() {
    _loading "Step 9: Enable SSL on destination"
    _log "STEP 9: Starting SSL enable"

    # Read SSL and domain data from state
    local source_is_ssl dest_domain_id
    source_is_ssl=$(_state_read ".data.source_is_ssl")
    dest_domain_id=$(_state_read ".data.dest_domain_id")

    # Check if source has SSL
    if [[ "$source_is_ssl" != "true" ]]; then
        _loading2 "Source does not have SSL enabled, skipping"
        _log "STEP 9: Source SSL not enabled, skipping"
        _state_write ".data.ssl_enabled" "false"
        _state_add_completed_step "9"
        _success "Step 9 complete: SSL not required (source has no SSL)"
        echo
        return 0
    fi

    # Check if DNS integration was skipped - prompt user to change DNS manually
    local dns_integration_enabled
    dns_integration_enabled=$(_state_read ".data.dns_integration_enabled")
    if [[ "$dns_integration_enabled" == "skipped" ]]; then
        local dest_server_ip dest_domain_url
        dest_server_ip=$(_state_read ".data.dest_server_ip")
        dest_domain_url=$(_state_read ".data.dest_domain_url")
        
        echo
        _warning "DNS integration was skipped. Manual DNS update required before SSL provisioning."
        echo
        _loading2 "Please update DNS for: $dest_domain_url"
        _loading2 "Point A record to: $dest_server_ip"
        echo
        _loading3 "SSL provisioning requires DNS to be pointing to the destination server."
        _loading3 "Please update your DNS records now, then wait for propagation."
        echo
        read -p "Have you updated DNS and confirmed propagation? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            _error "DNS update required before SSL can be enabled. Please update DNS and re-run."
            _log "STEP 9: Aborted - user declined DNS confirmation"
            return 1
        fi
        _log "STEP 9: User confirmed DNS has been updated manually"
    fi

    if [[ -z "$dest_domain_id" || "$dest_domain_id" == "null" ]]; then
        _error "Destination domain ID not found in state. Run Step 1.2 first."
        _log "STEP 9 FAILED: dest_domain_id not in state"
        return 1
    fi

    _loading2 "Source has SSL enabled, enabling SSL on destination domain_id=$dest_domain_id"

    if [[ "$DRY_RUN" == "1" ]]; then
        _dry_run_msg "Would enable SSL on destination via PUT /domain/$dest_domain_id with {\"ssl\": true}"
        _state_add_completed_step "9"
        _success "Step 9 complete (dry-run)"
        echo
        return 0
    fi

    # Switch to destination profile for API call
    local saved_token="$GPBC_TOKEN"
    local saved_token_name="$GPBC_TOKEN_NAME"
    
    if ! _gp_set_profile_silent "$DEST_PROFILE"; then
        _error "Failed to switch to destination profile: $DEST_PROFILE"
        _log "STEP 9 FAILED: Could not switch to destination profile"
        GPBC_TOKEN="$saved_token"
        GPBC_TOKEN_NAME="$saved_token_name"
        return 1
    fi

    # Make PUT request to enable SSL with rate limit retry
    local endpoint="/domain/${dest_domain_id}"
    local payload='{"ssl": true}'
    
    _loading2 "Sending PUT request to enable SSL..."
    _debug "Endpoint: $endpoint"
    _debug "Payload: $payload"

    local curl_output curl_http_code curl_exit_code api_output
    local retry_count=0
    local max_retries=3
    local rate_limit_delay=15
    
    while [[ $retry_count -lt $max_retries ]]; do
        curl_output=$(mktemp)
        curl_http_code="$(curl -s \
            --output "$curl_output" \
            -w "%{http_code}\n" \
            --request PUT \
            --url "${GP_API_URL}${endpoint}" \
            -H "Authorization: Bearer $GPBC_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$payload")"
        curl_exit_code="$?"
        curl_http_code=${curl_http_code%%$'\n'*}
        api_output=$(<"$curl_output")
        rm -f "$curl_output"

        _debug "HTTP Code: $curl_http_code, Exit Code: $curl_exit_code"
        _debug "API Output: $api_output"
        
        # Handle rate limiting (429)
        if [[ $curl_http_code -eq 429 ]]; then
            ((retry_count++))
            if [[ $retry_count -lt $max_retries ]]; then
                local current_delay=$((rate_limit_delay * retry_count))
                _warning "Rate limited (429). Retry ${retry_count}/${max_retries} after ${current_delay}s..."
                _log "STEP 9: Rate limited (429) - Retry ${retry_count}/${max_retries}"
                sleep "$current_delay"
                continue
            else
                _error "Rate limited (429) after ${max_retries} retries."
                _log "STEP 9 FAILED: Rate limited (429) after ${max_retries} retries"
                GPBC_TOKEN="$saved_token"
                GPBC_TOKEN_NAME="$saved_token_name"
                return 1
            fi
        fi
        
        # Break out of retry loop on non-429 response
        break
    done

    # Restore original profile
    GPBC_TOKEN="$saved_token"
    GPBC_TOKEN_NAME="$saved_token_name"

    # Check for success (HTTP 200 for update)
    if [[ $curl_http_code -eq 200 ]]; then
        _verbose "API Response: $api_output"
        _state_write ".data.ssl_enabled" "true"
        _state_add_completed_step "9"
        _success "Step 9 complete: SSL enable request sent"
        _loading3 "Note: SSL provisioning may take a few minutes to complete"
        _log "STEP 9 COMPLETE: SSL enabled on destination domain_id=$dest_domain_id"
        echo
        return 0
    else
        _error "Failed to enable SSL. HTTP Code: $curl_http_code"
        if [[ -n "$api_output" ]]; then
            local error_msg
            error_msg=$(echo "$api_output" | jq -r '.message // .error // empty' 2>/dev/null)
            [[ -n "$error_msg" ]] && _error "API Error: $error_msg"
            _verbose "Full response: $api_output"
        fi
        _log "STEP 9 FAILED: API returned HTTP $curl_http_code - $api_output"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Step 10 - Final Steps
# Creates cyber.html for DNS verification, runs gp fix cached and wp cache flush on destination
# -----------------------------------------------------------------------------
function _step_10() {
    _loading "Step 10: Final steps"
    _log "STEP 10: Starting final steps"

    # Get variables from state
    local dest_server_ip dest_site_path dest_htdocs_path site_url
    dest_server_ip=$(_state_read ".data.dest_server_ip")
    dest_site_path=$(_state_read ".data.dest_site_path")
    dest_htdocs_path=$(_state_read ".data.dest_htdocs_path")
    site_url=$(_state_read ".site")

    # Use htdocs path if available, otherwise construct it
    if [[ -z "$dest_htdocs_path" || "$dest_htdocs_path" == "null" ]]; then
        dest_htdocs_path="${dest_site_path}/htdocs"
    fi

    if [[ -z "$dest_server_ip" || "$dest_server_ip" == "null" ]]; then
        _error "Destination server IP not found in state"
        _log "STEP 10 FAILED: dest_server_ip not in state"
        return 1
    fi

    local ssh_user="root"
    local ssh_opts=(-o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
    ssh_opts+=(-o "UserKnownHostsFile=${STATE_DIR}/gp-site-mig-${SITE}-known_hosts")

    if [[ "$DRY_RUN" == "1" ]]; then
        _dry_run_msg "Would create cyber.html with content 'vm7' in $dest_htdocs_path"
        _dry_run_msg "Would chown cyber.html to match site ownership"
        _dry_run_msg "Would run: gp fix cached $site_url"
        _dry_run_msg "Would run: wp cache flush"
        _state_add_completed_step "10"
        _success "Step 10 complete (dry-run)"
        return 0
    fi

    # Step 10.1: Create cyber.html file for DNS propagation verification
    _loading2 "Creating cyber.html in destination htdocs..."
    local cyber_output cyber_rc
    cyber_output=$(ssh "${ssh_opts[@]}" "$ssh_user@$dest_server_ip" "set -e; file='$dest_htdocs_path/cyber.html'; echo 'vm7' > \"\$file\"; owner_group=\$(stat -c '%U:%G' '$dest_htdocs_path' 2>/dev/null || ls -ld '$dest_htdocs_path' | awk '{print \$3":"\$4}'); [[ -n \"\$owner_group\" ]] && chown \"\$owner_group\" \"\$file\" || true; ls -l \"\$file\"" 2>&1)
    cyber_rc=$?
    if [[ $cyber_rc -eq 0 ]]; then
        _verbose "cyber.html created successfully"
        _loading3 "Created: $dest_htdocs_path/cyber.html (content: vm7)"
        _loading3 "Use to verify DNS: curl -s http://$site_url/cyber.html"
    else
        _warning "Failed to create cyber.html: $cyber_output"
        _log "STEP 10 WARNING: cyber.html creation failed - $cyber_output"
    fi

    # Step 10.2: Run gp fix cached
    _loading2 "Running gp fix cached $site_url on destination..."
    local gp_fix_output gp_fix_rc
    gp_fix_output=$(ssh "${ssh_opts[@]}" "$ssh_user@$dest_server_ip" "gp fix cached '$site_url' 2>&1")
    gp_fix_rc=$?
    if [[ $gp_fix_rc -eq 0 ]]; then
        _verbose "gp fix cached completed successfully"
        _verbose "Output: $gp_fix_output"
    else
        _warning "gp fix cached returned: $gp_fix_rc"
        _verbose "Output: $gp_fix_output"
        _log "STEP 10 WARNING: gp fix cached failed - $gp_fix_output"
    fi

    # Step 10.3: Clear WordPress object cache using wp-cli
    _loading2 "Clearing WordPress object cache on destination..."
    local wp_cache_output wp_cache_rc
    wp_cache_output=$(ssh "${ssh_opts[@]}" "$ssh_user@$dest_server_ip" "cd '$dest_htdocs_path' && wp cache flush --allow-root 2>&1" 2>&1)
    wp_cache_rc=$?
    if [[ $wp_cache_rc -eq 0 ]]; then
        _verbose "WordPress cache flushed successfully"
    else
        _warning "WordPress cache flush returned: $wp_cache_rc"
        _verbose "Output: $wp_cache_output"
        _log "STEP 10 WARNING: wp cache flush failed - $wp_cache_output"
    fi

    _state_add_completed_step "10"
    _success "Step 10 complete: Final steps done"
    _log "STEP 10 COMPLETE: cyber.html created, caches cleared"
    echo
    return 0
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
        -d|--debug)
            DEBUG="1"
            shift
            ;;
        --rsync-local)
            RSYNC_LOCAL="1"
            shift
            ;;
        --db-file)
            DB_FILE="1"
            shift
            ;;
        --force-db)
            FORCE_DB="1"
            shift
            ;;
        --skip-db)
            SKIP_DB="1"
            shift
            ;;
        --dns-integration)
            if [[ -z "$2" || "$2" == -* ]]; then
                _usage
                _error "No DNS integration ID provided after --dns-integration flag"
                exit 1
            fi
            DNS_INTEGRATION_ID="$2"
            shift 2
            ;;
        --dns-integration-skip)
            DNS_INTEGRATION_SKIP="1"
            shift
            ;;
        --list-states)
            LIST_STATES="1"
            shift
            ;;
        --clear-state)
            CLEAR_STATE="1"
            shift
            ;;
        --fix-state)
            FIX_STATE="1"
            shift
            ;;
        --json)
            if [[ -z "$2" || "$2" == -* ]]; then
                _usage
                _error "No JSON file provided after --json flag"
                exit 1
            fi
            DATA_FILE="$2"
            DATA_FORMAT="json"
            shift 2
            ;;
        --csv)
            if [[ -z "$2" || "$2" == -* ]]; then
                _usage
                _error "No CSV file provided after --csv flag"
                exit 1
            fi
            DATA_FILE="$2"
            DATA_FORMAT="csv"
            shift 2
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
# Handle --list-states (no site required)
# -----------------------------------------------------------------------------
if [[ "$LIST_STATES" == "1" ]]; then
    echo "Migration State Files:"
    echo
    if [[ ! -d "$STATE_DIR" ]] || [[ -z "$(ls -A "$STATE_DIR" 2>/dev/null)" ]]; then
        echo "  No state files found."
        exit 0
    fi
    printf "  %-40s %s\n" "SITE" "COMPLETED STEPS"
    printf "  %-40s %s\n" "----" "---------------"
    for state_file in "$STATE_DIR"/gp-site-mig-*.json; do
        [[ -f "$state_file" ]] || continue
        site_name=$(basename "$state_file" | sed 's/gp-site-mig-//; s/.json//')
        completed=$(jq -r '.completed_steps // [] | join(", ")' "$state_file" 2>/dev/null || echo "none")
        [[ -z "$completed" ]] && completed="none"
        printf "  %-40s %s\n" "$site_name" "$completed"
    done
    echo
    exit 0
fi

# -----------------------------------------------------------------------------
# Handle --clear-state (requires -s site)
# -----------------------------------------------------------------------------
if [[ "$CLEAR_STATE" == "1" ]]; then
    if [[ -z "$SITE" ]]; then
        _error "--clear-state requires -s <site> to specify which state to clear"
        exit 1
    fi
    SITE=$(_sanitize_domain "$SITE")
    STATE_FILE="${STATE_DIR}/gp-site-mig-${SITE}.json"
    KNOWN_HOSTS_FILE="${STATE_DIR}/gp-site-mig-${SITE}-known_hosts"
    
    if [[ ! -f "$STATE_FILE" ]]; then
        _error "No state file found for site: $SITE"
        exit 1
    fi
    
    echo "Clearing state for site: $SITE"
    rm -f "$STATE_FILE" && echo "  Removed: $STATE_FILE"
    [[ -f "$KNOWN_HOSTS_FILE" ]] && rm -f "$KNOWN_HOSTS_FILE" && echo "  Removed: $KNOWN_HOSTS_FILE"
    _success "State cleared for $SITE"
    exit 0
fi

# -----------------------------------------------------------------------------
# Handle --fix-state (requires -s site) - deduplicate completed_steps
# -----------------------------------------------------------------------------
if [[ "$FIX_STATE" == "1" ]]; then
    if [[ -z "$SITE" ]]; then
        _error "--fix-state requires -s <site> to specify which state to fix"
        exit 1
    fi
    SITE=$(_sanitize_domain "$SITE")
    STATE_FILE="${STATE_DIR}/gp-site-mig-${SITE}.json"
    
    if [[ ! -f "$STATE_FILE" ]]; then
        _error "No state file found for site: $SITE"
        exit 1
    fi
    
    echo "Fixing state for site: $SITE"
    local tmp_file="${STATE_FILE}.tmp"
    # Deduplicate completed_steps array while preserving order
    jq '.completed_steps = (.completed_steps | unique)' "$STATE_FILE" > "$tmp_file" \
        && mv "$tmp_file" "$STATE_FILE"
    
    completed=$(jq -r '.completed_steps | join(", ")' "$STATE_FILE" 2>/dev/null)
    echo "  Deduplicated completed_steps: $completed"
    _success "State fixed for $SITE"
    exit 0
fi

# -----------------------------------------------------------------------------
# Validate Required Arguments
# -----------------------------------------------------------------------------
# When using --json or --csv, profiles are optional (data comes from file)
if [[ -n "$DATA_FILE" ]]; then
    if [[ -z "$SITE" ]]; then
        _usage
        echo
        _error "Missing required argument:"
        _error "  -s, --site is required"
        exit 1
    fi
    # Set placeholder profile names when using file-based data
    [[ -z "$SOURCE_PROFILE" ]] && SOURCE_PROFILE="file-source"
    [[ -z "$DEST_PROFILE" ]] && DEST_PROFILE="file-dest"
elif [[ -z "$SITE" || -z "$SOURCE_PROFILE" || -z "$DEST_PROFILE" ]]; then
    _usage
    echo
    _error "Missing required arguments:"
    [[ -z "$SITE" ]] && _error "  -s, --site is required"
    [[ -z "$SOURCE_PROFILE" ]] && _error "  -sp, --source-profile is required (or use --json/--csv)"
    [[ -z "$DEST_PROFILE" ]] && _error "  -dp, --dest-profile is required (or use --json/--csv)"
    exit 1
fi

# Sanitize site domain
SITE=$(_sanitize_domain "$SITE")

# Define state and log file paths (must be after SITE is set)
STATE_FILE="${STATE_DIR}/gp-site-mig-${SITE}.json"
LOG_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/gp-site-mig-${SITE}-${LOG_TIMESTAMP}.log"
ERROR_LOG_FILE="${LOG_DIR}/gp-site-mig-${SITE}-${LOG_TIMESTAMP}_error.log"

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------
_loading "GridPane Site Migration - $VERSION"
_pre_flight_mig

# Display migration summary
echo
echo "  Site:        $SITE"
if [[ -n "$DATA_FILE" ]]; then
    echo "  Data Source: $DATA_FILE ($DATA_FORMAT)"
else
    echo "  Source:      $SOURCE_PROFILE"
    echo "  Destination: $DEST_PROFILE"
fi

# Show server details if state file exists
if [[ -f "$STATE_FILE" ]]; then
    _src_name=$(_state_read ".data.source_server_name" 2>/dev/null)
    _src_ip=$(_state_read ".data.source_server_ip" 2>/dev/null)
    _dest_name=$(_state_read ".data.dest_server_name" 2>/dev/null)
    _dest_ip=$(_state_read ".data.dest_server_ip" 2>/dev/null)
    if [[ -n "$_src_ip" ]]; then
        if [[ -n "$_src_name" ]]; then
            echo "  Source Server:      $_src_name ($_src_ip)"
        else
            echo "  Source Server:      $_src_ip"
        fi
    fi
    if [[ -n "$_dest_ip" ]]; then
        if [[ -n "$_dest_name" ]]; then
            echo "  Destination Server: $_dest_name ($_dest_ip)"
        else
            echo "  Destination Server: $_dest_ip"
        fi
    fi
    unset _src_name _src_ip _dest_name _dest_ip
fi
echo

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
_verbose "Rsync Local Relay: $RSYNC_LOCAL"
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
_verbose "Log file: $LOG_FILE"
_verbose "State file: $STATE_FILE"

_debug "DEBUG: DRY_RUN=$DRY_RUN"
_debug "DEBUG: VERBOSE=$VERBOSE"
_debug "DEBUG: DEBUG=$DEBUG"
_debug "DEBUG: RUN_STEP=$RUN_STEP"
_debug "DEBUG: RSYNC_LOCAL=$RSYNC_LOCAL"
_debug "DEBUG: SITE=$SITE"
_debug "DEBUG: SOURCE_PROFILE=$SOURCE_PROFILE"
_debug "DEBUG: DEST_PROFILE=$DEST_PROFILE"
_debug "DEBUG: STATE_FILE=$STATE_FILE"
_debug "DEBUG: LOG_FILE=$LOG_FILE"

# =============================================================================
# Execute Migration Steps
# =============================================================================

# Step 1: Validate Input (or load from file)
if [[ -n "$DATA_FILE" ]]; then
    # Load data from file instead of API
    if ! _state_is_step_completed "1"; then
        _loading "Step 1: Loading site data from file"
        if ! _load_data_from_file "$SITE"; then
            _error "Migration failed at Step 1 (file data load)"
            _log "Migration FAILED at Step 1 (file data load)"
            exit 1
        fi
    else
        _loading3 "Step 1 already completed (data from file), skipping..."
    fi
else
    # Use API-based validation
    if ! _run_step "1" _step_1; then
        _error "Migration failed at Step 1"
        _log "Migration FAILED at Step 1"
        exit 1
    fi
fi

# Step 1.1: Validate system users
if ! _run_step "1.1" _step_1_1; then
    _error "Migration failed at Step 1.1"
    _log "Migration FAILED at Step 1.1"
    exit 1
fi

# Step 1.2: Get domain routing
if ! _run_step "1.2" _step_1_2; then
    _error "Migration failed at Step 1.2"
    _log "Migration FAILED at Step 1.2"
    exit 1
fi

# Step 1.3: Get SSL and DNS integration info
if ! _run_step "1.3" _step_1_3; then
    _error "Migration failed at Step 1.3"
    _log "Migration FAILED at Step 1.3"
    exit 1
fi

# Step 2.1: Resolve server IPs
if ! _run_step "2.1" _step_2_1; then
    _error "Migration failed at Step 2.1"
    _log "Migration FAILED at Step 2.1"
    exit 1
fi

# Step 2.2: Test SSH connectivity
if ! _run_step "2.2" _step_2_2; then
    _error "Migration failed at Step 2.2"
    _log "Migration FAILED at Step 2.2"
    exit 1
fi

# Step 2.5: Confirm site directory paths
if ! _run_step "2.5" _step_2_5; then
    _error "Migration failed at Step 2.5"
    _log "Migration FAILED at Step 2.5"
    exit 1
fi

# Step 2.3: Get database name from wp-config.php
if ! _run_step "2.3" _step_2_3; then
    _error "Migration failed at Step 2.3"
    _log "Migration FAILED at Step 2.3"
    exit 1
fi

# Step 2.4: Confirm database exists
if ! _run_step "2.4" _step_2_4; then
    _error "Migration failed at Step 2.4"
    _log "Migration FAILED at Step 2.4"
    exit 1
fi

# Step 3.1: Verify rsync on source
if ! _run_step "3.1" _step_3_1; then
    _error "Migration failed at Step 3.1"
    _log "Migration FAILED at Step 3.1"
    exit 1
fi

# Step 3.2: Verify rsync on destination
if ! _run_step "3.2" _step_3_2; then
    _error "Migration failed at Step 3.2"
    _log "Migration FAILED at Step 3.2"
    exit 1
fi

# Step 3.3: Authorize destination SSH key on source
if ! _run_step "3.3" _step_3_3; then
    _error "Migration failed at Step 3.3"
    _log "Migration FAILED at Step 3.3"
    exit 1
fi

# Step 3.4: Rsync htdocs
if ! _run_step "3.4" _step_3_4; then
    _error "Migration failed at Step 3.4"
    _log "Migration FAILED at Step 3.4"
    exit 1
fi

# Step 4: Migrate database
if ! _run_step "4" _step_4; then
    _error "Migration failed at Step 4"
    _log "Migration FAILED at Step 4"
    exit 1
fi

# Step 5.1: Check for custom nginx configs
if ! _run_step "5.1" _step_5_1; then
    _error "Migration failed at Step 5.1"
    _log "Migration FAILED at Step 5.1"
    exit 1
fi

# Step 5.2: Run gp commands for special configs
if ! _run_step "5.2" _step_5_2; then
    _error "Migration failed at Step 5.2"
    _log "Migration FAILED at Step 5.2"
    exit 1
fi

# Step 5.3: Backup and copy nginx files
if ! _run_step "5.3" _step_5_3; then
    _error "Migration failed at Step 5.3"
    _log "Migration FAILED at Step 5.3"
    exit 1
fi

# Step 6: Copy user-configs.php
if ! _run_step "6" _step_6; then
    _error "Migration failed at Step 6"
    _log "Migration FAILED at Step 6"
    exit 1
fi

# Step 7: Sync domain route
if ! _run_step "7" _step_7; then
    _error "Migration failed at Step 7"
    _log "Migration FAILED at Step 7"
    exit 1
fi

# Step 8: Enable DNS Integration on Destination
if ! _run_step "8" _step_8; then
    _error "Migration failed at Step 8"
    _log "Migration FAILED at Step 8"
    exit 1
fi

# Step 9: Enable SSL on Destination
if ! _run_step "9" _step_9; then
    _error "Migration failed at Step 9"
    _log "Migration FAILED at Step 9"
    exit 1
fi

# Step 10: Final Steps (cyber.html, cache flush)
if ! _run_step "10" _step_10; then
    _error "Migration failed at Step 10"
    _log "Migration FAILED at Step 10"
    exit 1
fi

# All steps completed successfully
if [[ -n "$RUN_STEP" ]]; then
    case "$RUN_STEP" in
        1|1.1|1.2|1.3|2|2.1|2.2|2.3|2.4|2.5|3|3.1|3.2|3.3|3.4|4|5|5.1|5.2|5.3|6|7|8|9|10)
            ;;
        *)
            _error "Requested step '$RUN_STEP' is not implemented yet"
            _log "Migration FAILED: Requested step '$RUN_STEP' not implemented"
            exit 1
            ;;
    esac
fi

_success "Migration completed successfully!"
exit 0
