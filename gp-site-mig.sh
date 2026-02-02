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
DEBUG="0"
RUN_STEP=""
RSYNC_LOCAL="0"
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
    echo "  -d,  --debug                    Enable debug output"
    echo "  --rsync-local                    If server-to-server rsync fails, relay via local machine"
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
    echo "          3.3  Authorize destination SSH key on source (remote rsync prereq)"
    echo "          3.4  Rsync htdocs"
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

    local source_server_label source_server_ip
    source_server_label=$(_resolve_server_label_for_profile "$SOURCE_PROFILE" "$source_server_id")
    source_server_ip=$(_resolve_server_ip_for_profile "$SOURCE_PROFILE" "$source_server_id")

    if [[ "$source_server_label" == "UNKNOWN" ]]; then
        _warning "Server cache missing for '$SOURCE_PROFILE' (cannot resolve server label)."
        _loading3 "Run: ./gp-api.sh -p $SOURCE_PROFILE -c cache-servers"
        _log "STEP 1: Server cache missing for profile $SOURCE_PROFILE"
    fi
    
    _debug "Source site_id: $source_site_id"
    _debug "Source site_url: $source_site_url"
    _debug "Source server_id: $source_server_id"
    _debug "Source server_label: $source_server_label"
    _debug "Source server_ip: $source_server_ip"
    _debug "Source system_user_id: $source_system_user_id"
    
    _success "Found site on source: $source_site_url (site_id=$source_site_id)"
    _loading3 "  Source server: $source_server_label (server_id=$source_server_id, ip=$source_server_ip)"
    _log "Source site found: url=$source_site_url, id=$source_site_id, server_id=$source_server_id, server_label=$source_server_label, server_ip=$source_server_ip, system_user_id=$source_system_user_id"
    
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

    local dest_server_label dest_server_ip
    dest_server_label=$(_resolve_server_label_for_profile "$DEST_PROFILE" "$dest_server_id")
    dest_server_ip=$(_resolve_server_ip_for_profile "$DEST_PROFILE" "$dest_server_id")

    if [[ "$dest_server_label" == "UNKNOWN" ]]; then
        _warning "Server cache missing for '$DEST_PROFILE' (cannot resolve server label)."
        _loading3 "Run: ./gp-api.sh -p $DEST_PROFILE -c cache-servers"
        _log "STEP 1: Server cache missing for profile $DEST_PROFILE"
    fi
    
    _debug "Dest site_id: $dest_site_id"
    _debug "Dest site_url: $dest_site_url"
    _debug "Dest server_id: $dest_server_id"
    _debug "Dest server_label: $dest_server_label"
    _debug "Dest server_ip: $dest_server_ip"
    _debug "Dest system_user_id: $dest_system_user_id"
    
    _success "Found site on destination: $dest_site_url (site_id=$dest_site_id)"
    _loading3 "  Dest server: $dest_server_label (server_id=$dest_server_id, ip=$dest_server_ip)"
    _log "Destination site found: url=$dest_site_url, id=$dest_site_id, server_id=$dest_server_id, server_label=$dest_server_label, server_ip=$dest_server_ip, system_user_id=$dest_system_user_id"
    
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
    _state_write ".data.dest_site_id" "$dest_site_id"
    _state_write ".data.dest_site_url" "$dest_site_url"
    _state_write ".data.dest_server_id" "$dest_server_id"
    _state_write ".data.dest_server_label" "$dest_server_label"
    _state_write ".data.dest_server_ip" "$dest_server_ip"
    _state_write ".data.dest_system_user_id" "$dest_system_user_id"
    
    # Mark step complete
    _state_add_completed_step "1"
    
    _success "Step 1 complete: Input validation passed"
    _log "STEP 1 COMPLETE: Input validation passed"
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
            return $?
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

echo -n "$db"' --
EOF
)
    cmd="${cmd%$'\n'}"

    local source_db dest_db
    source_db=$(_ssh_capture "$source_server_ip" "$cmd '$source_wp_config' '$DEBUG'")
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

    dest_db=$(_ssh_capture "$dest_server_ip" "$cmd '$dest_wp_config' '$DEBUG'")
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
        "--exclude=.git"
        "--exclude=.gitignore"
        "--exclude=.DS_Store"
        "--exclude=wp-config.php"
        "--exclude=.htaccess"
        "--exclude=cache/"
        "--exclude=wp-content/cache/"
        "--exclude=wp-content/w3tc-config/"
        "--exclude=wp-content/uploads/cache/"
        "--exclude=wp-content/debug.log"
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
        _error "Missing server IPs in state. Run Step 2.1 first."
        _log "STEP 4 FAILED: Missing server IPs"
        return 1
    fi

    if [[ -z "$source_db" || -z "$dest_db" ]]; then
        _error "Missing DB names in state. Run Step 2.3 first."
        _log "STEP 4 FAILED: Missing DB names"
        return 1
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

    _state_add_completed_step "4"
    _log "STEP 4 COMPLETE: Database migration successful"
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

# Step 1: Validate Input
if ! _run_step "1" _step_1; then
    _error "Migration failed at Step 1"
    _log "Migration FAILED at Step 1"
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

# Stop after the last implemented step.
# If a specific step was requested and it's not implemented, fail clearly.
if [[ -n "$RUN_STEP" ]]; then
    case "$RUN_STEP" in
        1|2|2.1|2.2|2.3|2.4|2.5|3|3.1|3.2|3.3|3.4|4)
            ;;
        *)
            _error "Requested step '$RUN_STEP' is not implemented yet"
            _log "Migration FAILED: Requested step '$RUN_STEP' not implemented"
            exit 1
            ;;
    esac
fi

_log "Stopping after Step 4 (remaining steps not implemented yet)"
exit 0
