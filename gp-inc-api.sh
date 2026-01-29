#!/bin/bash
# =============================================================================
# -- API Commands
# =============================================================================

# ======================================
# -- gp_api $METOD $ENDPOINT
# ======================================
function gp_api () {
    _debugf "${FUNCNAME[0]} called with METHOD: $1, ENDPOINT: $2, EXTRA: $3"
    local METHOD=$1
    local ENDPOINT=$2
    local EXTRA=$3
    local CURL_HEADERS=()
    local CACHE_FILE

    # -- Check if the GPBC_TOKEN is set
    if [[ -z $GPBC_TOKEN ]]; then
        _gp_select_token
    fi

    _debugf "gp_api called with METHOD: $METHOD, ENDPOINT: $ENDPOINT, EXTRA: $EXTRA"

    [[ $DEBUGF == "1" ]] && set -x
    CURL_HEADERS+=(-H "Authorization: Bearer $GPBC_TOKEN")
    CURL_OUTPUT=$(mktemp)
    CURL_HTTP_CODE="$(curl -s \
    --output "$CURL_OUTPUT" \
    -w "%{http_code}\n" \
    --request "$METHOD" \
    --url "${GP_API_URL}${ENDPOINT}" \
    "${CURL_HEADERS[@]}" \
    "${EXTRA[@]}")"
    CURL_EXIT_CODE="$?"
    [[ $DEBUGF == "1" ]] && set +x
    API_OUTPUT=$(<"$CURL_OUTPUT")
    
    # Debug API response
    _debugf "API Request: $METHOD ${GP_API_URL}${ENDPOINT}"
    _debugf "API HTTP Code: $CURL_HTTP_CODE"
    _debugf "API Curl Exit Code: $CURL_EXIT_CODE"
    _debugf "API Response: $API_OUTPUT"
    
    [[ -z "$API_OUTPUT" ]] && { API_ERROR="No API output"; return 1; }
    #[[ $CURL_EXIT_CODE != 0 ]] && { API_ERROR="CURL exit code: $CURL_EXIT_CODE"; return 1; }
    # Remove new line and everything after it
    CURL_HTTP_CODE=${CURL_HTTP_CODE%%$'\n'*}
    [[ $CURL_HTTP_CODE -ne 200 ]] && { API_ERROR="CURL HTTP code: $CURL_HTTP_CODE Exit Code: $CURL_EXIT_CODE"; return 1; }

    # -- Store in cache
    if [[ $CACHE_ENABLED == "1" ]]; then
        _gp_api_cache_set "$ENDPOINT" "$API_OUTPUT"
    fi
    return 0
}

# ======================================
# -- _gp_test_token
# -- Test the GridPane API token
# ======================================
function _gp_test_token () {
    gp_api GET "/user"
    echo "API Output: $API_OUTPUT"

}

# ======================================
# -- _gp_api_get_api_stats
# -- Get live API statistics (bypasses cache)
# -- Queries /site and /server with per_page=1 to get total counts
# ======================================
function _gp_api_get_api_stats () {
    _debugf "${FUNCNAME[0]} called"
    
    # Ensure a profile is selected
    if [[ -z $GPBC_TOKEN ]]; then
        _gp_select_token
    fi
    
    _loading "Fetching live API statistics for profile: $GPBC_TOKEN_NAME"
    echo
    
    local sites_total=0
    local servers_total=0
    local sites_error=false
    local servers_error=false
    
    # Fetch sites with per_page=1 to get metadata
    _debugf "Fetching sites API with per_page=1"
    gp_api GET "/site?per_page=1"
    if [[ $? -eq 0 ]]; then
        # Try to extract total from response
        # Different API versions may structure this differently
        sites_total=$(echo "$API_OUTPUT" | jq -r '.meta.total // .total // length' 2>/dev/null)
        if [[ -z "$sites_total" || "$sites_total" == "null" ]]; then
            sites_total=$(echo "$API_OUTPUT" | jq 'length' 2>/dev/null || echo "0")
        fi
    else
        _debugf "Failed to fetch sites API: $API_ERROR"
        sites_error=true
        sites_total="ERROR"
    fi
    
    # Fetch servers with per_page=1 to get metadata
    _debugf "Fetching servers API with per_page=1"
    gp_api GET "/server?per_page=1"
    if [[ $? -eq 0 ]]; then
        # Try to extract total from response
        servers_total=$(echo "$API_OUTPUT" | jq -r '.meta.total // .total // length' 2>/dev/null)
        if [[ -z "$servers_total" || "$servers_total" == "null" ]]; then
            servers_total=$(echo "$API_OUTPUT" | jq 'length' 2>/dev/null || echo "0")
        fi
    else
        _debugf "Failed to fetch servers API: $API_ERROR"
        servers_error=true
        servers_total="ERROR"
    fi
    
    # Display results in formatted table
    printf "%-20s %-15s %-40s\n" "Resource" "Total Count" "Profile"
    printf "%-20s %-15s %-40s\n" "$(printf '=%.0s' {1..19})" "$(printf '=%.0s' {1..14})" "$(printf '=%.0s' {1..39})"
    
    if [[ "$sites_error" == true ]]; then
        printf "%-20s %-15s %-40s\n" "Sites" "ERROR" "$GPBC_TOKEN_NAME"
        _error "Failed to fetch sites data: $API_ERROR"
    else
        printf "%-20s %-15s %-40s\n" "Sites" "$sites_total" "$GPBC_TOKEN_NAME"
    fi
    
    if [[ "$servers_error" == true ]]; then
        printf "%-20s %-15s %-40s\n" "Servers" "ERROR" "$GPBC_TOKEN_NAME"
        _error "Failed to fetch servers data: $API_ERROR"
    else
        printf "%-20s %-15s %-40s\n" "Servers" "$servers_total" "$GPBC_TOKEN_NAME"
    fi
    
    echo
    
    # Display timestamp
    printf "%-20s %-15s %-40s\n" "$(printf '=%.0s' {1..19})" "$(printf '=%.0s' {1..14})" "$(printf '=%.0s' {1..39})"
    printf "%-60s\n" "Fetched at: $(date '+%Y-%m-%d %H:%M:%S')"
    echo
    
    # Return error if either failed
    if [[ "$sites_error" == true || "$servers_error" == true ]]; then
        _warning "Some API calls failed. Please check your token and network connectivity."
        return 1
    fi
    
    _success "API statistics retrieved successfully"
    return 0
}

# =============================================================================
# -- Cache
# =============================================================================

# ======================================
# -- _gp_api_cache_init
# -- Initialize the API cache in $HOME/.gpbc-cache
# ======================================
function _gp_api_cache_init () {
    # Create the cache directory if it doesn't exist
    mkdir -p "$CACHE_DIR"
}

# ======================================
# -- _gp_api_cache_status $ENDPOINT
# -- Check if the API output is cached for the given endpoint
# -- Returns 0 if cached, 1 if not cached
# ======================================
function _gp_api_cache_status () {
    _debugf "${FUNCNAME[0]} called with ENDPOINT: $1"
    local ENDPOINT=$1
    # -- Check if caching is enabled
    if [[ $CACHE_ENABLED == "1" ]]; then
        _gp_api_cache_init
        _debugf "Caching is enabled"
        # Check if $CACHE_FILE is set
        if [[ -z $CACHE_FILE ]]; then
            _debugf "CACHE_FILE is not set, using default cache file name"
            CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_$(echo "$ENDPOINT" | tr -d '/').json"
        fi

        if [[ -f "$CACHE_FILE" ]]; then
            local cache_mtime
            if cache_mtime=$(_file_mtime "$CACHE_FILE"); then
                CACHE_AGE=$(( $(date +%s) - cache_mtime ))
            else
                CACHE_AGE="n/a"
            fi
        else
            CACHE_AGE="n/a"
        fi

        _loading3 "Cache file: $CACHE_FILE Age: $CACHE_AGE"
        if [[ -f "$CACHE_FILE" ]]; then
            _debugf "Cache file exists"
            return 0
        else
            _debugf "Cache file does not exist"
            return 1
        fi
    else
        _debugf "Caching is disabled"
        return 1
    fi
}

# ======================================
# -- _gp_api_cache_get $ENDPOINT
# -- Cache the API output for the given endpoint
# ======================================
function _gp_api_cache_get () {
    # -- Check if caching is enabled
    if [[ $CACHE_ENABLED == "1" ]]; then
        _gp_api_cache_init
        _debugf "Caching is enabled"
        # Check if the cache file exists
        CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_$(echo "$ENDPOINT" | tr -d '/').json"
        _debugf "Cache file: $CACHE_FILE"
        if [[ -f "$CACHE_FILE" ]]; then
            _debugf "Cache file exists, reading from cache"
            API_OUTPUT=$(<"$CACHE_FILE")
            _debugf "API Output from cache: $API_OUTPUT"
            # Check if API_OUTPUT is empty
            if [[ -z "$API_OUTPUT" ]]; then
                _debugf "Cache file is empty, fetching from API"
                return 1
            else
                _debugf "Cache file is not empty"
                # Check if the cache is older than 1 hour
                local cache_mtime
                if cache_mtime=$(_file_mtime "$CACHE_FILE"); then
                    CACHE_AGE=$(( $(date +%s) - cache_mtime ))
                    _debugf "Cache age: $CACHE_AGE seconds"
                else
                    _debugf "Unable to determine cache age for $CACHE_FILE"
                    CACHE_AGE="n/a"
                fi
                if [[ $CACHE_AGE != "n/a" && $CACHE_AGE -lt 3600 ]]; then
                    _debugf "Cache is fresh, using cached data"
                    return 0
                else
                    _debugf "Cache is stale, fetching from API"
                    return 1
                fi
            fi
        else
            _debugf "Cache file does not exist, fetching from API"
            return 1
        fi
    else
        _debugf "Caching is disabled fetching from API"
        return 1
    fi
}

# ======================================
# -- _gp_api_cache_set $ENDPOINT $API_OUTPUT
# -- Set the API output in the cache for the given endpoint
# ======================================
function _gp_api_cache_set () {
    local ENDPOINT=$1
    local API_OUTPUT=$2
    # -- Check if caching is enabled
    if [[ $CACHE_ENABLED == "1" ]]; then
        _gp_api_cache_init
        CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_$(echo "$ENDPOINT" | tr -d '/').json"
        _debugf "Caching is enabled, creating cache file at: $CACHE_FILE"
        echo "$API_OUTPUT" > "$CACHE_FILE"
        _debugf "API output cached successfully"
    else
        _debugf "Caching is disabled, not caching API output"
    fi
}

# ======================================
# -- _gp_api_cache_age $CACHE_FILE
# -- Check the age of the cache file
# -- Returns 0 if cache is fresh, 1 if stale or not found
# ======================================
function _gp_api_cache_age () {
    local CACHE_FILE="$1"
    _debugf "${FUNCNAME[0]} called with CACHE_FILE: $CACHE_FILE"
    # -- Check if caching is enabled
    if [[ $CACHE_ENABLED == "1" ]]; then
        _debugf "Caching is enabled"
        # -- Check if the cache file exists
        if [[ -f "$CACHE_FILE" ]]; then
            _debugf "Cache file exists: $CACHE_FILE"
            # -- Check if the cache file is empty
            if [[ ! -s "$CACHE_FILE" ]]; then
                _debugf "Cache file is empty: $CACHE_FILE"
                return 1
            fi
            # -- Get the age of the cache file
            local cache_mtime
            if cache_mtime=$(_file_mtime "$CACHE_FILE"); then
                CACHE_AGE=$(( $(date +%s) - cache_mtime ))
                _debugf "Cache age: $CACHE_AGE seconds"
            else
                _debugf "Unable to determine cache age for $CACHE_FILE"
                CACHE_AGE="n/a"
            fi
            # -- Check if the cache is older than 1 hour (3600 seconds)
            if [[ $CACHE_AGE != "n/a" && $CACHE_AGE -lt 3600 ]]; then
                _debugf "Cache is fresh, age: $CACHE_AGE seconds"
                return 0
            else
                _debugf "Cache is stale, age: $CACHE_AGE seconds"
                return 1
            fi
        else
            _debugf "Cache file does not exist: $CACHE_FILE"
            return 1
        fi
    else
        _debugf "Caching is disabled"
        return 1
    fi
}

