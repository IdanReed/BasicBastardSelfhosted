#!/bin/sh
# beszel-init — materialise the two artefacts the hub reads exactly once.
#
# Runs before the hub every time the stack comes up (Arcane redeploys rerun
# it), so it must be idempotent. House rule: every mutation logs a line
# starting "beszel-init: CHANGE:", and a second run on an unchanged input must
# log ZERO of them. The suite asserts that.
#
# Busybox sh in alpine:3.21 — no bashisms, no `local`, no arrays.
set -eu

log() { echo "beszel-init: $*"; }
die() { echo "beszel-init: FATAL: $*" >&2; exit 1; }

DATA_DIR=/beszel_data
KEY_PATH="$DATA_DIR/id_ed25519"
CFG_PATH="$DATA_DIR/config.yml"

# The system's display name in the hub, and the key SyncSystems matches on.
# Renaming it deletes the old row and its history — see the config.yml comment.
SYSTEM_NAME="${BESZEL_SYSTEM_NAME:-services-vm}"

[ -d "$DATA_DIR" ] || die "$DATA_DIR is not mounted"

# ---------------------------------------------------------------------------
# Input validation. Both values come from .sops.env via env_file, so a missing
# one means decrypt-sops-envs has not run or the key is absent from the file —
# either way the hub must not be allowed to start and generate its own
# identity, because that identity is unrecoverable afterwards (the hub writes
# no .pub and keeps the public half in memory only).
# ---------------------------------------------------------------------------
[ -n "${HUB_SSH_KEY_B64:-}" ] || die \
  "HUB_SSH_KEY_B64 is empty. Without it the hub would generate its OWN
  ed25519 key on first start, the agent's KEY would not match it, and the
  agent would restart-loop on 'invalid signature - check KEY value'. See
  .sops.env.example for how to generate the pair."
[ -n "${TOKEN:-}" ] || die \
  "TOKEN is empty. It is the credential the agent presents to the hub AND the
  value SyncSystems upserts into the fingerprints collection; the two must be
  the same string. See .sops.env.example."

# The token is interpolated into YAML below. Constrain it to what a UUID can
# contain so it cannot inject a key, a newline, or a second document — the
# same guard notes-sync-init carries, and derived here by TESTING the
# characters rather than by reading a regex (finding #38: a guard written from
# a read of the rules silently dropped the hyphen, which is the one character
# a UUID cannot do without).
case "$TOKEN" in
  *[!0-9a-fA-F-]*) die "TOKEN contains characters outside [0-9a-f-]: refusing
  to write it into config.yml" ;;
esac

# ---------------------------------------------------------------------------
# 1. The hub's ed25519 identity.
#
# Base64 because this travels in a dotenv file: an OpenSSH PEM is multi-line,
# and `env_file` parsing of multi-line values is the kind of thing that works
# in one Compose version and mangles in the next. Base64 is one line with no
# `$` in it, which also sidesteps the interpolation hazard finding #30 pinned.
# ---------------------------------------------------------------------------
tmp_key="$DATA_DIR/.id_ed25519.tmp.$$"
printf '%s' "$HUB_SSH_KEY_B64" | base64 -d > "$tmp_key" 2>/dev/null || {
  rm -f "$tmp_key"
  die "HUB_SSH_KEY_B64 is not valid base64"
}

# Reject anything the hub's ssh.ParsePrivateKey would reject, HERE, where the
# error names the cause — rather than in the hub, where it surfaces as
# "failed to parse private key" after the container has already restarted.
head -n1 "$tmp_key" | grep -q -- "-----BEGIN .*PRIVATE KEY-----" || {
  rm -f "$tmp_key"
  die "HUB_SSH_KEY_B64 decodes to something that is not a PEM private key"
}

chmod 600 "$tmp_key"
if [ -f "$KEY_PATH" ] && cmp -s "$tmp_key" "$KEY_PATH"; then
  rm -f "$tmp_key"
  log "hub key already correct"
else
  # Overwriting is deliberate even when a key is already present: a hub that
  # started once without this secret generated its own, and that key is
  # unrecoverable and does not match the agent's KEY. Replacing it is the
  # repair. Nothing is lost — the key is an identity, not data.
  # `if`, not `[ ... ] && log ...`: under `set -e` a failing test makes the
  # && list return non-zero and aborts the script mid-write — on the very
  # first run, where the file legitimately does not exist yet.
  if [ -f "$KEY_PATH" ]; then
    log "CHANGE: replacing an existing hub key (self-generated, or a rotation)"
  fi
  mv "$tmp_key" "$KEY_PATH"
  chmod 600 "$KEY_PATH"
  log "CHANGE: wrote $KEY_PATH"
fi

# ---------------------------------------------------------------------------
# 2. The declarative systems list.
#
# 🚨 config.SyncSystems runs on EVERY hub start and DELETES every system row
# not present in this file. For a GitOps fleet that is the point — the systems
# list becomes declarative and cannot drift — but it also means a truncated or
# half-written file silently wipes history. Hence tmpfile+rename: the hub
# never observes a partial config.yml.
#
# `host` and `port` are vestigial in this topology. They describe where the
# hub would DIAL the agent in SSH pull mode, and the agent runs with
# DISABLE_SSH=true and no listener — the connection is agent -> hub over a
# websocket to HUB_URL. They are kept because the schema expects them.
# ---------------------------------------------------------------------------
tmp_cfg="$DATA_DIR/.config.yml.tmp.$$"
cat > "$tmp_cfg" <<EOF
# GENERATED by beszel-init from .env — do not edit on the host.
# SyncSystems deletes every system not listed here on each hub start.
systems:
  - name: $SYSTEM_NAME
    host: 127.0.0.1
    port: 45876
    token: $TOKEN
EOF

# 0600 like the key beside it: config.yml carries TOKEN in cleartext, and
# TOKEN is the credential the agent presents to the hub — the same class of
# secret as id_ed25519, so it gets the same mode. Set on the tmpfile so the
# token is never briefly world-readable under $DATA_DIR, and again after the
# rename for the same reason the key does it.
chmod 600 "$tmp_cfg"
if [ -f "$CFG_PATH" ] && cmp -s "$tmp_cfg" "$CFG_PATH"; then
  rm -f "$tmp_cfg"
  # Content-equal is not mode-equal: every config.yml written before this
  # chmod existed is still 0644 on disk, and it survives a redeploy precisely
  # because the content matches. Repair it here — and log it, because it IS a
  # mutation (house rule), which costs one CHANGE line on the first run after
  # this change and zero on every run after that.
  if [ "$(stat -c %a "$CFG_PATH")" != "600" ]; then
    chmod 600 "$CFG_PATH"
    log "CHANGE: tightened $CFG_PATH to 0600 (it held TOKEN at 0644)"
  fi
  log "systems config already correct"
else
  mv "$tmp_cfg" "$CFG_PATH"
  chmod 600 "$CFG_PATH"
  log "CHANGE: wrote $CFG_PATH ($SYSTEM_NAME)"
fi

log "done"
