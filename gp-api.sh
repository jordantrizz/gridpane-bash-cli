#!/bin/env bash

source $HOME/.gridpane
GP_API_URL="https://my.gridpane.com/oauth/api/v1"
RANDOM_NUM=$((RANDOM % 1000))
REPORT_FILE="/tmp/gp-api-report-$RANDOM_NUM.json"
_debugf() {
    if [[ $DEBUGF == "1" ]]; then
        echo -e "\e[1;32m$1\e[0m" >> debug.log
    fi
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
    curl -s --output "$CURL_OUTPUT" \
    -w "%{http_code}" \
    --url "${GP_API_URL}${ENDPOINT}" \
    "${CURL_HEADERS[@]}" \
    "${EXTRA[@]}"
    [[ $DEBUGF == "1" ]] && set +x
     API_OUTPUT=$(<"$CURL_OUTPUT")
}

# -- gp_api_servers $PAGE
function gp_api_servers () {
    local PAGE=$1
    gp_api GET "/server?page=$PAGE"
    _debugf "API Output: $API_OUTPUT"
    echo "$API_OUTPUT" | jq -r '.data[]'
}

CMD="$1"
[[ -z "$CMD" ]] && { echo "Usage: $0 <command>"; exit 1; }

if [[ $CMD == "server-summary" ]]; then
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
fi

gp_api GET "$CMD"
_debugf "API Output: $API_OUTPUT"
echo "$API_OUTPUT" | jq -r '.'