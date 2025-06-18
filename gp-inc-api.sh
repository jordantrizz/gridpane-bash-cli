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
    _gp_api_cache_status $ENDPOINT
    _gp_api_cache_get "$ENDPOINT"
    [[ $? -ne 1 ]] && { _debugf "Cache found for $ENDPOINT, using cached data"; return 0; }

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

# =============================================================================
# -- Servers Commands
# =============================================================================

# ======================================
# -- gp_api_servers_old
# ======================================
function gp_api_servers_old () {
    CMD="/server"
    gp_api GET "$CMD" | jq -r '.data[]' >> "$REPORT_FILE"
    _debugf "API Output: $API_OUTPUT"
    LAST_PAGE=$(echo "$API_OUTPUT" | jq -r '.meta.last_page')
    FIRST_PAGE=$(echo "$API_OUTPUT" | jq -r '.meta.current_page')
    MAX_PAGE="2"
    while [[ $LAST_PAGE != $FIRST_PAGE ]]; do
        FIRST_PAGE=$((FIRST_PAGE + 1))
        echo "Fetching page $FIRST_PAGE of $LAST_PAGE"
        gp_api GET "$CMD?page=$FIRST_PAGE" #"--data { \"summary\" true }"
        _debugf "API Output: $API_OUTPUT"
        echo "$API_OUTPUT" >> "$REPORT_FILE"
        ##[[ $FIRST_PAGE == $MAX_PAGE ]] && break
        sleep 5
    done
    echo "$REPORT_FILE"
    exit 1
}

# =====================================
# -- _gp_api_servers
# -- Fetch servers from GridPane API
# ======================================
function _gp_api_servers () {
    _debugf "${FUNCNAME[0]} called"
    local ENDPOINT="/server"
    local ENDPOINT_NAME
    ENDPOINT_NAME=$(echo "$ENDPOINT" | tr -d '/')
    local PER_PAGE=100
    local LAST_PAGE
    _gp_select_token
    CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_${ENDPOINT_NAME}.json"

    # Check cache first
    if [[ $CACHE_ENABLED == "1" && -f "$CACHE_FILE" ]]; then
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
    if [[ $CACHE_ENABLED == "1" && -f "$CACHE_FILE" ]]; then
        _debugf "Using cached ${ENDPOINT_NAME} data from $CACHE_FILE"
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
        _debugf "Cache not found or disabled, run get-sites first"
    fi
}

# =====================================
# -- _gp_api_list_servers_sites
# -- List servers from GridPane API
# ======================================
function _gp_api_list_servers_sites () {
    _debugf "${FUNCNAME[0]} called"
    local ENDPOINT="/server"
    local ENDPOINT_NAME
    ENDPOINT_NAME=$(echo "$ENDPOINT" | tr -d '/')
    _gp_select_token
    CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_${ENDPOINT_NAME}.json"

    # Check cache first
    _loading2 "Checking cache for ${ENDPOINT_NAME} data at $CACHE_FILE"
    if [[ $CACHE_ENABLED == "1" && -f "$CACHE_FILE" ]]; then
        jq -r '.[] | .label as $server | .sites[]? | "\($server),\(.url)"' "$CACHE_FILE"
        return 0
    else
        _error "Cache not found or disabled, run get-servers first"
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
    local ENDPOINT="/site"
    local PER_PAGE=100
    local LAST_PAGE
    CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_site.json"

    # Check cache first
    if [[ $CACHE_ENABLED == "1" && -f "$CACHE_FILE" ]]; then
        _debugf "Using cached combined sites data"
        cat "$CACHE_FILE"
        return 0
    fi

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
    _loading "Combined sites data cached to $CACHE_FILE"
}

# =====================================
# -- _gp_api_get_urls
# -- Fetch domains from GridPane API
# ======================================
function _gp_api_get_urls () {
    local CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_site.json"

    # Check cache first
    _loading2 "Checking cache for site data for domain: $DOMAIN"
    local CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_site.json"
    if [[ $CACHE_ENABLED == "1" && -f "$CACHE_FILE" ]]; then
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
        _debugf "Cache not found or disabled, run get-sites first"
    fi
}


# =====================================
# -- _gp_api_get_site $DOMAIN
# -- Fetch sites from GridPane API
# ======================================
function _gp_api_get_site () {
    local DOMAIN="$1"
    if [[ -z "$DOMAIN" ]]; then
        _error "Error: Domain is required"
        return 1
    fi

    # Check cache first
    _loading2 "Checking cache for site data for domain: $DOMAIN"
    local CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_site.json"
    if [[ $CACHE_ENABLED == "1" && -f "$CACHE_FILE" ]]; then
        _debugf "Using cached site data for domain: $DOMAIN"
        jq --arg domain "$DOMAIN" '.[] | select(.url == $domain)' "$CACHE_FILE"
        return 0
    else
        _debugf "Cache not found or disabled, run get-sites first"
    fi
}


