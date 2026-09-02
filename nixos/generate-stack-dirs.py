#!/usr/bin/env python3
"""Generate nixos/stack-dirs.nix from the compose files.

WHY THIS EXISTS
---------------
Docker creates a missing bind-mount source as a ROOT-OWNED directory at
container start. That default is the bug — it is what made seerr crash-loop on
first deploy (EACCES mkdir as uid 1000), what makes MySQL's `--initialize`
refuse its datadir, and what makes syncthing report a HEALTHY container with an
errored folder. So every /mnt bind source named by a compose file gets a
`systemd.tmpfiles` 'd' rule with a deliberate owner.

Those rules used to be ~95 hand-written lines in hardware-configuration.nix,
kept in sync with the compose files by a hand-maintained list in the
`tmpfiles-ownership` lint. The list named 17 of 22 stacks, so 13 bind sources
across backrest, caddy, forgejo, ntfy and paperless had no rule at all and
nothing noticed for a whole campaign.

WHY A GENERATED, CHECKED-IN FILE
--------------------------------
`nixos/` is its own flake root and a flake cannot reference files outside its
root, so the NixOS config CANNOT read ../stacks/ at eval time — the same
constraint that triplicates ssh-pubkeys.nix. Hence: this script writes a
CHECKED-IN stack-dirs.nix, and the `stack-dirs-generated` lint re-runs this
exact script and byte-compares. Drift is a build failure, exactly like
ssh-pubkey-parity. The human step is not removed; the SILENT GAP is.

USAGE
-----
    nixos/generate-stack-dirs.sh              # regenerate nixos/stack-dirs.nix

    python3 generate-stack-dirs.py --repo <repo-root>            # to stdout
    python3 generate-stack-dirs.py --repo <repo-root> --write
    python3 generate-stack-dirs.py --manifest m.json --json      # for the lints

`--manifest` takes [{"stack": ..., "path": ...}, ...] so the lints can feed the
compose files they discovered themselves (a Nix-side readDir) through the same
code path; the rule computation below is then provably the same one.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys

import yaml

# ---------------------------------------------------------------------------
# What counts as a stack-derived directory
# ---------------------------------------------------------------------------
# Whole-tier mounts are NOT directories to create: /mnt/fast and /mnt/slow are
# real filesystems declared in hardware-configuration.nix's `fileSystems`, and
# stacks/backrest mounts both wholesale (:ro) so it can snapshot everything. A
# tmpfiles rule for them would fight the mount unit for ownership of a
# mountpoint.
TIER_MOUNTS = {"/mnt", "/mnt/fast", "/mnt/slow"}

# Only /mnt/{fast,slow} sources are ours. Anything else a compose file binds
# (/var/run/docker.sock, /var/lib/backup/..., ./relative files) is either
# system state or repo content and is owned elsewhere.
SOURCE_RE = re.compile(r"^/mnt/(fast|slow)/")

DEFAULT_MODE = "0755"
DEFAULT_OWNER = ("root", "root")


# ---------------------------------------------------------------------------
# Per-stack prose. Moved verbatim from hardware-configuration.nix — the reason
# a given ownership is what it is IS the valuable part of these rules, and it
# has to live where the value is decided, which is now here.
# ---------------------------------------------------------------------------
# A stack that gains /mnt bind mounts and has no entry here makes this script
# EXIT NONZERO (see _check_tables), which fails the stack-dirs-generated lint.
# That is deliberate: root:root is also docker's default, so inheriting it
# silently is indistinguishable from choosing it, and this fleet has been bitten
# by that four times. An empty string is a legitimate entry — it means "every
# directory here is root:root and the image runs as root".
#
# ⚠ KOMODO: komodo/compose.yaml is scanned by this generator even though it
# lives outside stacks/, because it is bootstrapped onto the same host — the
# deploy-plane manager that replaced arcane/. It contributes the Postgres
# datadir /mnt/fast/komodo/pgdata (the FerretDB backend), the ONLY stateful
# part of the Komodo stack; Core, Periphery and FerretDB keep no /mnt state.
#
# The tables below are the tripwire the generator exists for: with a
# STACK_NOTES/DIR_NOTES entry present but the compose not yet mounting the
# path, this script exits nonzero with "DIR_NOTES has an entry for
# /mnt/fast/komodo/pgdata, which no compose file bind-mounts" and the
# stack-dirs-generated lint goes red. The reverse — compose mounting a path
# this table says nothing about — is the case the table exists to catch.
STACK_NOTES = {
    "actual": """\
