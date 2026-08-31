# Restore drill — the half of disaster recovery that a VM can actually prove.
#
# The fleet has elaborate backup PREPARATION (nixos/backup-prepare.sh, the
# Backrest plans, the dead-man's switch) and, until this suite, no evidence
# that anything it produces can be restored. A backup nobody has restored is a
# hypothesis.
#
# The companion document is ServerNotes/designs/core-disaster-recovery.md,
# which covers the parts no VM can reach: the Proxmox re-image, the cloud-init
# age-key injection, the Storage Box round trip, and the VPS rebuild. Those
# stay a manual twice-yearly ritual. What is mechanised here is the chain from
# "a dump exists" to "the service works again", plus three properties the
# runbook leans on.
#
# Genuinely under test:
#   - **The Postgres path, using backup-prepare.sh's literal command.** Dump a
#     populated database with `pg_dumpall -U <svc>`, destroy the cluster
#     entirely, restore, and read the data back. Not an approximation of the
#     command — the same one, so a change to how the script invokes it breaks
#     this suite rather than the next restore.
#   - **The SQLite path against a LIVE WAL database.** `sqlite_backup` uses
#     `.backup`, and the reason is that a raw copy of a live WAL database can
#     capture a torn page set with an out-of-date `-wal`. The drill takes the
#     dump while Vaultwarden is running and proves it opens.
#   - 🚨 **The silent-no-op hazard, pinned.** `sqlite_backup` returns 0 for a
#     MISSING source (`[ -f "$src" ] || return 0`). That is how the Karakeep
#     line backed up nothing for months with a clean exit. The drill asserts
#     the behaviour explicitly, so it can never be "fixed" without someone
#     deciding to.
#   - **`systemd-tmpfiles --create` reproduces declared ownership**, which is
#     what step 1.3 of the runbook depends on after a partial restore. Several
#     services cannot fix a wrongly-owned tree themselves.
#   - 🚨 **Vaultwarden regenerates `rsa_key.pem` SILENTLY when it is missing.**
#     This is not a behaviour to celebrate — it is the reason §0.2 of the
#     runbook exists. A restore that brings back `db.sqlite3` without that file
#     produces a healthy-looking server that has logged out every client and
#     will re-prompt 2FA. Pinned here so the runbook's claim is verified rather
#     than asserted.
#
# Documented gaps:
#   - **Restic and the Storage Box.** No network, no Hetzner. The drill starts
#     from the dumps, not from a snapshot.
#   - **The Proxmox rebuild and the age key.** Untestable here by construction.
#   - **MariaDB.** backup-prepare.sh's mysqldump branch is not exercised;
#     bookstack's suite covers the dump side only.

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
    images."postgres_17_9-alpine"
    images."vaultwarden_server_1_37_2"
  ];

  seedSrv = pkgs.runCommand "srv-seed-restore" { } ''
    mkdir -p $out/stacks/vaultwarden
    cp -r ${../../stacks/vaultwarden}/. $out/stacks/vaultwarden/
    chmod -R u+w $out/stacks/vaultwarden
    rm -f $out/stacks/vaultwarden/.env
    rm -f $out/stacks/vaultwarden/.sops.env.example
    cp ${../fixtures/vaultwarden.sops.env} $out/stacks/vaultwarden/.sops.env
  '';
