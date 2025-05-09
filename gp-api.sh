#!/usr/bin/env bash

[[ -f "$HOME/.gridpane" ]] || { echo "Missing $HOME/.gridpane"; exit 1; }
source $HOME/.gridpane

# -- Variables
GP_API_URL="https://my.gridpane.com/oauth/api/v1"
RANDOM_NUM=$((RANDOM % 1000))
REPORT_FILE="/tmp/gp-api-report-$RANDOM_NUM.json"

# -- Functions
function usage() {
    echo "Usage: $0 <command>"
    echo "Commands:"
    echo "  gp-servers-old"
    echo "  gp-servers"
}
# Cyan debug
_debugf() {
    if [[ $DEBUGF == "1" ]]; then
        echo -e "\e[1;36m$@\e[0m"
    fi
}

_debug_file () {
    if [[ $DEBUGF == "1" ]]; then
        echo "$@" >> debug.log
    fi
}
_error() {
    echo -e "\e[1;31m$1\e[0m"
}

# -- gp_api $METOD $ENDPOINT
function gp_api () {
    local METHOD=$1
    local ENDPOINT=$2
    local EXTRA=$3
    local CURL_HEADERS=()
    local CURL_OUTPUT
    
    [[ $DEBUGF == "1" ]] && set -x
    CURL_HEADERS+=(-H "Authorization: Bearer $GP_TOKEN")
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
    [[ $CURL_HTTP_CODE -ne 200 ]] && { API_ERROR="CURL exit code: $CURL_HTTP_CODE"; return 1; }
    return 0
}

# -- gp_api_servers_old
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
# -- gp_api_servers $PAGE
# =====================================
function gp_api_servers () {
    gp_api GET "/server"
    GP_API_RETURN="$?"
    _debugf "GP API Return: $GP_API_RETURN"
    _debug_file "API Output: $API_OUTPUT"
    [[ $GP_API_RETURN != 0 ]] && { _error "Error: $API_ERROR"; exit 1; }
    echo "$API_OUTPUT" > page1.json
    LAST_PAGE=$(echo "$API_OUTPUT" | jq -r '.meta.last_page')
    _debugf "Last page: $LAST_PAGE"

    # Fetch each page, grab its .data array, and feed into jq to flatten
    for p in $(seq 2 "$LAST_PAGE"); do
        echo "Fetching page $p of $LAST_PAGE"
        gp_api GET "/server?page=$p"
        echo "$API_OUTPUT" > "page${p}.json"
        GP_API_RETURN="$?"
        _debugf "GP API Return: $GP_API_RETURN"
        _debug_file "API Output: $API_OUTPUT"
        [[ $GP_API_RETURN != 0 ]] && { _error "Error: $API_ERROR"; exit 1; }
        # Check if page${p}.json is empty
        if [[ ! -s "page${p}.json" ]]; then
            _error "Error: page${p}.json is empty"
            exit 1
        fi
    done
    jq -s '[ .[] | .data[] ]' page*.json > combined.json
    #rm page*.json
}

CMD="$1"
[[ -z "$CMD" ]] && { echo "Usage: $0 <command>"; exit 1; }
if [[ $CMD == "api" ]]; then
    CMD_ACTION="$2"
    [[ -z "$CMD_ACTION" ]] && { echo "Usage: $0 api <action>"; exit 1; }
    gp_api GET "$CMD_ACTION"
    _debugf "API Output: $API_OUTPUT"
    echo "$API_OUTPUT" | jq -r '.'
elif [[ $CMD == "gp-servers-old" ]]; then
    gp_api_servers_old
elif [[ $CMD == "gp-servers" ]]; then
    gp_api_servers
else
    usage
    echo "Unknown command: $CMD" 
    exit 1
fi