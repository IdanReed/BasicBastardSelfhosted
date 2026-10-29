# Media suite (heavy): the full media stack on the services VM — Jellyfin,
# the arrs, Seerr, Bazarr, Profilarr, Cleanuparr, ClamAV, and qBittorrent in
# gluetun's netns. ~14 containers.
#
# Genuinely under test:
#   - the sops-nix render of the stack env (root-only, 0400), and env threading
#     END TO END: the arr API keys, the qbit PBKDF2 seed and the gluetun
#     provider config exist only in the encrypted fixture, so an API answering
#     to the fixture key proves the whole
#     sops -> /run/stack-env -> env_file -> {APP}__AUTH__APIKEY chain
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
#     logs zero "CHANGE:" lines (what protects Komodo redeploys)
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
#   - Jellyfin over LDAP: the pinned plugin installed from its verified zip
#     (a fixed-output fetch stands in for the download) and configured from
#     jellyfin-ldap.json; against a stand-in directory shaped like Authentik's
#     outpost (the outsider's slapd, reached as authentik-ldap on `homelab`),
#     a member's first login creates their Jellyfin account, an Admin member
#     becomes a Jellyfin admin, a non-member and a wrong password are refused,
#     the local idan stays local (an LDAP idan with another password cannot
#     log in as him, and no second idan appears), and an LDAP user signs in
#     to Seerr. The outpost itself is the authentik suite's: it runs the real
#     stacks/ldap against a real Authentik with the same filters
#   - the self-hosted indexer: Bitmagnet, its Postgres and Armiger come up in
#     gluetun's netns (started past its never-healthy gate, like qbit) and
#     have zero egress there too; two releases and an executable lure are
#     imported into Bitmagnet, Armiger tags them offline with its baked model,
#     media-init adds the Armiger indexer to Prowlarr at gluetun:8097, and a
#     Prowlarr search through it returns the releases WITHOUT the lure —
#     which raw Bitmagnet still serves, so Prowlarr is proven to sit behind
#     Armiger's filter. No crawling: the VM has no DHT to find
#   - loopback-only publishing for every port 10050-10059, from another host
#
# Documented gaps (do not read a green run as covering these):
#   - Profilarr's Dictionarry database link + profile sync needs egress
#     (git clone of the PCD repo) — offline, media-init logs its WARN and the
#     arrs carry no Dictionarry profiles. The x265 sweep is therefore
#     structural here (guard mechanics + no negative scores), not a check of
#     Dictionarry profile CONTENT; that runs on the real host at first link.
#     Same reason Profilarr's /api/v1/arr is asserted to answer with the
#     fixture key but not to list linked arrs: linking them is the one
#     documented UI/backup-restore step.
#   - gluetun can never turn HEALTHY offline (its healthcheck dials through
#     the tunnel), so `up --wait` cannot include it: it is started detached
#     and qbittorrent with --no-deps, and the netns behaviour is asserted
#     instead. The depends_on service_healthy + restart:true contract is
#     exercised only on the real host.
#   - actual HW transcode (Arc A380): no GPU in the VM. The compose's guarded
#     /dev/dri stanza is asserted to EXIST (drift guard) and jellyfin to run
#     without the device — software-transcode degradation.
#   - indexer push to Radarr/Sonarr: NOT asserted. The Armiger indexer is in
#     Prowlarr, but offline Bitmagnet cannot match releases to TMDB, so they
#     land in category 8000 ("Other") and the arrs' own indexer tests (movie
#     and TV categories) find nothing — only the applications (fullSync)
#     CONFIG is asserted, not the push.
#   - ntfy: the scanner's quarantine notification is never asserted — ntfy is
#     not deployed in this suite.
#   - cleanuparr: healthchecked, and cleanuparr-init's account claim + OIDC
#     settings asserted — but no strike exercise (needs a live queue), and its
#     arr connections and strike rules stay a one-time UI setup (v2 is
#     UI/SQLite-configured). The OIDC sign-in itself needs a live Authentik.
#   - Jellyfin's plugin is never pointed at the real outpost here (no
#     Authentik in this suite); the stand-in serves the entry shapes the
#     authentik suite reads back from the real one.
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
    images."python_3_13-alpine" # media-init + the jellyfin/seerr/bazarr sidecars
    images."postgres_16_13-alpine" # bitmagnet-db
    images."ghcr_io_bitmagnet-io_bitmagnet_v0_10_0"
    images."ghcr_io_spencernorton_armiger_3_4_1"
  ];

  # An SSO-Auth install from an earlier deploy (the last pinned release),
  # pre-seeded into the config volume with a stored provider config, so the
  # suite proves jellyfin-config-init removes both before jellyfin starts.
  ssoPlugin = pkgs.runCommand "jellyfin-sso-auth-4.0.0.4" {
    nativeBuildInputs = [ pkgs.unzip ];
  } ''
    mkdir $out
    unzip -q ${pkgs.fetchurl {
      url = "https://github.com/9p4/jellyfin-plugin-sso/releases/download/v4.0.0.4/sso-authentication_4.0.0.4.zip";
      sha256 = "c09f16ba31059a434ddd7f811e4f9608d4b4c4514cc80a5bf1ca33bee61e1107";
    }} -d $out
  '';

  # The LDAP plugin's pin. The suite is offline, so the zip jellyfin-config-init
  # would download is fetched here, by the SAME url and sha256, and placed in
  # its cache: the init still verifies and unpacks it.
  jellyfinLdap = builtins.fromJSON (builtins.readFile ../../stacks/media/jellyfin-ldap.json);
  ldapPluginZip = pkgs.fetchurl {
    inherit (jellyfinLdap.plugin) url sha256;
  };

  # A stand-in for Authentik's LDAP outpost: entries shaped the way the real
  # one serves them (cn=<username>,ou=users,<base>; a 64-hex uid; memberOf
  # cn=<group>,ou=groups,<base>) — the authentik suite reads those shapes back
  # from the real outpost with the same filters. idan exists here with a
  # password that is NOT his local one, to prove the local account wins.
  ldapBase = "dc=ldap,dc=idanreed,dc=com";
  ldapUsers = "ou=users,${ldapBase}";
  groupDn = g: "cn=${g},ou=groups,${ldapBase}";
  ldapPerson =
    {
      name,
      pw,
      uid,
      groups,
    }:
    lib.concatStringsSep "\n" (
      [
        "dn: cn=${name},${ldapUsers}"
        "objectClass: inetOrgPerson"
        "cn: ${name}"
        "sn: ${name}"
        "uid: ${uid}"
        "userPassword: ${pw}"
      ]
      ++ map (g: "memberOf: ${groupDn g}") groups
    )
    + "\n";
  ldapContents = lib.concatStringsSep "\n" (
    [
      ''
        dn: ${ldapBase}
        objectClass: dcObject
        objectClass: organization
        dc: ldap
        o: stand-in

        dn: ${ldapUsers}
        objectClass: organizationalUnit
        ou: users
      ''
    ]
    ++ map ldapPerson [
      {
        name = "jellyfin-ldap-bind";
        pw = "test_jellyfin_ldap_bind_not_secret";
        uid = lib.fixedWidthString 64 "0" "";
        groups = [ ];
      }
      {
        name = "ldapfriend";
        pw = "ldapfriend-pw";
        uid = lib.fixedWidthString 64 "1" "";
        groups = [ "headscale-users" ];
      }
      {
        name = "ldapadmin";
        pw = "ldapadmin-pw";
        uid = lib.fixedWidthString 64 "2" "";
        groups = [
          "headscale-users"
          "Admin"
        ];
      }
      {
        name = "ldapstranger";
        pw = "ldapstranger-pw";
        uid = lib.fixedWidthString 64 "3" "";
        groups = [ ];
      }
      {
        name = "idan";
        pw = "idan-ldap-only-pw";
        uid = lib.fixedWidthString 64 "4" "";
        groups = [
          "headscale-users"
          "Admin"
        ];
      }
    ]
  );

  # Gives the stand-in the outpost's name on `homelab`: a TCP relay
  # container called authentik-ldap, forwarding to the outsider's slapd.
  ldapRelay = pkgs.writeText "ldap-relay.py" ''
    import asyncio, sys

    async def pipe(r, w):
        try:
            while data := await r.read(65536):
                w.write(data)
                await w.drain()
        finally:
            w.close()

    async def handle(cr, cw):
        ur, uw = await asyncio.open_connection(sys.argv[1], 389)
        await asyncio.gather(pipe(cr, uw), pipe(ur, cw), return_exceptions=True)

    async def main():
        server = await asyncio.start_server(handle, "0.0.0.0", 3389)
        async with server:
            await server.serve_forever()

    asyncio.run(main())
  '';

  # Seeds /srv the way the real host gets it: Komodo's clone on the live
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
    rm -f $out/stacks/media/secrets.example.env
    ln -s /run/stack-env/media.env $out/stacks/media/.env
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
            memoryMB = 10240;
            diskMB = 28672;
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
            # it, and its containers starve the quarantine-inode timing.
            systemd.services.bootstrap-komodo.wantedBy = lib.mkForce [ ];
            # Komodo's sync bootstrap Requires the masked unit and would pull it
            # back in; Forgejo runs from the host too, and only the forgejo and
            # gitops suites load its image.
            systemd.services.komodo-sync-bootstrap.wantedBy = lib.mkForce [ ];
            systemd.services.forgejo.wantedBy = lib.mkForce [ ];
          }
        ];

        # This many containers on the sized profile's 2 cores makes every
        # healthcheck window a coin toss; 4 keeps startup contention sane.
        virtualisation.cores = lib.mkForce 4;

        # bootstrap-komodo.service `requires = srv.mount`; the tmpfs gives it
        # a genuine .mount unit.
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
          "d /mnt/fast/jellyfin/config/plugins 0755 root root -"
          "C /mnt/fast/jellyfin/config/plugins/SSO-Auth_4.0.0.4 - - - - ${ssoPlugin}"
          "d /mnt/fast/jellyfin/config/plugins/configurations 0755 root root -"
          # The LDAP plugin zip, where jellyfin-config-init looks before it
          # downloads (it verifies the sha256 either way).
          "d /mnt/fast/jellyfin/config/plugin-cache 0755 root root -"
          "C /mnt/fast/jellyfin/config/plugin-cache/${baseNameOf jellyfinLdap.plugin.url} - - - - ${ldapPluginZip}"
          "f /mnt/fast/jellyfin/config/plugins/configurations/SSO-Auth.xml 0600 root root - <PluginConfiguration/>"
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
          "d /mnt/fast/bitmagnet 0755 root root -"
          "d /mnt/fast/bitmagnet/pgdata 0700 70 70 -"
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

        # Populate /srv before anything reads it — the stand-in for
        # Komodo's clone having already run.
        systemd.services.seed-srv = {
          description = "Seed /srv from the repo (test only)";
          after = [ "srv.mount" ];
          requires = [ "srv.mount" ];
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
    #
    # A third role: the stand-in LDAP directory (see ldapContents).
    outsider =
      { pkgs, ... }:
      {
        services.nginx = {
          enable = true;
          virtualHosts."outsider" = {
            default = true;
            locations."/".return = "200 'outsider-ok'";
          };
        };
        services.openldap = {
          enable = true;
          urlList = [ "ldap:///" ];
          settings.children = {
            # memberOf itself comes with slapd's built-in memberof overlay.
            "cn=schema".includes = [
              "${pkgs.openldap}/etc/schema/core.ldif"
              "${pkgs.openldap}/etc/schema/cosine.ldif"
              "${pkgs.openldap}/etc/schema/inetorgperson.ldif"
            ];
            "olcDatabase={1}mdb".attrs = {
              objectClass = [
                "olcDatabaseConfig"
                "olcMdbConfig"
              ];
              olcDatabase = "{1}mdb";
              olcDbDirectory = "/var/lib/openldap/data";
              olcSuffix = ldapBase;
              olcAccess = [ "{0}to * by * read" ];
            };
          };
          declarativeContents.${ldapBase} = ldapContents;
        };
        networking.firewall.allowedTCPPorts = [
          80
          389
        ];
      };
  };

  testScript = ''
    import json
    import re
    import shlex

    MEDIA = "docker compose -f /srv/stacks/media/compose.yaml -p media"

    # Fixture values from tests/fixtures/stacks/media.sops.json — committed
    # test-only secrets, same pattern as the backrest suite's
    # test_backrest_password. Both passwords are idan's one password, rendered
    # from IDAN_INITIAL_PASSWORD in tests/fixtures/shared.sops.json (the qBit
    # PBKDF2 in the stack fixture is a real hash of it).
    RKEY = "746573747261646172726b6579303031"
    SKEY = "74657374736f6e6172726b6579303031"
    PKEY = "7465737470726f776c6172726b657931"
    PFKEY = "7465737470726f66696c6172726b65793030303030303030303030303030"
    QBIT_USER = "test_qbit_user"
    QBIT_PASS = "test_IDAN_initial_pw_not_secret"
    JELLYFIN_USER = "idan"
    JELLYFIN_PASS = "test_IDAN_initial_pw_not_secret"
    SEERR_KEY = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    BAZARR_KEY = "fedcba9876543210fedcba9876543210"

    # Jellyfin refuses any authenticated call without this header shape; the
    # token is appended once there is one.
    JF_AUTH = ('MediaBrowser Client="suite", Device="suite", '
               'DeviceId="media-suite", Version="1.0.0"')
    # The LDAP plugin's pin and configuration (stacks/media/jellyfin-ldap.json),
    # and the shared fixture's bind password jellyfin-init writes into it.
    JL = json.loads('${builtins.toJSON jellyfinLdap}')
    LDAP_BIND_PW = "test_jellyfin_ldap_bind_not_secret"
    LDAP_PROVIDER = "Jellyfin.Plugin.LDAP_Auth.LdapAuthenticationProviderPlugin"

    def jf_auth(user, pw, device):
        # (HTTP status, body) of a Jellyfin password login. Each probe gets its
        # own DeviceId: a login replaces any session of the same user+device.
        hdr = JF_AUTH.replace('DeviceId="media-suite"', f'DeviceId="{device}"')
        out = services_vm.succeed(
            "curl -s -w '\\n%{http_code}' --max-time 90 -X POST "
            "-H 'Content-Type: application/json' "
            + "-H " + shlex.quote("Authorization: " + hdr) + " "
            + "-d " + shlex.quote(json.dumps({"Username": user, "Pw": pw})) + " "
            "http://127.0.0.1:10050/Users/AuthenticateByName"
        )
        body, _, code = out.rpartition("\n")
        return code.strip(), (json.loads(body) if code.strip() == "200" else body)

    def jf_get(path, token):
        return json.loads(services_vm.succeed(
            "curl -sf --max-time 30 "
            + "-H " + shlex.quote(
                'Authorization: ' + JF_AUTH + ', Token="' + token + '"') + " "
            + f"http://127.0.0.1:10050{path}"
        ))

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
            "docker logs bitmagnet 2>&1 | grep -v '^\\s' | tail -20",
            "docker logs armiger 2>&1 | tail -20",
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
        url = shlex.quote(f"http://127.0.0.1:{port}/api/{ver}/{path}")
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
    # Boot chain: sops fixture -> /run/stack-env -> homelab network -> stack
    # -----------------------------------------------------------------------
    with subtest("the stack env rendered root-only (0400) and reaches the stack dir"):
        services_vm.wait_for_unit("docker-network-homelab.service")
        # Komodo is masked here, so nothing Requires stack-env-publish but
        # multi-user.target — wait the .env out (mk-stack-suite pattern).
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_until_succeeds("test -s /srv/stacks/media/.env", timeout=90)
        stat = services_vm.succeed(
            "stat -L -c '%a %u:%g' /srv/stacks/media/.env"
        ).strip()
        assert stat == "400 0:0", f".env is {stat}, expected 400 0:0"
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

    # Two releases and a lure (an executable dressed as a film) for Bitmagnet's
    # index: offline there is no DHT to crawl, and Prowlarr refuses to save an
    # indexer whose test search finds nothing.
    SEED = [
        ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "Big.Buck.Bunny.2008.1080p.BluRay.x265-SUITE"),
        ("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "Sintel.2010.2160p.WEB-DL.x265.10bit-SUITE"),
    ]
    LURE = ("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", "Cosmos.Laundromat.2015.1080p.WEB.x265.mkv.exe")

    def torznab_titles(url):
        # From inside armiger (python is there; curl is not): titles of an
        # empty-query search at a Torznab endpoint in gluetun's netns.
        out = services_vm.succeed(
            "docker exec armiger python -c "
            + shlex.quote(
                "import re, urllib.request; "
                f"x = urllib.request.urlopen('{url}/api?t=search', timeout=30).read().decode(); "
                "print('\\n'.join(t for t in re.findall(r'<title>([^<]*)</title>', x) if t != 'bitmagnet'))"
            )
        )
        return sorted(l for l in out.splitlines() if l.strip())

    with subtest("bitmagnet, its database and armiger start into gluetun's netns and turn healthy"):
        # --no-deps for the same reason as qbittorrent: their gluetun-healthy
        # gate can never be met offline.
        try:
            for svc, name in [("bitmagnet-db", "bitmagnet_db"),
                              ("bitmagnet", "bitmagnet"),
                              ("armiger", "armiger")]:
                services_vm.succeed(MEDIA + f" up -d --no-deps {svc}")
                services_vm.wait_until_succeeds(
                    f"docker inspect -f '{{{{.State.Health.Status}}}}' {name} "
                    "| grep -qx healthy",
                    timeout=600,
                )
        except Exception:
            diag("bitmagnet start")
            print(services_vm.execute(
                "docker logs bitmagnet 2>&1 | tail -30; docker logs armiger 2>&1 | tail -30")[1])
            raise
        # The import lands on Bitmagnet's UI publish — gluetun's 10059, the
        # same path Caddy uses.
        ndjson = "\n".join(json.dumps({"source": "suite", "infoHash": h, "name": n,
                                       "size": 1500000000})
                           for h, n in SEED + [LURE])
        out = services_vm.succeed(
            f"printf '%s\\n' {shlex.quote(ndjson)} | curl -sf --max-time 60 "
            "-X POST --data-binary @- http://127.0.0.1:10059/import"
        )
        assert "3 items imported" in out, out
        # Bitmagnet classifies on its queue before a release is searchable.
        try:
            services_vm.wait_until_succeeds(
                "docker exec armiger python -c "
                + shlex.quote(
                    "import urllib.request, sys; "
                    "x = urllib.request.urlopen('http://127.0.0.1:3333/torznab/api?t=search', timeout=30).read().decode(); "
                    "sys.exit(0 if x.count('<item>') >= 3 else 1)"
                ),
                timeout=600,
            )
        except Exception:
            print(services_vm.execute(
                "docker logs bitmagnet 2>&1 | grep -v '^\\s' | tail -40")[1])
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

    with subtest("jellyfin-init drives the wizard and exits 0"):
        # Same shape as media-init: no dependent consumes it, so `--wait`
        # would report a successful exit as a failure. It is ordered AFTER
        # media-init because POST /Library/VirtualFolders throws on a path
        # that does not exist and media-init creates the skeleton.
        try:
            services_vm.succeed(MEDIA + " up -d jellyfin-init")
            services_vm.wait_until_succeeds(
                "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
                "media_jellyfin_init | grep -qx exited/0",
                timeout=900,
            )
        except Exception:
            diag("jellyfin-init run")
            raise

    with subtest("seerr-bootstrap makes the three calls and exits 0"):
        try:
            services_vm.succeed(MEDIA + " up -d seerr-bootstrap")
            services_vm.wait_until_succeeds(
                "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
                "media_seerr_bootstrap | grep -qx exited/0",
                timeout=900,
            )
        except Exception:
            diag("seerr-bootstrap run")
            raise

    with subtest("cleanuparr-init claims the account and sets OIDC; a re-run changes nothing"):
        # Same shape as jellyfin-init: no dependent consumes it. Offline it
        # writes the OIDC settings without contacting the issuer — discovery
        # happens at sign-in.
        try:
            services_vm.succeed(MEDIA + " up -d cleanuparr-init")
            services_vm.wait_until_succeeds(
                "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
                "media_cleanuparr_init | grep -qx exited/0",
                timeout=600,
            )
        except Exception:
            diag("cleanuparr-init run")
            raise
        first = services_vm.succeed("docker logs media_cleanuparr_init 2>&1")
        assert "CHANGE:" in first, (
            f"cleanuparr-init's first run against a fresh Cleanuparr changed "
            f"nothing:\n{first}")
        again = services_vm.succeed(
            MEDIA + " run --rm --no-deps cleanuparr-init 2>&1")
        assert "CHANGE:" not in again, (
            f"a cleanuparr-init re-run was not a no-op:\n{again}")

    with subtest("every container is in its contract state"):
        # Healthchecked services must be healthy; the two init oneshots must
        # have exited 0; gluetun must be running AND unhealthy — offline, a
        # healthy gluetun would mean its healthcheck no longer proves the
        # tunnel, which is exactly the regression this pins.
        for name in ["qbittorrent", "jellyfin", "radarr", "sonarr", "prowlarr",
                     "seerr", "bazarr", "profilarr", "cleanuparr", "clamav",
                     "clamav_scanner", "bitmagnet_db", "bitmagnet", "armiger"]:
            h = services_vm.succeed(
                f"docker inspect -f '{{{{.State.Health.Status}}}}' {name}"
            ).strip()
            assert h == "healthy", f"{name} is {h!r}, expected healthy"
        for name in ["media_qbit_init", "media_seerr_init", "media_init",
                     "media_jellyfin_config_init", "media_jellyfin_init",
                     "media_bazarr_config_init", "media_seerr_bootstrap",
                     "media_cleanuparr_init"]:
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

    with subtest("qbit listens on the forwarded port, UPnP and random port off"):
        # The fixture carries FIREWALL_VPN_INPUT_PORTS=51413; media-init set
        # qbit's listen port to it over the API (qBittorrent.conf is seed-once).
        services_vm.succeed(
            "curl -s -o /dev/null --max-time 10 -c /tmp/qbit.jar "
            "-H 'Referer: http://127.0.0.1:10057' "
            + f"--data-urlencode 'username={QBIT_USER}' "
            f"--data-urlencode 'password={QBIT_PASS}' "
            "http://127.0.0.1:10057/api/v2/auth/login"
        )
        prefs = json.loads(services_vm.succeed(
            "curl -sf --max-time 10 -b /tmp/qbit.jar "
            "http://127.0.0.1:10057/api/v2/app/preferences"
        ))
        assert prefs.get("listen_port") == 51413, (
            f"qbit listens on {prefs.get('listen_port')}, expected the forwarded 51413")
        assert prefs.get("upnp") is False and prefs.get("random_port") is False, (
            f"qbit upnp={prefs.get('upnp')} random_port={prefs.get('random_port')}")
        init_log = services_vm.succeed("docker logs media_init 2>&1")
        assert "forwarded port" in init_log, init_log[-2000:]

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

    with subtest("kill-switch: bitmagnet and armiger have zero egress too"):
        # Same netns as qbittorrent, so the same default-drop — asserted from
        # each container, because the crawler is the one that would leak.
        outsider_ip = outsider.succeed(
            "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
        ).strip()
        services_vm.fail(
            f"docker exec bitmagnet curl -s --max-time 10 http://{outsider_ip}/"
        )
        services_vm.fail(
            "docker exec armiger python -c "
            + shlex.quote(f"import urllib.request; urllib.request.urlopen('http://{outsider_ip}/', timeout=10)")
        )
        # What the stack network does reach: Armiger's Torznab proxy (gluetun
        # admits its own docker subnet to the netns) — but not Bitmagnet's
        # database, which listens on 127.0.0.1 only.
        services_vm.succeed(
            "docker exec prowlarr curl -sf --max-time 10 "
            "'http://gluetun:8097/torznab/api?t=caps' | grep -q '<caps>'"
        )
        services_vm.fail(
            "docker exec prowlarr bash -c "
            + shlex.quote('timeout 5 bash -c ": </dev/tcp/gluetun/5432"')
        )

    with subtest("prowlarr searches Bitmagnet only through Armiger's filter"):
        idx = [i for i in api("prowlarr", "indexer") or []
               if i.get("name") == "Armiger (Bitmagnet)"]
        assert len(idx) == 1, f"prowlarr indexers: {api('prowlarr', 'indexer')!r}"
        fields = {f["name"]: f.get("value") for f in idx[0]["fields"]}
        assert idx[0].get("implementation") == "Torznab" and idx[0].get("enable"), idx[0]
        assert fields.get("baseUrl") == "http://gluetun:8097/torznab", fields
        init_out = services_vm.succeed("docker logs media_init 2>&1")
        assert "prowlarr: added the Armiger (Bitmagnet) indexer" in init_out, init_out[-3000:]
        seed_titles = sorted(n for _, n in SEED)
        # Raw Bitmagnet serves the lure; Armiger's proxy drops it.
        assert torznab_titles("http://127.0.0.1:3333/torznab") == sorted(seed_titles + [LURE[1]])
        assert torznab_titles("http://127.0.0.1:8097/torznab") == seed_titles
        # And a search through Prowlarr is the filtered set.
        found = sorted(r.get("title") for r in api(
            "prowlarr", f"search?query=&type=search&indexerIds={idx[0]['id']}") or [])
        assert found == seed_titles, f"prowlarr found {found!r}"
        # Armiger's poller classified what Bitmagnet indexed, with the model
        # baked into its image (no downloads offline).
        tags = int(services_vm.succeed(
            "docker exec bitmagnet_db psql -U bitmagnet -d bitmagnet -tAc "
            "\"select count(*) from torrent_tags where name = 'armiger-movie'\""
        ).strip())
        assert tags >= 2, f"armiger tagged {tags} release(s) as movies"

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
        # The sweep, over BOTH arrs and every profile,
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
            f"profilarr /api/v1/arr answered {code} with no key (AUTH=oidc)"
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
        # 🚨 THE regression test for the ClamAV-quarantine/import race.
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
        # The scanner logs CONTAINER paths — its mount is /mnt/slow/data:/data,
        # so every UNLINKED line reads /data/..., never /mnt/slow/data/....
        # Translate each library dir before matching.
        for d in [lib_dir, lib_dir2]:
            cpath = d.replace("/mnt/slow/data", "/data", 1)
            assert any(cpath in l for l in unlinked), (
                f"the scanner unlinked nothing under {d!r} ({cpath!r} in the "
                f"container) — UNLINKED lines: {unlinked!r}"
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
        # The media stack acquires audiobooks and MOVES a completed entry into the
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
        # On a fresh volume the category comes from qbit-init's seeded
        # categories.json, which is the half that works with the tunnel down
        # (qbit never starts, so media-init's API reconcile cannot run).
        seed_log = services_vm.succeed("docker logs media_qbit_init 2>&1")
        assert "CHANGE: seeded" in seed_log and "categories.json" in seed_log, (
            f"qbit-init did not seed categories.json:\n{seed_log}"
        )
        services_vm.succeed(
            "test -f /mnt/fast/qbittorrent/config/qBittorrent/categories.json"
        )
        # And media-init reconciled rather than fighting it: with the seed in
        # place its first run is the already-correct branch, not a create and
        # not a repoint.
        first = services_vm.succeed("docker logs media_init 2>&1")
        assert "category 'audiobooks' already saves to" in first, (
            f"media-init did not agree with the seeded category:\n{first}"
        )
        assert "repointed category" not in first, (
            f"media-init repointed a category it should have agreed with:\n"
            f"{first}"
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
        # Drift guard: HW transcode is untestable here, but
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
        # The half that IS declarative: encoding.xml is seeded before the
        # first start and jellyfin keeps it (named configs are read but never
        # rewritten at startup). Without it nothing in the repo turns VAAPI
        # on, and a from-repo fleet transcodes in software on an Arc A380.
        enc = services_vm.succeed(
            "cat /mnt/fast/jellyfin/config/config/encoding.xml"
        )
        assert "<HardwareAccelerationType>vaapi</HardwareAccelerationType>" in enc, (
            f"encoding.xml lost its vaapi setting:\n{enc[:600]}"
        )
        assert "<AllowHevcEncoding>true</AllowHevcEncoding>" in enc, (
            "encoding.xml forbids HEVC output — x265 is enforced fleet-wide, "
            "so every HEVC source needing a transcode would become h264"
        )

    with subtest("the startup wizard is CLOSED and the seeded admin owns it"):
        # The whole point of jellyfin-init: no browser ever touched this
        # server. StartupWizardCompleted flips only through POST
        # /Startup/Complete, which is reachable only while it is still open.
        info = json.loads(services_vm.succeed(
            "curl -sf --max-time 30 http://127.0.0.1:10050/System/Info/Public"
        ))
        assert info.get("StartupWizardCompleted") is True, (
            f"jellyfin still has its setup wizard open: {info!r}"
        )
        # The admin is the .env one, proven by authenticating as it.
        body = json.dumps({"Username": JELLYFIN_USER, "Pw": JELLYFIN_PASS})
        auth = json.loads(services_vm.succeed(
            "curl -sf --max-time 30 -X POST "
            "-H 'Content-Type: application/json' "
            + "-H " + shlex.quote("Authorization: " + JF_AUTH) + " "
            + "-d " + shlex.quote(body) + " "
            "http://127.0.0.1:10050/Users/AuthenticateByName"
        ))
        token = auth.get("AccessToken")
        assert token, f"AuthenticateByName returned no token: {auth!r}"
        policy = (auth.get("User") or {}).get("Policy") or {}
        assert policy.get("IsAdministrator") is True, (
            f"the seeded jellyfin user is not an administrator: {auth!r}"
        )
        # ... and the two libraries exist, on the read-only bind.
        folders = json.loads(services_vm.succeed(
            "curl -sf --max-time 30 "
            + "-H " + shlex.quote(
                'Authorization: ' + JF_AUTH + ', Token="' + token + '"') + " "
            "http://127.0.0.1:10050/Library/VirtualFolders"
        ))
        by_name = {f["Name"]: f for f in folders}
        assert set(by_name) >= {"Movies", "TV"}, (
            f"jellyfin libraries are {sorted(by_name)!r}"
        )
        for name, path in [("Movies", "/data/media/movies"),
                           ("TV", "/data/media/tv")]:
            assert path in by_name[name]["Locations"], (
                f"library {name!r} points at {by_name[name]['Locations']!r}"
            )
        # A second run is a no-op — the CHANGE: contract every redeploy needs.
        out = services_vm.succeed(
            MEDIA + " run --rm --no-deps jellyfin-init 2>&1"
        )
        assert "CHANGE:" not in out, (
            f"a jellyfin-init run against a seeded server was not a no-op:\n{out}"
        )

    with subtest("no SSO: the earlier plugin is gone and the login page has no button"):
        # Jellyfin keeps its own logins (TV clients cannot follow an OIDC
        # redirect). The pre-seeded SSO-Auth install and its config stand in
        # for an earlier deploy; jellyfin-config-init removed both.
        services_vm.fail("ls -d /mnt/fast/jellyfin/config/plugins/SSO-Auth_*")
        services_vm.fail(
            "test -e /mnt/fast/jellyfin/config/plugins/configurations/SSO-Auth.xml")
        auth = json.loads(services_vm.succeed(
            "curl -sf --max-time 30 -X POST "
            "-H 'Content-Type: application/json' "
            + "-H " + shlex.quote("Authorization: " + JF_AUTH) + " "
            + "-d " + shlex.quote(json.dumps(
                {"Username": JELLYFIN_USER, "Pw": JELLYFIN_PASS})) + " "
            "http://127.0.0.1:10050/Users/AuthenticateByName"
        ))
        hdr = "-H " + shlex.quote(
            'Authorization: ' + JF_AUTH + ', Token="' + auth["AccessToken"] + '"')
        plugins = json.loads(services_vm.succeed(
            f"curl -sf --max-time 30 {hdr} http://127.0.0.1:10050/Plugins"))
        sso = [p for p in plugins if str(p.get("Id", "")).replace("-", "").lower()
               == "505ce9d1d91642fa86ca673ef241d7df"]
        assert not sso, f"an SSO-Auth plugin is still loaded: {sso!r}"
        branding = json.loads(services_vm.succeed(
            "curl -sf --max-time 30 http://127.0.0.1:10050/Branding/Configuration"))
        assert "/sso/OID/" not in (branding.get("LoginDisclaimer") or ""), branding

    # -----------------------------------------------------------------------
    # (f2) Jellyfin over LDAP
    # -----------------------------------------------------------------------
    with subtest("the LDAP plugin is installed from its verified zip, pinned, and configured"):
        ver = JL["plugin"]["version"]
        init_out = services_vm.succeed("docker logs media_jellyfin_config_init 2>&1")
        assert f"CHANGE: installed the LDAP plugin {ver}" in init_out, init_out
        # The suite's copy satisfied the cache, so nothing was downloaded —
        # and the init still checked its sha256 before unpacking it.
        assert "downloaded" not in init_out and "WARN" not in init_out, init_out
        meta = json.loads(services_vm.succeed(
            f"cat /mnt/fast/jellyfin/config/plugins/LDAP-Auth_{ver}/meta.json"))
        assert meta.get("autoUpdate") is False, (
            f"the pinned plugin would be auto-updated by jellyfin: {meta!r}")
        token = jf_auth(JELLYFIN_USER, JELLYFIN_PASS, "suite-ldap-cfg")[1]["AccessToken"]
        guid = JL["plugin"]["guid"].replace("-", "").lower()
        loaded = [p for p in jf_get("/Plugins", token)
                  if str(p.get("Id", "")).replace("-", "").lower() == guid]
        assert loaded and loaded[0].get("Status") == "Active", loaded
        assert loaded[0].get("Version") == ver, loaded
        cfg = jf_get(f"/Plugins/{loaded[0]['Id']}/Configuration", token)
        for k, v in JL["configuration"].items():
            assert cfg.get(k) == v, f"plugin {k} is {cfg.get(k)!r}, expected {v!r}"
        assert cfg.get("LdapBindPassword") == LDAP_BIND_PW, "bind password not configured"
        out = services_vm.succeed(MEDIA + " run --rm --no-deps jellyfin-config-init 2>&1")
        assert "CHANGE:" not in out, f"a jellyfin-config-init re-run changed something:\n{out}"

    with subtest("a stand-in directory answers as authentik-ldap on homelab"):
        outsider_ip = outsider.succeed(
            "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
        ).strip()
        outsider.wait_for_unit("openldap.service")
        services_vm.succeed(
            "docker run -d --name authentik-ldap --network homelab "
            "-v ${ldapRelay}:/relay.py:ro python:3.13-alpine "
            f"python /relay.py {outsider_ip}"
        )
        # From jellyfin's own netns: the name resolves on homelab and the
        # directory answers through the relay.
        services_vm.wait_until_succeeds(
            "docker exec jellyfin bash -c ': </dev/tcp/authentik-ldap/3389'",
            timeout=60,
        )

    with subtest("an LDAP member's first login creates the account; Admin members are admins"):
        try:
            code, body = jf_auth("ldapfriend", "ldapfriend-pw", "suite-ldapfriend")
            assert code == "200", f"ldapfriend: HTTP {code} {body!r}"
            pol = body["User"]["Policy"]
            assert pol.get("AuthenticationProviderId") == LDAP_PROVIDER, pol
            assert not pol.get("IsAdministrator") and pol.get("EnableAllFolders"), pol
            code, body = jf_auth("ldapadmin", "ldapadmin-pw", "suite-ldapadmin")
            assert code == "200", f"ldapadmin: HTTP {code} {body!r}"
            assert body["User"]["Policy"].get("IsAdministrator") is True, (
                "a member of Admin did not become a Jellyfin admin")
            code, _ = jf_auth("ldapstranger", "ldapstranger-pw", "suite-stranger")
            assert code == "401", f"a non-member of headscale-users got HTTP {code}"
            code, _ = jf_auth("ldapfriend", "not-the-password", "suite-ldapfriend-bad")
            assert code == "401", f"a wrong LDAP password got HTTP {code}"
        except Exception:
            print(services_vm.execute("docker logs jellyfin 2>&1 | grep -i ldap | tail -30")[1])
            print(outsider.execute("journalctl -u openldap --no-pager | tail -30")[1])
            raise

    with subtest("idan stays the local admin: no LDAP idan, no second account"):
        code, body = jf_auth(JELLYFIN_USER, JELLYFIN_PASS, "suite-idan-local")
        assert code == "200" and body["User"]["Policy"].get("IsAdministrator"), body
        assert body["User"]["Policy"].get("AuthenticationProviderId", "").endswith(
            "DefaultAuthenticationProvider"), body["User"]["Policy"]
        # The stand-in's idan has another password: an existing account is
        # authenticated by its own provider only, so it is refused.
        code, _ = jf_auth(JELLYFIN_USER, "idan-ldap-only-pw", "suite-idan-ldap")
        assert code == "401", f"idan logged in with the directory's password (HTTP {code})"
        token = jf_auth(JELLYFIN_USER, JELLYFIN_PASS, "suite-idan-local")[1]["AccessToken"]
        names = sorted(str(u.get("Name", "")).lower() for u in jf_get("/Users", token))
        assert names == ["idan", "ldapadmin", "ldapfriend"], names

    with subtest("jellyfin-init stays a no-op, and keeps the plugin's user links"):
        out = services_vm.succeed(MEDIA + " run --rm --no-deps jellyfin-init 2>&1")
        assert "CHANGE:" not in out, f"jellyfin-init changed something:\n{out}"
        xml = services_vm.succeed(
            "cat /mnt/fast/jellyfin/config/plugins/configurations/LDAP-Auth.xml")
        assert xml.count("<LinkedJellyfinUserId>") == 2, xml[-1500:]

    with subtest("only jellyfin-init carries the bind password; the outpost's env renders"):
        for c in ["gluetun", "radarr", "sonarr", "prowlarr", "profilarr", "jellyfin"]:
            env = services_vm.succeed(
                f"docker inspect -f '{{{{range .Config.Env}}}}{{{{println .}}}}{{{{end}}}}' {c}")
            assert "JELLYFIN_LDAP_BIND_PASSWORD=" not in env, f"{c} carries it"
        assert "JELLYFIN_LDAP_BIND_PASSWORD=" in services_vm.succeed(
            "docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "
            "media_jellyfin_init")
        # stacks/ldap's env: the outpost token, from the shared fixture.
        st = services_vm.succeed("stat -c '%a %u:%g' /run/stack-env/ldap.env").strip()
        assert st == "400 0:0", st
        services_vm.succeed(
            "grep -qx \"AUTHENTIK_TOKEN='test_ldap_outpost_token_not_secret'\" "
            "/run/stack-env/ldap.env")

    with subtest("seerr is initialised, with the arrs and jellyfin linked"):
        # public.initialized is the first-run flag; /setup is the browser step
        # this replaces.
        pub = json.loads(services_vm.succeed(
            "curl -sf --max-time 30 "
            "http://127.0.0.1:10054/api/v1/settings/public"
        ))
        assert pub.get("initialized") is True, (
            f"seerr still reports first-run: {pub!r}"
        )
        # The seeded settings.json reached seerr rather than being ignored:
        # radarr came from the file, the jellyfin block from the auth call.
        # The API key resolving at all also proves compose handed seerr
        # API_KEY from SEERR_API_KEY (it forces main.apiKey on every load).
        radarr = json.loads(services_vm.succeed(
            "curl -sf --max-time 30 "
            + "-H " + shlex.quote("X-Api-Key: " + SEERR_KEY) + " "
            "http://127.0.0.1:10054/api/v1/settings/radarr"
        ))
        assert any(r.get("hostname") == "radarr" for r in radarr), (
            f"seerr has no radarr connection: {radarr!r}"
        )
        jf = json.loads(services_vm.succeed(
            "curl -sf --max-time 30 "
            + "-H " + shlex.quote("X-Api-Key: " + SEERR_KEY) + " "
            "http://127.0.0.1:10054/api/v1/settings/jellyfin"
        ))
        assert jf.get("ip") == "jellyfin", f"seerr jellyfin block: {jf!r}"
        # A second run is a no-op, guarded on public.initialized.
        out = services_vm.succeed(
            MEDIA + " run --rm --no-deps seerr-bootstrap 2>&1"
        )
        assert "CHANGE:" not in out, (
            f"a seerr-bootstrap run against an initialised seerr changed "
            f"something:\n{out}"
        )

    with subtest("an LDAP user signs in to Seerr, which creates their account"):
        # Seerr signs in against Jellyfin, so this is the plugin's login again;
        # seerr-bootstrap keeps Jellyfin sign-in and new-user sign-in on.
        main = json.loads(services_vm.succeed(
            "curl -sf --max-time 30 "
            + "-H " + shlex.quote("X-Api-Key: " + SEERR_KEY) + " "
            "http://127.0.0.1:10054/api/v1/settings/main"
        ))
        assert main.get("mediaServerLogin") is True and main.get("newPlexLogin") is True, main
        status = services_vm.succeed(
            "curl -s -o /dev/null -w '%{http_code}' --max-time 90 -X POST "
            "-H 'Content-Type: application/json' "
            + "-d " + shlex.quote(json.dumps(
                {"username": "ldapfriend", "password": "ldapfriend-pw"})) + " "
            "http://127.0.0.1:10054/api/v1/auth/jellyfin"
        ).strip()
        assert status == "200", f"seerr sign-in for ldapfriend: HTTP {status}"
        users = json.loads(services_vm.succeed(
            "curl -sf --max-time 30 "
            + "-H " + shlex.quote("X-Api-Key: " + SEERR_KEY) + " "
            "'http://127.0.0.1:10054/api/v1/user?take=50'"
        ))
        names = sorted(str(u.get("jellyfinUsername") or u.get("displayName") or "")
                       for u in users.get("results", []))
        assert "ldapfriend" in names, names

    with subtest("bazarr loaded its seeded arr connections"):
        # The file bazarr reads is <config_dir>/config/config.yaml, with
        # the doubled `config`. Asserted through the API, so this proves
        # bazarr LOADED the file rather than that the file exists — and the
        # pinned auth.apikey working is the other half (the default is a
        # random 16 bytes nobody could know).
        cfg = services_vm.succeed(
            "cat /mnt/fast/bazarr/config/config/config.yaml"
        )
        assert "use_radarr: true" in cfg and "use_sonarr: true" in cfg, cfg
        data = json.loads(services_vm.succeed(
            "curl -sf --max-time 30 "
            + "-H " + shlex.quote("X-API-KEY: " + BAZARR_KEY) + " "
            "http://127.0.0.1:10055/api/system/settings"
        ))
        for section, host in [("radarr", "radarr"), ("sonarr", "sonarr")]:
            # Dynaconf's as_dict() case is not contractual; the values are.
            block = {k.lower(): v for k, v in (data.get(section) or {}).items()}
            assert block.get("ip") == host, (
                f"bazarr {section} block is {block!r}"
            )
        # Negative control: without the pinned key the API refuses, so the
        # positive above is about auth.apikey and not an open endpoint.
        code = services_vm.succeed(
            "curl -s -o /dev/null -w '%{http_code}' --max-time 30 "
            "-H 'X-API-KEY: definitely-not-the-key' "
            "http://127.0.0.1:10055/api/system/settings"
        ).strip()
        assert code == "401", f"bazarr accepted a wrong API key (HTTP {code})"

    # -----------------------------------------------------------------------
    # (g) loopback-only publishing, from the VLAN
    # -----------------------------------------------------------------------
    with subtest("no media port is reachable from the VLAN"):
        # Positive control: the outsider can resolve and reach the VM at all
        # (22 is in allowedTCPPorts); without it every fail() below would
        # pass identically on a dead vlan.
        outsider.succeed("nc -z -w 5 services-vm 22")
        for port in range(10050, 10060):
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
        # working, not a regression.
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
