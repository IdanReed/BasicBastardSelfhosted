{ config, pkgs, lib, ... }:

# Ships this host's journal to the services VM's VictoriaLogs, so the VPS's
# auth surface (every fail2ban ban, every authentik login_failed) is visible
# somewhere other than an SSH session.
#
# Native unit, not a container, for the same reason headscale is: the moments
# this is worth having are the moments something is broken, and dockerd is a
# thing that breaks. SupplementaryGroups=systemd-journal also saves the
# /var/log/journal + /etc/machine-id bind mounts a container would need.
#
# The transport contract spans three files nothing else links (the
# vlogs-ingest-contract lint keeps them honest): this module (sink URL +
# token), stacks/caddy/Caddyfile (the vhost that terminates it), and
# secrets-gen/manifest.yaml (VLOGS_INGEST_TOKEN as a cross-host twin).

let
  # Its own hostname rather than a path on an existing one: the wildcard cert
  # covers it for free, and separating it is what lets the Caddy route expose
  # ONLY the push endpoint. VictoriaLogs has no auth of its own — its
  # /select/* query API and /internal/* maintenance endpoints sit on the same
  # port — so "which paths does the vhost answer" IS the authorization model.
  ingestHost = "vlogs-ingest.svc.idanreed.com";

  # Must match stacks/logging/config.alloy's sink, _stream_fields included:
  # that list decides which labels define a VictoriaLogs stream, and two
  # collectors disagreeing would split one logical stream in two.
  ingestPath = "/insert/loki/api/v1/push";
  streamFields = "job,unit,container,host";

  tokenFile = config.sops.secrets.VLOGS_INGEST_TOKEN.path;
in
{
  # Ingest token
  # Group-readable, not owner-readable, because the nixpkgs alloy module runs
  # the unit with DynamicUser=true — there is no stable username to hand
  # sops-nix's `owner`. Decryption happens during activation, so the file
  # exists before alloy.service ever starts.
  users.groups.vlogs-ingest = { };

  sops.secrets.VLOGS_INGEST_TOKEN = {
    group = config.users.groups.vlogs-ingest.name;
    mode = "0440";
  };

  # Alloy
  services.alloy = {
    enable = true;

    # configPath is left at its /etc/alloy default on purpose: the module wires
    # every *.alloy file there into reloadTriggers, so a switch reloads the
    # collector in place instead of restarting it.

    extraFlags = [
      # Alloy's own defaults, pinned. The storage default is RELATIVE to the
      # working directory, which under DynamicUser is not durable — and the WAL
      # surviving a restart is the entire point of having one.
      "--storage.path=/var/lib/alloy/data"

      # Loopback: a default that silently became 0.0.0.0 would leave the
      # firewall as the only thing between this host's component graph and the
      # internet.
      "--server.http.listen-addr=127.0.0.1:12345"
    ];
  };

  systemd.services.alloy = {
    # List-valued, so this MERGES: the module's own
    # SupplementaryGroups=["systemd-journal"] survives and the unit ends up in
    # both groups. Losing the journal group is the silent-zero failure, so
    # tests/suites/vps.nix asserts lines were actually read.
    serviceConfig.SupplementaryGroups = [ config.users.groups.vlogs-ingest.name ];

    # Ordering only, deliberately not a `requires`: the sink is across the
    # tailnet, so at boot the first pushes fail regardless. The WAL is the
    # answer to that, and a hard dependency would take the collector down
    # exactly while the tailnet is — the window whose logs are worth keeping.
    after = [ "tailscaled.service" ];

    # Alloy dying is invisible by construction: the symptom is an absence of
    # logs, in the place you would go to look for the absence.
    onFailure = [ "notify-failure@%n.service" ];
  };

  # Collector config
  # environment.etc rather than a store path, per the module's own guidance:
  # it is what makes reload (rather than restart) possible.
  environment.etc."alloy/config.alloy".text = ''
    // Generated from headscale-vps/modules/log-shipper.nix — edit there.
    //
    // The label schema mirrors stacks/logging/config.alloy; read that file for
    // the empirical work behind it. Only what DIFFERS here is noted.

    // Source: the host journal
    loki.source.journal "host" {
      // Explicit: without it the reader filters on its own /etc/machine-id,
      // which happens to be right for a native unit — written down rather
      // than relied on. services.journald.storage = "persistent" in
      // ../configuration.nix guarantees the directory has anything in it.
      path          = "/var/log/journal"
      relabel_rules = loki.relabel.journal.rules
      forward_to    = [loki.process.json_host.receiver]

      // Cold-start replay bound, same value as the services VM.
      max_age = "12h"

      // No `labels` argument: it loses to the component's own default `job`
      // when relabel_rules are set. `job` is a relabel rule below.
    }

    // Relabelling — identical to stacks/logging/config.alloy on purpose. Both
    // hosts push into one store; a label promoted on one side only makes every
    // fleet-wide query quietly host-specific.
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

      // Sparser here than on the services VM: this host's docker runs
      // Authentik only. An absent source label simply does not set the target.
      rule {
        source_labels = ["__journal_container_name"]
        target_label  = "container"
      }

      rule {
        source_labels = ["__journal_priority_keyword"]
        target_label  = "level"
      }

      // The label this whole module turns on — the selector the Grafana
      // dashboard and the Gatus freshness probe both key on.
      rule {
        source_labels = ["__journal__hostname"]
        target_label  = "host"
      }
    }

    // Rename a top-level JSON "host" key (see stacks/logging/config.alloy):
    // Authentik's request logs carry "host": "<vhost>", which VictoriaLogs
    // turns into a second `host` stream tag beside host="headscale-vps" and
    // panics on.
    loki.process "json_host" {
      forward_to = [loki.write.default.receiver]

      stage.replace {
        expression = "\"(host)\"\\s*:"
        replace    = "http_host"
      }
    }

    // Sink: the services VM's VictoriaLogs, through its Caddy.
    //
    // Through Caddy, not directly at :10456: VictoriaLogs publishes on that
    // host's loopback only, and re-binding it to the tailnet would hand every
    // peer an unauthenticated read/write API over the whole fleet's logs. Not
    // `import protected` on that vhost either — a forward-auth 302 on a push
    // endpoint is silently discarded telemetry.
    loki.write "default" {
      endpoint {
        url = "https://${ingestHost}${ingestPath}?_stream_fields=${streamFields}"

        // Never inlined: this config lands world-readable in /etc, and the vps
        // suite asserts the token string does not appear in it.
        bearer_token_file = "${tokenFile}"

        // A 429 is backpressure, and the one moment this pipeline earns its
        // keep is the moment it is asked to carry a burst.
        retry_on_http_429 = true
      }

      // Worth more here than on the services VM: it also covers the tailnet
      // being down, and the tailnet's control plane is THIS host — so
      // "headscale is broken" is both the likeliest outage and the one whose
      // logs you most want afterwards.
      wal {
        enabled = true
      }
    }

    // Alloy's own diagnostics go to the journal, which this collector then
    // reads — so a shipper that is failing to ship says so where you can still
    // read it. That is a feedback loop while the sink is down (each failed
    // batch logs a WARN that gets queued); it is bounded by backoff and
    // journald's SystemMaxUse, and it is why level stays at info.
    logging {
      level  = "info"
      format = "logfmt"
    }
  '';
}
