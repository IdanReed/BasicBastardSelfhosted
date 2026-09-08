{ config, pkgs, ... }:

let
  docker = "${config.virtualisation.docker.package}/bin/docker";
in
{
  virtualisation.docker = {
    enable = true;
    # pkgs.docker is 28.x, marked insecure by nixpkgs — refuses to evaluate.
    package = pkgs.docker_29;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };

    # Log driver
    # Container stdout goes to the host journal so stacks/logging's Alloy can
    # read it from a read-only bind mount instead of the docker socket.
    # `docker logs` keeps working (verified on 29.4.3). Do NOT copy to
    # headscale-vps: its authentik compose pins a per-service journald tag that
    # fail2ban matches, and the fail2ban-journal-contract lint reads the YAML.
    #
    # Without an explicit tag docker labels every stream with the truncated
    # container id, which changes on each `docker compose up`.
    daemon.settings = {
      log-driver = "journald";
      log-opts = {
        tag = "{{.Name}}";
      };
    };
  };

  # journald
  # rateLimitBurst = 0 must stay in lockstep with the log driver above: docker
  # submits the whole fleet as docker.service, so one shared bucket drops lines
  # `docker logs` then cannot show either. The bound moves to the byte cap.
  services.journald = {
    rateLimitBurst = 0;
    storage = "persistent";

    # The journal is a buffer, not the archive — it only has to cover the
    # window in which Alloy is down. It lives on `/`, so the cap is what keeps
    # the log fleet from filling the root filesystem. SystemKeepFree is above
    # systemd's 15% default because the test VMs get an 8 GB disk.
    extraConfig = ''
      SystemMaxUse=2G
      SystemKeepFree=2G
      SystemMaxFileSize=128M
    '';
  };

  # Cross-stack traffic rides service names on `homelab`: published ports bind
  # 127.0.0.1, which containers cannot reach, and host.docker.internal does not
  # resolve on Linux.
  systemd.services.docker-network-homelab = {
    description = "Create the shared 'homelab' docker network";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    before = [ "bootstrap-komodo.service" ];

    # Silent failure mode: every `networks: [homelab]` stack fails to start.
    onFailure = [ "notify-failure@%n.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      ${docker} network inspect homelab >/dev/null 2>&1 \
        || ${docker} network create homelab
    '';
  };
}
