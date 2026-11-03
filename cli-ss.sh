#!/usr/bin/env bash
# cli-ss — Delinea Secret Server CLI for SSH and credential management
# Usage:
#   cli-ss auth login              # interactive login
#   cli-ss auth token              # show current token info
#   cli-ss templates               # list available secret templates
#   cli-ss templates <templateId>  # show fields for a template
#   cli-ss search <keyword>        # search secrets by name
#   cli-ss get <keyword>           # show secret fields for first match
#   cli-ss ssh <servername>        # SSH into a server (password via keyboard-interactive)
#   cli-ss ssh-key <servername>    # SSH using a private key from the secret
#   cli-ss passwd <servername>     # print password to stdout
#   cli-ss key <servername>        # print private key to stdout
#   cli-ss create                  # create a new secret from a template
#   cli-ss delete <keyword>        # delete a secret by search match
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
  cli-ss templates               List all secret templates
  cli-ss templates <templateId>  Show fields required by a template
  cli-ss search <keyword>        Search secrets by name
  cli-ss get <keyword>           Show all fields of first match
  cli-ss ssh <servername>        SSH into a server (password via keyboard-interactive)
  cli-ss ssh-key <servername>    SSH using a private key from the secret
  cli-ss passwd <servername>     Print password to stdout
  cli-ss key <servername>        Print private key to stdout
  cli-ss create                  Create a new secret from a template
  cli-ss delete <keyword>        Delete a secret by search match
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

# ─── Templates ────────────────────────────────────────────────────────────────

cmd_templates() {
    local token
    token=$(get_token)

    if [[ $# -gt 0 && "$1" != "--help" ]]; then
        # Show fields for a specific template
        local tid="$1"
        local url="${SS_HOST%/}/api/v1/secret-templates/${tid}/fields"
        local resp
        resp=$(curl -s -f "${url}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" 2>&1) || {
            echo "Failed to fetch template fields for ID ${tid}. Response: $resp" >&2
            exit 1
        }

        local name
        name=$(echo "$resp" | jq -r '.name // "unknown"')
        echo "=== Template: ${name} (ID: ${tid}) ==="
        echo ""
        echo "$resp" | jq -r '.fields[] | "  [\(.fieldId)] \(.name) (\(.slug)) — \(.type)  \(.description // "")"' 2>/dev/null

        # Also show the stub format needed to create secrets with this template
        echo ""
        echo "Stub structure for create:"
        local stub
        stub=$(curl -s -f "${SS_HOST%/}/api/v1/secrets/stub?filter.secrettemplateid=${tid}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" 2>&1) || {
            echo "Failed to fetch stub." >&2
            exit 1
        }
        echo "$stub" | jq '.items[] | {fieldId, name: .fieldName, slug, type: .type}' 2>/dev/null

    else
        # List all templates
        local url="${SS_HOST%/}/api/v1/secret-templates"
        local resp
        resp=$(curl -s -f "${url}?filter.includeinactive=true" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" 2>&1) || {
            echo "Failed to fetch templates. Response: $resp" >&2
            exit 1
        }

        echo "Available secret templates:"
        echo ""
        printf "%-6s %-40s %-15s\n" "ID" "NAME" "RECORDS"
        printf "%-6s %-40s %-15s\n" "------" "----------------------------------------" "-------"

        echo "$resp" | jq -r '.records[] | "\(.id)\t\(.name)\t\(.secretRecordCount // 0)"' 2>/dev/null | while IFS=$'\t' read -r tid tname tcount; do
            printf "%-6s %-40s %-15s\n" "$tid" "${tname:0:40}" "$tcount"
        done
    fi
}

# ─── Create ───────────────────────────────────────────────────────────────────

cmd_create() {
    local name="" tid="" fid=""
    local -A field_vals=()
    local gen_password=false
    local prompt_user=true

    # Parse args: --name, --template, --folder, --fields, --password, --no-prompt
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)     name="$2"; shift 2 ;;
            --template) tid="$2"; shift 2 ;;
            --folder)   fid="$2"; shift 2 ;;
            --fields)
                IFS=',' read -ra pairs <<< "$2"
                for pair in "${pairs[@]}"; do
                    local key="${pair%%=*}"
                    local val="${pair#*=}"
                    field_vals["$key"]="$val"
                done
                shift 2 ;;
            --password)
                if [[ "$2" == "gen" || "$2" == "generate" ]]; then
                    gen_password=true
                    shift 2
                elif [[ "$2" == "auto" ]]; then
                    gen_password=true
                    shift 2
                else
                    echo "Usage: cli-ss create --password gen|auto" >&2
                    exit 1
                fi
                ;;
            --no-prompt)
                prompt_user=false
                shift ;;
            --help|-h)
                cat <<'EOF'
cli-ss create — Create a new secret from a template

Usage:
  cli-ss create --name "My Secret" --template 6001 [options]

Options:
  --name <name>          Secret display name (required)
  --template <id>        Secret template ID (required; use 'cli-ss templates' to list)
  --folder <id>          Folder ID (optional, defaults to template default)
  --fields <k=v,...>     Field values as comma-separated key=value pairs.
                         Keys can be field names (e.g. "Username=admin,Password=s3cret")
                         or field slugs.
  --password gen|auto    Auto-generate passwords for all password-type fields.
  --no-prompt            Skip interactive prompts; fail if fields missing.
  --help                 Show this help.

Examples:
  cli-ss create --name "web01" --template 6001 --fields "Username=admin,Password=mypass"
  cli-ss create --name "db01" --template 6001 --password gen
  cli-ss create --name "host01" --template 6001 --fields "Hostname=10.0.0.1" --password gen
