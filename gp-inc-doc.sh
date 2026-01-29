#!/bin/bash
# =============================================================================
# -- gp-inc-doc.sh - API Documentation Functions
# =============================================================================
echo "Loaded gp-inc-doc.sh"

DOC_FILE="$SCRIPT_DIR/doc/gridpane-api.json"

# =====================================
# -- Check jq dependency
# =====================================
_gp_doc_check_jq() {
    if ! command -v jq &> /dev/null; then
        _error "jq is required for documentation commands but is not installed."
        _error "Install with: sudo apt install jq (Debian/Ubuntu) or brew install jq (macOS)"
        exit 1
    fi
}

# =====================================
# -- Check doc file exists
# =====================================
_gp_doc_check_file() {
    if [[ ! -f "$DOC_FILE" ]]; then
        _error "API documentation file not found: $DOC_FILE"
        exit 1
    fi
}

# =====================================
# -- Normalize string for fuzzy matching
# -- Converts to lowercase, replaces hyphens/underscores with spaces
# =====================================
_gp_doc_normalize() {
    local str="$1"
    echo "$str" | tr 'A-Z' 'a-z' | tr '-' ' ' | tr '_' ' ' | tr -s ' '
}

# =====================================
# -- List all API endpoint categories
# =====================================
_gp_doc_list_categories() {
    _gp_doc_check_jq
    _gp_doc_check_file
    _debugf "${FUNCNAME[0]} called"
    
    echo ""
    echo "GridPane API Endpoint Categories"
    echo "================================="
    echo ""
    printf "%-20s %s\n" "CATEGORY" "ENDPOINTS"
    printf "%-20s %s\n" "--------" "---------"
    
    # Parse categories and count endpoints
    jq -r '.collection.item[] | "\(.name)\t\(.item | length)"' "$DOC_FILE" | \
    while IFS=$'\t' read -r name count; do
        printf "%-20s %s\n" "$name" "$count"
    done
    
    echo ""
    echo "Usage: ./gp-api.sh -c doc <category>"
    echo "Example: ./gp-api.sh -c doc server"
}

# =====================================
# -- List endpoints in a category
# =====================================
_gp_doc_list_endpoints() {
    local category="$1"
    _gp_doc_check_jq
    _gp_doc_check_file
    _debugf "${FUNCNAME[0]} called with category: $category"
    
    if [[ -z "$category" ]]; then
        _error "Category is required. Use 'doc-api' to list available categories."
        exit 1
    fi
    
    local normalized_input
    normalized_input=$(_gp_doc_normalize "$category")
    _debugf "Normalized input: $normalized_input"
    
    # Find matching category (case-insensitive, partial match)
    local match
    match=$(jq -r '.collection.item[] | .name' "$DOC_FILE" | while read -r cat_name; do
        local normalized_cat
        normalized_cat=$(_gp_doc_normalize "$cat_name")
        if [[ "$normalized_cat" == *"$normalized_input"* ]] || [[ "$normalized_input" == *"$normalized_cat"* ]]; then
            echo "$cat_name"
            break
        fi
    done)
    
    if [[ -z "$match" ]]; then
        _error "Category '$category' not found."
        echo ""
        echo "Available categories:"
        jq -r '.collection.item[] | "  - \(.name)"' "$DOC_FILE"
        exit 1
    fi
    
    _debugf "Matched category: $match"
    
    echo ""
    echo "Endpoints in '$match' category"
    echo "================================="
    echo ""
    printf "%-35s %-8s %s\n" "ENDPOINT" "METHOD" "DESCRIPTION"
    printf "%-35s %-8s %s\n" "--------" "------" "-----------"
    
    local row_count=0
    
    # Parse endpoints for the matched category
    jq -r --arg cat "$match" '
        .collection.item[] | 
        select(.name == $cat) | 
        .item[] | 
        "\(.name)\t\(.request.method // "GET")\t\(.request.description // "No description" | split("\n")[0] | .[0:50])"
    ' "$DOC_FILE" | while IFS=$'\t' read -r name method desc; do
        # Repeat headers every 10 rows for readability
        if [[ $row_count -gt 0 && $((row_count % 10)) -eq 0 ]]; then
            echo ""
            printf "%-35s %-8s %s\n" "ENDPOINT" "METHOD" "DESCRIPTION"
            printf "%-35s %-8s %s\n" "--------" "------" "-----------"
        fi
        printf "%-35s %-8s %s\n" "$name" "$method" "$desc"
        ((row_count++))
    done
    
    echo ""
    echo "Usage: ./gp-api.sh -c doc $match <endpoint-name>"
    echo "Example: ./gp-api.sh -c doc $match get-servers"
}

