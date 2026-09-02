# journald log-driver suite — small, fast, and guarding the single widest
# contract in this repo.
#
# `virtualisation.docker.daemon.settings.log-driver = "journald"` in
# nixos/configuration.nix exists so stacks/logging's Alloy can collect the
# fleet's container output from the HOST JOURNAL through two read-only bind
# mounts, instead of being handed the docker socket. That is a hard rule from
# Idan, and the price of it is that container stdout no longer goes to
# json-file — which changes `docker logs`, and **131 call sites across tests/
# read `docker logs`**, many of them asserting on its CONTENT.
#
# So the switch is only safe if a specific set of properties holds, and each
# of them is a thing that fails SILENTLY if it does not. This suite pins them.
#
# Genuinely under test:
#   - **The daemon default is really journald**, read back from `docker info`
#     rather than from the Nix attribute. A `daemon.settings` typo produces a
#     valid config that docker ignores.
#   - **`docker logs` returns every line**, for a container that has already
#     EXITED — which is the shape most suites use (an init one-shot's output
#     read after it finished).
#   - **stdout and stderr stay demultiplexed.** The journald driver stores a
#     priority per entry and `docker logs` splits on it; if that broke, every
#     `docker logs X 2>/dev/null` in tests/ would silently start returning
#     stderr too, or nothing.
#   - **`CONTAINER_TAG` is the container NAME.** With no `tag` log-opt docker
#     uses the TRUNCATED CONTAINER ID, which changes on every
#     `docker compose up`. Alloy promotes this field to Loki's `container`
#     stream label, so the untagged version is both unqueryable and a
#     cardinality bomb — and it is also the field a future fail2ban-style
#     `journalmatch` on this host would key on.
#   - 🚨 **`services.journald.rateLimitBurst = 0` actually takes effect.**
#     This is the reason the suite exists. journald rate-limits PER SENDING
#     UNIT, and docker's journald driver submits from dockerd, so every
#     container in the fleet shares ONE bucket — at the systemd default,
#     10000 messages per 30 s between all of them. A dropped line does not
#     reach the journal at all, so `docker logs` cannot show it either:
#     measured on a host at the default burst, a container emitting 30000
#     lines was readable as **9994**, with no "Suppressed N messages" note
#     anywhere. That is an intermittent failure in whichever suite happened to
#     be grepping `docker logs` while another container was chatty, and it
#     would be blamed on the wrong stack every time. The 30000-line subtest
#     below fails if the setting is ever dropped or overridden.
#
# Documented gaps:
#   - **The VPS is not covered.** headscale-vps keeps json-file as its daemon
#     default and sets `logging: {driver: journald, options: {tag:
#     authentik-server}}` on the authentik container only; the
#     `fail2ban-journal-contract` lint is what pins that, and it is a
#     different mechanism from this one on purpose.
#   - **Alloy is not here.** Whether the journal is READ correctly is
#     stacks/logging's problem (`run.sh stack logging`), and whether entries
#     reach Loki is asserted by neither — see the note on the loki probe in
#     stacks/gatus/gatus.yaml. This suite is only about what the journald
#     driver does to `docker logs`.
#   - **No rotation pressure.** SystemMaxUse=2G is configured but never
#     filled here, so the interaction between journal rotation and a suite
#     reading `docker logs` of a long-lived container is untested.

{
  pkgs,
  lib,
  images,
  profiles,
  sopsModule,
  ...
}:

let
  # Already pinned for other suites; nothing here needs a specific image, only
  # a shell that can emit a lot of lines quickly.
  alpine = images."alpine_3_21";