# ======================================
# -- _gp_api_cache_sites
# -- Cache sites from the GridPane API
# -- Fetches sites from the API and caches them in $CACHE_DIR
# -- Uses the endpoint /site with pagination
# ======================================
function _gp_api_cache_sites () {
    _debugf "${FUNCNAME[0]} called"
    _gp_select_token
    
    local ENDPOINT="/site"
    local CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_site.json"
    local PER_PAGE="${GPBC_DEFAULT_PER_PAGE:-100}"
    local LAST_PAGE
    local SAVED_CACHE_ENABLED="$CACHE_ENABLED"
    
    _loading "Fetching all sites from API with pagination"
    
    # Disable caching during pagination to avoid cache overwrite
    CACHE_ENABLED="0"
    
    # Fetch first page to get pagination info
    gp_api GET "$ENDPOINT?per_page=$PER_PAGE"
    local api_result=$?
    
    if [[ $api_result -ne 0 ]]; then
        CACHE_ENABLED="$SAVED_CACHE_ENABLED"
        _error "Failed to fetch sites from API: $API_ERROR"
        return 1
    fi
    
    # Extract pagination metadata
    LAST_PAGE=$(echo "$API_OUTPUT" | jq -r '.meta.last_page // "1"')
    TOTAL_ITEMS=$(echo "$API_OUTPUT" | jq -r '.meta.total // "0"')
    _debugf "Total sites: $TOTAL_ITEMS, Last page: $LAST_PAGE"
    
    if [[ $LAST_PAGE -le 1 ]]; then
        # Single page - extract data array and save
        echo "$API_OUTPUT" | jq '.data' > "$CACHE_FILE"
        CACHE_ENABLED="$SAVED_CACHE_ENABLED"
        _success "Successfully cached $TOTAL_ITEMS sites"
        return 0
    fi
    
    # Multiple pages - fetch all and combine
    local TMP_DIR
    TMP_DIR=$(mktemp -d)
    echo "$API_OUTPUT" > "$TMP_DIR/page1.json"
    
    # Fetch all other pages
    for p in $(seq 2 "$LAST_PAGE"); do
        _loading2 "Fetching page $p of $LAST_PAGE..."
        _debugf "Fetching page $p of $LAST_PAGE"
        gp_api GET "$ENDPOINT?page=$p&per_page=$PER_PAGE"
        local page_result=$?
        
        if [[ $page_result -ne 0 ]]; then
            CACHE_ENABLED="$SAVED_CACHE_ENABLED"
            _error "Failed to fetch page $p: $API_ERROR"
            rm -rf "$TMP_DIR"
            return 1
        fi
        echo "$API_OUTPUT" > "$TMP_DIR/page${p}.json"
    done
    
    # Combine all .data[] arrays into one flat array
    jq -s '[ .[] | .data[] ]' "$TMP_DIR"/page*.json > "$CACHE_FILE"
    rm -rf "$TMP_DIR"
    
    # Re-enable caching
    CACHE_ENABLED="$SAVED_CACHE_ENABLED"
    
    _success "Successfully cached $TOTAL_ITEMS sites"
    return 0
}

# =======================================
# -- _gp_api_cache_servers
# -- Cache servers from the GridPane API
# -- Fetches servers from the API and caches them in $CACHE_DIR
# -- Uses the endpoint /server with pagination
# =======================================
function _gp_api_cache_servers () {
    _debugf "${FUNCNAME[0]} called"
    _gp_select_token
    
    local ENDPOINT="/server"
    local CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_server.json"
    local PER_PAGE="${GPBC_DEFAULT_PER_PAGE:-100}"
    local LAST_PAGE
    local SAVED_CACHE_ENABLED="$CACHE_ENABLED"
    
    _loading "Fetching all servers from API with pagination"
    
    # Disable caching during pagination to avoid cache overwrite
    CACHE_ENABLED="0"
    
    # Fetch first page to get pagination info
    gp_api GET "$ENDPOINT?per_page=$PER_PAGE"
    local api_result=$?
    
    if [[ $api_result -ne 0 ]]; then
        CACHE_ENABLED="$SAVED_CACHE_ENABLED"
        _error "Failed to fetch servers from API: $API_ERROR"
        return 1
    fi
    
    # Extract pagination metadata
    LAST_PAGE=$(echo "$API_OUTPUT" | jq -r '.meta.last_page // "1"')
    TOTAL_ITEMS=$(echo "$API_OUTPUT" | jq -r '.meta.total // "0"')
    _debugf "Total servers: $TOTAL_ITEMS, Last page: $LAST_PAGE"
    
    if [[ $LAST_PAGE -le 1 ]]; then
        # Single page - extract data array and save
        echo "$API_OUTPUT" | jq '.data' > "$CACHE_FILE"
        CACHE_ENABLED="$SAVED_CACHE_ENABLED"
        _success "Successfully cached $TOTAL_ITEMS servers"
        return 0
    fi
    
    # Multiple pages - fetch all and combine
    local TMP_DIR
    TMP_DIR=$(mktemp -d)
    echo "$API_OUTPUT" > "$TMP_DIR/page1.json"
    
    # Fetch all other pages
    for p in $(seq 2 "$LAST_PAGE"); do
        _loading2 "Fetching page $p of $LAST_PAGE..."
        _debugf "Fetching page $p of $LAST_PAGE"
        gp_api GET "$ENDPOINT?page=$p&per_page=$PER_PAGE"
        local page_result=$?
        
        if [[ $page_result -ne 0 ]]; then
            CACHE_ENABLED="$SAVED_CACHE_ENABLED"
            _error "Failed to fetch page $p: $API_ERROR"
            rm -rf "$TMP_DIR"
            return 1
        fi
        echo "$API_OUTPUT" > "$TMP_DIR/page${p}.json"
    done
    
    # Combine all .data[] arrays into one flat array
    jq -s '[ .[] | .data[] ]' "$TMP_DIR"/page*.json > "$CACHE_FILE"
    rm -rf "$TMP_DIR"
    
    # Re-enable caching
    CACHE_ENABLED="$SAVED_CACHE_ENABLED"
    
    _success "Successfully cached $TOTAL_ITEMS servers"
    return 0
}

# ======================================
# -- _gp_api_cache_users
# -- Cache system users from the GridPane API
# -- Fetches users from the API and caches them in $CACHE_DIR
# -- Uses the endpoint /system-user with pagination
# ======================================
function _gp_api_cache_users () {
    _debugf "${FUNCNAME[0]} called"
    _gp_select_token
    
    local ENDPOINT="/system-user"
    local CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_system-user.json"
    local PER_PAGE="${GPBC_DEFAULT_PER_PAGE:-100}"
    local LAST_PAGE
    local SAVED_CACHE_ENABLED="$CACHE_ENABLED"
    
    _loading "Fetching all system users from API with pagination"
    
    # Disable caching during pagination to avoid cache overwrite
    CACHE_ENABLED="0"
    
    # Fetch first page to get pagination info
    gp_api GET "$ENDPOINT?per_page=$PER_PAGE"
    local api_result=$?
    
    if [[ $api_result -ne 0 ]]; then
        CACHE_ENABLED="$SAVED_CACHE_ENABLED"
        _error "Failed to fetch system users from API: $API_ERROR"
        return 1
    fi
    
    # Extract pagination metadata
    LAST_PAGE=$(echo "$API_OUTPUT" | jq -r '.meta.last_page // "1"')
    TOTAL_ITEMS=$(echo "$API_OUTPUT" | jq -r '.meta.total // "0"')
    _debugf "Total system users: $TOTAL_ITEMS, Last page: $LAST_PAGE"
    
    if [[ $LAST_PAGE -le 1 ]]; then
        # Single page - extract data array and save
        echo "$API_OUTPUT" | jq '.data' > "$CACHE_FILE"
        CACHE_ENABLED="$SAVED_CACHE_ENABLED"
        _success "Successfully cached $TOTAL_ITEMS system users"
        return 0
    fi
    
    # Multiple pages - fetch all and combine
    local TMP_DIR
    TMP_DIR=$(mktemp -d)
    echo "$API_OUTPUT" > "$TMP_DIR/page1.json"
    
    # Fetch all other pages
    for p in $(seq 2 "$LAST_PAGE"); do
        _loading2 "Fetching page $p of $LAST_PAGE..."
        _debugf "Fetching page $p of $LAST_PAGE"
        gp_api GET "$ENDPOINT?page=$p&per_page=$PER_PAGE"
        local page_result=$?
        
        if [[ $page_result -ne 0 ]]; then
            CACHE_ENABLED="$SAVED_CACHE_ENABLED"
            _error "Failed to fetch page $p: $API_ERROR"
            rm -rf "$TMP_DIR"
            return 1
        fi
        echo "$API_OUTPUT" > "$TMP_DIR/page${p}.json"
    done
    
    # Combine all .data[] arrays into one flat array
    jq -s '[ .[] | .data[] ]' "$TMP_DIR"/page*.json > "$CACHE_FILE"
    rm -rf "$TMP_DIR"
    
    # Re-enable caching
    CACHE_ENABLED="$SAVED_CACHE_ENABLED"
    
    _success "Successfully cached $TOTAL_ITEMS system users"
    return 0
}

# ======================================
# -- _gp_api_get_users
# -- Get all system users from cache
# -- Returns the full user array
# ======================================
function _gp_api_get_users () {
    _debugf "${FUNCNAME[0]} called"
    _gp_select_token
    
    local CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_system-user.json"
    
    if [[ ! -f "$CACHE_FILE" ]]; then
        _error "System users cache not found. Run 'cache-users' first."
        return 1
    fi
    
    cat "$CACHE_FILE"
    return 0
}

# ======================================
# -- _gp_api_get_user $SEARCH_TERM
# -- Get a specific system user by ID or username
# -- Returns the user object as JSON
# ======================================
function _gp_api_get_user () {
    local SEARCH_TERM="$1"
    _debugf "${FUNCNAME[0]} called with SEARCH_TERM: $SEARCH_TERM"
    _gp_select_token
    
    if [[ -z "$SEARCH_TERM" ]]; then
        _error "User ID or username is required"
        return 1
    fi
    
    local CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_system-user.json"
    
    if [[ ! -f "$CACHE_FILE" ]]; then
        _error "System users cache not found. Run 'cache-users' first."
        return 1
    fi
    
    # Try to match by ID first (numeric), then by username
    local result
    result=$(jq --arg search "$SEARCH_TERM" '.[] | select(.id == ($search | tonumber)? or .username == $search)' "$CACHE_FILE" 2>/dev/null)
    
    if [[ -z "$result" ]]; then
        _error "System user not found: $SEARCH_TERM"
        return 1
    fi
    
    echo "$result"
    return 0
}

# =============================================================================
# -- Domains
# =============================================================================

