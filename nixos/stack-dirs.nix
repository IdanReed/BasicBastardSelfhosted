# GENERATED FILE — DO NOT EDIT BY HAND.
#
#   Regenerate:  nixos/generate-stack-dirs.sh
#   Source:      stacks/*/compose.yaml + arcane/compose.yaml
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
{
  systemd.tmpfiles.rules = [
    # === automation (bind sources in its compose.yaml) ===
    # Ownership, VERIFIED per image (annex §2.3):
    #   - home assistant runs as ROOT and has no PUID/PGID mechanism at all.
    #     Its /config must also be WRITABLE: .HA_VERSION is rewritten on every
    #     version change and that write is not wrapped in a try/except, so a
    #     read-only config dir kills startup.
    #   - mosquitto starts as root and DROPS to uid 1883, and its 2.x
    #     entrypoint chowns only some of its tree (2.1 narrowed it to
    #     /mosquitto/data alone) — so both directories are declared 1883
    #     rather than relying on the image to heal them. This is the seerr
    #     crash-loop class (finding #14) and the one place in this stack it
    #     could still bite.
    #   - frigate runs as root.
    "d /mnt/fast/frigate 0755 root root -"
    "d /mnt/fast/frigate/config 0755 root root -"
    "d /mnt/fast/homeassistant 0755 root root -"
    "d /mnt/fast/mosquitto 0755 root root -"
    "d /mnt/fast/mosquitto/config 0755 1883 1883 -"
    "d /mnt/fast/mosquitto/data 0755 1883 1883 -"
    # Recordings, clips and exports. Deliberately NOT in backrest's
    # slow-volume include list — it is an explicit allowlist and this path is
    # not on it, which is how many GB of re-recordable video stays out of the
    # backups. Do not add it.
    "d /mnt/slow/frigate 0755 root root -"
    # === backrest (bind sources in its compose.yaml) ===
    # All root:root. The backrest image declares no USER and its compose sets
    # none — it must run as root to read every service's data through the
    # /mnt/{fast,slow}:ro mounts — and config-init is plain alpine, also root.
    # config/ must stay WRITABLE (:ro breaks it): Backrest rewrites config.json
    # whenever anything changes in the UI.
    #
    # These had NO rule at all until the generator landed: stacks/backrest was
    # never in the tmpfiles-ownership lint's hand-maintained COMPOSE_FILES list.
    # tests/suites/backrest.nix has run green against exactly this ownership
    # since it was written (backrest.nix, systemd.tmpfiles.rules).
    "d /mnt/fast/backrest 0755 root root -"
    "d /mnt/fast/backrest/cache 0755 root root -"
    "d /mnt/fast/backrest/config 0755 root root -"
    "d /mnt/fast/backrest/data 0755 root root -"
    # === beszel (bind sources in its compose.yaml) ===
    # The hub's directory holds data.db, the generated config.yml, and
    # id_ed25519 at 0600 — beszel-init writes the key mode itself, so this rule
    # only needs to own the parent.
    "d /mnt/fast/beszel 0755 root root -"
    # The agent's fingerprint file. It lives on the DATA disk on purpose:
    # ./rebuild_os_proxmox.sh --build re-images the OS disk, and the fingerprint
    # is sha256 of the machine-id — a hub that has pinned the old one rejects
    # the agent outright after a routine re-image, visible only in hub logs.
    "d /mnt/fast/beszel-agent 0755 root root -"
    # Two EMPTY marker directories, one per storage tier, bound read-only into
    # the agent at /extra-filesystems/*. Beszel reports filesystem usage via
    # statfs, which answers for the whole containing filesystem regardless of
    # which path on it is asked — verified against v0.18.8, where an empty
    # directory yielded `d: 3665.96, du: 114.19` for its device. So these give
    # the same numbers a wholesale /mnt/fast:ro bind would, without handing a
    # monitoring container a readable copy of every service's data.
    "d /mnt/fast/beszel-agent/fsprobe 0755 root root -"
    "d /mnt/slow/beszel-fsprobe 0755 root root -"
    # === books (bind sources in its compose.yaml) ===
    # Ownership, VERIFIED per image (annex §2.2):
    #   - kavita runs as ROOT: its entrypoint's PUID/PGID block is commented
    #     out upstream ("causing issues for Synology users") and the image sets
    #     no USER. It also hard-exits if it cannot write /kavita/config, and
    #     that directory must stay WRITABLE — Kavita rewrites appsettings.json
    #     and swallows the failure, so a read-only config dir silently leaves
    #     the published placeholder JWT key in play (annex §0.5).
    #   - audiobookshelf runs as ROOT too ("User": null in the image config;
    #     it has no PUID/PGID mechanism at all) — the immich call, for the same
    #     reasons: tailnet-only, loopback-bound, socketless.
    #   - shelfmark starts as root, then drops to PUID/PGID (1000 here). Its
    #     entrypoint recursively chowns /config and repairs /tmp/shelfmark, so
    #     these would self-heal — declaring them 1000:1000 anyway just means it
    #     has nothing to do.
    #   - The two /mnt/slow trees are 1000:1000: shelfmark (uid 1000) writes
    #     the ebook tree, and the audiobook tree keeps the same ownership for
    #     whatever ends up filling it (shelfmark's Direct Download source is
    #     ebook-only, so audiobooks arrive by other means for now). Kavita and
    #     audiobookshelf mount their tree :ro as root and only read.
    "d /mnt/fast/audiobookshelf 0755 root root -"
    "d /mnt/fast/audiobookshelf/config 0755 root root -"
    "d /mnt/fast/audiobookshelf/metadata 0755 root root -"
    "d /mnt/fast/kavita 0755 root root -"
    "d /mnt/fast/kavita/config 0755 root root -"
    "d /mnt/fast/shelfmark 0755 root root -"
    "d /mnt/fast/shelfmark/config 0755 1000 1000 -"
    "d /mnt/fast/shelfmark/tmp 0755 1000 1000 -"
    # Both library trees live under /mnt/slow/books deliberately: backrest's
    # slow-volume-selective plan already includes that path, so they are backed
    # up without touching its config.
    "d /mnt/slow/books 0755 1000 1000 -"
    "d /mnt/slow/books/audiobooks 0755 1000 1000 -"
    "d /mnt/slow/books/library 0755 1000 1000 -"
    # === caddy (bind sources in its compose.yaml) ===
    # root:root. The official caddy image runs as root (it binds 80/443 and here
    # network_mode: host), so the ACME account key and the issued certificates
    # under data/ are written as root. Nothing else on the host reads them.
    #
    # This stack was never in the tmpfiles-ownership lint's COMPOSE_FILES list
    # either, so both directories were left to docker to create. That happened to
    # be harmless — docker's default IS root:root — but it was luck, not a
    # decision: tests/suites/services-vm.nix and tailnet.nix pre-create
    # /mnt/fast/caddy root-owned and have run green throughout.
    "d /mnt/fast/caddy 0755 root root -"
    "d /mnt/fast/caddy/config 0755 root root -"
    "d /mnt/fast/caddy/data 0755 root root -"
    # === dawarich (bind sources in its compose.yaml) ===
    # Both of its entrypoints gosu-drop to PUID/PGID *only if* they start as uid
    # 0, chowning first — which is why its compose sets no `user:` and these are
    # 1000:1000 to match what the entrypoint will enforce. Setting `user:` there
    # instead would skip the chown branch entirely and crash-loop on a root-owned
    # mount; upstream warns about it inline, twice.
    "d /mnt/fast/dawarich 0755 root root -"
    "d /mnt/fast/dawarich/pgdata 0755 root root -"
    "d /mnt/fast/dawarich/public 0755 1000 1000 -"
    # The redis image runs as uid 999 and does NOT chown its data directory.
    # This holds the sidekiq queue: losing it drops in-flight import and
    # statistics jobs, which is survivable, but a wrong owner makes redis
    # exit at start and takes sidekiq with it.
    "d /mnt/fast/dawarich/redis 0755 999 999 -"
    "d /mnt/fast/dawarich/storage 0755 1000 1000 -"
    "d /mnt/fast/dawarich/watched 0755 1000 1000 -"
    # === docspace (bind sources in its compose.yaml) ===
    # THREE containers, THREE DIFFERENT NON-ROOT UIDs, and getting any of them
    # wrong produces `dependency failed to start` naming a container that is fine:
    #   docspace       uid 104 gid 107 (USER onlyoffice, starts pre-dropped)
    #   docspace_db    uid 999 gid 999 (mysql drops before --initialize)
    #   docspace_ds    root            (documentserver chowns from its entry)
    # Three different conventions in three containers; do not normalise them.
    #   - Document Server runs as ROOT and chowns its own mounts to ds:ds on
    #     every start, so root-owned is correct and self-healing. Never set
    #     `user:` on it — that skips the chown branch.
    #   - The monolith runs `user: root` following upstream, because its
    #     entrypoint edits /etc/nginx and its config files before dropping into
    #     supervisord. The ExcaliDash lesson applies: an image that stays root
    #     deliberately in order to fix permissions crash-loops when you take
    #     that away.
    #   - MySQL chowns its own datadir at first init.
    #
    # ⚠ Note the DS and monolith trees are SEPARATE here. Upstream's community
    # compose mounts the same volume into both (/app/onlyoffice/data and
    # /var/www/onlyoffice/Data) — two different applications' state sharing one
    # namespace. Separating them is what makes the Backrest exclude list for
    # the document cache expressible at all.
    "d /mnt/fast/docspace 0755 root root -"
    # 104:107 = the image's `USER onlyoffice`. NOT load-bearing: the compose
    # file sets `user: root` following upstream, because the entrypoint edits
    # /etc/nginx and /app/onlyoffice/config before dropping into supervisord.
    # These are declared anyway so that dropping `user: root` later degrades
    # rather than breaking, and so the ownership matches what the app expects
    # if it ever drops privileges internally. (An earlier version of this
    # comment claimed root ownership was what broke the first suite run. It
    # was not — that was mysqldata below. Corrected rather than left to be
    # believed.)
    "d /mnt/fast/docspace/app 0755 104 107 -"
    "d /mnt/fast/docspace/ds-data 0755 root root -"
    "d /mnt/fast/docspace/ds-lib 0755 root root -"
    "d /mnt/fast/docspace/ds-logs 0755 root root -"
    "d /mnt/fast/docspace/logs 0755 104 107 -"
    # 🚨 999:999, NOT root. The official mysql image drops to uid 999
    # (`mysql`) and `--initialize` refuses a data directory it cannot write:
    # "the designated data directory /var/lib/mysql/ is unusable". The
    # container then restart-loops while every other container in the project
    # comes up fine, so the visible symptom is `dependency failed to start`
    # on a service that has nothing wrong with it. This is finding #14
    # (seerr) in a second image — root-owned bind mounts are the default
    # docker would have chosen, which is exactly why these rules exist.
    "d /mnt/fast/docspace/mysqldata 0755 999 999 -"
    # === firefly (bind sources in its compose.yaml) ===
    # A convention of its own: the image ends on `USER www-data` at BUILD time and
    # never invokes an id-remap entrypoint, so PUID/PGID are inert and the upload
    # directory must be pre-owned 33:33 or attachment upload fails at runtime with
    # a permission error and no startup symptom at all. Its Postgres starts as
    # root and chowns its own datadir, as everywhere else here.
    "d /mnt/fast/firefly 0755 root root -"
    "d /mnt/fast/firefly/pgdata 0755 root root -"
    "d /mnt/fast/firefly/upload 0755 33 33 -"
    # === forgejo (bind sources in its compose.yaml) ===
    # 1000:1000, matching the USER_UID/USER_GID the compose file sets: the classic
    # (root-entrypoint) image runs its `git` user at that uid, so everything under
    # /data is written as 1000 and the fast-volume backup reads it without
    # surprises. tests/suites/forgejo.nix pre-creates the volume root at exactly
    # this ownership and pushes/clones against it.
    #
    # /data holds app.ini — which carries the SECRET_KEY, INTERNAL_TOKEN and JWT
    # secrets Forgejo self-generates on first start — plus gitea.db and every
    # repository. There is no .sops.env for this stack precisely because that
    # material lives here instead, which makes this directory the whole of
    # Forgejo's identity and state.
    #
    # Never had a rule before the generator: stacks/forgejo was missing from the
    # tmpfiles-ownership lint's COMPOSE_FILES list, so this — the git ROOT for the
    # homelab, including the remote Arcane's GitOps sync pulls from — was left to
    # docker to create root-owned.
    "d /mnt/fast/forgejo 0755 1000 1000 -"
    "d /mnt/fast/forgejo/data 0755 1000 1000 -"
    # === gatus (bind sources in its compose.yaml) ===
    # Its SQLite history lives here; the container is on the HOST network and has
    # no ports: entry, which is why it needs a host-network-declared entry in
    # tests/lib/lints.nix.
    "d /mnt/fast/gatus 0755 root root -"
    # === immich (bind sources in its compose.yaml) ===
    # root:root everywhere ON PURPOSE: the immich images have no PUID/PGID
    # mechanism and run as root by default (the FAQ's non-root mode is deliberately
    # not used — annex §2/§7.5: tailnet-only, loopback-bound, socketless), so the
    # server/ML write /data and /cache as root; the postgres image chowns pgdata
    # itself from its root entrypoint; and immich-config-init (alpine, root) writes
    # the 0600 immich.json into the config dir. The seerr uid-1000 crash-loop class
    # (finding #14) therefore does not apply, but the 'd' rules still must exist:
    # docker creates missing bind sources at container start with no say over the
    # parent /mnt/fast/immich.
    "d /mnt/fast/immich 0755 root root -"
    "d /mnt/fast/immich/config 0755 root root -"
    "d /mnt/fast/immich/model-cache 0755 root root -"
    "d /mnt/fast/immich/pgdata 0755 root root -"
    # The photo originals tree (UPLOAD_LOCATION). Slow tier per the overview's
    # volume column: bulk, sequential.
    "d /mnt/slow/photos 0755 root root -"
    # === media (bind sources in its compose.yaml) ===
    # Declared here rather than left to docker's create-on-mount because docker
    # always creates missing bind sources root-owned at container start — exactly
    # the class of bug that made seerr crash-loop on first deploy (EACCES mkdir;
    # its image runs as uid 1000 and cannot chown, now worked around by the
    # seerr-init oneshot) — and because nothing else would create /mnt/slow/data
    # with the uid the hardlink layout needs. The media suite mirrors this exact
    # set in its tmpfiles block; keep the two in sync.
    #
    # Ownership: root:root is correct for the config roots — the LSIO images
    # (radarr/sonarr/prowlarr/bazarr/qbittorrent) chown per PUID/PGID from a
    # root entrypoint, jellyfin and gluetun run as root, cleanuparr's
    # entrypoint honors PUID/PGID, profilarr runs as root, seerr-init chowns
    # /mnt/fast/seerr/config, and clamav 1.5's /init (VERIFIED by reading
    # the pinned image's entrypoint script) runs as root and does
    # `chown -R clamav:clamav /var/lib/clamav` unconditionally before
    # starting clamd. /mnt/slow/data is 1000:1000: every media container
    # works there as uid 1000 and media-init creates the skeleton with that
    # owner.
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
    # directly), so without rules docker would create them root-owned during
    # `up` — media-init heals ownership later, but only because it happens to
    # run as root; don't depend on that.
    "d /mnt/slow/data/downloads 0755 1000 1000 -"
    "d /mnt/slow/data/media 0755 1000 1000 -"
    # === notes-sync (bind sources in its compose.yaml) ===
    # ALL 1000:1000, and for two different reasons:
    #   - rmfakecloud is FROM scratch with no entrypoint and no PUID/PGID, so
    #     it cannot fix anything itself. Its compose sets `user: "1000:1000"`
    #     deliberately (Windmill later mounts this tree read-only as uid 1000
    #     to scan .rm files, and a root-owned tree would make that scan
    #     silently see nothing), which means the ownership MUST come from here.
    #   - syncthing's entrypoint chown is `chown PUID:PGID $HOME || true` —
    #     NON-RECURSIVE, with an upstream comment saying "maybe it'll work
    #     anyway, so we let the error slide". It fixes /var/syncthing and
    #     nothing beneath it, so config/ and every synced tree must be
    #     pre-owned. Getting this wrong yields a HEALTHY container with an
    #     errored folder: finding #14 with the crash-loop replaced by silence.
    "d /mnt/fast/rmfakecloud 0755 1000 1000 -"
    "d /mnt/fast/rmfakecloud/data 0755 1000 1000 -"
    "d /mnt/fast/syncthing 0755 1000 1000 -"
    "d /mnt/fast/syncthing/config 0755 1000 1000 -"
    "d /mnt/fast/vault 0755 1000 1000 -"
    # === ntfy (bind sources in its compose.yaml) ===
    # root:root. The ntfy image declares no USER and the compose sets none, so
    # `ntfy serve` runs as root and owns both trees. lib/ holds the auth database
    # (user.db) and the attachment store; cache/ holds cache.db, the recent-message
    # buffer, which is deliberately transient — see the backup-coverage allowlist.
    #
    # Another stack that was missing from the tmpfiles-ownership lint's
    # COMPOSE_FILES list. It is the single place every failure in the fleet gets
    # reported, so it silently failing to start would take the alert path with it;
    # tests/suites/backrest.nix and services-vm.nix both pre-create these
    # root-owned and have run green throughout.
    "d /mnt/fast/ntfy 0755 root root -"
    "d /mnt/fast/ntfy/cache 0755 root root -"
    "d /mnt/fast/ntfy/lib 0755 root root -"
    # === paperless (bind sources in its compose.yaml) ===
    # root:root for all five, and that is VERIFIED rather than assumed: the
    # paperless entrypoint runs as root, maps its `paperless` user onto
    # USERMAP_UID/USERMAP_GID (1000 here) and chowns data/media/consume/export
    # before dropping privileges, and the postgres image chowns pgdata itself from
    # its root entrypoint. tests/suites/paperless.nix creates exactly these six
    # directories root-owned and runs the whole document pipeline against them.
    #
    # Missing from the tmpfiles-ownership lint's COMPOSE_FILES list until the
    # generator landed — five bind sources with no rule.
    "d /mnt/fast/paperless 0755 root root -"
    "d /mnt/fast/paperless/consume 0755 root root -"
    "d /mnt/fast/paperless/data 0755 root root -"
    "d /mnt/fast/paperless/export 0755 root root -"
    "d /mnt/fast/paperless/media 0755 root root -"
    "d /mnt/fast/paperless/pgdata 0755 root root -"
    # === samba (bind sources in its compose.yaml) ===
    # smbd runs as ROOT and must — it needs to setuid per connection — so /data is
    # root-owned.
    "d /mnt/fast/samba 0755 root root -"
    "d /mnt/slow/samba 0755 root root -"
    # 🚨 The share tree is 1000:1000, and that is a CONTRACT with
    # stacks/samba/config.yml's `auth:` entry, which creates the SMB user with
    # uid 1000 gid 1000 INSIDE the container via `adduser -u`. Nothing
    # connects the two but these two files agreeing. A mismatch is not a crash
    # — it is files nothing else in the fleet can read, found much later.
    # samba-init refuses to start on a mismatch and the suite measures it
    # (write over SMB, stat on the host).
    #
    # 0775 rather than 0755: the group bit is what lets a future second SMB
    # user share the tree without each file being private to whoever wrote it.
    "d /mnt/slow/samba/shared 0775 1000 1000 -"
    # === tandoor (bind sources in its compose.yaml) ===
    # Food domain — TWO stacks (stacks/tandoor, stacks/wger), one per app, because
    # both are Django and both read the BARE name SECRET_KEY out of their
    # environment.
    #
    # Tandoor runs as ROOT (its Dockerfile has no USER instruction; nginx and
    # gunicorn both run as root, and boot.sh chmods the media root on every
    # start), so root:root is what it will write as.
    "d /mnt/fast/tandoor 0755 root root -"
    "d /mnt/fast/tandoor/mediafiles 0755 root root -"
    "d /mnt/fast/tandoor/pgdata 0755 root root -"
    # === tracking (bind sources in its compose.yaml) ===
    # This stack alone carries THREE different ownership conventions, and
    # normalising any of them breaks it (annex §8):
    #   - bookstack is an LSIO image: it drops to PUID/PGID and runs
    #     `lsiown -R abc:abc /config` at every start, so 1000:1000 matches
    #     what it will enforce anyway.
    #   - its MariaDB starts as root and chowns its own datadir before
    #     dropping to mysql, so root:root is correct there.
    #   - homebox (default variant) runs as ROOT with no PUID/PGID and no
    #     chown-on-start.
    #   - karakeep MUST be root-owned: a non-root uid dies with EACCES on
    #     /app/apps/web/.next/cache, which is INSIDE the image, so chowning
    #     the host mount cannot fix it (upstream #1324, closed unfixed). This
    #     is the inverse of the /srv/stacks convention — do not "fix" it.
    "d /mnt/fast/bookstack 0755 root root -"
    "d /mnt/fast/bookstack/config 0755 1000 1000 -"
    "d /mnt/fast/bookstack/db 0755 root root -"
    "d /mnt/fast/homebox 0755 root root -"
    "d /mnt/fast/karakeep 0755 root root -"
    "d /mnt/fast/karakeep/data 0755 root root -"
    "d /mnt/fast/karakeep/meili 0755 root root -"
    # === vaultwarden (bind sources in its compose.yaml) ===
    # Runs as ROOT: the debian image declares no USER and start.sh execs the binary
    # directly, so root:root is what it will write as. That also matches
    # backup-prepare.sh, which reads db.sqlite3 from here as root.
    #
    # The path is load-bearing beyond ownership: backup-prepare.sh hardcodes
    # /mnt/fast/vaultwarden/db.sqlite3, and sqlite_backup returns 0 for a MISSING
    # source — so moving this mount would turn the vault's only dump into a
    # permanent silent no-op rather than an error.
    "d /mnt/fast/vaultwarden 0755 root root -"
    # === wger (bind sources in its compose.yaml) ===
    # 🚨 Wger's media directory must be 1000:1000. Its base image does
    # `deluser ubuntu` then `adduser wger --uid 1000` and the production image
    # ends on `USER wger` — there is NO PUID/PGID, no id-remap entrypoint and
    # no chown-on-start, so a root-owned bind source makes collectstatic fail
    # on the very first boot. Finding #14's crash-loop pattern.
    "d /mnt/fast/wger 0755 root root -"
    "d /mnt/fast/wger/media 0755 1000 1000 -"
    "d /mnt/fast/wger/pgdata 0755 root root -"
    # === windmill (bind sources in its compose.yaml) ===
    # Only the pgdata root — the DEPENDENCY CACHE is deliberately a named docker
    # volume and must never get a rule here: the image bakes CPython 3.11 and 3.12
    # into /tmp/windmill/cache at build time, a named volume is seeded from the
    # image on first use, and a bind mount is never seeded. Pointing it at
    # /mnt/fast would delete both interpreters, and UV_PYTHON_PREFERENCE=
    # only-managed forbids a system fallback, so the first Python job would try to
    # download one and hang offline.
    "d /mnt/fast/windmill 0755 root root -"
    "d /mnt/fast/windmill/pgdata 0755 root root -"
  ];
}
