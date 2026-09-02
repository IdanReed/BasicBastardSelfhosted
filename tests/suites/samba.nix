# Samba suite — hand-written, for two independent reasons: `network_mode: host`
# makes the stack invisible to mk-stack-suite's port probe (it derives its list
# from `ports:`, so a host-networked service passes with an empty set), and
# samba-init is a one-shot that must exit, which the generic harness asserts
# against.
#
# The organising idea, same as beszel's: the healthcheck cannot see any of the
# things that actually go wrong here. It is an ANONYMOUS `smbclient -L
# \\localhost -U % -m SMB3` — a real SMB3 round trip, which is unusually
# honest — but anonymous means it proves smbd is listening and speaking SMB3
# and NOTHING about whether any user can log in. And underneath it, the
# generated [global] carries `map to guest = bad user` with
# `guest account = nobody`: a user missing from the passdb is mapped to GUEST
# rather than rejected. So a failed `smbpasswd -a -s` produces a green
# container serving a share that only the share-level `valid users` keeps
# anyone out of.
#
# Genuinely under test:
#   - 🚨 **An authenticated write/read round trip.** Not the health status.
#   - 🚨 **A wrong password for an EXISTING user is REFUSED.** The highest-value
#     assertion in the set: it is the only one that distinguishes "the user was
#     created" from "the user was silently mapped to guest". A negative run
#     against a NONEXISTENT username would test the guest mapping instead, and
#     would pass either way.
#   - 🚨 **The uid contract, measured.** config.yml creates the SMB user as
#     1000:1000 inside the container; the tmpfiles rule owns the directory on
#     the host; nothing connects them. Write over SMB, stat on the host.
#   - 🚨 **The exposure decision, from both sides.** smbd IS listening on the
#     LAN interface and the FIREWALL is what stops the outsider — asserted
#     separately, because "outsider cannot connect" alone would also pass if
#     smbd had failed to bind at all. Then 445 is opened at runtime and the
#     outsider completes a full authenticated round trip, which turns "the
#     firewall is the only thing in the way" from an inference into a
#     measurement.
#   - **samba-init refuses all three ways it can**: empty password, an
#     interface list without `lo`, and a share directory whose ownership
#     disagrees with config.yml. Each of those, unguarded, produces a server
#     that looks fine and is not (or, for `lo`, looks dead and is fine).
#
# Documented gaps:
#   - **Reachability over the tailnet**, which is how it will actually be used.
#     Needs a real headscale; `run.sh tailnet` is where that lives.
#   - **Avahi/wsdd2 discovery.** Off by decision, so there is nothing to test.
#     If the firewall is ever opened for LAN clients, this suite gains the
#     inverse assertions.
#   - **SMB1 being refused.** `server min protocol = SMB3_00` is set; proving
#     it needs a client that will speak SMB1, and modern smbclient will not.

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
    images."alpine_3_21"
    images."crazymax_samba_4_23_8"
  ];

  fixture = ../fixtures/samba.sops.env;

  seedSrv = pkgs.runCommand "srv-seed-samba" { } ''
    mkdir -p $out/stacks/samba
    cp -r ${../../stacks/samba}/. $out/stacks/samba/
    chmod -R u+w $out/stacks/samba
    rm -f $out/stacks/samba/.env
    rm -f $out/stacks/samba/.sops.env.example $out/stacks/samba/.sops.env
    cp ${fixture} $out/stacks/samba/.sops.env
  '';

  # /mnt tmpfiles rules, read from the SAME generated file the real host
  # imports (nixos/stack-dirs.nix) rather than hand-copied. The 1000:1000 on
  # .../shared IS the thing the uid subtest measures, so a drifted copy would
  # make the suite assert its own fixture (the class ledger #77 fixed in
  # mk-stack-suite). Only the test-only /srv and sops-nix rules stay literal
  # below.
  stackMntRoots = [
    "/mnt/fast/samba"
    "/mnt/slow/samba"
  ];
  stackDirRules = (import ../../nixos/stack-dirs.nix).systemd.tmpfiles.rules;
  rulePath = r: lib.elemAt (lib.splitString " " r) 1;
  missingRoots = lib.filter (root: !(lib.any (r: rulePath r == root) stackDirRules)) stackMntRoots;
  mntRules =
    if missingRoots == [ ] then
      lib.filter (
        r: lib.any (root: root == rulePath r || lib.hasPrefix (root + "/") (rulePath r)) stackMntRoots
      ) stackDirRules
    else
      throw (
        "samba suite: nixos/stack-dirs.nix has no rule for "
        + lib.concatStringsSep ", " missingRoots
        + " — re-run nixos/generate-stack-dirs.sh or fix stackMntRoots"
      );