in
pkgs.testers.runNixOSTest {
  name = "journald-logging";

  nodes.services =
    { ... }:
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
          images = [ alpine ];
          beforeUnits = [ "multi-user.target" ];
        })
      ];

      # Nothing container-shaped needs to run at boot: this suite starts its
      # own throwaway containers and never touches /srv.
      systemd.services.bootstrap-komodo.wantedBy = lib.mkForce [ ];
      # The new stack-git-sync timer would fail its clone every tick with no Forgejo here.
      systemd.timers.stack-git-sync.wantedBy = lib.mkForce [ ];
      systemd.tmpfiles.rules = [ "d /var/lib/sops-nix 0700 root root -" ];
    };

  testScript = ''
    IMG = "${alpine.finalImageName}:${alpine.finalImageTag}"

    start_all()
    services_vm.wait_for_unit("multi-user.target")
    services_vm.wait_for_unit("docker.service")

    with subtest("the daemon default really is journald"):
        # From the daemon, not from the Nix attribute: a misspelt key in
        # daemon.settings produces a daemon.json docker accepts and ignores.
        drv = services_vm.succeed(
            "docker info --format '{{.LoggingDriver}}'"
        ).strip()
        assert drv == "journald", (
            f"docker's default log driver is {drv!r}. stacks/logging's Alloy "
            f"reads the host journal and would collect nothing."
        )

    with subtest("journald rate limiting really is off"):
        conf = services_vm.succeed("cat /etc/systemd/journald.conf")
        assert "RateLimitBurst=0" in conf, (
            "RateLimitBurst is not 0. The whole fleet shares one bucket "
            "through docker.service, and dropped lines vanish from "
            "`docker logs` as well as from Loki.\n" + conf
        )

    with subtest("docker logs returns both streams, demultiplexed, after exit"):
        # The container has EXITED by the time these run — the shape every
        # init-one-shot assertion in tests/ uses.
        services_vm.succeed(
            f"docker run --name streams {IMG} sh -c "
            "'echo out-1; echo err-1 >&2; echo out-2; echo err-2 >&2'"
        )
        merged = services_vm.succeed("docker logs streams 2>&1")
        for want in ["out-1", "out-2", "err-1", "err-2"]:
            assert want in merged, f"{want} missing from:\n{merged}"

        # Note this asserts SEPARATION, not interleaving order. Under both
        # json-file and journald the CLI's stdout is block-buffered and its
        # stderr is not, so `2>&1` groups stdout ahead of stderr — that is a
        # property of the client, identical across drivers, and nothing in
        # tests/ depends on the relative order of the two streams.
        only_out = services_vm.succeed("docker logs streams 2>/dev/null")
        assert "err-1" not in only_out, (
            "stderr leaked into stdout — every `docker logs X 2>/dev/null` "
            "in tests/ now sees more than it did.\n" + only_out
        )
        only_err = services_vm.succeed("docker logs streams 2>&1 1>/dev/null")
        assert "out-1" not in only_err, only_err

    with subtest("CONTAINER_TAG is the container NAME, not its id"):
        # log-opts tag={{.Name}}. Without it this is the truncated container
        # id, which changes on every recreate — Alloy promotes this field to
        # Loki's `container` label.
        tag = services_vm.succeed(
            "journalctl CONTAINER_NAME=streams -o json --no-pager "
            "| head -1 | jq -r .CONTAINER_TAG"
        ).strip()
        assert tag == "streams", (
            f"CONTAINER_TAG is {tag!r}, expected the container name. "
            f"log-opts tag={{{{.Name}}}} is missing or not being applied."
        )

    with subtest("🚨 30000 lines all survive (the default burst loses 2/3)"):
        # Well over the systemd default of 10000 per 30 s, and emitted fast
        # enough to land inside one interval. On a host at that default this
        # same container is readable as ~9994 lines.
        services_vm.succeed(
            f"docker run --name flood {IMG} sh -c "
            "'i=1; while [ $i -le 30000 ]; do echo line-$i; i=$((i+1)); done'"
        )
        # docker run returns at container exit, but journald ingests dockerd's
        # writes asynchronously — under exactly this burst load `docker logs`
        # can briefly read back fewer lines. Poll until the count settles so a
        # timing flake cannot masquerade as a rateLimitBurst regression; a
        # count that PLATEAUS short still falls through to the assert below
        # with the config-regression message.
        try:
            services_vm.wait_until_succeeds(
                "[ $(docker logs flood 2>&1 | grep -c '^line-') -eq 30000 ]",
                timeout=60,
            )
        except Exception:
            pass  # the assert below reports the real count and the real cause
        n = int(services_vm.succeed(
            "docker logs flood 2>&1 | grep -c '^line-'"
        ).strip())
        assert n == 30000, (
            f"docker logs returned {n} of 30000 lines — journald dropped "
            f"{30000 - n}. services.journald.rateLimitBurst = 0 is not in "
            f"effect, and every content assertion on `docker logs` in tests/ "
            f"is now intermittently wrong."
        )
        # The tail specifically, so a truncation at the end cannot hide behind
        # a count that happens to add up.
        tail = services_vm.succeed("docker logs flood 2>&1 | tail -1").strip()
        assert tail == "line-30000", f"last line is {tail!r}"
  '';
}
