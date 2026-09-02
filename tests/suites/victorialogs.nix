# VictoriaLogs suite — the INGEST contract, which no generic machinery can
# see. `run.sh stack logging` proves the containers are healthy, the fixture
# decrypts and the publishes are loopback-only; every one of those held in the
# Loki era while a misconfigured collector forwarded ZERO lines — the alloy
# healthcheck comment in stacks/logging/compose.yaml named that gap loudly for
# months. This suite closes it: a real container writes a marker line and the
# suite polls the store's query API until the marker comes back, or the build
# is red.
#
# Genuinely under test:
#   - 🚨 **The whole pipeline**: container stdout -> docker's journald driver
#     -> the host journal -> Alloy's two read-only mounts -> the loki push
#     protocol -> VictoriaLogs -> a LogsQL query. Any silent-zero failure —
#     the `path`/machine-id matrix, a `user:` on alloy, a wrong sink URL, a
#     label mapping regression — fails HERE, as a missing marker.
#   - **The label contract**: the marker comes back with job=systemd-journal
#     (the relabel-rule-not-labels-argument gotcha), unit=docker.service,
#     container=<the NAME, not an id> — and with `level` as a plain field
#     that is NOT in `_stream`, pinning the sink URL's `_stream_fields` list.
#   - **The retention flags in the RUNNING process argv**, read from
#     /proc/<pid>/cmdline rather than from the compose file: the 100GiB cap
#     (`-retention.maxDiskSpaceUsageBytes=100GiB`) is the reason this store
#     replaced Loki, and a dropped or typo'd flag is a silent
#     keep-everything-forever.
#   - **The gatus probe semantics**: /health answers a literal "OK", and an
#     empty query result is HTTP 200 with a ZERO-BYTE body — the property the
#     recommended ingest probe's `len([BODY]) > 0` condition depends on.
#   - **Grafana stays healthy OFFLINE with the datasource plugin ABSENT.**
#     The victoriametrics-logs-datasource plugin is a one-time operator
#     download (compose.yaml documents it), so every VM boot and every fresh
#     host runs plugin-less for a while — this pins that Grafana provisions
#     the unknown-type datasource, starts, and reports database ok anyway
#     (measured against 13.2.0 before it was relied on).
#
# Documented gaps:
#   - **Retention ENFORCEMENT is not exercised.** Filling 100 GiB inside a VM
#     is not a fast suite; what is asserted is the flag in the live argv. That
#     the flag then drops the oldest per-day partitions is upstream's
#     documented contract, not ours to re-prove per build.
#   - **The plugin-present path is not tested here** — offline, so the plugin
#     cannot be fetched. Datasource health against a live store was measured
#     by hand (2026-09-02, grafana:13.2.0 + plugin v0.31.0 + this pinned
#     image: "Data source is working"); in production it is a human check
#     after the one-time install.
#   - **`docker logs` behaviour under the journald driver** is
#     journald-logging.nix's territory, not duplicated here.

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
    images."victoriametrics_victoria-logs_v1_52_0"
    images."grafana_alloy_v1_19_2"
    images."grafana_grafana_13_2_0"
    images."alpine_3_21"
  ];

  alpine = images."alpine_3_21";

  # The real stack directory plus the fixture, exactly as mk-stack-suite
  # seeds it: the committed .sops.env is encrypted to the production
  # recipient (undecryptable here), so the fixture stands in and the real
  # decrypt path still runs.
  seedSrv = pkgs.runCommand "srv-seed-logging" { } ''
    mkdir -p $out/stacks/logging
    cp -r ${../../stacks/logging}/. $out/stacks/logging/
    chmod -R u+w $out/stacks/logging
    rm -f $out/stacks/logging/.env
    rm -f $out/stacks/logging/.sops.env $out/stacks/logging/.sops.env.example
    cp ${../fixtures/logging.sops.env} $out/stacks/logging/.sops.env
  '';
