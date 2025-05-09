#!/usr/bin/env bash
[[ -f "$HOME/.gridpane" ]] && source "$HOME/.gridpane"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z $DATA_DIR ]] && { DATA_DIR="$SCRIPT_DIR/data"; }
[[ -z $DEBUGF ]] && { DEBUGF=0; }
JSON_FILE="$DATA_DIR/combined.json"
[[ ! -f $JSON_FILE ]] && { echo "Missing $JSON_FILE"; exit 1; }

# id, label, ip, database, webserver, os_version, is_mysql_slow_query_log
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

# -- Get list of sites on each server
# -- Format as site,server in csv
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
