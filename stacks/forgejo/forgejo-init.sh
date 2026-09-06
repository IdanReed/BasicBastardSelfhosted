#!/bin/sh
# forgejo-init — seed the Authentik OAuth2/OIDC auth source (login-tiers tier 1).
#
# WHY A CONTAINER, not env: Forgejo stores auth sources in its DATABASE, not in
# app.ini/env — so a one-shot `forgejo admin auth add-oauth` is the only
# declarative way to make the OIDC source exist. Runs AFTER forgejo is healthy
# (depends_on) as uid 1000, so it shares the /data sqlite the live instance uses
# (a brief busy-wait on the lock is fine; the suite proves `admin` ops work
# against a running instance). The source NAME "authentik" is load-bearing:
# Forgejo's callback is /user/oauth2/<name>/callback, matched strict by the
# blueprint's redirect_uri.
#
# Idempotent: every mutation logs "forgejo-init: CHANGE:"; a second run must log
# none. The secret is RE-ASSERTED each run (update-oauth) so a rotation
# propagates — that is a no-op write, not a CHANGE line.
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

# add-oauth --auto-discover-url makes Forgejo FETCH the discovery doc. If
# Authentik is unreachable — the offline VM tests, or early bring-up before DNS
# / the VPS is up — that would hard-fail and abort the stack. Probe first: skip
# (exit 0) when unreachable (the init re-runs every redeploy, so it seeds as
# soon as Authentik answers), but let a REACHABLE-but-rejected discovery fall
# through to a loud failure below.
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
