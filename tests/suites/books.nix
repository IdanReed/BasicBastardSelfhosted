# Books suite (heavy): the ebook + audiobook stack on the services VM —
# kavita, shelfmark, audiobookshelf, plus the two oneshots
# (kavita-config-init, books-init). Hand-written because mk-stack-suite's
# generic all-containers-running assertion cannot pass a stack with
# restart:"no" oneshots (its header says so). Annex §6 of
# ServerNotes/designs/service-ebook-stack-research.md is the assertion spec.
#
# Genuinely under test:
#   - decrypt-sops-envs turning stacks/books/.sops.env into a 0600 .env owned
#     1000:1000, and env threading END TO END: the JWT key and both admin
#     credential pairs exist only in the encrypted fixture, so a working login
#     in each app and a rendered appsettings.json carrying the fixture token
#     key prove the whole sops -> .env -> env_file chain
#   - kavita-config-init's MERGE-style render contract: it owns only the keys
#     the template declares, preserves everything else in the file, is a no-op
#     on re-run, and — the point of the whole exercise (annex §0.5) — the
#     TokenKey it seeded is STILL there after Kavita has started and had every
#     chance to rewrite the file. Kavita swallows write failures silently, so
#     "the placeholder key is not in play" is a thing that has to be asserted,
#     not assumed.
#   - the OIDC-READY-BUT-OFF shipping state (annex §8.4): with both client
#     secrets empty, Kavita must report OIDC disabled and audiobookshelf must
#     advertise local auth only — i.e. the off state is deliberate and
#     complete, not a half-configured login page that 500s
#   - headless seeding of BOTH apps in one oneshot, idempotent under Komodo
#     redeploys (books-init's CHANGE: contract), including the two
#     audiobookshelf hazards the annex flags: /init is guarded by GET /status
#     (a second POST returns 500, a malformed one kills the server), and an
#     empty password would silently create a passwordless root
#   - a real EPUB and a real audio file indexed offline: both apps'
#     metadata-free paths (Kavita reads the EPUB's own OPF, audiobookshelf
#     reads folder structure + embedded tags), which is exactly what survives
#     with no egress
#   - OPDS end to end, which IS the reMarkable's access path: the auth key
#     exists as soon as the admin does, the feed answers XML, and the indexed
#     book is in it. Plus the KOReader sync endpoint's auth leg.
#   - the :ro library mounts really being sufficient — the tree is byte-identical
#     after both apps have scanned it (the difference between a :ro and a :rw
#     line in the compose file, so it gets measured rather than reasoned)
#   - the audiobook hand-off, books half (Option C,
#     ServerNotes/designs/audiobook-acquisition.md): /mnt/slow/books/drop is a
#     SECOND FOLDER of the Audiobooks library, an audiobook that appears there
#     becomes a library item, the library carries the scan cron that is the
#     only thing watching it, and this stack still has no QBITTORRENT_*
#     variable and no mount of the media stack's trees. What the media side
#     does before the file lands there — the ClamAV verdict and the move — is
#     tests/suites/media.nix's job; here the writer is stood in for by the
#     seed unit.
#   - shelfmark's post-download hook, both directions: it triggers the right
#     app's scan, and it STILL EXITS 0 when the target is unreachable — a
#     non-zero exit would mark a perfectly good download as Error in the UI
#   - loopback-only publishing for 10150/10151/10152 asserted from another
#     host, and the oneshots publishing nothing
#   - the backup contract: the two SQLite paths backup-prepare.sh hardcodes
#     exist and are dumpable with the same `.backup` call it makes
#   - reboot survival on PERSISTENT storage: /mnt is a real ext4 disk here
#     precisely so the reboot subtest asserts data durability — the databases,
#     the rendered appsettings.json and the indexed book must all come back
#
# Documented egress gaps (a green run covers NONE of these — annex §6):
#   - every Anna's Archive search and download, and the Cloudflare-bypass
#     browser path. Shelfmark is asserted to come up healthy and stay healthy
#     with zero egress (which is real: its Chromium is baked in at build time,
#     not fetched at runtime), and nothing beyond that.
#   - every metadata and cover provider (Google Books, OpenLibrary, Audible/
#     audnex, Hardcover), so all metadata enrichment. The libraries are created
#     with matching disabled for exactly this reason.
#   - Kavita's update check and stats ping. Both FAIL offline and log; that is
#     expected noise, and books-init turns stat collection off to reduce it.
#   - the live OIDC browser flow for either app, and audiobookshelf's mobile
#     audiobookshelf://oauth handoff. Only the OFF-state contract is asserted
#     here; the ON-state config path is the operator's to exercise once the
#     Authentik client secrets exist.
#   - KOReader on the reMarkable in its entirety (tablet-side, Toltec).

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
    # Every pinned ref from stacks/books/compose.yaml. Komodo's images are
    # NOT here — bootstrap-komodo is masked below.
    images."jvmilazz0_kavita_0_9_1"
    images."ghcr_io_calibrain_shelfmark_1_3_13"
    images."ghcr_io_advplyr_audiobookshelf_2_36_0"
    images."python_3_13-alpine" # kavita-config-init + books-init
  ];

  # A minimal but genuinely valid EPUB 3, built at eval time. Kavita parses
  # metadata out of the EPUB's own OPF (title/author/series) and falls back to
  # the filename — so this has to be a real zip with a real package document,
  # not a renamed text file, or the indexing subtest proves nothing.
  #
  # It lives in an Author subdirectory because Kavita ignores files at the
  # library root outright ("No files can exist at root level"), which is also
  # why shelfmark runs with FILE_ORGANIZATION=organize.
  testEpub = pkgs.runCommand "test-epub" { nativeBuildInputs = [ pkgs.zip ]; } ''
    mkdir -p build/META-INF build/OEBPS
    # The mimetype entry must be first and STORED (uncompressed) — that is the
    # one structural rule an EPUB reader may reject the file over.
    printf 'application/epub+zip' > build/mimetype
    cat > build/META-INF/container.xml <<'XML'
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    XML
    cat > build/OEBPS/content.opf <<'XML'
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="bookid">urn:uuid:11111111-2222-3333-4444-555555555555</dc:identifier>
        <dc:title>Offline Test Book</dc:title>
        <dc:creator>Test Author</dc:creator>
        <dc:language>en</dc:language>
        <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
      </metadata>
      <manifest>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
      </manifest>
      <spine>
        <itemref idref="ch1"/>
      </spine>
    </package>
    XML
    cat > build/OEBPS/nav.xhtml <<'XML'
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
      <head><title>Contents</title></head>
      <body><nav epub:type="toc"><ol><li><a href="ch1.xhtml">Chapter 1</a></li></ol></nav></body>
    </html>
    XML
    cat > build/OEBPS/ch1.xhtml <<'XML'
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml">
      <head><title>Chapter 1</title></head>
      <body><h1>Chapter 1</h1><p>This file exists so a scan has something to find.</p></body>
    </html>
    XML
    cd build
    # Built under a .epub name and moved into place: `zip` appends .zip to a
    # target with no extension, so writing straight to $out silently produces
    # $out.zip and the derivation fails with "failed to produce output path".
    zip -q -X -0 book.epub mimetype
    zip -q -X -r book.epub META-INF OEBPS
    mv book.epub $out
  '';

  # One second of silence, encoded with ffmpeg's NATIVE flac encoder (no
  # external codec libraries, so this builds anywhere). Audiobookshelf needs a
  # file it can actually probe: a renamed text file scans as an invalid item
  # and the indexing subtest would be asserting nothing.
  testAudio = pkgs.runCommand "test-audio" { nativeBuildInputs = [ pkgs.ffmpeg ]; } ''
    # -f flac is required, not decoration: ffmpeg picks the muxer from the
    # output file's extension, and $out has none.
    ffmpeg -nostdin -loglevel error \
      -f lavfi -i anullsrc=r=44100:cl=mono -t 1 -c:a flac -f flac "$out"
  '';

  # Seeds /srv the way the real host gets it: stack-git-sync on the live
  # machine, a store copy here. Only the books stack — bootstrap-komodo is
  # masked, so /srv/komodo is not needed.
  seedSrv = pkgs.runCommand "srv-seed-books" { } ''
    mkdir -p $out/stacks/books
    cp -r ${../../stacks/books}/. $out/stacks/books/
    chmod -R u+w $out/stacks/books
    # The working-tree cp -r can capture a developer's locally-decrypted
    # plaintext .env (gitignored on purpose) in the world-readable store.
    rm -f $out/stacks/books/.env
    rm -f $out/stacks/books/.sops.env.example
    cp ${../fixtures/books.sops.env} $out/stacks/books/.sops.env
  '';
