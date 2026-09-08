#!/bin/sh
# forgejo-init — seed the Authentik OAuth2/OIDC auth source. Forgejo stores auth
# sources in its DATABASE, not app.ini, so `forgejo admin auth add-oauth` is the
# only declarative route. Runs as uid 1000 against the live instance's /data.
#
# The source NAME "authentik" is load-bearing: the callback is
# /user/oauth2/<name>/callback, matched strictly by the blueprint's redirect_uri.
#
# Idempotent: every mutation logs "forgejo-init: CHANGE:"; a second run logs
# none. The secret is re-asserted each run so a rotation propagates.
#
# ACCEPTED: --secret puts FORGEJO_OIDC_CLIENT_SECRET on argv, which is
# host-visible in /proc/<pid>/cmdline for the life of the command, on every
# deploy. cmd/admin_auth_oauth.go defines `secret` as a plain StringFlag — no
# --secret-file, no EnvVars — so there is no alternative in this version, and
# the CLI is the only declarative route (see above). Same tradeoff as
# stacks/tracking/bookstack-admin-init.sh. arch-security / declarative E1.
set -eu

export GITEA_WORK_DIR=/data
CONF=/data/gitea/conf/app.ini
NAME=authentik
DISCOVERY=https://auth.idanreed.com/application/o/forgejo/.well-known/openid-configuration

log() { echo "forgejo-init: $*"; }
die() { echo "forgejo-init: FATAL: $*" >&2; exit 1; }
fj()  { forgejo --config "$CONF" "$@"; }

SECRET="${FORGEJO_OIDC_CLIENT_SECRET:-}"
case "$SECRET" in
  "")         die "FORGEJO_OIDC_CLIENT_SECRET is empty/unset — .env not decrypted or the secret was never filled (sops-gen forgejo/oidc)" ;;
  changeme*)  die "FORGEJO_OIDC_CLIENT_SECRET is still a changeme placeholder" ;;
esac

[ -f "$CONF" ] || die "$CONF not found — forgejo volume unmounted or instance not initialised"

# --auto-discover-url makes Forgejo FETCH the discovery doc, which would
# hard-fail and abort the stack offline. Probe first and skip when unreachable
# (the init re-runs every redeploy); a reachable-but-rejected discovery still
# falls through to a loud failure below.
if ! curl -fsS --max-time 10 "$DISCOVERY" >/dev/null 2>&1; then
  log "WARN: $DISCOVERY unreachable (offline test, or Authentik/DNS not up yet) — skipping auth-source seed; re-runs next deploy"
  exit 0
fi

# `admin auth list` columns: ID<tab>Name<tab>Type<tab>Enabled (header on row 1).
id=$(fj admin auth list 2>/dev/null | awk -v n="$NAME" 'NR>1 && $2==n {print $1; exit}')

if [ -z "$id" ]; then
  fj admin auth add-oauth \
    --name "$NAME" \
    --provider openidConnect \
    --key forgejo \
    --secret "$SECRET" \
    --auto-discover-url "$DISCOVERY" \
    --scopes "openid profile email"
  log "CHANGE: created OAuth2 auth source '$NAME' (client_id forgejo)"
else
  # Re-assert secret + discovery so a rotation lands; no CHANGE line on a no-op.
  fj admin auth update-oauth \
    --id "$id" \
    --name "$NAME" \
    --provider openidConnect \
    --key forgejo \
    --secret "$SECRET" \
    --auto-discover-url "$DISCOVERY" \
    --scopes "openid profile email"
  log "auth source '$NAME' present (id $id) — secret + discovery re-asserted"
fi

log "done"
