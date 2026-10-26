# The deploy plane: Komodo, run from the flake.
#
# Stacks are Komodo git stacks: a push to Forgejo fires ONE webhook at Komodo's
# `apply` procedure (komodo/sync/fleet.toml), which runs the `fleet` Resource
# Sync (registers / updates / removes stacks from komodo/sync/*.toml) and then
# BatchDeployStackIfChanged — each stack re-reads its files at the new commit,
# compares them with what it last deployed, and only a changed stack is
# redeployed. Periphery clones and runs compose; the host only renders the
# envs (stack-env.nix). Nothing on the host signals Komodo.
#
# Komodo itself (and Forgejo, forgejo.nix) cannot be deployed by Komodo, so
# both run from the store on `nixos-rebuild switch`.

{ config, pkgs, ... }:

let
  docker = "${config.virtualisation.docker.package}/bin/docker";
  # The whole directory, so compose resolves anything relative to the file.
  compose = "${docker} compose -f ${../../komodo}/compose.yaml -p komodo --env-file /run/stack-env/komodo.env";
  api = "http://127.0.0.1:10000";
  forgejoRepo = "idan/BasicBastardSelfhosted";
in
{
  # Core's git provider: the `komodo` bot's read-only Forgejo token. Komodo
  # clones over HTTP with a token only (no ssh); Core hands it to Periphery
  # per request. Published to /run/stack-env with the stack envs and mounted
  # at /config/git.config.toml (komodo/compose.yaml).
  sops.templates."stacks/komodo-core.config.toml" = {
    content = ''
      [[git_provider]]
      domain = "forgejo:3000"
      https = false
      accounts = [
        { username = "komodo", token = "komodo:${config.sops.placeholder."stacks/komodo/KOMODO_GIT_TOKEN"}" },
      ]
    '';
    restartUnits = [
      "stack-env-publish.service"
      "komodo-core-reload.service"
      "komodo-sync-bootstrap.service"
    ];
  };

  # A changed Komodo env re-runs `up -d`, which recreates exactly the
  # containers whose environment changed.
  sops.templates."stacks/komodo.env".restartUnits = [ "bootstrap-komodo.service" ];

  systemd.services.bootstrap-komodo = {
    description = "Komodo deploy plane (docker compose from the flake)";
    # Core joins `homelab` to reach Forgejo and receive its webhook, so the
    # network is a start dependency, not just an ordering edge.
    after = [ "docker.service" "network-online.target" "srv.mount" "stack-env-publish.service" "docker-network-homelab.service" ];
    wants = [ "network-online.target" ];
    requires = [ "docker.service" "srv.mount" "stack-env-publish.service" "docker-network-homelab.service" ];
    wantedBy = [ "multi-user.target" ];

    # Deploy plane down = running stacks keep running, so nothing looks wrong
    # until the next change silently does not land.
    onFailure = [ "notify-failure@%n.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    # From the store: a changed compose.yaml changes this script, so a switch
    # re-runs it. The project name is pinned — the store path changes on every
    # rebuild and would otherwise orphan the running containers.
    script = ''
      sleep 5
      ${compose} up -d --remove-orphans
    '';
  };

  # Core reads its config files only at start.
  systemd.services.komodo-core-reload = {
    description = "Restart Komodo Core to re-read its git-provider config";
    after = [ "stack-env-publish.service" "bootstrap-komodo.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      if ${docker} inspect komodo >/dev/null 2>&1; then
        ${docker} restart komodo
      fi
    '';
  };

  # Creates the `fleet` Resource Sync once and runs it, which registers the
  # `apply` procedure the Forgejo webhook calls and every stack. From then on
  # the sync manages itself (it is declared in komodo/sync/fleet.toml too).
  # Re-run when the git token changes: before Forgejo has minted it, Komodo
  # cannot read the repo and this exits 0 having only said so.
  systemd.services.komodo-sync-bootstrap = {
    description = "Register Komodo's fleet Resource Sync (first run only)";
    after = [ "bootstrap-komodo.service" "forgejo.service" ];
    requires = [ "bootstrap-komodo.service" ];
    wantedBy = [ "multi-user.target" ];
    onFailure = [ "notify-failure@%n.service" ];
    path = with pkgs; [ curl jq coreutils gnugrep ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      # The rendered env single-quotes every value, so it sources cleanly.
      set -a
      . /run/stack-env/komodo.env
      set +a

      if [[ $KOMODO_GIT_TOKEN == changeme* ]]; then
        echo "KOMODO_GIT_TOKEN is still a placeholder — mint it in Forgejo, sopsedit komodo/secrets.sops.json, switch."
        exit 0
      fi

      # Core needs a while on a fresh database.
      jwt=""
      for _ in $(seq 60); do
        jwt=$(jq -n --arg u "$KOMODO_INIT_ADMIN_USERNAME" --arg p "$KOMODO_INIT_ADMIN_PASSWORD" \
                '{username: $u, password: $p}' \
              | curl -fsS --max-time 10 -X POST -H 'content-type: application/json' \
                  --data-binary @- ${api}/auth/login/LoginLocalUser 2>/dev/null \
              | jq -r '.data.jwt // empty') && [ -n "$jwt" ] && break
        sleep 5
      done
      [ -n "$jwt" ] || { echo "Komodo Core never accepted the admin login at ${api}" >&2; exit 1; }

      k() { # path json-body
        curl -fsS --max-time 300 -X POST -H 'content-type: application/json' \
          -H "authorization: $jwt" --data-binary "$2" "${api}$1"
      }

      # Done once the first sync has run: it is what creates `apply`. (Not
      # "the sync exists" — a first RunSync that failed would leave the sync
      # registered and `apply` missing forever.)
      if k /read/GetProcedure '{"procedure":"apply"}' >/dev/null 2>&1; then
        echo "apply procedure exists — Komodo manages the fleet from here."
        exit 0
      fi

      if ! k /read/GetResourceSync '{"sync":"fleet"}' >/dev/null 2>&1; then
        k /write/CreateResourceSync "$(jq -n '{
          name: "fleet",
          config: {
            git_provider: "forgejo:3000", git_https: false, git_account: "komodo",
            repo: "${forgejoRepo}", branch: "main",
            resource_path: ["komodo/sync"], delete: true
          }
        }')" >/dev/null
      fi

      # The sync clones from Forgejo, which starts beside Komodo at boot.
      for _ in $(seq 120); do
        curl -fsS --max-time 5 http://127.0.0.1:10550/api/healthz >/dev/null 2>&1 && break
        sleep 5
      done

      k /execute/RunSync '{"sync":"fleet"}' >/dev/null
      for _ in $(seq 60); do
        if k /read/GetProcedure '{"procedure":"apply"}' >/dev/null 2>&1; then
          echo "fleet sync ran: the apply procedure and every stack now exist."
          exit 0
        fi
        sleep 5
      done
      echo "RunSync did not create the apply procedure — see the fleet sync's update log in Komodo" >&2
      exit 1
    '';
  };
}
