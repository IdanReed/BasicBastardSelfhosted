# One fast suite per stack, generated from the stack's own compose file.
#
#   nix-build tests -A stackChecks.<name>
#
# The point is iteration speed on a SINGLE stack: boot the real services VM
# config, seed only that stack into /srv/stacks, `docker compose up --wait`
# it, and assert the things every stack must get right — env decryption,
# loopback-only publishing, containers actually healthy.
#
# ZERO per-stack maintenance, by construction: the images to preload, the
# ports to probe and the /mnt volume roots to create are all derived at eval
# time from stacks/<name>/compose.yaml itself. Adding a stack to
# `stackChecks` in ../default.nix is one list entry; if its images are not
# pinned yet, evaluation throws and tells you to run tests/update-images.sh.
#
# What this deliberately does NOT cover (see ../suites/services-vm.nix for
# all of it): the arcane boot chain, Caddy routing, the notify-failure path,
# cross-stack interactions, SSH, and reboot convergence. This suite trades
# that breadth for booting one stack in the time the full suite spends
# loading images.

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

  # -------------------------------------------------------------------------
  # Eval-time compose parse
  # -------------------------------------------------------------------------
  # A line-oriented regex scan, not a YAML parser. That is enough because the
  # stack conventions (CLAUDE.md) keep compose files flat: one `image:` per
  # service, list-form `ports:` and `volumes:`. A stack that strays far
  # enough from the conventions to defeat this parse should get a hand-written
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

  # Host-published ports, forms `127.0.0.1:P:C` and `P:C` (with optional
  # quotes and /tcp|/udp). Group 1 is the host port either way. Every stack
  # publishes on 127.0.0.1 by convention; a bare `P:C` still yields a
  # loopback listener to probe plus the outsider negative. That negative
  # verifies firewall posture only (nothing but 22 open to the LAN), NOT
  # loopback-only binding: an accidental 0.0.0.0 publish is still dropped by
  # the firewall here, and the real exposure — 0.0.0.0 reachable through the
  # trusted tailscale0 — is untestable in this suite because the VM never
  # joins a tailnet.
  hostPorts = map lib.toInt (
    lib.unique (
      # trailing comment tolerated (POSIX ERE: plain group, not (?:...))
      matchAll "[[:space:]]*-[[:space:]]*[\"']?(127\\.0\\.0\\.1:)?([0-9]+):([0-9]+)(/tcp|/udp)?[\"']?[[:space:]]*(#.*)?" 1
    )
  );

  # Bind-mount sources under /mnt. The real host has these created by
  # hardware-configuration.nix tmpfiles / earlier runs; in the VM they must
  # exist before compose up or Docker creates them root-owned at mount time
  # anyway — creating them explicitly keeps the suite honest about which
  # paths the stack expects, and a typo'd volume path shows up as a probe of
  # a directory nothing writes to. Relative (./file) and non-/mnt mounts are
  # left to the seeded stack directory and the base system respectively.
  mntPaths = lib.unique (matchAll "[[:space:]]*-[[:space:]]*[\"']?(/mnt/[^:\"']+):.*" 0);

  # -------------------------------------------------------------------------
  # Volume-root OWNERSHIP, from the generated table — not from root:root
  # -------------------------------------------------------------------------
  # This used to be `map (p: "d ${p} 0755 root root -") mntPaths`, which is
  # the one ownership this fleet has been bitten by four times: root:root is
  # ALSO docker's create-on-mount default, so a suite that hardcodes it is not
  # neutral — it silently reproduces the bug that nixos/stack-dirs.nix exists
  # to prevent, and then reports the stack healthy because the two images
  # already in `stackChecks` happen to run as root.
  #
  # Any stack whose image drops privileges (loki 10001, grafana 472,
  # mosquitto 1883, docspace 104:107, mysql 999 ...) therefore could not pass
  # this harness at all — measured, not inferred: with root-owned volume roots
  # loki and grafana both restart-loop within seconds. Reading the SAME
  # generated file the real host imports fixes that and costs nothing: it is a
  # plain attrset of rule strings, and `stack-dirs-generated` already
  # byte-compares it against a fresh run of the generator.
  #
  # Parents come along because the generator emits a rule for each one (a
  # parent tmpfiles creates implicitly gets the DEFAULT ownership, not the
  # rule's), so `/mnt/slow/books/library` also brings `/mnt/slow/books`.
  #
  # Zero behaviour change for the stacks already here: ntfy's three rules are
  # root:root and util has no /mnt binds at all.
  stackDirRules = (import ../../nixos/stack-dirs.nix).systemd.tmpfiles.rules;
  rulePath = r: lib.elemAt (lib.splitString " " r) 1;
  # Is `dir` this path or an ancestor of it?
  covers = dir: p: p == dir || lib.hasPrefix (dir + "/") p;
  mntRules = lib.filter (r: lib.any (covers (rulePath r)) mntPaths) stackDirRules;

  # A bind source with no rule of its own would fall back to whatever tmpfiles
  # gives an undeclared path — the silent case again. The generator refuses to
  # emit without a STACK_NOTES entry, so this can only fire if the two parsers
  # disagree about a path, and then it should fire loudly at eval.
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

  # -------------------------------------------------------------------------
  # Image pins
  # -------------------------------------------------------------------------
  # Every compose ref must have a content-addressed pin in images.nix — the
  # suites run offline, so an unpinned image cannot be pulled at runtime and
  # the failure would otherwise surface minutes into a VM boot instead of at
  # eval.
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

  # -------------------------------------------------------------------------
  # /srv seed
  # -------------------------------------------------------------------------
  fixture = ../fixtures + "/${stack}.sops.env";
  hasFixture = builtins.pathExists fixture;

  # Only this stack is seeded — the whole point is not booting the others.
  # The stack's real .sops.env (if committed) is encrypted to the production
  # recipient, which the throwaway test key cannot decrypt, so it is dropped
  # and the fixture stands in. decrypt-sops-envs.service then runs the real
  # sops CLI against it, so decryption, mode and the '$'-quoting path are
  # still exercised for real whenever a fixture exists.
  seedSrv = pkgs.runCommand "srv-seed-${stack}" { } ''
    mkdir -p $out/stacks/${stack}
    cp -r ${composeDir}/. $out/stacks/${stack}/
    chmod -R u+w $out/stacks/${stack}
    # The working-tree cp -r can capture a developer's locally-decrypted
    # plaintext .env (gitignored on purpose) in the world-readable store.
    rm -f $out/stacks/${stack}/.env
    rm -f $out/stacks/${stack}/.sops.env.example $out/stacks/${stack}/.sops.env
    ${lib.optionalString hasFixture ''
      cp ${fixture} $out/stacks/${stack}/.sops.env
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

        # Keep Arcane out of the boot path: its multi-hundred-MB image and
        # bootstrap ordering are irrelevant to iterating on one stack, and
        # they dominate this suite's runtime if left in.
        #
        # Coverage lost: the decrypt-sops-envs -> docker-network-homelab ->
        # bootstrap-komodo chain and Arcane itself. That is exactly what
        # checks.services exists to cover — run it before trusting a change
        # to anything in that chain.
        systemd.services.bootstrap-komodo.wantedBy = lib.mkForce [ ];
        # The new stack-git-sync timer would fail its clone every tick with no Forgejo here.
        systemd.timers.stack-git-sync.wantedBy = lib.mkForce [ ];

        # decrypt-sops-envs.service `requires = srv.mount`; without a real
        # mount unit it never starts. tmpfs gives a genuine .mount unit, and
        # /mnt/{fast,slow} back whatever volume roots the compose file names.
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
          # Volume roots for this stack, with the REAL ownership from
          # nixos/stack-dirs.nix (see the derivation above). Generic on
          # purpose, so a new stack works without touching the harness — and
          # correct on purpose, so a stack whose image is not root is tested
          # against the ownership it will actually get.
        ]
        ++ checkedMntRules;

        # Populate /srv before decrypt-sops-envs reads it; on the real host
        # Arcane's git sync plays this role.
        systemd.services.seed-srv = {
          description = "Seed /srv with the ${stack} stack (test only)";
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
            ("decrypt-sops-envs journal",
             "journalctl -u decrypt-sops-envs --no-pager -o cat | tail -20"),
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
        services_vm.wait_for_unit("multi-user.target")
        # Only wait on decrypt-sops-envs when a fixture was seeded. (The old
        # rationale about the unit exiting 1 on an empty /srv is obsolete —
        # the per-file-accumulating rewrite ends with an explicit exit status
        # and succeeds with zero .sops.env files, as the forgejo suite's
        # no-failed-units sweep demonstrates — but the wait is still only
        # *meaningful* when this stack actually has secrets to decrypt.)
        if has_fixture:
            # Transient oneshot now (a minutely timer re-fires it), so
            # wait_for_unit would race its inactive-after-success state.
            # The artifact it must produce is the synchronisation point.
            services_vm.wait_until_succeeds(
                "test -s /srv/stacks/${stack}/.env", timeout=90
            )
        # The compose files attach to the external 'homelab' network; its
        # unit is wantedBy multi-user.target independently of the masked
        # bootstrap-komodo (it requires only docker.service).
        services_vm.wait_for_unit("docker-network-homelab.service")

        if has_fixture:
            with subtest("the fixture .sops.env decrypted to a 0600 .env"):
                # Real sops against the fixture: a stack whose .env is missing
                # or world-readable is a deploy failure before compose starts.
                services_vm.succeed("test -s /srv/stacks/${stack}/.env")
                mode = services_vm.succeed(
                    "stat -c '%a' /srv/stacks/${stack}/.env"
                ).strip()
                assert mode == "600", f"expected mode 600, got {mode}"

        with subtest("docker compose up --wait succeeds"):
            services_vm.succeed(
                "docker compose -f /srv/stacks/${stack}/compose.yaml "
                "-p ${stack} up -d --wait --wait-timeout 300"
            )

        with subtest("published ports answer on loopback and nowhere else"):
            for port in ${builtins.toJSON hostPorts}:
                services_vm.wait_for_open_port(port, addr="127.0.0.1")
                outsider.fail(f"nc -z -w 5 services-vm {port}")

        with subtest("every container is running; healthchecked ones healthy"):
            # --wait already gates on this, but inspect directly so a
            # container that flipped to restarting between --wait and here —
            # or a healthcheck that --wait's semantics glossed over — still
            # fails loudly. Note this asserts *running* for every container,
            # so a stack with a legitimate one-shot init container needs a
            # hand-written suite (as backrest has).
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
