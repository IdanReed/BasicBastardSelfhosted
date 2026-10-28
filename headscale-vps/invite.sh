#!/usr/bin/env bash
#
# Mint an Authentik invitation and print its link.
#
# Usage: ./invite.sh <username> <email> [display name]
#
# The invitation is single-use, expires in 7 days, and fixes the username and
# email: the enrollment flow (authentik/blueprints/custom/invite-enrollment.yaml)
# shows both read-only and writes only these. The invitee picks their own
# password and sets up TOTP in the flow, so no credential passes through here.
#
# Runs on the VPS over ssh: the API calls go to Authentik's loopback listener
# with the bootstrap token, which never leaves the host. INVITE_SSH_HOST
# overrides the ssh target (default `vps`, the desktop's ssh alias). The
# authentik suite runs the REMOTE heredoc as-is against a real Authentik, so
# keep its delimiters exactly as they are.

set -euo pipefail

usage() {
    echo "Usage: $0 <username> <email> [display name]" >&2
    exit 2
}
[[ $# -ge 2 && $# -le 3 ]] || usage
username=$1
email=$2
name=${3:-$1}

# Every app takes the username as its own login name; keep it to the subset
# all of them accept.
if [[ ! $username =~ ^[a-z][a-z0-9_-]{1,31}$ ]]; then
    echo "username must match ^[a-z][a-z0-9_-]{1,31}\$: $username" >&2
    exit 2
fi
if [[ ! $email =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    echo "not an email address: $email" >&2
    exit 2
fi
if [[ $name == *$'\n'* || -z $name ]]; then
    usage
fi

host=${INVITE_SSH_HOST:-vps}

# The arguments reach the remote script as positional parameters, %q-quoted
# for the remote shell; nothing is spliced into the script text.
# shellcheck disable=SC2029
ssh "$host" "sudo bash -s -- $(printf '%q ' "$username" "$email" "$name")" <<'REMOTE'
set -euo pipefail
username=$1
email=$2
name=$3

api=http://127.0.0.1:9000/api/v3
base=https://auth.idanreed.com
flow_slug=invite-enrollment

# The token goes to curl as a header file, never as an argument.
hdr=$(mktemp)
trap 'rm -f "$hdr"' EXIT
printf 'Authorization: Bearer %s\n' "$(cat /run/secrets/AUTHENTIK_BOOTSTRAP_TOKEN)" > "$hdr"
ak() {
    curl -sS --fail-with-body --max-time 20 -H @"$hdr" \
        -H 'Content-Type: application/json' "$@"
}

flow_pk=$(ak "$api/flows/instances/$flow_slug/" | jq -er .pk) || {
    echo "no '$flow_slug' flow: has invite-enrollment.yaml applied on this host?" >&2
    exit 1
}

# Usernames are unique in Authentik; emails are not, but apps link logins to
# local accounts by email, so a second account on one address is refused too.
taken=$(ak "$api/core/users/?page_size=1000" | jq -r --arg u "$username" --arg e "$email" \
    '[.results[] | select(.username == $u or ((.email // "") | ascii_downcase) == ($e | ascii_downcase))
      | "\(.username) <\(.email)>"] | join(", ")')
if [[ -n $taken ]]; then
    echo "already an account: $taken" >&2
    exit 1
fi

# An unused invitation for the same username is reprinted, not duplicated.
existing=$(ak "$api/stages/invitation/invitations/?flow__slug=$flow_slug&page_size=1000" |
    jq -r --arg u "$username" \
        '[.results[] | select(.fixed_data.username == $u)] | first // empty | "\(.pk) \(.expires)"')
if [[ -n $existing ]]; then
    read -r pk expires <<<"$existing"
    echo "$username already has an unused invitation (expires $expires):"
    echo "$base/if/flow/$flow_slug/?itoken=$pk"
    exit 0
fi

expires=$(date -u -d '+7 days' +%Y-%m-%dT%H:%M:%SZ)
body=$(jq -n --arg u "$username" --arg e "$email" --arg n "$name" \
    --arg flow "$flow_pk" --arg exp "$expires" '{
        name: ("invite-" + $u),
        flow: $flow,
        single_use: true,
        expires: $exp,
        fixed_data: {username: $u, email: $e, name: $n}
    }')
pk=$(ak -X POST --data "$body" "$api/stages/invitation/invitations/" | jq -er .pk)

echo "Invitation for $username <$email>, single use, expires $expires:"
echo "$base/if/flow/$flow_slug/?itoken=$pk"
echo "Opening the link uses it up; if they abandon the form, run this again."
REMOTE
