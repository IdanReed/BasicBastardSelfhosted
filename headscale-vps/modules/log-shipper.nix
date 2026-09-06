{ config, pkgs, lib, ... }:

# Ships this host's journal to the services VM's VictoriaLogs, so that the
# VPS's auth surface is visible somewhere other than an SSH session.
#
# WHY THIS EXISTS. fail2ban and Authentik's reputation policy are the two
# layers guarding the only publicly reachable login surfaces the fleet has
# (configuration.nix's jails; authentik/blueprints/custom/login-hardening.yaml).
# Both are *enforcement*. Neither is *observation*: a ban is one NOTICE line in
# this host's journal, and until this module existed the only ways to see it
# were `fail2ban-client status` over SSH and `journalctl -u fail2ban` — no
# history beyond the journal's own byte cap, no query, and nothing at all if
# you are not already logged in. Meanwhile the fleet has had a log store and a
# Grafana in front of it since 2026-09 (stacks/logging/) that this host simply
# never reached, because stacks/logging/config.alloy reads ONE host's journal:
# the services VM's own.
#
# So this is the second collector that config.alloy's `host` relabel rule was
# written for ("One value today; it stays correct if a second collector is
# ever pointed at this store"). The label schema below is deliberately
# byte-identical to that file's, so both hosts land in one queryable namespace
# and `host` is what tells them apart.
#
# 🚨 NATIVE SYSTEMD UNIT, NOT A CONTAINER, and the reason is the same one that
# makes headscale native here (modules/headscale.nix): the moments this is
# worth having are the moments something is broken, and dockerd is a thing
# that breaks. A container would also need the /var/log/journal + /etc/machine-id
# bind mounts that stacks/logging/config.alloy documents at length; a unit with
# SupplementaryGroups=systemd-journal (which the nixpkgs module already sets)
# needs neither. Note this is NOT the socket taboo from the services VM —
# nothing here goes anywhere near /var/run/docker.sock, and it must not.
#
# The transport contract, which lives in three files that nothing else links
# (the vlogs-ingest-contract lint in tests/lib/lints.nix is what keeps them
# honest):
#   1. here                          — the sink URL + bearer token
#   2. stacks/caddy/Caddyfile        — the vlogs-ingest vhost that terminates it
#   3. secrets-gen/manifest.yaml     — VLOGS_INGEST_TOKEN as a cross-host twin

let
  # The ingest vhost on the services VM. Deliberately its OWN hostname rather
  # than a path on an existing one: the wildcard cert covers it for free, and
  # separating it is what lets the Caddy route expose ONLY the push endpoint.
  # VictoriaLogs has no auth of its own — its /select/* query API and its
  # /internal/* maintenance endpoints sit on the same port as this push — so
  # "which paths does the vhost answer" IS the authorization model.
  #
  # Resolves publicly (the *.svc.idanreed.com A record points at the services
  # VM's tailnet IP, a CGNAT address routable only from inside the tailnet), so
  # no headscale extra_records entry and no /etc/hosts line is needed here.
  ingestHost = "vlogs-ingest.svc.idanreed.com";

  # 🚨 MUST MATCH stacks/logging/config.alloy's sink, `_stream_fields` included.
  # That list decides which pushed labels define a VictoriaLogs *stream*; two
  # collectors pushing the same label set with different _stream_fields would
  # split one logical stream in two and make cross-host queries lie.
  ingestPath = "/insert/loki/api/v1/push";
  streamFields = "job,unit,container,host";

  tokenFile = config.sops.secrets.VLOGS_INGEST_TOKEN.path;
