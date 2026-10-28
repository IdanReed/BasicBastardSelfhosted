# GENERATED FILE — DO NOT EDIT BY HAND.
#
#   Regenerate:  nixos/generate-stack-dirs.sh
#   Source:      stacks/*/compose.yaml + komodo/compose.yaml + forgejo/compose.yaml
#   Generator:   nixos/generate-stack-dirs.py (ownership table + prose live there)
#
# One `d` rule per /mnt bind-mount source named by a compose file, plus its
# parents, because docker creates a missing bind source ROOT-OWNED at container
# start (finding #14). The `stack-dirs-generated` lint re-runs the generator and
# byte-compares, so editing this file by hand is a lint failure.
#
# Rules that are NOT stack-derived (/srv, /srv/komodo, /var/lib/sops-nix,
# /mnt/fast/docker) stay hand-written in hardware-configuration.nix,
# which imports this file.
{
  systemd.tmpfiles.rules = [
    # === actual (bind sources in its compose.yaml) ===
    # 1001:1001 — the uid the compose PINS with `user: "1001:1001"`. The image
    # ships no USER and nothing in it chowns, and the create-folders migration
    # mkdirs under /data before the server binds, so a root-owned source is a
    # container that exits at start (finding #14).
    # account.sqlite (server password, sessions, file index, the SimpleFIN
    # credential) plus every budget file — the whole backup payload. No
    # backup-prepare.sh line yet: raw fast-volume include set only.
    "d /mnt/fast/actual 0755 1001 1001 -"
    # === automation (bind sources in its compose.yaml) ===
    # home assistant runs as ROOT with no PUID/PGID, and its /config must stay
    # WRITABLE: .HA_VERSION is rewritten on every version change, unguarded.
    # mosquitto starts as root and drops to uid 1883, but its 2.x entrypoint
    # chowns only /mosquitto/data — so both directories are declared 1883
    # rather than relying on the image to heal them (finding #14).
    # frigate runs as root.
    "d /mnt/fast/frigate 0755 root root -"
    "d /mnt/fast/frigate/config 0755 root root -"
    "d /mnt/fast/homeassistant 0755 root root -"
    "d /mnt/fast/mosquitto 0755 root root -"
    "d /mnt/fast/mosquitto/config 0755 1883 1883 -"
    "d /mnt/fast/mosquitto/data 0755 1883 1883 -"
    # Recordings, clips and exports. Deliberately NOT in backrest's slow-volume
    # include list — that is how many GB of re-recordable video stays out of
    # the backups. Do not add it.
    "d /mnt/slow/frigate 0755 root root -"
    # === backrest (bind sources in its compose.yaml) ===
    # All root:root. Backrest must run as root to read every service's data
    # through the /mnt/{fast,slow}:ro mounts, and config-init is plain alpine.
    # config/ must stay WRITABLE: Backrest rewrites config.json on every UI
    # change.
    "d /mnt/fast/backrest 0755 root root -"
    "d /mnt/fast/backrest/cache 0755 root root -"
    "d /mnt/fast/backrest/config 0755 root root -"
    "d /mnt/fast/backrest/data 0755 root root -"
    # === beszel (bind sources in its compose.yaml) ===
    # Holds data.db, the generated config.yml and id_ed25519 at 0600 —
    # beszel-init writes the key mode itself, so this rule only owns the
    # parent.
    "d /mnt/fast/beszel 0755 root root -"
    # The agent's fingerprint file, on the DATA disk on purpose:
    # rebuild_os_proxmox.sh --build re-images the OS disk, and the fingerprint
    # is sha256 of the machine-id — a hub that pinned the old one rejects the
    # agent after a routine re-image, visible only in hub logs.
    "d /mnt/fast/beszel-agent 0755 root root -"
    # Two EMPTY marker directories, one per storage tier, bound read-only into
    # the agent. Beszel reports usage via statfs, which answers for the whole
    # containing filesystem regardless of the path asked — so these give the
    # same numbers a wholesale /mnt/fast:ro bind would, without handing a
    # monitoring container a readable copy of every service's data.
    "d /mnt/fast/beszel-agent/fsprobe 0755 root root -"
    "d /mnt/slow/beszel-fsprobe 0755 root root -"
    # === books (bind sources in its compose.yaml) ===
    # kavita runs as ROOT (its PUID/PGID block is commented out upstream) and
    # hard-exits if it cannot write /kavita/config; that directory must stay
    # WRITABLE or the published placeholder JWT key silently stays in play.
    # audiobookshelf runs as ROOT too, with no PUID/PGID mechanism.
    # shelfmark drops to PUID/PGID (1000) and chowns /config itself, so
    # 1000:1000 just leaves it nothing to do.
    # The /mnt/slow trees are 1000:1000: shelfmark (uid 1000) writes the ebook
    # tree, and audiobooks arrive from the MEDIA stack via
    # /mnt/slow/books/drop. Kavita and audiobookshelf mount theirs :ro.
    "d /mnt/fast/audiobookshelf 0755 root root -"
    "d /mnt/fast/audiobookshelf/config 0755 root root -"
    "d /mnt/fast/audiobookshelf/metadata 0755 root root -"
    "d /mnt/fast/kavita 0755 root root -"
    "d /mnt/fast/kavita/config 0755 root root -"
    "d /mnt/fast/shelfmark 0755 root root -"
    "d /mnt/fast/shelfmark/config 0755 1000 1000 -"
    "d /mnt/fast/shelfmark/tmp 0755 1000 1000 -"
    # Both library trees live under /mnt/slow/books deliberately: backrest's
    # slow-volume-selective plan already includes that path.
    "d /mnt/slow/books 0755 1000 1000 -"
    "d /mnt/slow/books/audiobooks 0755 1000 1000 -"
    # The one directory TWO stacks share
    # (ServerNotes/designs/audiobook-acquisition.md, Option C). stacks/media's
    # clamav-scanner (root) moves a completed `audiobooks` download in after a
    # clean verdict; stacks/books' audiobookshelf mounts it :ro. The 1000:1000
    # is for the third party: a human or shelfmark reorganising a promoted book
    # into /mnt/slow/books/audiobooks, which a root-owned drop dir would make a
    # sudo job.
    "d /mnt/slow/books/drop 0755 1000 1000 -"
    "d /mnt/slow/books/library 0755 1000 1000 -"
    # === caddy (bind sources in its compose.yaml) ===
    # root:root. The image runs as root — it binds 80/443 under
    # network_mode: host — so the ACME account key and the issued certificates
    # under data/ are written as root.
    "d /mnt/fast/caddy 0755 root root -"
    "d /mnt/fast/caddy/config 0755 root root -"
    "d /mnt/fast/caddy/data 0755 root root -"
    # === dawarich (bind sources in its compose.yaml) ===
    # Both entrypoints gosu-drop to PUID/PGID *only if* they start as uid 0,
    # chowning first, which is why the compose sets no `user:` and these are
    # 1000:1000. Setting `user:` there skips the chown branch and crash-loops
    # on a root-owned mount; upstream warns about it inline, twice.
    "d /mnt/fast/dawarich 0755 root root -"
    "d /mnt/fast/dawarich/pgdata 0700 70 70 -"
    "d /mnt/fast/dawarich/public 0755 1000 1000 -"
    # The redis image runs as uid 999 and does NOT chown its data directory.
    # This holds the sidekiq queue: a wrong owner makes redis exit at start and
    # takes sidekiq with it.
    "d /mnt/fast/dawarich/redis 0755 999 999 -"
    "d /mnt/fast/dawarich/storage 0755 1000 1000 -"
    "d /mnt/fast/dawarich/watched 0755 1000 1000 -"
    # === docspace (bind sources in its compose.yaml) ===
    # Three containers, three non-root uids, and getting one wrong shows up as
    # `dependency failed to start` naming a container that is fine:
    #   docspace       uid 104 gid 107 (USER onlyoffice) — but the compose runs
    #                  `user: root` following upstream, because the entrypoint
    #                  edits /etc/nginx before dropping into supervisord.
    #   docspace_db    uid 999 (mysql drops before --initialize)
    #   docspace_ds    root — chowns its own mounts every start; never set
    #                  `user:` on it, that skips the chown branch.
    # The DS and monolith trees are SEPARATE here, unlike upstream's shared
    # volume — which is what makes the Backrest exclude for the document cache
    # expressible at all.
    "d /mnt/fast/docspace 0755 root root -"
    # 104:107 = the image's `USER onlyoffice`. Not load-bearing today — the
    # compose sets `user: root` following upstream — but declared so that
    # dropping `user: root` later degrades rather than breaks.
    "d /mnt/fast/docspace/app 0755 104 107 -"
    "d /mnt/fast/docspace/ds-data 0755 root root -"
    "d /mnt/fast/docspace/ds-lib 0755 root root -"
    "d /mnt/fast/docspace/ds-logs 0755 root root -"
    "d /mnt/fast/docspace/logs 0755 104 107 -"
    # 999:999, NOT root. The mysql image drops to uid 999 and `--initialize`
    # refuses a data directory it cannot write, then restart-loops while every
    # other container comes up fine — so the visible symptom is `dependency
    # failed to start` on a service that has nothing wrong with it.
    "d /mnt/fast/docspace/mysqldata 0755 999 999 -"
    # === excalidraw (bind sources in its compose.yaml) ===
    # Only the pgdata root: the three app containers are stateless by design,
    # scene blobs live in a second database in the same cluster
    # (stacks/excalidraw/keyv-init.sql). Postgres chowns its own datadir.
    "d /mnt/fast/excalidraw 0755 root root -"
    # Both AstraDraw databases (`excalidraw` for metadata, `excalidraw_storage`
    # for the scene payloads) — the whole backup payload, captured by the
    # pg_dumpall loop.
    "d /mnt/fast/excalidraw/pgdata 0700 70 70 -"
    # === firefly (bind sources in its compose.yaml) ===
    # The image ends on `USER www-data` at BUILD time and never remaps ids, so
    # PUID/PGID are inert and the upload directory must be pre-owned 33:33 or
    # attachment upload fails at runtime with no startup symptom at all. Its
    # Postgres chowns its own datadir.
    "d /mnt/fast/firefly 0755 root root -"
    "d /mnt/fast/firefly/pgdata 0700 70 70 -"
    "d /mnt/fast/firefly/upload 0755 33 33 -"
    # === forgejo (bind sources in its compose.yaml) ===
    # 1000:1000, matching the USER_UID/USER_GID the compose sets. /data holds
    # app.ini — the SECRET_KEY, INTERNAL_TOKEN and JWT secrets Forgejo
    # self-generates on first start — plus gitea.db and every repository,
    # including the compose repo Komodo deploys from. There is no
    # secrets.sops.json for this stack's own state precisely because that
    # material lives here.
    "d /mnt/fast/forgejo 0755 1000 1000 -"
    "d /mnt/fast/forgejo/data 0755 1000 1000 -"
    # === gatus (bind sources in its compose.yaml) ===
    # Its SQLite history. The container is on the HOST network with no `ports:`
    # entry, which is why it needs a host-network-declared entry in
    # tests/lib/lints.nix.
    "d /mnt/fast/gatus 0755 root root -"
    # === ghostfolio (bind sources in its compose.yaml) ===
    # One directory, root:root: the only /mnt mount is the Postgres datadir,
    # and the image chowns it to uid 999 before initdb drops privileges. The
    # app container has no /mnt mount at all and its Redis deliberately has no
    # volume, so the whole backup story is the pg_dumpall of ghostfolio_db.
    "d /mnt/fast/ghostfolio 0755 root root -"
    "d /mnt/fast/ghostfolio/pgdata 0700 70 70 -"
    # === immich (bind sources in its compose.yaml) ===
    # root:root everywhere on purpose: the immich images have no PUID/PGID and
    # run as root, the postgres image chowns pgdata itself, and
    # immich-config-init (alpine, root) writes the 0600 immich.json. Finding
    # #14 does not apply, but the rules still must exist — docker creates a
    # missing bind source with no say over the parent /mnt/fast/immich.
    "d /mnt/fast/immich 0755 root root -"
    "d /mnt/fast/immich/config 0755 root root -"
    "d /mnt/fast/immich/model-cache 0755 root root -"
    "d /mnt/fast/immich/pgdata 0700 999 999 -"
    # The photo originals tree (UPLOAD_LOCATION). Slow tier: bulk, sequential.
    "d /mnt/slow/photos 0755 root root -"
    # === komodo (bind sources in its compose.yaml) ===
    # All root:root. Core keeps all its state in the Mongo-wire DB and has no
    # /mnt source; Periphery mounts the docker socket, /srv/komodo (its stack
    # clones) and /run/stack-env (none a /mnt source) and runs as root, so it
    # reads the root-only rendered envs; FerretDB is stateless; Postgres is
    # the only stateful component and chowns its own datadir to uid 999 from a
    # root entrypoint. The age key never enters any of them — sops-nix renders
    # the envs on the host.
    "d /mnt/fast/komodo 0755 root root -"
    # The FerretDB backend — Komodo's entire state as JSONB, captured by the
    # pg_dumpall loop rather than a mongodump path.
    "d /mnt/fast/komodo/pgdata 0700 999 999 -"
    # === logging (bind sources in its compose.yaml) ===
    # Three containers, three answers, each read out of the pinned image:
    #   victorialogs  ROOT — the image sets User "0", NOT the old loki's 10001.
    #   grafana       uid 472 — the image sets USER 472; owner-write is what
    #                 /var/lib/grafana needs, and grafana.db is created there.
    #   alloy         ROOT — the image sets no USER, and uid 0 is what lets it
    #                 read the journal (root:systemd-journal 0640 under 2755
    #                 directories). A `user:` without gid 62 would give a
    #                 healthy process that collects nothing.
    # The read-only journal mounts (/var/log/journal, /etc/machine-id) are
    # system paths, not per-stack bind sources, and must never enter this
    # table.
    # root:root deliberately: grafana/alloy sets no USER, and uid 0 is the
    # mechanism that lets it read the host journal (root:systemd-journal 0640).
    # Adding `user:` to that service silently breaks collection — the container
    # stays healthy and forwards nothing. Holds only the positions file and the
    # write-ahead log, both regenerable.
    "d /mnt/fast/alloy 0755 root root -"
    # 472:472, NOT root — the image sets USER 472. grafana.db is created here
    # on first start and is the only per-install state (the datasource is
    # provisioned read-only and the admin credential comes from the stack env);
    # backup-prepare.sh dumps it with `sqlite3 .backup` because it is WAL-mode.
    # Root-owned this fails visibly for once: /api/health reports the
    # database.
    "d /mnt/fast/grafana 0755 472 472 -"
    # root:root, matching the image: victoria-logs runs as User "0", NOT the
    # old loki's 10001 — worth re-reading on every upgrade. This one directory
    # is the whole store, trimmed by -retention.maxDiskSpaceUsageBytes in
    # stacks/logging/compose.yaml. On /mnt/slow because log data is
    # append-mostly, and deliberately off the slow-volume plan — hence its
    # NOT_BACKED_UP entry in tests/lib/lints.nix.
    "d /mnt/slow/victorialogs 0755 root root -"
    # === mealie (bind sources in its compose.yaml) ===
    # root:root is fine and any hand-fix is futile: entry.sh runs
    # `chown -R $PUID:$PGID /app` — which includes the bind-mounted /app/data —
    # on EVERY start, then gosu-drops to 911:911. This ends up 911:911 within
    # seconds of first `up` regardless of the rule.
    "d /mnt/fast/mealie 0755 root root -"
    # === media (bind sources in its compose.yaml) ===
    # Declared here rather than left to docker's create-on-mount, which is what
    # made seerr crash-loop on first deploy (finding #14), and because nothing
    # else would create /mnt/slow/data with the uid the hardlink layout needs.
    # The media suite mirrors this exact set; keep the two in sync.
    #
    # root:root is correct for the config roots: the LSIO images chown per
    # PUID/PGID from a root entrypoint, jellyfin/gluetun/profilarr run as root,
    # seerr-init chowns seerr's config, and clamav 1.5's /init chowns
    # /var/lib/clamav unconditionally before starting clamd. /mnt/slow/data is
    # 1000:1000 — every media container works there as uid 1000.
    #
    # This stack also binds /mnt/slow/books/drop, which BELONGS TO THE BOOKS
    # STACK: clamav-scanner moves a clean audiobook download in and
    # audiobookshelf reads it :ro. Nothing else crosses.
    "d /mnt/fast/bazarr 0755 root root -"
    "d /mnt/fast/bazarr/config 0755 root root -"
    "d /mnt/fast/clamav 0755 root root -"
    "d /mnt/fast/clamav/db 0755 root root -"
    "d /mnt/fast/clamav/scanner 0755 root root -"
    "d /mnt/fast/cleanuparr 0755 root root -"
    "d /mnt/fast/cleanuparr/config 0755 root root -"
    "d /mnt/fast/gluetun 0755 root root -"
    "d /mnt/fast/jellyfin 0755 root root -"
    "d /mnt/fast/jellyfin/cache 0755 root root -"
    "d /mnt/fast/jellyfin/config 0755 root root -"
    "d /mnt/fast/profilarr 0755 root root -"
    "d /mnt/fast/profilarr/config 0755 root root -"
    "d /mnt/fast/prowlarr 0755 root root -"
    "d /mnt/fast/prowlarr/config 0755 root root -"
    "d /mnt/fast/qbittorrent 0755 root root -"
    "d /mnt/fast/qbittorrent/config 0755 root root -"
    "d /mnt/fast/radarr 0755 root root -"
    "d /mnt/fast/radarr/config 0755 root root -"
    "d /mnt/fast/seerr 0755 root root -"
    "d /mnt/fast/seerr/config 0755 root root -"
    "d /mnt/fast/sonarr 0755 root root -"
    "d /mnt/fast/sonarr/config 0755 root root -"
    "d /mnt/slow/data 0755 1000 1000 -"
    # Also bind sources in their own right (qbittorrent/scanner mount them
    # directly), so without rules docker creates them root-owned during `up`.
    # media-init heals them later only because it happens to run as root.
    "d /mnt/slow/data/downloads 0755 1000 1000 -"
    "d /mnt/slow/data/media 0755 1000 1000 -"
    # === notes-sync (bind sources in its compose.yaml) ===
    # All 1000:1000, for two different reasons:
    #   - rmfakecloud is FROM scratch with no entrypoint and no PUID/PGID, so
    #     it cannot fix anything itself. Its compose pins `user: "1000:1000"`
    #     (Windmill later reads this tree as uid 1000), so the ownership MUST
    #     come from here.
    #   - syncthing's entrypoint chown is non-recursive: it fixes
    #     /var/syncthing and nothing beneath it, so config/ and every synced
    #     tree must be pre-owned. Getting it wrong yields a HEALTHY container
    #     with an errored folder.
    "d /mnt/fast/rmfakecloud 0755 1000 1000 -"
    "d /mnt/fast/rmfakecloud/data 0755 1000 1000 -"
    "d /mnt/fast/syncthing 0755 1000 1000 -"
    "d /mnt/fast/syncthing/config 0755 1000 1000 -"
    "d /mnt/fast/vault 0755 1000 1000 -"
    # === ntfy (bind sources in its compose.yaml) ===
    # root:root — the image declares no USER and the compose sets none. lib/
    # holds the auth database and the attachment store; cache/ holds the
    # transient recent-message buffer. This is the path every failure in the
    # fleet is reported through, so a silent failure to start takes the alert
    # path with it.
    "d /mnt/fast/ntfy 0755 root root -"
    "d /mnt/fast/ntfy/cache 0755 root root -"
    "d /mnt/fast/ntfy/lib 0755 root root -"
    # === outline (bind sources in its compose.yaml) ===
    # 1001:1001 for the app's data directory: the image ends on `USER nodejs`
    # (uid 1001) and its entrypoint chowns nothing. Its Postgres chowns its own
    # datadir, and redis deliberately has no volume at all.
    "d /mnt/fast/outline 0755 root root -"
    # 1001:1001 — the `nodejs` user the image runs as, NOT 1000, and nothing in
    # the container repairs it. FILE_STORAGE=local makes this the object store
    # for every attachment, so a root-owned copy is a wiki that works until the
    # first upload.
    "d /mnt/fast/outline/data 0755 1001 1001 -"
    "d /mnt/fast/outline/pgdata 0700 70 70 -"
    # === paperless (bind sources in its compose.yaml) ===
    # root:root for all five: the entrypoint runs as root, maps its
    # `paperless` user onto USERMAP_UID/USERMAP_GID (1000 here) and chowns
    # data/media/consume/export before dropping privileges, and the postgres
    # image chowns pgdata itself.
    "d /mnt/fast/paperless 0755 root root -"
    "d /mnt/fast/paperless/consume 0755 root root -"
    "d /mnt/fast/paperless/data 0755 root root -"
    "d /mnt/fast/paperless/export 0755 root root -"
    "d /mnt/fast/paperless/media 0755 root root -"
    "d /mnt/fast/paperless/pgdata 0700 70 70 -"
    # === proton (bind sources in its compose.yaml) ===
    # hydroxide runs as USER hydroxide (uid 1000) with no chown-on-start, so
    # its directory must be pre-owned or the one-time `auth` can never write
    # auth.json — serve stays green and every login fails.
    # The isync image (proton-export) sets no USER and runs as root, so the
    # maildir archive stays root:root. No database anywhere; backup is the
    # slow-volume-selective plan, not a dump.
    "d /mnt/fast/proton 0755 root root -"
    # auth.json — the Proton refresh token and passwords, encrypted with a key
    # derived from the bridge password in secrets.sops.json; neither half is useful
    # alone. Written by the one-time `hydroxide auth` as uid 1000; nothing
    # in-container repairs a wrong owner.
    "d /mnt/fast/proton/hydroxide 0755 1000 1000 -"
    # The mail export — a full-mailbox maildir, append-only by construction
    # (mbsyncrc: Sync Pull + Expunge None). Slow tier, and unlike the log store
    # it IS backed up: slow-volume-selective names it.
    "d /mnt/slow/proton-mail-archive 0755 root root -"
    # === silverbullet (bind sources in its compose.yaml) ===
    # 1000:1000, and here the ownership DECIDES THE UID THE SERVER RUNS AS: the
    # entrypoint reads the owner of $SB_FOLDER and re-execs at that uid unless
    # PUID is set. Leave the space root-owned and the wiki runs as root,
    # writing pages the git-sync sidecar (uid 1000) cannot commit — nothing
    # crashes, the mirror just stops. 1000 is also the fleet's content uid
    # (finding #10).
    "d /mnt/fast/silverbullet 0755 1000 1000 -"
    # This ownership IS the uid SilverBullet runs as — its entrypoint infers
    # PUID from the owner of the space — so changing this line changes the
    # process, not just the file modes. It is also the git working tree the
    # sync sidecar (uid 1000) commits from.
    "d /mnt/fast/silverbullet/space 0755 1000 1000 -"
    # === tandoor (bind sources in its compose.yaml) ===
    # Runs as ROOT: no USER instruction, nginx and gunicorn both root, and
    # boot.sh chmods the media root on every start.
    "d /mnt/fast/tandoor 0755 root root -"
    "d /mnt/fast/tandoor/mediafiles 0755 root root -"
    "d /mnt/fast/tandoor/pgdata 0700 70 70 -"
    # === tracking (bind sources in its compose.yaml) ===
    # Three ownership conventions in one stack; normalising any breaks it:
    #   - bookstack is LSIO: it drops to PUID/PGID and runs
    #     `lsiown -R abc:abc /config`, so 1000:1000 matches what it enforces.
    #   - its MariaDB chowns its own datadir before dropping to mysql.
    #   - homebox runs as ROOT with no PUID/PGID and no chown-on-start.
    #   - karakeep MUST be root-owned: a non-root uid dies with EACCES on
    #     /app/apps/web/.next/cache, which is INSIDE the image, so chowning the
    #     host mount cannot fix it (upstream #1324, closed unfixed).
    "d /mnt/fast/bookstack 0755 root root -"
    "d /mnt/fast/bookstack/config 0755 1000 1000 -"
    "d /mnt/fast/bookstack/db 0700 999 999 -"
    "d /mnt/fast/homebox 0755 root root -"
    "d /mnt/fast/karakeep 0755 root root -"
    "d /mnt/fast/karakeep/data 0755 root root -"
    "d /mnt/fast/karakeep/meili 0755 root root -"
    # === vaultwarden (bind sources in its compose.yaml) ===
    # Runs as ROOT: the debian image declares no USER and start.sh execs the
    # binary directly. The path is load-bearing beyond ownership —
    # backup-prepare.sh hardcodes /mnt/fast/vaultwarden/db.sqlite3 and
    # sqlite_backup returns 0 for a MISSING source, so moving this mount turns
    # the vault's only dump into a permanent silent no-op.
    "d /mnt/fast/vaultwarden 0755 root root -"
    # === wealthfolio (bind sources in its compose.yaml) ===
    # 1000:1000, and the image will NOT heal a wrong owner: the Dockerfile ends
    # on USER 1000:1000 with no root entrypoint and no chown, so the first
    # write to a root-owned /data exits the container. One directory carries
    # wealthfolio.db (SQLite, WAL) and secrets.json.
    "d /mnt/fast/wealthfolio 0755 1000 1000 -"
    # === wger (bind sources in its compose.yaml) ===
    # 1000:1000. The base image does `deluser ubuntu` then
    # `adduser wger --uid 1000` and the production image ends on `USER wger` —
    # no PUID/PGID, no id-remap entrypoint, no chown-on-start — so a root-owned
    # bind source fails collectstatic on the very first boot (finding #14).
    "d /mnt/fast/wger 0755 root root -"
    "d /mnt/fast/wger/media 0755 1000 1000 -"
    "d /mnt/fast/wger/pgdata 0700 70 70 -"
    # === windmill (bind sources in its compose.yaml) ===
    # Only the pgdata root. The dependency cache is deliberately a named docker
    # volume and must never get a rule here: the image bakes CPython 3.11 and
    # 3.12 into /tmp/windmill/cache at build time, a named volume is seeded
    # from the image and a bind mount is not, and
    # UV_PYTHON_PREFERENCE=only-managed forbids a system fallback.
    "d /mnt/fast/windmill 0755 root root -"
    "d /mnt/fast/windmill/pgdata 0700 70 70 -"
  ];
}
