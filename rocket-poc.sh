#!/usr/bin/env bash
# =============================================================================
# rocket-poc.sh - Rocket.net server discovery POC
# =============================================================================
# Discover users, sites, and WordPress DB config on a Rocket.net server
# via SSH. Uses multiple enumeration strategies to work from a restricted
# (non-root) user context where /home/* glob may be blocked.
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
    echo "Works from restricted (non-root) SSH sessions by using multiple strategies:"
    echo "  1. /etc/passwd to enumerate system users"
    echo "  2. Nginx/Apache vhost configs for site->path mappings"
    echo "  3. Direct probing of discovered user home dirs"
    echo "  4. wp-config.php DB_ extraction for each discovered site"
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
    echo "  $0 -h 203.0.113.10 -u dp6nxud -p 22 -v"
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

_verbose() {
    [[ "$VERBOSE" == "1" ]] && echo -e "  \e[1;30m[verbose] $1\e[0m"
}

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

echo "============================================="
echo " Rocket.net Server Discovery POC"
echo " Host: $SSH_USER@$SSH_HOST:$SSH_PORT"
echo "============================================="
echo

# =============================================================================
# Step 1: Enumerate users via multiple strategies
# =============================================================================
_loading "Step 1: Enumerating users (multiple strategies) ..."
echo

declare -a USERS=()
declare -A USER_SOURCES=()  # track how each user was discovered

# -- Strategy 1a: /etc/passwd (almost always world-readable)
_loading2 "  1a. Reading /etc/passwd for /home users ..."
passwd_users=$(_ssh_cmd "awk -F: '\$6 ~ /^\/home\// && \$7 !~ /nologin|false/ {print \$1}' /etc/passwd 2>/dev/null || true")
if [[ -n "$passwd_users" ]]; then
    while IFS= read -r u; do
        [[ -z "$u" ]] && continue
        if [[ -z "${USER_SOURCES[$u]+x}" ]]; then
            USERS+=("$u")
            USER_SOURCES[$u]="/etc/passwd"
        fi
    done <<< "$passwd_users"
    _success "    Found $(echo "$passwd_users" | wc -l | tr -d ' ') user(s) from /etc/passwd"
else
    _warning "    /etc/passwd not readable or no /home users found"
fi

# -- Strategy 1b: ls /home/ directory listing
_loading2 "  1b. Listing /home/ directory ..."
home_dirs=$(_ssh_cmd "ls -1 /home/ 2>/dev/null || true")
if [[ -n "$home_dirs" ]]; then
    while IFS= read -r u; do
        [[ -z "$u" ]] && continue
        if [[ -z "${USER_SOURCES[$u]+x}" ]]; then
            USERS+=("$u")
            USER_SOURCES[$u]="/home/ listing"
        else
            USER_SOURCES[$u]="${USER_SOURCES[$u]}, /home/ listing"
        fi
    done <<< "$home_dirs"
    _success "    Found $(echo "$home_dirs" | wc -l | tr -d ' ') entries in /home/"
else
    _warning "    /home/ not listable"
fi

# -- Strategy 1c: Nginx vhost configs (discover domains + webroots)
_loading2 "  1c. Scanning Nginx/Apache vhost configs ..."
vhost_users=$(_ssh_cmd "cat /etc/nginx/sites-enabled/* /etc/nginx/conf.d/* /etc/apache2/sites-enabled/* 2>/dev/null | grep -oP '(?<=/home/)[^/]+' | sort -u || true")
if [[ -n "$vhost_users" ]]; then
    while IFS= read -r u; do
        [[ -z "$u" ]] && continue
        if [[ -z "${USER_SOURCES[$u]+x}" ]]; then
            USERS+=("$u")
            USER_SOURCES[$u]="vhost configs"
        else
            USER_SOURCES[$u]="${USER_SOURCES[$u]}, vhost configs"
        fi
    done <<< "$vhost_users"
    _success "    Found user(s) from vhost configs"
else
    _verbose "    No vhost configs readable"
fi

# -- Strategy 1d: Direct glob (works if root or permissive)
_loading2 "  1d. Trying /home/*/public_html glob ..."
glob_users=$(_ssh_cmd "ls -d /home/*/public_html 2>/dev/null | sed 's|/home/||;s|/public_html||' || true")
if [[ -n "$glob_users" ]]; then
    while IFS= read -r u; do
        [[ -z "$u" ]] && continue
        if [[ -z "${USER_SOURCES[$u]+x}" ]]; then
            USERS+=("$u")
            USER_SOURCES[$u]="glob"
        else
            USER_SOURCES[$u]="${USER_SOURCES[$u]}, glob"
        fi
    done <<< "$glob_users"
    _success "    Glob succeeded"
else
    _verbose "    /home/*/public_html glob blocked"
fi

