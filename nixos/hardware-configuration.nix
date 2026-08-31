{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  # Boot configuration
  boot.initrd.availableKernelModules = [ "ata_piix" "uhci_hcd" "virtio_pci" "virtio_scsi" "sd_mod" "sr_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # Bootloader
  boot.loader.grub = {
    enable = true;
    device = "/dev/sda";
  };

  # Root filesystem (OS disk - will be the Proxmox image disk)
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  # Persistent state storage
  fileSystems."/srv" = {
    device = "/dev/disk/by-partlabel/state";
    fsType = "ext4";
    options = [ "defaults" ];
  };

  # Fast storage (SSD) - Docker images/volumes
  fileSystems."/mnt/fast" = {
    device = "/dev/disk/by-partlabel/fast";
    fsType = "ext4";
    options = [ "defaults" ];
  };

  # Slow storage (HDD) - Media/bulk data
  fileSystems."/mnt/slow" = {
    device = "/dev/disk/by-partlabel/slow";
    fsType = "ext4";
    options = [ "defaults" ];
  };

  # Bind mount Docker data directory to fast storage
  fileSystems."/var/lib/docker" = {
    device = "/mnt/fast/docker";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/mnt/fast" ];
  };

  # Ensure required directories exist
  systemd.tmpfiles.rules = [
    "d /srv/arcane 0755 root root -"
    # 1000:1000 = the PUID/PGID Arcane runs as. Root-owned, its git sync can
    # never create a project directory here and its deploys cannot read the
    # 0600 .env files — GitOps delivery silently dead (caught by
    # tests/suites/gitops.nix).
    "d /srv/stacks 0755 1000 1000 -"
    # Live-host migration: tmpfiles 'd' only applies its owner when it CREATES
    # the directory — on the real VM /srv/stacks already existed (root-owned,
    # populated) before the 1000:1000 rule above landed, so 'd' never fixes
    # it. 'Z' recursively re-owns everything on each boot; the mode field is
    # left '-' on purpose so per-file modes (0600 .env vs 0644 compose) stay
    # untouched.
    "Z /srv/stacks - 1000 1000 -"
    "d /mnt/fast/docker 0711 root root -"
    "d /var/lib/sops-nix 0700 root root -"
    # Media stack bind-mount roots (stacks/media/compose.yaml). Declared here
    # rather than left to docker's create-on-mount because docker always
    # creates missing bind sources root-owned at container start — exactly
    # the class of bug that made seerr crash-loop on first deploy (EACCES
    # mkdir; its image runs as uid 1000 and cannot chown, now worked around
    # by the seerr-init oneshot) — and because nothing else would create
    # /mnt/slow/data with the uid the hardlink layout needs. The media suite
    # mirrors this exact set in its tmpfiles block; keep the two in sync.
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
    "d /mnt/fast/gluetun 0755 root root -"
    "d /mnt/fast/qbittorrent 0755 root root -"
    "d /mnt/fast/qbittorrent/config 0755 root root -"
    "d /mnt/fast/jellyfin 0755 root root -"
    "d /mnt/fast/jellyfin/config 0755 root root -"
    "d /mnt/fast/jellyfin/cache 0755 root root -"
    "d /mnt/fast/radarr 0755 root root -"
    "d /mnt/fast/radarr/config 0755 root root -"
    "d /mnt/fast/sonarr 0755 root root -"
    "d /mnt/fast/sonarr/config 0755 root root -"
    "d /mnt/fast/prowlarr 0755 root root -"
    "d /mnt/fast/prowlarr/config 0755 root root -"
    "d /mnt/fast/seerr 0755 root root -"
    "d /mnt/fast/seerr/config 0755 root root -"
    "d /mnt/fast/bazarr 0755 root root -"
    "d /mnt/fast/bazarr/config 0755 root root -"
    "d /mnt/fast/profilarr 0755 root root -"
    "d /mnt/fast/profilarr/config 0755 root root -"
    "d /mnt/fast/cleanuparr 0755 root root -"
    "d /mnt/fast/cleanuparr/config 0755 root root -"
    "d /mnt/fast/clamav 0755 root root -"
    "d /mnt/fast/clamav/db 0755 root root -"
    "d /mnt/fast/clamav/scanner 0755 root root -"
    "d /mnt/slow/data 0755 1000 1000 -"
    # Also bind sources in their own right (qbittorrent/scanner mount them
    # directly), so without rules docker would create them root-owned during
    # `up` — media-init heals ownership later, but only because it happens to
    # run as root; don't depend on that.
    "d /mnt/slow/data/downloads 0755 1000 1000 -"
    "d /mnt/slow/data/media 0755 1000 1000 -"
    # Immich stack bind-mount roots (stacks/immich/compose.yaml). root:root
    # everywhere ON PURPOSE: the immich images have no PUID/PGID mechanism and
    # run as root by default (the FAQ's non-root mode is deliberately not used
    # — annex §2/§7.5: tailnet-only, loopback-bound, socketless), so the
    # server/ML write /data and /cache as root; the postgres image chowns
    # pgdata itself from its root entrypoint; and immich-config-init (alpine,
    # root) writes the 0600 immich.json into the config dir. The seerr
    # uid-1000 crash-loop class (finding #14) therefore does not apply, but
    # the 'd' rules still must exist: docker creates missing bind sources at
    # container start with no say over the parent /mnt/fast/immich. The
    # tmpfiles-ownership lint's bind-source parity leg parses this compose
    # file too — keep the set in sync.
    "d /mnt/fast/immich 0755 root root -"
    "d /mnt/fast/immich/pgdata 0755 root root -"
    "d /mnt/fast/immich/model-cache 0755 root root -"
    "d /mnt/fast/immich/config 0755 root root -"
    # The photo originals tree (UPLOAD_LOCATION). Slow tier per the overview's
    # volume column: bulk, sequential.
    "d /mnt/slow/photos 0755 root root -"
    # Books stack bind-mount roots (stacks/books/compose.yaml). Same reason as
    # the two blocks above: docker creates a missing bind source root-owned at
    # container start, and here that would matter — shelfmark drops privileges
    # to PUID/PGID 1000 and writes both library trees.
    #
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
    "d /mnt/fast/kavita 0755 root root -"
    "d /mnt/fast/kavita/config 0755 root root -"
    "d /mnt/fast/shelfmark 0755 root root -"
    "d /mnt/fast/shelfmark/config 0755 1000 1000 -"
    "d /mnt/fast/shelfmark/tmp 0755 1000 1000 -"
    "d /mnt/fast/audiobookshelf 0755 root root -"
    "d /mnt/fast/audiobookshelf/config 0755 root root -"
    "d /mnt/fast/audiobookshelf/metadata 0755 root root -"
    # Both library trees live under /mnt/slow/books deliberately: backrest's
    # slow-volume-selective plan already includes that path, so they are backed
    # up without touching its config.
    "d /mnt/slow/books 0755 1000 1000 -"
    "d /mnt/slow/books/library 0755 1000 1000 -"
    "d /mnt/slow/books/audiobooks 0755 1000 1000 -"
    # Automation stack bind-mount roots (stacks/automation/compose.yaml).
    #
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
    "d /mnt/fast/homeassistant 0755 root root -"
    "d /mnt/fast/mosquitto 0755 root root -"
    "d /mnt/fast/mosquitto/config 0755 1883 1883 -"
    "d /mnt/fast/mosquitto/data 0755 1883 1883 -"
    "d /mnt/fast/frigate 0755 root root -"
    "d /mnt/fast/frigate/config 0755 root root -"
    # Recordings, clips and exports. Deliberately NOT in backrest's
    # slow-volume include list — it is an explicit allowlist and this path is
    # not on it, which is how many GB of re-recordable video stays out of the
    # backups. Do not add it.
    "d /mnt/slow/frigate 0755 root root -"
    # Tracking stack bind-mount roots (stacks/tracking/compose.yaml). This
    # stack alone carries THREE different ownership conventions, and
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
    # Firefly III (stacks/firefly/compose.yaml) — a FOURTH convention in the
    # same port range. The image ends on `USER www-data` at BUILD time and
    # never invokes an id-remap entrypoint, so PUID/PGID are inert and the
    # upload directory must be pre-owned 33:33 or attachment upload fails at
    # runtime with a permission error and no startup symptom at all.
    # Its Postgres starts as root and chowns its own datadir, as everywhere
    # else here.
    "d /mnt/fast/firefly 0755 root root -"
    "d /mnt/fast/firefly/upload 0755 33 33 -"
    "d /mnt/fast/firefly/pgdata 0755 root root -"
    # Dawarich (stacks/dawarich/compose.yaml). Both of its entrypoints
    # gosu-drop to PUID/PGID *only if* they start as uid 0, chowning first —
    # which is why its compose sets no `user:` and these are 1000:1000 to
    # match what the entrypoint will enforce. Setting `user:` there instead
    # would skip the chown branch entirely and crash-loop on a root-owned
    # mount; upstream warns about it inline, twice.
    "d /mnt/fast/dawarich 0755 root root -"
    "d /mnt/fast/dawarich/public 0755 1000 1000 -"
    "d /mnt/fast/dawarich/storage 0755 1000 1000 -"
    "d /mnt/fast/dawarich/watched 0755 1000 1000 -"
    "d /mnt/fast/dawarich/pgdata 0755 root root -"
    # The redis image runs as uid 999 and does NOT chown its data directory.
    # This holds the sidekiq queue: losing it drops in-flight import and
    # statistics jobs, which is survivable, but a wrong owner makes redis
    # exit at start and takes sidekiq with it.
    "d /mnt/fast/dawarich/redis 0755 999 999 -"
    # Vaultwarden (stacks/vaultwarden/compose.yaml). Runs as ROOT: the debian
    # image declares no USER and start.sh execs the binary directly, so
    # root:root is what it will write as. That also matches backup-prepare.sh,
    # which reads db.sqlite3 from here as root.
    #
    # The path is load-bearing beyond ownership: backup-prepare.sh hardcodes
    # /mnt/fast/vaultwarden/db.sqlite3, and sqlite_backup returns 0 for a
    # MISSING source — so moving this mount would turn the vault's only dump
    # into a permanent silent no-op rather than an error.
    "d /mnt/fast/vaultwarden 0755 root root -"
    # Notes/Sync stack bind-mount roots (stacks/notes-sync/compose.yaml).
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
    # Windmill's Postgres (stacks/windmill/compose.yaml). Only the pgdata root
    # — the DEPENDENCY CACHE is deliberately a named docker volume and must
    # never get a rule here: the image bakes CPython 3.11 and 3.12 into
    # /tmp/windmill/cache at build time, a named volume is seeded from the
    # image on first use, and a bind mount is never seeded. Pointing it at
    # /mnt/fast would delete both interpreters, and UV_PYTHON_PREFERENCE=
    # only-managed forbids a system fallback, so the first Python job would
    # try to download one and hang offline.
    "d /mnt/fast/windmill 0755 root root -"
    "d /mnt/fast/windmill/pgdata 0755 root root -"
    # Food domain — TWO stacks (stacks/tandoor, stacks/wger), one per app,
    # because both are Django and both read the BARE name SECRET_KEY out of
    # their environment.
    #
    # Tandoor runs as ROOT (its Dockerfile has no USER instruction; nginx and
    # gunicorn both run as root, and boot.sh chmods the media root on every
    # start), so root:root is what it will write as.
    #
    # 🚨 Wger's media directory must be 1000:1000. Its base image does
    # `deluser ubuntu` then `adduser wger --uid 1000` and the production image
    # ends on `USER wger` — there is NO PUID/PGID, no id-remap entrypoint and
    # no chown-on-start, so a root-owned bind source makes collectstatic fail
    # on the very first boot. Finding #14's crash-loop pattern.
    "d /mnt/fast/tandoor 0755 root root -"
    "d /mnt/fast/tandoor/pgdata 0755 root root -"
    "d /mnt/fast/tandoor/mediafiles 0755 root root -"
    "d /mnt/fast/wger 0755 root root -"
    "d /mnt/fast/wger/pgdata 0755 root root -"
    "d /mnt/fast/wger/media 0755 1000 1000 -"
    # OnlyOffice DocSpace (stacks/docspace/compose.yaml). THREE different
    # conventions in three containers; do not normalise them.
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
    "d /mnt/fast/docspace/app 0755 root root -"
    "d /mnt/fast/docspace/logs 0755 root root -"
    "d /mnt/fast/docspace/ds-data 0755 root root -"
    "d /mnt/fast/docspace/ds-lib 0755 root root -"
    "d /mnt/fast/docspace/ds-logs 0755 root root -"
    "d /mnt/fast/docspace/mysqldata 0755 root root -"
    # Gatus (stacks/gatus/compose.yaml). Its SQLite history lives here; the
    # container is on the HOST network and has no ports: entry, which is why it
    # needs a host-network-declared entry in tests/lib/lints.nix.
    "d /mnt/fast/gatus 0755 root root -"
    # Beszel (stacks/beszel/compose.yaml). The hub's directory holds data.db,
    # the generated config.yml, and id_ed25519 at 0600 — beszel-init writes the
    # key mode itself, so this rule only needs to own the parent.
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
  ];

  # Swap (optional - can be added if needed)
  swapDevices = [ ];

  # Hardware
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
