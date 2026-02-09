#!/usr/bin/env bash
# =============================================================================
# rocket-poc.sh - Rocket.net server discovery POC
# =============================================================================
# Discover users, sites, and WordPress DB config on a Rocket.net server
# via SSH by scanning /home/*/public_html
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/gp-inc.sh"

# -- Defaults
SSH_USER="root"
SSH_PORT="22"
SSH_HOST=""
VERBOSE="0"

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
_usage() {
    echo "Usage: $0 -h <host> [-u <user>] [-p <port>] [-v]"
    echo
    echo "Rocket.net server discovery POC - enumerate users, sites, and WP DB config."
    echo
    echo "Required:"
    echo "  -h, --host <ip|hostname>   Server IP or hostname to SSH into"
    echo
    echo "Options:"
    echo "  -u, --user <user>          SSH user (default: root)"
    echo "  -p, --port <port>          SSH port (default: 22)"
    echo "  -v, --verbose              Show detailed output"
    echo "  --help                     Show this help message"
    echo
    echo "Examples:"
    echo "  $0 -h 203.0.113.10"
    echo "  $0 -h 203.0.113.10 -u rocketuser -p 2222 -v"
}

# -----------------------------------------------------------------------------
# Parse args
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--host)  SSH_HOST="$2"; shift 2 ;;
        -u|--user)  SSH_USER="$2"; shift 2 ;;
        -p|--port)  SSH_PORT="$2"; shift 2 ;;
        -v|--verbose) VERBOSE="1"; shift ;;
        --help)     _usage; exit 0 ;;
        *)          _error "Unknown option: $1"; _usage; exit 1 ;;
    esac
done

if [[ -z "$SSH_HOST" ]]; then
    _error "Missing required argument: --host"
    _usage
    exit 1
fi

# -----------------------------------------------------------------------------
# SSH helper
# -----------------------------------------------------------------------------
_ssh_cmd() {
    local cmd="$1"
    ssh -o ConnectTimeout=10 \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        -p "$SSH_PORT" \
        "$SSH_USER@$SSH_HOST" \
        "$cmd"
}

# -----------------------------------------------------------------------------
# Step 1: List all users with public_html directories
# -----------------------------------------------------------------------------
echo "============================================="
echo " Rocket.net Server Discovery POC"
echo " Host: $SSH_USER@$SSH_HOST:$SSH_PORT"
echo "============================================="
echo

_loading "Step 1: Discovering users via /home/*/public_html ..."
echo

users_raw=$(_ssh_cmd "ls -d /home/*/public_html 2>/dev/null || true")

if [[ -z "$users_raw" ]]; then
    _error "No /home/*/public_html directories found (or SSH failed)."
    exit 1
fi

# Extract usernames from paths
declare -a USERS=()
while IFS= read -r line; do
    # /home/<user>/public_html -> <user>
    user=$(echo "$line" | sed 's|/home/||;s|/public_html||')
    USERS+=("$user")
done <<< "$users_raw"

_success "Found ${#USERS[@]} user(s):"
echo
printf "  %-30s %s\n" "USER" "PUBLIC_HTML PATH"
printf "  %-30s %s\n" "----" "----------------"
for u in "${USERS[@]}"; do
    printf "  %-30s /home/%s/public_html\n" "$u" "$u"
done
echo

# -----------------------------------------------------------------------------
# Step 2: List sites (folders) inside each user's public_html
# -----------------------------------------------------------------------------
_loading "Step 2: Listing sites in each user's public_html ..."
echo

for u in "${USERS[@]}"; do
    _loading2 "  User: $u"
    sites_raw=$(_ssh_cmd "ls -1 /home/$u/public_html/ 2>/dev/null || true")

    if [[ -z "$sites_raw" ]]; then
        _warning "    (empty - no sites found)"
    else
        while IFS= read -r site; do
            [[ -z "$site" ]] && continue
            echo "    📁 $site"
        done <<< "$sites_raw"
    fi
    echo
done

# -----------------------------------------------------------------------------
# Step 3: Locate wp-config.php and extract DB_ constants
# -----------------------------------------------------------------------------
_loading "Step 3: Locating wp-config.php and extracting DB_ settings ..."
echo

# Build a single SSH command that finds all wp-config.php under /home/*/public_html
# and greps out DB_ defines from each
wp_config_cmd=$(cat <<'REMOTESCRIPT'
for wpconfig in $(find /home/*/public_html -maxdepth 3 -name "wp-config.php" -type f 2>/dev/null); do
    echo "===FILE=== $wpconfig"
    grep -E "define\(\s*'DB_" "$wpconfig" 2>/dev/null || echo "  (no DB_ defines found)"
done
REMOTESCRIPT
)

wp_output=$(_ssh_cmd "$wp_config_cmd")

if [[ -z "$wp_output" ]]; then
    _warning "No wp-config.php files found under /home/*/public_html"
else
    current_file=""
    while IFS= read -r line; do
        if [[ "$line" == "===FILE=== "* ]]; then
            filepath="${line#===FILE=== }"
            # Extract user and site from path: /home/<user>/public_html/<site>/wp-config.php
            user=$(echo "$filepath" | cut -d'/' -f3)
            site_path=$(echo "$filepath" | sed "s|/home/$user/public_html/||;s|/wp-config.php||")
            echo
            _success "  [$user] $site_path"
            echo "  File: $filepath"
            echo "  ─────────────────────────────────────"
        else
            # Print the DB_ define lines
            trimmed=$(echo "$line" | sed 's/^[[:space:]]*//')
            [[ -n "$trimmed" ]] && echo "    $trimmed"
        fi
    done <<< "$wp_output"
fi

echo
echo "============================================="
_success "Discovery complete."
echo "============================================="