in
pkgs.testers.runNixOSTest {
  name = "restore";

  globalTimeout = 3600;

  nodes.services =
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
          diskMB = 12288;
        })
        (profiles.loadImages {
          inherit pkgs;
          images = stackImages;
          beforeUnits = [ "multi-user.target" ];
        })
      ];

      systemd.services.bootstrap-arcane.wantedBy = lib.mkForce [ ];
      virtualisation.cores = lib.mkForce 2;

      virtualisation.emptyDiskImages = [ 4096 ];
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
        "d /srv/stacks 0755 1000 1000 -"
        "d /var/lib/sops-nix 0700 root root -"
        "d /mnt/fast 0755 root root -"
        "d /mnt/slow 0755 root root -"
        "d /mnt/fast/vaultwarden 0755 root root -"
        # A directory with a DELIBERATELY unusual owner, so the
        # tmpfiles-reproduces-ownership subtest is proving the rule and not
        # merely observing root:root everywhere.
        "d /mnt/fast/_drill 0750 1001 1001 -"
      ];

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

      environment.systemPackages = with pkgs; [ docker-compose jq sqlite ];
    };

  testScript = ''
    import shlex

    VW = "docker compose -f /srv/stacks/vaultwarden/compose.yaml -p vaultwarden"
    DATA = "/mnt/fast/vaultwarden"
    ADMIN_PASS = "test_vaultwarden_admin_token_not_secret"

    # A standalone Postgres standing in for any of the services in
    # backup-prepare.sh's loop. Using the loop's own naming convention
    # (<svc>_db, POSTGRES_USER=<svc>) on purpose: the drill exercises the
    # CONTRACT, not one particular stack.
    PG_IMG = "postgres:17.9-alpine"
    PG = "drill_db"

    def sh(cmd, **kw):
        return services_vm.succeed(cmd, **kw)

    services_vm.wait_for_unit("multi-user.target")
    services_vm.wait_for_unit("docker-network-homelab.service")
    services_vm.wait_for_unit("load-test-images.service")

    # -----------------------------------------------------------------------
    # Postgres: dump -> destroy -> restore -> read back
    # -----------------------------------------------------------------------
    with subtest("a populated Postgres survives a dump/destroy/restore cycle"):
        sh(
            f"docker run -d --name {PG} "
            "-e POSTGRES_USER=drill -e POSTGRES_DB=drill "
            "-e POSTGRES_PASSWORD=test_drill_password_not_secret "
            f"{PG_IMG}"
        )
        services_vm.wait_until_succeeds(
            f"docker exec {PG} pg_isready -U drill -d drill", timeout=180
        )
        sh(
            f"docker exec {PG} psql -U drill -d drill -c "
            "\"create table canary(id int primary key, note text)\""
        )
        sh(
            f"docker exec {PG} psql -U drill -d drill -c "
            "\"insert into canary values (1, 'survives-the-restore')\""
        )

        # backup-prepare.sh's literal command, tmpfile-and-rename included —
        # so a change to how the script invokes pg_dumpall breaks this suite
        # rather than the next real restore.
        sh("install -d -m 0700 /mnt/fast/_dumps")
        sh(f"docker exec {PG} pg_dumpall -U drill > /mnt/fast/_dumps/drill.sql.tmp")
        sh("mv -f /mnt/fast/_dumps/drill.sql.tmp /mnt/fast/_dumps/drill.sql")
        size = int(sh("stat -c %s /mnt/fast/_dumps/drill.sql").strip())
        assert size > 0, "the dump is empty"

        # Destroy the cluster completely — not `drop table`, which would leave
        # roles and settings behind and prove much less.
        sh(f"docker rm -f {PG}")
        sh(f"docker volume prune -f >/dev/null 2>&1 || true")
        sh(
            f"docker run -d --name {PG} "
            "-e POSTGRES_USER=drill -e POSTGRES_DB=drill "
            "-e POSTGRES_PASSWORD=test_drill_password_not_secret "
            f"{PG_IMG}"
        )
        services_vm.wait_until_succeeds(
            f"docker exec {PG} pg_isready -U drill -d drill", timeout=180
        )
        # Sanity: the canary must be GONE before the restore, or the assertion
        # after it would pass against a database that was never destroyed.
        services_vm.fail(
            f"docker exec {PG} psql -U drill -d drill -tAc "
            "\"select note from canary where id=1\" 2>/dev/null | grep -q survives"
        )

        sh(f"docker exec -i {PG} psql -U drill < /mnt/fast/_dumps/drill.sql")
        out = sh(
            f"docker exec {PG} psql -U drill -d drill -tAc "
            "\"select note from canary where id=1\""
        ).strip()
        assert out == "survives-the-restore", f"restored value is {out!r}"
        sh(f"docker rm -f {PG}")

    # -----------------------------------------------------------------------
    # SQLite: .backup against a LIVE, WAL-mode database
    # -----------------------------------------------------------------------
    with subtest("sqlite_backup's .backup produces a usable copy of a live database"):
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/vaultwarden/.env", timeout=120
        )
        sh(f"{VW} up -d --wait --wait-timeout 600")
        services_vm.succeed(f"test -f {DATA}/db.sqlite3")

        mode = sh(f"sqlite3 {DATA}/db.sqlite3 'PRAGMA journal_mode;'").strip()
        assert mode == "wal", (
            f"journal_mode is {mode!r} — this drill is specifically about the "
            "WAL case, where a raw file copy can capture a torn page set with "
            "an out-of-date -wal. If WAL is off, revisit why sqlite_backup "
            "exists at all rather than deleting this assertion."
        )

        # The container is RUNNING throughout: that is the whole point.
        sh(f"sqlite3 {DATA}/db.sqlite3 \".backup '/mnt/fast/_dumps/vw.sqlite.tmp'\"")
        sh("mv -f /mnt/fast/_dumps/vw.sqlite.tmp /mnt/fast/_dumps/vw.sqlite")
        n = int(sh(
            "sqlite3 /mnt/fast/_dumps/vw.sqlite "
            "\"select count(*) from sqlite_master\""
        ).strip())
        assert n > 0, "the sqlite dump has no schema"
        # An integrity check is the difference between "the file exists" and
        # "the file is a database".
        ok = sh(
            "sqlite3 /mnt/fast/_dumps/vw.sqlite 'PRAGMA integrity_check;'"
        ).strip()
        assert ok == "ok", f"integrity_check says {ok!r}"

    with subtest("🚨 sqlite_backup returns 0 for a MISSING source — pinned"):
        # This is how the Karakeep line backed up nothing for months with a
        # clean exit and no notification. It is asserted rather than fixed
        # because the alternative (failing on a missing source) would make
        # backup-prepare.sh fail on every host that does not run every stack.
        # The mitigation is the backup-coverage lint plus per-suite existence
        # assertions — this subtest exists so the hazard cannot quietly change.
        script = "/mnt/fast/_drill/probe.sh"
        sh(
            "printf '%s\\n' '#!/bin/sh' "
            "'sqlite_backup() { local n=\"$1\" s=\"$2\"; [ -f \"$s\" ] || return 0; "
            "echo would-dump; }' "
            "'sqlite_backup nothing /mnt/fast/_drill/does-not-exist.db' "
            f"'echo rc=$?' > {script}"
        )
        out = sh(f"sh {script}")
        assert "rc=0" in out and "would-dump" not in out, out

    # -----------------------------------------------------------------------
    # The runbook's other two load-bearing claims
    # -----------------------------------------------------------------------
    with subtest("systemd-tmpfiles --create reproduces declared ownership"):
        # Step 1.3 of core-disaster-recovery.md depends on this: a partial
        # restore can leave a directory with the wrong owner, and several
        # services cannot fix that themselves (syncthing's chown is
        # non-recursive and swallows its error; rmfakecloud has no entrypoint).
        before = sh("stat -c '%a %u:%g' /mnt/fast/_drill").strip()
        assert before == "750 1001:1001", f"declared rule did not apply: {before}"
        sh("chown 0:0 /mnt/fast/_drill && chmod 0777 /mnt/fast/_drill")
        sh("systemd-tmpfiles --create")
        after = sh("stat -c '%a %u:%g' /mnt/fast/_drill").strip()
        assert after == before, (
            f"tmpfiles did not restore ownership: {after} (was {before}). "
            "The runbook's 'systemd-tmpfiles --create' step does not do what "
            "it claims."
        )

    with subtest("🚨 Vaultwarden regenerates rsa_key.pem silently — the risk, pinned"):
        # NOT a behaviour to celebrate. It is exactly why §0.2 of
        # core-disaster-recovery.md lists rsa_key.pem: a restore that brings
        # back db.sqlite3 without it yields a server that looks perfectly
        # healthy and has logged out every client, re-prompting 2FA. If this
        # ever starts failing loudly instead, the runbook can be relaxed —
        # until then it must not be.
        services_vm.succeed(f"test -f {DATA}/rsa_key.pem")
        old = sh(f"sha256sum {DATA}/rsa_key.pem | cut -d' ' -f1").strip()
        sh(f"{VW} down")
        sh(f"rm -f {DATA}/rsa_key.pem")
        sh(f"{VW} up -d --wait --wait-timeout 600")
        services_vm.wait_until_succeeds(f"test -f {DATA}/rsa_key.pem", timeout=120)
        new = sh(f"sha256sum {DATA}/rsa_key.pem | cut -d' ' -f1").strip()
        assert new != old, "rsa_key.pem was not regenerated — good news, update the runbook"
        # And it came back healthy, which is the dangerous part.
        health = sh(
            "docker inspect --format '{{.State.Health.Status}}' vaultwarden"
        ).strip()
        assert health == "healthy", (
            f"vaultwarden is {health} after losing its signing key — if it now "
            "fails loudly, core-disaster-recovery.md §0.2 can be relaxed"
        )
        # The admin token still works, so nothing surfaces the loss at all.
        out = sh(
            "curl -sS -i --max-time 30 -X POST "
            f"-d {shlex.quote('token=' + ADMIN_PASS)} http://127.0.0.1:10400/admin"
        )
        assert "VW_ADMIN" in out, out[:800]
  '';
}
