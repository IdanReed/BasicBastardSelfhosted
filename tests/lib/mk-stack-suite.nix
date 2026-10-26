# One fast suite per stack (`nix-build tests -A stackChecks.<name>`): boot the
# real services VM, seed only that stack, `docker compose up --wait`, and
# assert env decryption, loopback-only publishing and healthy containers.
#
# ZERO per-stack maintenance by construction — images, ports and /mnt roots
# are all derived at eval time from the compose file, so adding a stack is one
# list entry in ../default.nix.
#
# Deliberately NOT covered (that is ../suites/services-vm.nix's job): the
# komodo boot chain, Caddy routing, notify-failure, cross-stack interaction,
# SSH and reboot convergence.

{
  pkgs,
  lib,
  images,
  profiles,
  sopsModule,
}:

{ stack }:

let
  composeDir = ../../stacks + "/${stack}";
  composeFile = composeDir + "/compose.yaml";

  # Compose parse

  # A line scan, not a YAML parser: the stack conventions keep compose files
  # flat, and a stack that strays far enough to defeat it wants a hand-written
  # suite anyway.
  composeLines = lib.splitString "\n" (builtins.readFile composeFile);

  matchAll =
    regex: group:
    lib.concatMap (
      line:
      let
        m = builtins.match regex line;
      in
      if m == null then [ ] else [ (lib.elemAt m group) ]
    ) composeLines;

  # `image: ref`, optionally quoted, optionally with a trailing comment.
  # Commented-out image lines never match: the leading `#` is not consumed.
  imageRefs = lib.unique (
    matchAll "[[:space:]]*image:[[:space:]]*[\"']?([^\"'[:space:]#]+)[\"']?[[:space:]]*(#.*)?" 0
  );

  # Host-published ports, `127.0.0.1:P:C` or bare `P:C`; group 1 is the host
  # port either way. The outsider negative below verifies FIREWALL POSTURE
  # only, not loopback binding — a 0.0.0.0 publish is dropped by the firewall
  # here, and the real exposure is through tailscale0, which this VM never
  # joins. loopback-binding is the lint that covers it.
  parsedHostPorts = map lib.toInt (
    lib.unique (
      # trailing comment tolerated (POSIX ERE: plain group, not (?:...))
      matchAll "[[:space:]]*-[[:space:]]*[\"']?(127\\.0\\.0\\.1:)?([0-9]+):([0-9]+)(/tcp|/udp)?[\"']?[[:space:]]*(#.*)?" 1
    )
  );

  # Zero ports would make the publishing subtest an empty loop, so an empty
  # parse means the compose file strayed and needs a hand-written suite.
  hostPorts =
    if parsedHostPorts == [ ] then
      throw (
        "stackChecks.${stack}: no host ports parsed from compose.yaml — the "
        + "publishing subtest would be vacuous. Long-form or variable ports? "
        + "Write a hand-written suite for this stack."
      )
    else
      parsedHostPorts;

  # Bind-mount sources under /mnt. Relative (./file) and non-/mnt mounts are
  # left to the seeded stack directory and the base system.
  mntPaths = lib.unique (matchAll "[[:space:]]*-[[:space:]]*[\"']?(/mnt/[^:\"']+):.*" 0);

  # Volume-root ownership

  # 🚨 Read from the SAME generated table the real host imports, never
  # hardcoded root:root — that is also docker's create-on-mount default, so
  # hardcoding it reproduces the very bug stack-dirs.nix prevents (any image
  # that drops privileges restart-loops within seconds, measured).
  stackDirRules = (import ../../nixos/stack-dirs.nix).systemd.tmpfiles.rules;
  rulePath = r: lib.elemAt (lib.splitString " " r) 1;
  # Ancestor-or-self, so a bind source's parents come along with their own
  # declared ownership rather than tmpfiles' default for a created parent.
  covers = dir: p: p == dir || lib.hasPrefix (dir + "/") p;
  mntRules = lib.filter (r: lib.any (covers (rulePath r)) mntPaths) stackDirRules;

  # Every bind source needs a rule of its OWN (not just an ancestor's). The
  # generator refuses to emit without a STACK_NOTES entry, so this can only
  # fire when the two parsers disagree about a path — loudly, at eval.
  unruled = lib.filter (p: !(lib.any (r: rulePath r == p) stackDirRules)) mntPaths;
  checkedMntRules =
    if unruled == [ ] then
      mntRules
    else
      throw (
        "stackChecks.${stack}: compose.yaml bind-mounts ${lib.concatStringsSep ", " unruled} "
        + "but nixos/stack-dirs.nix has no rule for it. Add the STACK_NOTES/DIR_NOTES "
        + "entry and re-run nixos/generate-stack-dirs.sh."
      );

  # Image pins

  # The suites run offline, so an unpinned image cannot be pulled at runtime —
  # throw at eval rather than minutes into a VM boot. The isAttrs filter drops
  # images.nix's `_unresolved`/`_skipped` lists.
  pinnedImages = lib.filter (v: builtins.isAttrs v) (lib.attrValues images);

  pinFor =
    ref:
    let
      matches = lib.filter (v: v.composeRef == ref) pinnedImages;
    in
    if matches == [ ] then
      throw (
        "stackChecks.${stack}: no pin for image '${ref}' in tests/lib/images.nix. "
        + "Run tests/update-images.sh to resolve and pin it."
      )
    else
      builtins.head matches;

  stackImages = map pinFor imageRefs;

  # /srv seed

  # A stack has secrets iff it has a fixture: the fixture set mirrors the real
  # one (the stack-env-drift lint pins their key sets together).
  fixture = ../fixtures/stacks + "/${stack}.sops.json";
  hasFixture = builtins.pathExists fixture;

  # The stack directory as the host gets it: compose.yaml plus its read-only
  # bind sources. Its environment is rendered from the fixture by the REAL
  # sops-nix templates and stack-env-publish (profiles.sopsFixture), into
  # /run/stack-env/<stack>.env. The .env symlink stands in for Komodo's
  # --env-file, so `${VAR}` interpolation in compose.yaml sees the same file.
  seedSrv = pkgs.runCommand "srv-seed-${stack}" { } ''
    mkdir -p $out/stacks/${stack}
    cp -r ${composeDir}/. $out/stacks/${stack}/
    chmod -R u+w $out/stacks/${stack}
    # The working-tree cp -r can capture a developer's stray plaintext .env
    # (gitignored on purpose) in the world-readable store.
    rm -f $out/stacks/${stack}/.env $out/stacks/${stack}/secrets.sops.json
    ${lib.optionalString hasFixture ''
      ln -s /run/stack-env/${stack}.env $out/stacks/${stack}/.env
    ''}
  '';
