!/usr/bin/env bash
set -euo pipefail
# ── Config ──────────────────────────────────────────────────────
SS_HOST="${SS_HOST:?Set SS_HOST to your Secret Server base URL (e.g. https://ss.example.com/SecretServer)}"
SS_USER="${SS_USER:?Set SS_USER to your username}"
SS_PASS="${SS_PASS:-}"
SS_TOKEN_FILE="${SS_TOKEN_FILE:-$HOME/.ss_token}"
SS_EXPIRY_FILE="${SS_EXPIRY_FILE:-$HOME/.ss_expiry}"
# ── Auth with OTP ───────────────────────────────────────────────
auth() {
    local pass=""
    if [[ -n "$SS_PASS" ]]; then
        pass="$SS_PASS"
    else
        read -rs 'pass="Password: "' && echo
    fi
    local otp=""
    read -rs 'otp="Enter OTP: "' && echo
    local domain_param=""
    if [[ -n "${SS_DOMAIN:-}" ]]; then
        domain_param="&domain=${SS_DOMAIN}"
    fi
    local response
    response=$(curl -s -f -w "\n%{http_code}" \
        -X POST "${SS_HOST%/}/oauth2/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "OTP: ${otp}" \
        -d "username=${SS_USER}&password=${pass}&grant_type=password${domain_param}")
    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')
    if [[ "$http_code" -eq 200 ]]; then
        local access_token expires_in
        access_token=$(echo "$body" | jq -r '.access_token')
        expires_in=$(echo "$body" | jq -r '.expires_in')
        local expires_epoch
        expires_epoch=$(( $(date +%s) + expires_in ))
        echo "$access_token" > "$SS_TOKEN_FILE"
        chmod 600 "$SS_TOKEN_FILE"
        echo "$expires_epoch" > "$SS_EXPIRY_FILE"
        chmod 600 "$SS_EXPIRY_FILE"
        echo "$access_token"
    else
        echo "Auth failed (HTTP $http_code): $(echo "$body" | jq -r '.error // .error_description // "unknown"' 2>/dev/null || echo "$body")" >&2
        return 1
    fi
}
# ── Auto-refresh token (re-prompt only when expired) ────────────
get_token() {
    local token="" expires_epoch=0 now_epoch
    [[ -f "$SS_TOKEN_FILE" ]] && token=$(cat "$SS_TOKEN_FILE")
    [[ -f "$SS_EXPIRY_FILE" ]] && expires_epoch=$(cat "$SS_EXPIRY_FILE")
    now_epoch=$(date +%s)
    if [[ -z "$token" || "$now_epoch" -ge $(( expires_epoch - 60 )) ]]; then
        auth
    else
        echo "$token"
    fi
}
# ── Get a secret field value ────────────────────────────────────
get_secret() {
    local secret_id="$1"
    local field_slug="${2:-}"
    local token
    token=$(get_token)
    if [[ -n "$field_slug" ]]; then
        curl -s -f "${SS_HOST%/}/api/v1/secrets/${secret_id}/fields/${field_slug}" \
            -H "Authorization: Bearer ${token}" | jq -r '.value'
    else
        curl -s -f "${SS_HOST%/}/api/v1/secrets/${secret_id}" \
            -H "Authorization: Bearer ${token}" | jq '.'
    fi
}
# ── Search secrets ──────────────────────────────────────────────
search_secrets() {
    local keyword="${1:-}"
    local token
    token=$(get_token)
    curl -s -f "${SS_HOST%/}/api/v1/secrets?filter.includeRestricted=true&filter.searchtext=${keyword}&filter.includeinactive=true" \
        -H "Authorization: Bearer ${token}" | jq -r '.records[] | "\(.id)\t\(.displayname)\t\(.folderId)"'
}
# ── Logout ──────────────────────────────────────────────────────
logout() {
    rm -f "$SS_TOKEN_FILE" "$SS_EXPIRY_FILE"
    echo "Token cache removed."
}
# ── Main ────────────────────────────────────────────────────────
COMMAND="${1:-help}"
shift 2>/dev/null || true
case "$COMMAND" in
    auth)       auth ;;
    token)      get_token ;;
    secret)     get_secret "$@" ;;
    search)     search_secrets "$@" ;;
    logout)     logout ;;
    help|*)
        echo "Usage: $0 <command> [args]"
        echo ""
        echo "Commands:"
        echo "  auth              Authenticate (prompts for password + OTP)"
        echo "  token             Get/cached access token"
        echo "  secret <id> [slug]  Get secret (or specific field by slug)"
        echo "  search <keyword>    Search secrets"
        echo "  logout            Clear cached token"
        ;;
esac
