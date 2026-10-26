# The deploy plane: Komodo, run from the flake.
#
# Stacks are Komodo git stacks: a push to Forgejo fires ONE webhook at Komodo's
# `apply` procedure (komodo/fleet.toml), which runs the `fleet` Resource Sync
# (registers / updates / removes stacks from komodo/sync/*.toml) and then
# BatchDeployStackIfChanged — each stack re-reads its files at the new commit,
# compares them with what it last deployed, and only a changed stack is
# redeployed. Periphery clones and runs compose; the host only renders the
# envs (stack-env.nix) and owns the sync and `apply` themselves. Nothing on the
# host signals Komodo.
#
# Komodo itself (and Forgejo, forgejo.nix) cannot be deployed by Komodo, so
# both run from the store on `nixos-rebuild switch`.

{ config, pkgs, ... }:

let
  docker = "${config.virtualisation.docker.package}/bin/docker";
  # The whole directory, so compose resolves anything relative to the file.
  compose = "${docker} compose -f ${../../komodo}/compose.yaml -p komodo --env-file /run/stack-env/komodo.env";
  api = "http://127.0.0.1:10000";
  # The sync and `apply`, as the API takes them. The TOML is Komodo's export
  # form, which spells a procedure's `stages` as `stage`.
  fleet = builtins.fromTOML (builtins.readFile ../../komodo/fleet.toml);
  sync = builtins.head fleet.resource_sync;
  apply = builtins.head fleet.procedure;
  fleetJson = pkgs.writeText "komodo-fleet.json" (builtins.toJSON {
    sync = { inherit (sync) name description config; };
    apply = {
      inherit (apply) name description;
      config = removeAttrs apply.config [ "stage" ] // { stages = apply.config.stage; };
    };
  });
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

  # Creates the `fleet` sync and the `apply` procedure from komodo/fleet.toml —
  # or updates them to it — then runs the sync, which registers every stack (a
  # push deploys them). Neither resource is in the sync's own files: `apply`
  # runs the sync, and a running resource cannot be updated. A changed
  # fleet.toml changes this script, so `nrs-vm` re-applies it. Also re-run when
  # the git token changes: before Forgejo has minted it, Komodo cannot read the
  # repo and this exits 0 having only said so.
  systemd.services.komodo-sync-bootstrap = {
    description = "Apply komodo/fleet.toml to Komodo and register the stacks";
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

      # Create the resource, or update it to the file. A resource that is busy
      # (an `apply` mid-run) refuses the update, so that is retried.
      ensure() { # type get-param key
        local type=$1 param=$2 key=$3 name config id
        name=$(jq -r ".$key.name" ${fleetJson})
        config=$(jq -c ".$key.config" ${fleetJson})
        if id=$(k "/read/Get$type" "$(jq -n --arg p "$param" --arg n "$name" '{($p): $n}')" 2>/dev/null \
                | jq -er '._id."$oid"'); then
          for i in $(seq 24); do
            k "/write/Update$type" "$(jq -n --arg id "$id" --argjson c "$config" '{id: $id, config: $c}')" \
              >/dev/null && break
            [ "$i" = 24 ] && { echo "Update$type $name kept failing" >&2; return 1; }
            sleep 5
          done
        else
          id=$(k "/write/Create$type" "$(jq -n --arg n "$name" --argjson c "$config" '{name: $n, config: $c}')" \
               | jq -er '._id."$oid"')
        fi
        k /write/UpdateResourceMeta "$(jq -n --arg t "$type" --arg id "$id" \
            --arg d "$(jq -r ".$key.description" ${fleetJson})" \
            '{target: {type: $t, id: $id}, description: $d}')" >/dev/null
        echo "$type $name matches komodo/fleet.toml"
      }
      ensure ResourceSync sync sync
      ensure Procedure procedure apply

      # The sync clones from Forgejo, which starts beside Komodo at boot.
      for _ in $(seq 120); do
        curl -fsS --max-time 5 http://127.0.0.1:10550/api/healthz >/dev/null 2>&1 && break
        sleep 5
      done

      # Register (never deploy): a push deploys, and this run may follow a
      # change to the sync itself. Busy while an `apply` runs it — retried.
      upd=""
      for _ in $(seq 24); do
        upd=$(k /execute/RunSync '{"sync":"fleet"}' 2>/dev/null | jq -er '._id."$oid"') && break
        sleep 5
      done
      [ -n "$upd" ] || { echo "Komodo never started the fleet sync" >&2; exit 1; }
      u=""
      for _ in $(seq 120); do
        u=$(k /read/GetUpdate "$(jq -n --arg id "$upd" '{id: $id}')")
        [ "$(jq -r .status <<<"$u")" = Complete ] && break
        sleep 5
      done
      if [ "$(jq -r .success <<<"$u")" != true ]; then
        echo "the fleet sync failed (update $upd):" >&2
        jq -r '.logs[] | select(.success == false) | "\(.stage): \(.stderr)"' <<<"$u" >&2
        exit 1
      fi
      echo "fleet sync ran: every stack in komodo/sync/ is registered."
    '';
  };
}
