{ config, pkgs, ... }:

{
  # Komodo
  systemd.services.bootstrap-komodo = {
    description = "Bootstrap Komodo container management";
    # Core joins `homelab` to reach Forgejo for Resource-Sync polling, so the
    # network is a start dependency, not just an ordering edge.
    after = [ "docker.service" "network-online.target" "srv.mount" "decrypt-sops-envs.service" "docker-network-homelab.service" ];
    wants = [ "network-online.target" ];
    requires = [ "docker.service" "srv.mount" "decrypt-sops-envs.service" "docker-network-homelab.service" ];
    wantedBy = [ "multi-user.target" ];

    # Deploy plane down = running stacks keep running, so nothing looks wrong
    # until the next change silently does not land.
    onFailure = [ "notify-failure@%n.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      WorkingDirectory = "/srv/komodo";
    };

    script = ''
      sleep 5
      ${config.virtualisation.docker.package}/bin/docker compose up -d
    '';
  };

  # Stack delivery
  # The clone lives on the host (invariant #1: git credentials and file writes
  # stay out of the socket-mounting Periphery). Timer-driven, not
  # wantedBy multi-user.target: Forgejo is itself a managed stack, so a
  # boot-time pull would race it and page.
  systemd.services.stack-git-sync = {
    description = "Sync compose stacks from Forgejo into /srv/stacks";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # Silent failure mode: a stack that never updates.
    onFailure = [ "notify-failure@%n.service" ];

    path = with pkgs; [
      git
      openssh # git shells out to ssh for the ssh:// remote
      rsync
      coreutils
    ];

    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "stack-git-sync";
      StateDirectoryMode = "0700";
    };

    script = ''
      # NOT set -e: each step is `|| fail` so errors alert with a message.
      set -uo pipefail
      umask 077

      # Loopback SSH, not the tailnet vhost: keeps tailscaled and Caddy out of
      # the dependency set. 10551 is the forgejo stack's loopback sshd publish.
      host="127.0.0.1"
      port="10551"
      repo="idan/BasicBastardSelfhosted"
      branch="main"
      work="$STATE_DIRECTORY/checkout"
      url="ssh://git@$host:$port/$repo.git"

      # Deploy key via GIT_SSH_COMMAND, never argv. accept-new pins Forgejo's
      # host key on first contact (its host keys are generated at first start,
      # so there is nothing to pin against beforehand); a later mismatch fails
      # loudly, which is the wanted signal on /data loss.
      export GIT_SSH_COMMAND="ssh -i ${config.sops.secrets.STACK_GIT_SSH_KEY.path} -o IdentitiesOnly=yes -o UserKnownHostsFile=$STATE_DIRECTORY/known_hosts -o StrictHostKeyChecking=accept-new"
      export GIT_TERMINAL_PROMPT=0

      # Alert on state CHANGE: a persistent failure must not ntfy every 60s.
      stamp=/run/stack-git-sync.failed

      fail() {
        echo "$1" >&2
        if [ -e "$stamp" ] && [ "$1" = "$(cat "$stamp")" ]; then
          echo "(already notified; see the journal above)" >&2
          exit 0
        fi
        printf '%s\n' "$1" > "$stamp"
        exit 1
      }

      # Clone once, fetch+reset thereafter, so a force-push heals rather than
      # wedging.
      if [ ! -d "$work/.git" ]; then
        rm -rf "$work"
        git clone --quiet --branch "$branch" "$url" "$work" \
          || fail "clone failed (is Forgejo's sshd reachable at $host:$port, deploy key registered?)"
      else
        git -C "$work" fetch --quiet origin "$branch" \
          || fail "fetch failed (is Forgejo's sshd reachable at $host:$port, deploy key registered?)"
        # Refresh first: last tick's chmod left every file stat-dirty, and a
        # stat-dirty file is rewritten by `reset --hard` even when unchanged.
        git -C "$work" update-index -q --refresh || true
        git -C "$work" reset --quiet --hard "origin/$branch" \
          || fail "reset to origin/$branch failed"
      fi

      [ -d "$work/stacks" ] || fail "repo checkout has no stacks/ directory"

      # Delivered files must be world-readable, secrets excepted (finding #79):
      # umask 077 makes git create them 0600 and rsync -p copies that verbatim,
      # which EACCESes any file bind-mounted into a non-root container.
      # Normalise at the source so -p propagates exact modes and the
      # destination never flaps; the checkout sits in the 0700 StateDirectory.
      chmod -R u=rwX,go=rX "$work/stacks" \
        || fail "chmod on checkout failed"
      find "$work/stacks" -name '.sops.env' -exec chmod 0600 {} + \
        || fail "chmod 0600 on .sops.env failed"

      # --checksum AND NO -t: a delivered file's mtime moves only when its
      # content does, which is the signal decrypt-sops-envs keys on (with -t
      # every .env was re-decrypted minutely). NO --delete: the decrypted .env
      # is absent from the checkout and would be nuked. Excludes are
      # belt-and-suspenders.
      rsync -rlpD --checksum \
        --exclude='.env' --exclude='komodo.env' \
        "$work/stacks/" /srv/stacks/ \
        || fail "rsync into /srv/stacks failed"

      # rsync copies root-owned; the deploy plane reads as uid 1000
      # (finding #10). Only the dirs this sync manages, never /srv/stacks.
      for d in "$work"/stacks/*/; do
        name="$(basename "$d")"
        [ -d "/srv/stacks/$name" ] && chown -R 1000:1000 "/srv/stacks/$name"
      done

      if [ -e "$stamp" ]; then
        rm -f "$stamp"
        echo "recovered: stack sync succeeded again"
      fi
      exit 0
    '';
  };

  systemd.timers.stack-git-sync = {
    description = "Poll Forgejo for compose stack changes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "minutely";
      AccuracySec = "1s";
      Unit = "stack-git-sync.service";
    };
  };
}
