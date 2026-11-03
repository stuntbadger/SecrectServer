#!/usr/bin/env bash
# cli-ss — Delinea Secret Server CLI for SSH and credential management
# Usage:
#   cli-ss auth login              # interactive login
#   cli-ss auth token              # show current token info
#   cli-ss search <keyword>        # search secrets by name
#   cli-ss get <keyword>           # show secret fields for first match
#   cli-ss ssh <servername>        # SSH into a server (password via keyboard-interactive)
#   cli-ss ssh-key <servername>    # SSH using a private key from the secret
#   cli-ss passwd <servername>     # print password to stdout
#   cli-ss key <servername>        # print private key to stdout
#   cli-ss logout                  # clear cached token
#
# Environment variables:
#   SS_HOST        — Secret Server base URL, e.g. https://ss.example.com/ss
#   SS_USER        — username for authentication
#   SS_PASS        — password for authentication
#   SS_DOMAIN      — domain (optional, for Windows auth)
#   SS_TOKEN_FILE  — path to cached token (default: ~/.ss_token)
#   SS_EXPIRY_FILE — path to cached expiry (default: ~/.ss_expiry)

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────
SS_HOST="${SS_HOST:-}"
SS_USER="${SS_USER:-}"
SS_PASS="${SS_PASS:-}"
SS_DOMAIN="${SS_DOMAIN:-}"
SS_TOKEN_FILE="${SS_TOKEN_FILE:-$HOME/.ss_token}"
SS_EXPIRY_FILE="${SS_EXPIRY_FILE:-$HOME/.ss_expiry}"
COMMAND="${1:-help}"
shift 2>/dev/null || true

# ─── Helpers ──────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
cli-ss — Delinea Secret Server CLI

Usage:
  cli-ss auth login              Interactive login (stores token)
  cli-ss auth token              Show current token expiry
  cli-ss search <keyword>        Search secrets by name
  cli-ss get <keyword>           Show all fields of first match
  cli-ss ssh <servername>        SSH into a server (password via keyboard-interactive)
  cli-ss ssh-key <servername>    SSH using a private key from the secret
  cli-ss passwd <servername>     Print password to stdout
  cli-ss key <servername>        Print private key to stdout
  cli-ss logout                  Clear cached token

Environment variables:
  SS_HOST        Secret Server URL (e.g. https://ss.example.com/ss)
  SS_USER        Username
  SS_PASS        Password
  SS_DOMAIN      Domain (optional)
  SS_TOKEN_FILE  Cached token path (default: ~/.ss_token)

Prerequisites:
  curl, jq, ssh
EOF
    exit 0
}

err() {
    echo "cli-ss ERROR: $*" >&2
    exit 1
}

# Authenticate against Secret Server and cache the token
do_auth() {
    local user="$1" pass="$2" domain="${3:-}"

    [[ -z "$SS_HOST" ]] && err "SS_HOST is not set. Export it before running."
    [[ -z "$user" ]] && err "Username is empty."
    [[ -z "$pass" ]] && err "Password is empty."

    local url
    url="${SS_HOST%/}"

    local body="username=${user}&password=${pass}&grant_type=password"
    [[ -n "$domain" ]] && body="${body}&domain=${domain}"

    local resp
    resp=$(curl -s -f -X POST "${url}/oauth2/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "$body" 2>&1) || {
        echo "Authentication failed. Check credentials and host." >&2
        echo "Server response: $resp" >&2
        return 1
    }

    local token expires_in
    token=$(echo "$resp" | jq -r '.access_token' 2>/dev/null)
    expires_in=$(echo "$resp" | jq -r '.expires_in // 1200' 2>/dev/null)

    [[ "$token" == "null" || -z "$token" ]] && err "No access_token in response: $resp"

    echo -n "$token" > "$SS_TOKEN_FILE"
    local now_epoch
    now_epoch=$(date +%s)
    echo $(( now_epoch + expires_in )) > "$SS_EXPIRY_FILE"

    chmod 600 "$SS_TOKEN_FILE" "$SS_EXPIRY_FILE"
    echo "Token cached (expires in ${expires_in}s)."
    return 0
}

