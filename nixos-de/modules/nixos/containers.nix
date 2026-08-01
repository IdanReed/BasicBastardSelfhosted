{ config, pkgs, ... }:

{
  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
  };

  users.users.idan.extraGroups = [ "docker" ];

  environment.systemPackages = with pkgs; [
    docker-compose
  ];
}
