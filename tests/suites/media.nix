# Media suite (heavy): the full media stack on the services VM — Jellyfin,
# the arrs, Seerr, Bazarr, Profilarr, Cleanuparr, ClamAV, and qBittorrent in
# gluetun's netns. ~14 containers; annex §8 of
# ServerNotes/designs/service-media-stack-research.md is the assertion spec.
#
# Genuinely under test:
#   - decrypt-sops-envs turning stacks/media/.sops.env into a 0600 .env owned
#     1000:1000, and env threading END TO END: the arr API keys, the qbit
#     PBKDF2 seed and the gluetun provider config exist only in the encrypted
#     fixture, so an API answering to the fixture key proves the whole
#     sops -> .env -> env_file -> {APP}__AUTH__APIKEY chain
#   - the KILL-SWITCH (the crown): the fixture points gluetun at TEST-NET-1
#     (192.0.2.1 — unroutable by construction), so the tunnel is down for the
#     whole suite. gluetun starts, raises its default-drop firewall, never
#     turns healthy — and qBittorrent, sharing that netns, must have ZERO
#     egress beyond the docker subnet while its UI on 127.0.0.1:10057 still
#     answers. Positive controls from a sibling container prove the probes
#     would succeed without the firewall.
#   - media-init end to end: health-gated reconciliation (root folders,
#     download client at gluetun:8080 via forceSave while the tunnel is down,
#     TRaSH naming, Prowlarr application push) and IDEMPOTENCE — a second run
#     logs zero "CHANGE:" lines (what protects Arcane redeploys)
#   - x265 ENFORCEMENT, mechanically and BOTH-SIDED: a TRaSH-style
#     "x265 (HD)" custom format scored -10000 AND an "x264" one scored
#     +10000 are injected into BOTH arrs via the API — the two artifacts an
#     x264-biased profile produces — and a media-init re-run must zero the
#     first, invert the second, and log the GUARD lines (the injection is
#     also what makes the sonarr sweep leg non-vacuous). Then both arrs are
#     swept: no custom format matching /x265|h.?265|hevc/i scores negative,
#     none matching /x264|h.?264|\bavc\b/i scores positive, and wherever a
#     profile carries both kinds the best x265 score strictly outranks the
#     best x264 score. A one-sided sweep would pass a profile that scores
#     x264 at +10000 — that is not "enforced", hence both sides.
#   - the ClamAV chain: EICAR dropped into the downloads tree is quarantined
#     by scan-downloads.sh within a poll interval, a clean file is untouched,
#     and clamd publishes no host port
#   - QUARANTINE IS AN INODE OPERATION: an EICAR file hardlinked into
#     /data/media BEFORE the scan — the state an *arr import leaves, and it
#     imports on qBittorrent's completion signal while the scanner polls, so
#     nothing sequences them — must be GONE FROM THE LIBRARY afterwards, not
#     merely renamed into .quarantine. Asserted as REACHABILITY: after the
#     verdict no path anywhere on /mnt/slow outside .quarantine resolves to
#     that inode, over two library links so a walk stopping at its first hit
#     fails. The old assertions passed while the malware was still in the
#     library; this one is what makes hardlink import safe for any consumer.
#   - the audiobook hand-off (Option C): a clean entry under the `audiobooks`
#     category is promoted whole into /mnt/slow/books/drop with its ownership
#     intact, an entry containing EICAR reaches the drop dir in no form (not
#     even its clean sibling track), and media-init has declared the category
#     in qBittorrent with the save path the promotion reads
#   - loopback-only publishing for every port 10050-10058, from another host
#
# Documented gaps (do not read a green run as covering these):
#   - Profilarr's Dictionarry database link + profile sync needs egress
#     (git clone of the PCD repo) — offline, media-init logs its WARN and the
#     arrs carry no Dictionarry profiles. The x265 sweep is therefore
#     structural here (guard mechanics + no negative scores), not a check of
#     Dictionarry profile CONTENT; that runs on the real host at first link.
#     Same reason Profilarr's /api/v1/arr is asserted to answer with the
#     fixture key but not to list linked arrs: linking them is the one
#     documented UI/backup-restore step (annex §6).
#   - gluetun can never turn HEALTHY offline (its healthcheck dials through
#     the tunnel), so `up --wait` cannot include it: it is started detached
#     and qbittorrent with --no-deps, and the netns behaviour is asserted
#     instead. The depends_on service_healthy + restart:true contract is
#     exercised only on the real host.
#   - actual HW transcode (Arc A380): no GPU in the VM. The compose's guarded
#     /dev/dri stanza is asserted to EXIST (drift guard, annex §8.18) and
#     jellyfin to run without the device — software-transcode degradation.
#   - annex §8.2 (indexer push): NOT exercised. No test indexer is added in
#     Prowlarr and nothing asserts one arrives in Radarr/Sonarr — only the
#     applications (fullSync) CONFIG is asserted, not a push. Needs a fake
#     indexer definition to be non-vacuous offline.
#   - annex §8.4 (bazarr/seerr wiring): NOT asserted — and the STACK does
#     not wire them yet either. media-init configures neither; bazarr's arr
#     connections and seerr's Jellyfin + arr connections are first-login UI
#     steps (annex §6 open question). Both get healthchecks only here.
#   - annex §8.12 (ntfy): the scanner's quarantine notification is never
#     asserted — ntfy is not deployed in this suite, and scan-downloads.sh's
#     notify-failure WARN line is not even grepped for.
#   - annex §8.14 (cleanuparr): healthchecked on its port only — no strike
#     exercise (needs a live queue), and the LOCAL malware-blocklist file
#     the compose comment points at is shipped by NOTHING in the stack:
#     production Cleanuparr starts WHOLLY UNCONFIGURED (v2 is UI/SQLite-
#     configured, annex §0.2) until its one-time UI setup. Read no coverage
#     into a green run here; freshclam updates and the arr-import -> strike
#     fallout additionally need egress / a live indexer.
#   - the clamav DB volume is seeded from the image before first start: the
#     bind mount shadows the image's baked database, and freshclam (which
#     populates it on the real host, where egress exists) cannot run offline.
#     Production first start just takes longer; the seed step mirrors its
#     outcome, not its mechanism.

{
  pkgs,
  lib,
  images,
  profiles,
  sopsModule,
  ...
}:

