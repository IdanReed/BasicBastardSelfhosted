#!/usr/bin/env python3
"""Generate nixos/stack-dirs.nix from the compose files.

Docker creates a missing bind-mount source ROOT-OWNED at container start, so
every /mnt bind source named by a compose file gets a `systemd.tmpfiles` 'd'
rule with a deliberate owner (finding #14).

nixos/ is its own flake root and cannot read ../stacks/ at eval time, so the
output is CHECKED IN and the `stack-dirs-generated` lint re-runs this and
byte-compares.

USAGE
-----
    nixos/generate-stack-dirs.sh              # regenerate nixos/stack-dirs.nix

    python3 generate-stack-dirs.py --repo <repo-root>            # to stdout
    python3 generate-stack-dirs.py --repo <repo-root> --write
    python3 generate-stack-dirs.py --manifest m.json --json      # for the lints

`--manifest` takes [{"stack": ..., "path": ...}, ...] so the lints can feed
their own compose discovery through this same code path.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys

import yaml

# Whole-tier mounts are real filesystems declared in hardware-configuration.nix
# and stacks/backrest mounts both wholesale (:ro); a tmpfiles rule for them
# would fight the mount unit for ownership of a mountpoint.
TIER_MOUNTS = {"/mnt", "/mnt/fast", "/mnt/slow"}

# Only /mnt/{fast,slow} sources are ours; anything else a compose file binds is
# system state or repo content, owned elsewhere.
SOURCE_RE = re.compile(r"^/mnt/(fast|slow)/")

DEFAULT_MODE = "0755"
DEFAULT_OWNER = ("root", "root")


# ---------------------------------------------------------------------------
# Per-stack prose
# ---------------------------------------------------------------------------
# A stack that gains /mnt bind mounts with no entry here makes this script exit
# nonzero (_check_tables): root:root is also docker's default, so inheriting it
# silently is indistinguishable from choosing it. An empty string is a valid
# entry. A stale entry is an error too.
#
# komodo/compose.yaml is scanned despite living outside stacks/, because the
# deploy plane is bootstrapped onto the same host.
STACK_NOTES = {
    "actual": """\
