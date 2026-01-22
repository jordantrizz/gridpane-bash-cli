#!/bin/bash
# =============================================================================
# -- Report Generation Commands
# =============================================================================

# ======================================
# -- _gp_report_sites_per_server
# -- Generate a report of total sites per server (alphabetically sorted)
# ======================================
function _gp_report_sites_per_server () {
    _debugf "${FUNCNAME[0]} called"
    _gp_select_token
    
    local SITE_CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_site.json"
    local SERVER_CACHE_FILE="${CACHE_DIR}/${GPBC_TOKEN_NAME}_server.json"
    
    # Check if site cache exists and is fresh
    _loading2 "Checking site cache at $SITE_CACHE_FILE"
    _check_cache_with_options "$SITE_CACHE_FILE" "sites"
    local site_cache_status=$?
    
    if [[ $site_cache_status -ne 0 ]]; then
        _error "Unable to proceed without site cache."
        return 1
    fi
    
    # Check if server cache exists and is fresh
    _loading2 "Checking server cache at $SERVER_CACHE_FILE"
    _check_cache_with_options "$SERVER_CACHE_FILE" "servers"
    local server_cache_status=$?
    
    if [[ $server_cache_status -ne 0 ]]; then
        _error "Unable to proceed without server cache."
        return 1
    fi
    
    _loading3 "Generating report: Sites per Server"
    
    # Use jq to:
    # 1. Group sites by server_id
    # 2. Count sites per server
    # 3. Cross-reference with server cache to get server names
    # 4. Sort alphabetically by server name
    local REPORT
    REPORT=$(jq -s '
        # First, get the sites array and count by server_id
        .[0] as $sites |
        .[1] as $servers |
        
        # Create a map of site counts by server_id
        ($sites | group_by(.server_id) | map({
            server_id: .[0].server_id,
            count: length
        }) | map({(.server_id | tostring): .count}) | add) as $site_counts |
        
        # Map through servers and add site counts
        $servers | map({
            server_id: .id,
            server_name: .label,
            total_sites: ($site_counts[(.id | tostring)] // 0)
        }) |
        
        # Sort alphabetically by server name
        sort_by(.server_name) |
        
        # Format as table rows
        .[] | 
        "\(.server_id)\t\(.server_name)\t\(.total_sites)"
    ' "$SITE_CACHE_FILE" "$SERVER_CACHE_FILE")
    
    # Output the report as a formatted table
    _success "Report: Sites per Server (alphabetically sorted)"
    echo
    echo -e "Server ID\tServer Name\tTotal Sites" | column -t -s $'\t'
    echo "=========================================="
    echo -e "$REPORT" | column -t -s $'\t'
    echo
    
    return 0
}