in
pkgs.testers.runNixOSTest {
  name = "victorialogs";

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
            memoryMB = 3072;
            diskMB = 8192;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            beforeUnits = [ "multi-user.target" ];
          })
        ];

        systemd.services.bootstrap-komodo.wantedBy = lib.mkForce [ ];
        # The stack-git-sync timer would fail its clone every tick with no Forgejo here.
        systemd.timers.stack-git-sync.wantedBy = lib.mkForce [ ];

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
          # Volume roots with the ownership the DIR_NOTES table in
          # nixos/generate-stack-dirs.py declares (the generic stack suite
          # reads the generated stack-dirs.nix instead; hardcoded here so
          # this suite states its assumptions in-line):
          #   victorialogs  root — image config User "0" (read from the
          #                 pinned image; NOT loki's 10001)
          #   alloy         root — no USER in the image, and root is what
          #                 reads the journal
          #   grafana       472 — grafana.db must be creatable on first start
          "d /mnt/slow/victorialogs 0755 root root -"
          "d /mnt/fast/alloy 0755 root root -"
          "d /mnt/fast/grafana 0755 472 472 -"
        ];

        systemd.services.seed-srv = {
          description = "Seed /srv with the logging stack (test only)";
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
  };

  # No outsider node: loopback-only publishing for 10455/10456 is asserted by
  # the generic stackChecks."logging" suite, which probes every published
  # port from a second machine. This suite only adds what that one cannot.
  testScript = ''
    import json
    import urllib.parse

    COMPOSE = "docker compose -f /srv/stacks/logging/compose.yaml -p logging"
    VL = "http://127.0.0.1:10456"
    IMG = "${alpine.finalImageName}:${alpine.finalImageTag}"

    # One query helper used throughout: LogsQL over the loopback publish —
    # the same surface the recommended gatus ingest probe uses.
    def q(logsql, limit=10):
        return (
            f"curl -fsS --max-time 30 '{VL}/select/logsql/query"
            f"?query={urllib.parse.quote(logsql)}&limit={limit}'"
        )

    def dump_diag():
        for label, cmd in [
            ("compose ps", f"{COMPOSE} ps -a || true"),
            ("compose logs", f"{COMPOSE} logs --tail=100 || true"),
            ("decrypt-sops-envs journal",
             "journalctl -u decrypt-sops-envs --no-pager -o cat | tail -20"),
            ("docker journal",
             "journalctl -u docker --no-pager -o cat | tail -30"),
        ]:
            print(f"=== {label} ===")
            print(services_vm.execute(cmd)[1])

    start_all()

    try:
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_for_unit("docker.service")
        services_vm.wait_for_unit("docker-network-homelab.service")
        # The fixture must decrypt before grafana can seed its admin user.
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/logging/.env", timeout=90
        )

        with subtest("docker compose up --wait succeeds"):
            # --wait gates on alloy's and grafana's healthchecks and on
            # victorialogs reaching `running` (it has no healthcheck and can
            # have none — asserted below). Waiting on the PROJECT is fine;
            # only NAMING a healthcheck-less service in a health condition
            # errors (finding #42).
            services_vm.succeed(
                f"{COMPOSE} up -d --wait --wait-timeout 300"
            )

        with subtest("victorialogs has NO healthcheck, and that is pinned"):
            # The image is distroless: one static binary, no shell, no wget,
            # no curl — a HEALTHCHECK here would have to be a lie (the loki
            # and gatus precedent). Pinned so nobody "adds the missing
            # healthcheck" against an image that cannot run one.
            out = services_vm.succeed(
                "docker inspect --format '{{json .Config.Healthcheck}}' victorialogs"
            ).strip()
            assert out in ("null", "{}"), f"victorialogs grew a healthcheck: {out}"

        with subtest("/health answers OK — the gatus liveness probe contract"):
            body = services_vm.succeed(
                f"curl -fsS --max-time 10 {VL}/health"
            ).strip()
            assert body == "OK", f"/health said {body!r}, gatus asserts == 200 on it"

        with subtest("🚨 the retention flags are in the RUNNING argv"):
            # From /proc of the live process, not from the compose file: this
            # is the store's whole retention config (there is no config
            # file), and the 100GiB cap is the reason the store was swapped.
            # A dropped flag is a silent keep-everything-forever.
            pid = services_vm.succeed(
                "docker inspect --format '{{.State.Pid}}' victorialogs"
            ).strip()
            argv = services_vm.succeed(
                f"tr '\\0' '\\n' < /proc/{pid}/cmdline"
            ).splitlines()
            for want in [
                "-retention.maxDiskSpaceUsageBytes=100GiB",
                "-retentionPeriod=1y",
                "-storageDataPath=/victoria-logs-data",
            ]:
                assert want in argv, f"{want} missing from live argv: {argv}"

        with subtest("🚨 a container's stdout is queryable in the store"):
            # THE assertion this suite exists for: the full chain from a
            # container write to a query hit. In the Loki era every link of
            # this chain could break silently behind green healthchecks.
            services_vm.succeed(
                f"docker run --name vl-marker {IMG} "
                "echo VLSUITE-MARKER-CONTAINER-7391"
            )
            services_vm.wait_until_succeeds(
                q("VLSUITE-MARKER-CONTAINER-7391", limit=5)
                + " | grep -q VLSUITE-MARKER-CONTAINER-7391",
                timeout=120,
            )

        with subtest("the marker carries the fleet's label contract"):
            raw = services_vm.succeed(q("VLSUITE-MARKER-CONTAINER-7391", limit=5))
            entry = json.loads(raw.splitlines()[0])
            # job comes from the relabel RULE (the `labels` argument silently
            # loses to the component default — the measured alloy gotcha).
            assert entry.get("job") == "systemd-journal", entry
            # dockerd is the submitting unit for every container line.
            assert entry.get("unit") == "docker.service", entry
            # The container NAME, not a truncated id — the tag={{.Name}}
            # daemon setting reaching all the way through.
            assert entry.get("container") == "vl-marker", entry
            # level arrives as a PLAIN field (echo to stdout is priority
            # info)...
            assert entry.get("level") == "info", entry
            # ...and is NOT stream-defining: the sink URL's _stream_fields
            # pins streams to job,unit,container,host. If level ever shows up
            # in _stream, someone widened that list — a cardinality decision
            # this assert makes explicit instead of silent.
            assert 'container="vl-marker"' in entry.get("_stream", ""), entry
            assert "level=" not in entry.get("_stream", ""), entry

        with subtest("a non-container journal entry arrives too"):
            # Host services (sshd, timers, the decrypt unit) share the same
            # pipeline; systemd-cat writes straight to the journal with no
            # docker involved. No `unit` assertion — a backdoor-spawned
            # command's _SYSTEMD_UNIT is a test-harness artifact.
            services_vm.succeed("systemd-cat -t vlsuite echo VLSUITE-MARKER-JOURNAL-4482")
            services_vm.wait_until_succeeds(
                q("VLSUITE-MARKER-JOURNAL-4482", limit=5)
                + " | grep -q VLSUITE-MARKER-JOURNAL-4482",
                timeout=120,
            )

        with subtest("an empty result is 200 with a zero-byte body"):
            # The recommended gatus ingest probe conditions on
            # `len([BODY]) > 0`; that only detects a dead pipeline if a
            # no-match query really returns NOTHING with a success status.
            # Pinned here so a store upgrade that starts returning `{}` or a
            # 204 breaks this suite, not silently the probe.
            out = services_vm.succeed(
                q("VLSUITE-NO-SUCH-MARKER-0000", limit=5) + " | wc -c"
            ).strip()
            assert out == "0", f"no-match query returned {out} bytes, expected 0"

        with subtest("data really lands under /mnt/slow/victorialogs"):
            # Proves -storageDataPath and the bind mount agree: per-day
            # partitions appear under the host directory the retention cap,
            # the du-quota alarm and NOT_BACKED_UP all reason about.
            services_vm.succeed(
                "test -n \"$(ls /mnt/slow/victorialogs/partitions 2>/dev/null)\""
            )

        with subtest("vmui answers — the documented plugin-less stopgap UI"):
            services_vm.succeed(
                f"curl -fsS -o /dev/null --max-time 10 {VL}/select/vmui/"
            )

        with subtest("🚨 grafana is healthy OFFLINE with the plugin ABSENT"):
            # The datasource plugin is a one-time operator download
            # (compose.yaml documents it), so a fresh host and every VM run
            # plugin-less. This pins the load-bearing measurement: Grafana
            # provisions a datasource of an uninstalled type, starts, and
            # /api/health reports a real database ok. First prove the plugin
            # truly is absent, so this subtest cannot rot into testing the
            # other path.
            services_vm.succeed(
                "test -z \"$(docker exec grafana ls /var/lib/grafana/plugins 2>/dev/null)\""
            )
            health = json.loads(services_vm.succeed(
                "curl -fsS --max-time 10 http://127.0.0.1:10455/api/health"
            ))
            assert health.get("database") == "ok", health

        with subtest("the datasource provisioning file is mounted and names the plugin type"):
            # What this proves: the file reached the container read-only at
            # the path Grafana scans, declaring the victoriametrics type.
            # What it CANNOT prove offline: that queries work — that needs
            # the plugin, measured by hand and documented in compose.yaml.
            ds = services_vm.succeed(
                "docker exec grafana cat /etc/grafana/provisioning/datasources/victorialogs.yaml"
            )
            assert "victoriametrics-logs-datasource" in ds, ds
            assert "http://victorialogs:9428" in ds, ds
    except Exception:
        dump_diag()
        raise
  '';
}
