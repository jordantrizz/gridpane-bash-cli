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
    _gp_api_get_sites
    local get_sites_result=$?
    
    # Check if _gp_api_get_sites was successful
    if [[ $get_sites_result -ne 0 ]]; then
        _error "Failed to fetch sites from API"
        return 1
    fi
    
    # -- Count how many sites are in cache
    if [[ -n "$API_OUTPUT" ]]; then
        _debugf "Counting sites in cache via \$API_OUTPUT"
        TOTAL_ITEMS=$(echo "$API_OUTPUT" | jq 'length')
        _debugf "Total sites in cache: $TOTAL_ITEMS"
        _success "Successfully cached $TOTAL_ITEMS sites"
        return 0
    else
        _error "No API output to cache"
        return 1
    fi
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
    _gp_api_get_servers
    local get_servers_result=$?

    # Check if _gp_api_get_servers was successful
    if [[ $get_servers_result -ne 0 ]]; then
        _error "Failed to fetch servers from API"
        return 1
    fi

    # -- Count how many servers are in cache
    if [[ -n "$API_OUTPUT" ]]; then
        _debugf "Counting servers in cache via \$API_OUTPUT"
        TOTAL_ITEMS=$(echo "$API_OUTPUT" | jq 'length')
        _debugf "Total servers in cache: $TOTAL_ITEMS"
        _success "Successfully cached $TOTAL_ITEMS servers"
        return 0
    else
        _error "No API output to cache"
        return 1
    fi
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
    local PER_PAGE=100
    local LAST_PAGE
    CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_${ENDPOINT_NAME}.json"

    # Check cache first
    _loading2 "Checking cache for ${ENDPOINT_NAME} data at $CACHE_FILE"
    _gp_api_cache_age "$CACHE_FILE"
    if [[ $? -eq 0 ]]; then
        _loading3 "Using cached combined ${ENDPOINT_NAME} data from $CACHE_FILE"
        API_OUTPUT=$(<"$CACHE_FILE")
    else
        _loading3 "Cache not found or disabled, fetching data from API"
        # Fetch first page to get pagination info
        gp_api GET "$ENDPOINT?per_page=$PER_PAGE"
        GP_API_RETURN="$?"
        [[ $GP_API_RETURN != 0 ]] && { _error "Error: $API_ERROR"; exit 1; }
        LAST_PAGE=$(echo "$API_OUTPUT" | jq -r '.meta.last_page')
        TOTAL_API_ITEMS=$(echo "$API_OUTPUT" | jq -r '.meta.total')
        _loading3 "Total ${ENDPOINT_NAME}: $TOTAL_API_ITEMS, Last page: $LAST_PAGE"
        local TMP_DIR
        TMP_DIR=$(mktemp -d)
        echo "$API_OUTPUT" > "$TMP_DIR/page1.json"

        # Fetch all other pages
        for p in $(seq 2 "$LAST_PAGE"); do
            _debugf "Fetching page $p of $LAST_PAGE"
            gp_api GET "$ENDPOINT?page=$p&per_page=$PER_PAGE"
            GP_API_RETURN="$?"
            [[ $GP_API_RETURN != 0 ]] && { _error "Error: $API_ERROR"; rm -rf "$TMP_DIR"; exit 1; }
            echo "$API_OUTPUT" > "$TMP_DIR/page${p}.json"
        done

        # Combine all .data[] arrays into one
        jq -s '[ .[] | .data[] ]' "$TMP_DIR"/page*.json > "$CACHE_FILE"
        rm -rf "$TMP_DIR"
        _loading "Combined ${ENDPOINT_NAME} data cached to $CACHE_FILE"
        # Set API_OUTPUT to the combined data
        API_OUTPUT=$(<"$CACHE_FILE")
    fi

    TOTAL_ITEMS=$(jq 'length' "$CACHE_FILE")
    _loading3 "Total ${ENDPOINT_NAME}: $TOTAL_ITEMS"
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

    # Check cache first
    _loading2 "Checking cache for ${ENDPOINT_NAME} data at $CACHE_FILE"
    _gp_api_cache_age "$CACHE_FILE"
    if [[ $? -eq 0 ]]; then
        _debugf "Cache is fresh, using cached ${ENDPOINT_NAME} data"
        # Use jq to filter domains from the cached file
        _debugf "Filtering ${ENDPOINT_NAME} from cache file: $CACHE_FILE"
        if [[ $EXTENDED == "1" ]]; then
            # Extended output with all fields
            DOMAINS=$(jq -r '.[] | "\(.id),\(.label),\(.ip),\(.database),\(.webserver),\(.os_version)"' "$CACHE_FILE")
        else
            # Default output with just label and id
            DOMAINS=$(jq -r '.[] | .label' "$CACHE_FILE" | sort -u)
        fi
        echo "$DOMAINS"
        # Total Domains
        TOTAL_DOMAINS=$(echo "$DOMAINS" | wc -l)
        _loading3 "Total ${ENDPOINT_NAME} found: $TOTAL_DOMAINS"
        return 0
    else
        # Cache not found - prompt user to run cache-servers
        _handle_cache_not_found "servers"
        if [[ $? -eq 0 ]]; then
            # Cache was populated, retry the operation
            _gp_api_cache_age "$CACHE_FILE"
            if [[ $? -eq 0 ]]; then
                if [[ $EXTENDED == "1" ]]; then
                    DOMAINS=$(jq -r '.[] | "\(.id),\(.label),\(.ip),\(.database),\(.webserver),\(.os_version)"' "$CACHE_FILE")
                else
                    DOMAINS=$(jq -r '.[] | .label' "$CACHE_FILE" | sort -u)
                fi
                echo "$DOMAINS"
                TOTAL_DOMAINS=$(echo "$DOMAINS" | wc -l)
                _loading3 "Total ${ENDPOINT_NAME} found: $TOTAL_DOMAINS"
                return 0
            fi
        fi
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

    # Check both cache files exist and are fresh
    _loading2 "Checking server cache at $SERVER_CACHE_FILE"
    _gp_api_cache_age "$SERVER_CACHE_FILE"
    local SERVER_CACHE_FRESH=$?

    _loading2 "Checking site cache at $SITE_CACHE_FILE"
    _gp_api_cache_age "$SITE_CACHE_FILE"
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
        _error "Cache not found or disabled, run cache-servers and cache-sites first"
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
    local ENDPOINT="/site"
    local ENDPOINT_NAME
    ENDPOINT_NAME=$(echo "$ENDPOINT" | tr -d '/')
    local PER_PAGE=100
    local LAST_PAGE
    CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_site.json"

    # Check cache first
    _loading2 "Checking cache for ${ENDPOINT_NAME} data at $CACHE_FILE"
    _gp_api_cache_age "$CACHE_FILE"
    if [[ $? -eq 0 ]]; then
        _success "Cache exists and is fresh"
        API_OUTPUT=$(<"$CACHE_FILE")
        _debugf "Using cached site data from $CACHE_FILE"
    else
        # Fetch first page to get pagination info
        gp_api GET "$ENDPOINT?per_page=$PER_PAGE"
        GP_API_RETURN="$?"
        [[ $GP_API_RETURN != 0 ]] && { _error "Error: $API_ERROR"; exit 1; }
        LAST_PAGE=$(echo "$API_OUTPUT" | jq -r '.meta.last_page')
        TOTAL_ITEMS=$(echo "$API_OUTPUT" | jq -r '.meta.total')
        _loading3 "Total sites: $TOTAL_ITEMS, Last page: $LAST_PAGE"
        local TMP_DIR
        TMP_DIR=$(mktemp -d)
        echo "$API_OUTPUT" > "$TMP_DIR/page1.json"

        # Fetch all other pages
        for p in $(seq 2 "$LAST_PAGE"); do
            _debugf "Fetching page $p of $LAST_PAGE"
            gp_api GET "$ENDPOINT?page=$p&per_page=$PER_PAGE"
            GP_API_RETURN="$?"
            [[ $GP_API_RETURN != 0 ]] && { _error "Error: $API_ERROR"; rm -rf "$TMP_DIR"; exit 1; }
            echo "$API_OUTPUT" > "$TMP_DIR/page${p}.json"
        done

        # Combine all .data[] arrays into one
        jq -s '[ .[] | .data[] ]' "$TMP_DIR"/page*.json > "$CACHE_FILE"
        rm -rf "$TMP_DIR"
        _debugf "All data from ${CACHE_FILE} combined and cached into \$API_OUTPUT"
        API_OUTPUT=$(<"$CACHE_FILE")
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
            # Default output with just label and id
            DOMAINS=$(jq -r '.[] | .url' "$CACHE_FILE" | sort -u)
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
    local CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_site.json"

    # Check cache first
    _loading2 "Checking cache for ${ENDPOINT_NAME} data at $CACHE_FILE"
    _gp_api_cache_age "$CACHE_FILE"
    if [[ $? -eq 0 ]]; then
        _debugf "Using cached site data for domain: $DOMAIN"
        # Use jq to filter domains from the cached file
        _debugf "Filtering domains from cache file: $CACHE_FILE"
        DOMAINS=$(jq -r '.[] | .url' "$CACHE_FILE" | sort -u)
        echo "$DOMAINS"
        # Total Domains
        TOTAL_DOMAINS=$(echo "$DOMAINS" | wc -l)
        _loading3 "Total domains found: $TOTAL_DOMAINS"
        return 0
    else
        # Cache not found - prompt user to run cache-sites
        _handle_cache_not_found "sites"
        if [[ $? -eq 0 ]]; then
            # Cache was populated, retry the operation
            _gp_api_cache_age "$CACHE_FILE"
            if [[ $? -eq 0 ]]; then
                DOMAINS=$(jq -r '.[] | .url' "$CACHE_FILE" | sort -u)
                echo "$DOMAINS"
                TOTAL_DOMAINS=$(echo "$DOMAINS" | wc -l)
                _loading3 "Total domains found: $TOTAL_DOMAINS"
                return 0
            fi
        fi
        return 1
    fi
}