# ======================================
# -- _gp_api_cache_domains
# -- Cache domains from the GridPane API
# -- Fetches domains from the API and caches them in $CACHE_DIR
# -- Uses the endpoint /domain with pagination
# ======================================
function _gp_api_cache_domains () {
    _debugf "${FUNCNAME[0]} called"
    _gp_select_token
    
    local ENDPOINT="/domain"
    local CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_domain.json"
    local PER_PAGE=300  # Domains use higher limit due to larger dataset
    local LAST_PAGE
    local SAVED_CACHE_ENABLED="$CACHE_ENABLED"
    
    _loading "Fetching all domains from API with pagination"
    
    # Disable caching during pagination to avoid cache overwrite
    CACHE_ENABLED="0"
    
    # Fetch first page to get pagination info
    gp_api GET "$ENDPOINT?per_page=$PER_PAGE"
    local api_result=$?
    
    if [[ $api_result -ne 0 ]]; then
        CACHE_ENABLED="$SAVED_CACHE_ENABLED"
        _error "Failed to fetch domains from API: $API_ERROR"
        return 1
    fi
    
    # Extract pagination metadata
    LAST_PAGE=$(echo "$API_OUTPUT" | jq -r '.meta.last_page // "1"')
    TOTAL_ITEMS=$(echo "$API_OUTPUT" | jq -r '.meta.total // "0"')
    _debugf "Total domains: $TOTAL_ITEMS, Last page: $LAST_PAGE"
    
    if [[ $LAST_PAGE -le 1 ]]; then
        # Single page - extract data array and save
        echo "$API_OUTPUT" | jq '.data' > "$CACHE_FILE"
        CACHE_ENABLED="$SAVED_CACHE_ENABLED"
        _success "Successfully cached $TOTAL_ITEMS domains"
        return 0
    fi
    
    # Multiple pages - fetch all and combine
    local TMP_DIR
    TMP_DIR=$(mktemp -d)
    echo "$API_OUTPUT" > "$TMP_DIR/page1.json"
    
    # Fetch all other pages
    for p in $(seq 2 "$LAST_PAGE"); do
        _loading2 "Fetching page $p of $LAST_PAGE..."
        _debugf "Fetching page $p of $LAST_PAGE"
        gp_api GET "$ENDPOINT?page=$p&per_page=$PER_PAGE"
        local page_result=$?
        
        if [[ $page_result -ne 0 ]]; then
            CACHE_ENABLED="$SAVED_CACHE_ENABLED"
            _error "Failed to fetch page $p: $API_ERROR"
            rm -rf "$TMP_DIR"
            return 1
        fi
        echo "$API_OUTPUT" > "$TMP_DIR/page${p}.json"
    done
    
    # Combine all .data[] arrays into one flat array
    jq -s '[ .[] | .data[] ]' "$TMP_DIR"/page*.json > "$CACHE_FILE"
    rm -rf "$TMP_DIR"
    
    # Re-enable caching
    CACHE_ENABLED="$SAVED_CACHE_ENABLED"
    
    _success "Successfully cached $TOTAL_ITEMS domains"
    return 0
}

# ======================================
# -- _gp_api_list_domains
# -- List all domains from cache
# -- Returns domain details in formatted table
# ======================================
function _gp_api_list_domains () {
    _debugf "${FUNCNAME[0]} called"
    _gp_select_token
    
    local CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_domain.json"
    
    # Check cache with user options for age and missing cache
    _loading2 "Checking cache for domains data at $CACHE_FILE"
    _check_cache_with_options "$CACHE_FILE" "domains"
    local cache_status=$?
    
    if [[ $cache_status -eq 0 ]]; then
        _debugf "Using cached domains data"
        # Define header function
        _print_domain_header() {
            printf "%-8s %-40s %-8s %-8s %-8s %-10s %-10s %-20s %-15s\n" \
                "ID" "URL" "Route" "SSL" "Wild" "Site ID" "DNS ID" "Integration" "Provider"
            printf "%-8s %-40s %-8s %-8s %-8s %-10s %-10s %-20s %-15s\n" \
                "--------" "----------------------------------------" "--------" "--------" "--------" "----------" "----------" "--------------------" "---------------"
        }
        # Output initial header
        _print_domain_header
        # Handle potential nested array from API and output data
        local line_count=0
        jq -r '
            (if type == "array" and (.[0] | type) == "array" then .[0] else . end) |
            .[] | 
            "\(.id // "N/A")|\(.url // "N/A")|\(.route // "none")|\(.is_ssl // false)|\(.is_wildcard // false)|\(.site_id // "N/A")|\(.dns_management_id // "N/A")|\(.user_dns.integration_name // "N/A")|\(.user_dns.provider.name // "N/A")"
        ' "$CACHE_FILE" | sort -t'|' -k2 | while IFS='|' read -r id url route is_ssl is_wildcard site_id dns_id integration provider; do
            printf "%-8s %-40s %-8s %-8s %-8s %-10s %-10s %-20s %-15s\n" \
                "$id" "$url" "$route" "$is_ssl" "$is_wildcard" "$site_id" "$dns_id" "$integration" "$provider"
            ((line_count++))
            if (( line_count % 10 == 0 )); then
                echo
                _print_domain_header
            fi
        done
        local total_domains
        total_domains=$(jq '(if type == "array" and (.[0] | type) == "array" then .[0] else . end) | length' "$CACHE_FILE")
        _loading3 "Total domains found: $total_domains"
        return 0
    else
        _error "Unable to proceed without domains cache."
        return 1
    fi
}

# ======================================
# -- _gp_api_get_domains
# -- Get all domains from cache
# -- Returns the full domains array as JSON
# ======================================
function _gp_api_get_domains () {
    _debugf "${FUNCNAME[0]} called"
    _gp_select_token
    
    local CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_domain.json"
    
    # Check cache with user options for age and missing cache
    _loading2 "Checking cache for domains data at $CACHE_FILE"
    _check_cache_with_options "$CACHE_FILE" "domains"
    local cache_status=$?
    
    if [[ $cache_status -eq 0 ]]; then
        _debugf "Using cached domains data"
        cat "$CACHE_FILE"
        return 0
    else
        _error "Unable to proceed without domains cache."
        return 1
    fi
}