in
pkgs.testers.runNixOSTest {
  name = "stack-${stack}";

  nodes = {
    services =
      { config, pkgs, ... }:
      {
        imports = [
          sopsModule
          ../../nixos/configuration.nix

          profiles.noBootloader
          profiles.noDhcp
          profiles.manualTailscaleAutoconnect
          (profiles.sopsFixture ../fixtures/services-vm.sops.yaml)
          (profiles.sized {
            memoryMB = 3072;
            diskMB = 8192;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            # Nothing container-shaped runs at boot here (bootstrap-komodo is
            # masked below), so the only contract is "loaded before the test
            # script's compose up", i.e. before the boot finishes.
            beforeUnits = [ "multi-user.target" ];
          })
        ];

        # Keep the deploy plane out of the boot path: its images and bootstrap
        # ordering dominate this suite's runtime. Coverage lost — the
        # stack-env-publish -> docker-network-homelab -> bootstrap-komodo
        # chain and Komodo itself — is exactly what checks.services covers.
        systemd.services.bootstrap-komodo.wantedBy = lib.mkForce [ ];
        # Komodo's sync bootstrap Requires the masked unit and would pull it
        # back in; Forgejo runs from the host too, and only the forgejo and
        # gitops suites load its image.
        systemd.services.komodo-sync-bootstrap.wantedBy = lib.mkForce [ ];
        systemd.services.forgejo.wantedBy = lib.mkForce [ ];

        # bootstrap-komodo `requires = srv.mount`; tmpfs gives a genuine .mount
        # unit, and /mnt/{fast,slow} back whatever volume roots the compose
        # file names.
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
          "d /srv/stacks 0755 1000 1000 -"
          "d /var/lib/sops-nix 0700 root root -"
        ]
        ++ checkedMntRules;

        # Populate /srv with the stack directory; on the real host Komodo's
        # clone plays this role.
        systemd.services.seed-srv = {
          description = "Seed /srv with the ${stack} stack (test only)";
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

    # Another host on the LAN. Loopback-only publishing is the convention
    # that keeps tailnet users from bypassing Caddy (and forward auth) by
    # port number; the probe from here checks firewall posture from off-host,
    # not the bind address itself (see the hostPorts note above).
    outsider = { };
  };

  testScript = ''
    import json

    start_all()

    def dump_diag():
        # wait_until_succeeds/--wait grinds are silent; say what the stack
        # actually did before the failure propagates.
        for label, cmd in [
            ("compose ps",
             "docker compose -f /srv/stacks/${stack}/compose.yaml -p ${stack} ps -a || true"),
            ("compose logs",
             "docker compose -f /srv/stacks/${stack}/compose.yaml -p ${stack} logs --tail=100 || true"),
            ("stack-env-publish journal",
             "journalctl -u stack-env-publish --no-pager -o cat | tail -20"),
            ("docker journal",
             "journalctl -u docker --no-pager -o cat | tail -30"),
        ]:
            print(f"=== {label} ===")
            print(services_vm.execute(cmd)[1])

    # A Nix-interpolated constant rather than a spliced-in block: Nix indented
    # strings do not re-indent multi-line interpolations, so conditionally
    # splicing python into a try: body produces an IndentationError for exactly
    # the stacks that have a fixture. A constant keeps the script static and
    # valid for every stack.
    has_fixture = ${if hasFixture then "True" else "False"}

    # The waits live inside the try so a boot-chain failure still gets a
    # journal dump instead of a bare stack trace.
    try:
        try:
            # 600s: the production NIC name (ens18) is absent here and its
            # device job times out at ~300s before multi-user settles.
            services_vm.wait_for_unit("multi-user.target", timeout=600)
        except Exception:
            # Boot never settled: name the job holding it before failing.
            print(services_vm.execute(
                "systemctl list-jobs --no-pager; systemctl --failed --no-pager"
            )[1])
            raise
        if has_fixture:
            services_vm.wait_for_unit("stack-env-publish.service")
        # The compose files attach to the external 'homelab' network; its
        # unit is wantedBy multi-user.target independently of the masked
        # bootstrap-komodo (it requires only docker.service).
        services_vm.wait_for_unit("docker-network-homelab.service")

        if has_fixture:
            with subtest("the fixture rendered to a root-only /run/stack-env file"):
                # Real sops-nix against the fixture: a stack whose env is
                # missing or readable beyond root is a deploy failure before
                # compose starts.
                services_vm.succeed("test -s /run/stack-env/${stack}.env")
                mode = services_vm.succeed(
                    "stat -c '%a %U' /run/stack-env/${stack}.env"
                ).strip()
                assert mode == "400 root", f"expected '400 root', got {mode!r}"

        with subtest("docker compose up --wait succeeds"):
            services_vm.succeed(
                "docker compose -f /srv/stacks/${stack}/compose.yaml "
                "-p ${stack} up -d --wait --wait-timeout 300"
            )

        with subtest("published ports answer on loopback and nowhere else"):
            # Positive control FIRST (immich/books precedent): without it, a
            # node-naming or routing regression makes every fail() below pass
            # vacuously. 22 is the one port the firewall opens.
            outsider.succeed("nc -z -w 5 services-vm 22")
            for port in ${builtins.toJSON hostPorts}:
                services_vm.wait_for_open_port(port, addr="127.0.0.1")
                outsider.fail(f"nc -z -w 5 services-vm {port}")

        with subtest("every container is running; healthchecked ones healthy"):
            # Inspected directly, not left to --wait: this asserts *running*
            # for EVERY container, so a stack with a legitimate restart:"no"
            # init one-shot needs a hand-written suite instead.
            ids = services_vm.succeed(
                "docker compose -f /srv/stacks/${stack}/compose.yaml "
                "-p ${stack} ps -aq"
            ).split()
            assert ids, "compose project ${stack} has no containers"
            for cid in ids:
                state = json.loads(
                    services_vm.succeed(f"docker inspect {cid}")
                )[0]["State"]
                assert state["Status"] == "running", (
                    f"container {cid} is {state['Status']}, expected running"
                )
                health = state.get("Health")
                if health is not None:
                    assert health["Status"] == "healthy", (
                        f"container {cid} health is {health['Status']}"
                    )
    except Exception:
        dump_diag()
        raise
  '';
}
