# Runtime decryption of the two forge credentials the CI half of this host
# needs: Renovate's Forgejo PAT and the Actions runner's registration token.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS AT ALL (read before "fixing" it into secrets.sops.yaml)
# ---------------------------------------------------------------------------
# CLAUDE.md's rule is that OS-level secrets live in nixos/secrets.sops.yaml and
# are extracted per-key by sops-nix at activation. That rule is correct and
# every other secret on this host follows it. These two do not, for one
# mechanical reason:
#
#   Adding a key to an already-encrypted sops-yaml requires the age PRIVATE
#   key. sops has to recompute the file-wide MAC over every value, so there is
#   no append-without-decrypt path — `sops set`, `sops -e -i` and hand-editing
#   all need the key. ENCRYPTING A NEW FILE, by contrast, needs only the
#   public recipient in .sops.yaml.
#
#   nixos/secrets.sops.yaml currently holds two REAL ed25519 private keys
#   (BACKUP_VPS_SSH_KEY / BACKUP_STORAGEBOX_SSH_KEY — 411 and 419 plaintext
#   bytes; the changeme_ templates they replaced were 35 and 42). Recreating
#   that file from its .example to make room for two new keys would destroy
#   them, and they are authorised on the VPS and on the Hetzner Storage Box.
#
# So the credentials ship as their own encrypted dotenv files and are decrypted
# HERE, at runtime, with the host age key — the identical mechanism
# decrypt-sops-envs.service already uses for every stack. Dotenv is not a
# compromise in this shape: each file is consumed WHOLE as a systemd
# EnvironmentFile by exactly one unit, which is precisely the criterion
# CLAUDE.md gives for choosing dotenv over yaml. The sops-dotenv-extraction
# trap (sops-nix ignoring the per-key selector for dotenv) cannot apply,
# because sops-nix is not involved.
#
# MIGRATION, when the key holder next opens the file: move RENOVATE_TOKEN and
# the runner TOKEN into nixos/secrets.sops.yaml, add them to the .example and
# to tests/fixtures/services-vm.sops.yaml (the sops-declared lint compares all
# three), and replace this module with two sops.secrets declarations. That is
# a ~10-line change. It is not done here only because it cannot be done
# without the private key.
#
# ---------------------------------------------------------------------------
# FAILURE PHILOSOPHY: absent is not failed
# ---------------------------------------------------------------------------
# This unit ALWAYS exits 0, which is unusual for this repo. The reason is the
# state it is designed to sit in for a while: neither credential can exist
# until Forgejo is live (one is minted in the UI, the other in site admin), so
# "not configured yet" is the expected steady state at first deploy — and it
# is not a fault. If this unit failed, its OnFailure would push to Idan's
# phone on every boot for a known-pending operator step, and the two consumer
# units would enter dependency-failed. Instead: no output file is written, and
# the consumers gate on ConditionPathExists, which systemd treats as
# "skipped", not "failed". That keeps `systemctl --failed` clean — which the
# services and forgejo suites assert on literally.
#
# A genuine problem still surfaces: every branch below logs a distinct,
# greppable reason at the unit's own journal, and the consumers being silently
# inactive is visible in `systemctl list-timers` / the runner never appearing
# in Forgejo's runner list.

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
  # THE CONTRACT, in one place. The two consumer modules spell these paths
  # out literally rather than importing a shared constant — two strings do
  # not justify a new option, and a grep for "/run/ci-secrets" finds all
  # three sites:
  #
  #   /run/ci-secrets/renovate.env              RENOVATE_TOKEN=…
  #     -> nixos/modules/renovate.nix       (EnvironmentFile + ConditionPathExists)
  #   /run/ci-secrets/forgejo-runner-token.env  TOKEN=…
  #     -> nixos/modules/forgejo-runner.nix (tokenFile + ConditionPathExists)
  #
  # Each file is the decrypted dotenv verbatim, so the KEY NAMES above are
  # fixed by the consumers: `TOKEN` in particular is what nixpkgs'
  # gitea-actions-runner ExecStartPre reads, and renaming it in
  # nixos/forgejo-runner.sops.env silently breaks registration.

  systemd.tmpfiles.rules = [
    # 0700 root: the decrypted tokens are root-only. Both consumers read them
    # through EnvironmentFile=/LoadCredential=, which PID 1 opens as root
    # before dropping to the unit's (Dynamic)User — so nothing needs to be
    # readable by the renovate or gitea-runner users.
    "d ${runtimeDir} 0700 root root -"
  ];

  systemd.services.ci-secrets = {
    description = "Decrypt Forgejo CI credentials (Renovate PAT, runner token)";
    wantedBy = [ "multi-user.target" ];

    # local-fs.target: the age key lives on the state filesystem
    # (/var/lib/sops-nix), which is a separate mount on this host.
    after = [ "local-fs.target" ];

    # Ordering only, not Requires=: a consumer must be SKIPPED (condition) when
    # a credential is missing, never dependency-failed. Requires= would turn a
    # pending operator step into a failed unit.
    before = [
      "renovate.service"
      "gitea-runner-forgejo.service"
    ];

    path = [ pkgs.sops ];

    serviceConfig = {
      Type = "oneshot";
      # The runtime files must outlive the unit's own exit: the consumers'
      # ConditionPathExists is evaluated when THEY start, which is after this
      # oneshot has finished.
      RemainAfterExit = true;
      # NO OnFailure=, on purpose: the script below cannot fail (see the
      # failure philosophy above), so an OnFailure= here would be dead code
      # dressed up as coverage — exactly what configuration.nix's
      # notify-failure@ header warns about. The alerting that matters lives on
      # renovate.service, which CAN fail meaningfully.
    };

    script = ''
      # Plaintext tokens must never be world-readable, not even for the
      # instant between creat() and chmod.
      umask 077

      export SOPS_AGE_KEY_FILE=/var/lib/sops-nix/sops_age_key.txt

      install -d -m 0700 -o root -g root ${runtimeDir}

      decrypt() {
        src="$1"
        out="${runtimeDir}/$2"

        # Remove first: a credential that STOPS being valid (file replaced by
        # something that no longer decrypts, key rotated away) must take the
        # consumer offline rather than leave it running on a stale token that
        # nothing in the repo describes any more.
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

        # The committed files start life as encrypted changeme_ templates, and
        # a real switch installs those verbatim. Registering a runner with a
        # placeholder token, or handing Renovate a placeholder PAT, produces a
        # confusing 401 loop against the forge; refusing to write the file
        # produces a one-line journal entry and a skipped unit instead.
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