let
  stackImages = [
    # The deploy plane (Komodo) is MASKED in this suite — media does not test
    # it, and its 4 containers (Core/Periphery/FerretDB/Postgres) starved the
    # timing-sensitive clamav quarantine-inode test under the 3-concurrent
    # sweep. So no komodo images here; the mask is in the node config below.
    # The stack, every pinned ref from stacks/media/compose.yaml:
    images."qmcgaw_gluetun_v3_41_3"
    images."alpine_3_21" # qbit-init
    images."lscr_io_linuxserver_qbittorrent_5_2_3"
    images."jellyfin_jellyfin_10_11_11"
    images."lscr_io_linuxserver_radarr_6_3_0"
    images."lscr_io_linuxserver_sonarr_4_0_19"
    images."lscr_io_linuxserver_prowlarr_2_5_2"
    images."ghcr_io_seerr-team_seerr_v3_4_1"
    images."lscr_io_linuxserver_bazarr_1_6_0"
    images."ghcr_io_dictionarry-hub_profilarr_2_2_0"
    images."ghcr_io_cleanuparr_cleanuparr_2_10_5"
    images."clamav_clamav_1_5" # clamav + clamav-scanner (same pin)
    images."python_3_13-alpine" # media-init
  ];

  # Seeds /srv the way the real host gets it: stack-git-sync on the live
  # machine, a store copy here. Only the media stack is seeded — the other
  # stacks are the light suite's job; komodo is masked, so /srv/komodo is not
  # needed.
  seedSrv = pkgs.runCommand "srv-seed-media" { } ''
    mkdir -p $out/stacks/media
    cp -r ${../../stacks/media}/. $out/stacks/media/
    chmod -R u+w $out/stacks/media
    # The working-tree cp -r can capture a developer's locally-decrypted
    # plaintext .env (gitignored on purpose) in the world-readable store.
    rm -f $out/stacks/media/.env
    rm -f $out/stacks/media/.sops.env.example
    cp ${../fixtures/media.sops.env} $out/stacks/media/.sops.env
  '';
