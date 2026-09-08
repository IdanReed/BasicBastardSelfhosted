#!/bin/sh
# Two-writer sync for the SilverBullet space: this host on one side, Obsidian
# (through a Forgejo repo) on the other.
#
# CONFLICT POLICY: REMOTE WINS, and it says so out loud when it fires.
# SilverBullet commits every cycle, so its version is seconds old and easy to
# retype; an Obsidian edit is a deliberate push from a device possibly offline
# for days. Two cases, and A would otherwise be silent:
#   A. `-X ours` RESOLVED it: no git error, the page comes out as the remote's
#      version. The local version is kept on `git-sync-superseded-<ts>` and
#      named in an ntfy alert.
#   B. `-X ours` could NOT resolve it: rebase aborted, local commit kept on
#      `git-sync-conflict-<ts>`, tree hard-reset to the remote, ntfy told.
# Both lose content from the WORKING TREE only, never history.
#
# ⚠ `-X ours` is not a typo: a rebase replays the local commits ONTO the
# upstream, so git calls the REMOTE side "ours". Inverting it would silently
# prefer this host on every conflict forever.
#
# Two rules kept on purpose:
#   - No `origin` remote is ever configured: the URL carries a PAT and
#     `git remote add` would persist it in /space/.git/config, i.e. in every
#     backup. Per-command URLs keep it in the environment only.
#   - `set -e` deliberately NOT used: every git call is checked, and one failed
#     fetch must not kill the loop.

SPACE="${GIT_SYNC_SPACE:-/space}"
BRANCH="${GIT_SYNC_BRANCH:-main}"
INTERVAL="${GIT_SYNC_INTERVAL:-60}"
DEBOUNCE="${GIT_SYNC_DEBOUNCE:-30}"
REMOTE="${GIT_SYNC_REMOTE:-}"
NTFY_URL="${GIT_SYNC_NTFY_URL:-}"
ALERT_COOLDOWN="${GIT_SYNC_ALERT_COOLDOWN:-3600}"

HEARTBEAT=/tmp/git-sync.alive
ALERT_STATE=/tmp/git-sync.last-alert

log() { echo "git-sync: $*"; }

# Rate-limited ntfy publish, keyed by nothing but time: this loop has one job,
# so any alert inside the cooldown is about the same broken thing.
alert() {
  log "ALERT: $*"
  [ -n "$NTFY_URL" ] || return 0
  now="$(date +%s)"
  if [ -f "$ALERT_STATE" ]; then
    last="$(cat "$ALERT_STATE" 2>/dev/null || echo 0)"
    if [ $((now - last)) -lt "$ALERT_COOLDOWN" ]; then
      log "(alert suppressed, cooldown)"
      return 0
    fi
  fi
  echo "$now" > "$ALERT_STATE"
  # A notifier that can fail must not add a second failure.
  wget -q -O /dev/null \
    --header="Title: services-vm: silverbullet git-sync" \
    --header="Priority: high" \
    --header="Tags: rotating_light" \
    --post-data="$*" \
    "$NTFY_URL" || log "(ntfy publish failed)"
  return 0
}

# `git -C /space`, with the URL never stored.
g() { git -C "$SPACE" "$@"; }

# Written once, only if absent, so the operator (or Obsidian) can extend it.
# .silverbullet.auth.json is live session/lockout state — pushing it would put
# session material in a git repo.
ensure_gitignore() {
  [ -f "$SPACE/.gitignore" ] && return 0
  cat > "$SPACE/.gitignore" <<'EOF'
# Written by stacks/silverbullet/git-sync.sh on first run; yours to edit.
.silverbullet.auth.json
EOF
  log "seeded .gitignore"
}

# Trap 3 in compose.yaml: /space/CONTAINER_BOOT.md is executed as bash at every
# start and can arrive from the remote. Reported, never touched — deleting a file
# the operator may have added deliberately is its own silent failure.
check_boot_script() {
  [ -f "$SPACE/CONTAINER_BOOT.md" ] || return 0
  alert "CONTAINER_BOOT.md exists in the space. The SilverBullet image RUNS IT AS BASH at every container start. If you did not put it there, treat this as code execution delivered through the notes repo."
}