# ======================================
# -- _gp_api_get_domain $DOMAIN_URL
# -- Get a specific domain by URL
# -- Returns the domain object as JSON
# ======================================
function _gp_api_get_domain () {
    local DOMAIN_URL="$1"
    _debugf "${FUNCNAME[0]} called with DOMAIN_URL: $DOMAIN_URL"
    _gp_select_token
    
    if [[ -z "$DOMAIN_URL" ]]; then
        _error "Domain URL is required"
        return 1
    fi
    
    local CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_domain.json"
    
    # Check cache with user options for age and missing cache
    _check_cache_with_options "$CACHE_FILE" "domains" > /dev/null 2>&1
    local cache_status=$?
    
    if [[ $cache_status -ne 0 ]]; then
        _error "Unable to proceed without domains cache."
        return 1
    fi
    
    # Match by url, domain_url, or name field (handle potential nested array)
    local result
    result=$(jq --arg url "$DOMAIN_URL" '
        (if type == "array" and (.[0] | type) == "array" then .[0] else . end) |
        .[] | select(.url == $url or .domain_url == $url or .name == $url)
    ' "$CACHE_FILE" 2>/dev/null)
    
    if [[ -z "$result" ]]; then
        _error "Domain not found: $DOMAIN_URL"
        return 1
    fi
    
    echo "$result"
    return 0
}

# ======================================
# -- _gp_api_get_domain_formatted $DOMAIN_URL
# -- Get a specific domain by URL with formatted output
# -- Returns human-readable domain details
# ======================================
function _gp_api_get_domain_formatted () {
    local DOMAIN_URL="$1"
    _debugf "${FUNCNAME[0]} called with DOMAIN_URL: $DOMAIN_URL"
    
    local domain_json
    domain_json=$(_gp_api_get_domain "$DOMAIN_URL")
    local result=$?
    
    if [[ $result -ne 0 ]]; then
        return 1
    fi
    
    # Extract fields
    local id url site_id server_id domain_type ssl routing wildcard
    id=$(echo "$domain_json" | jq -r '.id // "N/A"')
    url=$(echo "$domain_json" | jq -r '.url // .domain_url // .name // "N/A"')
    site_id=$(echo "$domain_json" | jq -r '.site_id // "N/A"')
    server_id=$(echo "$domain_json" | jq -r '.server_id // "N/A"')
    domain_type=$(echo "$domain_json" | jq -r '.type // "N/A"')
    ssl=$(echo "$domain_json" | jq -r '.ssl // "N/A"')
    routing=$(echo "$domain_json" | jq -r '.routing // "N/A"')
    wildcard=$(echo "$domain_json" | jq -r '.wildcard // "N/A"')
    
    # Lookup site URL from sites cache
    local site_url="N/A"
    local SITES_CACHE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_site.json"
    if [[ -f "$SITES_CACHE" ]] && [[ "$site_id" != "N/A" ]]; then
        site_url=$(jq -r --arg sid "$site_id" '.[] | select(.id == ($sid | tonumber)) | .url' "$SITES_CACHE" 2>/dev/null)
        [[ -z "$site_url" ]] && site_url="N/A"
    fi
    
    echo "Domain Details:"
    echo "  ID:          $id"
    echo "  URL:         $url"
    echo "  Type:        $domain_type"
    echo "  Site ID:     $site_id"
    echo "  Site URL:    $site_url"
    echo "  Server ID:   $server_id"
    echo "  SSL:         $ssl"
    echo "  Routing:     $routing"
    echo "  Wildcard:    $wildcard"
    
    return 0
}

# ======================================
# -- _gp_api_get_domains_for_site $SITE_ID
# -- Get all domains for a specific site
# -- Returns the domains as JSON array
# ======================================
function _gp_api_get_domains_for_site () {
    local SITE_ID="$1"
    _debugf "${FUNCNAME[0]} called with SITE_ID: $SITE_ID"
    _gp_select_token
    
    if [[ -z "$SITE_ID" ]]; then
        _error "Site ID is required"
        return 1
    fi
    
    local CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_domain.json"
    
    if [[ ! -f "$CACHE_FILE" ]]; then
        _debugf "Domains cache not found"
        echo "[]"
        return 0
    fi
    
    jq --arg sid "$SITE_ID" '
        (if type == "array" and (.[0] | type) == "array" then .[0] else . end) |
        [ .[] | select(.site_id == ($sid | tonumber)) ]
    ' "$CACHE_FILE" 2>/dev/null
    return 0
}

# ======================================
# -- _gp_api_get_primary_domain_for_site $SITE_ID
# -- Get the primary domain for a site
# -- If no primary, returns first alias, or empty
# ======================================
function _gp_api_get_primary_domain_for_site () {
    local SITE_ID="$1"
    _debugf "${FUNCNAME[0]} called with SITE_ID: $SITE_ID"
    _gp_select_token
    
    if [[ -z "$SITE_ID" ]]; then
        return 1
    fi
    
    local CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_domain.json"
    
    if [[ ! -f "$CACHE_FILE" ]]; then
        return 1
    fi
    
    # Try to get primary domain first (handle potential nested array)
    local primary
    primary=$(jq -r --arg sid "$SITE_ID" '
        (if type == "array" and (.[0] | type) == "array" then .[0] else . end) |
        .[] | select(.site_id == ($sid | tonumber) and .type == "primary") | .url // .domain_url // .name
    ' "$CACHE_FILE" 2>/dev/null | head -1)
    
    if [[ -n "$primary" ]]; then
        echo "$primary"
        return 0
    fi
    
    # Fallback to first alias (handle potential nested array)
    local alias_domain
    alias_domain=$(jq -r --arg sid "$SITE_ID" '
        (if type == "array" and (.[0] | type) == "array" then .[0] else . end) |
        .[] | select(.site_id == ($sid | tonumber)) | .url // .domain_url // .name
    ' "$CACHE_FILE" 2>/dev/null | head -1)
    
    if [[ -n "$alias_domain" ]]; then
        echo "$alias_domain"
        return 0
    fi
    
    return 1
}

# ======================================
# -- _gp_api_cache_clear
# -- Clear the API cache
# -- Deletes all cache files in the cache directory
# ======================================
function _gp_api_cache_clear () {
    _debugf "${FUNCNAME[0]} called"
    if [[ -d "$CACHE_DIR" ]]; then
        _debugf "Cache directory exists: $CACHE_DIR"
        # Delete all files in the cache directory
        rm "$CACHE_DIR/*"
        _debugf "Cache cleared successfully"
    else
        _debugf "Cache directory does not exist: $CACHE_DIR"
        _error "Cache directory does not exist: $CACHE_DIR"
        return 1
    fi
    return 0
}

# ======================================
# -- _gp_api_cache_stats
# -- Display cache statistics
# -- Shows count, location, size, and API comparison
# ======================================
function _gp_api_cache_stats () {
    _debugf "${FUNCNAME[0]} called"
    
    if [[ ! -d "$CACHE_DIR" ]]; then
        _error "Cache directory does not exist: $CACHE_DIR"
        return 1
    fi
    
    _loading "Cache Statistics with API Comparison"
    echo
    printf "%-22s %-12s %-12s %-12s %-10s\n" "Cache Type" "Cached" "API Total" "Stale" "Size"
    printf "%-22s %-12s %-12s %-12s %-10s\n" "$(printf '=%.0s' {1..21})" "$(printf '=%.0s' {1..11})" "$(printf '=%.0s' {1..11})" "$(printf '=%.0s' {1..11})" "$(printf '=%.0s' {1..9})"
    
    # Process sites cache files
    local sites_count=0
    local sites_total_size=0
    declare -A api_sites_totals
    
    for profile_sites in "$CACHE_DIR"/*_site.json; do
        if [[ -f "$profile_sites" ]]; then
            local count
            count=$(jq 'length' "$profile_sites" 2>/dev/null || echo "0")
            local size
            size=$(stat -f%z "$profile_sites" 2>/dev/null || stat -c%s "$profile_sites" 2>/dev/null)
            sites_count=$((sites_count + count))
            sites_total_size=$((sites_total_size + size))
            
            local profile_name
            profile_name=$(basename "$profile_sites" "_site.json")
            
            # Query API for this profile
            local api_total="?"
            if _gp_set_profile_silent "$profile_name" 2>/dev/null; then
                # Save current token
                local saved_token="$GPBC_TOKEN"
                local saved_token_name="$GPBC_TOKEN_NAME"
                
                # Query API with per_page=1 to get metadata
                gp_api GET "/site?per_page=1" 2>/dev/null
                if [[ $? -eq 0 ]]; then
                    api_total=$(echo "$API_OUTPUT" | jq -r '.meta.total // .total // length' 2>/dev/null)
                    if [[ -z "$api_total" || "$api_total" == "null" ]]; then
                        api_total=$(echo "$API_OUTPUT" | jq 'length' 2>/dev/null || echo "?")
                    fi
                fi
                
                # Restore token
                GPBC_TOKEN="$saved_token"
                GPBC_TOKEN_NAME="$saved_token_name"
            fi
            
            api_sites_totals[$profile_name]="$api_total"
            local size_human
            size_human=$(_format_bytes "$size")
            
            # Determine if stale
            local stale=""
            if [[ "$api_total" != "?" ]] && [[ "$count" -lt "$api_total" ]]; then
                stale="⚠️ YES"
            fi
            
            printf "%-22s %-12s %-12s %-12s %-10s\n" "Sites ($profile_name)" "$count" "$api_total" "$stale" "$size_human"
        fi
    done
    
    echo
    
    # Process servers cache files
    local servers_count=0
    local servers_total_size=0
    declare -A api_servers_totals
    
    for profile_servers in "$CACHE_DIR"/*_server.json; do
        if [[ -f "$profile_servers" ]]; then
            local count
            count=$(jq 'length' "$profile_servers" 2>/dev/null || echo "0")
            local size
            size=$(stat -f%z "$profile_servers" 2>/dev/null || stat -c%s "$profile_servers" 2>/dev/null)
            servers_count=$((servers_count + count))
            servers_total_size=$((servers_total_size + size))
            
            local profile_name
            profile_name=$(basename "$profile_servers" "_server.json")
            
            # Query API for this profile
            local api_total="?"
            if _gp_set_profile_silent "$profile_name" 2>/dev/null; then
                # Save current token
                local saved_token="$GPBC_TOKEN"
                local saved_token_name="$GPBC_TOKEN_NAME"
                
                # Query API with per_page=1 to get metadata
                gp_api GET "/server?per_page=1" 2>/dev/null
                if [[ $? -eq 0 ]]; then
                    api_total=$(echo "$API_OUTPUT" | jq -r '.meta.total // .total // length' 2>/dev/null)
                    if [[ -z "$api_total" || "$api_total" == "null" ]]; then
                        api_total=$(echo "$API_OUTPUT" | jq 'length' 2>/dev/null || echo "?")
                    fi
                fi
                
                # Restore token
                GPBC_TOKEN="$saved_token"
                GPBC_TOKEN_NAME="$saved_token_name"
            fi
            
            api_servers_totals[$profile_name]="$api_total"
            local size_human
            size_human=$(_format_bytes "$size")
            
            # Determine if stale
            local stale=""
            if [[ "$api_total" != "?" ]] && [[ "$count" -lt "$api_total" ]]; then
                stale="⚠️ YES"
            fi
            
            printf "%-22s %-12s %-12s %-12s %-10s\n" "Servers ($profile_name)" "$count" "$api_total" "$stale" "$size_human"
        fi
    done
    
    echo
    
    # Process domains cache files
    local domains_count=0
    local domains_total_size=0
    declare -A api_domains_totals
    
    for profile_domains in "$CACHE_DIR"/*_domain.json; do
        if [[ -f "$profile_domains" ]]; then
            local count
            count=$(jq 'length' "$profile_domains" 2>/dev/null || echo "0")
            local size
            size=$(stat -f%z "$profile_domains" 2>/dev/null || stat -c%s "$profile_domains" 2>/dev/null)
            domains_count=$((domains_count + count))
            domains_total_size=$((domains_total_size + size))
            
            local profile_name
            profile_name=$(basename "$profile_domains" "_domain.json")
            
            # Query API for this profile
            local api_total="?"
            if _gp_set_profile_silent "$profile_name" 2>/dev/null; then
                # Save current token
                local saved_token="$GPBC_TOKEN"
                local saved_token_name="$GPBC_TOKEN_NAME"
                
                # Query API with per_page=1 to get metadata
                gp_api GET "/domain?per_page=1" 2>/dev/null
                if [[ $? -eq 0 ]]; then
                    api_total=$(echo "$API_OUTPUT" | jq -r '.meta.total // .total // length' 2>/dev/null)
                    if [[ -z "$api_total" || "$api_total" == "null" ]]; then
                        api_total=$(echo "$API_OUTPUT" | jq 'length' 2>/dev/null || echo "?")
                    fi
                fi
                
                # Restore token
                GPBC_TOKEN="$saved_token"
                GPBC_TOKEN_NAME="$saved_token_name"
            fi
            
            api_domains_totals[$profile_name]="$api_total"
            local size_human
            size_human=$(_format_bytes "$size")
            
            # Determine if stale
            local stale=""
            if [[ "$api_total" != "?" ]] && [[ "$count" -lt "$api_total" ]]; then
                stale="⚠️ YES"
            fi
            
            printf "%-22s %-12s %-12s %-12s %-10s\n" "Domains ($profile_name)" "$count" "$api_total" "$stale" "$size_human"
        fi
    done
    
    echo
    printf "%-22s %-12s %-12s %-12s %-10s\n" "$(printf '=%.0s' {1..21})" "$(printf '=%.0s' {1..11})" "$(printf '=%.0s' {1..11})" "$(printf '=%.0s' {1..11})" "$(printf '=%.0s' {1..9})"
    
    local total_items=$((sites_count + servers_count + domains_count))
    local total_size=$((sites_total_size + servers_total_size + domains_total_size))
    local total_size_human
    total_size_human=$(_format_bytes "$total_size")
    printf "%-22s %-12s %-12s %-12s %-10s\n" "TOTAL" "$total_items" "-" "-" "$total_size_human"
    echo
    printf "Legend: ⚠️ YES = Cache has fewer items than API (cache is stale and should be refreshed)\n"
    echo
    _success "Cache statistics retrieved successfully"
    return 0
}

# Helper function to format bytes to human-readable size
_format_bytes () {
    local bytes=$1
    if [[ $bytes -lt 1024 ]]; then
        echo "${bytes}B"
    elif [[ $bytes -lt 1048576 ]]; then
        echo "$((bytes / 1024))KB"
    else
        echo "$((bytes / 1048576))MB"
    fi
}

# ======================================
# -- _gp_api_cache_status_compare
# -- Compare cache stats with live API stats
# -- Shows which caches are stale/incomplete
# ======================================
function _gp_api_cache_status_compare () {
    _debugf "${FUNCNAME[0]} called"
    
    if [[ ! -d "$CACHE_DIR" ]]; then
        _error "Cache directory does not exist: $CACHE_DIR"
        return 1
    fi
    
    _loading "Comparing cache status with live API statistics"
    echo
    
    # Get list of all unique profile names from cache files
    local profiles=()
    for cache_file in "$CACHE_DIR"/*_site.json "$CACHE_DIR"/*_server.json; do
        if [[ -f "$cache_file" ]]; then
            local profile
            profile=$(basename "$cache_file" | sed 's/_site\.json$//' | sed 's/_server\.json$//')
            # Add to array if not already present
            if [[ ! " ${profiles[@]} " =~ " ${profile} " ]]; then
                profiles+=("$profile")
            fi
        fi
    done
    
    # Display header
    printf "%-25s %-15s %-15s %-15s %-20s\n" "Profile" "Cache Sites" "API Sites" "Difference" "Status"
    printf "%-25s %-15s %-15s %-15s %-20s\n" "$(printf '=%.0s' {1..24})" "$(printf '=%.0s' {1..14})" "$(printf '=%.0s' {1..14})" "$(printf '=%.0s' {1..14})" "$(printf '=%.0s' {1..19})"
    
    # Compare each profile
    for profile in "${profiles[@]}"; do
        local cache_sites=0
        local cache_servers=0
        local api_sites=0
        local api_servers=0
        
        # Get cached sites count
        local sites_cache_file="$CACHE_DIR/${profile}_site.json"
        if [[ -f "$sites_cache_file" ]]; then
            cache_sites=$(jq 'length' "$sites_cache_file" 2>/dev/null || echo "0")
        fi
        
        # Get cached servers count
        local servers_cache_file="$CACHE_DIR/${profile}_server.json"
        if [[ -f "$servers_cache_file" ]]; then
            cache_servers=$(jq 'length' "$servers_cache_file" 2>/dev/null || echo "0")
        fi
        
        # Query API for this profile
        _debugf "Querying API for profile: $profile"
        local saved_token="$GPBC_TOKEN"
        local saved_token_name="$GPBC_TOKEN_NAME"
        
        # Set token for this profile
        _gp_set_profile_silent "$profile" 2>/dev/null
        
        # Fetch sites count from API
        gp_api GET "/site?per_page=1" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            api_sites=$(echo "$API_OUTPUT" | jq -r '.meta.total // .total // length' 2>/dev/null)
            if [[ -z "$api_sites" || "$api_sites" == "null" ]]; then
                api_sites=$(echo "$API_OUTPUT" | jq 'length' 2>/dev/null || echo "0")
            fi
        else
            api_sites="ERR"
        fi
        
        # Fetch servers count from API
        gp_api GET "/server?per_page=1" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            api_servers=$(echo "$API_OUTPUT" | jq -r '.meta.total // .total // length' 2>/dev/null)
            if [[ -z "$api_servers" || "$api_servers" == "null" ]]; then
                api_servers=$(echo "$API_OUTPUT" | jq 'length' 2>/dev/null || echo "0")
            fi
        else
            api_servers="ERR"
        fi
        
        # Restore previous token
        GPBC_TOKEN="$saved_token"
        GPBC_TOKEN_NAME="$saved_token_name"
        
        # Calculate differences and determine status
        local sites_diff="N/A"
        local sites_status="✓"
        if [[ "$api_sites" != "ERR" && "$cache_sites" != "0" ]]; then
            sites_diff=$((api_sites - cache_sites))
            if [[ $sites_diff -eq 0 ]]; then
                sites_status="✓ Fresh"
            elif [[ $sites_diff -gt 0 ]]; then
                sites_status="⚠ Stale"
            fi
        fi
        
        # Display results
        printf "%-25s %-15s %-15s %-15s %-20s\n" "$profile" "$cache_sites" "$api_sites" "$sites_diff" "$sites_status"
    done
    
    echo
    _success "Cache status comparison completed"
    echo "Note: Compare 'Cache Sites' and 'API Sites' columns to identify stale caches"
    echo
    return 0
}

# =============================================================================
# -- Servers Commands
# =============================================================================

# =====================================
# -- _gp_api_get_servers
# -- Fetch servers from GridPane API
# ======================================
function _gp_api_get_servers () {
    _debugf "${FUNCNAME[0]} called"
    local ENDPOINT="/server"
    local ENDPOINT_NAME
    ENDPOINT_NAME=$(echo "$ENDPOINT" | tr -d '/')
    local CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_${ENDPOINT_NAME}.json"

    # Check cache with user options for age and missing cache
    _loading2 "Checking cache for ${ENDPOINT_NAME} data at $CACHE_FILE"
    _check_cache_with_options "$CACHE_FILE" "servers"
    local cache_status=$?

    if [[ $cache_status -eq 0 ]]; then
        _debugf "Cache is available, using cached ${ENDPOINT_NAME} data"
        API_OUTPUT=$(<"$CACHE_FILE")
        TOTAL_ITEMS=$(jq 'length' "$CACHE_FILE")
        _loading3 "Total ${ENDPOINT_NAME}: $TOTAL_ITEMS"
        return 0
    else
        _error "Unable to proceed without servers cache."
        return 1
    fi
}

# =====================================
# -- _gp_api_list_servers $EXTENDED
# -- List servers from GridPane API
# ======================================
function _gp_api_list_servers () {
    _debugf "${FUNCNAME[0]} called with EXTENDED: $1"
    local EXTENDED="$1"
    local ENDPOINT="/server"
    local ENDPOINT_NAME
    ENDPOINT_NAME=$(echo "$ENDPOINT" | tr -d '/')
    _gp_select_token
    CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_${ENDPOINT_NAME}.json"

    # Check cache with user options for age and missing cache
    _loading2 "Checking cache for ${ENDPOINT_NAME} data at $CACHE_FILE"
    _check_cache_with_options "$CACHE_FILE" "servers"
    local cache_status=$?

    if [[ $cache_status -eq 0 ]]; then
        _debugf "Using cached ${ENDPOINT_NAME} data"
        # Use jq to filter servers from the cached file
        _debugf "Filtering ${ENDPOINT_NAME} from cache file: $CACHE_FILE"
        if [[ $EXTENDED == "1" ]]; then
            # Extended output with all fields
            DOMAINS=$(jq -r '.[] | "\(.id),\(.label),\(.ip),\(.database),\(.webserver),\(.os_version)"' "$CACHE_FILE")
        else
            # Default output with just label and id
            DOMAINS=$(jq -r '.[] | .label' "$CACHE_FILE" | sort -u)
        fi
        echo "$DOMAINS"
        # Total Servers
        TOTAL_DOMAINS=$(echo "$DOMAINS" | wc -l)
        _loading3 "Total ${ENDPOINT_NAME} found: $TOTAL_DOMAINS"
        return 0
    else
        _error "Unable to proceed without servers cache."
        return 1
    fi
}

# =====================================
# -- _gp_api_list_servers_sites
# -- List servers from GridPane API
# ======================================
function _gp_api_list_servers_sites () {
    _debugf "${FUNCNAME[0]} called"
    _gp_select_token
    local SERVER_CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_server.json"
    local SITE_CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_site.json"

    # Check both cache files with user options for age and missing cache
    _loading2 "Checking server cache at $SERVER_CACHE_FILE"
    _check_cache_with_options "$SERVER_CACHE_FILE" "servers"
    local SERVER_CACHE_FRESH=$?

    _loading2 "Checking site cache at $SITE_CACHE_FILE"
    _check_cache_with_options "$SITE_CACHE_FILE" "sites"
    local SITE_CACHE_FRESH=$?

    if [[ $SERVER_CACHE_FRESH -eq 0 && $SITE_CACHE_FRESH -eq 0 ]]; then
        _loading3 "Using cached data to cross-reference sites with servers"
        # Cross-reference sites with servers to get site IDs
        jq -r --slurpfile sites "$SITE_CACHE_FILE" '
            .[] | .label as $server |
            .sites[]? |
            .url as $site_url |
            ($sites[0][] | select(.url == $site_url) | .id) as $site_id |
            if $site_id then "\($site_id),\($site_url),\($server)"
            else "N/A,\($site_url),\($server)" end
        ' "$SERVER_CACHE_FILE" | sort -u
        return 0
    else
        _error "Unable to proceed without both server and site caches."
        return 1
    fi
}

# =============================================================================
# -- Sites Commands
# =============================================================================

# =====================================
# -- _gp_api_get_sites
# -- Fetch sites from GridPane API
# ======================================
function _gp_api_get_sites () {
    _debugf "${FUNCNAME[0]} called"
    _gp_select_token
    local ENDPOINT="/site"
    local ENDPOINT_NAME
    ENDPOINT_NAME=$(echo "$ENDPOINT" | tr -d '/')
    local CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_site.json"

    # Check cache with user options for age and missing cache
    _loading2 "Checking cache for ${ENDPOINT_NAME} data at $CACHE_FILE"
    _check_cache_with_options "$CACHE_FILE" "sites"
    local cache_status=$?

    if [[ $cache_status -eq 0 ]]; then
        _debugf "Cache is available, using cached ${ENDPOINT_NAME} data"
        API_OUTPUT=$(<"$CACHE_FILE")
        return 0
    else
        _error "Unable to proceed without sites cache."
        return 1
    fi

}

# ======================================
# -- _gp_api_list_sites $EXTENDED
# -- List sites from GridPane API
# ======================================
function _gp_api_list_sites () {
    _debugf "${FUNCNAME[0]} called with EXTENDED: $1"
    local EXTENDED="$1"
    local ENDPOINT="/site"
    local ENDPOINT_NAME
    ENDPOINT_NAME=$(echo "$ENDPOINT" | tr -d '/')
    _gp_select_token
    CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_${ENDPOINT_NAME}.json"
    local DOMAIN_CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_domain.json"

    # Check cache with user options for age and missing cache
    _loading2 "Checking cache for ${ENDPOINT_NAME} data at $CACHE_FILE"
    _check_cache_with_options "$CACHE_FILE" "sites"
    local cache_status=$?

    if [[ $cache_status -eq 0 ]]; then
        _debugf "Using cached ${ENDPOINT_NAME} data"
        # Use jq to filter domains from the cached file
        _debugf "Filtering ${ENDPOINT_NAME} from cache file: $CACHE_FILE"
        if [[ $EXTENDED == "1" ]]; then
            # Extended output with all fields
            echo "id,url,server_id, server_name, is_ssl, php_version, multisites, www, root, remote_bup, local_bup, nginx_caching"
            # Server_name is under server->label
            DOMAINS=$(jq -r '.[] | "\(.id),\(.url),\(.server_id),\(.server.label),\(.is_ssl),\(.php_version),\(.multisites),\(.www),\(.root),\(.remote_bup),\(.local_bup),\(.nginx_caching)"' "$CACHE_FILE" | sort -u)
        else
            # Default output with site URL and primary domain
            # If domain cache exists, show primary domain for each site
            if [[ -f "$DOMAIN_CACHE_FILE" ]]; then
                DOMAINS=$(jq -r --slurpfile domains "$DOMAIN_CACHE_FILE" '
                    .[] | 
                    .id as $site_id | 
                    .url as $site_url |
                    ([$domains[0][] | select(.site_id == $site_id and .type == "primary")] | first | .url // .domain_url // .name) as $primary |
                    ([$domains[0][] | select(.site_id == $site_id)] | first | .url // .domain_url // .name) as $first_domain |
                    if $primary then "\($site_url) → \($primary)"
                    elif $first_domain then "\($site_url) → \($first_domain)"
                    else $site_url end
                ' "$CACHE_FILE" | sort -u)
            else
                DOMAINS=$(jq -r '.[] | .url' "$CACHE_FILE" | sort -u)
            fi
        fi
        echo "$DOMAINS"
        # Total Domains
        TOTAL_DOMAINS=$(echo "$DOMAINS" | wc -l)
        _loading3 "Total ${ENDPOINT_NAME} found: $TOTAL_DOMAINS"
        return 0
    else
        _error "Unable to proceed without sites cache."
        return 1
    fi
}

# =====================================
# -- _gp_api_get_urls
# -- Fetch domains from GridPane API
# ======================================
function _gp_api_get_urls () {
    _gp_select_token
    local CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_site.json"

    # Check cache with user options for age and missing cache
    _loading2 "Checking cache for sites data at $CACHE_FILE"
    _check_cache_with_options "$CACHE_FILE" "sites"
    local cache_status=$?

    if [[ $cache_status -eq 0 ]]; then
        _debugf "Using cached site data"
        # Use jq to filter domains from the cached file
        _debugf "Filtering domains from cache file: $CACHE_FILE"
        DOMAINS=$(jq -r '.[] | .url' "$CACHE_FILE" | sort -u)
        echo "$DOMAINS"
        # Total Domains
        TOTAL_DOMAINS=$(echo "$DOMAINS" | wc -l)
        _loading3 "Total domains found: $TOTAL_DOMAINS"
        return 0
    else
        _error "Unable to proceed without sites cache."
        return 1
    fi
}


# =====================================
# -- _gp_api_get_site $DOMAIN
# -- Fetch sites from GridPane API
# ======================================
function _gp_api_get_site () {
    local DOMAIN="$1"
    _gp_select_token
    local CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_site.json"
    if [[ -z "$DOMAIN" ]]; then
        _error "Error: Domain is required"
        return 1
    fi

    # Check cache with user options for age and missing cache
    _check_cache_with_options "$CACHE_FILE" "sites" > /dev/null 2>&1
    local cache_status=$?

    if [[ $cache_status -eq 0 ]]; then
        _debugf "Using cached site data for domain: $DOMAIN"
        jq --arg domain "$DOMAIN" '.[] | select(.url == $domain)' "$CACHE_FILE" 2>/dev/null
        return 0
    else
        _error "Unable to proceed without sites cache."
        return 1
    fi
}

# =====================================
# -- _gp_api_list_servers_csv
# -- List servers from GridPane API in CSV format (serverid,servername)
# ======================================
function _gp_api_list_servers_csv () {
    _debugf "${FUNCNAME[0]} called"
    local ENDPOINT="/server"
    local ENDPOINT_NAME
    ENDPOINT_NAME=$(echo "$ENDPOINT" | tr -d '/')
    _gp_select_token
    CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_${ENDPOINT_NAME}.json"

    # Check cache with user options for age and missing cache
    _loading2 "Checking cache for ${ENDPOINT_NAME} data at $CACHE_FILE"
    _check_cache_with_options "$CACHE_FILE" "servers"
    local cache_status=$?

    if [[ $cache_status -eq 0 ]]; then
        _debugf "Cache is fresh, using cached ${ENDPOINT_NAME} data"
        # Use jq to filter server id and label from the cached file
        _debugf "Filtering ${ENDPOINT_NAME} from cache file: $CACHE_FILE"
        
        # Output CSV header
        echo "serverid,servername,ip,database,webserver,os_version,status,cpu,ram,region_label"
        
        # Output CSV data with server ID and server name, sorted alphabetically by server name
        # Fields id, label, ip, database, webserver, os_version, status, cpu, ram, region_label
        #jq -r '.[] | "\(.id),\(.label)"' "$CACHE_FILE" | sort -t',' -k2,2
        jq -r '.[] | "\(.id),\(.label),\(.ip),\(.database),\(.webserver),\(.os_version),\(.status),\(.cpu),\(.ram),\(.region_label)"' "$CACHE_FILE" | sort -t',' -k2,2
        
        # Total count
        TOTAL_SERVERS=$(jq 'length' "$CACHE_FILE")
        _loading3 "Total ${ENDPOINT_NAME} found: $TOTAL_SERVERS"
        return 0
    else
        _error "Unable to proceed without servers cache."
        return 1
    fi
}

# =====================================
# -- _gp_api_get_site_formatted $DOMAIN
# -- Get site in formatted output
# ======================================
function _gp_api_get_site_formatted () {
    local DOMAIN="$1"
    _gp_select_token
    local SITE_CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_site.json"
    local SERVER_CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_server.json"
    
    if [[ -z "$DOMAIN" ]]; then
        _error "Error: Domain is required"
        return 1
    fi

    # Check if site cache exists and get user preference on age
    _loading2 "Checking site cache at $SITE_CACHE_FILE"
    _check_cache_with_options "$SITE_CACHE_FILE" "sites"
    local site_cache_status=$?
    
    if [[ $site_cache_status -ne 0 ]]; then
        _error "Unable to proceed without site cache."
        return 1
    fi

    # Get site data - handle multiple sites with same URL
    _debugf "Getting site data for domain: $DOMAIN"
    local sites_data
    sites_data=$(jq --arg domain "$DOMAIN" '[.[] | select(.url == $domain)]' "$SITE_CACHE_FILE" 2>/dev/null)
    _debugf "Sites data for domain $DOMAIN: $sites_data"
    
    if [[ -z "$sites_data" || "$sites_data" == "null" || "$sites_data" == "[]" ]]; then
        _error "Site not found: $DOMAIN"
        return 1
    fi
    
    local sites_count
    sites_count=$(echo "$sites_data" | jq 'length' 2>/dev/null)
    
    if [[ "$sites_count" -eq 0 ]]; then
        _error "Site not found: $DOMAIN"
        return 1
    fi
    
    # Output formatted table header
    printf "%-8s %-40s %-12s %-10s %-20s %-8s %-12s %-15s\n" \
        "ID" "URL" "SSL" "SSL Status" "Server ID" "Server Name" "User ID" "System UID" "Nginx Cache"
    printf "%-8s %-40s %-12s %-10s %-20s %-8s %-12s %-15s\n" \
        "--------" "----------------------------------------" "------------"  "----------" "--------------------" "--------" "------------" "---------------"
    
    # Process each site instance
    for ((i=0; i<sites_count; i++)); do
        local site_data
        site_data=$(echo "$sites_data" | jq ".[$i]" 2>/dev/null)
        _debugf "Processing site data for instance $i: $site_data"

        # Extract site fields for this instance
        local id url ssl_status server_id user_id system_userid nginx_caching

        id=$(echo "$site_data" | jq -r '.id // "N/A"' 2>/dev/null)
        url=$(echo "$site_data" | jq -r '.url // "N/A"' 2>/dev/null)
        is_ssl=$(echo "$site_data" | jq -r '.is_ssl' 2>/dev/null)
        ssl_status=$(echo "$site_data" | jq -r '.ssl_status' 2>/dev/null)
        server_id=$(echo "$site_data" | jq -r '.server_id // "N/A"' 2>/dev/null)
        user_id=$(echo "$site_data" | jq -r '.user_id // "N/A"' 2>/dev/null)
        system_userid=$(echo "$site_data" | jq -r '.system_userid // "N/A"' 2>/dev/null)
        nginx_caching=$(echo "$site_data" | jq -r '.nginx_caching // "N/A"' 2>/dev/null)

        # Get server name from server cache for this instance
        local servername="N/A"
        if [[ "$server_id" != "N/A" && "$server_id" != "null" && -n "$server_id" ]]; then
            servername=$(jq --arg server_id "$server_id" '.[] | select(.id == ($server_id | tonumber)) | .label // "N/A"' "$SERVER_CACHE_FILE" 2>/dev/null | head -n1)
            # Remove quotes if present and handle empty results
            if [[ -n "$servername" && "$servername" != "null" ]]; then
                servername=$(echo "$servername" | tr -d '"')
            else
                servername="N/A"
            fi
        fi

        # Output this site's data
        printf "%-8s %-40s %-12s %-12s %-10s %-20s %-8s %-12s %-15s\n" \
            "$id" "$url" "$is_ssl" "$ssl_status" "$server_id" "$servername" "$user_id" "$system_userid" "$nginx_caching"
        
        # Show domains associated with this site
        local DOMAIN_CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_domain.json"
        if [[ -f "$DOMAIN_CACHE_FILE" ]]; then
            local site_domains
            site_domains=$(jq -r --arg sid "$id" '.[] | select(.site_id == ($sid | tonumber)) | "\(.type): \(.url // .domain_url // .name)"' "$DOMAIN_CACHE_FILE" 2>/dev/null)
            if [[ -n "$site_domains" ]]; then
                echo
                echo "Domains:"
                echo "$site_domains" | while read -r domain_line; do
                    echo "  $domain_line"
                done
            fi
        fi
    done
    
    return 0
}

# =====================================
# -- _gp_api_get_site_live $DOMAIN
# -- Get live site settings from API using cached site ID
# -- Requires site cache to be pre-populated
# ======================================
function _gp_api_get_site_live () {
    local DOMAIN="$1"
    _gp_select_token
    local CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_site.json"
    
    if [[ -z "$DOMAIN" ]]; then
        _error "Error: Domain is required"
        return 1
    fi

    # Check cache exists
    if [[ ! -f "$CACHE_FILE" ]]; then
        _error "Site cache not found. Run: ./gp-api.sh -c cache-sites first"
        return 1
    fi

    # Get site ID from cache
    _debugf "Looking up site ID for domain: $DOMAIN"
    local site_id
    site_id=$(jq --arg domain "$DOMAIN" '.[] | select(.url == $domain) | .id' "$CACHE_FILE" 2>/dev/null | head -1)
    
    if [[ -z "$site_id" || "$site_id" == "null" ]]; then
        _error "Site not found in cache: $DOMAIN"
        return 1
    fi

    _debugf "Found site ID: $site_id for domain: $DOMAIN"
    
    # Fetch live site data from API
    _loading2 "Fetching live site data from API for site ID: $site_id"
    local ENDPOINT="/site/$site_id"
    local RESPONSE
    RESPONSE=$(curl -s -H "Authorization: Bearer $GPBC_TOKEN" "${GP_API_URL}${ENDPOINT}")
    
    if [[ -z "$RESPONSE" ]]; then
        _error "No response from API"
        return 1
    fi

    # Check if response contains an error
    if echo "$RESPONSE" | jq -e '.errors' >/dev/null 2>&1; then
        _error "API Error: $(echo "$RESPONSE" | jq -r '.errors[]')"
        return 1
    fi

    # Extract the site data from the response
    local site_data
    site_data=$(echo "$RESPONSE" | jq '.data // .' 2>/dev/null)
    
    if [[ -z "$site_data" || "$site_data" == "null" ]]; then
        _error "No data returned from API"
        return 1
    fi

    # Output formatted table
    printf "\n%-30s %-45s\n" "Setting" "Value"
    printf "%-30s %-45s\n" "$(printf '=%.0s' {1..29})" "$(printf '=%.0s' {1..44})"
    
    # Display all fields from the API response
    echo "$site_data" | jq -r 'to_entries[] | "\(.key) \(.value)"' | while read -r key value; do
        # Truncate long values
        if [[ ${#value} -gt 45 ]]; then
            value="${value:0:42}..."
        fi
        printf "%-30s %-45s\n" "$key" "$value"
    done
    
    echo
    _success "Live site data retrieved"
    return 0
}

# =====================================
# -- _gp_api_get_site_servers $FILE
# -- Get server names for domains listed in file (one per line)
# ======================================
function _gp_api_get_site_servers () {
    local DOMAIN_FILE="$1"
    _gp_select_token
    local SITE_CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_site.json"
    local SERVER_CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_server.json"
    
    if [[ -z "$DOMAIN_FILE" ]]; then
        _error "Error: Domain file is required"
        return 1
    fi
    
    if [[ ! -f "$DOMAIN_FILE" ]]; then
        _error "Error: Domain file not found: $DOMAIN_FILE"
        return 1
    fi

    # Check if site cache exists and get user preference on age
    _loading2 "Checking site cache at $SITE_CACHE_FILE"
    _check_cache_with_options "$SITE_CACHE_FILE" "sites"
    local site_cache_status=$?
    
    if [[ $site_cache_status -ne 0 ]]; then
        _error "Unable to proceed without site cache."
        return 1
    fi
    
    # Check if server cache exists (optional but helpful for server names)
    _loading2 "Checking server cache at $SERVER_CACHE_FILE"
    if [[ -f "$SERVER_CACHE_FILE" ]]; then
        _check_cache_with_options "$SERVER_CACHE_FILE" "servers"
        local server_cache_status=$?
        if [[ $server_cache_status -ne 0 ]]; then
            _warning "Server cache unavailable. Will show server IDs instead of names."
            SERVER_CACHE_FILE=""
        fi
    else
        _warning "Server cache not found. Will show server IDs instead of names."
        SERVER_CACHE_FILE=""
    fi

    # Process each domain in the file
    _loading3 "Processing domains from file: $DOMAIN_FILE"
    local OUTPUT=""
    OUTPUT+="Domain\tServer(s)\n"
    OUTPUT+="======\t=========\n"

    while IFS= read -r domain || [[ -n "$domain" ]]; do
        # Skip empty lines and comments
        [[ -z "$domain" || "$domain" =~ ^[[:space:]]*# ]] && continue

        # Trim whitespace
        domain=$(echo "$domain" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$domain" ]] && continue

        # Get all sites matching this domain (there could be multiple)
        local sites_data
        sites_data=$(jq --arg domain "$domain" '[.[] | select(.url == $domain)]' "$SITE_CACHE_FILE" 2>/dev/null)

        if [[ -z "$sites_data" || "$sites_data" == "null" || "$sites_data" == "[]" ]]; then
            OUTPUT+="$domain\tNOT_FOUND\n"
            continue
        fi

        # Extract unique server IDs for this domain
        local server_ids
        server_ids=$(echo "$sites_data" | jq -r '.[].server_id' 2>/dev/null | sort -u)

        if [[ -z "$server_ids" || "$server_ids" == "null" ]]; then
            OUTPUT+="$domain\tNO_SERVERS\n"
            continue
        fi

        # Convert server IDs to server names if server cache is available
        local server_names=()
        while IFS= read -r server_id; do
            [[ -z "$server_id" || "$server_id" == "null" ]] && continue

            if [[ -n "$SERVER_CACHE_FILE" && -f "$SERVER_CACHE_FILE" ]]; then
                local server_name
                server_name=$(jq --arg server_id "$server_id" '.[] | select(.id == ($server_id | tonumber)) | .label' "$SERVER_CACHE_FILE" 2>/dev/null | tr -d '"')
                if [[ -n "$server_name" && "$server_name" != "null" ]]; then
                    server_names+=("$server_name")
                else
                    server_names+=("ID:$server_id")
                fi
            else
                server_names+=("ID:$server_id")
            fi
        done <<< "$server_ids"

        # Join server names with commas
        local servers_list
        if [[ ${#server_names[@]} -gt 0 ]]; then
            servers_list=$(IFS=','; echo "${server_names[*]}")
        else
            servers_list="NO_SERVERS"
        fi

        OUTPUT+="$domain\t$servers_list\n"

    done < "$DOMAIN_FILE"

    echo -e "$OUTPUT" | column -t -s $'\t'
    return 0
}

# =============================================================================
# -- System User Commands
# =============================================================================

# ======================================
# -- _gp_api_list_system_users_formatted
# -- List system users in formatted output
# ======================================
function _gp_api_list_system_users_formatted () {
    _debugf "${FUNCNAME[0]} called"
    _gp_select_token
    
    local CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_system-user.json"
    
    if [[ ! -f "$CACHE_FILE" ]]; then
        _error "System users cache not found. Run 'cache-users' first."
        return 1
    fi
    
    # Output formatted table header
    printf "%-6s %-20s %-12s\n" "ID" "USERNAME" "SERVER_ID"
    printf "%-6s %-20s %-12s\n" "------" "--------------------" "------------"
    
    # Output user data in formatted columns
    jq -r '.[] | "\(.id)\t\(.username)\t\(.server_id)"' "$CACHE_FILE" | column -t -s $'\t'
    
    local total
    total=$(jq 'length' "$CACHE_FILE" 2>/dev/null || echo "0")
    _loading3 "Total system users found: $total"
    
    return 0
}

# ======================================
# -- _gp_api_get_system_user_formatted
# -- Get a specific system user in formatted output
# ======================================
function _gp_api_get_system_user_formatted () {
    local SEARCH_TERM="$1"
    _debugf "${FUNCNAME[0]} called with SEARCH_TERM: $SEARCH_TERM"
    
    if [[ -z "$SEARCH_TERM" ]]; then
        _error "User ID or username is required"
        return 1
    fi
    
    # Get user data
    local user_data
    user_data=$(_gp_api_get_user "$SEARCH_TERM")
    
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    # Output formatted table header
    printf "%-15s %-30s\n" "FIELD" "VALUE"
    printf "%-15s %-30s\n" "---------------" "------------------------------"
    
    # Extract and display fields
    local id username server_id ssh_public_key created_at updated_at
    id=$(echo "$user_data" | jq -r '.id // "N/A"' 2>/dev/null)
    username=$(echo "$user_data" | jq -r '.username // "N/A"' 2>/dev/null)
    server_id=$(echo "$user_data" | jq -r '.server_id // "N/A"' 2>/dev/null)
    ssh_public_key=$(echo "$user_data" | jq -r '.ssh_public_key // "N/A"' 2>/dev/null)
    created_at=$(echo "$user_data" | jq -r '.created_at // "N/A"' 2>/dev/null)
    updated_at=$(echo "$user_data" | jq -r '.updated_at // "N/A"' 2>/dev/null)
    
    printf "%-15s %-30s\n" "ID" "$id"
    printf "%-15s %-30s\n" "Username" "$username"
    printf "%-15s %-30s\n" "Server ID" "$server_id"
    printf "%-15s %-30s\n" "SSH Key" "${ssh_public_key:0:27}..."
    printf "%-15s %-30s\n" "Created" "$created_at"
    printf "%-15s %-30s\n" "Updated" "$updated_at"
    
    return 0
}

# =============================================================================
# -- Add Site Commands
# =============================================================================

# ======================================
# -- _gp_api_add_site
# -- Add a site to a server
# ======================================
function _gp_api_add_site () {
    _debugf "${FUNCNAME[0]} called with DOMAIN: $1, SERVER_ID: $2"
    
    # Ensure token is selected
    if [[ -z $GPBC_TOKEN ]]; then
        _gp_select_token
    fi
    
    local DOMAIN=$1
    local SERVER_ID=$2
    local PHP_VERSION=${3:-"8.1"}
    local PM=${4:-"dynamic"}
    local NGINX_CACHING=${5:-"fastcgi"}
    
    # Validate inputs
    if [[ -z "$DOMAIN" ]]; then
        _error "Error: Domain is required"
        return 1
    fi
    
    if [[ -z "$SERVER_ID" ]]; then
        _error "Error: Server ID is required"
        return 1
    fi
    
    # Validate Server ID is numeric
    if ! [[ "$SERVER_ID" =~ ^[0-9]+$ ]]; then
        _error "Error: Server ID must be numeric (got: $SERVER_ID)"
        return 1
    fi
    
    # Validate PHP version
    local VALID_PHP_VERSIONS=("7.2" "7.3" "7.4" "8.0" "8.1" "8.2" "8.3" "8.4")
    if [[ ! " ${VALID_PHP_VERSIONS[@]} " =~ " ${PHP_VERSION} " ]]; then
        _error "Error: Invalid PHP version '$PHP_VERSION'"
        _error "Valid PHP versions: ${VALID_PHP_VERSIONS[*]}"
        return 1
    fi
    
    # Validate PM (Process Manager)
    local VALID_PM_VALUES=("dynamic" "static" "ondemand")
    if [[ ! " ${VALID_PM_VALUES[@]} " =~ " ${PM} " ]]; then
        _error "Error: Invalid PM value '$PM'"
        _error "Valid PM values: ${VALID_PM_VALUES[*]}"
        return 1
    fi
    
    # Prepare the endpoint
    local ENDPOINT="/site"
    
    # Validate and normalize nginx_caching value
    case "$NGINX_CACHING" in
        redis|fastcgi|none)
            # Valid values - keep as is
            ;;
        0|false|disabled)
            NGINX_CACHING="none"
            ;;
        1|true|enabled)
            _error "Error: nginx_caching cannot use '1' for enable. Use 'redis' or 'fastcgi' instead"
            return 1
            ;;
        *)
            _error "Error: Invalid nginx caching value '$NGINX_CACHING'"
            _error "Valid values: redis, fastcgi, or none"
            return 1
            ;;
    esac
    
    # Prepare the JSON payload with all required fields
    local PAYLOAD
    PAYLOAD=$(jq -n \
        --arg domain "$DOMAIN" \
        --arg server_id "$SERVER_ID" \
        --arg php_version "$PHP_VERSION" \
        --arg pm "$PM" \
        --arg nginx_caching "$NGINX_CACHING" \
        '{
            url: $domain,
            server_id: ($server_id | tonumber),
            php_version: $php_version,
            pm: $pm,
            nginx_caching: $nginx_caching
        }')
    
    _loading2 "Adding site '$DOMAIN' to server with ID '$SERVER_ID'"
    _loading3 "Configuration: PHP $PHP_VERSION, PM: $PM, Nginx Caching: $NGINX_CACHING"
    _debugf "Endpoint: $ENDPOINT"
    _debugf "Payload: $PAYLOAD"
    _debugf "Token (masked): $(_mask_token)"
    
    # Make the API call with POST method and JSON data
    CURL_HEADERS=()
    CURL_HEADERS+=(-H "Authorization: Bearer $GPBC_TOKEN")
    CURL_HEADERS+=(-H "Content-Type: application/json")
    
    CURL_OUTPUT=$(mktemp)
    CURL_HTTP_CODE="$(curl -s \
    --output "$CURL_OUTPUT" \
    -w "%{http_code}\n" \
    --request POST \
    --url "${GP_API_URL}${ENDPOINT}" \
    "${CURL_HEADERS[@]}" \
    -d "$PAYLOAD")"
    
    CURL_EXIT_CODE="$?"
    CURL_HTTP_CODE=${CURL_HTTP_CODE%%$'\n'*}
    API_OUTPUT=$(<"$CURL_OUTPUT")
    
    _debugf "HTTP Code: $CURL_HTTP_CODE, Exit Code: $CURL_EXIT_CODE"
    _debugf "API Output: $API_OUTPUT"
    
    # Check for success (HTTP 201 for creation or 200 for success)
    if [[ $CURL_HTTP_CODE -eq 201 || $CURL_HTTP_CODE -eq 200 ]]; then
        _success "Site '$DOMAIN' successfully added to server with ID '$SERVER_ID'"
        echo "$API_OUTPUT" | jq -r '.'
        rm -f "$CURL_OUTPUT"
        return 0
    else
        _error "Failed to add site. HTTP Code: $CURL_HTTP_CODE"
        
        # Parse and display structured errors if present
        if [[ -n "$API_OUTPUT" ]]; then
            local ERRORS
            ERRORS=$(echo "$API_OUTPUT" | jq -r '.errors // empty' 2>/dev/null)
            if [[ -n "$ERRORS" ]]; then
                _error "API Errors:"
                # Parse each error field and display error messages
                echo "$API_OUTPUT" | jq -r '.errors | to_entries[] | .key as $field | .value[] | "  - \($field): \(.)"' 2>/dev/null | while read -r line; do
                    _error "$line"
                done
            else
                # Fallback to raw JSON output if not structured errors
                echo "$API_OUTPUT" | jq -r '.' 2>/dev/null || echo "$API_OUTPUT"
            fi
        fi
        
        _warning "Valid PM values: dynamic, static, ondemand"
        _warning "Valid PHP versions: 7.2, 7.3, 7.4"
        _warning "Valid nginx_caching values: redis, fastcgi, none"
        _warning "Server must be Nginx and must belong to your account"
        
        rm -f "$CURL_OUTPUT"
        return 1
    fi
}

# =====================================
# -- _gp_api_get_server_build_status $SERVER_ID
# -- Get server build status and progress
# ======================================
function _gp_api_get_server_build_status () {
    local SERVER_ID="$1"
    
    if [[ -z "$SERVER_ID" ]]; then
        _error "Error: Server ID is required"
        return 1
    fi
    
    _gp_select_token
    
    local ENDPOINT="/server/build-progress/$SERVER_ID"
    
    _loading2 "Fetching build status for server ID: $SERVER_ID"
    _debugf "Endpoint: $ENDPOINT"
    
    gp_api GET "$ENDPOINT"
    GP_API_RETURN="$?"
    
    if [[ $GP_API_RETURN != 0 ]]; then
        _error "Failed to fetch build status: $API_ERROR"
        return 1
    fi
    
    # Check if response indicates success
    local success
    success=$(echo "$API_OUTPUT" | jq -r '.success // false' 2>/dev/null)
    
    if [[ "$success" != "true" ]]; then
        _error "API returned unsuccessful response"
        _debugf "Response: $API_OUTPUT"
        return 1
    fi
    
    # Extract build status fields
    local server_id_resp build_status build_percentage current_details updated_at
    
    server_id_resp=$(echo "$API_OUTPUT" | jq -r '.server_id // "N/A"' 2>/dev/null)
    build_status=$(echo "$API_OUTPUT" | jq -r '.build_status // "N/A"' 2>/dev/null)
    build_percentage=$(echo "$API_OUTPUT" | jq -r '.build_percentage // "N/A"' 2>/dev/null)
    current_details=$(echo "$API_OUTPUT" | jq -r '.current_details // "N/A"' 2>/dev/null)
    updated_at=$(echo "$API_OUTPUT" | jq -r '.updated_at // "N/A"' 2>/dev/null)
    
    _loading3 "Build status retrieved successfully"
    
    # Output formatted table header
    printf "\n%-20s %-20s\n" "Field" "Value"
    printf "%-20s %-20s\n" "--------------------" "--------------------"
    
    # Output build status information
    printf "%-20s %-20s\n" "Server ID" "$server_id_resp"
    printf "%-20s %-20s\n" "Build Status" "$build_status"
    printf "%-20s %-20s\n" "Build Percentage" "$build_percentage"
    printf "%-20s %-20s\n" "Current Details" "$current_details"
    printf "%-20s %-20s\n" "Updated At" "$updated_at"
    printf "\n"
    
    return 0
}

# ======================================
# -- _gp_csv_add_sites
# ======================================
function _gp_csv_add_sites () {
    # Parameters:
    # $1 = CSV_FILE (required, path to CSV file)
    # $2 = DELAY (optional, seconds between additions, default: 300)
    
    local CSV_FILE="$1"
    local DELAY="${2:-300}"
    local LOG_FILE="/tmp/gp-add-sites-csv-$(date +%Y%m%d_%H%M%S).log"
    local PROGRESS_FILE="${CSV_FILE}.progress"
    local ROW_COUNT=0
    local ADDED_COUNT=0
    local SKIPPED_COUNT=0
    local LINE_NUM=0
    
    # Helper function for timestamped logging
    _log() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    }
    
    _debugf "${FUNCNAME[0]} called with CSV_FILE: $CSV_FILE, DELAY: $DELAY"
    
    # Ensure profile/token is selected
    if [[ -z $GPBC_TOKEN ]]; then
        _gp_select_token
        if [[ -z $GPBC_TOKEN ]]; then
            _error "No profile selected. Cannot proceed with add-site-csv."
            return 1
        fi
    fi
    
    # Check for existing progress file
    if [[ -f "$PROGRESS_FILE" ]]; then
        local PROGRESS_COUNT=$(wc -l < "$PROGRESS_FILE")
        _loading3 "Found progress file: $PROGRESS_FILE ($PROGRESS_COUNT sites already processed)"
        _log "Resuming from progress file: $PROGRESS_FILE ($PROGRESS_COUNT sites already processed)"
    else
        _loading3 "No progress file found, starting fresh"
        _log "No progress file found, starting fresh"
    fi
    
    # Create log file
    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] GridPane Add Sites CSV - Started"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] CSV File: $CSV_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Progress File: $PROGRESS_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Delay: ${DELAY}s"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Log File: $LOG_FILE"
        echo "======================================"
    } > "$LOG_FILE"
    
    # Display log file location to user
    echo >&2
    _loading3 "Logging to: $LOG_FILE"
    _loading3 "Progress file: $PROGRESS_FILE"
    echo >&2
    
    # Read CSV file line by line
    while IFS=',' read -r line; do
        ((LINE_NUM++))
        
        # Skip header row (first line)
        if [[ $LINE_NUM -eq 1 ]]; then
            _log "Header: $line"
            continue
        fi
        
        # Skip empty lines
        if [[ -z "${line// }" ]]; then
            continue
        fi
        
        ((ROW_COUNT++))
        
        # Parse CSV fields with whitespace trimming
        local DOMAIN=$(echo "$line" | cut -d',' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        local SERVER_ID=$(echo "$line" | cut -d',' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        local PHP=$(echo "$line" | cut -d',' -f3 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Validate required fields
        if [[ -z "$DOMAIN" ]] || [[ -z "$SERVER_ID" ]]; then
            local ERROR_MSG="Row $ROW_COUNT: Missing required fields (domain: '$DOMAIN', server_id: '$SERVER_ID')"
            _error "$ERROR_MSG"
            _log "ERROR: $ERROR_MSG"
            _log "CSV Line: $line"
            _log "======================================"
            _log "Processing stopped due to error at row $ROW_COUNT"
            _error "Full log: $LOG_FILE"
            return 1
        fi
        
        # Display progress
        echo >&2
        _loading2 "Processing: $DOMAIN (row $ROW_COUNT)"
        _loading3 "  Parameters: domain=$DOMAIN, server_id=$SERVER_ID, php=$PHP"
        
        # Log the row being processed
        _log "Row $ROW_COUNT: domain=$DOMAIN, server_id=$SERVER_ID, php=$PHP"
        
        # Check progress file first
        if [[ -f "$PROGRESS_FILE" ]] && grep -qx "$DOMAIN" "$PROGRESS_FILE" 2>/dev/null; then
            ((SKIPPED_COUNT++))
            _cache "Skipping $DOMAIN (already in progress file)"
            _log "PROGRESS: Skipping $DOMAIN (already in progress file)"
            continue
        fi
        
        # Check if site already exists using live API
        _cache "Checking if site already exists..."
        _log "CACHE: Checking if site already exists via cache lookup..."
        
        # Use _gp_api_get_site_live which checks cache for ID then validates via API
        local SITE_CHECK
        SITE_CHECK=$(_gp_api_get_site_live "$DOMAIN" 2>&1)
        local SITE_CHECK_RC=$?
        
        if [[ $SITE_CHECK_RC -eq 0 ]]; then
            # Site exists - skip it
            _live "Site already exists (confirmed via API), waiting 5 seconds..."
            _log "LIVE: Site already exists (confirmed via API) - skipping"
            _log "Waiting 5s..."
            sleep 5
            continue
        else
            # Site doesn't exist
            _debugf "Site does not exist (API check failed), proceeding with creation"
            _log "DEBUG: Site does not exist or not in cache - proceeding with creation"
        fi
        
        # Site doesn't exist - proceed with creation
        _loading3 "  Site does not exist, waiting 5 seconds before creating..."
        _log "Site does not exist, proceeding with creation..."
        _log "Waiting 5s before creation..."
        sleep 5
        
        # Show API call details
        _live "Sending API request to GridPane..."
        _log "LIVE: Sending API request: POST /site"
        _log "  domain: $DOMAIN"
        _log "  server_id: $SERVER_ID"
        _log "  php_version: $PHP"
        
        # Call add-site API function with retry logic for rate limiting
        local START_TIME=$(date +%s)
        local RETRY_COUNT=0
        local MAX_RETRIES=3
        local RETRY_DELAY=15
        local ADD_SITE_OUTPUT
        local ADD_SITE_RC
        
        while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
            _live "Waiting for API response..."
            ADD_SITE_OUTPUT=$(_gp_api_add_site "$DOMAIN" "$SERVER_ID" "$PHP" "" "" 2>&1)
            ADD_SITE_RC=$?
            
            # Check for rate limiting (429 or "too fast" message)
            if echo "$ADD_SITE_OUTPUT" | grep -qi "too fast\|429"; then
                ((RETRY_COUNT++))
                local CURRENT_DELAY=$((RETRY_DELAY * RETRY_COUNT))
                
                if [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; then
                    _live "Rate limited! Waiting ${CURRENT_DELAY}s before retry ${RETRY_COUNT}/${MAX_RETRIES}..."
                    _log "LIVE: Rate limited (429) - Retry ${RETRY_COUNT}/${MAX_RETRIES}, waiting ${CURRENT_DELAY}s..."
                    sleep "$CURRENT_DELAY"
                else
                    _error "  Rate limited! Max retries (${MAX_RETRIES}) exceeded."
                    _log "LIVE: Rate limited (429) - Max retries exceeded after ${RETRY_COUNT} attempts"
                fi
            else
                # Not rate limited, break out of retry loop
                break
            fi
        done
        
        local END_TIME=$(date +%s)
        local DURATION=$((END_TIME - START_TIME))
        
        # Log the output (with timestamp prefix for each line)
        echo "$ADD_SITE_OUTPUT" | while IFS= read -r line; do
            _log "$line"
        done
        
        if [[ $ADD_SITE_RC -eq 0 ]]; then
            ((ADDED_COUNT++))
            _success "✓ Successfully added (${DURATION}s)"
            _log "✓ Success - Response received in ${DURATION}s"
            # Save to progress file
            echo "$DOMAIN" >> "$PROGRESS_FILE"
            _log "PROGRESS: Saved $DOMAIN to progress file"
        else
            # Check if error is "already exists" - if so, skip instead of stopping
            if echo "$ADD_SITE_OUTPUT" | grep -qi "already exists"; then
                _cache "Site already exists on server (not in cache), skipping..."
                _log "CACHE: Site already exists on server - skipping"
                # Save to progress file so we don't check again
                echo "$DOMAIN" >> "$PROGRESS_FILE"
                _log "PROGRESS: Saved $DOMAIN to progress file (already exists)"
                _log "Waiting 5s..."
                sleep 5
                continue
            fi
            
            # Check if we exhausted retries due to rate limiting
            if echo "$ADD_SITE_OUTPUT" | grep -qi "too fast\|429"; then
                _log "✗ Error: Rate limit exceeded after ${MAX_RETRIES} retries"
            fi
            
            # Other errors - stop processing
            local ERROR_MSG="Failed to add site $DOMAIN to server $SERVER_ID"
            _error "✗ $ERROR_MSG (${DURATION}s)"
            _log "✗ Error: $ERROR_MSG (${DURATION}s)"
            _log "======================================"
            _log "Processing stopped due to error at row $ROW_COUNT"
            _error "Full log: $LOG_FILE"
            return 1
        fi
        
        # Sleep between additions (except after last row)
        if [[ $ROW_COUNT -lt $(wc -l < "$CSV_FILE") ]]; then
            _loading3 "  Rate limiting: waiting ${DELAY}s before next site..."
            _log "Sleeping ${DELAY}s before next addition..."
            sleep "$DELAY"
        fi
        
    done < "$CSV_FILE"
    
    # Final summary
    _log ""
    _log "======================================"
    _log "Summary: $ADDED_COUNT sites added, $SKIPPED_COUNT skipped (out of $ROW_COUNT rows)"
    _log "Completed"
    
    echo >&2
    _success "✓ Batch job completed!"
    _success "✓ Added: $ADDED_COUNT | Skipped: $SKIPPED_COUNT | Total rows: $ROW_COUNT"
    _loading3 "Log file: $LOG_FILE"
    
    # Clean up progress file on successful completion
    if [[ -f "$PROGRESS_FILE" ]]; then
        _loading3 "Removing progress file (batch completed successfully)"
        rm -f "$PROGRESS_FILE"
        _log "PROGRESS: Removed progress file (batch completed successfully)"
    fi
    
    return 0
}
