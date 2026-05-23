{ config, ... }:

{
  sops = {
    age.keyFile = "/var/lib/sops-nix/sops_age_key.txt";

    # Uncomment once .sops.env exists (created from .sops.env.example
    # and encrypted with `sops -e -i .sops.env`):
    #
    # defaultSopsFile = ../../.sops.env;
    # defaultSopsFormat = "dotenv";
    # secrets = {
    #   USER_PASSWORD_HASH = { neededForUsers = true; };
    # };
  };
}