# True when the remote already has the branch. Also the connectivity probe:
# every other git call is skipped when this fails, so a down Forgejo produces
# one message per cycle rather than three.
remote_has_branch() {
  git ls-remote --exit-code "$REMOTE" "refs/heads/$BRANCH" >/dev/null 2>&1
}

# First run against a non-empty space: SilverBullet has already created
# index.md, and the remote may hold the real notes. `reset --mixed` then
# `checkout -- .` rather than `reset --hard`: history becomes the remote's (no
# unrelated-histories rebase later), remote content wins for tracked files, and
# local-only files stay untracked for the first normal cycle to commit.
bootstrap() {
  g rev-parse --verify HEAD >/dev/null 2>&1 && return 0   # already has history
  if ! remote_has_branch; then
    # ⚠ ls-remote cannot tell "branch does not exist" from "cannot connect" —
    # both exit nonzero — so this line says both. The distinction is made one
    # step later: the push either seeds the branch or fails and alerts.
    log "no $BRANCH on the remote yet (or the remote is unreachable); a push will tell us which"
    return 0
  fi
  log "bootstrapping from the remote (remote content wins for tracked files)"
  # NOT a shallow fetch: a shallow repo cannot be rebased or pushed from
  # reliably, and a markdown space is small.
  if ! g fetch "$REMOTE" "$BRANCH"; then
    alert "bootstrap fetch failed; the space is NOT syncing"
    return 1
  fi
  if ! g reset --mixed FETCH_HEAD || ! g checkout -- .; then
    alert "bootstrap checkout failed; the space is NOT syncing"
    return 1
  fi
  return 0
}

# Nothing has been written for DEBOUNCE seconds. A stamp file plus `-newer`,
# because busybox find has no -newermt — it errors, and with stderr discarded
# the check always reported "quiet". find's stderr is deliberately NOT
# discarded: swallowing it is what hid that. .git is excluded, or git's own
# writes would re-arm the debounce forever.
space_is_quiet() {
  stamp=/tmp/git-sync.debounce
  if ! touch -d "@$(( $(date +%s) - DEBOUNCE ))" "$stamp" 2>/dev/null; then
    # No stamp, no debounce: commit anyway rather than defer forever — the
    # loop must never wedge on a broken /tmp.
    log "cannot write $stamp; skipping the write-debounce this cycle"
    return 0
  fi
  hit="$(find "$SPACE" -path "$SPACE/.git" -prune -o \
      -type f -newer "$stamp" -print -quit)"
  [ -z "$hit" ]
}

commit_local() {
  if ! space_is_quiet; then
    log "space still being written to; deferring the commit one cycle"
    return 0
  fi
  g add -A || { alert "git add failed"; return 1; }
  if g diff --cached --quiet; then
    return 0
  fi
  g commit -q -m "silverbullet: $(date -u '+%Y-%m-%d %H:%M:%SZ')" \
    || { alert "git commit failed"; return 1; }
  log "committed local changes"
  return 0
}

# Called only when the rebase could not be resolved even with remote-wins; keeps
# the local commit reachable before the hard reset.
rescue_and_reset() {
  ts="$(date -u '+%Y%m%d-%H%M%S')"
  branch="git-sync-conflict-$ts"
  g rebase --abort >/dev/null 2>&1
  g branch "$branch" >/dev/null 2>&1
  g reset --hard FETCH_HEAD >/dev/null 2>&1
  # Best effort, so the recovery does not depend on this host's disk.
  g push "$REMOTE" "refs/heads/$branch:refs/heads/$branch" >/dev/null 2>&1 \
    && pushed="pushed to Forgejo" || pushed="LOCAL ONLY (push failed)"
  alert "UNRESOLVABLE CONFLICT in the SilverBullet space. The remote (Obsidian) version is now live. The local version is saved on branch $branch ($pushed) and in the reflog; nothing was deleted from history."
}