# =====================================
# -- _gp_api_get_site $DOMAIN
# -- Fetch sites from GridPane API
# ======================================
function _gp_api_get_site () {
    local DOMAIN="$1"
    local CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_site.json"
    if [[ -z "$DOMAIN" ]]; then
        _error "Error: Domain is required"
        return 1
    fi

    # Check cache first
    _loading2 "Checking cache for ${ENDPOINT_NAME} data at $CACHE_FILE"
    _gp_api_cache_age "$CACHE_FILE"
    if [[ $? -eq 0 ]]; then
        _debugf "Using cached site data for domain: $DOMAIN"
        jq --arg domain "$DOMAIN" '.[] | select(.url == $domain)' "$CACHE_FILE"
        return 0
    else
        # Cache not found - prompt user to run cache-sites
        _handle_cache_not_found "sites"
        if [[ $? -eq 0 ]]; then
            # Cache was populated, retry the operation
            _gp_api_cache_age "$CACHE_FILE"
            if [[ $? -eq 0 ]]; then
                jq --arg domain "$DOMAIN" '.[] | select(.url == $domain)' "$CACHE_FILE"
                return 0
            fi
        fi
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

    # Check cache first
    _loading2 "Checking cache for ${ENDPOINT_NAME} data at $CACHE_FILE"
    _gp_api_cache_age "$CACHE_FILE"
    if [[ $? -eq 0 ]]; then
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
        # Cache not found - prompt user to run cache-servers
        _handle_cache_not_found "servers"
        if [[ $? -eq 0 ]]; then
            # Cache was populated, retry the operation
            _gp_api_cache_age "$CACHE_FILE"
        fi
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
    done
    
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