1001:1001 — the uid the compose PINS with `user: "1001:1001"`. The image
ships no USER and nothing in it chowns, and the create-folders migration
mkdirs under /data before the server binds, so a root-owned source is a
container that exits at start (finding #14).""",
    "automation": """\
home assistant runs as ROOT with no PUID/PGID, and its /config must stay
WRITABLE: .HA_VERSION is rewritten on every version change, unguarded.
mosquitto starts as root and drops to uid 1883, but its 2.x entrypoint
chowns only /mosquitto/data — so both directories are declared 1883
rather than relying on the image to heal them (finding #14).
frigate runs as root.""",
    "backrest": """\
All root:root. Backrest must run as root to read every service's data
through the /mnt/{fast,slow}:ro mounts, and config-init is plain alpine.
config/ must stay WRITABLE: Backrest rewrites config.json on every UI
change.""",
    "beszel": "",
    "books": """\
kavita runs as ROOT (its PUID/PGID block is commented out upstream) and
hard-exits if it cannot write /kavita/config; that directory must stay
WRITABLE or the published placeholder JWT key silently stays in play.
audiobookshelf runs as ROOT too, with no PUID/PGID mechanism.
shelfmark drops to PUID/PGID (1000) and chowns /config itself, so
1000:1000 just leaves it nothing to do.
The /mnt/slow trees are 1000:1000: shelfmark (uid 1000) writes the ebook
tree, and audiobooks arrive from the MEDIA stack via
/mnt/slow/books/drop. Kavita and audiobookshelf mount theirs :ro.""",
    "caddy": """\
root:root. The image runs as root — it binds 80/443 under
network_mode: host — so the ACME account key and the issued certificates
under data/ are written as root.""",
    "dawarich": """\
Both entrypoints gosu-drop to PUID/PGID *only if* they start as uid 0,
chowning first, which is why the compose sets no `user:` and these are
1000:1000. Setting `user:` there skips the chown branch and crash-loops
on a root-owned mount; upstream warns about it inline, twice.""",
    "docspace": """\
Three containers, three non-root uids, and getting one wrong shows up as
`dependency failed to start` naming a container that is fine:
  docspace       uid 104 gid 107 (USER onlyoffice) — but the compose runs
                 `user: root` following upstream, because the entrypoint
                 edits /etc/nginx before dropping into supervisord.
  docspace_db    uid 999 (mysql drops before --initialize)
  docspace_ds    root — chowns its own mounts every start; never set
                 `user:` on it, that skips the chown branch.
The DS and monolith trees are SEPARATE here, unlike upstream's shared
volume — which is what makes the Backrest exclude for the document cache
expressible at all.""",
    "excalidraw": """\
Only the pgdata root: the three app containers are stateless by design,
scene blobs live in a second database in the same cluster
(stacks/excalidraw/keyv-init.sql). Postgres chowns its own datadir.""",
    "firefly": """\
The image ends on `USER www-data` at BUILD time and never remaps ids, so
PUID/PGID are inert and the upload directory must be pre-owned 33:33 or
attachment upload fails at runtime with no startup symptom at all. Its
Postgres chowns its own datadir.""",
    "forgejo": """\
1000:1000, matching the USER_UID/USER_GID the compose sets. /data holds
app.ini — the SECRET_KEY, INTERNAL_TOKEN and JWT secrets Forgejo
self-generates on first start — plus gitea.db and every repository,
including the compose repo stack-git-sync pulls from. There is no
.sops.env for this stack precisely because that material lives here.""",
    "gatus": "",
    "ghostfolio": """\
One directory, root:root: the only /mnt mount is the Postgres datadir,
and the image chowns it to uid 999 before initdb drops privileges. The
app container has no /mnt mount at all and its Redis deliberately has no
volume, so the whole backup story is the pg_dumpall of ghostfolio_db.""",
    "logging": """\
Three containers, three answers, each read out of the pinned image:
  victorialogs  ROOT — the image sets User "0", NOT the old loki's 10001.
  grafana       uid 472 — the image sets USER 472; owner-write is what
                /var/lib/grafana needs, and grafana.db is created there.
  alloy         ROOT — the image sets no USER, and uid 0 is what lets it
                read the journal (root:systemd-journal 0640 under 2755
                directories). A `user:` without gid 62 would give a
                healthy process that collects nothing.
The read-only journal mounts (/var/log/journal, /etc/machine-id) are
system paths, not per-stack bind sources, and must never enter this
table.""",
    "immich": """\
root:root everywhere on purpose: the immich images have no PUID/PGID and
run as root, the postgres image chowns pgdata itself, and
immich-config-init (alpine, root) writes the 0600 immich.json. Finding
#14 does not apply, but the rules still must exist — docker creates a
missing bind source with no say over the parent /mnt/fast/immich.""",
    "komodo": """\
All root:root. Core keeps all its state in the Mongo-wire DB and has no
/mnt source; Periphery mounts the docker socket and /srv/stacks (neither
a /mnt source) and runs as root, so it reads the 0600 .env files;
FerretDB is stateless; Postgres is the only stateful component and
chowns its own datadir to uid 999 from a root entrypoint. The age key
never enters any of them — decrypt-sops-envs and stack-git-sync are host
units.""",
    "mealie": """\
root:root is fine and any hand-fix is futile: entry.sh runs
`chown -R $PUID:$PGID /app` — which includes the bind-mounted /app/data —
on EVERY start, then gosu-drops to 911:911. This ends up 911:911 within
seconds of first `up` regardless of the rule.""",
    "media": """\
Declared here rather than left to docker's create-on-mount, which is what
made seerr crash-loop on first deploy (finding #14), and because nothing
else would create /mnt/slow/data with the uid the hardlink layout needs.
The media suite mirrors this exact set; keep the two in sync.

root:root is correct for the config roots: the LSIO images chown per
PUID/PGID from a root entrypoint, jellyfin/gluetun/profilarr run as root,
seerr-init chowns seerr's config, and clamav 1.5's /init chowns
/var/lib/clamav unconditionally before starting clamd. /mnt/slow/data is
1000:1000 — every media container works there as uid 1000.

This stack also binds /mnt/slow/books/drop, which BELONGS TO THE BOOKS
STACK: clamav-scanner moves a clean audiobook download in and
audiobookshelf reads it :ro. Nothing else crosses.""",
    "notes-sync": """\
All 1000:1000, for two different reasons:
  - rmfakecloud is FROM scratch with no entrypoint and no PUID/PGID, so
    it cannot fix anything itself. Its compose pins `user: "1000:1000"`
    (Windmill later reads this tree as uid 1000), so the ownership MUST
    come from here.
  - syncthing's entrypoint chown is non-recursive: it fixes
    /var/syncthing and nothing beneath it, so config/ and every synced
    tree must be pre-owned. Getting it wrong yields a HEALTHY container
    with an errored folder.""",
    "ntfy": """\
root:root — the image declares no USER and the compose sets none. lib/
holds the auth database and the attachment store; cache/ holds the
transient recent-message buffer. This is the path every failure in the
fleet is reported through, so a silent failure to start takes the alert
path with it.""",
    "outline": """\
1001:1001 for the app's data directory: the image ends on `USER nodejs`
(uid 1001) and its entrypoint chowns nothing. Its Postgres chowns its own
datadir, and redis deliberately has no volume at all.""",
    "paperless": """\
root:root for all five: the entrypoint runs as root, maps its
`paperless` user onto USERMAP_UID/USERMAP_GID (1000 here) and chowns
data/media/consume/export before dropping privileges, and the postgres
image chowns pgdata itself.""",
    "proton": """\
hydroxide runs as USER hydroxide (uid 1000) with no chown-on-start, so
its directory must be pre-owned or the one-time `auth` can never write
auth.json — serve stays green and every login fails.
The isync image (proton-export) sets no USER and runs as root, so the
maildir archive stays root:root. No database anywhere; backup is the
slow-volume-selective plan, not a dump.""",
    "samba": """\
smbd runs as ROOT and must — it setuids per connection — so /data is
root-owned.""",
    "silverbullet": """\
1000:1000, and here the ownership DECIDES THE UID THE SERVER RUNS AS: the
entrypoint reads the owner of $SB_FOLDER and re-execs at that uid unless
PUID is set. Leave the space root-owned and the wiki runs as root,
writing pages the git-sync sidecar (uid 1000) cannot commit — nothing
crashes, the mirror just stops. 1000 is also the fleet's content uid
(finding #10).""",
    "tandoor": """\
Runs as ROOT: no USER instruction, nginx and gunicorn both root, and
boot.sh chmods the media root on every start.""",
    "tracking": """\
Three ownership conventions in one stack; normalising any breaks it:
  - bookstack is LSIO: it drops to PUID/PGID and runs
    `lsiown -R abc:abc /config`, so 1000:1000 matches what it enforces.
  - its MariaDB chowns its own datadir before dropping to mysql.
  - homebox runs as ROOT with no PUID/PGID and no chown-on-start.
  - karakeep MUST be root-owned: a non-root uid dies with EACCES on
    /app/apps/web/.next/cache, which is INSIDE the image, so chowning the
    host mount cannot fix it (upstream #1324, closed unfixed).""",
    "vaultwarden": """\
Runs as ROOT: the debian image declares no USER and start.sh execs the
binary directly. The path is load-bearing beyond ownership —
backup-prepare.sh hardcodes /mnt/fast/vaultwarden/db.sqlite3 and
sqlite_backup returns 0 for a MISSING source, so moving this mount turns
the vault's only dump into a permanent silent no-op.""",
    "wealthfolio": """\
1000:1000, and the image will NOT heal a wrong owner: the Dockerfile ends
on USER 1000:1000 with no root entrypoint and no chown, so the first
write to a root-owned /data exits the container. One directory carries
wealthfolio.db (SQLite, WAL) and secrets.json.""",
    "wger": """\
1000:1000. The base image does `deluser ubuntu` then
`adduser wger --uid 1000` and the production image ends on `USER wger` —
no PUID/PGID, no id-remap entrypoint, no chown-on-start — so a root-owned
bind source fails collectstatic on the very first boot (finding #14).""",
    "windmill": """\
Only the pgdata root. The dependency cache is deliberately a named docker
volume and must never get a rule here: the image bakes CPython 3.11 and
3.12 into /tmp/windmill/cache at build time, a named volume is seeded
from the image and a bind mount is not, and
UV_PYTHON_PREFERENCE=only-managed forbids a system fallback.""",
}


