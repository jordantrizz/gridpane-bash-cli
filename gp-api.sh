#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/gp-inc.sh"
[[ -f "$HOME/.gridpane" ]] || { _error "Missing $HOME/.gridpane"; exit 1; }
source $HOME/.gridpane
[[ -z $DATA_DIR ]] && { DATA_DIR="$SCRIPT_DIR/data"; }

# =======================================
# -- Variables
# =======================================
GP_API_URL="https://my.gridpane.com/oauth/api/v1"
RANDOM_NUM=$((RANDOM % 1000))
REPORT_FILE="$DATA_DIR/$RANDOM_NUM.json"

# =======================================
# -- Usage
# =======================================
function usage() {
    echo "Usage: $0 -c <command> <action> [options]"
    echo
    echo "Commands:"
    echo "  api <endpoint>       - Run an API endpoint (GET only)"
    echo "  gp-servers-old       - Fetch servers using old method"
    echo "  gp-servers           - Fetch servers with page support and json combine"
    echo
    echo "Options:"
    echo "  -h, --help          - Show this help message"
    echo "  -d, --debug         - Enable debug mode"
}

# ======================================
# -- gp_api $METOD $ENDPOINT
# ======================================
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

# =============================================================================
# -- Main
# =============================================================================
# -- Process Arguments
    POSITIONAL=()
    while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -c|--command)
        CMD="$2"
        shift 2
        [[ -n $1 ]] && { CMD_ACTION="$1"; shift ; }
        ;;
        -d|--debug)
        DEBUG="1"
        shift # past argument
        ;;
        -h|--help)
        usage
        ;;
        *)    # unknown option
        POSITIONAL+=("$1") # save it in an array for later
        shift # past argument
        ;;
    esac
    done
    set -- "${POSITIONAL[@]}" # restore positional parameters

# -- API
if [[ $CMD == "api" ]]; then
    [[ -z "$CMD_ACTION" ]] && { echo "Usage: $0 api <action>"; exit 1; }
    gp_api GET "$CMD_ACTION"
    _debugf "API Output: $API_OUTPUT"
    echo "$API_OUTPUT" | jq -r '.'
# -- gp-servers-old
elif [[ $CMD == "gp-servers-old" ]]; then
    gp_api_servers_old
# -- gp-servers
elif [[ $CMD == "gp-servers" ]]; then
    gp_api_servers
elif [[ $CMD == "" ]]; then
    usage
    _error "No command provided"
    exit 1
else
    usage
    _error "Unknown command: $CMD"
    exit 1
fi