# Get a valid auth token — refresh if expired
get_token() {
    local token="" expires_epoch=0 now_epoch

    [[ -f "$SS_TOKEN_FILE" ]] && token=$(cat "$SS_TOKEN_FILE")
    [[ -f "$SS_EXPIRY_FILE" ]] && expires_epoch=$(cat "$SS_EXPIRY_FILE")
    now_epoch=$(date +%s)

    if [[ -z "$token" || "$now_epoch" -ge $(( expires_epoch - 60 )) ]]; then
        local auth_user="${SS_USER}"
        local auth_pass="${SS_PASS}"

        [[ -z "$auth_user" ]] && read -rp "Secret Server username: " auth_user
        [[ -z "$auth_pass" ]] && {
            read -rsp "Secret Server password: " auth_pass
            echo
        }

        do_auth "$auth_user" "$auth_pass" "$SS_DOMAIN" || exit 1
        token=$(cat "$SS_TOKEN_FILE")
    fi

    echo "$token"
}

# Search for secrets by keyword, returns "id<tab>displayname<tab>folderId"
search_secrets() {
    local keyword="$1"
    local token
    token=$(get_token)

    local url="${SS_HOST%/}/api/v1/secrets"

    local resp
    resp=$(curl -s -f "${url}?filter.includeRestricted=true&filter.searchtext=${keyword}&filter.includeinactive=true" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" 2>&1) || {
        echo "Search failed. Response: $resp" >&2
        exit 1
    }

    echo "$resp" | jq -r '.records[] | "\(.id)\t\(.displayname)\t\(.folderId)"' 2>/dev/null
}

# Fetch full details of a single secret by ID
get_secret() {
    local secret_id="$1"
    local token
    token=$(get_token)

    local url="${SS_HOST%/}/api/v1/secrets/${secret_id}"
    local resp
    resp=$(curl -s -f "${url}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" 2>&1) || {
        echo "Failed to fetch secret ${secret_id}. Response: $resp" >&2
        exit 1
    }

    echo "$resp"
}

# Get a single field value from a secret by slug
secret_field() {
    local secret_id="$1" field_slug="$2"
    local token
    token=$(get_token)

    local url="${SS_HOST%/}/api/v1/secrets/${secret_id}/fields/${field_slug}"
    local resp
    resp=$(curl -s -f "${url}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" 2>&1) || {
        echo "Failed to get field '${field_slug}' from secret ${secret_id}. Response: $resp" >&2
        exit 1
    }

    echo "$resp" | jq -r '.value'
}

