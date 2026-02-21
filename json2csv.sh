#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/inc/gp-inc.sh"
_loading "Running json2csv.sh"

# -- Load .gridpane
[[ -f "$HOME/.gridpane" ]] && source "$HOME/.gridpane" || { _error "Missing $HOME/.gridpane"; exit 1; }
_loading2 "Loading $HOME/.gridpane"

# -- Set DATA_DIR
[[ -z $DATA_DIR ]] && { DATA_DIR="$SCRIPT_DIR/data"; }
_loading2 "Using DATA_DIR=$DATA_DIR"
JSON_FILE="$DATA_DIR/combined.json"
[[ ! -f $JSON_FILE ]] && { _error "Missing $JSON_FILE"; exit 1; }
_loading2 "Using JSON_FILE=$JSON_FILE"
# -- Check if jq is installed
[[ ! -x "$(command -v jq)" ]] && { _error "jq is not installed"; exit 1; }

# id, label, ip, database, webserver, os_version, is_mysql_slow_query_log
_loading2 "Converting $JSON_FILE to $DATA_DIR/combined.csv"
jq -r '
    .[] | 
    [
        .id, 
        .label, 
        .ip,
        .database, 
        .webserver, 
        .os_version, 
        .is_mysql_slow_query_log,
        .provider.id,
        .provider.name
    ] | @csv
' "$JSON_FILE" > "$DATA_DIR/combined.csv"

_loading2 "Converting $JSON_FILE to $DATA_DIR/sites.csv"
jq -r '
  .[] 
  | . as $host 
  | $host.sites[]
  # drop urls starting with canary or staging (case-insensitive)
  | select( .url
      | test("^(?:https?://)?(?:canary|staging)\\."; "i")
      | not
    )
  | [ .id, .url, $host.label ] 
  | @csv
' "$JSON_FILE" > "$DATA_DIR/sites.csv"