in
pkgs.testers.runNixOSTest {
  name = "media";

  # ~14 containers, several with long start periods (clamd loads its whole DB
  # into memory), plus explicit waits with minutes-scale budgets. The driver's
  # 3600s default would kill the VMs without running any except handler, so
  # the diag dumps would never print.
  globalTimeout = 7200;

  nodes = {
    services =
      { config, pkgs, ... }:
      {
        imports = [
          sopsModule
          ../../nixos/configuration.nix

          profiles.noBootloader
          profiles.noDhcp
          # No headscale in this suite; left on boot it would retry forever
          # against an unreachable login server and hold up multi-user.target.
          profiles.manualTailscaleAutoconnect
          (profiles.sopsFixture ../fixtures/services-vm.sops.yaml)
          # Biggest stack in the fleet: jellyfin + four arrs + clamd (whole
          # signature DB in RAM) fight for memory, and fourteen unpacked
          # images live in /var/lib/docker.
          (profiles.sized {
            memoryMB = 8192;
            diskMB = 24576;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            # Komodo masked below, so nothing container-shaped runs at boot;
            # the only contract is "loaded before the test script's compose up".
            beforeUnits = [ "multi-user.target" ];
          })
          {
            # Keep the deploy plane out of the boot path — media does not test
            # it, and its containers starve the quarantine-inode timing. The
            # stack-git-sync timer would also fail its clone (no Forgejo here).
            systemd.services.bootstrap-komodo.wantedBy = lib.mkForce [ ];
            systemd.timers.stack-git-sync.wantedBy = lib.mkForce [ ];
          }
        ];

        # This many containers on the sized profile's 2 cores makes every
        # healthcheck window a coin toss; 4 keeps startup contention sane.
        virtualisation.cores = lib.mkForce 4;

        # decrypt-sops-envs.service and bootstrap-komodo.service both
        # `requires = srv.mount`; the tmpfs gives them a genuine .mount unit.
        # /mnt/fast holds every config volume, /mnt/slow the /data tree.
        virtualisation.fileSystems = {
          "/srv" = {
            device = "tmpfs";
            fsType = "tmpfs";
            options = [ "mode=0755" ];
          };
          "/mnt/fast" = {
            device = "tmpfs";
            fsType = "tmpfs";
            options = [ "mode=0755" ];
          };
          "/mnt/slow" = {
            device = "tmpfs";
            fsType = "tmpfs";
            options = [ "mode=0755" ];
          };
        };

        systemd.tmpfiles.rules = [
          # Mirrors nixos/hardware-configuration.nix, which cannot be
          # imported here because it mounts real partitions by partlabel.
          # The media rules below are the SAME set production declares —
          # keep the two lists in sync by hand. (No /srv/komodo: masked here.)
          "d /srv/stacks 0755 1000 1000 -"
          "d /var/lib/sops-nix 0700 root root -"
          # Bind-mount roots from stacks/media/compose.yaml. root-owned is
          # correct for the config dirs: the LSIO images chown per PUID/PGID
          # from a root entrypoint, jellyfin/profilarr run as root, seerr's
          # seerr-init oneshot chowns its config, and clamav 1.5's /init
          # (runs as root, VERIFIED by reading the pinned image's entrypoint)
          # does `chown -R clamav:clamav /var/lib/clamav` unconditionally —
          # "just in case it is a mounted volume" — before starting clamd.
          # /mnt/slow/data is 1000:1000 — media-init asserts/creates the
          # skeleton under it with that owner.
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
          "d /mnt/slow/data/downloads 0755 1000 1000 -"
          "d /mnt/slow/data/media 0755 1000 1000 -"
          # The books stack's drop directory. It belongs to stacks/books
          # (that is where the generator's rule for it lives) but the media
          # stack is its WRITER — clamav-scanner moves clean `audiobooks`
          # downloads into it — so this suite has to declare it too, or
          # docker would create it root-owned at container start and the
          # ownership assertions below would be measuring docker's default.
          "d /mnt/slow/books 0755 1000 1000 -"
          "d /mnt/slow/books/drop 0755 1000 1000 -"
        ];

        # Populate /srv before anything reads it — the stand-in for Arcane's
        # git sync having already run.
        systemd.services.seed-srv = {
          description = "Seed /srv from the repo (test only)";
          after = [ "srv.mount" ];
          requires = [ "srv.mount" ];
          before = [ "decrypt-sops-envs.service" ];
          requiredBy = [ "decrypt-sops-envs.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            mkdir -p /srv/stacks
            cp -r --no-preserve=mode ${seedSrv}/stacks/. /srv/stacks/
            chown -R 1000:1000 /srv/stacks
          '';
        };

        environment.systemPackages = with pkgs; [
          docker-compose
          jq
        ];
      };

    # Another host on the LAN, in two roles: the loopback negative probes
    # (anything it can reach on a non-tailnet interface is reachable from the
    # whole VLAN), and the kill-switch egress target — it serves a trivial
    # HTTP 200 that containers WITH egress reach through the host's NAT and
    # qbittorrent must not.
    outsider =
      { ... }:
      {
        services.nginx = {
          enable = true;
          virtualHosts."outsider" = {
            default = true;
            locations."/".return = "200 'outsider-ok'";
          };
        };
        networking.firewall.allowedTCPPorts = [ 80 ];
      };
  };

  testScript = ''
    import json
    import re
    import shlex

    MEDIA = "docker compose -f /srv/stacks/media/compose.yaml -p media"

    # Fixture values from tests/fixtures/media.sops.env — committed test-only
    # secrets, same pattern as the backrest suite's test_backrest_password.
    RKEY = "746573747261646172726b6579303031"
    SKEY = "74657374736f6e6172726b6579303031"
    PKEY = "7465737470726f776c6172726b657931"
    PFKEY = "7465737470726f66696c6172726b65793030303030303030303030303030"
    QBIT_USER = "test_qbit_user"
    QBIT_PASS = "test_qbit_password_not_secret"

    ARRS = {
        "radarr": (10051, "v3", RKEY),
        "sonarr": (10052, "v3", SKEY),
        "prowlarr": (10053, "v1", PKEY),
    }

    def diag(label):
        # A --wait failure ten minutes into a boot is useless without context;
        # dump what docker actually did on the way out.
        print("=== diagnostics: " + label + " ===")
        for cmd in [
            "docker ps -a",
            "docker logs gluetun 2>&1 | tail -40",
            "docker logs qbittorrent 2>&1 | tail -30",
            "docker logs media_qbit_init 2>&1 | tail -20",
            "docker logs media_init 2>&1 | tail -60",
            "docker logs radarr 2>&1 | tail -30",
            "docker logs prowlarr 2>&1 | tail -20",
            "docker logs profilarr 2>&1 | tail -30",
            "docker logs cleanuparr 2>&1 | tail -30",
            "docker logs seerr 2>&1 | tail -30",
            "docker logs clamav 2>&1 | tail -40",
            "docker logs clamav_scanner 2>&1 | tail -30",
            # The scanner's OWN view of the tree it polls. A quarantine that
            # never happens is either "the loop never saw the file" or "clamd
            # said clean", and only the container can tell you which: the
            # host's ls proves nothing about what is visible through the
            # bind mounts.
            "docker exec clamav_scanner sh -c "
            "'date; ls -la /data /data/downloads /data/downloads/movies "
            "/data/downloads/audiobooks /state /drop 2>&1; "
            "echo ---newer---; find /data/downloads -newer /state/last-scan "
            "2>&1 | head -20' 2>&1",
            "ls -la /srv/stacks/media /mnt/fast /mnt/slow/data 2>&1",
            "df -h /var/lib/docker /mnt/fast /mnt/slow; free -m",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    def api(name, path, method="GET", body=None):
        # Servarr API helper: talks to the loopback-published port with the
        # fixture key, JSON in/out. Bodies go through a pipe so shell quoting
        # cannot mangle them.
        port, ver, key = ARRS[name]
        cmd = (
            f"curl -sf --max-time 60 -X {method} -H 'X-Api-Key: {key}' "
            "-H 'Content-Type: application/json' "
        )
        url = f"http://127.0.0.1:{port}/api/{ver}/{path}"
        if body is not None:
            payload = shlex.quote(json.dumps(body))
            full = f"printf '%s' {payload} | " + cmd + "-d @- " + url
        else:
            full = cmd + url
        out = services_vm.succeed(full)
        return json.loads(out) if out.strip() else None

    def run_media_init():
        # Re-runs the exited oneshot with its original env and mounts (the
        # backrest config-init pattern); returns ONLY this run's output.
        return services_vm.succeed("docker start -a media_init 2>&1")

    start_all()

    # -----------------------------------------------------------------------
    # Boot chain: sops fixture -> decrypted .env -> homelab network -> stack
    # -----------------------------------------------------------------------
    with subtest("decrypt-sops-envs produced a 0600 .env owned by uid 1000 (the /srv/stacks world)"):
        services_vm.wait_for_unit("docker-network-homelab.service")
        # Komodo is masked here, so decrypt runs via its minutely timer, not
        # bootstrap-komodo's Requires — wait the .env out (mk-stack-suite pattern).
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_until_succeeds("test -s /srv/stacks/media/.env", timeout=90)
        stat = services_vm.succeed(
            "stat -c '%a %u:%g' /srv/stacks/media/.env"
        ).strip()
        assert stat == "600 1000:1000", f".env is {stat}, expected 600 1000:1000"
        # The keys everything below depends on: a later API failure then
        # points at the service, not at decryption.
        for k in ["RADARR__AUTH__APIKEY", "QBIT_WEBUI_PASSWORD_PBKDF2",
                  "VPN_SERVICE_PROVIDER"]:
            services_vm.succeed(f"grep -q '^{k}=' /srv/stacks/media/.env")

    # Images are loaded before multi-user.target; the compose runs below must
    # not race the load (an `up` mid-load pulls nothing offline).
    services_vm.wait_for_unit("load-test-images.service")

    # -----------------------------------------------------------------------
    # Test-only: seed the clamav DB volume from the image (see header — the
    # bind mount shadows the baked database and freshclam has no egress here;
    # on the real host freshclam populates it on first start instead).
    # -----------------------------------------------------------------------
    with subtest("clamav signature DB seeded from the image"):
        services_vm.succeed("docker create --name clamdb-seed clamav/clamav:1.5")
        services_vm.succeed(
            "docker cp clamdb-seed:/var/lib/clamav/. /mnt/fast/clamav/db/"
        )
        services_vm.succeed("docker rm clamdb-seed")
        # clamd runs as the image's clamav user; chown through the image so
        # the uid is whatever IT says, not a guessed constant.
        services_vm.succeed(
            "docker run --rm -v /mnt/fast/clamav/db:/db --entrypoint sh "
            "clamav/clamav:1.5 -c 'chown -R clamav:clamav /db'"
        )
        services_vm.succeed("test -s /mnt/fast/clamav/db/main.cvd")

    # -----------------------------------------------------------------------
    # (a) the stack comes up
    # -----------------------------------------------------------------------
    # gluetun is started detached and NEVER waited on: its healthcheck dials
    # through the tunnel, and the fixture keeps the tunnel down by
    # construction (TEST-NET-1 endpoint). Everything that can converge is
    # brought up with --wait; qbittorrent joins gluetun's netns afterwards
    # with --no-deps (its gluetun-healthy gate can never be met offline —
    # documented gap, see header).
    with subtest("gluetun starts detached and raises its firewall"):
        services_vm.succeed(MEDIA + " up -d gluetun")
        services_vm.wait_until_succeeds(
            "docker inspect -f '{{.State.Status}}' gluetun | grep -qx running",
            timeout=120,
        )

    with subtest("qbittorrent starts into gluetun's netns and turns healthy"):
        # Before the arrs: media-init's download-client POST triggers a live
        # connection test (forceSave does not override severity:error), so
        # qbit must be answering on the shared netns first. --no-deps because
        # qbit's gluetun-healthy gate can never be met offline (see header);
        # qbit-init is therefore ordered explicitly here.
        try:
            # No --wait here: compose's --wait reports failure when the only
            # in-scope service is a oneshot that (successfully) exited. Poll
            # the exit code instead.
            services_vm.succeed(MEDIA + " up -d qbit-init")
            services_vm.wait_until_succeeds(
                "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
                "media_qbit_init | grep -qx exited/0",
                timeout=120,
            )
            services_vm.succeed(MEDIA + " up -d --no-deps qbittorrent")
            # Its healthcheck is the WebUI on the shared netns' loopback —
            # deliberately independent of tunnel state.
            services_vm.wait_until_succeeds(
                "docker inspect -f '{{.State.Health.Status}}' qbittorrent "
                "| grep -qx healthy",
                timeout=300,
            )
        except Exception:
            diag("qbittorrent start")
            raise

    with subtest("docker compose brings up every waitable service"):
        # media-init is NOT in this set: compose's --wait reports failure for
        # an in-scope oneshot that exited 0 unless a dependent consumes it
        # (backrest's config-init has one; media-init does not). It is
        # started right after, against already-healthy dependencies.
        try:
            services_vm.succeed(
                MEDIA + " up -d --wait --wait-timeout 1200 "
                "jellyfin radarr sonarr prowlarr seerr seerr-init bazarr "
                "profilarr cleanuparr clamav clamav-scanner",
                timeout=1300,
            )
        except Exception:
            diag("compose up --wait")
            raise

    with subtest("media-init reconciles the stack and exits 0"):
        try:
            services_vm.succeed(MEDIA + " up -d media-init")
            services_vm.wait_until_succeeds(
                "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
                "media_init | grep -qx exited/0",
                timeout=900,
            )
        except Exception:
            diag("media-init run")
            raise

    with subtest("every container is in its contract state"):
        # Healthchecked services must be healthy; the two init oneshots must
        # have exited 0; gluetun must be running AND unhealthy — offline, a
        # healthy gluetun would mean its healthcheck no longer proves the
        # tunnel, which is exactly the regression this pins.
        for name in ["qbittorrent", "jellyfin", "radarr", "sonarr", "prowlarr",
                     "seerr", "bazarr", "profilarr", "cleanuparr", "clamav",
                     "clamav_scanner"]:
            h = services_vm.succeed(
                f"docker inspect -f '{{{{.State.Health.Status}}}}' {name}"
            ).strip()
            assert h == "healthy", f"{name} is {h!r}, expected healthy"
        for name in ["media_qbit_init", "media_seerr_init", "media_init"]:
            code = services_vm.succeed(
                f"docker inspect -f '{{{{.State.ExitCode}}}}' {name}"
            ).strip()
            assert code == "0", f"{name} exited {code}, expected 0"
        st = services_vm.succeed(
            "docker inspect -f '{{.State.Status}}/{{.State.Health.Status}}' gluetun"
        ).strip()
        assert st == "running/unhealthy", (
            f"gluetun is {st!r}, expected running/unhealthy (tunnel down by "
            "construction — see the fixture)"
        )

    # -----------------------------------------------------------------------
    # (b) THE KILL-SWITCH: tunnel down => zero egress from qbit's netns
    # -----------------------------------------------------------------------
    with subtest("kill-switch: qbittorrent has zero egress beyond the docker subnet"):
        outsider_ip = outsider.succeed(
            "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
        ).strip()
        services_ip = services_vm.succeed(
            "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
        ).strip()
        gw = services_vm.succeed(
            "docker network inspect media_default "
            "-f '{{(index .IPAM.Config 0).Gateway}}'"
        ).strip()
        assert outsider_ip and services_ip and gw, (
            f"missing address: outsider={outsider_ip!r} "
            f"services={services_ip!r} gw={gw!r}"
        )

        # Positive controls first, from a sibling container on the same
        # docker network: without them the fail() probes below would pass
        # identically on a dead NAT path and prove nothing.
        services_vm.succeed(
            f"docker exec radarr curl -sf --max-time 10 http://{outsider_ip}/ "
            "| grep -q outsider-ok"
        )
        services_vm.succeed(
            "docker exec radarr bash -c "
            + shlex.quote(f'timeout 5 bash -c ": </dev/tcp/{services_ip}/22"')
        )

        # The crown: the SAME probes from qbittorrent's (= gluetun's) netns
        # must fail — the LAN, the host's LAN address, anything beyond the
        # docker subnet is default-dropped while the tunnel is down.
        services_vm.fail(
            f"docker exec qbittorrent curl -s --max-time 10 http://{outsider_ip}/"
        )
        services_vm.fail(
            "docker exec qbittorrent bash -c "
            + shlex.quote(f'timeout 5 bash -c ": </dev/tcp/{services_ip}/22"')
        )

        # Documented exception, pinned on purpose: gluetun always allows the
        # container's OWN docker subnet (that is what lets docker's embedded
        # DNS work and the arrs reach the WebUI) — the gateway is in-subnet,
        # so the host's sshd IS reachable through it. Not a hole in the
        # kill-switch: it never crosses the bridge.
        services_vm.succeed(
            "docker exec qbittorrent bash -c "
            + shlex.quote(f'timeout 5 bash -c ": </dev/tcp/{gw}/22"')
        )

    with subtest("kill-switch != UI outage: the WebUI answers on loopback"):
        services_vm.wait_until_succeeds(
            "curl -sf --max-time 5 http://127.0.0.1:10057/ -o /dev/null",
            timeout=60,
        )
        # And the fixture PBKDF2 is a REAL derivation: qbit-init's seeded
        # credentials actually log in (Referer required by qbit's CSRF
        # check; qBittorrent 5.2.x answers 204 on success, 401 on bad
        # creds). Good login FIRST — qbit IP-bans after repeated failures.
        code = services_vm.succeed(
            "curl -s -o /dev/null -w '%{http_code}' --max-time 10 "
            "-H 'Referer: http://127.0.0.1:10057' "
            + f"--data-urlencode 'username={QBIT_USER}' "
            f"--data-urlencode 'password={QBIT_PASS}' "
            "http://127.0.0.1:10057/api/v2/auth/login"
        ).strip()
        assert code == "204", f"qbit login returned {code}, expected 204"
        code = services_vm.succeed(
            "curl -s -o /dev/null -w '%{http_code}' --max-time 10 "
            "-H 'Referer: http://127.0.0.1:10057' "
            + f"--data-urlencode 'username={QBIT_USER}' "
            "--data-urlencode 'password=definitely-wrong' "
            "http://127.0.0.1:10057/api/v2/auth/login"
        ).strip()
        assert code == "401", (
            f"qbit login with a wrong password returned {code}, expected 401"
        )

    # -----------------------------------------------------------------------
    # (c) arr wiring
    # -----------------------------------------------------------------------
    with subtest("each arr answers to the fixture API key, and only to it"):
        for name, (port, ver, key) in ARRS.items():
            status = api(name, "system/status")
            assert status.get("appName", "").lower() == name, (
                f"{name} system/status: {status!r}"
            )
            code = services_vm.succeed(
                "curl -s -o /dev/null -w '%{http_code}' --max-time 10 "
                + f"http://127.0.0.1:{port}/api/{ver}/system/status"
            ).strip()
            assert code == "401", (
                f"{name} without a key returned {code}, expected 401"
            )

    with subtest("media-init wired the stack (first run made changes)"):
        first = services_vm.succeed("docker logs media_init 2>&1")
        assert "media-init: CHANGE:" in first, (
            f"first media-init run logged no changes:\n{first}"
        )
        assert "FATAL" not in first, f"media-init logged FATAL:\n{first}"

    with subtest("radarr and sonarr list qbit at gluetun:8080 with a root folder"):
        for name, root, cat in [("radarr", "/data/media/movies", "movies"),
                                ("sonarr", "/data/media/tv", "tv")]:
            folders = api(name, "rootfolder")
            assert any(f.get("path") == root for f in folders), (
                f"{name} rootfolders: {folders!r}"
            )
            clients = api(name, "downloadclient")
            qb = [c for c in clients if c.get("name") == "qbittorrent"]
            assert qb, f"{name} has no qbittorrent download client: {clients!r}"
            fields = {f["name"]: f.get("value") for f in qb[0]["fields"]}
            # The load-bearing bit: the arrs reach qbit at gluetun's compose
            # DNS name — configured via forceSave while the tunnel is down.
            assert fields.get("host") == "gluetun" and fields.get("port") == 8080, (
                f"{name} qbit client fields: {fields!r}"
            )

    with subtest("the arr->qbit path is live even with the tunnel down"):
        # Inbound to the netns on 8080 is exempted by FIREWALL_INPUT_PORTS;
        # this is the connection the download clients actually use.
        services_vm.succeed(
            "docker exec radarr curl -sf --max-time 10 "
            "http://gluetun:8080/ -o /dev/null"
        )

    with subtest("prowlarr lists both arrs as fullSync applications"):
        apps = api("prowlarr", "applications")
        impls = sorted(a.get("implementation") for a in apps)
        assert impls == ["Radarr", "Sonarr"], f"prowlarr applications: {impls!r}"
        for a in apps:
            assert a.get("syncLevel") == "fullSync", (
                f"{a.get('name')} syncLevel is {a.get('syncLevel')!r}"
            )
            fields = {f["name"]: f.get("value") for f in a["fields"]}
            want = {"Radarr": "http://radarr:7878", "Sonarr": "http://sonarr:8989"}
            assert fields.get("baseUrl") == want[a["implementation"]], (
                f"{a['implementation']} baseUrl: {fields.get('baseUrl')!r}"
            )

    with subtest("media-init is idempotent: a second run makes zero changes"):
        try:
            out = run_media_init()
        except Exception:
            diag("media-init second run")
            raise
        assert "media-init: CHANGE:" not in out, (
            f"second media-init run was not a no-op:\n{out}"
        )
        assert "complete: 0 change(s)" in out, (
            f"second run did not report zero changes:\n{out}"
        )

    with subtest("backup-prepare's sqlite dump paths exist on the live stack"):
        # Pins the path contract for nixos/backup-prepare.sh's sqlite_backup
        # lines: its `[ -f ] || return 0` silently skips FOREVER on a drifted
        # path, and nothing else exercises these paths against live arrs.
        for p in [
            "/mnt/fast/radarr/config/radarr.db",
            "/mnt/fast/sonarr/config/sonarr.db",
            "/mnt/fast/prowlarr/config/prowlarr.db",
            "/mnt/fast/bazarr/config/db/bazarr.db",
            "/mnt/fast/jellyfin/config/data/jellyfin.db",
            "/mnt/fast/seerr/config/db/db.sqlite3",
        ]:
            services_vm.succeed(f"test -f {p}")

    # -----------------------------------------------------------------------
    # (d) x265 ENFORCEMENT — mechanical, not vibes
    # -----------------------------------------------------------------------
    with subtest("the guard fixes BOTH sides of an x264-biased profile"):
        # Inject the two artifacts an x264-biased profile produces — TRaSH's
        # golden-rule 'x265 (HD)' at -10000 AND an 'x264' at +10000 — into
        # BOTH arrs via the API, then re-run media-init: the guard must zero
        # the first, invert the second, and say so. This is the codified
        # anti-TRaSH assertion (and what makes the sonarr leg of the sweep
        # below non-vacuous — without injection sonarr carries no codec CFs);
        # the offline gap is only Dictionarry profile CONTENT (see header).
        cf265 = {
            "name": "x265 (HD)",
            "includeCustomFormatWhenRenaming": False,
            "specifications": [{
                "name": "x265",
                "implementation": "ReleaseTitleSpecification",
                "negate": False,
                "required": True,
                "fields": [{"name": "value", "value": "[xh]265|HEVC"}],
            }],
        }
        cf264 = {
            "name": "x264",
            "includeCustomFormatWhenRenaming": False,
            "specifications": [{
                "name": "x264",
                "implementation": "ReleaseTitleSpecification",
                "negate": False,
                "required": True,
                "fields": [{"name": "value", "value": "[xh]264|AVC"}],
            }],
        }
        try:
            injected = {}
            for name in ["radarr", "sonarr"]:
                id265 = api(name, "customformat", "POST", cf265)["id"]
                id264 = api(name, "customformat", "POST", cf264)["id"]
                profs = api(name, "qualityprofile")
                assert profs, f"{name} has no quality profiles at all"
                prof = profs[0]
                hits = {id265: 0, id264: 0}
                for fi in prof.get("formatItems", []):
                    if fi.get("format") == id265:
                        fi["score"] = -10000
                        hits[id265] += 1
                    elif fi.get("format") == id264:
                        fi["score"] = 10000
                        hits[id264] += 1
                assert hits == {id265: 1, id264: 1}, (
                    f"expected each new CF once in {name}'s formatItems, "
                    f"saw {hits}: {prof!r}"
                )
                api(name, f"qualityprofile/{prof['id']}", "PUT", prof)
                injected[name] = (id265, id264, prof["id"])

            out = run_media_init()
            assert "GUARD" in out and "zeroing (x265 ENFORCED)" in out, (
                f"guard did not zero the injected -10000 x265 CFs:\n{out}"
            )
            assert "inverting" in out, (
                f"guard did not invert the injected +10000 x264 CFs:\n{out}"
            )

            # And the APIs agree: x265 back to 0, x264 inverted to -10000,
            # in each arr independently (the log asserts above cannot tell
            # which arr a GUARD line came from).
            for name, (id265, id264, pid) in injected.items():
                prof2 = api(name, f"qualityprofile/{pid}")
                scores = {fi.get("format"): fi.get("score")
                          for fi in prof2.get("formatItems", [])}
                assert scores.get(id265) == 0, (
                    f"{name} post-guard x265 score: {scores.get(id265)!r}, "
                    "expected 0"
                )
                assert scores.get(id264) == -10000, (
                    f"{name} post-guard x264 score: {scores.get(id264)!r}, "
                    "expected -10000"
                )

            # A further run is a no-op again — the guard itself is idempotent
            # (including the strictness demotion on every OTHER profile, where
            # both CFs landed at the arrs' default score of 0).
            out = run_media_init()
            assert "complete: 0 change(s)" in out, (
                f"run after the guard was not a no-op:\n{out}"
            )
        except Exception:
            diag("x265 guard")
            raise

    with subtest("x265 outranks x264 in every profile (both-sided sweep)"):
        # The sweep from annex §8.6/§8.7, over BOTH arrs and every profile,
        # both-sided: negative x265 AND positive x264 each defeat the policy,
        # and a profile carrying both kinds must rank x265 STRICTLY higher —
        # pure formatItems arithmetic, no egress needed.
        x265 = re.compile(r"x265|h\.?265|hevc", re.I)
        x264 = re.compile(r"x264|h\.?264|\bavc\b", re.I)
        for name in ["radarr", "sonarr"]:
            cfs = api(name, "customformat") or []
            f265 = {c["id"]: c["name"]
                    for c in cfs if x265.search(c.get("name", ""))}
            # A name matching both regexes (e.g. "h264/h265") counts as x265
            # so the two rule sets cannot fight over one format — same
            # precedence media-init's guard uses.
            f264 = {c["id"]: c["name"]
                    for c in cfs
                    if x264.search(c.get("name", "")) and c["id"] not in f265}
            for prof in api(name, "qualityprofile") or []:
                s265, s264 = [], []
                for fi in prof.get("formatItems", []):
                    if fi.get("format") in f265:
                        s265.append(fi.get("score", 0))
                        assert fi.get("score", 0) >= 0, (
                            f"{name} profile {prof['name']!r} scores "
                            f"{f265[fi['format']]!r} at {fi['score']} — "
                            "x265 is ENFORCED"
                        )
                    elif fi.get("format") in f264:
                        s264.append(fi.get("score", 0))
                        assert fi.get("score", 0) <= 0, (
                            f"{name} profile {prof['name']!r} scores "
                            f"{f264[fi['format']]!r} at {fi['score']} — "
                            "a positive x264 score defeats x265 enforcement"
                        )
                if s265 and s264:
                    assert max(s265) > max(s264), (
                        f"{name} profile {prof['name']!r}: best x265 score "
                        f"{max(s265)} does not strictly outrank best x264 "
                        f"score {max(s264)} — x265 is ENFORCED"
                    )

    with subtest("profilarr answers to the fixture key; anonymous is refused"):
        # Content assertions (linked arrs, Dictionarry DB) need egress and the
        # one documented UI step — the offline claim is exactly: healthy
        # container, API key from the fixture works, no key does not.
        services_vm.succeed(
            f"curl -sf --max-time 10 -H 'X-Api-Key: {PFKEY}' "
            "http://127.0.0.1:10056/api/v1/arr -o /dev/null"
        )
        code = services_vm.succeed(
            "curl -s -o /dev/null -w '%{http_code}' --max-time 10 "
            "http://127.0.0.1:10056/api/v1/arr"
        ).strip()
        assert code != "200", (
            f"profilarr /api/v1/arr answered {code} with no key (AUTH=on)"
        )
        # media-init could not link Dictionarry offline — that must be the
        # loud WARN with the UI fallback, never a silent skip or a FATAL.
        # Line-anchored on the exact prefix media-init.sh emits: independent
        # greps for 'profilarr' and 'WARN' would be satisfied by an unrelated
        # WARN (the download-client retry) plus a profilarr OK line.
        init_log = services_vm.succeed("docker logs media_init 2>&1")
        assert re.search(r"^media-init: WARN: profilarr: ", init_log, re.M), (
            "media-init did not log the documented Profilarr WARN fallback "
            f"line:\n{init_log}"
        )

    # -----------------------------------------------------------------------
    # (e) ClamAV: EICAR in, quarantine out; clean file untouched
    # -----------------------------------------------------------------------
    with subtest("EICAR is quarantined; the clean file is not"):
        # Assembled from two halves so no committed file starts with the
        # 68-byte EICAR signature (dev-machine AV scanners flag those).
        e1 = "X5O!P%@AP[4\\PZX54(P^)7CC)7}"
        e2 = "$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"
        services_vm.succeed(
            "printf '%s' 'clean media suite fixture' "
            "> /mnt/slow/data/downloads/movies/clean.txt"
        )
        services_vm.succeed(
            f"printf '%s' {shlex.quote(e1 + e2)} "
            "> /mnt/slow/data/downloads/movies/eicar.mkv"
        )
        try:
            # SCAN_INTERVAL_SECONDS=60 in the compose; one interval + scan
            # time, with slack for a pass already in flight.
            services_vm.wait_until_succeeds(
                "ls /mnt/slow/data/downloads/.quarantine/ "
                "| grep -q '^eicar\\.mkv\\.'",
                timeout=420,
            )
        except Exception:
            diag("eicar quarantine")
            raise
        services_vm.fail("test -e /mnt/slow/data/downloads/movies/eicar.mkv")
        logs = services_vm.succeed("docker logs clamav_scanner 2>&1")
        assert "INFECTED" in logs, f"scanner never logged INFECTED:\n{logs}"
        # The clean file survived at least one full pass (the pass that took
        # the EICAR) untouched, in place.
        services_vm.succeed("test -f /mnt/slow/data/downloads/movies/clean.txt")
        services_vm.fail(
            "ls /mnt/slow/data/downloads/.quarantine/ | grep -q clean"
        )

    with subtest("quarantine follows the INODE: a pre-scan hardlink dies too"):
        # 🚨 THE regression test for the ClamAV-quarantine/import race
        # (ServerNotes/designs/audiobook-acquisition.md, finding 4).
        #
        # *arr imports are HARDLINKS by design — /mnt/slow is one filesystem
        # precisely so they are (compose.yaml's layout header) — and they
        # fire on qBittorrent's completion signal while this scanner polls
        # every 60s. Nothing sequences the two. Quarantine used to be a bare
        # `mv` within that one filesystem, i.e. a RENAME: it moved a
        # directory entry and left the inode, so the library link kept
        # resolving to the infected content. The subtest above would have
        # stayed green through all of it — it asserts that .quarantine gained
        # a file, which is exactly what still happened.
        #
        # Written LINK-FIRST on purpose: the EICAR bytes are created at the
        # LIBRARY path, which the scanner never walks, and only then
        # hardlinked into the download tree. "The link existed before the
        # verdict" is then true by construction rather than by timing.
        lib_dir = "/mnt/slow/data/media/movies/Race Test (2026)"
        lib_file = f"{lib_dir}/race.mkv"
        # A SECOND library link, in a second directory. An *arr leaves more
        # than one often enough (re-import, a kept manual copy), and a walk
        # that stopped at its first hit would pass with only one to find.
        lib_dir2 = "/mnt/slow/data/media/movies/Race Test Copy (2026)"
        lib_file2 = f"{lib_dir2}/race.mkv"
        dl_file = "/mnt/slow/data/downloads/movies/race.mkv"
        services_vm.succeed(
            "mkdir -p " + shlex.quote(lib_dir) + " " + shlex.quote(lib_dir2)
        )
        services_vm.succeed(
            f"printf '%s' {shlex.quote(e1 + e2)} > {shlex.quote(lib_file)}"
        )
        services_vm.succeed(
            f"ln {shlex.quote(lib_file)} {shlex.quote(lib_file2)}"
        )
        services_vm.succeed(
            f"ln {shlex.quote(lib_file)} {shlex.quote(dl_file)}"
        )
        # Owned like production. Unlinking needs write on the DIRECTORY, and
        # the arrs create these as uid 1000 — leaving them root-owned would
        # let a scanner that stopped running as root still pass this test.
        services_vm.succeed(
            "chown -R 1000:1000 " + shlex.quote(lib_dir) + " "
            + shlex.quote(lib_dir2)
        )
        # Three names, one inode: the state an *arr import leaves behind. If
        # this is ever 1, the test is not modelling the race any more.
        links = services_vm.succeed(
            f"stat -c %h {shlex.quote(dl_file)}"
        ).strip()
        assert links == "3", (
            f"the fixture is not hardlinked (nlink={links}) — /mnt/slow must "
            "be one filesystem for this test to model an *arr import"
        )
        # The inode itself, so the assertion below can ask the question the
        # defect was actually about — reachability — instead of asking about
        # the two paths this test happens to know.
        ino = services_vm.succeed(f"stat -c %i {shlex.quote(dl_file)}").strip()
        try:
            services_vm.wait_until_succeeds(
                "ls /mnt/slow/data/downloads/.quarantine/ "
                "| grep -q '^race\\.mkv\\.'",
                timeout=420,
            )
            # THE assertion. Not "quarantine gained a file" — "the library
            # links are gone". A rename-only quarantine fails exactly here
            # while .quarantine looks perfectly correct.
            services_vm.wait_until_fails(
                f"test -e {shlex.quote(lib_file)}", timeout=120
            )
            services_vm.wait_until_fails(
                f"test -e {shlex.quote(lib_file2)}", timeout=120
            )
        except Exception:
            diag("eicar hardlink race")
            raise
        services_vm.fail(f"test -e {shlex.quote(dl_file)}")

        # And the general form: NO path anywhere on /mnt/slow, outside the
        # quarantine dir, still resolves to that inode. This is the one that
        # would catch a walk scoped to a subtree the test did not think of.
        reachable = services_vm.succeed(
            "find /mnt/slow -xdev "
            "-path /mnt/slow/data/downloads/.quarantine -prune -o "
            f"-type f -inum {ino} -print"
        ).strip()
        assert reachable == "", (
            "the infected inode is still reachable outside .quarantine:\n"
            + reachable
        )

        # The evidence sample survives, and it is the ONLY link left: the
        # quarantine directory is what the unlink walk prunes, which is what
        # makes it the survivor rather than a lucky one.
        q = services_vm.succeed(
            "ls -1 /mnt/slow/data/downloads/.quarantine/race.mkv.*"
        ).strip().splitlines()[0]
        services_vm.succeed(f"grep -q EICAR {shlex.quote(q)}")
        qlinks = services_vm.succeed(f"stat -c %h {shlex.quote(q)}").strip()
        assert qlinks == "1", (
            f"the quarantined sample still has {qlinks} links — something "
            "else still reaches the infected inode"
        )
        # Both removals are REPORTED. A quarantine that purges links without
        # saying which is unauditable after the fact.
        logs = services_vm.succeed("docker logs clamav_scanner 2>&1")
        unlinked = [l for l in logs.splitlines() if "scan: UNLINKED" in l]
        for d in [lib_dir, lib_dir2]:
            assert any(d in l for l in unlinked), (
                f"the scanner unlinked nothing under {d!r} — UNLINKED lines: "
                f"{unlinked!r}"
            )
        # Nothing else in the library was touched by the walk: the emptied
        # directories are still there (removing them is the arr's job).
        services_vm.succeed("test -d " + shlex.quote(lib_dir))
        services_vm.succeed("test -d " + shlex.quote(lib_dir2))
        services_vm.succeed("test -f /mnt/slow/data/downloads/movies/clean.txt")

    # -----------------------------------------------------------------------
    # (e2) the audiobook hand-off: downloads/audiobooks -> the books drop dir
    # -----------------------------------------------------------------------
    with subtest("audiobooks: a clean entry is promoted, an infected one never is"):
        # Option C (ServerNotes/designs/audiobook-acquisition.md): the media
        # stack acquires audiobooks and MOVES a completed entry into the
        # books stack's drop directory — but only on a clean verdict, and
        # per ENTRY, because an audiobook is a folder of tracks with one
        # verdict. The two directions are asserted together so they share the
        # scanner's settle passes.
        ab = "/mnt/slow/data/downloads/audiobooks"
        drop = "/mnt/slow/books/drop"
        services_vm.succeed(
            f"mkdir -p '{ab}/Clean Book' '{ab}/Infected Book'"
        )
        services_vm.succeed(
            f"printf '%s' 'clean audiobook fixture' > '{ab}/Clean Book/01.mp3'"
        )
        # The infected entry gets a CLEAN track too: quarantining only the
        # infected file would leave this one looking promotable, and that
        # partial promotion is the failure this pins.
        services_vm.succeed(
            f"printf '%s' 'clean track' > '{ab}/Infected Book/01.mp3'"
        )
        services_vm.succeed(
            f"printf '%s' {shlex.quote(e1 + e2)} > '{ab}/Infected Book/02.mp3'"
        )
        # qBittorrent writes as uid 1000; the promotion is a rename, so the
        # ownership must ride along into the drop dir (which is what lets a
        # human reorganise a promoted book without sudo).
        services_vm.succeed(f"chown -R 1000:1000 '{ab}'")
        try:
            # Two passes to settle (identical `du -s`), one to scan and move.
            services_vm.wait_until_succeeds(
                f"test -f '{drop}/Clean Book/01.mp3'", timeout=600
            )
            services_vm.wait_until_succeeds(
                "ls /mnt/slow/data/downloads/.quarantine/ "
                "| grep -q '^Infected Book\\.'",
                timeout=600,
            )
        except Exception:
            diag("audiobook promotion")
            raise
        services_vm.fail(f"test -e '{ab}/Clean Book'")
        services_vm.fail(f"test -e '{ab}/Infected Book'")
        # The infected entry reached the drop dir in NO form — not the entry,
        # not its clean sibling track.
        services_vm.fail(f"test -e '{drop}/Infected Book'")
        listing = sorted(
            l for l in services_vm.succeed(f"ls -1 '{drop}'").splitlines()
            if l.strip()
        )
        assert listing == ["Clean Book"], (
            f"the drop dir holds {listing!r}, expected only the clean entry"
        )
        owner = services_vm.succeed(
            f"stat -c '%u:%g' '{drop}/Clean Book/01.mp3'"
        ).strip()
        assert owner == "1000:1000", (
            f"the promoted audiobook is owned {owner}, expected 1000:1000 — "
            "the books stack reads it as that uid"
        )
        logs = services_vm.succeed("docker logs clamav_scanner 2>&1")
        assert "PROMOTED clean audiobook 'Clean Book'" in logs, (
            f"scanner did not log the promotion:\n{logs}"
        )
        assert "INFECTED audiobook 'Infected Book'" in logs, (
            f"scanner did not log the infected entry's quarantine:\n{logs}"
        )

    with subtest("media-init declared the audiobooks category in qBittorrent"):
        # Nothing *arr-shaped owns this category, so media-init creates it —
        # and its save path is what scan-downloads.sh promotes out of. The
        # tunnel is down for the whole suite and this still has to work: the
        # WebUI answers on the shared netns regardless (FIREWALL_INPUT_PORTS).
        #
        # Read from INSIDE the container, against the shared netns' own
        # loopback: qbit-init sets WebUI\LocalHostAuth=false (it is what lets
        # gluetun's port-forward hook post without credentials), so a local
        # caller needs no session at all. That keeps this assertion about the
        # category rather than about qBittorrent's login shape — which is
        # exactly the thing that bit media-init here: 5.2.3 answers 204 with
        # an empty body on success, so both a body check and a Set-Cookie
        # check are wrong ways to ask "am I logged in".
        cats = json.loads(services_vm.succeed(
            "docker exec qbittorrent curl -sf --max-time 10 "
            "http://localhost:8080/api/v2/torrents/categories"
        ))
        assert "audiobooks" in cats, (
            f"qbittorrent has no audiobooks category: {sorted(cats)!r}"
        )
        # rstrip("/"): qBittorrent normalises stored paths, and a returned
        # trailing separator is a formatting difference, not a wrong path —
        # media-init compares the same way, so that it does not "reconcile"
        # a difference that is not one on every run.
        save = (cats["audiobooks"].get("savePath") or "").rstrip("/")
        assert save == "/data/downloads/audiobooks", (
            f"audiobooks category saves to {save!r}"
        )
        services_vm.succeed("test -d /mnt/slow/data/downloads/audiobooks")
        # And media-init said it did this, on the FIRST run — a category that
        # exists with no CHANGE line behind it would mean something else
        # created it.
        first = services_vm.succeed("docker logs media_init 2>&1")
        assert "CHANGE: qbittorrent: created category 'audiobooks'" in first, (
            f"media-init did not report creating the category:\n{first}"
        )

    with subtest("clamd publishes no host port"):
        ports = services_vm.succeed("docker port clamav").strip()
        assert ports == "", f"clamav publishes ports: {ports!r}"

    # -----------------------------------------------------------------------
    # (f) jellyfin
    # -----------------------------------------------------------------------
    with subtest("jellyfin serves its UI on 10050"):
        services_vm.wait_until_succeeds(
            "curl -sfL --max-time 10 http://127.0.0.1:10050/ -o /dev/null",
            timeout=120,
        )

    with subtest("the guarded GPU stanza exists and degrades in a VM"):
        # Drift guard for annex §8.18: HW transcode is untestable here, but
        # losing the stanza silently would cost the Arc A380 on the real host.
        services_vm.succeed(
            "grep -qF -- '- /dev/dri:/dev/dri' /srv/stacks/media/compose.yaml"
        )
        services_vm.succeed(
            "grep -qF \"c 226:* rmw\" /srv/stacks/media/compose.yaml"
        )
        # And the guard works: no GPU in this VM, container runs anyway with
        # the bind-mounted (possibly empty) /dev/dri present.
        services_vm.succeed("docker exec jellyfin test -d /dev/dri")

    # -----------------------------------------------------------------------
    # (g) loopback-only publishing, from the VLAN
    # -----------------------------------------------------------------------
    with subtest("no media port is reachable from the VLAN"):
        # Positive control: the outsider can resolve and reach the VM at all
        # (22 is in allowedTCPPorts); without it every fail() below would
        # pass identically on a dead vlan.
        outsider.succeed("nc -z -w 5 services-vm 22")
        for port in range(10050, 10059):
            outsider.fail(f"nc -z -w 5 services-vm {port}")

    # -----------------------------------------------------------------------
    # Nothing failed that the suite did not fail on purpose
    # -----------------------------------------------------------------------
    with subtest("no unit is left failed at suite end"):
        # backup-prepare (02:45) and backup-staleness-check (12:00) are
        # wall-clock timers that legitimately fail on this fixture host (no
        # VPS key, no success stamp) if the suite happens to straddle their
        # OnCalendar moment; their failure paths are the services suite's
        # coverage, so a coincidence must not flake this one.
        allowed = {"backup-prepare.service", "backup-staleness-check.service"}

        # unhealthy-containers is the third, and it is EXPECTED here rather
        # than tolerated: gluetun is deliberately unhealthy for this suite's
        # whole duration (the fixture points it at TEST-NET-1), so any tick
        # of its 15-minute timer that lands inside the run alerts — the unit
        # working, not a regression. It became reachable when this suite grew
        # past a quarter-hour.
        #
        # Allowed NARROWLY: the stamp it wrote must name gluetun and nothing
        # else, so a second container going sick still fails this subtest.
        if services_vm.execute("test -e /run/unhealthy-containers.failed")[0] == 0:
            stamp = services_vm.succeed(
                "cat /run/unhealthy-containers.failed"
            ).split()
            assert stamp == ["gluetun"], (
                f"unhealthy-containers alerted on {stamp!r} — only gluetun is "
                "unhealthy by construction here"
            )
            allowed.add("unhealthy-containers.service")

        failed = services_vm.succeed(
            "systemctl --failed --no-legend --plain"
        ).strip()
        rogue = [l for l in failed.splitlines() if l.split()[0] not in allowed]
        assert not rogue, "failed units at suite end:\n" + "\n".join(rogue)
  '';
}