in
{
  # ---------------------------------------------------------------------------
  # The shared ingest token
  # ---------------------------------------------------------------------------
  # 🚨 GROUP-READABLE, NOT OWNER-READABLE, and that is forced by the nixpkgs
  # alloy module: it runs the unit with DynamicUser=true, so there is no stable
  # username to hand to sops-nix's `owner`. A static group the dynamic user is
  # added to below is the supported way through. mode 0440 keeps it off every
  # other account on the box.
  #
  # sops-nix decrypts during ACTIVATION (system.activationScripts.setupSecrets),
  # not from a unit, so this file is on disk before alloy.service is ever
  # started — including on the first boot after an install.
  users.groups.vlogs-ingest = { };

  sops.secrets.VLOGS_INGEST_TOKEN = {
    group = config.users.groups.vlogs-ingest.name;
    mode = "0440";
  };

  # ---------------------------------------------------------------------------
  # Alloy
  # ---------------------------------------------------------------------------
  services.alloy = {
    enable = true;

    # configPath defaults to /etc/alloy, and the module wires every *.alloy
    # file in that directory into reloadTriggers — so `nixos-rebuild switch`
    # reloads the collector in place instead of restarting it. Left at the
    # default on purpose; pointing it at a store path would cost that.

    extraFlags = [
      # Both are Alloy's own defaults, pinned because neither is harmless to
      # inherit. The storage path is where the WAL below lives, and Alloy's
      # default is RELATIVE to the working directory ("data-alloy/") — under a
      # DynamicUser unit that is not a durable location. StateDirectory=alloy
      # (set by the nixpkgs module) gives us /var/lib/alloy; name it explicitly
      # so the WAL survives a restart, which is the entire point of having one.
      "--storage.path=/var/lib/alloy/data"

      # The UI/metrics listener. Loopback because the firewall in
      # ../configuration.nix opens 22/80/443 and nothing else — but a default
      # that silently became 0.0.0.0 would publish this host's component graph,
      # and the firewall would be the only thing between it and the internet.
      "--server.http.listen-addr=127.0.0.1:12345"
    ];
  };

  systemd.services.alloy = {
    # 🚨 LIST-VALUED, SO THIS MERGES rather than replaces: NixOS's `unitOption`
    # type concatenates lists across definitions, so the module's own
    # SupplementaryGroups=[ "systemd-journal" ] survives and the unit ends up in
    # both groups. Losing the journal group is the silent-zero failure —
    # a healthy Alloy reading nothing — so tests/suites/vps.nix asserts lines
    # were actually read rather than trusting this merge.
    serviceConfig.SupplementaryGroups = [ config.users.groups.vlogs-ingest.name ];

    # Ordering only, and deliberately NOT a `requires`: the sink is across the
    # tailnet, so at boot Alloy will fail its first pushes no matter what we
    # order against. The WAL is the real answer to that (see below), and a hard
    # dependency would only mean the collector is DOWN while the tailnet is,
    # which is precisely the window whose logs are worth keeping.
    after = [ "tailscaled.service" ];

    # This host's failure notifier (../configuration.nix). Alloy dying is
    # invisible by construction — the symptom is an absence of logs, in the
    # place you would go to look for the absence — so it gets the same
    # treatment as caddy/headscale/authentik. The Gatus side of the same gap is
    # the "victorialogs (vps ingest)" probe in stacks/gatus/gatus.yaml, which
    # alerts on the stream going quiet rather than on the unit dying.
    onFailure = [ "notify-failure@%n.service" ];
  };

  # ---------------------------------------------------------------------------
  # The collector config
  # ---------------------------------------------------------------------------
  # environment.etc rather than a store path, per the module's own guidance:
  # it is what makes config reload (rather than restart) possible.
  environment.etc."alloy/config.alloy".text = ''
    // Generated from headscale-vps/modules/log-shipper.nix — edit there.
    //
    // The label schema and the journal-reading notes here are a deliberate
    // mirror of stacks/logging/config.alloy. Read that file for the empirical
    // work behind them (the path/machine-id silent-zero matrix, the
    // relabel-rule-not-labels-argument gotcha, the cardinality argument for
    // each label); this comment records only what DIFFERS on this host.

    // -------------------------------------------------------------------------
    // Source: the host journal
    // -------------------------------------------------------------------------
    loki.source.journal "host" {
      // Explicit, and load-bearing for the same reason as on the services VM:
      // without it the reader filters on its own /etc/machine-id. That happens
      // to be the right id for a native unit (no container, no synthetic id),
      // so unlike the containerised collector this host would survive the
      // omission — which is exactly why it is written down rather than relied
      // on. services.journald.storage = "persistent" in ../configuration.nix
      // is what guarantees the directory has anything in it.
      path          = "/var/log/journal"
      relabel_rules = loki.relabel.journal.rules
      forward_to    = [loki.write.default.receiver]

      // Cold-start replay bound, same value as the services VM.
      max_age = "12h"

      // No `labels` argument — see the services VM's config for the measured
      // reason (it loses to the component's own default `job` when
      // relabel_rules are set). `job` is set by a relabel rule below.
    }

    // -------------------------------------------------------------------------
    // Relabelling
    // -------------------------------------------------------------------------
    // 🚨 IDENTICAL TO stacks/logging/config.alloy, ON PURPOSE. Both hosts push
    // into one store; a label promoted on one side and not the other makes
    // every fleet-wide query quietly host-specific.
    loki.relabel "journal" {
      forward_to = []

      rule {
        target_label = "job"
        replacement  = "systemd-journal"
      }

      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label  = "unit"
      }

      // Container name. Sparser here than on the services VM and that is
      // correct, not a bug: this host's docker runs Authentik only, and the
      // journald driver is NixOS's dockerd default (../configuration.nix
      // documents why json-file log-opts are fatal here), so CONTAINER_NAME is
      // present for the containers that use it and absent for everything else.
      // An absent source label simply does not set the target label.
      rule {
        source_labels = ["__journal_container_name"]
        target_label  = "container"
      }

      rule {
        source_labels = ["__journal_priority_keyword"]
        target_label  = "level"
      }

      // 🚨 THE LABEL THIS WHOLE MODULE TURNS ON. Until now every stream in the
      // store carried the services VM's hostname; this is what makes
      // host="headscale-vps" a thing you can query, and it is the selector the
      // Grafana dashboard and the Gatus freshness probe both key on.
      rule {
        source_labels = ["__journal__hostname"]
        target_label  = "host"
      }
    }

    // -------------------------------------------------------------------------
    // Sink: the services VM's VictoriaLogs, through its Caddy
    // -------------------------------------------------------------------------
    // 🚨 THROUGH CADDY, NOT DIRECTLY AT :10456. VictoriaLogs publishes on the
    // services VM's LOOPBACK only, and that stays true — the loopback-only
    // publish is asserted generically for every stack (tests/lib/mk-stack-suite.nix)
    // and re-binding it to the tailnet would hand every tailnet peer an
    // unauthenticated read/write API over the whole fleet's logs. The vhost in
    // stacks/caddy/Caddyfile exposes exactly one path and demands the token
    // below.
    //
    // Not `import protected` on that vhost, and the Caddyfile says so at
    // length: a forward-auth 302 on a push endpoint is silently discarded
    // telemetry. Machine ingest gets a bearer token; browsers get Authentik.
    loki.write "default" {
      endpoint {
        url = "https://${ingestHost}${ingestPath}?_stream_fields=${streamFields}"

        // Read from the file, never inlined: this config lands world-readable
        // in /etc, and the vps suite asserts the token string does not appear
        // in it. sops-nix delivers the file at activation (see above).
        bearer_token_file = "${tokenFile}"

        // Same reasoning as the services VM: a 429 is backpressure, and the
        // one moment this pipeline earns its keep is the moment it is being
        // asked to carry a burst.
        retry_on_http_429 = true
      }

      // 🚨 WORTH MORE HERE THAN ON THE SERVICES VM. There, a WAL covers a store
      // restart. Here it also covers the tailnet itself being down — and the
      // tailnet's control plane is THIS host, so "headscale is broken" is both
      // the most likely outage and the one whose logs you most want afterwards.
      // Without this, that outage erases its own evidence.
      wal {
        enabled = true
      }
    }

    // -------------------------------------------------------------------------
    // Alloy's own diagnostics
    // -------------------------------------------------------------------------
    // Straight to the journal (systemd captures stdout), which loki.source.journal
    // above then reads — so Alloy's own logs ship by the same path as
    // everything else, and a shipper that is failing to ship says so in the
    // place you can still read: `journalctl -u alloy`.
    //
    // ⚠ THAT IS A FEEDBACK LOOP WHILE THE SINK IS DOWN, observed while
    // watching the vps suite (whose sink is unreachable by design): each failed
    // batch logs one "error sending batch, will retry" WARN, which lands in the
    // journal, which this collector then reads and queues. It is bounded and
    // deliberately left alone — the retry backs off, and journald's
    // SystemMaxUse=512M in ../configuration.nix caps the journal regardless —
    // but it is the reason `level` stays at info rather than debug here. At
    // debug the same loop carries an order of magnitude more per retry.
    logging {
      level  = "info"
      format = "logfmt"
    }
  '';
}
