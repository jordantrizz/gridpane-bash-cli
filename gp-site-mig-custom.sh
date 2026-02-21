#!/usr/bin/env bash
# gp-site-mig-custom.sh - Migrate a site from a custom SSH server to GridPane
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_FILE="$HOME/.gridpane"
CACHE_DIR="$HOME/.gpbc-cache"
VERSION="$(cat $SCRIPT_DIR/VERSION)"
MIG_PREFIX="gp-site-mig-custom"
GP_API_URL="https://my.gridpane.com/oauth/api/v1"

# Source shared functions
source "$SCRIPT_DIR/inc/gp-inc.sh"
source "$SCRIPT_DIR/inc/gp-inc-api.sh"

# Migration-specific globals
DRY_RUN="0"
VERBOSE="0"
DEBUG="0"
RUN_STEP=""
RSYNC_LOCAL="0"
DB_FILE="0"
FORCE_DB="0"
SKIP_DB="0"
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
    echo "Usage: $0 -s <site> -dp <dest-profile> (--csv <file> | --json <file>) [options]"
    echo
    echo "Migrate a site from a custom SSH server to a GridPane server (destination)."
    echo
    echo "Required Arguments:"
    echo "  -s,  --site <domain>            Site domain to migrate (e.g., example.com)"
    echo "  -dp, --dest-profile <name>      Destination account profile name (from ~/.gridpane)"
    echo "  --csv <file>                    Load site data from CSV seed (custom source)"
    echo "  --json <file>                   Load site data from JSON seed (custom source)"
    echo
    echo "Options:"
    echo "  -n,  --dry-run                  Show what would be done without executing"
    echo "  -v,  --verbose                  Show detailed output"
    echo "  -d,  --debug                    Enable debug output"
    echo "  --rsync-local                    If server-to-server rsync fails, relay via local machine"
    echo "  --db-file                       Use file-based DB migration (dump to file, gzip, transfer, import)"
    echo "  --force-db                      Force database migration even if marker exists on destination"
    echo "  --skip-db                       Skip database migration if marker already exists (continue to next step)"
    echo "  --step <step>                   Run a specific step only (e.g., 3 or 2.2)"
    echo "  --list-states                   List all migration state files"
    echo "  --clear-state                   Clear state file for the specified site (-s required)"
    echo "  --fix-state                     Deduplicate completed_steps in state file (-s required)"
    echo "  -h,  --help                     Show this help message"
    echo
    echo "Migration Steps:"
    echo "  1      - Validate source/destination site via caches (or load seed file)"
    echo "  1.1    - Autodetect missing dest fields from profile cache"
    echo "  1.2    - Validate system users"
    echo "  1.3    - Capture primary domain routing"
    echo "  2      - Server discovery and SSH validation"
    echo "    2.2  - Test SSH to source and destination"
    echo "    2.5  - Locate wp-config.php and set site/htdocs paths"
    echo "    2.3  - Read DB_NAME and credentials from wp-config.php"
    echo "    2.4  - Confirm database exists on both servers"
    echo "  3      - Files: rsync htdocs"
    echo "    3.1  - Verify rsync on source"
    echo "    3.2  - Verify rsync and htdocs writable on destination"
    echo "    3.3  - Authorize destination SSH key on source"
    echo "    3.4  - Sync htdocs (direct dest->source rsync, --rsync-local fallback)"
    echo "  4      - Migrate database (mysqldump -> mysql; honors --force-db/--skip-db)"
    echo "  5      - Nginx config check + XML-RPC hardening"
    echo "    5.1  - Detect custom and special configs"
    echo "  6      - Sync domain routing to match source (destination: gp site -route-domain-*)"
    echo "  7      - Enable SSL on destination (prompts for DNS confirmation)"
    echo "  8      - Final steps: backup source wp-config.php, cyber.html, gp fix cached, wp cache flush"
    echo
    echo "State & Logs:"
    echo "  State files: $STATE_DIR/${MIG_PREFIX}-<site>.json"
    echo "  Log files:   $LOG_DIR/${MIG_PREFIX}-<site>-<timestamp>.log"
    echo
    echo "Examples:"
    echo "  $0 -s example.com -dp staging-account --csv conf/rocket-gp-site-mig.csv.example"
    echo "  $0 -s example.com -dp staging-account --json conf/rocket-gp-site-mig.json.example -n -v"
    echo "  $0 -s example.com -dp staging-account --step 2.2 --csv conf/rocket-gp-site-mig.csv.example"
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
        local source_system_user_id source_system_user_name source_ssh_host source_ssh_user source_ssh_port source_webroot
        source_site_id=$(echo "$site_data" | jq -r '.source.site_id // "0"')
        source_site_url=$(echo "$site_data" | jq -r '.url')
        source_server_id=$(echo "$site_data" | jq -r '.source.server_id // "0"')
        source_server_label=$(echo "$site_data" | jq -r '.source.server_label // "unknown"')
        source_server_ip=$(echo "$site_data" | jq -r '.source.server_ip')
        source_system_user_id=$(echo "$site_data" | jq -r '.source.system_user_id // "0"')
        source_system_user_name=$(echo "$site_data" | jq -r '.source.system_user_name // "unknown"')
        source_ssh_host=$(echo "$site_data" | jq -r '.source.ssh_host // empty')
        source_ssh_user=$(echo "$site_data" | jq -r '.source.ssh_user // empty')
        source_ssh_port=$(echo "$site_data" | jq -r '.source.ssh_port // empty')
        source_webroot=$(echo "$site_data" | jq -r '.source.webroot // empty')

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
        # Expected format: url,source_server_ip,source_ssh_user,dest_site_id,dest_server_id,dest_server_label,dest_server_ip,dest_system_user_id,dest_system_user_name,dest_ssh_user[,dest_profile]
        # Note: dest_site_id and dest_server_id can be blank/0 and will be autodetected from the dest profile's site cache
        local csv_line
        csv_line=$(grep "^${site_domain}," "$DATA_FILE" | head -1)

        if [[ -z "$csv_line" ]]; then
            _error "Site '$site_domain' not found in CSV file"
            return 1
        fi

        # Parse CSV line (simple approach - assumes no commas in values)
        IFS=',' read -r source_site_url source_server_ip source_ssh_user_csv dest_site_id dest_server_id dest_server_label dest_server_ip dest_system_user_id dest_system_user_name dest_ssh_user_csv dest_profile_csv <<< "$csv_line"
        dest_site_url="$source_site_url"
        source_site_id="0"
        source_server_id="0"
        source_system_user_id="0"
        source_server_label="custom"
        source_ssh_host="$source_server_ip"
        source_ssh_user="${source_ssh_user_csv:-$source_system_user_name}"
        source_system_user_name="$source_ssh_user"
        source_ssh_port="22"
        source_webroot=""
        dest_ssh_user="${dest_ssh_user_csv:-${GPBC_SSH_USER:-root}}"

        # Override DEST_PROFILE from CSV if provided and not already set via CLI
        if [[ -n "$dest_profile_csv" && ( -z "$DEST_PROFILE" || "$DEST_PROFILE" == "file-dest" ) ]]; then
            DEST_PROFILE="$dest_profile_csv"
            _verbose "CSV override: DEST_PROFILE=$DEST_PROFILE"
        fi

        _verbose "CSV parsed: url=$source_site_url source_ip=$source_server_ip source_ssh_user=$source_ssh_user dest_site_id=$dest_site_id dest_server_id=$dest_server_id dest_server_label=$dest_server_label dest_ip=$dest_server_ip dest_user_id=$dest_system_user_id dest_user_name=$dest_system_user_name dest_ssh_user=$dest_ssh_user"
    else
        _error "Unknown data format: $DATA_FORMAT"
        return 1
    fi

    # Normalize SSH host/user/port for custom source
    [[ -z "$source_ssh_host" || "$source_ssh_host" == "null" ]] && source_ssh_host="$source_server_ip"
    [[ -z "$source_ssh_user" || "$source_ssh_user" == "null" ]] && source_ssh_user="root"
    [[ -z "$source_ssh_port" || "$source_ssh_port" == "null" ]] && source_ssh_port="22"
    
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
    _state_write ".data.source_ssh_host" "$source_ssh_host"
    _state_write ".data.source_ssh_user" "$source_ssh_user"
    _state_write ".data.source_ssh_port" "$source_ssh_port"
    _state_write ".data.dest_ssh_user" "$dest_ssh_user"
    _state_write ".data.dest_ssh_port" "22"
    _state_write ".data.source_webroot" "$source_webroot"
    _state_write ".data.ssh_user" "$source_ssh_user"
    _state_write ".data.custom_source" "1"
    _state_write ".data_source" "file:$DATA_FILE"
    
    # Mark step 1 as complete (data loaded from file replaces API validation)
    _state_add_completed_step "1"
    _log "STEP 2 COMPLETE: Server discovery and SSH validation done"
    
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
# Usage: _state_add_completed_step "1" or _state_add_completed_step "2.2"
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
# Usage: if _state_is_step_completed "2.2"; then echo "Skip"; fi
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

    jq --arg user_id "$system_user_id" -r '
        flatten
        | .[]
        | select((.id | tostring) == ($user_id | tostring))
        | (.username // .name // .user_name // .user // empty)
    ' "$cache_file" 2>/dev/null | head -n1
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
# Step 1.1 - Autodetect missing dest fields from profile site cache
# When dest_site_id or dest_server_id are blank/0, look them up by URL
# in the destination profile's site cache. Also fills in dest_server_label,
# dest_server_ip, dest_system_user_id, and dest_system_user_name if missing.
# -----------------------------------------------------------------------------
function _step_1_1() {
    _loading "Step 1.1: Autodetect destination site/server from profile cache"
    _log "STEP 1.1: Starting dest autodetection"

    local dest_site_id dest_server_id dest_site_url
    dest_site_id=$(_state_read ".data.dest_site_id")
    dest_server_id=$(_state_read ".data.dest_server_id")
    dest_site_url=$(_state_read ".data.dest_site_url")
    [[ -z "$dest_site_url" || "$dest_site_url" == "null" ]] && dest_site_url="$SITE"

    # Check if site cache lookup is needed (for missing dest ids/user id)
    local _needs_cache_lookup=0
    local dest_system_user_id
    dest_system_user_id=$(_state_read ".data.dest_system_user_id")
    if [[ -z "$dest_site_id" || "$dest_site_id" == "0" || "$dest_site_id" == "null" \
       || -z "$dest_server_id" || "$dest_server_id" == "0" || "$dest_server_id" == "null" \
       || -z "$dest_system_user_id" || "$dest_system_user_id" == "0" || "$dest_system_user_id" == "null" ]]; then
        _needs_cache_lookup=1
    fi

    local _auto_profile="$DEST_PROFILE"
    if [[ -z "$_auto_profile" || "$_auto_profile" == "file-dest" ]]; then
        if [[ "$_needs_cache_lookup" == "1" ]]; then
            _warning "No dest profile set - cannot autodetect dest_site_id/dest_server_id"
        fi
        _log "STEP 1.1: No dest profile available for autodetection"
        _state_add_completed_step "1.1"
        return 0
    fi

    # --- Site cache lookup (only if site_id or server_id missing) ---
    if [[ "$_needs_cache_lookup" == "1" ]]; then
        local _auto_cache="${CACHE_DIR}/${_auto_profile}_site.json"
        if [[ ! -f "$_auto_cache" ]]; then
            _warning "Site cache not found for profile '$_auto_profile' - cannot autodetect dest IDs"
            _loading3 "Run: ./gp-api.sh -p $_auto_profile -c cache-sites"
            _log "STEP 1.1: Site cache missing for profile $_auto_profile"
            _state_add_completed_step "1.1"
            return 0
        fi

        local _auto_site_data
        _auto_site_data=$(jq --arg domain "$dest_site_url" 'flatten | .[] | select(.url == $domain)' "$_auto_cache" 2>/dev/null | head -c 65536)

        if [[ -z "$_auto_site_data" || "$_auto_site_data" == "null" ]]; then
            _warning "Site '$dest_site_url' not found in $_auto_profile site cache for autodetection"
            _loading3 "Run: ./gp-api.sh -p $_auto_profile -c cache-sites"
            _log "STEP 1.1: Site not found in cache for profile $_auto_profile"
            _state_add_completed_step "1.1"
            return 0
        fi

        # Autodetect dest_site_id
        if [[ -z "$dest_site_id" || "$dest_site_id" == "0" || "$dest_site_id" == "null" ]]; then
            dest_site_id=$(echo "$_auto_site_data" | jq -r '.id')
            _state_write ".data.dest_site_id" "$dest_site_id"
            _verbose "Autodetected dest_site_id=$dest_site_id from profile $_auto_profile"
        fi

        # Autodetect dest_server_id
        if [[ -z "$dest_server_id" || "$dest_server_id" == "0" || "$dest_server_id" == "null" ]]; then
            dest_server_id=$(echo "$_auto_site_data" | jq -r '.server_id')
            _state_write ".data.dest_server_id" "$dest_server_id"
            _verbose "Autodetected dest_server_id=$dest_server_id from profile $_auto_profile"
        fi

        # Autodetect dest_system_user_id from site cache if missing
        dest_system_user_id=$(_state_read ".data.dest_system_user_id")
        if [[ -z "$dest_system_user_id" || "$dest_system_user_id" == "0" || "$dest_system_user_id" == "null" ]]; then
            dest_system_user_id=$(echo "$_auto_site_data" | jq -r '.system_user_id // "0"')
            _state_write ".data.dest_system_user_id" "$dest_system_user_id"
            _verbose "Autodetected dest_system_user_id=$dest_system_user_id"
        fi
    fi

    # --- Always resolve related fields (server label, IP, system user name) if blank ---
    local dest_server_label dest_server_ip dest_system_user_name
    dest_system_user_id=$(_state_read ".data.dest_system_user_id")
    dest_server_label=$(_state_read ".data.dest_server_label")
    dest_server_ip=$(_state_read ".data.dest_server_ip")
    dest_system_user_name=$(_state_read ".data.dest_system_user_name")

    if [[ -z "$dest_server_label" || "$dest_server_label" == "unknown" || "$dest_server_label" == "null" ]]; then
        dest_server_label=$(_resolve_server_label_for_profile "$_auto_profile" "$dest_server_id")
        _state_write ".data.dest_server_label" "$dest_server_label"
        _verbose "Autodetected dest_server_label=$dest_server_label"
    fi

    if [[ -z "$dest_server_ip" || "$dest_server_ip" == "null" || "$dest_server_ip" == "UNKNOWN" ]]; then
        dest_server_ip=$(_resolve_server_ip_for_profile "$_auto_profile" "$dest_server_id")
        _state_write ".data.dest_server_ip" "$dest_server_ip"
        _verbose "Autodetected dest_server_ip=$dest_server_ip"
    fi

    if [[ -z "$dest_system_user_name" || "$dest_system_user_name" == "unknown" || "$dest_system_user_name" == "null" || "$dest_system_user_name" == "UNKNOWN" ]]; then
        local resolved_user
        resolved_user=$(_resolve_system_user_name_for_profile "$_auto_profile" "$dest_system_user_id")

        if [[ -z "$resolved_user" || "$resolved_user" == "unknown" || "$resolved_user" == "null" || "$resolved_user" == "UNKNOWN" ]]; then
            _warning "Destination system user name not resolved from cache for profile $_auto_profile (id=${dest_system_user_id:-empty})"
            _loading3 "Run: ./gp-api.sh -p $_auto_profile -c cache-users"
            resolved_user="UNKNOWN"
        fi

        dest_system_user_name="$resolved_user"
        _state_write ".data.dest_system_user_name" "$dest_system_user_name"
        _verbose "Autodetected dest_system_user_name=$dest_system_user_name"
    fi

    _success "Step 1.1 complete: dest_site_id=$dest_site_id, dest_server_id=$dest_server_id"
    _loading3 "  Server: $dest_server_label ($dest_server_ip)"
    _loading3 "  System user: $dest_system_user_name (id=$dest_system_user_id)"
    _log "STEP 1.1 COMPLETE: dest_site_id=$dest_site_id, dest_server_id=$dest_server_id, dest_server_label=$dest_server_label, dest_server_ip=$dest_server_ip"
    _state_add_completed_step "1.1"
    echo
    return 0
}

# -----------------------------------------------------------------------------
# Step 1.2 - Get system user usernames from system-user API
# Queries the system-user API using system_user_id from site data
# Stores: source_system_user (username), dest_system_user (username)
# Note: This is largely redundant now as Step 1 already resolves usernames
#       from cache, but kept for API-based validation if needed
# -----------------------------------------------------------------------------
function _step_1_2() {
    _loading "Step 1.2: Validate system users"
    _log "STEP 1.2: Starting system user validation"

    # Read system user data from state (captured in Step 1)
    local source_system_user_id source_system_user_name
    local dest_system_user_id dest_system_user_name
    source_system_user_id=$(_state_read ".data.source_system_user_id")
    source_system_user_name=$(_state_read ".data.source_system_user_name")
    dest_system_user_id=$(_state_read ".data.dest_system_user_id")
    dest_system_user_name=$(_state_read ".data.dest_system_user_name")

    if [[ -z "$source_system_user_id" || "$source_system_user_id" == "null" ]]; then
        _error "Source system user ID not found in state. Run Step 1 first."
        _log "STEP 1.2 FAILED: source_system_user_id not in state"
        return 1
    fi

    if [[ -z "$dest_system_user_id" || "$dest_system_user_id" == "null" ]]; then
        _error "Destination system user ID not found in state. Run Step 1 first."
        _log "STEP 1.2 FAILED: dest_system_user_id not in state"
        return 1
    fi

    _loading2 "Source system user: $source_system_user_name (id=$source_system_user_id)"
    _loading2 "Destination system user: $dest_system_user_name (id=$dest_system_user_id)"

    # Validate that usernames were resolved
    if [[ -z "$source_system_user_name" || "$source_system_user_name" == "UNKNOWN" || "$source_system_user_name" == "null" ]]; then
        _error "Source system user name not resolved. Check system-user cache for $SOURCE_PROFILE"
        _loading3 "Run: ./gp-api.sh -p $SOURCE_PROFILE -c cache-users"
        _log "STEP 1.2 FAILED: source_system_user_name not resolved"
        return 1
    fi

    if [[ -z "$dest_system_user_name" || "$dest_system_user_name" == "UNKNOWN" || "$dest_system_user_name" == "null" ]]; then
        _error "Destination system user name not resolved. Check system-user cache for $DEST_PROFILE"
        _loading3 "Run: ./gp-api.sh -p $DEST_PROFILE -c cache-users"
        _log "STEP 1.2 FAILED: dest_system_user_name not resolved"
        return 1
    fi

    _state_add_completed_step "1.2"
    _success "Step 1.2 complete: System users validated"
    _log "STEP 1.2 COMPLETE: source_user=$source_system_user_name, dest_user=$dest_system_user_name"
    echo
    return 0
}

# -----------------------------------------------------------------------------
# Resolve routing by curling apex and www and following redirects
# Returns: "<route>|<apex_effective>|<www_effective>" where route is root/www/none
# -----------------------------------------------------------------------------
function _curl_effective_url() {
    local url="$1"
    local effective
    effective=$(curl -ksL -o /dev/null -w '%{url_effective}' "$url" 2>/dev/null)
    [[ $? -ne 0 ]] && effective=""
    echo "$effective"
}

function _detect_route_from_http() {
    local domain="$1"

    local apex_effective www_effective apex_host www_host route
    apex_effective=$(_curl_effective_url "http://${domain}")
    [[ -z "$apex_effective" ]] && apex_effective=$(_curl_effective_url "https://${domain}")

    www_effective=$(_curl_effective_url "http://www.${domain}")
    [[ -z "$www_effective" ]] && www_effective=$(_curl_effective_url "https://www.${domain}")

    apex_host=$(echo "$apex_effective" | awk -F/ '{print $3}' | sed 's/:.*//')
    www_host=$(echo "$www_effective" | awk -F/ '{print $3}' | sed 's/:.*//')

    local apex_dom="$domain"
    local www_dom="www.${domain}"
    route="none"

    if [[ -z "$apex_host" && -z "$www_host" ]]; then
        route="none"
    elif [[ "$apex_host" == "$www_dom" && ( "$www_host" == "$www_dom" || -z "$www_host" ) ]]; then
        route="www"
    elif [[ "$www_host" == "$apex_dom" && ( "$apex_host" == "$apex_dom" || -z "$apex_host" ) ]]; then
        route="root"
    elif [[ "$apex_host" == "$apex_dom" && "$www_host" == "$apex_dom" ]]; then
        route="root"
    elif [[ "$apex_host" == "$www_dom" && "$www_host" == "$www_dom" ]]; then
        route="www"
    else
        route="none"
    fi

    _debug "Route detect ($domain): apex->$apex_effective (host=$apex_host), www->$www_effective (host=$www_host), route=$route"

    echo "$route|$apex_effective|$www_effective"
}

# -----------------------------------------------------------------------------
# Step 1.3 - Get domain routing for source and destination
# Gets the primary domain for source/dest sites from domains cache
# Reads the route field (none, www, root) for both
# Stores: source_domain_id, source_route, dest_domain_id, dest_route
# -----------------------------------------------------------------------------
function _step_1_3() {
    _loading "Step 1.3: Get domain routing"
    _log "STEP 1.3: Starting domain routing lookup"

    # Always infer via HTTP (no GridPane domain caches/API)
    local source_domain_url dest_domain_url source_domain_id dest_domain_id

    source_domain_url=$(_state_read ".data.source_domain_url")
    [[ -z "$source_domain_url" || "$source_domain_url" == "null" ]] && source_domain_url=$(_state_read ".data.source_site_url")
    [[ -z "$source_domain_url" || "$source_domain_url" == "null" ]] && source_domain_url="$SITE"

    dest_domain_url=$(_state_read ".data.dest_domain_url")
    [[ -z "$dest_domain_url" || "$dest_domain_url" == "null" ]] && dest_domain_url=$(_state_read ".data.dest_site_url")
    [[ -z "$dest_domain_url" || "$dest_domain_url" == "null" ]] && dest_domain_url="$SITE"

    # Source domain ID is not resolvable for custom sources - leave as placeholder
    source_domain_id=$(_state_read ".data.source_domain_id")
    [[ -z "$source_domain_id" || "$source_domain_id" == "null" ]] && source_domain_id="custom-source"

    # Resolve destination domain ID from GridPane domain cache (needed for API calls like SSL enable)
    dest_domain_id=$(_state_read ".data.dest_domain_id")
    if [[ -z "$dest_domain_id" || "$dest_domain_id" == "null" || "$dest_domain_id" == "http-derived" ]]; then
        local dest_site_id dest_domain_cache dest_domain_data
        dest_site_id=$(_state_read ".data.dest_site_id")

        if [[ -n "$dest_site_id" && "$dest_site_id" != "null" && "$dest_site_id" != "0" ]]; then
            # Switch to destination profile to read its domain cache
            local saved_token="$GPBC_TOKEN"
            local saved_token_name="$GPBC_TOKEN_NAME"

            if _gp_set_profile_silent "$DEST_PROFILE"; then
                dest_domain_cache="${CACHE_DIR}/${GPBC_TOKEN_NAME}_domain.json"

                if [[ -f "$dest_domain_cache" ]]; then
                    dest_domain_data=$(jq --arg site_id "$dest_site_id" \
                        '[flatten | .[] | select(.site_id == ($site_id | tonumber) and .type == "primary")] | .[0]' \
                        "$dest_domain_cache" 2>/dev/null)

                    if [[ -n "$dest_domain_data" && "$dest_domain_data" != "null" ]]; then
                        dest_domain_id=$(echo "$dest_domain_data" | jq -r '.id')
                        dest_domain_url=$(echo "$dest_domain_data" | jq -r '.url // empty')
                        [[ -z "$dest_domain_url" ]] && dest_domain_url="$SITE"
                        _verbose "Resolved dest_domain_id=$dest_domain_id from domain cache"
                    else
                        _warning "Primary domain not found in cache for dest site_id=$dest_site_id"
                        _loading3 "Run: ./gp-api.sh -p $DEST_PROFILE -c cache-domains"
                        dest_domain_id="unresolved"
                    fi
                else
                    _warning "Domain cache not found for profile '$DEST_PROFILE'"
                    _loading3 "Run: ./gp-api.sh -p $DEST_PROFILE -c cache-domains"
                    dest_domain_id="unresolved"
                fi

                # Restore original profile
                GPBC_TOKEN="$saved_token"
                GPBC_TOKEN_NAME="$saved_token_name"
            else
                _warning "Could not switch to destination profile '$DEST_PROFILE' to resolve domain ID"
                dest_domain_id="unresolved"
            fi
        else
            _verbose "dest_site_id not available; cannot resolve domain ID from cache"
            dest_domain_id="unresolved"
        fi
    fi

    local source_route source_apex_effective source_www_effective
    local dest_route dest_apex_effective dest_www_effective

    IFS='|' read -r source_route source_apex_effective source_www_effective <<< "$(_detect_route_from_http "$source_domain_url")"
    [[ -z "$source_route" ]] && source_route="none"

    IFS='|' read -r dest_route dest_apex_effective dest_www_effective <<< "$(_detect_route_from_http "$dest_domain_url")"
    [[ -z "$dest_route" ]] && dest_route="none"

    _loading3 "Source domain: $source_domain_url (id=$source_domain_id, route=$source_route)"
    _loading3 "Destination domain: $dest_domain_url (id=$dest_domain_id, route=$dest_route)"
    _debug "Source routing check: apex->$source_apex_effective, www->$source_www_effective"
    _debug "Destination routing check: apex->$dest_apex_effective, www->$dest_www_effective"

    if [[ "$source_route" == "$dest_route" ]]; then
        _loading3 "Routes match: $source_route"
    else
        _warning "Routes differ: source=$source_route, destination=$dest_route"
        _loading3 "Step 6 will sync the route from source to destination"
    fi

    _state_write ".data.source_domain_id" "$source_domain_id"
    _state_write ".data.source_domain_url" "$source_domain_url"
    _state_write ".data.source_route" "$source_route"
    _state_write ".data.dest_domain_id" "$dest_domain_id"
    _state_write ".data.dest_domain_url" "$dest_domain_url"
    _state_write ".data.dest_route" "$dest_route"

    _state_add_completed_step "1.3"
    _success "Step 1.3 complete: Domain routing captured via HTTP"
    _log "STEP 1.3 COMPLETE: source_route=$source_route, dest_route=$dest_route"
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
# Step 2.2 - Test SSH connectivity
# Requires server IPs in state
# -----------------------------------------------------------------------------
function _step_2_2() {
    _loading "Step 2.2: Testing SSH connectivity"
    _log "STEP 2.2: Testing SSH connectivity"

    local source_server_ip dest_server_ip custom_mode
    source_server_ip=$(_state_read ".data.source_server_ip")
    dest_server_ip=$(_state_read ".data.dest_server_ip")
    custom_mode=$(_state_read ".data.custom_source")

    if [[ -z "$source_server_ip" || -z "$dest_server_ip" ]]; then
        _error "Missing server IPs in state. Provide IPs via seed/state before SSH checks."
        _log "STEP 2.5 FAILED: Missing server IPs in state"
        return 1
    fi

    local ssh_user_source ssh_user_dest
    ssh_user_dest=$(_state_read ".data.dest_ssh_user")
    [[ -z "$ssh_user_dest" || "$ssh_user_dest" == "null" ]] && ssh_user_dest="${GPBC_SSH_USER:-root}"
    if [[ "$custom_mode" == "1" ]]; then
        ssh_user_source=$(_state_read ".data.source_ssh_user")
        [[ -z "$ssh_user_source" || "$ssh_user_source" == "null" ]] && ssh_user_source="${GPBC_SSH_USER:-root}"
    else
        ssh_user_source="${GPBC_SSH_USER:-root}"
    fi

    local known_hosts_file
    known_hosts_file="${STATE_DIR}/${MIG_PREFIX}-${SITE}-known_hosts"
    mkdir -p "$STATE_DIR"

    local source_port dest_port
    source_port=$(_state_read ".data.source_ssh_port")
    dest_port=$(_state_read ".data.dest_ssh_port")
    [[ -z "$source_port" || "$source_port" == "null" ]] && source_port="22"
    [[ -z "$dest_port" || "$dest_port" == "null" ]] && dest_port="22"

    local ssh_opts
    ssh_opts=( -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known_hosts_file" )

    _loading2 "Testing SSH to source: $ssh_user_source@$source_server_ip"
    local ssh_err
    ssh_err=$(ssh "${ssh_opts[@]}" -p "$source_port" "$ssh_user_source@$source_server_ip" "echo ok" 2>&1 >/dev/null)

    if [[ $? -ne 0 ]]; then
        if echo "$ssh_err" | grep -qi "Bad configuration option"; then
            _debug "SSH client does not support accept-new; retrying with StrictHostKeyChecking=no"
            ssh_opts=( -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="$known_hosts_file" )
            ssh_err=$(ssh "${ssh_opts[@]}" -p "$source_port" "$ssh_user_source@$source_server_ip" "echo ok" 2>&1 >/dev/null)
        fi
    fi

    if [[ $? -ne 0 ]]; then
        _error "SSH failed to source server: $ssh_user_source@$source_server_ip"
        _loading3 "Hint: verify auth with 'ssh -p $source_port $ssh_user_source@$source_server_ip'"
        _debug "SSH error (source): $ssh_err"
        _log "STEP 2.2 FAILED: SSH to source failed"
        return 1
    fi
    [[ -n "$ssh_err" ]] && _debug "SSH stderr (source): $ssh_err"
    _success "SSH OK: source ($source_server_ip)"

    _loading2 "Testing SSH to destination: $ssh_user_dest@$dest_server_ip"
    ssh_err=$(ssh "${ssh_opts[@]}" -p "$dest_port" "$ssh_user_dest@$dest_server_ip" "echo ok" 2>&1 >/dev/null)

    if [[ $? -ne 0 ]]; then
        if echo "$ssh_err" | grep -qi "Bad configuration option"; then
            _debug "SSH client does not support accept-new; retrying with StrictHostKeyChecking=no"
            ssh_opts=( -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="$known_hosts_file" )
            ssh_err=$(ssh "${ssh_opts[@]}" -p "$dest_port" "$ssh_user_dest@$dest_server_ip" "echo ok" 2>&1 >/dev/null)
        fi
    fi

    if [[ $? -ne 0 ]]; then
        _error "SSH failed to destination server: $ssh_user_dest@$dest_server_ip"
        _loading3 "Hint: verify auth with 'ssh -p $dest_port $ssh_user_dest@$dest_server_ip'"
        _debug "SSH error (dest): $ssh_err"
        _log "STEP 2.2 FAILED: SSH to destination failed"
        return 1
    fi
    [[ -n "$ssh_err" ]] && _debug "SSH stderr (dest): $ssh_err"
    _success "SSH OK: destination ($dest_server_ip)"

    _state_write ".data.ssh_user" "$ssh_user_source"
    _state_add_completed_step "2.2"
    _log "STEP 2.2 COMPLETE: SSH connectivity validated"
    echo
    return 0
}

function _ssh_run() {
    local host_ip="$1"
    local remote_cmd="$2"

    # Choose SSH user based on which host we're contacting
    local ssh_user src_user dest_user
    src_user=$(_state_read ".data.source_ssh_user")
    dest_user=$(_state_read ".data.dest_ssh_user")
    [[ -z "$src_user" || "$src_user" == "null" ]] && src_user="${GPBC_SSH_USER:-root}"
    [[ -z "$dest_user" || "$dest_user" == "null" ]] && dest_user="${GPBC_SSH_USER:-root}"

    local known_hosts_file
    known_hosts_file="${STATE_DIR}/${MIG_PREFIX}-${SITE}-known_hosts"
    mkdir -p "$STATE_DIR"

    local ssh_port=""
    local source_ip source_port dest_port dest_ip
    source_ip=$(_state_read ".data.source_server_ip")
    source_port=$(_state_read ".data.source_ssh_port")
    dest_port=$(_state_read ".data.dest_ssh_port")
    dest_ip=$(_state_read ".data.dest_server_ip")

    # Default to source user unless host matches destination IP
    ssh_user="$src_user"
    if [[ -n "$dest_ip" && "$host_ip" == "$dest_ip" ]]; then
        ssh_user="$dest_user"
    fi

    local ssh_opts
    ssh_opts=( -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known_hosts_file" )
    if [[ -n "$source_ip" && -n "$source_port" && "$host_ip" == "$source_ip" ]]; then
        ssh_opts+=( -p "$source_port" )
    elif [[ -n "$dest_port" && "$host_ip" == "$dest_ip" ]]; then
        ssh_opts+=( -p "$dest_port" )
    fi

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

    # Choose SSH user based on which host we're contacting
    local ssh_user src_user dest_user
    src_user=$(_state_read ".data.source_ssh_user")
    dest_user=$(_state_read ".data.dest_ssh_user")
    [[ -z "$src_user" || "$src_user" == "null" ]] && src_user="${GPBC_SSH_USER:-root}"
    [[ -z "$dest_user" || "$dest_user" == "null" ]] && dest_user="${GPBC_SSH_USER:-root}"

    local known_hosts_file
    known_hosts_file="${STATE_DIR}/${MIG_PREFIX}-${SITE}-known_hosts"

    local ssh_port=""
    local source_ip source_port dest_port dest_ip
    source_ip=$(_state_read ".data.source_server_ip")
    source_port=$(_state_read ".data.source_ssh_port")
    dest_port=$(_state_read ".data.dest_ssh_port")
    dest_ip=$(_state_read ".data.dest_server_ip")
    mkdir -p "$STATE_DIR"

    # Default to source user unless host matches destination IP
    ssh_user="$src_user"
    if [[ -n "$dest_ip" && "$host_ip" == "$dest_ip" ]]; then
        ssh_user="$dest_user"
    fi

    local ssh_opts
    ssh_opts=( -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known_hosts_file" )
    if [[ -n "$source_ip" && -n "$source_port" && "$host_ip" == "$source_ip" ]]; then
        ssh_opts+=( -p "$source_port" )
    elif [[ -n "$dest_port" && "$host_ip" == "$dest_ip" ]]; then
        ssh_opts+=( -p "$dest_port" )
    fi

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
    "$PWD/htdocs/wp-config.php" \
    "$PWD/wp-config.php" \
    "$PWD/public_html/wp-config.php" \
    "$PWD/www/wp-config.php" \
    ; do
    if [[ -f "$f" ]]; then
        echo "$f"
        exit 0
    fi
done

# Bounded find fallback under $PWD
found=$(find "$PWD" -maxdepth 5 -type f -name wp-config.php -path "*/${site}/*" 2>/dev/null | head -n1 || true)
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
    echo "Find wp-config.php under PWD=$PWD (top 30):"
    find "$PWD" -maxdepth 6 -type f -name wp-config.php 2>/dev/null | head -n 30 | sed "s/^/  /" || true
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
        _error "Missing server IPs in state. Provide IPs via seed/state before SSH checks."
        _log "STEP 2.2 FAILED: Missing server IPs in state"
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

    local source_site_path dest_htdocs_path dest_site_path

    # GridPane structure: wp-config.php is always in site root, htdocs is site_path/htdocs
    # e.g., /var/www/site/wp-config.php -> site_path=/var/www/site, htdocs=/var/www/site/htdocs
    source_site_path=$(dirname "$source_wp_config")

    dest_site_path=$(dirname "$dest_wp_config")
    dest_htdocs_path="${dest_site_path}/htdocs"

    _success "Source wp-config: $source_wp_config"
    _loading3 "  Source site:   $source_site_path"
    _success "Dest wp-config:   $dest_wp_config"
    _loading3 "  Dest htdocs:   $dest_htdocs_path"
    _loading3 "  Dest site:     $dest_site_path"

    _state_write ".data.source_wp_config_path" "$source_wp_config"
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

get_const() {
    local key="$1" line val sq dq
    line=$(grep -m1 "$key" "$f" 2>/dev/null || true)
    [[ -z "$line" ]] && { echo ""; return; }
    sq=$(printf "%b" "\\047")
    dq=$(printf "%b" "\\042")
    if echo "$line" | grep -q "$sq"; then
        val=$(printf "%s" "$line" | cut -d"$sq" -f4)
    elif echo "$line" | grep -q "$dq"; then
        val=$(printf "%s" "$line" | cut -d"$dq" -f4)
    else
        val=""
    fi
    if [[ "$dbg" == "1" ]]; then
        echo "DBG: $key line=$line" >&2
        echo "DBG: $key val=$val" >&2
    fi
    printf "%s" "$val"
}

db=$(get_const "DB_NAME")
user=$(get_const "DB_USER")
pass=$(get_const "DB_PASSWORD")

# Extract $table_prefix (e.g. $table_prefix = 'wp_';)
# NOTE: This script runs inside: bash -lc '...'
# Avoid embedding literal single quotes here (they would terminate the outer quote).
prefix_line=$(grep -m1 "table_prefix" "$f" 2>/dev/null || true)
prefix=""
if [[ -n "$prefix_line" ]]; then
    sq=$(printf "%b" "\\047")
    dq=$(printf "%b" "\\042")
    if echo "$prefix_line" | grep -q "$sq"; then
        prefix=$(printf "%s" "$prefix_line" | cut -d"$sq" -f2)
    elif echo "$prefix_line" | grep -q "$dq"; then
        prefix=$(printf "%s" "$prefix_line" | cut -d"$dq" -f2)
    fi
fi

# Return as pipe-delimited tuple to avoid newlines
printf "%s|%s|%s|%s" "$db" "$user" "$pass" "$prefix"' --
EOF
)
        cmd="${cmd%$'\n'}"

    local source_db dest_db source_db_user source_db_pass source_table_prefix dest_table_prefix
    local source_tuple dest_tuple

    source_tuple=$(_ssh_capture "$source_server_ip" "$cmd '$source_wp_config' '$DEBUG'")
    IFS='|' read -r source_db source_db_user source_db_pass source_table_prefix <<< "$source_tuple"
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
    IFS='|' read -r dest_db _ _ dest_table_prefix <<< "$dest_tuple"
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
    _state_write ".data.source_db_user" "$source_db_user"
    _state_write ".data.source_db_password" "$source_db_pass"
    _state_write ".data.db_user" "$source_db_user"
    _state_write ".data.db_password" "$source_db_pass"

    # Store WordPress table prefix (used by Step 4 marker checks)
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
    local source_db dest_db source_db_user source_db_pass
    source_db=$(_state_read ".data.source_db_name")
    dest_db=$(_state_read ".data.dest_db_name")
    source_db_user=$(_state_read ".data.source_db_user")
    source_db_pass=$(_state_read ".data.source_db_password")

    if [[ -z "$source_db" || -z "$dest_db" ]]; then
        _error "Missing DB names in state. Run Step 2.3 first."
        _log "STEP 2.4 FAILED: Missing DB names"
        return 1
    fi

    local check_cmd
    check_cmd=$(cat <<'EOF'
bash -lc 'set -euo pipefail
db="$1"
user="${2:-}"
pass="${3:-}"
if ! command -v mysql >/dev/null 2>&1; then
    echo "NO_MYSQL"
    exit 2
fi

# Build query with single quotes without embedding literal single quotes in this script.
sq=$(printf "%b" "\\047")
q="SHOW DATABASES LIKE ${sq}${db}${sq}"
auth=""
if [[ -n "$user" ]]; then
    auth="-u$user"
fi
if [[ -n "$pass" ]]; then
    auth="$auth -p$pass"
fi

mysql $auth -N -e "$q" 2>/dev/null | head -n1' --
EOF
)
    check_cmd="${check_cmd%$'\n'}"

    local out
    _loading2 "Checking source DB exists: $source_db"
    out=$(_ssh_capture "$source_server_ip" "$check_cmd '$source_db' '$source_db_user' '$source_db_pass'")
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
# Requires server IPs in state
# -----------------------------------------------------------------------------
function _step_3_1() {
    _loading "Step 3.1: Verifying rsync on source server"
    _log "STEP 3.1: Verifying rsync on source server"

    local source_server_ip
    source_server_ip=$(_state_read ".data.source_server_ip")

    if [[ -z "$source_server_ip" ]]; then
        _error "Missing source server IP in state. Provide it via seed/state before rsync checks."
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
# Requires server IPs and htdocs path
# -----------------------------------------------------------------------------
function _step_3_2() {
    _loading "Step 3.2: Verifying rsync on destination server"
    _log "STEP 3.2: Verifying rsync on destination server"

    local dest_server_ip dest_htdocs_path
    dest_server_ip=$(_state_read ".data.dest_server_ip")
    dest_htdocs_path=$(_state_read ".data.dest_htdocs_path")

    if [[ -z "$dest_server_ip" ]]; then
        _error "Missing destination server IP in state. Provide it via seed/state before rsync checks."
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
# That requires destination->source SSH auth (uses source SSH user from seed).
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

    local source_server_ip dest_server_ip source_ssh_port source_ssh_user
    source_server_ip=$(_state_read ".data.source_server_ip")
    dest_server_ip=$(_state_read ".data.dest_server_ip")
    source_ssh_port=$(_state_read ".data.source_ssh_port")
    source_ssh_user=$(_state_read ".data.source_ssh_user")
    [[ -z "$source_ssh_port" || "$source_ssh_port" == "null" ]] && source_ssh_port="22"
    [[ -z "$source_ssh_user" || "$source_ssh_user" == "null" ]] && source_ssh_user="${GPBC_SSH_USER:-root}"

    if [[ -z "$source_server_ip" || -z "$dest_server_ip" ]]; then
        _error "Missing server IPs in state. Provide source/dest IPs via seed/state before SSH authorization."
        _log "STEP 3.3 FAILED: Missing server IPs"
        return 1
    fi

    # -------------------------------------------------------------------------
    # 3.3.1 - Test if destination can already SSH to source
    # -------------------------------------------------------------------------
    _loading2 "3.3.1: Testing if destination can SSH to source..."
    local ssh_test_result ssh_test_rc
    ssh_test_result=$(_ssh_capture "$dest_server_ip" "ssh -o ConnectTimeout=5 -o BatchMode=yes -p $source_ssh_port $source_ssh_user@$source_server_ip 'echo ok' 2>&1")
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
        _loading3 "Destination key missing; generating passwordless keypair..."
        local keygen_out keygen_rc
        keygen_out=$(_ssh_capture "$dest_server_ip" "test -f /root/.ssh/id_rsa || ssh-keygen -t rsa -N '' -f /root/.ssh/id_rsa 2>&1")
        keygen_rc=$?
        if [[ $keygen_rc -ne 0 ]]; then
            _error "Failed to generate SSH key on destination: $keygen_out"
            _log "STEP 3.3.2 FAILED: Could not generate destination key"
            return 1
        fi
        dest_pubkey=$(_ssh_capture "$dest_server_ip" "cat /root/.ssh/id_rsa.pub 2>/dev/null")
        dest_pubkey="$(echo "$dest_pubkey" | head -n 1 | tr -d '\r')"
    fi

    _debug "3.3.2: Destination public key: $dest_pubkey"
    _success "Fetched destination public key"

    # -------------------------------------------------------------------------
    # 3.3.3 - Validate source authorized_keys exists
    # -------------------------------------------------------------------------
    # Use the source SSH user's home directory for authorized_keys (not hard-coded /root)
    local source_auth_keys
    source_auth_keys=$(_ssh_capture "$source_server_ip" "echo \$HOME/.ssh/authorized_keys")
    [[ -z "$source_auth_keys" ]] && source_auth_keys="/root/.ssh/authorized_keys"

    _loading2 "3.3.3: Checking if source $source_auth_keys exists..."
    local dbg_ssh_user dbg_ssh_port
    dbg_ssh_user="$source_ssh_user"
    dbg_ssh_port="$source_ssh_port"
    _debug "3.3.3: testing as ${dbg_ssh_user:-root}@$source_server_ip port ${dbg_ssh_port:-22}"

    _ssh_capture "$source_server_ip" "test -f '$source_auth_keys'" >/dev/null 2>&1
    local test_rc=$?

    if [[ $test_rc -ne 0 ]]; then
        # Extra debug: show perms and directory listing when missing
        local ak_debug
        ak_debug=$(_ssh_capture "$source_server_ip" "ls -ld $(dirname '$source_auth_keys') 2>/dev/null; ls -l '$source_auth_keys' 2>/dev/null" 2>/dev/null)
        [[ -n "$ak_debug" ]] && _debug "3.3.3: authorized_keys debug:\n$ak_debug"
        _error "Source $source_auth_keys does not exist"
        _loading3 "Fix: create the file on source (e.g., touch $source_auth_keys && chmod 600 $source_auth_keys)"
        _log "STEP 3.3.3 FAILED: Source authorized_keys does not exist"
        return 1
    fi
    _success "Source authorized_keys exists: $source_auth_keys"

    # -------------------------------------------------------------------------
    # 3.3.4 - Append destination pubkey to source authorized_keys
    # Note: This runs even in dry-run mode (SSH key setup is safe and required)
    # -------------------------------------------------------------------------
    _loading2 "3.3.4: Appending destination key to source authorized_keys..."

    # Check if key already present
    local key_b64
    key_b64=$(printf "%s" "$dest_pubkey" | base64 -w0 2>/dev/null || printf "%s" "$dest_pubkey" | base64 2>/dev/null | tr -d '\n')

    local check_and_append_cmd
    check_and_append_cmd="pubkey=\$(echo '$key_b64' | base64 -d 2>/dev/null || echo '$key_b64' | base64 --decode 2>/dev/null); ak='$source_auth_keys'; if grep -qxF \"\$pubkey\" \"$source_auth_keys\"; then echo ALREADY_PRESENT; else printf '%s\n' \"\$pubkey\" >> \"$source_auth_keys\" && echo ADDED; fi"

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
        _ssh_capture "$dest_server_ip" "ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p $source_ssh_port $source_ssh_user@$source_server_ip 'echo ok' >/dev/null 2>&1 || true" >/dev/null
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

    local source_server_ip dest_server_ip source_site_path dest_htdocs_path source_ssh_port
    source_server_ip=$(_state_read ".data.source_server_ip")
    dest_server_ip=$(_state_read ".data.dest_server_ip")
    source_site_path=$(_state_read ".data.source_site_path")
    dest_htdocs_path=$(_state_read ".data.dest_htdocs_path")
    source_ssh_port=$(_state_read ".data.source_ssh_port")
    [[ -z "$source_ssh_port" || "$source_ssh_port" == "null" ]] && source_ssh_port="22"

    # Extra debug: show how paths were derived from wp-config
    local source_wp_config dest_wp_config source_site_path dest_site_path
    source_wp_config=$(_state_read ".data.source_wp_config_path")
    dest_wp_config=$(_state_read ".data.dest_wp_config_path")
    source_site_path=$(_state_read ".data.source_site_path")
    dest_site_path=$(_state_read ".data.dest_site_path")
    _verbose "Paths pre-normalize (from state):"
    _verbose "  source_wp_config=$source_wp_config"
    _verbose "  source_site_path=$source_site_path"
    _verbose "  dest_wp_config=$dest_wp_config"
    _verbose "  dest_site_path=$dest_site_path"
    _verbose "  dest_htdocs_path=$dest_htdocs_path"

    if [[ -z "$source_server_ip" || -z "$dest_server_ip" ]]; then
        _error "Missing server IPs in state. Provide source/dest IPs via seed/state before file sync."
        _log "STEP 3.4 FAILED: Missing server IPs"
        return 1
    fi

    if [[ -z "$source_site_path" || -z "$dest_htdocs_path" ]]; then
        _error "Missing site paths in state. Run Step 2.5 first."
        _log "STEP 3.4 FAILED: Missing site paths"
        return 1
    fi

    dest_htdocs_path=$(_normalize_htdocs_path "$dest_server_ip" "$dest_htdocs_path" ".data.dest_htdocs_path") || return 1

    _verbose "Paths post-normalize:"
    _verbose "  source_site_path=$source_site_path"
    _verbose "  dest_htdocs_path=$dest_htdocs_path"

    local source_ssh_user dest_ssh_user source_ssh_port dest_ssh_port
    source_ssh_user=$(_state_read ".data.source_ssh_user")
    dest_ssh_user=$(_state_read ".data.dest_ssh_user")
    source_ssh_port=$(_state_read ".data.source_ssh_port")
    dest_ssh_port=$(_state_read ".data.dest_ssh_port")
    [[ -z "$source_ssh_user" || "$source_ssh_user" == "null" ]] && source_ssh_user="${GPBC_SSH_USER:-root}"
    [[ -z "$dest_ssh_user" || "$dest_ssh_user" == "null" ]] && dest_ssh_user="${GPBC_SSH_USER:-root}"
    [[ -z "$source_ssh_port" || "$source_ssh_port" == "null" ]] && source_ssh_port=""
    [[ -z "$dest_ssh_port" || "$dest_ssh_port" == "null" ]] && dest_ssh_port=""

    local known_hosts_file
    known_hosts_file="${STATE_DIR}/${MIG_PREFIX}-${SITE}-known_hosts"

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

    _loading2 "Source: $source_ssh_user@$source_server_ip:$source_site_path/"
    _loading2 "Dest:   $dest_ssh_user@$dest_server_ip:$dest_htdocs_path/"
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
    can_reach=$(_ssh_capture "$dest_server_ip" "ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p $source_ssh_port $source_ssh_user@$source_server_ip 'echo ok' 2>/dev/null || echo 'CANNOT_REACH'")

    if [[ "$can_reach" == "ok" ]]; then
        # Destination can SSH to source - run rsync on destination pulling from source
        _loading2 "Direct rsync: destination will pull from source"
        _log "RSYNC: Direct mode - destination pulling from source"

        local remote_rsync_cmd
        remote_rsync_cmd="rsync $rsync_opts -e 'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p $source_ssh_port' $source_ssh_user@$source_server_ip:$source_site_path/ $dest_htdocs_path/"

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
        tmp_dir=$(mktemp -d -t ${MIG_PREFIX}-rsync-XXXXXX)
        _verbose "Temp directory: $tmp_dir"

        # Step 1: rsync from source to local temp
        _loading2 "Pulling from source to local..."
        local pull_cmd
        pull_cmd="rsync $rsync_opts -e \"$ssh_opts -p $source_ssh_port\" $source_ssh_user@$source_server_ip:$source_site_path/ $tmp_dir/"

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
        push_cmd="rsync $rsync_opts -e \"$ssh_opts\" $tmp_dir/ $dest_ssh_user@$dest_server_ip:$dest_htdocs_path/"

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
# Requires server IPs and DB names
# -----------------------------------------------------------------------------
function _step_4() {
    _loading "Step 4: Migrating database"
    _log "STEP 4: Starting database migration"

    local source_server_ip dest_server_ip source_db dest_db source_db_user source_db_pass
    source_server_ip=$(_state_read ".data.source_server_ip")
    dest_server_ip=$(_state_read ".data.dest_server_ip")
    source_db=$(_state_read ".data.source_db_name")
    dest_db=$(_state_read ".data.dest_db_name")
    source_db_user=$(_state_read ".data.source_db_user")
    source_db_pass=$(_state_read ".data.source_db_password")

    if [[ -z "$source_server_ip" || -z "$dest_server_ip" ]]; then
        _error "Missing server IPs in state. Provide source/dest server_ip via seed/state before database migration."
        _log "STEP 4 FAILED: Missing server IPs"
        return 1
    fi

    if [[ -z "$source_db" || -z "$dest_db" ]]; then
        # Step 2.3 requires Step 2.5 (site paths) first
        local source_site_path dest_site_path
        source_site_path=$(_state_read ".data.source_site_path")
        dest_site_path=$(_state_read ".data.dest_site_path")
        if [[ -z "$source_site_path" || -z "$dest_site_path" ]]; then
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
    known_hosts_file="${STATE_DIR}/${MIG_PREFIX}-${SITE}-known_hosts"

    # Build SSH options arrays for proper argument handling
    local base_ssh_opts_array=(-o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$known_hosts_file")
    local source_ssh_opts_array=("${base_ssh_opts_array[@]}")
    local dest_ssh_opts_array=("${base_ssh_opts_array[@]}")
    [[ -n "$source_ssh_port" ]] && source_ssh_opts_array+=( -p "$source_ssh_port" )
    [[ -n "$dest_ssh_port" ]] && dest_ssh_opts_array+=( -p "$dest_ssh_port" )

    _loading2 "Source DB: $source_db on $source_ssh_user@$source_server_ip"
    _loading2 "Dest DB:   $dest_db on $dest_ssh_user@$dest_server_ip"

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
    
    local source_mysql_auth dest_mysql_auth
    source_mysql_auth=""
    dest_mysql_auth=""
    if [[ -n "$source_db_user" && "$source_db_user" != "null" ]]; then
        source_mysql_auth+=" -u$(printf '%q' "$source_db_user")"
    fi
    if [[ -n "$source_db_pass" && "$source_db_pass" != "null" ]]; then
        source_mysql_auth+=" -p$(printf '%q' "$source_db_pass")"
    fi

    local mysqldump_cmd="mysqldump --single-transaction --quick --lock-tables=false --routines --triggers$source_mysql_auth $safe_source_db"
    local mysql_cmd="mysql $dest_mysql_auth $safe_dest_db"

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
    existing_marker=$(ssh "${dest_ssh_opts_array[@]}" "$dest_ssh_user@$dest_server_ip" "mysql $dest_mysql_auth -N $safe_dest_db -e \"$existing_marker_sql\"" 2>&1)
    existing_marker_rc=$?

    # If the destination wp-config prefix differs from the source, the destination DB might already
    # contain tables under the source prefix (e.g., reruns). Try the source prefix as a fallback.
    if [[ $existing_marker_rc -ne 0 && "$dest_options_table" != "$source_options_table" ]]; then
        existing_marker_sql="SELECT option_value FROM ${source_options_table} WHERE option_name='wp_miggp';"
        existing_marker=$(ssh "${dest_ssh_opts_array[@]}" "$dest_ssh_user@$dest_server_ip" "mysql $dest_mysql_auth -N $safe_dest_db -e \"$existing_marker_sql\"" 2>&1)
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
    marker_output=$(ssh "${source_ssh_opts_array[@]}" "$source_ssh_user@$source_server_ip" "mysql $source_mysql_auth $safe_source_db -e \"$marker_insert_sql\"" 2>&1)
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
            _dry_run_msg "  1. ssh $source_ssh_user@$source_server_ip \"$mysqldump_cmd | gzip > $source_db_path\""
            _dry_run_msg "  2. (transfer) ssh $source_ssh_user@$source_server_ip \"cat $source_db_path\" | ssh $dest_ssh_user@$dest_server_ip \"cat > $dest_db_path\""
            _dry_run_msg "  3. ssh $dest_ssh_user@$dest_server_ip \"gunzip < $dest_db_path | $mysql_cmd\""
            _dry_run_msg "  4. Cleanup temp files on both servers"
            _log "STEP 4 DRY-RUN: Would migrate database via file"
            _state_add_completed_step "4"
            echo
            return 0
        fi
        
        _loading2 "Step 1/4: Dumping database on source and compressing..."
        local dump_output dump_rc
        dump_output=$(ssh "${source_ssh_opts_array[@]}" "$source_ssh_user@$source_server_ip" "$mysqldump_cmd | gzip > $source_db_path" 2>&1)
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
        transfer_output=$(ssh "${source_ssh_opts_array[@]}" "$source_ssh_user@$source_server_ip" "cat $source_db_path" 2>&1 | ssh "${dest_ssh_opts_array[@]}" "$dest_ssh_user@$dest_server_ip" "cat > $dest_db_path" 2>&1)
        transfer_rc=$?
        
        _log "DATABASE TRANSFER OUTPUT: $transfer_output"
        
        if [[ $transfer_rc -ne 0 ]]; then
            _error "Database file transfer failed (exit code: $transfer_rc)"
            [[ -n "$transfer_output" ]] && _error "Output: $transfer_output"
            _log "STEP 4 FAILED: Database transfer error (rc=$transfer_rc)"
            # Cleanup source file
            ssh "${source_ssh_opts_array[@]}" "$source_ssh_user@$source_server_ip" "rm -f $source_db_path" 2>/dev/null || true
            return 1
        fi
        _success "Database file transferred to destination"
        
        _loading2 "Step 3/4: Importing database on destination..."
        local import_output import_rc
        import_output=$(ssh "${dest_ssh_opts_array[@]}" "$dest_ssh_user@$dest_server_ip" "gunzip < $dest_db_path | $mysql_cmd" 2>&1)
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
            ssh "${source_ssh_opts_array[@]}" "$source_ssh_user@$source_server_ip" "rm -f $source_db_path" 2>/dev/null || true
            ssh "${dest_ssh_opts_array[@]}" "$dest_ssh_user@$dest_server_ip" "rm -f $dest_db_path" 2>/dev/null || true
            return 1
        fi
        _success "Database imported successfully"
        
        _loading2 "Step 4/4: Cleaning up temporary files..."
        ssh "${source_ssh_opts_array[@]}" "$source_ssh_user@$source_server_ip" "rm -f $source_db_path" 2>/dev/null || true
        ssh "${dest_ssh_opts_array[@]}" "$dest_ssh_user@$dest_server_ip" "rm -f $dest_db_path" 2>/dev/null || true
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
        
        _verbose "Database migration command (password hidden):"
        _verbose "  ssh ${source_ssh_opts_array[*]} $source_ssh_user@$source_server_ip \"mysqldump ... $safe_source_db\""
        _verbose "  | ssh ${dest_ssh_opts_array[*]} $dest_ssh_user@$dest_server_ip \"$mysql_cmd\""

        if [[ "$DRY_RUN" == "1" ]]; then
            _dry_run_msg "Would execute database migration (auth from source wp-config):"
            _dry_run_msg "  ssh ${source_ssh_opts_array[*]} $source_ssh_user@$source_server_ip \"mysqldump ... $safe_source_db\""
            _dry_run_msg "  | ssh ${dest_ssh_opts_array[*]} $dest_ssh_user@$dest_server_ip \"$mysql_cmd\""
            _log "STEP 4 DRY-RUN: Would migrate database"
            _state_add_completed_step "4"
            echo
            return 0
        fi

        _loading2 "Exporting database from source and importing to destination..."
        _loading3 "This may take several minutes depending on database size..."

        # Execute the database migration with error handling
        # IMPORTANT: Do not merge the *source* ssh stderr into stdout, otherwise ssh errors
        # can be piped into mysql and show up as confusing SQL syntax errors.
        # Also, ensure we fail the step if either side of the pipeline fails.
        local db_output db_rc
        db_output=$(
            (
                set -o pipefail
                ssh "${source_ssh_opts_array[@]}" "$source_ssh_user@$source_server_ip" "$mysqldump_cmd" \
                    | ssh "${dest_ssh_opts_array[@]}" "$dest_ssh_user@$dest_server_ip" "$mysql_cmd"
            ) 2>&1
        )
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
    verify_output=$(ssh "${dest_ssh_opts_array[@]}" "$dest_ssh_user@$dest_server_ip" "mysql -N $safe_dest_db -e \"$verify_sql\"" 2>&1)
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
        _error "Missing source server IP or site path. Ensure source_server_ip and source_site_path exist in state (seed + Step 2.5)."
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
# Step 5 - Migrate Nginx Config (wrapper)
# Calls sub-step 5.1
# -----------------------------------------------------------------------------
function _step_5() {
    _loading "Step 5: Migrate Nginx Config"
    _log "STEP 5: Starting nginx config migration"

    _run_step "5.1" _step_5_1 || return 1

    # If source nginx configs do NOT include XML-RPC disable, enforce it on destination.
    # This aligns with the intention that XML-RPC should be disabled unless explicitly present.
    local special_configs
    special_configs=$(_state_read ".data.nginx_special_configs")
    if [[ ",${special_configs}," != *",disable-xmlrpc-main-context.conf,"* ]]; then
        _loading2 "XML-RPC disable config not found on source; enforcing on destination"

        local dest_server_ip
        dest_server_ip=$(_state_read ".data.dest_server_ip")
        if [[ -z "$dest_server_ip" || "$dest_server_ip" == "null" ]]; then
            _error "Missing destination server IP. Ensure dest_server_ip exists in state (seed + Step 2.2)."
            _log "STEP 5 FAILED: Missing dest_server_ip"
            return 1
        fi

        if [[ "$DRY_RUN" == "1" ]]; then
            _dry_run_msg "Would execute on destination: gp site $SITE -disable-xmlrpc"
        else
            local gp_cmd cmd_output cmd_rc
            gp_cmd="gp site $SITE -disable-xmlrpc"
            cmd_output=$(_ssh_capture "$dest_server_ip" "$gp_cmd" 2>&1)
            cmd_rc=$?
            if [[ $cmd_rc -ne 0 ]]; then
                _error "Failed to disable XML-RPC on destination (exit code: $cmd_rc)"
                [[ -n "$cmd_output" ]] && _error "Output: $cmd_output"
                _log "STEP 5 FAILED: disable-xmlrpc command failed (rc=$cmd_rc)"
                _error_log "Step 5: Failed to run '$gp_cmd' on destination - $cmd_output"
                return 1
            fi
            _success "XML-RPC disabled on destination"
            _log "STEP 5: Successfully disabled XML-RPC on destination"
        fi
    else
        _verbose "Source already includes disable-xmlrpc-main-context.conf; no enforcement needed"
    fi

    _state_add_completed_step "5"
    _log "STEP 5 COMPLETE: Nginx config migration done"
    return 0
}

# -----------------------------------------------------------------------------
# Step 6 - Sync Domain Route (destination gp CLI)
# Uses route captured in Step 1.3 and applies it to destination via:
#   gp site {site.url} -route-domain-www
#   gp site {site.url} -route-domain-root
#   gp site {site.url} -route-domain-off
# -----------------------------------------------------------------------------
function _step_6() {
    _loading "Step 6: Sync Domain Route"
    _log "STEP 6: Starting domain route sync"

    local source_route dest_route
    source_route=$(_state_read ".data.source_route")
    dest_route=$(_state_read ".data.dest_route")

    if [[ -z "$source_route" || "$source_route" == "null" ]]; then
        _warning "Source route not found in state. Run Step 1.3 first or route data not captured."
        _log "STEP 6 WARNING: source_route not in state"
        _state_add_completed_step "6"
        _success "Step 6 complete: Skipped (no route data)"
        echo
        return 0
    fi

    local dest_server_ip
    dest_server_ip=$(_state_read ".data.dest_server_ip")
    if [[ -z "$dest_server_ip" || "$dest_server_ip" == "null" ]]; then
        _error "Missing destination server IP. Ensure dest_server_ip exists in state (seed + Step 2.2)."
        _log "STEP 6 FAILED: Missing dest_server_ip"
        return 1
    fi

    if [[ -n "$dest_route" && "$dest_route" != "null" && "$source_route" == "$dest_route" ]]; then
        _loading2 "Routes already match ($source_route)"
        _log "STEP 6: Routes already match ($source_route), skipping update"
        _state_write ".data.route_updated" "false"
        _state_add_completed_step "6"
        _success "Step 6 complete: Routes already in sync"
        echo
        return 0
    fi

    local gp_cmd
    case "$source_route" in
        www)
            gp_cmd="gp site $SITE -route-domain-www"
            ;;
        root)
            gp_cmd="gp site $SITE -route-domain-root"
            ;;
        none|off)
            gp_cmd="gp site $SITE -route-domain-off"
            ;;
        *)
            _warning "Unknown source_route '$source_route' (expected: none/www/root). Skipping."
            _log "STEP 6 WARNING: Unknown source_route '$source_route'"
            _state_add_completed_step "6"
            _success "Step 6 complete: Skipped (unknown route)"
            echo
            return 0
            ;;
    esac

    _loading2 "Applying source route '$source_route' on destination"
    [[ -n "$dest_route" && "$dest_route" != "null" ]] && _loading3 "Destination currently: $dest_route"

    if [[ "$DRY_RUN" == "1" ]]; then
        _dry_run_msg "Would execute on destination: $gp_cmd"
        _state_add_completed_step "6"
        _success "Step 6 complete (dry-run)"
        echo
        return 0
    fi

    local cmd_output cmd_rc
    cmd_output=$(_ssh_capture "$dest_server_ip" "$gp_cmd" 2>&1)
    cmd_rc=$?
    if [[ $cmd_rc -ne 0 ]]; then
        _error "Failed to update destination route (exit code: $cmd_rc)"
        [[ -n "$cmd_output" ]] && _error "Output: $cmd_output"
        _log "STEP 6 FAILED: route-domain command failed (rc=$cmd_rc)"
        _error_log "Step 6: Failed to run '$gp_cmd' on destination - $cmd_output"
        return 1
    fi

    _state_write ".data.route_updated" "true"
    _state_write ".data.dest_route" "$source_route"
    _state_add_completed_step "6"
    _success "Step 6 complete: Domain routing set to '$source_route'"
    _log "STEP 6 COMPLETE: Domain routing set to '$source_route'"
    echo
    return 0
}

# -----------------------------------------------------------------------------
# Step 7 - Enable SSL on Destination
# Prompts user to confirm DNS has been pointed, then enables SSL via API
# -----------------------------------------------------------------------------
function _step_7() {
    _loading "Step 7: Enable SSL on destination"
    _log "STEP 7: Starting SSL enable"

    local dest_domain_id
    dest_domain_id=$(_state_read ".data.dest_domain_id")

    if [[ -z "$dest_domain_id" || "$dest_domain_id" == "null" || "$dest_domain_id" == "http-derived" || "$dest_domain_id" == "unresolved" ]]; then
        _error "Destination domain ID not resolved (got: '${dest_domain_id:-empty}')."
        _loading3 "Ensure domain cache exists: ./gp-api.sh -p $DEST_PROFILE -c cache-domains"
        _loading3 "Then re-run step 1.3 to resolve: --step 1.3"
        _log "STEP 7 FAILED: dest_domain_id not resolved ($dest_domain_id)"
        return 1
    fi

    # Prompt user to confirm DNS has been updated before enabling SSL
    _loading2 "SSL will be enabled on destination domain_id=$dest_domain_id"
    _loading3 "Before proceeding, ensure DNS for this site points to the destination server."
    _loading3 "SSL provisioning (Let's Encrypt) requires DNS to resolve to the destination."
    echo
    if [[ "$DRY_RUN" != "1" ]]; then
        local dns_confirm
        read -r -p "Has DNS been updated to point to the destination server? [y/N] " dns_confirm
        if [[ "$dns_confirm" != "y" && "$dns_confirm" != "Y" ]]; then
            _warning "DNS not confirmed. Skipping SSL enable."
            _loading3 "Re-run step 7 after updating DNS: --step 7"
            _log "STEP 7 SKIPPED: User indicated DNS not yet updated"
            return 1
        fi
    fi

    _loading2 "Enabling SSL on destination domain_id=$dest_domain_id"

    if [[ "$DRY_RUN" == "1" ]]; then
        _dry_run_msg "Would enable SSL on destination via PUT /domain/$dest_domain_id with {\"ssl\": true}"
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
                _log "STEP 7: Rate limited (429) - Retry ${retry_count}/${max_retries}"
                sleep "$current_delay"
                continue
            else
                _error "Rate limited (429) after ${max_retries} retries."
                _log "STEP 7 FAILED: Rate limited (429) after ${max_retries} retries"
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
        _state_add_completed_step "7"
        _success "Step 7 complete: SSL enable request sent"
        _loading3 "Note: SSL provisioning may take a few minutes to complete"
        _log "STEP 7 COMPLETE: SSL enabled on destination domain_id=$dest_domain_id"
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
        _log "STEP 7 FAILED: API returned HTTP $curl_http_code - $api_output"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Step 8 - Final Steps
# Creates cyber.html for DNS verification, runs gp fix cached and wp cache flush on destination
# -----------------------------------------------------------------------------
function _step_8() {
    _loading "Step 8: Final steps"
    _log "STEP 8: Starting final steps"

    # Get variables from state
    local source_server_ip source_wp_config_path
    local dest_server_ip dest_site_path dest_htdocs_path site_url
    local dest_wp_config_backup_path
    local source_ssh_user dest_ssh_user source_ssh_port dest_ssh_port
    local known_hosts_file
    dest_server_ip=$(_state_read ".data.dest_server_ip")
    source_server_ip=$(_state_read ".data.source_server_ip")
    dest_site_path=$(_state_read ".data.dest_site_path")
    dest_htdocs_path=$(_state_read ".data.dest_htdocs_path")
    site_url=$(_state_read ".site")
    source_wp_config_path=$(_state_read ".data.source_wp_config_path")
    dest_wp_config_backup_path="${dest_site_path}/wp-config.php.backup"

    # Use htdocs path if available, otherwise construct it
    if [[ -z "$dest_htdocs_path" || "$dest_htdocs_path" == "null" ]]; then
        dest_htdocs_path="${dest_site_path}/htdocs"
    fi

    if [[ -z "$dest_server_ip" || "$dest_server_ip" == "null" ]]; then
        _error "Destination server IP not found in state"
        _log "STEP 8 FAILED: dest_server_ip not in state"
        return 1
    fi

    if [[ -z "$source_server_ip" || "$source_server_ip" == "null" ]]; then
        _error "Source server IP not found in state"
        _log "STEP 8 FAILED: source_server_ip not in state"
        return 1
    fi

    if [[ -z "$dest_site_path" || "$dest_site_path" == "null" ]]; then
        _error "Destination site path not found in state. Run Step 2.5 first."
        _log "STEP 8 FAILED: dest_site_path not in state"
        return 1
    fi

    source_ssh_user=$(_state_read ".data.source_ssh_user")
    dest_ssh_user=$(_state_read ".data.dest_ssh_user")
    [[ -z "$source_ssh_user" || "$source_ssh_user" == "null" ]] && source_ssh_user="${GPBC_SSH_USER:-root}"
    [[ -z "$dest_ssh_user" || "$dest_ssh_user" == "null" ]] && dest_ssh_user="${GPBC_SSH_USER:-root}"
    source_ssh_port=$(_state_read ".data.source_ssh_port")
    dest_ssh_port=$(_state_read ".data.dest_ssh_port")

    known_hosts_file="${STATE_DIR}/${MIG_PREFIX}-${SITE}-known_hosts"
    mkdir -p "$STATE_DIR" || true

    # Determine if our local ssh supports StrictHostKeyChecking=accept-new
    local strict_mode="accept-new"
    local strict_test_err
    strict_test_err=$(mktemp)
    ssh -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$known_hosts_file" \
        ${dest_ssh_port:+-p "$dest_ssh_port"} "$dest_ssh_user@$dest_server_ip" "echo ok" 2>"$strict_test_err" >/dev/null || true
    if grep -qi "Bad configuration option" "$strict_test_err"; then
        strict_mode="no"
    fi
    rm -f "$strict_test_err" || true

    local ssh_opts=(-o ConnectTimeout=8 -o BatchMode=yes -o "StrictHostKeyChecking=$strict_mode" -o "UserKnownHostsFile=$known_hosts_file")

    local dest_system_user_name
    dest_system_user_name=$(_state_read ".data.dest_system_user_name")

    if [[ "$DRY_RUN" == "1" ]]; then
        if [[ -n "$source_wp_config_path" && "$source_wp_config_path" != "null" ]]; then
            _dry_run_msg "Would copy source wp-config.php to destination: $dest_wp_config_backup_path"
        else
            _dry_run_msg "Would copy source wp-config.php to destination as: $dest_wp_config_backup_path (source path not in state; run Step 2.5)"
        fi
        _dry_run_msg "Would create cyber.html with content 'vm7' in $dest_htdocs_path"
        _dry_run_msg "Would chown cyber.html to match site ownership"
        _dry_run_msg "Would run: gp fix cached $site_url"
        _dry_run_msg "Would run: wp cache flush"
        _state_add_completed_step "8"
        _success "Step 8 complete (dry-run)"
        return 0
    fi

    # Step 8.0: Backup source wp-config.php to destination
    if [[ -z "$source_wp_config_path" || "$source_wp_config_path" == "null" ]]; then
        _warning "Source wp-config path not found in state. Run Step 2.5 first; skipping wp-config backup."
        _log "STEP 8 WARNING: source_wp_config_path not in state"
    else
        _loading2 "Backing up source wp-config.php to destination as wp-config.php.backup..."

        local exists
        exists=$(_ssh_capture "$source_server_ip" "test -f '$source_wp_config_path' && echo exists || echo missing")
        exists=$(echo "$exists" | tr -d '[:space:]')
        if [[ "$exists" != "exists" ]]; then
            _warning "Source wp-config.php not found at: $source_wp_config_path (skipping backup)"
            _log "STEP 8 WARNING: source wp-config missing at $source_wp_config_path"
        else
            local tmp_err copy_rc copy_err
            tmp_err=$(mktemp)
            (
                set -o pipefail
                ssh "${ssh_opts[@]}" ${source_ssh_port:+-p "$source_ssh_port"} "$source_ssh_user@$source_server_ip" "cat '$source_wp_config_path'" 2>>"$tmp_err" \
                    | ssh "${ssh_opts[@]}" ${dest_ssh_port:+-p "$dest_ssh_port"} "$dest_ssh_user@$dest_server_ip" "cat > '$dest_wp_config_backup_path'" 2>>"$tmp_err"
            )
            copy_rc=$?
            copy_err=$(cat "$tmp_err" || true)
            rm -f "$tmp_err" || true

            if [[ $copy_rc -ne 0 ]]; then
                _error "Failed to copy source wp-config.php to destination (exit code: $copy_rc)"
                [[ -n "$copy_err" ]] && _error "SSH error: $copy_err"
                _log "STEP 8 FAILED: wp-config backup copy failed (rc=$copy_rc)"
                _error_log "Step 8: Failed to copy '$source_wp_config_path' to '$dest_wp_config_backup_path' - $copy_err"
                return 1
            fi

            _success "Backed up source wp-config.php to: $dest_wp_config_backup_path"
            _log "STEP 8: Source wp-config.php backed up to destination"
        fi
    fi

    # Step 8.1: Create cyber.html file for DNS propagation verification
    _loading2 "Creating cyber.html in destination htdocs..."
    local cyber_output cyber_rc
    cyber_output=$(ssh "${ssh_opts[@]}" ${dest_ssh_port:+-p "$dest_ssh_port"} "$dest_ssh_user@$dest_server_ip" "set -e; file='$dest_htdocs_path/cyber.html'; echo 'vm7' > \"\$file\"; if [[ -n '$dest_system_user_name' && '$dest_system_user_name' != 'null' && '$dest_system_user_name' != 'UNKNOWN' ]]; then chown '$dest_system_user_name:$dest_system_user_name' \"\$file\"; else owner_group=\$(stat -c '%U:%G' '$dest_htdocs_path' 2>/dev/null || ls -ld '$dest_htdocs_path' | awk '{print \$3":"\$4}'); [[ -n \"\$owner_group\" ]] && chown \"\$owner_group\" \"\$file\" || true; fi; ls -l \"\$file\"" 2>&1)
    cyber_rc=$?
    if [[ $cyber_rc -eq 0 ]]; then
        _verbose "cyber.html created successfully"
        _loading3 "Created: $dest_htdocs_path/cyber.html (content: vm7)"
        _loading3 "Use to verify DNS: curl -s http://$site_url/cyber.html"
    else
        _warning "Failed to create cyber.html: $cyber_output"
        _log "STEP 8 WARNING: cyber.html creation failed - $cyber_output"
    fi

    # Step 8.2: Run gp fix cached
    _loading2 "Running gp fix cached $site_url on destination..."
    local gp_fix_output gp_fix_rc
    gp_fix_output=$(ssh "${ssh_opts[@]}" ${dest_ssh_port:+-p "$dest_ssh_port"} "$dest_ssh_user@$dest_server_ip" "gp fix cached '$site_url' 2>&1")
    gp_fix_rc=$?
    if [[ $gp_fix_rc -eq 0 ]]; then
        _verbose "gp fix cached completed successfully"
        _verbose "Output: $gp_fix_output"
    else
        _warning "gp fix cached returned: $gp_fix_rc"
        _verbose "Output: $gp_fix_output"
        _log "STEP 8 WARNING: gp fix cached failed - $gp_fix_output"
    fi

    # Step 8.3: Clear WordPress object cache using wp-cli
    _loading2 "Clearing WordPress object cache on destination..."
    local wp_cache_output wp_cache_rc
    wp_cache_output=$(ssh "${ssh_opts[@]}" ${dest_ssh_port:+-p "$dest_ssh_port"} "$dest_ssh_user@$dest_server_ip" "cd '$dest_htdocs_path' && wp cache flush --allow-root 2>&1" 2>&1)
    wp_cache_rc=$?
    if [[ $wp_cache_rc -eq 0 ]]; then
        _verbose "WordPress cache flushed successfully"
    else
        _warning "WordPress cache flush returned: $wp_cache_rc"
        _verbose "Output: $wp_cache_output"
        _log "STEP 8 WARNING: wp cache flush failed - $wp_cache_output"
    fi

    _state_add_completed_step "8"
    _success "Step 8 complete: Final steps done"
    _log "STEP 8 COMPLETE: cyber.html created, caches cleared"
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
    for state_file in "$STATE_DIR"/${MIG_PREFIX}-*.json; do
        [[ -f "$state_file" ]] || continue
        site_name=$(basename "$state_file" | sed "s/${MIG_PREFIX}-//; s/.json//")
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
    STATE_FILE="${STATE_DIR}/${MIG_PREFIX}-${SITE}.json"
    KNOWN_HOSTS_FILE="${STATE_DIR}/${MIG_PREFIX}-${SITE}-known_hosts"
    
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
    STATE_FILE="${STATE_DIR}/${MIG_PREFIX}-${SITE}.json"
    
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
# Custom migration requires seed data (CSV/JSON); site/dest profile can be inferred/placeholder.
if [[ -z "$DATA_FILE" ]]; then
    _usage
    echo
    _error "Missing required arguments:"
    _error "  --csv <file> or --json <file> is required for custom-source migration"
    exit 1
fi

# If site not provided, infer from first non-comment line of seed file
if [[ -z "$SITE" ]]; then
    SITE=$(grep -v '^[#[:space:]]' "$DATA_FILE" | head -1 | cut -d',' -f1 | tr -d '[:space:]')
    if [[ -z "$SITE" ]]; then
        _usage
        echo
        _error "Could not infer site domain from $DATA_FILE; provide -s <site>"
        exit 1
    fi
    _loading3 "Inferred site from seed: $SITE"
fi

# Destination profile is still needed for GridPane API/ssh context; default if not provided
[[ -z "$DEST_PROFILE" ]] && DEST_PROFILE="file-dest"
# Default source profile label for state/log readability
[[ -z "$SOURCE_PROFILE" ]] && SOURCE_PROFILE="custom-source"

# Sanitize site domain
SITE=$(_sanitize_domain "$SITE")

# Define state and log file paths (must be after SITE is set)
STATE_FILE="${STATE_DIR}/${MIG_PREFIX}-${SITE}.json"
LOG_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/${MIG_PREFIX}-${SITE}-${LOG_TIMESTAMP}.log"
ERROR_LOG_FILE="${LOG_DIR}/${MIG_PREFIX}-${SITE}-${LOG_TIMESTAMP}_error.log"

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

# Print parsed seed details (from state) when using file-based data
function _print_seed_summary() {
    local fmt="$DATA_FORMAT"
    if [[ -z "$fmt" ]]; then
        return
    fi

    local src_ip src_ssh_user dest_id dest_srv_id dest_label dest_ip dest_user dest_ssh_user
    src_ip=$(_state_read ".data.source_server_ip")
    src_ssh_user=$(_state_read ".data.source_ssh_user")
    dest_id=$(_state_read ".data.dest_site_id")
    dest_srv_id=$(_state_read ".data.dest_server_id")
    dest_label=$(_state_read ".data.dest_server_label")
    dest_ip=$(_state_read ".data.dest_server_ip")
    dest_user=$(_state_read ".data.dest_system_user_name")
    dest_ssh_user=$(_state_read ".data.dest_ssh_user")

    _loading2 "Seed ($fmt):"
    _loading3 "  src_ip=$src_ip src_ssh_user=$src_ssh_user"
    _loading3 "  dest_site_id=$dest_id dest_server_id=$dest_srv_id dest_label=$dest_label dest_ip=$dest_ip dest_user=$dest_user dest_ssh_user=$dest_ssh_user"
}

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

# Show seed summary early (before any resume prompt) when using file-based data
if [[ -n "$DATA_FILE" ]]; then
    _print_seed_summary
fi

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
    # Always refresh file-based seed data so newly added columns (e.g., dest_ssh_user) are picked up
    _loading "Step 1: Loading site data from file"
    if ! _load_data_from_file "$SITE"; then
        _error "Migration failed at Step 1 (file data load)"
        _log "Migration FAILED at Step 1 (file data load)"
        exit 1
    fi
else
    # Use API-based validation
    if ! _run_step "1" _step_1; then
        _error "Migration failed at Step 1"
        _log "Migration FAILED at Step 1"
        exit 1
    fi
fi

# Step 1.1: Autodetect missing dest fields from profile cache
if ! _run_step "1.1" _step_1_1; then
    _error "Migration failed at Step 1.1"
    _log "Migration FAILED at Step 1.1"
    exit 1
fi

# Step 1.2: Validate system users
if ! _run_step "1.2" _step_1_2; then
    _error "Migration failed at Step 1.2"
    _log "Migration FAILED at Step 1.2"
    exit 1
fi

# Step 1.3: Get domain routing
if ! _run_step "1.3" _step_1_3; then
    _error "Migration failed at Step 1.3"
    _log "Migration FAILED at Step 1.3"
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

# Step 5: Nginx config check + XML-RPC enforcement
if ! _run_step "5" _step_5; then
    _error "Migration failed at Step 5"
    _log "Migration FAILED at Step 5"
    exit 1
fi

# Step 6: Sync domain routing (destination gp site command)
if ! _run_step "6" _step_6; then
    _error "Migration failed at Step 6"
    _log "Migration FAILED at Step 6"
    exit 1
fi

# Step 7: Enable SSL on Destination
if ! _run_step "7" _step_7; then
    _error "Migration failed at Step 7"
    _log "Migration FAILED at Step 7"
    exit 1
fi

# Step 8: Final Steps (cyber.html, cache flush)
if ! _run_step "8" _step_8; then
    _error "Migration failed at Step 8"
    _log "Migration FAILED at Step 8"
    exit 1
fi

# All steps completed successfully
if [[ -n "$RUN_STEP" ]]; then
    case "$RUN_STEP" in
        1|1.1|1.2|2|2.2|2.3|2.4|2.5|3|3.1|3.2|3.3|3.4|4|5|5.1|6|7|8)
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