# ---------------------------------------------------------------------------
# Per-directory overrides
# ---------------------------------------------------------------------------
# Anything absent is `0755 root root` — docker's own default, chosen here
# rather than inherited. A key for a path no compose file implies is an error.
DIR_NOTES: dict[str, dict] = {
    # --- actual --------------------------------------------------------
    "/mnt/fast/actual": {
        "owner": ("1001", "1001"),
        "note": """\
account.sqlite (server password, sessions, file index, the SimpleFIN
credential) plus every budget file — the whole backup payload. No
backup-prepare.sh line yet: raw fast-volume include set only.""",
    },
    # --- excalidraw ----------------------------------------------------
    "/mnt/fast/excalidraw/pgdata": {
        "note": """\
Both AstraDraw databases (`excalidraw` for metadata, `excalidraw_storage`
for the scene payloads) — the whole backup payload, captured by the
pg_dumpall loop. root:root because the postgres image chowns its own
datadir before initdb drops privileges.""",
    },
    # --- komodo --------------------------------------------------------
    "/mnt/fast/komodo/pgdata": {
        "note": """\
The FerretDB backend — Komodo's entire state as JSONB, captured by the
pg_dumpall loop rather than a mongodump path. root:root because the
postgres image chowns its own datadir to uid 999 before initdb drops
privileges.""",
    },
    # --- media ---------------------------------------------------------
    "/mnt/slow/data": {"owner": ("1000", "1000")},
    "/mnt/slow/data/downloads": {
        "owner": ("1000", "1000"),
        "note": """\
Also bind sources in their own right (qbittorrent/scanner mount them
directly), so without rules docker creates them root-owned during `up`.
media-init heals them later only because it happens to run as root.""",
    },
    "/mnt/slow/data/media": {"owner": ("1000", "1000")},
    # --- immich --------------------------------------------------------
    "/mnt/slow/photos": {
        "note": "The photo originals tree (UPLOAD_LOCATION). Slow tier: bulk, sequential.",
    },
    # --- books ---------------------------------------------------------
    "/mnt/fast/shelfmark/config": {"owner": ("1000", "1000")},
    "/mnt/fast/shelfmark/tmp": {"owner": ("1000", "1000")},
    "/mnt/slow/books": {
        "owner": ("1000", "1000"),
        "note": """\
Both library trees live under /mnt/slow/books deliberately: backrest's
slow-volume-selective plan already includes that path.""",
    },
    "/mnt/slow/books/audiobooks": {"owner": ("1000", "1000")},
    "/mnt/slow/books/drop": {
        "owner": ("1000", "1000"),
        "note": """\
The one directory TWO stacks share
(ServerNotes/designs/audiobook-acquisition.md, Option C). stacks/media's
clamav-scanner (root) moves a completed `audiobooks` download in after a
clean verdict; stacks/books' audiobookshelf mounts it :ro. The 1000:1000
is for the third party: a human or shelfmark reorganising a promoted book
into /mnt/slow/books/audiobooks, which a root-owned drop dir would make a
sudo job.""",
    },
    "/mnt/slow/books/library": {"owner": ("1000", "1000")},
    # --- automation ----------------------------------------------------
    "/mnt/fast/mosquitto/config": {"owner": ("1883", "1883")},
    "/mnt/fast/mosquitto/data": {"owner": ("1883", "1883")},
    "/mnt/slow/frigate": {
        "note": """\
Recordings, clips and exports. Deliberately NOT in backrest's slow-volume
include list — that is how many GB of re-recordable video stays out of
the backups. Do not add it.""",
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
This holds the sidekiq queue: a wrong owner makes redis exit at start and
takes sidekiq with it.""",
    },
    # --- outline -------------------------------------------------------
    "/mnt/fast/outline/data": {
        "owner": ("1001", "1001"),
        "note": """\
1001:1001 — the `nodejs` user the image runs as, NOT 1000, and nothing in
the container repairs it. FILE_STORAGE=local makes this the object store
for every attachment, so a root-owned copy is a wiki that works until the
first upload.""",
    },
    # --- notes-sync ----------------------------------------------------
    "/mnt/fast/rmfakecloud": {"owner": ("1000", "1000")},
    "/mnt/fast/rmfakecloud/data": {"owner": ("1000", "1000")},
    "/mnt/fast/syncthing": {"owner": ("1000", "1000")},
    "/mnt/fast/syncthing/config": {"owner": ("1000", "1000")},
    "/mnt/fast/vault": {"owner": ("1000", "1000")},
    # --- silverbullet --------------------------------------------------
    # Parent is 1000:1000 too, matching forgejo: everything under it belongs
    # to the same content uid.
    "/mnt/fast/silverbullet": {"owner": ("1000", "1000")},
    "/mnt/fast/silverbullet/space": {
        "owner": ("1000", "1000"),
        "note": """\
This ownership IS the uid SilverBullet runs as — its entrypoint infers
PUID from the owner of the space — so changing this line changes the
process, not just the file modes. It is also the git working tree the
sync sidecar (uid 1000) commits from.""",
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
104:107 = the image's `USER onlyoffice`. Not load-bearing today — the
compose sets `user: root` following upstream — but declared so that
dropping `user: root` later degrades rather than breaks.""",
    },
    "/mnt/fast/docspace/logs": {"owner": ("104", "107")},
    "/mnt/fast/docspace/mysqldata": {
        "owner": ("999", "999"),
        "note": """\
999:999, NOT root. The mysql image drops to uid 999 and `--initialize`
refuses a data directory it cannot write, then restart-loops while every
other container comes up fine — so the visible symptom is `dependency
failed to start` on a service that has nothing wrong with it.""",
    },
    # --- gatus ---------------------------------------------------------
    "/mnt/fast/gatus": {
        "note": """\
Its SQLite history. The container is on the HOST network with no `ports:`
entry, which is why it needs a host-network-declared entry in
tests/lib/lints.nix.""",
    },
    # --- beszel --------------------------------------------------------
    "/mnt/fast/beszel": {
        "note": """\
Holds data.db, the generated config.yml and id_ed25519 at 0600 —
beszel-init writes the key mode itself, so this rule only owns the
parent.""",
    },
    "/mnt/fast/beszel-agent": {
        "note": """\
The agent's fingerprint file, on the DATA disk on purpose:
rebuild_os_proxmox.sh --build re-images the OS disk, and the fingerprint
is sha256 of the machine-id — a hub that pinned the old one rejects the
agent after a routine re-image, visible only in hub logs.""",
    },
    "/mnt/fast/beszel-agent/fsprobe": {
        "note": """\
Two EMPTY marker directories, one per storage tier, bound read-only into
the agent. Beszel reports usage via statfs, which answers for the whole
containing filesystem regardless of the path asked — so these give the
same numbers a wholesale /mnt/fast:ro bind would, without handing a
monitoring container a readable copy of every service's data.""",
    },
    # --- logging -------------------------------------------------------
    "/mnt/slow/victorialogs": {
        "note": """\
root:root, matching the image: victoria-logs runs as User "0", NOT the
old loki's 10001 — worth re-reading on every upgrade. This one directory
is the whole store, trimmed by -retention.maxDiskSpaceUsageBytes in
stacks/logging/compose.yaml. On /mnt/slow because log data is
append-mostly, and deliberately off the slow-volume plan — hence its
NOT_BACKED_UP entry in tests/lib/lints.nix.""",
    },
    "/mnt/fast/alloy": {
        "note": """\
root:root deliberately: grafana/alloy sets no USER, and uid 0 is the
mechanism that lets it read the host journal (root:systemd-journal 0640).
Adding `user:` to that service silently breaks collection — the container
stays healthy and forwards nothing. Holds only the positions file and the
write-ahead log, both regenerable.""",
    },
    "/mnt/fast/grafana": {
        "owner": ("472", "472"),
        "note": """\
472:472, NOT root — the image sets USER 472. grafana.db is created here
on first start and is the only per-install state (the datasource is
provisioned read-only and the admin credential comes from .sops.env);
backup-prepare.sh dumps it with `sqlite3 .backup` because it is WAL-mode.
Root-owned this fails visibly for once: /api/health reports the
database.""",
    },
    # --- proton --------------------------------------------------------
    "/mnt/fast/proton/hydroxide": {
        "owner": ("1000", "1000"),
        "note": """\
auth.json — the Proton refresh token and passwords, encrypted with a key
derived from the bridge password in .sops.env; neither half is useful
alone. Written by the one-time `hydroxide auth` as uid 1000; nothing
in-container repairs a wrong owner.""",
    },
    "/mnt/slow/proton-mail-archive": {
        "note": """\
The mail export — a full-mailbox maildir, append-only by construction
(mbsyncrc: Sync Pull + Expunge None). Slow tier, and unlike the log store
it IS backed up: slow-volume-selective names it.""",
    },
    # --- wealthfolio ---------------------------------------------------
    "/mnt/fast/wealthfolio": {"owner": ("1000", "1000")},
    # --- samba ---------------------------------------------------------
    "/mnt/slow/samba/shared": {
        "mode": "0775",
        "owner": ("1000", "1000"),
        "note": """\
1000:1000 is a CONTRACT with stacks/samba/config.yml's `auth:` entry,
which creates the SMB user with uid 1000 gid 1000 inside the container.
Nothing connects the two but these two files agreeing; samba-init refuses
to start on a mismatch. 0775 rather than 0755 so the other SMB users (all
gid 1000) can share the tree.""",
    },
    # Per-user private trees: ONE shared gid (1000) so everyone can use
    # `shared`, DISTINCT uids so each personal dir is private. Each uid must
    # match config.yml's `auth:`; samba-init refuses to start on a mismatch.
    "/mnt/slow/samba/personal": {
        "mode": "0755",
        "owner": ("root", "root"),
        "note": """\
Parent of the per-user private trees. Nobody writes here; o+x lets each
SMB user traverse into their own 0700 subdir.""",
    },
    "/mnt/slow/samba/personal/idan": {"mode": "0700", "owner": ("1000", "1000")},
    "/mnt/slow/samba/personal/alondra": {"mode": "0700", "owner": ("1001", "1000")},
    "/mnt/slow/samba/personal/cale": {"mode": "0700", "owner": ("1002", "1000")},
    "/mnt/slow/samba/personal/zach": {"mode": "0700", "owner": ("1003", "1000")},
    "/mnt/slow/samba/personal/rylan": {"mode": "0700", "owner": ("1004", "1000")},
    "/mnt/slow/samba/personal/cameron": {"mode": "0700", "owner": ("1005", "1000")},
    "/mnt/slow/samba/personal/justin": {"mode": "0700", "owner": ("1006", "1000")},
}


