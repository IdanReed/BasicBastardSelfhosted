# Runtime decryption of the two forge credentials the CI half of this host
# needs: Renovate's Forgejo PAT and the Actions runner's registration token.
#
# 🚨 NOT in nixos/secrets.sops.yaml, for one mechanical reason: sops has no
# append-without-decrypt (the file-wide MAC needs the age PRIVATE key), and
# that file holds two REAL ed25519 keys (BACKUP_VPS_SSH_KEY /
# BACKUP_STORAGEBOX_SSH_KEY — 411/419 plaintext bytes vs the 35/42-byte
# changeme_ templates) that a regenerate-from-.example would destroy.
# Encrypting a NEW file needs only the public recipient, so these ship as
# their own encrypted dotenv files, decrypted here with the host age key.
# Dotenv is correct in this shape: each file is consumed WHOLE as an
# EnvironmentFile by exactly one unit, and the sops-dotenv-extraction trap
# (sops-nix ignoring the per-key selector for dotenv) cannot apply because
# sops-nix is not involved.
#
# MIGRATION, when the key holder next opens the file: move both values into
# nixos/secrets.sops.yaml (+ .example + tests/fixtures/services-vm.sops.yaml —
# the sops-declared lint compares all three) and replace this module with two
# sops.secrets declarations.
#
# FAILURE PHILOSOPHY: absent is not failed. This unit ALWAYS exits 0 — neither
# credential can exist until Forgejo is live, so "not configured yet" is the
# expected steady state, and a failing unit would ntfy on every boot and
# dependency-fail both consumers. Instead no output file is written and the
# consumers gate on ConditionPathExists = skipped, not failed — keeping
# `systemctl --failed` clean, which the services and forgejo suites assert on
# literally. Every branch below still logs a distinct, greppable reason.

{ pkgs, lib, ... }:

let
  runtimeDir = "/run/ci-secrets";

  # name in $runtimeDir -> encrypted source shipped inside the flake.
  # Both are referenced as store paths, so a rotated secret changes this
  # unit's ExecStart and systemd restarts it on the next switch.
  sources = {
    "renovate.env" = ../renovate.sops.env;
    "forgejo-runner-token.env" = ../forgejo-runner.sops.env;
  };
in
{
  # THE CONTRACT (a grep for "/run/ci-secrets" finds all three sites):
  #
  #   /run/ci-secrets/renovate.env              RENOVATE_TOKEN=…
  #     -> nixos/modules/renovate.nix       (EnvironmentFile + ConditionPathExists)
  #   /run/ci-secrets/forgejo-runner-token.env  TOKEN=…
  #     -> nixos/modules/forgejo-runner.nix (tokenFile + ConditionPathExists)
  #
  # Each file is the decrypted dotenv verbatim, so the KEY NAMES are fixed by
  # the consumers: `TOKEN` is what nixpkgs' gitea-actions-runner ExecStartPre
  # reads — renaming it in nixos/forgejo-runner.sops.env silently breaks
  # registration.

  systemd.tmpfiles.rules = [
    # 0700 root: PID 1 opens EnvironmentFile= as root before dropping to the
    # unit's (Dynamic)User, so the consumers never need read access.
    "d ${runtimeDir} 0700 root root -"
  ];

  systemd.services.ci-secrets = {
    description = "Decrypt Forgejo CI credentials (Renovate PAT, runner token)";
    wantedBy = [ "multi-user.target" ];

    # Conservative anchor only — the age key lives on the ROOT fs, not /srv;
    # do not "tighten" this to srv.mount.
    after = [ "local-fs.target" ];

    # Ordering only, not Requires=: a missing credential must SKIP a consumer
    # (condition), never dependency-fail it.
    before = [
      "renovate.service"
      "gitea-runner-forgejo.service"
    ];

    path = [ pkgs.sops ];

    serviceConfig = {
      Type = "oneshot";
      # Files must outlive the unit: consumers' ConditionPathExists is
      # evaluated when THEY start, after this oneshot has finished.
      RemainAfterExit = true;
      # NO OnFailure=, on purpose: the script cannot fail (failure philosophy
      # above), so it would be dead code — the notify-failure@ header in
      # configuration.nix warns about exactly that. Alerting lives on
      # renovate.service, which CAN fail meaningfully.
    };

    script = ''
      # No world-readable instant between creat() and chmod
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

        # A changeme_ template registered/authenticated verbatim produces a
        # confusing 401 loop against the forge; refusing to write the file
        # gives a one-line journal entry and a skipped unit instead.
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