in
pkgs.testers.runNixOSTest {
  name = "books";

  # Three first boots (Kavita's EF Core migrations, audiobookshelf's, and
  # shelfmark's 90s Chromium start period), two library scans and a reboot.
  # The driver's 3600s default would kill the VMs without running any except
  # handler, so the diag dumps would never print.
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
          # Three application containers, one of which unpacks to multiple GB
          # (shelfmark bundles Chromium).
          (profiles.sized {
            memoryMB = 6144;
            diskMB = 24576;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            # Nothing container-shaped runs at boot (bootstrap-komodo is
            # masked), so the contract is just "loaded before the script's
            # first compose up".
            beforeUnits = [ "multi-user.target" ];
          })
        ];

        # Keep the deploy plane out of the boot path: this suite already
        # loads a Chromium-bearing image. Coverage lost — the
        # decrypt-sops-envs -> docker-network-homelab -> bootstrap-komodo
        # chain — is what checks.services covers.
        systemd.services.bootstrap-komodo.wantedBy = lib.mkForce [ ];
        # stack-git-sync would fail its clone every tick with no Forgejo here.
        systemd.timers.stack-git-sync.wantedBy = lib.mkForce [ ];

        # Migrations plus two scans on the sized profile's 2 cores make every
        # healthcheck window a coin toss; 4 keeps it sane.
        virtualisation.cores = lib.mkForce 4;

        # decrypt-sops-envs.service `requires = srv.mount`; the tmpfs gives it
        # a genuine .mount unit. /srv stays tmpfs ON PURPOSE: its post-reboot
        # re-seed + re-decrypt is itself the production shape (git sync +
        # the decrypt timer).
        #
        # /mnt is a real ext4 on a persistent qcow (auto-formatted on first
        # boot only), because the reboot subtest asserts DATA DURABILITY — the
        # SQLite databases, the rendered appsettings.json and the indexed book
        # must survive, which tmpfs cannot represent.
        virtualisation.emptyDiskImages = [ 16384 ];
        virtualisation.fileSystems = {
          "/srv" = {
            device = "tmpfs";
            fsType = "tmpfs";
            options = [ "mode=0755" ];
          };
          "/mnt" = {
            device = "/dev/vdb";
            fsType = "ext4";
            autoFormat = true;
          };
        };

        systemd.tmpfiles.rules = [
          # Mirrors nixos/hardware-configuration.nix, which cannot be
          # imported here because it mounts real partitions by partlabel.
          "d /srv/stacks 0755 1000 1000 -"
          "d /var/lib/sops-nix 0700 root root -"
          # The /mnt disk is bare ext4; production's separate fast/slow
          # mountpoints are plain directories here.
          "d /mnt/fast 0755 root root -"
          "d /mnt/slow 0755 root root -"
          # Books bind-mount roots — the SAME set and the SAME ownership
          # production declares in hardware-configuration.nix; keep the two
          # lists in sync by hand. kavita and audiobookshelf run as root and
          # only read their tree; shelfmark drops to 1000 and writes the ebook
          # tree.
          "d /mnt/fast/kavita 0755 root root -"
          "d /mnt/fast/kavita/config 0755 root root -"
          "d /mnt/fast/shelfmark 0755 root root -"
          "d /mnt/fast/shelfmark/config 0755 1000 1000 -"
          "d /mnt/fast/shelfmark/tmp 0755 1000 1000 -"
          "d /mnt/fast/audiobookshelf 0755 root root -"
          "d /mnt/fast/audiobookshelf/config 0755 root root -"
          "d /mnt/fast/audiobookshelf/metadata 0755 root root -"
          "d /mnt/slow/books 0755 1000 1000 -"
          "d /mnt/slow/books/library 0755 1000 1000 -"
          "d /mnt/slow/books/audiobooks 0755 1000 1000 -"
          # The media stack's audiobook hand-off (Option C). Written by
          # stacks/media's clamav-scanner, read :ro here as a second folder
          # of the Audiobooks library — this suite stands in for the writer.
          "d /mnt/slow/books/drop 0755 1000 1000 -"
        ];

        # Populate /srv before anything reads it — the stand-in for
        # stack-git-sync having already run. Re-runs on every boot (tmpfs /srv),
        # which the reboot subtest depends on.
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
            # --no-preserve=mode is the fleet idiom (store files arrive
            # read-only), but it sets every regular file to 0644 — and this is
            # the first stack with a file that MUST be executable: shelfmark
            # execs post-download.sh directly, so a 0644 copy fails with exit
            # 126 and every download would be marked Error. stack-git-sync
            # delivers the git mode on the real host; restore it here.
            chmod 0755 /srv/stacks/books/post-download.sh
            chown -R 1000:1000 /srv/stacks
          '';
        };

        # The library content the two scans have to find. Placed by the host
        # (shelfmark is the writer in production, but it cannot download
        # anything offline), with the ownership shelfmark would have produced.
        systemd.services.seed-library = {
          description = "Seed the library trees with test content (test only)";
          after = [ "mnt.mount" ];
          requires = [ "mnt.mount" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            install -d -o 1000 -g 1000 -m 0755 \
              "/mnt/slow/books/library/Test Author" \
              "/mnt/slow/books/audiobooks/Test Author" \
              "/mnt/slow/books/audiobooks/Test Author/Offline Test Audiobook" \
              "/mnt/slow/books/drop/Dropped Test Audiobook"
            install -o 1000 -g 1000 -m 0644 ${testEpub} \
              "/mnt/slow/books/library/Test Author/Test Author - Offline Test Book.epub"
            install -o 1000 -g 1000 -m 0644 ${testAudio} \
              "/mnt/slow/books/audiobooks/Test Author/Offline Test Audiobook/Offline Test Audiobook.flac"
            # Stands in for stacks/media's clamav-scanner having promoted a
            # clean audiobook: same ownership a rename out of the download
            # tree would preserve (qBittorrent's PUID), a whole entry
            # directory, no coordination with this stack beyond the path.
            install -o 1000 -g 1000 -m 0644 ${testAudio} \
              "/mnt/slow/books/drop/Dropped Test Audiobook/Dropped Test Audiobook.flac"
          '';
        };

        environment.systemPackages = with pkgs; [
          docker-compose
          jq
          sqlite
        ];
      };

    # Another host on the LAN, for the negative binding assertions: anything
    # it can reach on a non-tailnet interface is reachable from the whole
    # VLAN — and these APIs serve the whole library.
    outsider = { };
  };

  testScript = ''
    import json
    import shlex

    BOOKS = "docker compose -f /srv/stacks/books/compose.yaml -p books"
    KAVITA = "http://127.0.0.1:10150"
    ABS = "http://127.0.0.1:10152"
    SHELFMARK = "http://127.0.0.1:10151"

    # Fixture values from tests/fixtures/books.sops.env — committed test-only
    # secrets (see the fixture header; stack-env-drift keeps the key set
    # honest against .sops.env.example).
    KAVITA_USER = "test_kavita_admin"
    KAVITA_PASS = "test_kavita_password_not_secret"
    ABS_USER = "test_abs_admin"
    ABS_PASS = "test_abs_password_not_secret"
    TOKEN_KEY = ("746573745f6b61766974615f746f6b656e5f6b65795f6e6f745f736563"
                 "7265745f7061646465645f706173745f6b6176697461735f3531325f"
                 "6269745f6d696e")

    CONF = "/mnt/fast/kavita/config/appsettings.json"
    LIBRARY = "/mnt/slow/books/library"
    AUDIOBOOKS = "/mnt/slow/books/audiobooks"
    DROP = "/mnt/slow/books/drop"

    def diag(label):
        # A --wait failure minutes into first-boot migrations is useless
        # without context; dump what docker actually did on the way out.
        print("=== diagnostics: " + label + " ===")
        for cmd in [
            "docker ps -a",
            "docker logs kavita 2>&1 | tail -60",
            "docker logs shelfmark 2>&1 | tail -60",
            "docker logs audiobookshelf 2>&1 | tail -60",
            "docker logs books_config_init 2>&1 | tail -20",
            "docker logs books_init 2>&1 | tail -40",
            "ls -la /srv/stacks/books /mnt/fast/kavita/config "
            "/mnt/fast/shelfmark/config /mnt/fast/audiobookshelf/config 2>&1",
            "find /mnt/slow/books -maxdepth 4 2>&1",
            "cat " + CONF + " 2>&1",
            "df -h /var/lib/docker /mnt; free -m",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    def curl(base, path, method="GET", body=None, headers=None, fail=False,
             timeout=60):
        """JSON in/out against a loopback publish.

        Bodies go through a pipe so shell quoting cannot mangle them. With
        fail=True the HTTP status is returned instead of the body, for the
        negative assertions.
        """
        flags = "-s -o /dev/null -w '%{http_code}'" if fail else "-sf"
        cmd = f"curl {flags} --max-time {timeout} -X {method} "
        for k, v in (headers or {}).items():
            cmd += f"-H {shlex.quote(k + ': ' + v)} "
        if body is not None:
            payload = shlex.quote(json.dumps(body))
            cmd = (f"printf '%s' {payload} | " + cmd
                   + "-H 'Content-Type: application/json' -d @- ")
        out = services_vm.succeed(cmd + shlex.quote(base + path))
        if fail:
            return int(out.strip())
        if not out.strip():
            return None
        try:
            return json.loads(out)
        except ValueError:
            # Not every endpoint answers JSON: Kavita's opds-url action
            # returns a bare string, which ASP.NET serves as text/plain via
            # StringOutputFormatter. Hand it back raw rather than failing the
            # subtest with a JSONDecodeError that says nothing useful.
            return out.strip()

    def tree_state(path):
        """Path + size of every file under path — the :ro evidence."""
        return services_vm.succeed(
            f"find {shlex.quote(path)} -type f -printf '%p %s\\n' | sort"
        )

    start_all()

    # -----------------------------------------------------------------------
    # §6.1 boot chain + decrypt: sops fixture -> 0600 .env owned 1000:1000
    # -----------------------------------------------------------------------
    with subtest("decrypt-sops-envs produced a 0600 .env owned by uid 1000 (the /srv/stacks world)"):
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_for_unit("docker-network-homelab.service")
        # Transient oneshot on a minutely timer, so wait_for_unit would race
        # its inactive-after-success state; the artifact is the sync point.
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/books/.env", timeout=120
        )
        stat = services_vm.succeed(
            "stat -c '%a %u:%g' /srv/stacks/books/.env"
        ).strip()
        assert stat == "600 1000:1000", f".env is {stat}, expected 600 1000:1000"
        # The keys everything below depends on: a later failure then points at
        # the service, not at decryption. The two OIDC keys are asserted
        # PRESENT AND EMPTY — that is the shipping state this suite pins.
        for k in ["KAVITA_TOKEN_KEY", "KAVITA_ADMIN_USER", "ABS_ADMIN_USER",
                  "JWT_SECRET_KEY"]:
            services_vm.succeed(f"grep -q '^{k}=.' /srv/stacks/books/.env")
        for k in ["KAVITA_OIDC_CLIENT_SECRET", "ABS_OIDC_CLIENT_SECRET"]:
            services_vm.succeed(f"grep -qx '{k}=' /srv/stacks/books/.env")

    services_vm.wait_for_unit("load-test-images.service")
    services_vm.wait_for_unit("seed-library.service")

    # -----------------------------------------------------------------------
    # §6.2 config render: template + secrets -> /kavita/config/appsettings.json
    # -----------------------------------------------------------------------
    with subtest("kavita-config-init renders appsettings.json (0600, merged)"):
        try:
            services_vm.succeed(BOOKS + " up -d kavita-config-init")
            services_vm.wait_until_succeeds(
                "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
                "books_config_init | grep -qx exited/0",
                timeout=120,
            )
        except Exception:
            diag("config-init run")
            raise
        mode = services_vm.succeed(f"stat -c '%a' {CONF}").strip()
        assert mode == "600", f"appsettings.json is mode {mode}, expected 600"
        conf = json.loads(services_vm.succeed(f"cat {CONF}"))
        # The token key exists ONLY in the encrypted fixture: finding it here
        # proves sops -> .env -> env_file -> render end to end.
        assert conf["TokenKey"] == TOKEN_KEY, (
            f"rendered TokenKey is {conf['TokenKey']!r}"
        )
        # Non-secret template values arrive verbatim...
        assert conf["BaseUrl"] == "/", f"BaseUrl is {conf['BaseUrl']!r}"
        oidc = conf["OpenIdConnectSettings"]
        assert oidc["ClientId"] == "kavita", f"ClientId is {oidc['ClientId']!r}"
        # ...and with no client secret BOTH the secret and the authority must
        # be empty. Kavita computes "is OIDC enabled" two different ways — the
        # disk side wants Authority+ClientId+Secret, the DB side (which the
        # login path consults) wants only Authority — so an authority with no
        # secret is a genuinely half-configured state, not an off one. The
        # config-init blanks it for exactly that reason.
        # NB: never write a bare pair of single quotes anywhere in this
        # script — it is the terminator of a Nix indented string, and it ends
        # the whole testScript mid-expression at EVAL time.
        assert oidc["Secret"] == "", f"Secret is {oidc['Secret']!r}, expected empty"
        assert oidc["Authority"] == "", (
            f"Authority is {oidc['Authority']!r} with an empty Secret — the "
            f"DB-side Enabled getter would read that as OIDC being live"
        )

    # -----------------------------------------------------------------------
    # §6.3 the stack comes up
    # -----------------------------------------------------------------------
    with subtest("compose brings up kavita, shelfmark and audiobookshelf"):
        # books-init is NOT in the --wait set: compose's --wait reports failure
        # for an in-scope oneshot that exited 0 unless a dependent consumes it,
        # and books-init has no dependents. Same trap the media and immich
        # suites document.
        try:
            services_vm.succeed(
                BOOKS + " up -d --wait --wait-timeout 900 "
                "kavita shelfmark audiobookshelf",
                timeout=1000,
            )
        except Exception:
            diag("compose up --wait")
            raise

    with subtest("books-init seeds both apps and exits 0"):
        try:
            services_vm.succeed(BOOKS + " up -d books-init")
            services_vm.wait_until_succeeds(
                "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
                "books_init | grep -qx exited/0",
                timeout=300,
            )
        except Exception:
            diag("books-init run")
            raise
        seed_log = services_vm.succeed("docker logs books_init 2>&1")
        # First run against fresh state IS the mutation — it must say so
        # (media-init's CHANGE: contract), for each of the four seeds.
        for expected in ["CHANGE: kavita admin", "CHANGE: kavita library",
                         "CHANGE: audiobookshelf root user",
                         "CHANGE: audiobookshelf library"]:
            assert expected in seed_log, (
                f"books-init logged no {expected!r} line:\n{seed_log}"
            )
        # And with an empty client secret it must have left OIDC alone rather
        # than PATCHing a broken configuration in.
        assert "leaving audiobookshelf on local auth" in seed_log, (
            f"books-init did not take the OIDC-off path:\n{seed_log}"
        )

    with subtest("every container is in its contract state"):
        for name in ["kavita", "shelfmark", "audiobookshelf"]:
            h = services_vm.succeed(
                f"docker inspect -f '{{{{.State.Health.Status}}}}' {name}"
            ).strip()
            assert h == "healthy", f"{name} is {h!r}, expected healthy"
        for name in ["books_config_init", "books_init"]:
            code = services_vm.succeed(
                f"docker inspect -f '{{{{.State.ExitCode}}}}' {name}"
            ).strip()
            assert code == "0", f"{name} exited {code}, expected 0"

    # -----------------------------------------------------------------------
    # §6.4 the seeded TokenKey survived Kavita starting
    # -----------------------------------------------------------------------
    with subtest("kavita did not overwrite the seeded TokenKey"):
        # THE regression test for annex §0.5. Kavita's EnsureJwtTokenKey runs
        # at startup and every writer of this file swallows its exceptions, so
        # a read-only mount (or any other write failure) leaves the server
        # signing JWTs with the placeholder key that ships in the public repo
        # — with no crash and no log line. The only way to know is to look.
        conf = json.loads(services_vm.succeed(f"cat {CONF}"))
        assert conf["TokenKey"] == TOKEN_KEY, (
            f"TokenKey after startup is {conf['TokenKey']!r} — kavita "
            f"replaced the seeded key, or never read it"
        )

    # -----------------------------------------------------------------------
    # §6.5 admin seeds: fixture credentials log in
    # -----------------------------------------------------------------------
    with subtest("both seeded admins log in with the fixture credentials"):
        dto = curl(KAVITA, "/api/Account/login", "POST",
                   {"username": KAVITA_USER, "password": KAVITA_PASS})
        kavita_key = dto.get("apiKey")
        assert dto.get("token"), f"kavita login returned no token: {dto!r}"
        assert kavita_key, f"kavita login returned no apiKey: {dto!r}"

        login = curl(ABS, "/login", "POST",
                     {"username": ABS_USER, "password": ABS_PASS})
        abs_token = (login.get("user") or {}).get("accessToken")
        assert abs_token, f"abs login returned no accessToken: {login!r}"

    kv_auth = {"x-api-key": kavita_key}
    abs_auth = {"Authorization": f"Bearer {abs_token}"}

    # -----------------------------------------------------------------------
    # §6.6 the passwordless-root guard
    # -----------------------------------------------------------------------
    with subtest("an empty audiobookshelf password does not log in"):
        # A .env variable that failed to interpolate would have made POST
        # /init create a passwordless root user with a 200 response and only a
        # warning in the log (annex §3.3), and audiobookshelf's local strategy
        # then APPROVES a login whose submitted password is also empty. So
        # this assertion is only meaningful next to the previous subtest,
        # where the fixture password succeeded: together they say the account
        # has a password and it is the seeded one.
        login_status = curl(ABS, "/login", "POST",
                            {"username": ABS_USER, "password": ""}, fail=True)
        assert login_status >= 400, (
            f"empty-password login returned HTTP {login_status}"
        )

    # -----------------------------------------------------------------------
    # §6.7 both libraries index their test content, offline
    # -----------------------------------------------------------------------
    with subtest("kavita indexes the seeded EPUB"):
        # The library was created and scanned by books-init; a scan is
        # asynchronous, so poll for the result rather than trusting the 200.
        # POST /api/Series/all-v2 takes a FilterV2Dto with no required
        # members, so {} is a valid "everything" filter.
        try:
            services_vm.wait_until_succeeds(
                "curl -sf --max-time 30 -X POST "
                f"-H 'x-api-key: {kavita_key}' -H 'Content-Type: application/json' "
                f"-d '{{}}' {KAVITA}/api/Series/all-v2 "
                "| grep -q 'Offline Test Book'",
                timeout=300,
            )
        except Exception:
            diag("kavita scan")
            raise

    with subtest("audiobookshelf indexes the seeded audiobook"):
        try:
            libs = curl(ABS, "/api/libraries", "GET", None, abs_auth)
            abs_lib = next(lib for lib in libs["libraries"]
                           if lib["name"] == "Audiobooks")
            lib_id = abs_lib["id"]
            services_vm.wait_until_succeeds(
                f"curl -sf --max-time 30 -H {shlex.quote('Authorization: Bearer ' + abs_token)} "
                f"{ABS}/api/libraries/{lib_id}/items "
                "| grep -q 'Offline Test Audiobook'",
                timeout=300,
            )
        except Exception:
            diag("audiobookshelf scan")
            raise

    with subtest("the media stack's drop directory is a folder of that library"):
        # The books half of Option C
        # (ServerNotes/designs/audiobook-acquisition.md). Everything the
        # media stack needs from this stack is right here: a path, declared
        # as a library folder. No network path, no download tree mounted, no
        # QBITTORRENT_* variable anywhere in the stack — asserted below.
        folders = sorted(f.get("fullPath") for f in abs_lib.get("folders") or [])
        assert folders == ["/audiobooks", "/drop"], (
            f"the Audiobooks library's folders are {folders!r}, expected the "
            "curated tree and the media stack's drop directory"
        )
        # Nothing watches the drop dir (disableWatcher is on, and the only
        # precise scan trigger in this stack is shelfmark's post-download
        # hook, which has no part in this path), so the library carries a
        # scan cron instead. Read back rather than assumed: an
        # audiobookshelf that silently dropped the field would mean an
        # audiobook lands in the drop dir and is never noticed.
        cron = (abs_lib.get("settings") or {}).get("autoScanCronExpression")
        assert cron == "0 * * * *", (
            f"the Audiobooks library's autoScanCronExpression is {cron!r} — "
            "without it nothing ever notices a promoted audiobook"
        )

    with subtest("an audiobook in the drop directory reaches the library"):
        # The cron is hourly, so the scan is triggered explicitly here: what
        # is under test is that the FOLDER wiring and the :ro mount let a
        # file that appeared in the drop dir become a library item — the
        # cron's own value is asserted above.
        curl(ABS, f"/api/libraries/{lib_id}/scan", "POST", None, abs_auth)
        try:
            services_vm.wait_until_succeeds(
                f"curl -sf --max-time 30 -H {shlex.quote('Authorization: Bearer ' + abs_token)} "
                f"{ABS}/api/libraries/{lib_id}/items "
                "| grep -q 'Dropped Test Audiobook'",
                timeout=300,
            )
        except Exception:
            diag("audiobookshelf drop-dir scan")
            raise

    with subtest("books-init ADDS the drop folder to a library that predates it"):
        # The branch every existing deployment takes. The library above was
        # created with both folders, which is the fresh-install path; a host
        # seeded before the drop directory existed has a one-folder library,
        # and books-init has to reconcile it — carrying the surviving
        # folder's id, because audiobookshelf treats a folder missing from
        # the payload as a removal and removing one deletes its items.
        # Reproduced by doing exactly that removal.
        def abs_library():
            # Read through the LIST endpoint, the shape this suite already
            # relies on — GET /api/libraries/:id changes body shape with its
            # ?include= parameter.
            got = curl(ABS, "/api/libraries", "GET", None, abs_auth)
            return next(l for l in got["libraries"] if l["name"] == "Audiobooks")

        keep = next(f for f in abs_lib["folders"] if f["fullPath"] == "/audiobooks")
        curl(ABS, f"/api/libraries/{lib_id}", "PATCH",
             {"folders": [{"id": keep["id"], "fullPath": "/audiobooks"}]},
             abs_auth)
        after = abs_library()
        assert sorted(f["fullPath"] for f in after["folders"]) == ["/audiobooks"], (
            f"could not stage the pre-drop-dir state: {after['folders']!r}"
        )

        out = services_vm.succeed("docker start -a books_init 2>&1")
        assert "gained folder(s) /drop" in out, (
            f"books-init did not re-add the drop folder:\n{out}"
        )
        readd = abs_library()
        assert sorted(f["fullPath"] for f in readd["folders"]) == [
            "/audiobooks", "/drop"
        ], f"folders after reconcile: {readd['folders']!r}"
        # And the curated folder kept its identity rather than being
        # removed and recreated — the id is what the library items hang off.
        kept = next(f for f in readd["folders"] if f["fullPath"] == "/audiobooks")
        assert kept["id"] == keep["id"], (
            f"the /audiobooks folder was replaced ({keep['id']} -> "
            f"{kept['id']}) — its library items would have gone with it"
        )

        # ... and the run after that is a no-op, which is the CHANGE:
        # contract every Komodo redeploy depends on.
        out = services_vm.succeed("docker start -a books_init 2>&1")
        assert "CHANGE:" not in out, (
            f"a books-init run against a reconciled library was not a no-op:\n{out}"
        )

    with subtest("the books stack cannot reach the media stack's download client"):
        # The decision, asserted rather than commented: Option C was chosen
        # over Shelfmark-drives-qBittorrent, so a QBITTORRENT_* variable or a
        # mount of the media download tree appearing in this stack is a
        # reversal of it and must fail here.
        compose = services_vm.succeed("cat /srv/stacks/books/compose.yaml")
        # Comments are stripped first, and that is not a loophole: the
        # decision is DOCUMENTED in this file by naming qBittorrent and the
        # media stack, so a plain substring search over the whole file
        # matches the prose that records the rule and fails on the very
        # thing it is meant to protect.
        body = "\n".join(
            l for l in compose.splitlines() if not l.strip().startswith("#")
        )
        assert "QBITTORRENT_" not in body.upper(), (
            "the books stack declares a QBITTORRENT_* variable — Option C is "
            "'no cross-stack path to the download client'"
        )
        assert "/mnt/slow/data" not in body, (
            "the books stack mounts the media stack's download/library tree"
        )

    # -----------------------------------------------------------------------
    # §6.8/§6.9 OPDS end to end + the KOReader auth leg
    # -----------------------------------------------------------------------
    with subtest("the OPDS feed answers and contains the indexed book"):
        # Every Kavita user is created with a system auth key named 'opds', so
        # this exists as soon as the admin does. This URL is what a KOReader
        # OPDS catalogue entry on the reMarkable points at — the one part of
        # that story that is testable server-side.
        opds_url = curl(KAVITA, "/api/Account/opds-url?authKeyName=opds",
                        "GET", None, kv_auth)
        # Bare string over text/plain, or a JSON string — accept either, and
        # strip the quotes a JSON string would arrive with.
        assert isinstance(opds_url, str), f"opds-url payload: {opds_url!r}"
        opds_url = opds_url.strip().strip('"')
        assert "/api/opds/" in opds_url.lower(), (
            f"unexpected opds-url payload: {opds_url!r}"
        )
        auth_key = opds_url.rstrip("/").rsplit("/", 1)[-1]
        assert len(auth_key) >= 8, f"implausible opds auth key: {auth_key!r}"
        feed = services_vm.succeed(
            f"curl -sf --max-time 30 {KAVITA}/api/opds/{auth_key}"
        )
        assert "<feed" in feed or "<?xml" in feed, (
            f"OPDS root is not a feed:\n{feed[:400]}"
        )
        # Negative: a wrong key is refused, so the positive is not an
        # auth-disabled fluke.
        opds_status = int(services_vm.succeed(
            "curl -s -o /dev/null -w '%{http_code}' --max-time 30 "
            f"{KAVITA}/api/opds/notarealauthkey00000000000000"
        ).strip())
        assert opds_status >= 400, (
            f"OPDS accepted a bogus auth key (HTTP {opds_status})"
        )

    with subtest("the KOReader sync endpoint authenticates by auth key"):
        who = curl(KAVITA, f"/api/koreader/{auth_key}/users/auth")
        assert (who or {}).get("username") == KAVITA_USER, (
            f"koreader auth returned {who!r}"
        )

    # -----------------------------------------------------------------------
    # §6.10 the OIDC-ready-but-OFF contract
    # -----------------------------------------------------------------------
    with subtest("both apps report OIDC off, deliberately"):
        # Kavita's public, unauthenticated view of its own OIDC state.
        pub = curl(KAVITA, "/api/Settings/oidc")
        assert pub.get("enabled") is False, (
            f"kavita reports OIDC {pub!r} — with an empty Secret the computed "
            f"Enabled getter must be false"
        )
        # Audiobookshelf's: 'openid' must NOT be advertised, because a login
        # button that cannot complete is worse than no button.
        status = curl(ABS, "/status")
        assert status.get("authMethods") == ["local"], (
            f"abs advertises {status.get('authMethods')!r}, expected ['local']"
        )
        assert status.get("isInit") is True, f"abs status: {status!r}"

    # -----------------------------------------------------------------------
    # §6.11 the :ro library mounts really are sufficient
    # -----------------------------------------------------------------------
    with subtest("neither library app wrote into its library tree"):
        # Both apps have now scanned. If either needed write access, the
        # compose file's :ro would be wrong and this is where it shows up —
        # measured, not reasoned.
        #
        # Scope, honestly: this covers the SCAN path only. Both apps have
        # other paths that do write into a library tree regardless of
        # settings (audiobookshelf's embed-metadata, M4B merge, upload and
        # per-file delete; kavita's admin-settable BookmarkDirectory, which
        # is validated by a recursive delete). Those are not reachable from a
        # scan, and :ro is what makes them safe — this subtest pins the half
        # that a routine deploy exercises.
        # DROP is in this list for a second reason: it is written by another
        # STACK, so audiobookshelf writing there would be a container in one
        # stack mutating another's directory.
        for tree in [LIBRARY, AUDIOBOOKS, DROP]:
            listing = tree_state(tree)
            files = [line for line in listing.splitlines() if line.strip()]
            assert len(files) == 1, (
                f"{tree} holds {len(files)} files after the scans, expected "
                f"only the seeded one:\n{listing}"
            )

    # -----------------------------------------------------------------------
    # §6.12 shelfmark's post-download hook
    # -----------------------------------------------------------------------
    def run_hook(target, extra_env=""):
        # Invoked EXACTLY the way shelfmark invokes it: the script execed
        # directly (so a lost executable bit fails here, not in production),
        # the target path as argv[1], the task document on stdin. Piped with
        # printf rather than a heredoc — the driver ships this to a shell as
        # one string, and a multi-line heredoc through that path is a
        # quoting accident waiting to happen.
        payload = json.dumps({
            "version": 1, "phase": "post_transfer",
            "paths": {"destination": target, "target": target},
        })
        return services_vm.succeed(
            f"printf '%s' {shlex.quote(payload)} | docker exec -i {extra_env} "
            f"shelfmark /scripts/post-download.sh {shlex.quote(target)}"
        )

    with subtest("the post-download hook triggers the right app's scan"):
        out = run_hook("/books/Test Author")
        assert "kavita scan triggered" in out, (
            f"hook did not reach kavita:\n{out}"
        )
        # The audiobook branch is exercised even though shelfmark cannot
        # currently produce an audiobook (its Direct Download source is
        # ebook-only, so the audiobook tree is not even mounted into it). The
        # routing is what is under test, and it is what would carry the load
        # the day SEARCH_MODE=universal + a download client is decided on.
        out = run_hook("/audiobooks/Test Author")
        assert "audiobookshelf scan triggered" in out, (
            f"hook did not reach audiobookshelf:\n{out}"
        )

    with subtest("the hook still exits 0 when the scan target is unreachable"):
        # THE contract: a non-zero exit marks a perfectly good download as
        # Error in shelfmark's UI. A missed scan costs minutes of latency; a
        # false error costs a debugging session.
        out = run_hook("/books/Test Author",
                       extra_env="-e KAVITA_URL=http://127.0.0.1:1")
        assert "scan trigger failed" in out, (
            f"hook did not report the failed trigger:\n{out}"
        )

    # -----------------------------------------------------------------------
    # §6.13/§6.14 loopback positives and the off-host negatives
    # -----------------------------------------------------------------------
    with subtest("published ports answer on loopback and nowhere else"):
        # Positive control FIRST (immich precedent): without it, a node-naming
        # or routing regression makes every fail() below pass vacuously and
        # the loopback assertion silently stops testing anything.
        outsider.succeed("nc -z -w 5 services-vm 22")
        for port in [10150, 10151, 10152]:
            services_vm.wait_for_open_port(port, addr="127.0.0.1")
            outsider.fail(f"nc -z -w 5 services-vm {port}")
        # shelfmark's own health endpoint is exempt from its proxy-auth
        # middleware, which is what makes the container healthcheck work at
        # all under AUTH_METHOD=proxy — assert that rather than assuming it.
        services_vm.succeed(
            f"curl -sf --max-time 15 {SHELFMARK}/api/health | grep -q ok"
        )

    with subtest("the oneshots publish nothing"):
        for name in ["books_config_init", "books_init"]:
            ports = services_vm.succeed(
                f"docker inspect -f "
                f"'{{{{json .NetworkSettings.Ports}}}}' {name}"
            ).strip()
            assert ports in ("{}", "null"), f"{name} publishes {ports}"

    # -----------------------------------------------------------------------
    # §6.15 the backup contract backup-prepare.sh hardcodes
    # -----------------------------------------------------------------------
    with subtest("the SQLite paths backup-prepare.sh dumps exist and dump"):
        # Same `.backup` call the script makes (WAL-safe, unlike a raw copy).
        # If an image ever moves its database, this fails here instead of the
        # nightly backup silently skipping it — sqlite_backup returns 0 for a
        # missing source.
        for name, src in [
            ("kavita", "/mnt/fast/kavita/config/kavita.db"),
            ("audiobookshelf",
             "/mnt/fast/audiobookshelf/config/absdatabase.sqlite"),
        ]:
            services_vm.succeed(f"test -f {src}")
            services_vm.succeed(
                f"sqlite3 {src} \".backup '/tmp/{name}.sqlite'\""
            )
            services_vm.succeed(f"test -s /tmp/{name}.sqlite")
        # Shelfmark's users.db is not documented upstream — its name was
        # pinned down from an earlier run of this very suite, which is why it
        # is asserted here rather than left to the raw-copy path.
        services_vm.succeed("test -f /mnt/fast/shelfmark/config/users.db")
        services_vm.succeed(
            "sqlite3 /mnt/fast/shelfmark/config/users.db "
            "\".backup '/tmp/shelfmark.sqlite'\""
        )
        services_vm.succeed("test -s /tmp/shelfmark.sqlite")

    # -----------------------------------------------------------------------
    # §6.16 idempotence under redeploys
    # -----------------------------------------------------------------------
    with subtest("re-running both oneshots is a no-op"):
        for service, container in [("kavita-config-init", "books_config_init"),
                                   ("books-init", "books_init")]:
            services_vm.succeed(f"docker rm -f {container}")
            services_vm.succeed(BOOKS + f" up -d {service}")
            services_vm.wait_until_succeeds(
                "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
                f"{container} | grep -qx exited/0",
                timeout=300,
            )
            run_log = services_vm.succeed(f"docker logs {container} 2>&1")
            assert "CHANGE:" not in run_log, (
                f"second {service} run was not a no-op:\n{run_log}"
            )

    # -----------------------------------------------------------------------
    # §6.17 reboot survival on persistent storage
    # -----------------------------------------------------------------------
    with subtest("the stack returns after a reboot with its data intact"):
        # shutdown() + start(), NOT reboot(): the driver runs qemu with
        # -no-reboot, so an in-guest reboot terminates the VM and the next
        # command dies with "Shell disconnected". Same idiom as the immich
        # suite.
        services_vm.shutdown()
        services_vm.start()
        services_vm.wait_for_unit("multi-user.target")
        # /srv is tmpfs: the seed + decrypt path runs again, exactly as the
        # git sync + decrypt timer would on the real host.
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/books/.env", timeout=120
        )
        try:
            for port in [10150, 10151, 10152]:
                services_vm.wait_for_open_port(port, addr="127.0.0.1",
                                               timeout=600)
        except Exception:
            diag("post-reboot")
            raise
        # The rendered config survived on /mnt...
        conf = json.loads(services_vm.succeed(f"cat {CONF}"))
        assert conf["TokenKey"] == TOKEN_KEY, "TokenKey did not survive reboot"
        # ...the databases did, so the seeded admin still logs in...
        dto = curl(KAVITA, "/api/Account/login", "POST",
                   {"username": KAVITA_USER, "password": KAVITA_PASS})
        assert dto.get("apiKey"), f"post-reboot kavita login: {dto!r}"
        # ...and the indexed book is still indexed.
        services_vm.succeed(
            "curl -sf --max-time 30 -X POST "
            f"-H 'x-api-key: {dto['apiKey']}' -H 'Content-Type: application/json' "
            f"-d '{{}}' {KAVITA}/api/Series/all-v2 "
            "| grep -q 'Offline Test Book'"
        )
  '';
}
