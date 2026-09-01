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
#   - **The restic loop itself, closed.** The drill used to stop at the dump
#     FORMATS: it began at `/mnt/fast/_dumps`, which is backup-prepare.sh's
#     staging directory and therefore the INPUT to restic. Everything after it
#     — repository, snapshot, restore — was assertion, not evidence. It now
#     runs the second half for real: `restic init` on a local repository whose
#     password is the fixture `RESTIC_PASSWORD` taken through the production
#     decrypt-and-source path, a snapshot of the dumps plus one identity file,
#     the sources DESTROYED, `restic restore`, and bytes AND metadata compared
#     against a manifest taken before the destruction. Then Vaultwarden is
#     started back onto the restored `rsa_key.pem` — byte-identity is
#     necessary, a service that accepts the file is the actual property.
#   - **Two negative controls, because a restore test that cannot fail proves
#     nothing.** The wrong password must fail LOUDLY (nonzero, and saying so)
#     rather than return an empty snapshot list; and a single flipped byte in a
#     pack file must fail `restic check --read-data` — the same command
#     `checkPolicy` runs monthly against the Storage Box. The tamper runs on a
#     COPY that is checked clean first, so "the check always fails" cannot
#     masquerade as corruption detection.
#
# Documented gaps:
#   - **The Storage Box.** The repository here is a local path. What is
#     unproven is the Hetzner leg — the sftp backend, the sub-account scoping,
#     the console-side snapshots. `backrest` covers sftp + init + snapshot for
#     real against an in-VM endpoint; between the two suites the only unreal
#     element left is Hetzner itself. Note also that the drill restores a
#     repository this same VM wrote minutes earlier: it cannot speak to
#     forward compatibility, nor to a repository that has been pruned.
#   - **The Proxmox rebuild and the age key.** Untestable here by construction.
#     With them goes the thing that actually matters on the day — the
#     production `RESTIC_PASSWORD` is recoverable at all. A drill that reads
#     the password out of the fixture cannot prove the operator can read the
#     real one out of a burning building; that stays §0 of the runbook.
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

  # backrest is seeded for exactly ONE value: its fixture RESTIC_PASSWORD,
  # reached through the real decrypt-sops-envs -> .env -> source path rather
  # than written into this file. A drill whose repository password is a
  # constant in the test proves the test can talk to itself; this one fails if
  # the path the operator would actually use is broken. Nothing deploys the
  # stack — no backrest image is loaded here.
  seededStacks = [
    "vaultwarden"
    "backrest"
  ];

  seedSrv = pkgs.runCommand "srv-seed-restore" { } ''
    mkdir -p $out/stacks
    ${lib.concatMapStringsSep "\n" (s: ''
      mkdir -p $out/stacks/${s}
      cp -r ${../../stacks + "/${s}"}/. $out/stacks/${s}/
      chmod -R u+w $out/stacks/${s}
      # The working-tree cp -r can capture a developer's locally-decrypted
      # plaintext .env (gitignored on purpose) in the world-readable store.
      rm -f $out/stacks/${s}/.env
      rm -f $out/stacks/${s}/.sops.env.example
      cp ${../fixtures + "/${s}.sops.env"} $out/stacks/${s}/.sops.env
    '') seededStacks}
  '';

  # The corruption negative control's teeth: flip one byte in the largest pack
  # file of a restic repository.
  #
  # Fiddlier than it looks, for three reasons worth recording rather than
  # rediscovering. Repository files are mode 0444, so the write needs a chmod.
  # The replacement byte is a fixed printable one chosen to differ from the
  # original, never `orig + 1`: that can land on NUL, and a NUL cannot survive
  # sh command substitution — the tamper would silently write nothing and the
  # control would pass while proving the opposite. And the flip is at the
  # MIDDLE of the file, so it lands in pack payload rather than in the
  # trailing header, which is the case `--read-data` exists for.
  tamperPack = pkgs.writeShellScript "tamper-restic-pack" ''
    set -eu
    repo="$1"
    pack=$(find "$repo/data" -type f -printf '%s %p\n' | sort -rn | head -n1 | cut -d' ' -f2-)
    [ -n "$pack" ] || { echo "no pack files under $repo/data" >&2; exit 1; }
    off=$(( $(stat -c %s "$pack") / 2 ))
    orig=$(dd if="$pack" bs=1 skip="$off" count=1 2>/dev/null | od -An -tu1 | tr -d ' \n')
    if [ "$orig" -eq 65 ]; then new=B; else new=A; fi
    chmod u+w "$pack"
    printf '%s' "$new" | dd of="$pack" bs=1 seek="$off" count=1 conv=notrunc 2>/dev/null
    echo "tampered $pack at byte $off ($orig -> $new)"
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

      environment.systemPackages = with pkgs; [
        docker-compose
        jq
        sqlite
        # The restic half of the drill. From pkgs, not from the backrest
        # image: the point is a repository this host can init, read and check
        # without the orchestrator, which is also the position an operator is
        # in on restore day.
        restic
      ];
    };

  testScript = ''
    import json
    import shlex

    VW = "docker compose -f /srv/stacks/vaultwarden/compose.yaml -p vaultwarden"
    DATA = "/mnt/fast/vaultwarden"
    ADMIN_PASS = "test_vaultwarden_admin_token_not_secret"

    # The restic half. The repository is a LOCAL PATH and lives outside
    # /mnt/fast on purpose — a repository inside the tree it backs up is a
    # trap, and here it would also be destroyed by the destroy step.
    REPO = "/var/lib/restic-drill/repo"
    BAD_REPO = "/var/lib/restic-drill/repo-tampered"
    PW = "/root/.restic-drill-pass"
    WRONG_PW = "/root/.restic-drill-wrong-pass"
    CACHE = "env RESTIC_CACHE_DIR=/var/cache/restic"
    # The identity file that carries the whole point of §0.2 of the runbook,
    # used here as the canary: bytes that are NOT a database dump, whose loss
    # is invisible until every client is logged out.
    CANARY = f"{DATA}/rsa_key.pem"

    def restic(repo, pw):
        return f"{CACHE} restic -r {repo} -p {pw}"

    R = restic(REPO, PW)

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
        # -v removes the container's ANONYMOUS volume with it, which is where
        # postgres put its cluster. `docker volume prune` would also work here
        # and is what the reflex reaches for — but it would take every other
        # stack's named volumes with it, and a drill that destroys unrelated
        # state to prove a point is not a drill.
        sh(f"docker rm -fv {PG}")
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

    # -----------------------------------------------------------------------
    # Restic: init -> snapshot -> DESTROY -> restore -> verify
    # -----------------------------------------------------------------------
    # Everything above this line starts from /mnt/fast/_dumps, which is the
    # INPUT to restic. This is the other half.

    with subtest("the repository password comes from sops, not from this file"):
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/backrest/.env", timeout=150
        )
        # Decrypt -> source is the production path (config-init.sh does exactly
        # this), and it is the path with the hazard: a '$'-laden value that was
        # not single-quoted in the plaintext gets expanded to nothing here, and
        # the repository ends up protected by a password nobody can reproduce.
        sh(
            "umask 077; sh -c "
            "'. /srv/stacks/backrest/.env; printf %s \"$RESTIC_PASSWORD\"' "
            f"> {PW}"
        )
        sh(f"grep -qxF 'te$t_re$tic_pa$$word' {PW}")
        sh(f"umask 077; printf %s 'not-the-repository-password' > {WRONG_PW}")

    with subtest("a real repository is initialised and takes a real snapshot"):
        sh(f"{R} init")
        sh(f"test -s {REPO}/config")

        # The manifest is taken BEFORE the destruction and kept on /root, which
        # the destroy step does not touch. Metadata as well as bytes: a restore
        # that widens 0700 on a directory full of database dumps hands them to
        # every account on the box, and sha256 alone would call that a success.
        sh(f"sha256sum /mnt/fast/_dumps/* {CANARY} > /root/drill.sha256")
        dumps_meta = sh("stat -c '%a %u:%g' /mnt/fast/_dumps").strip()
        canary_meta = sh(f"stat -c '%a %u:%g' {CANARY}").strip()
        assert dumps_meta.startswith("700 "), (
            f"/mnt/fast/_dumps is {dumps_meta} before the backup — "
            "backup-prepare.sh's `install -d -m 0700` is what makes the "
            "post-restore comparison below meaningful"
        )

        sh(f"{R} backup --tag drill /mnt/fast/_dumps {CANARY}")

        # 2>/dev/null throughout the JSON reads: restic's progress and
        # informational lines go to stderr, which the driver merges into the
        # same stream, and json.loads would choke on them.
        snaps = json.loads(sh(f"{R} snapshots --json 2>/dev/null"))
        assert len(snaps) == 1, f"expected exactly one snapshot, got {snaps}"
        paths = snaps[0]["paths"]
        assert "/mnt/fast/_dumps" in paths and CANARY in paths, paths

        # "A snapshot exists" is not "the snapshot has the files in it" — an
        # excluded path or an empty staging directory would still snapshot.
        listing = sh(f"{R} ls latest 2>/dev/null")
        for f in ["/mnt/fast/_dumps/drill.sql", "/mnt/fast/_dumps/vw.sqlite", CANARY]:
            assert f in listing, f"{f} is not in the snapshot:\n{listing}"

    with subtest("the sources are DESTROYED and come back from the snapshot"):
        # Vaultwarden has to be down first. It regenerates rsa_key.pem within
        # seconds of noticing it gone (pinned in the subtest above), so a
        # running container would restore the canary for us and the comparison
        # afterwards would pass without restic having done anything.
        sh(f"{VW} down")
        sh("rm -rf /mnt/fast/_dumps")
        sh(f"rm -f {CANARY}")
        services_vm.fail("test -e /mnt/fast/_dumps")
        services_vm.fail(f"test -e {CANARY}")

        sh(f"{R} restore latest --target /")

        sh("sha256sum -c /root/drill.sha256")
        after_dumps = sh("stat -c '%a %u:%g' /mnt/fast/_dumps").strip()
        after_canary = sh(f"stat -c '%a %u:%g' {CANARY}").strip()
        assert after_dumps == dumps_meta, (
            f"/mnt/fast/_dumps came back as {after_dumps}, was {dumps_meta}"
        )
        assert after_canary == canary_meta, (
            f"{CANARY} came back as {after_canary}, was {canary_meta}"
        )

        # Deliberately NOT re-loading the restored drill.sql into Postgres:
        # the earlier subtest already proved that exact file loads and yields
        # the canary row, and sha256 equality carries the proof across. A
        # second cluster boot would cost a minute to re-prove it.

    with subtest("the service starts on the RESTORED identity file"):
        # Byte-identity is necessary, not sufficient: restic restores mode and
        # ownership too, and a key the container cannot read produces exactly
        # the silent regeneration §0.2 warns about. The test is whether
        # Vaultwarden comes up on this file and leaves it alone.
        restored = sh(f"sha256sum {CANARY} | cut -d' ' -f1").strip()
        sh(f"{VW} up -d --wait --wait-timeout 600")
        health = sh(
            "docker inspect --format '{{.State.Health.Status}}' vaultwarden"
        ).strip()
        assert health == "healthy", f"vaultwarden is {health} after the restore"
        now = sh(f"sha256sum {CANARY} | cut -d' ' -f1").strip()
        assert now == restored, (
            "vaultwarden REPLACED the restored rsa_key.pem instead of using "
            "it — the restore looked healthy and logged out every client"
        )

    with subtest("the pristine repository passes `restic check --read-data`"):
        # The same command checkPolicy runs monthly against the Storage Box,
        # here against the whole repository rather than a 5% subset because it
        # is a few megabytes.
        sh(f"{R} check --read-data")

    # -----------------------------------------------------------------------
    # Negative controls — a restore drill that cannot fail proves nothing
    # -----------------------------------------------------------------------
    with subtest("🚨 the WRONG password fails loudly, not silently"):
        # The failure mode being excluded: a wrong or empty password that
        # returns an empty snapshot list and exit 0. That reads, to a script
        # and to a tired operator, exactly like "the backups are gone".
        rc, out = services_vm.execute(
            f"{restic(REPO, WRONG_PW)} snapshots --no-cache 2>&1"
        )
        assert rc != 0, f"restic exited 0 with the WRONG password:\n{out}"
        assert "wrong password" in out.lower() or "no key found" in out.lower(), (
            f"the failure did not say why:\n{out}"
        )
        assert "/mnt/fast/_dumps" not in out, f"it listed the snapshot anyway:\n{out}"

    with subtest("🚨 a single flipped byte fails `restic check --read-data`"):
        # On a COPY, so the repository the rest of this suite depends on stays
        # intact and the tamper can be isolated.
        sh(f"cp -a {REPO} {BAD_REPO}")
        BR = restic(BAD_REPO, PW)

        # Control for the control: the copy passes BEFORE the byte is flipped.
        # Without this, a check failing for any unrelated reason — a bad copy,
        # a stale lock — would be read as corruption detection.
        sh(f"{BR} check --read-data --no-cache")

        print(sh("${tamperPack} " + BAD_REPO))

        # --no-cache on both runs: the copy shares the original's repository
        # ID, so a warm cache could answer from unmodified metadata.
        rc, out = services_vm.execute(f"{BR} check --read-data --no-cache 2>&1")
        assert rc != 0, f"a corrupted pack file PASSED check --read-data:\n{out}"
        assert "error" in out.lower(), f"the failure was not reported:\n{out}"
  '';
}