# Look up a field slug by partial name match (case-insensitive) from a JSON secret object
# Usage: find_field "$data" <pattern>  (e.g. "Password" or "Username" or "Key")
find_field() {
    local data="$1" pattern="$2"
    echo "$data" | jq -r "
        .secretFields[] | select(
            (.fieldName | test(\"${pattern}\"; \"i\"))
        ) | .slug
    " 2>/dev/null | head -1
}

# ─── Sub-commands ─────────────────────────────────────────────────────────────

cmd_auth_login() {
    echo "Logging into ${SS_HOST:-[not set]}..."
    do_auth "${SS_USER}" "${SS_PASS}" "$SS_DOMAIN" || exit 1
}

cmd_auth_token() {
    local token="" expires_epoch=0 now_epoch

    if [[ -f "$SS_TOKEN_FILE" ]]; then
        token=$(cat "$SS_TOKEN_FILE")
        echo "Token: ${token:0:20}..."
    else
        echo "No cached token."
    fi

    if [[ -f "$SS_EXPIRY_FILE" ]]; then
        expires_epoch=$(cat "$SS_EXPIRY_FILE")
        now_epoch=$(date +%s)
        local remaining=$(( expires_epoch - now_epoch ))
        local dt
        dt=$(date -d "@${expires_epoch}" 2>/dev/null || date -r "${expires_epoch}" 2>/dev/null || echo "unknown")
        if [[ $remaining -gt 0 ]]; then
            echo "Expires: ${dt} (${remaining}s remaining)"
        else
            echo "EXPIRED: ${dt}"
        fi
    fi
}

cmd_search() {
    local keyword="${1:-}"
    [[ -z "$keyword" ]] && err "Usage: cli-ss search <keyword>"

    echo "Searching for '${keyword}'..."
    echo ""
    printf "%-8s %-40s %-10s\n" "ID" "DISPLAY NAME" "FOLDER"
    printf "%-8s %-40s %-10s\n" "--------" "----------------------------------------" "--------"

    local results
    results=$(search_secrets "$keyword")

    if [[ -z "$results" ]]; then
        echo "(no results)"
        return
    fi

    echo "$results" | while IFS=$'\t' read -r sid name fid; do
        printf "%-8s %-40s %-10s\n" "$sid" "${name:0:40}" "$fid"
    done
}

cmd_get() {
    local keyword="${1:-}"
    [[ -z "$keyword" ]] && err "Usage: cli-ss get <keyword>"

    local sid
    sid=$(search_secrets "$keyword" | head -1 | cut -f1)
    [[ -z "$sid" ]] && err "No secret found matching '${keyword}'"

    local data
    data=$(get_secret "$sid")

    echo "=== $(echo "$data" | jq -r '.displayname') (ID: ${sid}) ==="
    echo ""
    echo "$data" | jq -r '.secretFields[] | "\(.fieldName): \(if .value then .value else "(empty)" end)"' 2>/dev/null
}

cmd_ssh() {
    local servername="${1:-}"
    [[ -z "$servername" ]] && err "Usage: cli-ss ssh <servername>"

    local sid
    sid=$(search_secrets "$servername" | head -1 | cut -f1)
    [[ -z "$sid" ]] && err "No secret found matching '${servername}'"

    local data
    data=$(get_secret "$sid")

    # Find field slugs by pattern
    local username_field password_field hostname_field
    username_field=$(find_field "$data" "Username")
    password_field=$(find_field "$data" "Password")
    hostname_field=$(find_field "$data" "Hostname")

    # Fallbacks
    [[ -z "$username_field" ]] && username_field=$(find_field "$data" "Login")
    [[ -z "$username_field" ]] && username_field=$(find_field "$data" "User")
    [[ -z "$password_field" ]] && password_field=$(find_field "$data" "Password 2")
    [[ -z "$password_field" ]] && password_field=$(find_field "$data" "Pass")

    [[ -z "$username_field" ]] && err "Could not find username field in secret '${servername}'"
    [[ -z "$password_field" ]] && err "Could not find password field in secret '${servername}'"

    local username password
    username=$(secret_field "$sid" "$username_field")
    password=$(secret_field "$sid" "$password_field")

    [[ -z "$username" ]] && err "Username is empty for '${servername}'"
    [[ -z "$password" ]] && err "Password is empty for '${servername}'"

    local ssh_host="${servername}"
    if [[ -n "$hostname_field" ]]; then
        local hostname_val
        hostname_val=$(secret_field "$sid" "$hostname_field")
        [[ -n "$hostname_val" ]] && ssh_host="$hostname_val"
    fi

    echo "Connecting to ${ssh_host} as ${username}..."

    # Use SSH's keyboard-interactive auth with password piped via stdin.
    # No sshpass required — we pipe the password and use keyboard-interactive.
    echo "$password" | ssh \
        -o PreferredAuthentications=keyboard-interactive,password \
        -o PubkeyAuthentication=no \
        -o StrictHostKeyChecking=accept-new \
        "${username}@${ssh_host}" "$@"
}

cmd_ssh_key() {
    local servername="${1:-}"
    [[ -z "$servername" ]] && err "Usage: cli-ss ssh-key <servername>"

    local sid
    sid=$(search_secrets "$servername" | head -1 | cut -f1)
    [[ -z "$sid" ]] && err "No secret found matching '${servername}'"

    local data
    data=$(get_secret "$sid")

    local username_field key_field hostname_field passphrase_field
    username_field=$(find_field "$data" "Username")
    key_field=$(find_field "$data" "Key")
    passphrase_field=$(find_field "$data" "Passphrase")
    hostname_field=$(find_field "$data" "Hostname")

    [[ -z "$username_field" ]] && err "Could not find username field in secret '${servername}'"
    [[ -z "$key_field" ]] && err "Could not find private key field in secret '${servername}'"

    local username key_content
    username=$(secret_field "$sid" "$username_field")
    key_content=$(secret_field "$sid" "$key_field")

    [[ -z "$username" ]] && err "Username is empty for '${servername}'"
    [[ -z "$key_content" ]] && err "Private key is empty for '${servername}'"

    local ssh_host="${servername}"
    if [[ -n "$hostname_field" ]]; then
        local hostname_val
        hostname_val=$(secret_field "$sid" "$hostname_field")
        [[ -n "$hostname_val" ]] && ssh_host="$hostname_val"
    fi

    # Write key to a temp file
    local tmp_key
    tmp_key=$(mktemp)
    trap "rm -f '$tmp_key'" EXIT

    chmod 600 "$tmp_key"
    printf '%s\n' "$key_content" > "$tmp_key"

    local ssh_args=(-o StrictHostKeyChecking=accept-new -i "$tmp_key")

    if [[ -n "$passphrase_field" ]]; then
        local passphrase
        passphrase=$(secret_field "$sid" "$passphrase_field")
        [[ -n "$passphrase" ]] && ssh_args+=(-o "PassPhrase=$passphrase" -o "BatchMode=no")
    fi

    ssh_args+=("${username}@${ssh_host}")

    echo "Connecting to ${ssh_host} as ${username} (key auth)..."
    exec ssh "${ssh_args[@]}" "$@"
}

cmd_passwd() {
    local servername="${1:-}"
    [[ -z "$servername" ]] && err "Usage: cli-ss passwd <servername>"

    local sid
    sid=$(search_secrets "$servername" | head -1 | cut -f1)
    [[ -z "$sid" ]] && err "No secret found matching '${servername}'"

    local data
    data=$(get_secret "$sid")

    local pw_field
    pw_field=$(find_field "$data" "Password")
    [[ -z "$pw_field" ]] && pw_field=$(find_field "$data" "Pass")

    [[ -z "$pw_field" ]] && err "Could not find password field in secret '${servername}'"

    secret_field "$sid" "$pw_field"
}

cmd_key() {
    local servername="${1:-}"
    [[ -z "$servername" ]] && err "Usage: cli-ss key <servername>"

    local sid
    sid=$(search_secrets "$servername" | head -1 | cut -f1)
    [[ -z "$sid" ]] && err "No secret found matching '${servername}'"

    local data
    data=$(get_secret "$sid")

    local key_field
    key_field=$(find_field "$data" "Key")

    [[ -z "$key_field" ]] && err "Could not find key field in secret '${servername}'"

    secret_field "$sid" "$key_field"
}

cmd_logout() {
    rm -f "$SS_TOKEN_FILE" "$SS_EXPIRY_FILE"
    echo "Token cleared."
}

cmd_help() {
    usage
}

# ─── Dispatch ─────────────────────────────────────────────────────────────────

case "$COMMAND" in
    auth)
        SUB="${1:-help}"
        case "$SUB" in
            login)  cmd_auth_login ;;
            token)  cmd_auth_token ;;
            *)      echo "Usage: cli-ss auth {login|token}" >&2; exit 1 ;;
        esac
        ;;
    search)   cmd_search "$@" ;;
    get)      cmd_get "$@" ;;
    ssh)      cmd_ssh "$@" ;;
    ssh-key)  cmd_ssh_key "$@" ;;
    passwd)   cmd_passwd "$@" ;;
    key)      cmd_key "$@" ;;
    logout)   cmd_logout ;;
    help|--help|-h) cmd_help ;;
    *)
        err "Unknown command '${COMMAND}'. Run 'cli-ss help' for usage."
        ;;
esac