1001:1001 — the uid the compose file PINS with `user: "1001:1001"`. The
image creates `actual` uid 1001 for exactly this purpose and then ships
with no USER instruction (measured: `"User": null` in the published
26.9.0 config; the suite's first run wrote account.sqlite as 0:0), so
without the compose pin the server runs as root. Nothing in the
container chowns, and the create-folders migration mkdirs server-files/
and user-files/ under /data before the server ever binds — so a
root-owned bind mount plus the pinned uid is a container that exits at
start (the seerr crash-loop class, finding #14).""",
    "automation": """\
Ownership, VERIFIED per image (annex §2.3):
  - home assistant runs as ROOT and has no PUID/PGID mechanism at all.
    Its /config must also be WRITABLE: .HA_VERSION is rewritten on every
    version change and that write is not wrapped in a try/except, so a
    read-only config dir kills startup.
  - mosquitto starts as root and DROPS to uid 1883, and its 2.x
    entrypoint chowns only some of its tree (2.1 narrowed it to
    /mosquitto/data alone) — so both directories are declared 1883
    rather than relying on the image to heal them. This is the seerr
    crash-loop class (finding #14) and the one place in this stack it
    could still bite.
  - frigate runs as root.""",
    "backrest": """\
All root:root. The backrest image declares no USER and its compose sets
none — it must run as root to read every service's data through the
/mnt/{fast,slow}:ro mounts — and config-init is plain alpine, also root.
config/ must stay WRITABLE (:ro breaks it): Backrest rewrites config.json
whenever anything changes in the UI.

These had NO rule at all until the generator landed: stacks/backrest was
never in the tmpfiles-ownership lint's hand-maintained COMPOSE_FILES list.
tests/suites/backrest.nix has run green against exactly this ownership
since it was written (backrest.nix, systemd.tmpfiles.rules).""",
    "beszel": "",
    "books": """\
Ownership, VERIFIED per image (annex §2.2):
  - kavita runs as ROOT: its entrypoint's PUID/PGID block is commented
    out upstream ("causing issues for Synology users") and the image sets
    no USER. It also hard-exits if it cannot write /kavita/config, and
    that directory must stay WRITABLE — Kavita rewrites appsettings.json
    and swallows the failure, so a read-only config dir silently leaves
    the published placeholder JWT key in play (annex §0.5).
  - audiobookshelf runs as ROOT too ("User": null in the image config;
    it has no PUID/PGID mechanism at all) — the immich call, for the same
    reasons: tailnet-only, loopback-bound, socketless.
  - shelfmark starts as root, then drops to PUID/PGID (1000 here). Its
    entrypoint recursively chowns /config and repairs /tmp/shelfmark, so
    these would self-heal — declaring them 1000:1000 anyway just means it
    has nothing to do.
  - The /mnt/slow trees are 1000:1000: shelfmark (uid 1000) writes the
    ebook tree, and the audiobook tree and the drop dir keep the same
    ownership for whatever ends up filling them (shelfmark's Direct
    Download source is ebook-only, so audiobooks arrive from the MEDIA
    stack — see the /mnt/slow/books/drop note; it is the one directory
    here a container in another stack writes). Kavita and audiobookshelf
    mount their trees :ro as root and only read.""",
    "caddy": """\
root:root. The official caddy image runs as root (it binds 80/443 and here
network_mode: host), so the ACME account key and the issued certificates
under data/ are written as root. Nothing else on the host reads them.

This stack was never in the tmpfiles-ownership lint's COMPOSE_FILES list
either, so both directories were left to docker to create. That happened to
be harmless — docker's default IS root:root — but it was luck, not a
decision: tests/suites/services-vm.nix and tailnet.nix pre-create
/mnt/fast/caddy root-owned and have run green throughout.""",
    "dawarich": """\
Both of its entrypoints gosu-drop to PUID/PGID *only if* they start as uid
0, chowning first — which is why its compose sets no `user:` and these are
1000:1000 to match what the entrypoint will enforce. Setting `user:` there
instead would skip the chown branch entirely and crash-loop on a root-owned
mount; upstream warns about it inline, twice.""",
    "docspace": """\
THREE containers, THREE DIFFERENT NON-ROOT UIDs, and getting any of them
wrong produces `dependency failed to start` naming a container that is fine:
  docspace       uid 104 gid 107 (USER onlyoffice, starts pre-dropped)
  docspace_db    uid 999 gid 999 (mysql drops before --initialize)
  docspace_ds    root            (documentserver chowns from its entry)
Three different conventions in three containers; do not normalise them.
  - Document Server runs as ROOT and chowns its own mounts to ds:ds on
    every start, so root-owned is correct and self-healing. Never set
    `user:` on it — that skips the chown branch.
  - The monolith runs `user: root` following upstream, because its
    entrypoint edits /etc/nginx and its config files before dropping into
    supervisord. The ExcaliDash lesson applies: an image that stays root
    deliberately in order to fix permissions crash-loops when you take
    that away.
  - MySQL chowns its own datadir at first init.

⚠ Note the DS and monolith trees are SEPARATE here. Upstream's community
compose mounts the same volume into both (/app/onlyoffice/data and
/var/www/onlyoffice/Data) — two different applications' state sharing one
namespace. Separating them is what makes the Backrest exclude list for
the document cache expressible at all.""",
    "firefly": """\
A convention of its own: the image ends on `USER www-data` at BUILD time and
never invokes an id-remap entrypoint, so PUID/PGID are inert and the upload
directory must be pre-owned 33:33 or attachment upload fails at runtime with
a permission error and no startup symptom at all. Its Postgres starts as
root and chowns its own datadir, as everywhere else here.""",
    "forgejo": """\
1000:1000, matching the USER_UID/USER_GID the compose file sets: the classic
(root-entrypoint) image runs its `git` user at that uid, so everything under
/data is written as 1000 and the fast-volume backup reads it without
surprises. tests/suites/forgejo.nix pre-creates the volume root at exactly
this ownership and pushes/clones against it.

/data holds app.ini — which carries the SECRET_KEY, INTERNAL_TOKEN and JWT
secrets Forgejo self-generates on first start — plus gitea.db and every
repository. There is no .sops.env for this stack precisely because that
material lives here instead, which makes this directory the whole of
Forgejo's identity and state.

Never had a rule before the generator: stacks/forgejo was missing from the
tmpfiles-ownership lint's COMPOSE_FILES list, so this — the git ROOT for the
homelab, including the compose repo the deploy-plane manager (Komodo, via the
host stack-git-sync unit) pulls from — was left to docker to create
root-owned.""",
    "gatus": "",
    "ghostfolio": """\
One directory, root:root, and that is VERIFIED rather than inherited: the
only /mnt mount in this stack is the Postgres datadir, and the
postgres:17.9-alpine image starts as root and chowns /var/lib/postgresql/data
to uid 999 itself before `initdb` drops privileges — the same reasoning that
makes paperless, wger, windmill, tandoor and firefly's pgdata roots
root:root here.

The app container has NO /mnt mount at all (all its state is in Postgres),
and its Redis deliberately has no volume either — it is a cache plus a
re-enqueueable Bull job queue, following the wger_cache precedent. So this
stack contributes exactly one leaf directory plus its parent, and the whole
of its backup story is the pg_dumpall of ghostfolio_db.""",
    "logging": """\
THREE CONTAINERS, THREE DIFFERENT ANSWERS, and each one was read out of the
pinned image rather than assumed (`docker inspect --format '{{.Config.User}}'`
on the exact tags in stacks/logging/compose.yaml):

  loki     uid 10001  the image sets USER 10001. /mnt/slow/loki is its whole
                      world — chunks, the tsdb index, the WAL and the
                      compactor's working directory — and it is written
                      continuously. Root-owned it does not degrade: Loki exits
                      at startup unable to create its path_prefix, which
                      presents as the collector's pushes failing and is
                      diagnosed three containers away. This is finding #14
                      (seerr) in a fourth image.
  grafana  uid 472    the image sets USER 472, with gid 0 — the OpenShift
                      convention. 472:472 is right anyway: owner-write is what
                      /var/lib/grafana needs, and grafana.db is created there
                      on first start. A root-owned directory here means an
                      unhealthy container rather than a silent one, because
                      /api/health reports the database.
  alloy    ROOT       and that is not a default anyone declined to change: the
                      grafana/alloy image sets NO USER, and root is exactly
                      what lets it read the journal. Journal files are
                      root:systemd-journal 0640 under 2755 directories, so a
                      reader is either uid 0 (owner-read) or in gid 62.
                      /mnt/fast/alloy holds only the positions file and the
                      write-ahead log, so root:root is both correct and the
                      default — but adding a `user:` to that container without
                      also granting gid 62 would turn it into a healthy
                      process that collects nothing, which is why this is
                      written down here rather than left implicit.

The read-only journal mounts (/var/log/journal, /etc/machine-id) are NOT in
this table and must never be: they are system paths owned by systemd, not
per-stack bind sources, and a `d` rule over /var/log/journal would fight
journald for its own directory.""",
    "immich": """\
root:root everywhere ON PURPOSE: the immich images have no PUID/PGID
mechanism and run as root by default (the FAQ's non-root mode is deliberately
not used — annex §2/§7.5: tailnet-only, loopback-bound, socketless), so the
server/ML write /data and /cache as root; the postgres image chowns pgdata
itself from its root entrypoint; and immich-config-init (alpine, root) writes
the 0600 immich.json into the config dir. The seerr uid-1000 crash-loop class
(finding #14) therefore does not apply, but the 'd' rules still must exist:
docker creates missing bind sources at container start with no say over the
parent /mnt/fast/immich.""",
    "komodo": """\
All root:root. Komodo is the deploy-plane manager that replaced Arcane and
splits across four containers, none needing a non-root /mnt owner:
  - Core holds ALL its state in the Mongo-wire DB and touches no /mnt — it
    has no bind source here at all.
  - Periphery mounts /var/run/docker.sock and /srv/stacks (neither a /mnt
    source) and runs as root, so it reads the 0600 decrypted .env files.
  - FerretDB is stateless — every document lives in its Postgres.
  - Postgres is the only stateful component; /mnt/fast/komodo/pgdata is the
    whole backup payload, and the postgres image chowns its own datadir to
    uid 999 from a root entrypoint (the ghostfolio/outline/paperless pgdata
    precedent) — so root:root is correct and self-healing.
The age key never enters any of them: decrypt-sops-envs (host) writes .env
and stack-git-sync (host) delivers the files; Periphery only runs compose.""",
    "mealie": """\
root:root is fine and ANY hand-fix is futile: the image's entry.sh starts
as root, runs `chown -R $PUID:$PGID /app` — which INCLUDES the bind-mounted
/app/data — on EVERY start, then gosu-drops to 911:911 (PUID/PGID defaults,
deliberately unset in the compose). So /mnt/fast/mealie ends up 911:911
within seconds of first `up` regardless of this rule. backup-prepare.sh
reads mealie.db from here as root, so nothing else cares who owns it.""",
    "media": """\
Declared here rather than left to docker's create-on-mount because docker
always creates missing bind sources root-owned at container start — exactly
the class of bug that made seerr crash-loop on first deploy (EACCES mkdir;
its image runs as uid 1000 and cannot chown, now worked around by the
seerr-init oneshot) — and because nothing else would create /mnt/slow/data
with the uid the hardlink layout needs. The media suite mirrors this exact
set in its tmpfiles block; keep the two in sync.

Ownership: root:root is correct for the config roots — the LSIO images
(radarr/sonarr/prowlarr/bazarr/qbittorrent) chown per PUID/PGID from a
root entrypoint, jellyfin and gluetun run as root, cleanuparr's
entrypoint honors PUID/PGID, profilarr runs as root, seerr-init chowns
/mnt/fast/seerr/config, and clamav 1.5's /init (VERIFIED by reading
the pinned image's entrypoint script) runs as root and does
`chown -R clamav:clamav /var/lib/clamav` unconditionally before
starting clamd. /mnt/slow/data is 1000:1000: every media container
works there as uid 1000 and media-init creates the skeleton with that
owner.

This stack also bind-mounts /mnt/slow/books/drop, which BELONGS TO THE
BOOKS STACK (its rule and its reasoning are under books, where the
directory lives). That is the entire audiobook hand-off: clamav-scanner
moves a clean `audiobooks` download into it and audiobookshelf reads it
:ro. Nothing else crosses.""",
    "notes-sync": """\
ALL 1000:1000, and for two different reasons:
  - rmfakecloud is FROM scratch with no entrypoint and no PUID/PGID, so
    it cannot fix anything itself. Its compose sets `user: "1000:1000"`
    deliberately (Windmill later mounts this tree read-only as uid 1000
    to scan .rm files, and a root-owned tree would make that scan
    silently see nothing), which means the ownership MUST come from here.
  - syncthing's entrypoint chown is `chown PUID:PGID $HOME || true` —
    NON-RECURSIVE, with an upstream comment saying "maybe it'll work
    anyway, so we let the error slide". It fixes /var/syncthing and
    nothing beneath it, so config/ and every synced tree must be
    pre-owned. Getting this wrong yields a HEALTHY container with an
    errored folder: finding #14 with the crash-loop replaced by silence.""",
    "ntfy": """\
root:root. The ntfy image declares no USER and the compose sets none, so
`ntfy serve` runs as root and owns both trees. lib/ holds the auth database
(user.db) and the attachment store; cache/ holds cache.db, the recent-message
buffer, which is deliberately transient — see the backup-coverage allowlist.

Another stack that was missing from the tmpfiles-ownership lint's
COMPOSE_FILES list. It is the single place every failure in the fleet gets
reported, so it silently failing to start would take the alert path with it;
tests/suites/backrest.nix and services-vm.nix both pre-create these
root-owned and have run green throughout.""",
    "outline": """\
1001:1001 for the app's data directory, and that is VERIFIED rather than
assumed: the image ends on `USER nodejs` and `id` inside the pinned
outlinewiki/outline:1.9.2 reports uid=1001(nodejs) gid=1001(nodejs). Its
entrypoint is the stock node one — it execs the server and chowns NOTHING —
so a root-owned bind source is never repaired. The symptom is not a
crash-loop: Outline starts, serves, and fails the first time someone
attaches a file, because FILE_STORAGE=local makes that directory the whole
object store (finding #14 with the crash-loop replaced by silence).

Its Postgres starts as root and chowns its own datadir, as everywhere else
here, so /mnt/fast/outline/pgdata is root:root. There is deliberately no
directory for redis: that container has no volume at all (its queue is
reconstructible — see the compose file).""",
    "paperless": """\
root:root for all five, and that is VERIFIED rather than assumed: the
paperless entrypoint runs as root, maps its `paperless` user onto
USERMAP_UID/USERMAP_GID (1000 here) and chowns data/media/consume/export
before dropping privileges, and the postgres image chowns pgdata itself from
its root entrypoint. tests/suites/paperless.nix creates exactly these six
directories root-owned and runs the whole document pipeline against them.

Missing from the tmpfiles-ownership lint's COMPOSE_FILES list until the
generator landed — five bind sources with no rule.""",
    "samba": """\
smbd runs as ROOT and must — it needs to setuid per connection — so /data is
root-owned.""",
    "silverbullet": """\
1000:1000, and here the ownership is not just about write access — it
DECIDES THE UID THE SERVER RUNS AS. The image's entrypoint reads the owner
of $SB_FOLDER and re-execs `su silverbullet` at that uid unless PUID is set
("Will run SilverBullet with UID 1000, inferred from the owner of /space" —
measured against the pinned 2.9.0). Leave the space root-owned and the wiki
runs as root instead, writing root-owned pages that the git-sync sidecar
(uid 1000, and it must be 1000 to match) then cannot commit. Nothing
crashes; the mirror just stops working.

1000 is also the fleet's "content" uid — the same one /srv/stacks and
Forgejo's /data use (finding #10) — so the space, the repo it is pushed to
and the backup all agree on who owns the files.""",
    "tandoor": """\
Food domain — TWO stacks (stacks/tandoor, stacks/wger), one per app, because
both are Django and both read the BARE name SECRET_KEY out of their
environment.

Tandoor runs as ROOT (its Dockerfile has no USER instruction; nginx and
gunicorn both run as root, and boot.sh chmods the media root on every
start), so root:root is what it will write as.""",
    "tracking": """\
This stack alone carries THREE different ownership conventions, and
normalising any of them breaks it (annex §8):
  - bookstack is an LSIO image: it drops to PUID/PGID and runs
    `lsiown -R abc:abc /config` at every start, so 1000:1000 matches
    what it will enforce anyway.
  - its MariaDB starts as root and chowns its own datadir before
    dropping to mysql, so root:root is correct there.
  - homebox (default variant) runs as ROOT with no PUID/PGID and no
    chown-on-start.
  - karakeep MUST be root-owned: a non-root uid dies with EACCES on
    /app/apps/web/.next/cache, which is INSIDE the image, so chowning
    the host mount cannot fix it (upstream #1324, closed unfixed). This
    is the inverse of the /srv/stacks convention — do not "fix" it.""",
    "vaultwarden": """\
Runs as ROOT: the debian image declares no USER and start.sh execs the binary
directly, so root:root is what it will write as. That also matches
backup-prepare.sh, which reads db.sqlite3 from here as root.

The path is load-bearing beyond ownership: backup-prepare.sh hardcodes
/mnt/fast/vaultwarden/db.sqlite3, and sqlite_backup returns 0 for a MISSING
source — so moving this mount would turn the vault's only dump into a
permanent silent no-op rather than an error.""",
    "wealthfolio": """\
1000:1000, and the image will NOT heal a wrong owner: the Dockerfile ends
on USER 1000:1000 with no root entrypoint and no chown — the first write
to a root-owned /data fails and the container exits (upstream's own
upgrade doc is a manual chown -R 1000:1000). One directory carries the
whole stack: wealthfolio.db (SQLite, WAL) plus secrets.json (provider
API keys, encrypted with WF_SECRET_KEY).""",
    "wger": """\
🚨 Wger's media directory must be 1000:1000. Its base image does
`deluser ubuntu` then `adduser wger --uid 1000` and the production image
ends on `USER wger` — there is NO PUID/PGID, no id-remap entrypoint and
no chown-on-start, so a root-owned bind source makes collectstatic fail
on the very first boot. Finding #14's crash-loop pattern.""",
    "windmill": """\
Only the pgdata root — the DEPENDENCY CACHE is deliberately a named docker
volume and must never get a rule here: the image bakes CPython 3.11 and 3.12
into /tmp/windmill/cache at build time, a named volume is seeded from the
image on first use, and a bind mount is never seeded. Pointing it at
/mnt/fast would delete both interpreters, and UV_PYTHON_PREFERENCE=
only-managed forbids a system fallback, so the first Python job would try to
download one and hang offline.""",
}

# ---------------------------------------------------------------------------
# Per-directory overrides. Anything absent from this table is
# `0755 root root` — docker's own default, chosen deliberately here rather
# than inherited by accident.
# ---------------------------------------------------------------------------
# Every key must correspond to a directory the compose files actually imply;
# a stale key is an error, not a no-op, so this table cannot rot into a list
# of ownerships for paths nothing mounts any more.
DIR_NOTES: dict[str, dict] = {
    # --- actual --------------------------------------------------------
    "/mnt/fast/actual": {
        "owner": ("1001", "1001"),
        "note": """\
account.sqlite (server password, sessions, file index — and the
SimpleFIN credential once bank sync is set up) plus every budget file.
This IS the backup payload; no backup-prepare.sh line yet (evaluation
stack) — raw fast-volume include set only.""",
    },
    # --- komodo --------------------------------------------------------
    "/mnt/fast/komodo/pgdata": {
        "note": """\
The FerretDB backend datastore — Komodo's ENTIRE state as JSONB, so the
whole backup payload (captured by the pg_dumpall loop in backup-prepare.sh,
not a new mongodump path). root:root because the postgres image chowns its
own datadir to uid 999 before initdb drops privileges, the same reasoning
that makes the ghostfolio/outline/paperless pgdata roots root:root.""",
    },
    # --- media ---------------------------------------------------------
    "/mnt/slow/data": {"owner": ("1000", "1000")},
    "/mnt/slow/data/downloads": {
        "owner": ("1000", "1000"),
        "note": """\
Also bind sources in their own right (qbittorrent/scanner mount them
directly), so without rules docker would create them root-owned during
`up` — media-init heals ownership later, but only because it happens to
run as root; don't depend on that.""",
    },
    "/mnt/slow/data/media": {"owner": ("1000", "1000")},
    # --- immich --------------------------------------------------------
    "/mnt/slow/photos": {
        "note": """\
The photo originals tree (UPLOAD_LOCATION). Slow tier per the overview's
volume column: bulk, sequential.""",
    },
    # --- books ---------------------------------------------------------
    "/mnt/fast/shelfmark/config": {"owner": ("1000", "1000")},
    "/mnt/fast/shelfmark/tmp": {"owner": ("1000", "1000")},
    "/mnt/slow/books": {
        "owner": ("1000", "1000"),
        "note": """\
Both library trees live under /mnt/slow/books deliberately: backrest's
slow-volume-selective plan already includes that path, so they are backed
up without touching its config.""",
    },
    "/mnt/slow/books/audiobooks": {"owner": ("1000", "1000")},
    "/mnt/slow/books/drop": {
        "owner": ("1000", "1000"),
        "note": """\
🚨 The one directory TWO stacks share, and the whole of the coupling
between them (ServerNotes/designs/audiobook-acquisition.md, Option C).

WRITER: stacks/media's clamav-scanner, which runs as ROOT (the pinned
clamav image sets no USER and this service overrides the entrypoint), so
the ownership here does not constrain it. It moves a completed
`audiobooks` download in — a rename within /mnt/slow, so the entry keeps
the ownership qBittorrent gave it, which is 1000:1000 — and only after a
clean ClamAV verdict on every file in it.

READER: stacks/books' audiobookshelf, which mounts it :ro as a second
folder of its Audiobooks library. It runs as root and only reads, so the
1000:1000 here is for the third party: a human (or shelfmark, uid 1000)
reorganising a promoted book into /mnt/slow/books/audiobooks, which a
root-owned drop dir would make a sudo job.

Under /mnt/slow/books deliberately, like the two library trees: backrest's
slow-volume-selective plan includes that path, so a promoted audiobook is
backed up from the moment it lands and needs no backrest change.""",
    },
    "/mnt/slow/books/library": {"owner": ("1000", "1000")},
    # --- automation ----------------------------------------------------
    "/mnt/fast/mosquitto/config": {"owner": ("1883", "1883")},
    "/mnt/fast/mosquitto/data": {"owner": ("1883", "1883")},
    "/mnt/slow/frigate": {
        "note": """\
Recordings, clips and exports. Deliberately NOT in backrest's
slow-volume include list — it is an explicit allowlist and this path is
not on it, which is how many GB of re-recordable video stays out of the
backups. Do not add it.""",
    },
    # --- tracking ------------------------------------------------------
    "/mnt/fast/bookstack/config": {"owner": ("1000", "1000")},
    # --- firefly -------------------------------------------------------
    "/mnt/fast/firefly/upload": {"owner": ("33", "33")},
    # --- dawarich ------------------------------------------------------
    "/mnt/fast/dawarich/public": {"owner": ("1000", "1000")},
    "/mnt/fast/dawarich/storage": {"owner": ("1000", "1000")},
    "/mnt/fast/dawarich/watched": {"owner": ("1000", "1000")},
    "/mnt/fast/dawarich/redis": {
        "owner": ("999", "999"),
        "note": """\
The redis image runs as uid 999 and does NOT chown its data directory.
This holds the sidekiq queue: losing it drops in-flight import and
statistics jobs, which is survivable, but a wrong owner makes redis
exit at start and takes sidekiq with it.""",
    },
    # --- outline -------------------------------------------------------
    "/mnt/fast/outline/data": {
        "owner": ("1001", "1001"),
        "note": """\
🚨 1001:1001 — the `nodejs` user the image runs as, NOT 1000. Outline is
the only thing in this fleet on that uid, and nothing in the container
repairs it. FILE_STORAGE=local makes this directory the object store for
every attachment and avatar, so a root-owned copy is a wiki that works
until the first upload.""",
    },
    # --- notes-sync ----------------------------------------------------
    "/mnt/fast/rmfakecloud": {"owner": ("1000", "1000")},
    "/mnt/fast/rmfakecloud/data": {"owner": ("1000", "1000")},
    "/mnt/fast/syncthing": {"owner": ("1000", "1000")},
    "/mnt/fast/syncthing/config": {"owner": ("1000", "1000")},
    "/mnt/fast/vault": {"owner": ("1000", "1000")},
    # --- silverbullet --------------------------------------------------
    # Parent declared 1000:1000 too, matching forgejo's pattern: everything
    # under it belongs to the same content uid, and a root-owned parent with
    # a 1000-owned child invites exactly the "why can it not write here"
    # confusion these rules exist to end.
    "/mnt/fast/silverbullet": {"owner": ("1000", "1000")},
    "/mnt/fast/silverbullet/space": {
        "owner": ("1000", "1000"),
        "note": """\
🚨 This ownership IS the uid SilverBullet runs as — its entrypoint infers
PUID from the owner of the space (see the stack note above), so changing
this line changes the process, not just the file modes. It is also the git
working tree the sync sidecar (uid 1000) commits from and, being plain
markdown, the one thing in this stack that backrest's fast-volume plan
actually needs to capture.""",
    },
    # --- forgejo -------------------------------------------------------
    "/mnt/fast/forgejo": {"owner": ("1000", "1000")},
    "/mnt/fast/forgejo/data": {"owner": ("1000", "1000")},
    # --- wger ----------------------------------------------------------
    "/mnt/fast/wger/media": {"owner": ("1000", "1000")},
    # --- docspace ------------------------------------------------------
    "/mnt/fast/docspace/app": {
        "owner": ("104", "107"),
        "note": """\
104:107 = the image's `USER onlyoffice`. NOT load-bearing: the compose
file sets `user: root` following upstream, because the entrypoint edits
/etc/nginx and /app/onlyoffice/config before dropping into supervisord.
These are declared anyway so that dropping `user: root` later degrades
rather than breaking, and so the ownership matches what the app expects
if it ever drops privileges internally. (An earlier version of this
comment claimed root ownership was what broke the first suite run. It
was not — that was mysqldata below. Corrected rather than left to be
believed.)""",
    },
    "/mnt/fast/docspace/logs": {"owner": ("104", "107")},
    "/mnt/fast/docspace/mysqldata": {
        "owner": ("999", "999"),
        "note": """\
🚨 999:999, NOT root. The official mysql image drops to uid 999
(`mysql`) and `--initialize` refuses a data directory it cannot write:
"the designated data directory /var/lib/mysql/ is unusable". The
container then restart-loops while every other container in the project
comes up fine, so the visible symptom is `dependency failed to start`
on a service that has nothing wrong with it. This is finding #14
(seerr) in a second image — root-owned bind mounts are the default
docker would have chosen, which is exactly why these rules exist.""",
    },
    # --- gatus ---------------------------------------------------------
    "/mnt/fast/gatus": {
        "note": """\
Its SQLite history lives here; the container is on the HOST network and has
no ports: entry, which is why it needs a host-network-declared entry in
tests/lib/lints.nix.""",
    },
    # --- beszel --------------------------------------------------------
    "/mnt/fast/beszel": {
        "note": """\
The hub's directory holds data.db, the generated config.yml, and
id_ed25519 at 0600 — beszel-init writes the key mode itself, so this rule
only needs to own the parent.""",
    },
    "/mnt/fast/beszel-agent": {
        "note": """\
The agent's fingerprint file. It lives on the DATA disk on purpose:
./rebuild_os_proxmox.sh --build re-images the OS disk, and the fingerprint
is sha256 of the machine-id — a hub that has pinned the old one rejects
the agent outright after a routine re-image, visible only in hub logs.""",
    },
    "/mnt/fast/beszel-agent/fsprobe": {
        "note": """\
Two EMPTY marker directories, one per storage tier, bound read-only into
the agent at /extra-filesystems/*. Beszel reports filesystem usage via
statfs, which answers for the whole containing filesystem regardless of
which path on it is asked — verified against v0.18.8, where an empty
directory yielded `d: 3665.96, du: 114.19` for its device. So these give
the same numbers a wholesale /mnt/fast:ro bind would, without handing a
monitoring container a readable copy of every service's data.""",
    },
    # --- logging -------------------------------------------------------
    "/mnt/slow/loki": {
        "owner": ("10001", "10001"),
        "note": """\
🚨 10001:10001, NOT root — grafana/loki:3.7.7 sets USER 10001 in the
image. This one directory is the whole store: chunks/, tsdb-index/,
tsdb-cache/, wal/, compactor/ and rules/ are all created under it on
first start (verified by booting the pinned image against
stacks/logging/loki.yaml). Root-owned, Loki cannot create any of them
and exits during startup — and because Loki has no healthcheck the
first visible symptom is Alloy's pushes failing, one container away.

On /mnt/slow rather than /mnt/fast because log chunks are append-mostly
and query-rarely, which is what _overview.md's hardware section says
belongs on the 80 TB tier. It is also the reason this path needs a
NOT_BACKED_UP entry in tests/lib/lints.nix: the slow-volume plan is an
explicit include list and this is deliberately not on it.""",
    },
    "/mnt/fast/alloy": {
        "note": """\
root:root, and DELIBERATELY so rather than by default. grafana/alloy
sets no USER, so the collector runs as uid 0 — which is the mechanism
that lets it read the host journal at all (root:systemd-journal 0640).
This directory holds only the journal positions file and the write-ahead
log that buffers pushes across a Loki restart; both are regenerable, and
both are written as root.

⚠ If anyone ever adds `user:` to the alloy service, this rule and the
journal mounts both stop working, silently — the container stays healthy
and forwards nothing. Change the container and this note together.""",
    },
    "/mnt/fast/grafana": {
        "owner": ("472", "472"),
        "note": """\
🚨 472:472, NOT root — grafana/grafana:13.2.0 sets USER 472 (gid 0, the
OpenShift convention; owner-write is what matters here). grafana.db is
created in this directory on first start and is the only per-install
state the stack has: the datasource is provisioned from a read-only file
and the admin credential comes from .sops.env, so what is genuinely only
here is dashboards, users and history. It is dumped by
nixos/backup-prepare.sh with `sqlite3 .backup` because it is WAL-mode.

Root-owned this fails visibly rather than silently, unusually for this
table: Grafana's /api/health reports {"database":"ok"} from a real query,
so an unwritable directory shows up as an unhealthy container.""",
    },
    # --- wealthfolio ---------------------------------------------------
    "/mnt/fast/wealthfolio": {"owner": ("1000", "1000")},
    # --- samba ---------------------------------------------------------
    "/mnt/slow/samba/shared": {
        "mode": "0775",
        "owner": ("1000", "1000"),
        "note": """\
🚨 The share tree is 1000:1000, and that is a CONTRACT with
stacks/samba/config.yml's `auth:` entry, which creates the SMB user with
uid 1000 gid 1000 INSIDE the container via `adduser -u`. Nothing
connects the two but these two files agreeing. A mismatch is not a crash
— it is files nothing else in the fleet can read, found much later.
samba-init refuses to start on a mismatch and the suite measures it
(write over SMB, stat on the host).

0775 rather than 0755: the group bit is what lets a future second SMB
user share the tree without each file being private to whoever wrote it.""",
    },
}


# ---------------------------------------------------------------------------
# The shared logic. Everything below is used identically by the generator CLI
# and by the lints (tests/lib/lints.nix) — that is the point of the file.
# ---------------------------------------------------------------------------
def discover(repo: str) -> list[dict]:
    """Every compose file whose bind mounts land on the services VM.

    Globbed, never listed: a new stack directory is covered the moment it
    exists. komodo/ rides along because it is bootstrapped outside stacks/ but
    onto the same host (the deploy-plane manager, as arcane/ was before it).
    headscale-vps/authentik/ deliberately does NOT — it is a different machine
    with different filesystems.
    """
    entries = [
        {"stack": os.path.basename(os.path.dirname(p)), "path": p}
        for p in sorted(glob.glob(os.path.join(repo, "stacks", "*", "compose.yaml")))
    ]
    komodo = os.path.join(repo, "komodo", "compose.yaml")
    if os.path.exists(komodo):
        entries.append({"stack": "komodo", "path": komodo})
    return entries


def bind_sources(entries: list[dict]) -> dict[str, list[str]]:
    """path -> sorted stacks that bind-mount it, for every /mnt source."""
    sources: dict[str, set[str]] = {}
    for e in entries:
        with open(e["path"]) as f:
            compose = yaml.safe_load(f) or {}
        for svc in (compose.get("services") or {}).values():
            for v in svc.get("volumes") or []:
                src = v.split(":")[0] if isinstance(v, str) else (v.get("source") or "")
                src = src.rstrip("/")
                if src in TIER_MOUNTS or not SOURCE_RE.match(src):
                    continue
                sources.setdefault(src, set()).add(e["stack"])
    return {p: sorted(s) for p, s in sorted(sources.items())}


def directories(sources: dict[str, list[str]]) -> dict[str, list[str]]:
    """Bind sources plus their parents down to /mnt/<tier>/<name>.

    A parent needs a rule of its own: tmpfiles creates missing parents with
    the DEFAULT ownership, not the rule's, so declaring only /mnt/fast/x/y
    leaves /mnt/fast/x root-owned by accident rather than by decision.
    """
    dirs: dict[str, set[str]] = {}
    for path, stacks in sources.items():
        parts = path.split("/")
        for i in range(4, len(parts) + 1):
            dirs.setdefault("/".join(parts[:i]), set()).update(stacks)
    return {p: sorted(s) for p, s in sorted(dirs.items())}


def rule_for(path: str) -> str:
    spec = DIR_NOTES.get(path, {})
    mode = spec.get("mode", DEFAULT_MODE)
    user, group = spec.get("owner", DEFAULT_OWNER)
    return f"d {path} {mode} {user} {group} -"


def _check_tables(dirs: dict[str, list[str]], stacks: set[str]) -> None:
    stale_dirs = sorted(set(DIR_NOTES) - set(dirs))
    stale_stacks = sorted(set(STACK_NOTES) - stacks)
    problems = []
    for p in stale_dirs:
        problems.append(
            f"DIR_NOTES has an entry for {p}, which no compose file bind-mounts "
            f"(directly or as a parent). Remove it rather than leaving an "
            f"ownership decision for a path that no longer exists."
        )
    for s in stale_stacks:
        problems.append(
            f"STACK_NOTES has an entry for stack {s!r}, which has no /mnt bind "
            f"mounts. Remove it."
        )
    for s in sorted(stacks - set(STACK_NOTES)):
        problems.append(
            f"stack {s!r} bind-mounts /mnt paths but has no STACK_NOTES entry. "
            f"Add one saying WHY its ownerships are what they are — an empty "
            f"string is allowed when every directory is root:root for the "
            f"obvious reason, but the decision has to be made explicitly."
        )
    if problems:
        for p in problems:
            print("generate-stack-dirs: " + p, file=sys.stderr)
        sys.exit(1)


def render(entries: list[dict]) -> str:
    sources = bind_sources(entries)
    dirs = directories(sources)
    stacks = {s for ss in dirs.values() for s in ss}
    _check_tables(dirs, stacks)

    # A directory belongs to the alphabetically first stack that mounts it (or
    # mounts something under it). Deterministic, and today no /mnt directory is
    # shared between stacks anyway.
    by_stack: dict[str, list[str]] = {}
    for path, ss in dirs.items():
        by_stack.setdefault(ss[0], []).append(path)

    out = [HEADER]
    out.append("{\n  systemd.tmpfiles.rules = [\n")
    for stack in sorted(by_stack):
        out.append(f"    # === {stack} (bind sources in its compose.yaml) ===\n")
        note = STACK_NOTES.get(stack, "")
        if note:
            out.append(_comment(note, "    "))
        for path in sorted(by_stack[stack]):
            spec = DIR_NOTES.get(path, {})
            if spec.get("note"):
                out.append(_comment(spec["note"], "    "))
            out.append(f'    "{rule_for(path)}"\n')
    out.append("  ];\n}\n")
    return "".join(out)


def _comment(text: str, indent: str) -> str:
    return "".join(
        f"{indent}#\n" if not line else f"{indent}# {line}\n"
        for line in text.rstrip("\n").split("\n")
    )


HEADER = """\
# GENERATED FILE — DO NOT EDIT BY HAND.
#
#   Regenerate:  nixos/generate-stack-dirs.sh
#   Source:      stacks/*/compose.yaml + komodo/compose.yaml
#   Generator:   nixos/generate-stack-dirs.py (ownership table + prose live there)
#
# One `d` rule per /mnt bind-mount source named by a compose file, plus its
# parent directories. They exist because docker creates a missing bind source
# ROOT-OWNED at container start, which is the failure this fleet keeps hitting
# (finding #14: seerr's EACCES crash-loop, mysql refusing its datadir,
# syncthing reporting healthy with an errored folder).
#
# nixos/ is its own flake root and cannot read ../stacks/ at eval time, so this
# file is generated and CHECKED IN. The `stack-dirs-generated` lint re-runs the
# generator and byte-compares — drift is a build failure, exactly like
# ssh-pubkey-parity. Editing this file by hand is therefore not a shortcut; it
# is a lint failure. Change nixos/generate-stack-dirs.py instead.
#
# Rules that are NOT stack-derived (/srv, /var/lib/sops-nix, /mnt/fast/docker,
# the /srv/stacks 'Z' migration rule) stay hand-written in
# hardware-configuration.nix, which imports this file.
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo", help="repo root to glob compose files from")
    ap.add_argument("--manifest", help="JSON [{stack,path}] instead of --repo")
    ap.add_argument("--write", action="store_true", help="write nixos/stack-dirs.nix")
    ap.add_argument("--json", action="store_true", help="dump the enumeration")
    args = ap.parse_args()

    if args.manifest:
        entries = json.load(open(args.manifest))
    elif args.repo:
        entries = discover(args.repo)
    else:
        ap.error("one of --repo or --manifest is required")

    if args.json:
        sources = bind_sources(entries)
        dirs = directories(sources)
        stacks: dict[str, list[str]] = {}
        for path, ss in sources.items():
            for s in ss:
                stacks.setdefault(s, []).append(path)
        json.dump(
            {
                "sources": sources,
                "directories": dirs,
                "byStack": {s: sorted(p) for s, p in sorted(stacks.items())},
            },
            sys.stdout,
            indent=2,
            sort_keys=True,
        )
        print()
        return 0

    text = render(entries)
    if args.write:
        if not args.repo:
            ap.error("--write needs --repo")
        dest = os.path.join(args.repo, "nixos", "stack-dirs.nix")
        with open(dest, "w") as f:
            f.write(text)
        print(f"wrote {dest}", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
