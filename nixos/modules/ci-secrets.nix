# Runtime decryption of the two forge credentials the CI half of this host
# needs: Renovate's Forgejo PAT and the Actions runner's registration token.
#
# Their own encrypted dotenv files rather than keys in nixos/secrets.sops.yaml:
# sops has no append-without-decrypt, and that file holds real ed25519 keys a
# regenerate-from-.example would destroy. Encrypting a new file needs only the
# public recipient. Dotenv is safe here because sops-nix is not involved — each
# file is consumed whole as an EnvironmentFile by exactly one unit.
#
# TODO, next time the key holder opens secrets.sops.yaml: move both values in
# (plus .example and tests/fixtures/services-vm.sops.yaml — sops-declared
# compares all three) and replace this module with two sops.secrets entries.
#
# Absent is not failed: this unit always exits 0, because neither credential
# can exist until Forgejo is live. Consumers gate on ConditionPathExists, so
# they are skipped rather than failed and `systemctl --failed` stays clean
# (asserted literally by the services and forgejo suites).

{ pkgs, lib, ... }:

let
  runtimeDir = "/run/ci-secrets";

  # Referenced as store paths, so a rotated secret changes this unit's
  # ExecStart and systemd restarts it on the next switch.
  sources = {
    "renovate.env" = ../renovate.sops.env;
    "forgejo-runner-token.env" = ../forgejo-runner.sops.env;
  };
in
{
  # The contract (grep "/run/ci-secrets" for all three sites):
  #
  #   /run/ci-secrets/renovate.env              RENOVATE_TOKEN=…  -> renovate.nix
  #   /run/ci-secrets/forgejo-runner-token.env  TOKEN=…           -> forgejo-runner.nix
  #
  # The key names are fixed by the consumers: `TOKEN` is what nixpkgs'
  # gitea-actions-runner ExecStartPre reads.

  systemd.tmpfiles.rules = [
    # PID 1 opens EnvironmentFile= as root before dropping to the unit's
    # (Dynamic)User, so consumers never need read access.
    "d ${runtimeDir} 0700 root root -"
  ];

  systemd.services.ci-secrets = {
    description = "Decrypt Forgejo CI credentials (Renovate PAT, runner token)";
    wantedBy = [ "multi-user.target" ];

    # The age key lives on the ROOT fs, not /srv — do not tighten this to
    # srv.mount.
    after = [ "local-fs.target" ];

    # Ordering only, never Requires=: a missing credential must SKIP a
    # consumer, not dependency-fail it.
    before = [
      "renovate.service"
      "gitea-runner-forgejo.service"
    ];

    path = [ pkgs.sops ];

    serviceConfig = {
      Type = "oneshot";
      # Files must outlive the unit: consumers' ConditionPathExists is
      # evaluated when THEY start.
      RemainAfterExit = true;
      # No OnFailure=: the script cannot fail, so it would be dead code.
    };

    script = ''
      umask 077

      export SOPS_AGE_KEY_FILE=/var/lib/sops-nix/sops_age_key.txt

      install -d -m 0700 -o root -g root ${runtimeDir}

      decrypt() {
        src="$1"
        out="${runtimeDir}/$2"

        # Remove first: a credential that stops decrypting must take the
        # consumer offline, not leave it running on a stale token.
        rm -f "$out" "$out.tmp"

        err="$(mktemp)"
        if ! sops -d "$src" > "$out.tmp" 2>"$err"; then
          echo "ci-secrets: cannot decrypt $src — leaving $out absent." >&2
          sed 's/^/  sops: /' "$err" >&2 || true
          echo "ci-secrets: if this host has its age key at" \
               "/var/lib/sops-nix/sops_age_key.txt this is a real fault;" \
               "in a test VM it is expected (the fixtures' throwaway key is" \
               "not a recipient of the production files)." >&2
          rm -f "$out.tmp" "$err"
          return 0
        fi
        rm -f "$err"

        # A changeme_ template would authenticate verbatim and produce a 401
        # loop against the forge.
        if grep -q 'changeme_' "$out.tmp"; then
          echo "ci-secrets: $src is still a changeme_ template — $2 not" \
               "written. Fill it in with: sopsedit $src" >&2
          rm -f "$out.tmp"
          return 0
        fi

        chmod 0400 "$out.tmp"
        mv "$out.tmp" "$out"
        echo "ci-secrets: wrote $out"
      }

      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: src: ''decrypt ${src} ${lib.escapeShellArg name}'') sources
      )}

      exit 0
    '';
  };
}
