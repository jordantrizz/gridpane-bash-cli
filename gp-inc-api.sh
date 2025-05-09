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

        # Get age of the cache file
        CACHE_AGE=$(($(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)))
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
                CACHE_AGE=$(($(date +%s) - $(stat -c %Y "$CACHE_FILE")))
                _debugf "Cache age: $CACHE_AGE seconds"
                if [[ $CACHE_AGE -lt 3600 ]]; then
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
            # -- Get the age of the cache file
            CACHE_AGE=$(($(date +%s) - $(stat -c %Y "$CACHE_FILE")))
            _debugf "Cache age: $CACHE_AGE seconds"
            # -- Check if the cache is older than 1 hour (3600 seconds)
            if [[ $CACHE_AGE -lt 3600 ]]; then
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
    # -- Count how many sites are in cache
    if [[ -n "$API_OUTPUT" ]]; then
        _debugf "Counting sites in cache via \$API_OUTPUT"
        TOTAL_ITEMS=$(echo "$API_OUTPUT" | jq 'length')
        _debugf "Total sites in cache: $TOTAL_ITEMS"
        # -- Cache the API output
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
    # -- Count how many sites are in cache
    if [[ -n "$API_OUTPUT" ]]; then
        _debugf "Counting servers in cache via \$API_OUTPUT"
        TOTAL_ITEMS=$(echo "$API_OUTPUT" | jq 'length')
        _debugf "Total servers in cache: $TOTAL_ITEMS"
        # -- Cache the API output
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
        _error "Cache not found or disabled, run get-sites first"
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

    # Check cache first
    _loading2 "Checking cache for ${ENDPOINT_NAME} data at $CACHE_FILE"
    _gp_api_cache_age "$CACHE_FILE"
    if [[ $? -eq 0 ]]; then
        _debugf "Cache is fresh, using cached ${ENDPOINT_NAME} data"
        # Use jq to filter domains from the cached file
        _debugf "Filtering ${ENDPOINT_NAME} from cache file: $CACHE_FILE"
        if [[ $EXTENDED == "1" ]]; then
            # Extended output with all fields
            DOMAINS=$(jq -r '.[] | "\(.id),\(.url),\(.server_id)"' "$CACHE_FILE")
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
        _error "Cache not found or disabled, run cache-sites first"
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
        _error "Cache not found or disabled, run get-sites first"
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
        _error "Cache not found or disabled, run get-sites first"
        return 1
    fi
}


