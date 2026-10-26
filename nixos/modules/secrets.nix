{ ... }:

{
  # YAML, not dotenv: sops-install-secrets applies the per-secret key only for
  # yaml/json — with dotenv every /run/secrets/<name> gets the whole file.
  sops = {
    defaultSopsFile = ../secrets.sops.yaml;
    defaultSopsFormat = "yaml";

    age.keyFile = "/var/lib/sops-nix/sops_age_key.txt";

    secrets = {
      TAILSCALE_AUTH_KEY = { };

      BACKUP_VPS_SSH_KEY = {
        path = "/var/lib/backup/vps_ed25519";
        mode = "0600";
      };

      # No custom path on purpose: backrest bind-mounts /var/lib/backup, where
      # a /run/secrets.d symlink dangles in-container. The tmpfiles C+ rule in
      # backup.nix materialises a real file instead.
      BACKUP_STORAGEBOX_SSH_KEY = {
        mode = "0600";
      };

      # Forge credentials for the CI half of this host, both minted by Forgejo
      # once it is live — so a `changeme_` value is their normal state until
      # then, and each consumer skips (never fails) while it is one. Rendered
      # into the EnvironmentFile each consumer wants by renovate.nix and
      # forgejo-runner.nix.
      RENOVATE_TOKEN = { };
      FORGEJO_RUNNER_TOKEN = { };
    };
  };
}