# =====================================
# -- Show full endpoint documentation
# =====================================
_gp_doc_show_endpoint() {
    local category="$1"
    local endpoint="$2"
    _gp_doc_check_jq
    _gp_doc_check_file
    _debugf "${FUNCNAME[0]} called with category: $category, endpoint: $endpoint"
    
    if [[ -z "$category" ]] || [[ -z "$endpoint" ]]; then
        _error "Both category and endpoint are required."
        echo "Usage: ./gp-api.sh -c doc <category> <endpoint>"
        exit 1
    fi
    
    local normalized_cat normalized_endpoint
    normalized_cat=$(_gp_doc_normalize "$category")
    normalized_endpoint=$(_gp_doc_normalize "$endpoint")
    _debugf "Normalized category: $normalized_cat, endpoint: $normalized_endpoint"
    
    # Find matching category
    local cat_match
    cat_match=$(jq -r '.collection.item[] | .name' "$DOC_FILE" | while read -r cat_name; do
        local normalized
        normalized=$(_gp_doc_normalize "$cat_name")
        if [[ "$normalized" == *"$normalized_cat"* ]] || [[ "$normalized_cat" == *"$normalized"* ]]; then
            echo "$cat_name"
            break
        fi
    done)
    
    if [[ -z "$cat_match" ]]; then
        _error "Category '$category' not found."
        exit 1
    fi
    
    _debugf "Matched category: $cat_match"
    
    # Find matching endpoint within category (fuzzy match)
    local endpoint_match
    endpoint_match=$(jq -r --arg cat "$cat_match" '
        .collection.item[] | 
        select(.name == $cat) | 
        .item[] | .name
    ' "$DOC_FILE" | while read -r ep_name; do
        local normalized
        normalized=$(_gp_doc_normalize "$ep_name")
        if [[ "$normalized" == *"$normalized_endpoint"* ]] || [[ "$normalized_endpoint" == *"$normalized"* ]]; then
            echo "$ep_name"
            break
        fi
    done)
    
    if [[ -z "$endpoint_match" ]]; then
        _error "Endpoint '$endpoint' not found in category '$cat_match'."
        echo ""
        echo "Available endpoints in '$cat_match':"
        jq -r --arg cat "$cat_match" '
            .collection.item[] | 
            select(.name == $cat) | 
            .item[] | "  - \(.name)"
        ' "$DOC_FILE"
        exit 1
    fi
    
    _debugf "Matched endpoint: $endpoint_match"
    
    # Extract and display full endpoint details
    echo ""
    echo "=============================================="
    echo " $endpoint_match"
    echo "=============================================="
    echo ""
    
    # Get endpoint details
    local details
    details=$(jq -r --arg cat "$cat_match" --arg ep "$endpoint_match" '
        .collection.item[] | 
        select(.name == $cat) | 
        .item[] | 
        select(.name == $ep) | 
        {
            method: .request.method,
            url: .request.url.raw,
            path: (.request.url.path | join("/")),
            description: .request.description,
            body: .request.body.raw
        }
    ' "$DOC_FILE")
    
    local method url path description body
    method=$(echo "$details" | jq -r '.method // "GET"')
    url=$(echo "$details" | jq -r '.url // "N/A"')
    path=$(echo "$details" | jq -r '.path // "N/A"')
    description=$(echo "$details" | jq -r '.description // "No description available"')
    body=$(echo "$details" | jq -r '.body // empty')
    
    echo "Method:  $method"
    echo "URL:     $url"
    echo "Path:    /$path"
    echo ""
    echo "Description:"
    echo "------------"
    echo "$description"
    
    if [[ -n "$body" && "$body" != "null" && "$body" != "" ]]; then
        echo ""
        echo "Request Body Template:"
        echo "----------------------"
        echo "$body" | jq -r '.' 2>/dev/null || echo "$body"
    fi
    
    echo ""
}