# ---------------------------------------------------------------------------
# Shared logic — used identically by the generator CLI and by the lints
# ---------------------------------------------------------------------------
def discover(repo: str) -> list[dict]:
    """Every compose file whose bind mounts land on the services VM.

    Globbed, never listed. komodo/ rides along because it is bootstrapped
    outside stacks/ but onto the same host; headscale-vps/authentik/ does not,
    being a different machine with different filesystems.
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

    A parent needs a rule of its own: tmpfiles creates missing parents with the
    DEFAULT ownership, not the rule's.
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

    # A directory belongs to the alphabetically first stack that mounts it.
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
# parents, because docker creates a missing bind source ROOT-OWNED at container
# start (finding #14). The `stack-dirs-generated` lint re-runs the generator and
# byte-compares, so editing this file by hand is a lint failure.
#
# Rules that are NOT stack-derived (/srv, /var/lib/sops-nix, /mnt/fast/docker,
# the /srv/stacks 'Z' rule) stay hand-written in hardware-configuration.nix,
# which imports this file.
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo", help="repo root to glob compose files from")
    ap.add_argument("--manifest", help="JSON [{stack,path}] instead of --repo")
    ap.add_argument("--write", action="store_true", help="write nixos/stack-dirs.nix")
    ap.add_argument("--json", action="store_true", help="dump the enumeration")
    args = ap.parse_args()

    if args.manifest:
        with open(args.manifest) as f:
            entries = json.load(f)
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