EOF
                exit 0
                ;;
            *)
                err "Unknown option '$1'. Run 'cli-ss create --help' for usage." ;;
        esac
    done

    [[ -z "$name" ]] && err "--name is required"
    [[ -z "$tid" ]] && err "--template is required (use 'cli-ss templates' to list)"

    # Fetch stub for the template
    local token
    token=$(get_token)
    local stub
    stub=$(curl -s -f "${SS_HOST%/}/api/v1/secrets/stub?filter.secrettemplateid=${tid}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" 2>&1) || {
        echo "Failed to fetch template stub for ID ${tid}. Response: $stub" >&2
        exit 1
    }

    local folder_id
    folder_id=$(echo "$stub" | jq -r '.folderId // empty' 2>/dev/null)
    [[ -z "$folder_id" ]] && folder_id="${fid}"
    [[ -z "$folder_id" ]] && {
        read -rp "Folder ID (default 1): " folder_id
        folder_id="${folder_id:-1}"
    }

    # Build field name->slug mapping and collect field details
    declare -A slug_type=()
    declare -A slug_fname=()
    declare -a field_slugs=()
    while IFS=$'\t' read -r s t n; do
        slug_type["$s"]="$t"
        slug_fname["$s"]="$n"
        field_slugs+=("$s")
    done < <(echo "$stub" | jq -r '.items[] | "\(.slug)\t\(.type // "string")\t\(.fieldName)"' 2>/dev/null)

    # Collect values for each field
    local -A resolved=()
    for slug in "${field_slugs[@]}"; do
        # Check if user provided a value (by slug or by field name lookup)
        local val="${field_vals[$slug]:-}"
        if [[ -z "$val" ]]; then
            # Try matching by field name from stub
            local fname="${slug_fname[$slug]:-}"
            val="${field_vals[$fname]:-}"
        fi

        if [[ -z "$val" ]]; then
            # Auto-generate passwords if requested
            if $gen_password; then
                local stype="${slug_type[$slug]:-}"
                if [[ "$stype" == *"password"* ]]; then
                    val=$(openssl rand -base64 16 2>/dev/null | tr -d '+/\n=' | head -c 20)
                fi
            fi
        fi

        if [[ -z "$val" ]]; then
            if $prompt_user; then
                local fname="${slug_fname[$slug]:-${slug}}"
                local stype="${slug_type[$slug]:-string}"
                local prompt_text="${fname}:"
                if [[ "$stype" == *"password"* ]]; then
                    read -rsp "  ${prompt_text} : " val
                    echo
                else
                    read -rp "  ${prompt_text} : " val
                fi
            else
                err "No value provided for field '${slug}' and --no-prompt is set"
            fi
        fi
        resolved["$slug"]="$val"
    done

    # Build JSON payload from stub, replacing itemValues with user-provided values
    # Create the resolved values JSON object for jq
    local resolved_json="{}"
    for slug in "${field_slugs[@]}"; do
        resolved_json=$(echo "$resolved_json" | jq --arg k "$slug" --arg v "${resolved[$slug]}" '. + {($k): $v}')
    done

    local payload
    payload=$(echo "$stub" | jq \
        --arg name "$name" \
        --arg folder "$folder_id" \
        --arg tid "$tid" \
        --argjson resolved "$resolved_json" \
        '
        .name = $name |
        .secretTemplateId = ($tid | tonumber) |
        .folderId = ($folder | tonumber) |
        .SiteId = 1 |
        .items = [.items[] | .itemValue = ($resolved[.slug] // .itemValue)]
    ')

    # Create the secret
    local url="${SS_HOST%/}/api/v1/secrets"
    local resp
    resp=$(curl -s -f -X POST "${url}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1) || {
        echo "Failed to create secret. Response: $resp" >&2
        exit 1
    }

    local new_id
    new_id=$(echo "$resp" | jq -r '.id')
    local new_name
    new_name=$(echo "$resp" | jq -r '.displayname')

    echo "Created secret: ${new_name} (ID: ${new_id})"
    echo "  Template:    ${tid}"
    echo "  Folder:      ${folder_id}"
    echo "  Name:        ${name}"
}

# ─── Delete ───────────────────────────────────────────────────────────────────

cmd_delete() {
    local keyword="${1:-}"
    [[ -z "$keyword" ]] && err "Usage: cli-ss delete <keyword>"

    local sid name
    sid=$(search_secrets "$keyword" | head -1 | cut -f1)
    [[ -z "$sid" ]] && err "No secret found matching '${keyword}'"

    name=$(search_secrets "$keyword" | head -1 | cut -f2)

    read -rp "Are you sure you want to delete '${name}' (ID: ${sid})? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

    local token
    token=$(get_token)

    local url="${SS_HOST%/}/api/v1/secrets/${sid}"
    local resp
    resp=$(curl -s -f -X DELETE "${url}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" 2>&1) || {
        echo "Failed to delete secret ${sid}. Response: $resp" >&2
        exit 1
    }

    echo "Deleted: ${name} (ID: ${sid})"
}

# ─── Existing commands ────────────────────────────────────────────────────────

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
    templates)  cmd_templates "$@" ;;
    create)     cmd_create "$@" ;;
    search)     cmd_search "$@" ;;
    get)        cmd_get "$@" ;;
    ssh)        cmd_ssh "$@" ;;
    ssh-key)    cmd_ssh_key "$@" ;;
    passwd)     cmd_passwd "$@" ;;
    key)        cmd_key "$@" ;;
    delete)     cmd_delete "$@" ;;
    logout)     cmd_logout ;;
    help|--help|-h) cmd_help ;;
    *)
        err "Unknown command '${COMMAND}'. Run 'cli-ss help' for usage."
        ;;
esac