sync_once() {
  case "$REMOTE" in
    "")
      log "GIT_SYNC_REMOTE is unset — the wiki works, nothing is mirrored"
      return 0
      ;;
    *changeme*)
      # A placeholder that looks configured is worse than an empty one. Not
      # fatal — the wiki is fine — but it must not be silent.
      alert "GIT_SYNC_REMOTE still contains a changeme_ placeholder — the space is NOT mirrored to Forgejo."
      return 0
      ;;
  esac

  if [ ! -d "$SPACE/.git" ]; then
    g init -q -b "$BRANCH" || { alert "git init failed in $SPACE"; return 1; }
    log "initialised a git repository in $SPACE"
  fi
  ensure_gitignore
  bootstrap || return 1

  commit_local || return 1

  if ! remote_has_branch; then
    # Empty repo (or a branch that does not exist yet): push seeds it.
    if g rev-parse --verify HEAD >/dev/null 2>&1; then
      g push "$REMOTE" "HEAD:refs/heads/$BRANCH" >/dev/null 2>&1 \
        && log "seeded $BRANCH on the remote" \
        || alert "cannot reach the Forgejo remote (or the PAT is rejected) — the space is NOT mirrored."
    fi
    return 0
  fi

  if ! g fetch --quiet "$REMOTE" "$BRANCH"; then
    alert "git fetch failed — the space is NOT mirrored right now."
    return 1
  fi

  # The common case: nothing new upstream and nothing to push.
  local_head="$(g rev-parse HEAD 2>/dev/null)"
  remote_head="$(g rev-parse FETCH_HEAD 2>/dev/null)"
  if [ "$local_head" = "$remote_head" ]; then
    return 0
  fi

  # 🚨 HARD GUARD: never rebase — and so never reach rescue_and_reset's
  # `reset --hard` — with a dirty tree. commit_local defers while the space is
  # being written to, and those edits exist ONLY in the working tree: a rebase
  # would refuse, be read as a conflict, and the rescue path would delete them.
  if ! g diff --quiet || ! g diff --cached --quiet; then
    log "working tree not clean (deferred commit); skipping rebase this cycle"
    return 0
  fi

  # What the local side is about to replay, recorded BEFORE the rebase
  # rewrites it — this is the only handle on the pre-rebase version once the
  # branch has moved.
  pre="$local_head"
  base="$(g merge-base "$pre" FETCH_HEAD 2>/dev/null)"
  changed_locally="$(g diff --name-only "$base" "$pre" 2>/dev/null)"

  # -X ours == REMOTE wins; see the header. --no-autostash: there is nothing
  # to stash (the guard above proves it) and an autostash would hide a
  # half-written file inside a stash nobody looks at.
  if ! g rebase -X ours --no-autostash FETCH_HEAD >/dev/null 2>&1; then
    rescue_and_reset
  else
    # THE QUIET CASE: `-X ours` RESOLVES the conflict rather than reporting it,
    # so a page edited on both sides comes out as the remote's version with no
    # error anywhere. Detected by asking, for each file the local side touched,
    # whether the post-rebase content still matches. Over-reports by design.
    #
    # IFS is a newline for the loop: SilverBullet page names routinely contain
    # spaces, and the default IFS would split one page into several
    # non-existent paths whose `git diff` succeeds trivially.
    superseded=""
    old_ifs="$IFS"
    IFS='
'
    for f in $changed_locally; do
      g diff --quiet "$pre" HEAD -- "$f" 2>/dev/null || superseded="$superseded
  $f"
    done
    IFS="$old_ifs"
    if [ -n "$superseded" ]; then
      ts="$(date -u '+%Y%m%d-%H%M%S')"
      # A named branch rather than the reflog, which expires. Local only —
      # pushing every reconcile would litter Forgejo. They accumulate; prune
      # with `git -C /space branch -D`.
      g branch "git-sync-superseded-$ts" "$pre" >/dev/null 2>&1
      alert "reconciled remote-wins:$superseded. The Obsidian version is now live; the SilverBullet version of those pages is on local branch git-sync-superseded-$ts (in /mnt/fast/silverbullet/space)."
    fi
  fi

  if ! g push "$REMOTE" "HEAD:refs/heads/$BRANCH" >/dev/null 2>&1; then
    # Usually a race with a push between the fetch and this; the next cycle
    # rebases again. The cooldown turns a persistent failure into one message
    # an hour.
    alert "git push rejected — retrying next cycle. If this persists the PAT may have expired or the branch is protected."
    return 1
  fi
  return 0
}

log "starting: space=$SPACE branch=$BRANCH interval=${INTERVAL}s debounce=${DEBOUNCE}s"
while :; do
  # Touched FIRST, before any git call, so the healthcheck measures the loop and
  # not the remote.
  touch "$HEARTBEAT"
  check_boot_script
  sync_once
  sleep "$INTERVAL"
done