in
pkgs.testers.runNixOSTest {
  name = "samba";

  globalTimeout = 2400;

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
            memoryMB = 2048;
            diskMB = 8192;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            beforeUnits = [ "multi-user.target" ];
          })
        ];

        systemd.services.bootstrap-komodo.wantedBy = lib.mkForce [ ];
        # stack-git-sync would fail its clone every tick with no Forgejo here.
        systemd.timers.stack-git-sync.wantedBy = lib.mkForce [ ];
        virtualisation.cores = lib.mkForce 2;

        # 🚨 REAL DISKS for the two tiers, not tmpfs, and the reboot subtest is
        # why. On the services VM /mnt/fast is a partition that survives a
        # reboot; as tmpfs it is wiped, which takes /data — and therefore
        # samba's passdb and /var/lib/samba/private — with it. Restarting the
        # existing container then fails with
        #
        #   directory_create_or_exist: mkdir failed on directory
        #   /var/lib/samba/private/msg.sock: No such file or directory
        #
        # because the image symlinks that path into /data and the entrypoint
        # does not rebuild the tree for a container it has already
        # initialised. That is a real behaviour, but it is the behaviour of
        # LOSING THE DATA DISK — not of rebooting — so asserting it here would
        # be asserting the wrong thing, and asserting persistence on tmpfs is
        # impossible. Real disks make the subtest mean what it says.
        virtualisation.emptyDiskImages = [
          1024
          2048
        ];

        virtualisation.fileSystems = {
          "/srv" = {
            device = "tmpfs";
            fsType = "tmpfs";
            options = [ "mode=0755" ];
          };
          "/mnt/fast" = {
            device = "/dev/vdb";
            fsType = "ext4";
            autoFormat = true;
          };
          "/mnt/slow" = {
            device = "/dev/vdc";
            fsType = "ext4";
            autoFormat = true;
          };
        };

        # The /mnt rules come from generated nixos/stack-dirs.nix (see the
        # let-binding above); only the test-only rules are literal here.
        systemd.tmpfiles.rules = [
          "d /srv/stacks 0755 1000 1000 -"
          "d /var/lib/sops-nix 0700 root root -"
        ]
        ++ mntRules;

        systemd.services.seed-srv = {
          description = "Seed /srv with the samba stack (test only)";
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
          samba
        ];
      };

    # The LAN neighbour. Needs a real SMB client, not just nc: the whole point
    # is an authenticated protocol round trip.
    outsider =
      { pkgs, ... }:
      {
        environment.systemPackages = [ pkgs.samba ];
      };
  };

  testScript = ''
    SMB = "docker compose -f /srv/stacks/samba/compose.yaml -p samba"
    USER = "idan"
    PASSWORD = "test_samba_password_not_secret"

    def dump_diag():
        for label, cmd in [
            ("compose ps", f"{SMB} ps -a"),
            ("init logs", "docker logs samba-init 2>&1 | tail -30"),
            ("samba logs", "docker logs samba 2>&1 | tail -40"),
            ("smb.conf", "docker exec samba cat /etc/samba/smb.conf 2>&1"),
            ("listeners", "ss -tlnp | grep -E '445|139' || true"),
            ("share", "ls -la /mnt/slow/samba/shared"),
        ]:
            print(f"--- {label} ---")
            print(services_vm.execute(cmd)[1])

    start_all()

    services_vm.wait_for_unit("multi-user.target")
    services_vm.wait_for_unit("docker-network-homelab.service")
    services_vm.wait_for_unit("load-test-images.service")
    outsider.wait_for_unit("network.target")

    try:
        with subtest("the fixture .sops.env decrypted to a 0600 .env"):
            # NOT wait_for_unit: decrypt-sops-envs is a transient oneshot
            # with no RemainAfterExit (a minutely timer re-fires it), so
            # waiting on the UNIT races its inactive-after-success state and
            # fails with "inactive and there are no pending jobs". The
            # artifact it must produce is the synchronisation point (see
            # mk-stack-suite).
            services_vm.wait_until_succeeds(
                "test -s /srv/stacks/samba/.env", timeout=90
            )
            mode = services_vm.succeed("stat -c %a /srv/stacks/samba/.env").strip()
            assert mode == "600", f".env is mode {mode}, expected 600"

        with subtest("the stack comes up: samba-init then samba"):
            # No `--wait`: samba-init is a one-shot that must EXIT, and
            # `up --wait` fails on an exited service (finding #39).
            services_vm.succeed(f"{SMB} up -d")
            services_vm.wait_until_succeeds(
                "test \"$(docker inspect -f '{{.State.Health.Status}}' "
                "samba)\" = healthy",
                timeout=180,
            )
            out = services_vm.succeed("docker logs samba-init 2>&1")
            assert "CHANGE:" not in out, f"the guard mutated something: {out}"
            assert "done" in out, out

        with subtest("smbclient -L lists exactly the expected shares"):
            # Cheap, and it catches a config.yml that failed to parse — the
            # image's `yq | jq` pipeline swallows errors with 2>/dev/null, so a
            # broken config produces a server with no shares rather than an
            # error.
            out = services_vm.succeed(
                f"smbclient -L //127.0.0.1 -U '{USER}%{PASSWORD}' -m SMB3 2>&1"
            )
            assert "shared" in out, out
            for unexpected in ["homes", "printers", "print$"]:
                assert unexpected not in out, f"unexpected share {unexpected}:\n{out}"

        with subtest("🚨 an authenticated write/read round trip"):
            services_vm.succeed("echo 'samba-round-trip-canary' > /tmp/up.txt")
            services_vm.succeed(
                f"smbclient //127.0.0.1/shared -U '{USER}%{PASSWORD}' -m SMB3 "
                "-c 'put /tmp/up.txt canary.txt'"
            )
            services_vm.succeed(
                f"smbclient //127.0.0.1/shared -U '{USER}%{PASSWORD}' -m SMB3 "
                "-c 'get canary.txt /tmp/down.txt'"
            )
            services_vm.succeed("cmp /tmp/up.txt /tmp/down.txt")

        with subtest("🚨 the uid contract, measured rather than reasoned"):
            # config.yml creates the SMB user as 1000:1000 with `adduser -u`
            # INSIDE the container; the host directory's ownership comes from a
            # tmpfiles rule in a different file. Nothing connects them, and a
            # mismatch is not a crash — it is files nothing else in the fleet
            # can read.
            owner = services_vm.succeed(
                "stat -c '%u:%g' /mnt/slow/samba/shared/canary.txt"
            ).strip()
            assert owner == "1000:1000", (
                f"file written over SMB is owned by {owner}, expected 1000:1000"
            )

        with subtest("🚨 a wrong password for an EXISTING user is REFUSED"):
            # THE assertion this suite exists for. `map to guest = bad user`
            # means a user missing from the passdb becomes a guest rather than
            # a rejection, so a positive test built on anonymous access passes
            # even when user creation failed silently. Note the username must
            # EXIST — a negative run against a nonexistent name tests the guest
            # mapping, not the credential.
            rc, out = services_vm.execute(
                f"smbclient //127.0.0.1/shared -U '{USER}%wrong-password' "
                "-m SMB3 -c 'ls' 2>&1"
            )
            assert rc != 0, f"a wrong password was ACCEPTED:\n{out}"
            assert "LOGON_FAILURE" in out or "ACCESS_DENIED" in out, out

        with subtest("🚨 guest access to the share is refused"):
            rc, out = services_vm.execute(
                "smbclient //127.0.0.1/shared -U '%' -m SMB3 -c 'ls' 2>&1"
            )
            assert rc != 0, f"anonymous access to the share succeeded:\n{out}"

        with subtest("🚨 smbd IS bound to the LAN nic — the firewall is the boundary"):
            # Asserted separately from the outsider's failure below, because
            # "the outsider cannot connect" would also pass if smbd had failed
            # to bind at all — which is exactly the mistake SAMBA_INTERFACES
            # invites. Proving the listener exists first makes the next
            # subtest mean what it says.
            listeners = services_vm.succeed("ss -tln '( sport = :445 )'")
            assert "445" in listeners, listeners

        with subtest("🚨 445 is NOT reachable from the LAN (tailnet-only)"):
            ip = services_vm.succeed(
                "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
            ).strip()
            outsider.fail(f"nc -z -w 5 {ip} 445")
            outsider.succeed(f"ping -c1 -W5 {ip} >/dev/null")

        with subtest("opening 445 makes the LAN round trip work — measured"):
            # Turns "the firewall is the only thing in the way" from an
            # inference into a fact, and pre-verifies the LAN-NAS variant that
            # is queued as an operator decision. The rule is added at runtime
            # and NOT committed: the shipped posture is tailnet-only.
            ip = services_vm.succeed(
                "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
            ).strip()
            services_vm.succeed(
                "iptables -I nixos-fw 1 -p tcp --dport 445 -j nixos-fw-accept"
            )
            outsider.succeed("echo 'from-the-lan' > /tmp/lan.txt")
            outsider.succeed(
                f"smbclient //{ip}/shared -U '{USER}%{PASSWORD}' -m SMB3 "
                "-c 'put /tmp/lan.txt lan.txt'"
            )
            services_vm.succeed("test -f /mnt/slow/samba/shared/lan.txt")
            services_vm.succeed("iptables -D nixos-fw -p tcp --dport 445 -j nixos-fw-accept")
            outsider.fail(f"nc -z -w 5 {ip} 445")

        with subtest("🚨 samba-init refuses an empty password"):
            # Unguarded this is the worst shape in the stack: the image
            # substitutes "", smbpasswd fails, the user never enters the
            # passdb, and the container reports HEALTHY forever because its
            # probe is anonymous.
            rc, out = services_vm.execute(
                "docker run --rm --name bkg-smb-nopw "
                "-e SAMBA_INTERFACES='lo eth1' "
                "-v /srv/stacks/samba/samba-init.sh:/init.sh:ro "
                "-v /mnt/slow/samba/shared:/share "
                "alpine:3.21 /bin/sh /init.sh 2>&1"
            )
            assert rc != 0, f"the guard accepted an empty password:\n{out}"
            assert "SAMBA_IDAN_PASSWORD" in out, out

        with subtest("🚨 samba-init refuses an interface list without lo"):
            # The inverse failure: smbd would not listen on loopback, the
            # healthcheck dials \\localhost, and the container goes
            # permanently unhealthy WHILE EVERY REAL CLIENT WORKS.
            rc, out = services_vm.execute(
                "docker run --rm --name bkg-smb-nolo "
                f"-e SAMBA_IDAN_PASSWORD='{PASSWORD}' "
                "-e SAMBA_INTERFACES='eth1' "
                "-v /srv/stacks/samba/samba-init.sh:/init.sh:ro "
                "-v /mnt/slow/samba/shared:/share "
                "alpine:3.21 /bin/sh /init.sh 2>&1"
            )
            assert rc != 0, f"the guard accepted an interface list without lo:\n{out}"
            assert "lo" in out, out

        with subtest("🚨 samba-init refuses a share it would write unreadably"):
            services_vm.succeed("mkdir -p /tmp/wrongowner && chown 4242:4242 /tmp/wrongowner")
            rc, out = services_vm.execute(
                "docker run --rm --name bkg-smb-uid "
                f"-e SAMBA_IDAN_PASSWORD='{PASSWORD}' "
                "-e SAMBA_INTERFACES='lo eth1' "
                "-v /srv/stacks/samba/samba-init.sh:/init.sh:ro "
                "-v /tmp/wrongowner:/share "
                "alpine:3.21 /bin/sh /init.sh 2>&1"
            )
            assert rc != 0, f"the guard accepted a uid mismatch:\n{out}"
            assert "4242" in out, out

        with subtest("the share survives a reboot"):
            # shutdown()+start(), not reboot(): qemu runs with -no-reboot.
            # /mnt/fast and /mnt/slow are real ext4 disks here (see the node
            # config), so this asserts persistence rather than re-creation.
            services_vm.succeed("test -f /mnt/slow/samba/shared/canary.txt")
            services_vm.shutdown()
            services_vm.start()
            services_vm.wait_for_unit("multi-user.target")
            services_vm.wait_for_unit("load-test-images.service")
            services_vm.succeed(f"{SMB} up -d")
            services_vm.wait_until_succeeds(
                "test \"$(docker inspect -f '{{.State.Health.Status}}' "
                "samba)\" = healthy",
                timeout=180,
            )
            # The user is re-created from config.yml on every start — that is
            # what makes a password rotation `sopsedit` plus a restart — so a
            # login after a reboot is not redundant with the one above.
            services_vm.succeed(
                f"smbclient //127.0.0.1/shared -U '{USER}%{PASSWORD}' -m SMB3 "
                "-c 'ls' >/dev/null"
            )
            # And the data is still there, which is the half a login cannot
            # prove on its own.
            services_vm.succeed("test -f /mnt/slow/samba/shared/canary.txt")
    except Exception:
        dump_diag()
        raise
  '';
}