echo
if [[ ${#USERS[@]} -eq 0 ]]; then
    _error "No users discovered via any strategy."
    exit 1
fi

_success "Discovered ${#USERS[@]} unique user(s):"
echo
printf "  %-25s %s\n" "USER" "DISCOVERED VIA"
printf "  %-25s %s\n" "----" "--------------"
for u in "${USERS[@]}"; do
    printf "  %-25s %s\n" "$u" "${USER_SOURCES[$u]}"
done
echo

# =============================================================================
# Step 2: Probe each user's public_html for sites
# =============================================================================
_loading "Step 2: Probing public_html for each user ..."
echo

declare -A USER_SITES=()  # user -> newline-separated site list

for u in "${USERS[@]}"; do
    _loading2 "  User: $u"

    # Try to list public_html contents
    sites_raw=$(_ssh_cmd "ls -1 /home/$u/public_html/ 2>/dev/null || true")

    if [[ -z "$sites_raw" ]]; then
        # Try alternate webroot paths (Rocket.net may use different structures)
        for alt_path in "/home/$u/www" "/home/$u/htdocs" "/home/$u/webapps"; do
            alt_raw=$(_ssh_cmd "ls -1 $alt_path/ 2>/dev/null || true")
            if [[ -n "$alt_raw" ]]; then
                _verbose "    Found sites at $alt_path instead"
                sites_raw="$alt_raw"
                break
            fi
        done
    fi

    if [[ -z "$sites_raw" ]]; then
        _warning "    Cannot access public_html (permission denied or empty)"
    else
        USER_SITES[$u]="$sites_raw"
        while IFS= read -r site; do
            [[ -z "$site" ]] && continue
            echo "    📁 $site"
        done <<< "$sites_raw"
    fi
    echo
done

# =============================================================================
# Step 3: Also pull domain->webroot mappings from Nginx if available
# =============================================================================
_loading "Step 3: Extracting domain->webroot maps from Nginx configs ..."
echo

# Single SSH call to extract server_name + root pairs from nginx
nginx_map=$(_ssh_cmd "grep -rh 'server_name\|root ' /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null | paste - - | sed 's/;//g' | awk '{print \$2, \$4}' | sort -u || true")

if [[ -n "$nginx_map" ]]; then
    printf "  %-40s %s\n" "DOMAIN" "WEBROOT"
    printf "  %-40s %s\n" "------" "-------"
    while IFS= read -r line; do
        domain=$(echo "$line" | awk '{print $1}')
        webroot=$(echo "$line" | awk '{print $2}')
        [[ -z "$domain" || "$domain" == "_" ]] && continue
        printf "  %-40s %s\n" "$domain" "$webroot"
    done <<< "$nginx_map"
else
    _warning "  Nginx configs not readable — skipping"
fi
echo

# =============================================================================
# Step 4: Locate wp-config.php and extract DB_ constants
# =============================================================================
_loading "Step 4: Locating wp-config.php and extracting DB_ settings ..."
echo

# Build a remote command that tries multiple approaches to find wp-config.php
wp_config_cmd=$(cat <<'REMOTESCRIPT'
found=0

# Method A: find across /home (may fail on restricted users)
for wpconfig in $(find /home/*/public_html -maxdepth 3 -name "wp-config.php" -type f 2>/dev/null); do
    found=1
    echo "===FILE=== $wpconfig"
    grep -E "define\(\s*'DB_" "$wpconfig" 2>/dev/null || echo "  (no DB_ defines found)"
done

# Method B: if Method A found nothing, try probing known users from /etc/passwd
if [ "$found" -eq 0 ]; then
    for user_home in $(awk -F: '$6 ~ /^\/home\// && $7 !~ /nologin|false/ {print $6}' /etc/passwd 2>/dev/null); do
        for search_root in "$user_home/public_html" "$user_home/www" "$user_home/htdocs"; do
            for wpconfig in $(find "$search_root" -maxdepth 3 -name "wp-config.php" -type f 2>/dev/null); do
                found=1
                echo "===FILE=== $wpconfig"
                grep -E "define\(\s*'DB_" "$wpconfig" 2>/dev/null || echo "  (no DB_ defines found)"
            done
        done
    done
fi

# Method C: try locate if available
if [ "$found" -eq 0 ]; then
    for wpconfig in $(locate wp-config.php 2>/dev/null | grep '/home/' | head -50); do
        [ -r "$wpconfig" ] || continue
        found=1
        echo "===FILE=== $wpconfig"
        grep -E "define\(\s*'DB_" "$wpconfig" 2>/dev/null || echo "  (no DB_ defines found)"
    done
fi

# Method D: try extracting DB info from nginx root paths
if [ "$found" -eq 0 ]; then
    for webroot in $(grep -rh 'root ' /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null | sed 's/;//g' | awk '{print $2}' | sort -u); do
        wpconfig="$webroot/wp-config.php"
        [ -r "$wpconfig" ] || continue
        found=1
        echo "===FILE=== $wpconfig"
        grep -E "define\(\s*'DB_" "$wpconfig" 2>/dev/null || echo "  (no DB_ defines found)"
    done
fi

[ "$found" -eq 0 ] && echo "===NONE==="
REMOTESCRIPT
)

wp_output=$(_ssh_cmd "$wp_config_cmd")

if [[ -z "$wp_output" || "$wp_output" == "===NONE===" ]]; then
    _warning "No readable wp-config.php files found via any method"
else
    while IFS= read -r line; do
        if [[ "$line" == "===FILE=== "* ]]; then
            filepath="${line#===FILE=== }"
            # Extract user and site from path
            user=$(echo "$filepath" | awk -F/ '{print $3}')
            site_path=$(echo "$filepath" | sed "s|.*public_html/||;s|.*www/||;s|.*htdocs/||;s|/wp-config.php||")
            echo
            _success "  [$user] $site_path"
            echo "  File: $filepath"
            echo "  ─────────────────────────────────────"
        elif [[ "$line" != "===NONE===" ]]; then
            trimmed=$(echo "$line" | sed 's/^[[:space:]]*//')
            [[ -n "$trimmed" ]] && echo "    $trimmed"
        fi
    done <<< "$wp_output"
fi

echo
echo "============================================="
_success "Discovery complete."
echo "============================================="
