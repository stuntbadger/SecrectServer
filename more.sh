#!/bin/bash
#Enviroment setting
TOKEN="AgIYgipII47eqZk-ctYV-pIeam7UDthScYN5vkeY0a26uSxqZVvllYhyeUTqQvvs9fUq1ij_0cK91rkkqRIlhdPDPMuI7H9AhstPZuLn0nnw3HxNjFfGkh2Sm6T841U2pcpepgIOeJoArKaJVqFTFv4kSo1T8TXSPQuf6GfPAdfSyO0ykKFh_d50oEbNwGOGAZbXfu4xIQoUDePIPMjewDQG8R8yENjInXn4tQE2GwgJgnepYswD7Eni6oehdgLaWa3w_KeJaLeCSCSHU4MtpsyS05KWed0kS4rdEdxeoy7EmdEHCmCbZPH-VWetF0vJNt8p4rNUgPDN7PYex5zyTPzfbhrbNkw-6NO0Z9c0twwQMUzKn1tGd4dy-7i2RriSyEgGBz0WFm7MYcJFXpdVmasXmKrjph17kEJ74ut8TRd8KGGFRStIvuQTX1m0AtunChz1T61Srd7t8gvC51VBq-oiiAWOMim-NOCUxwFBCnQGvP3c870g2mnLSzsfCqEzc6MdPHU4Qyk23Rqb3XhjFiUM4KOKdnFXSfgZ3dGHJHEkvdF07oWP2lJv0j4NSr9CJBvQO7JSkTvnlPEXg9QRiYYHKQUjFXjnWGFDrPx-9mVwBbWh5SFCuFfv7__PEXiBJe7WlSXPHSwugFtJ-Bzkaf9w6PeBgXoy2815mevCJSGP_w"

SS_URL="https://secretserver.example.com/SecretServer"

COMMAND="${1:-help}"

#this was only bringing back the first one in the list great if you know the exact hostname but otherwise useless
#cmd_search (){
#    local keyword="$1"
#    [[ -z "$keyword" ]] && err "Usage: cli-ss search <keyword>"
#    HOSTNAME="$2"
#    #HOSTNAME="tower_admin"

#    SECRET_ID=$(curl -sk \
#    -H "Authorization: Bearer $TOKEN" \
#    "$SS_URL/api/v1/secrets?filter.searchText=$HOSTNAME" \
#    | jq -r '.records[0].id')

#    curl -sk \
#    -H "Authorization: Bearer $TOKEN" \
#    "$SS_URL/api/v1/secrets/$SECRET_ID" \
#    | jq -r '.items[] | "\(.fieldName): \(.itemValue)"'
#}

cmd_search() {
    local HOSTNAME="$2"

    [[ -z "$HOSTNAME" ]] && err "Usage: cli-ss search <keyword>"

    curl -sk \
        -H "Authorization: Bearer $TOKEN" \
        "$SS_URL/api/v1/secrets?filter.searchText=$HOSTNAME" \
    | jq -r '.records[].id' |
    while read -r SECRET_ID
    do
        echo "===== Secret ID: $SECRET_ID ====="

        curl -sk \
            -H "Authorization: Bearer $TOKEN" \
            "$SS_URL/api/v1/secrets/$SECRET_ID" \
        | jq -r '.items[] | "\(.fieldName): \(.itemValue)"'

        echo
    done
}


cmd_passwd() {
    local HOSTNAME="$2"

    [[ -z "$HOSTNAME" ]] && err "Usage: cli-ss passwd <hostname>"

    SECRET_ID=$(curl -sk \
        -H "Authorization: Bearer $TOKEN" \
        "$SS_URL/api/v1/secrets?filter.searchText=$HOSTNAME" \
        | jq -r '.records[0].id')

    curl -sk \
        -H "Authorization: Bearer $TOKEN" \
        "$SS_URL/api/v1/secrets/$SECRET_ID" \
        | jq -r '.items[] | select(.fieldName=="Password") | .itemValue'
}

#testing function
detail_search (){
curl -sk -H "Authorization: Bearer $TOKEN" "$SS_URL/api/v1/secrets?filter.searchText=tower" | jq .
}


#Help page
usage() {
    cat <<'EOF'
ss-cli — Delinea Secret Server CLI

Usage:
  cli-ss search <keyword>        Search secrets by name
  cli-ss passwd <servername>     Print password to stdout


Prerequisites:
  curl, jq, ssh
EOF
    exit 0
}

err() {
    echo "ss-cli ERROR: $*" >&2
    exit 1
}


cmd_help() {
    usage
}


#Main Case statement
case "$COMMAND" in
    search)   cmd_search "$@" ;;
    passwd)   cmd_passwd "$@" ;;
    help|--help|-h) cmd_help ;;
    *)
        err "Unknown command '${COMMAND}'. Run 'ss-cli help' for usage."
        ;;
esac
