# Secret rotation (heavy): the restartUnits contract, end to end.
#
# modules/headscale.nix and modules/authentik.nix both annotate their secrets
# with restartUnits and explain why: sops-nix renders to STABLE paths, so
# rotating a value leaves every systemd unit byte-identical and nothing would
# restart on its own — Authentik's blueprint would pick up the new OIDC client
# secret while Headscale kept serving the old one, and OIDC would break in the
# quietest possible way. This suite is that comment, executed.
#
# Mechanism: the node carries a NixOS specialisation ("rotated") whose only
# delta is a sops fixture with a different HEADSCALE_OIDC_CLIENT_SECRET. The
# script runs the specialisation's switch-to-configuration — a real
# activation, the same code path `nixos-rebuild switch` takes on the VPS —
# and asserts:
#   (a) /run/secrets/* now hold the rotated value (per-key, exact)
#   (b) headscale.service RESTARTED (restartUnits on the secret)
#   (c) authentik.service RESTARTED (restartUnits on the rendered template)
#       and the re-rendered EnvironmentFile carries the rotated value
#   (d) what the WORKER environment sees after the restart — the container
#       boundary. Whether the provider ROW re-reads the blueprint's !Env
#       after a rotation is answered by NEITHER suite: it needs the API
#       surface (checks.authentik's world) plus a rotation (this one's),
#       and the two never meet — recorded in README's not-covered table.
#
# Deliberately NOT covered here: the full blueprint/API surface (that is
# checks.authentik's job); this suite keeps Authentik because its unit is one
# of the two restart targets under test.

{
  pkgs,
  lib,
  images,
  profiles,
  sopsModule,
  acmeServerModule,
  ...
}:

let
  headscaleHost = "headscale.idanreed.com";
  authHost = "auth.idanreed.com";
in
pkgs.testers.runNixOSTest {
  name = "rotation";

  # Authentik migrations + two full activations; keep diagnostics reachable.
  globalTimeout = 3600;

  nodes = {
    vps =
      { config, nodes, ... }:
      {
        imports = [
          sopsModule
          ../../headscale-vps/configuration.nix
          ../../headscale-vps/modules/caddy.nix
          ../../headscale-vps/modules/headscale.nix
          ../../headscale-vps/modules/authentik.nix

          profiles.noBootloader
          profiles.noDhcp
          profiles.manualTailscaleAutoconnect
          (profiles.sopsFixture ../fixtures/vps.sops.yaml)
          (profiles.pebbleTrust {
            caDomain = nodes.acme.test-support.acme.caDomain;
            caCert = nodes.acme.test-support.acme.caCert;
          })
          (profiles.sized {
            memoryMB = 4096;
            diskMB = 16384;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = [
              images."ghcr_io_goauthentik_server_2026_5_6"
              images."postgres_16_13-alpine"
              images."redis_7_4-alpine"
            ];
            beforeUnits = [ "authentik.service" ];
          })
        ];

        # The rotation, as a bootable sibling configuration. Its ONLY delta is
        # the sops file — exactly what a real rotation commit would change.
        # switch-to-configuration then has to do all the work restartUnits
        # promises.
        specialisation.rotated.configuration = {
          # mkOverride 40: the specialisation re-evaluates WITH the parent's
          # modules, so profiles.sopsFixture's mkForce (50) is present here
          # too and must lose.
          sops.defaultSopsFile = lib.mkOverride 40 ../fixtures/vps-rotated.sops.yaml;
        };

        services.caddy.globalConfig = lib.mkAfter ''
          acme_ca https://${nodes.acme.test-support.acme.caDomain}/dir
        '';
        security.pki.certificateFiles = [ nodes.acme.test-support.acme.caCert ];
        networking.hosts."127.0.0.1" = [
          headscaleHost
          authHost
        ];

        environment.systemPackages = [ pkgs.jq ];
      };

    acme =
      { nodes, ... }:
      {
        imports = [ acmeServerModule ];
        networking.hosts.${nodes.vps.networking.primaryIPAddress} = [
          headscaleHost
          authHost
        ];
      };
  };

  testScript =
    { nodes, ... }:
    ''
      OLD = "test0oidc0client0secret0deadbeef0deadbeef0dead"
      NEW = "rotated0oidc0secret0cafebabe0cafebabe0cafebabe"
      SECRET = "${nodes.vps.sops.secrets.HEADSCALE_OIDC_CLIENT_SECRET.path}"
      ENVFILE = "${nodes.vps.sops.templates."authentik.env".path}"

      def diag():
          for label, cmd in [
              ("activation journal", "journalctl -u '*sops*' --no-pager | tail -30"),
              ("headscale unit", "systemctl status headscale --no-pager | head -15"),
              ("authentik unit", "systemctl status authentik --no-pager | head -15"),
              ("docker ps", "docker ps -a"),
          ]:
              print(f"=== {label} ===")
              print(headscale_vps.execute(cmd)[1])

      start_all()
      acme.wait_for_unit("pebble.service")
      headscale_vps.wait_for_unit("headscale.service")

      # authentik.service is a oneshot with a long --wait; being active means
      # all four containers passed their healthchecks.
      headscale_vps.wait_until_succeeds(
          "systemctl is-active --quiet authentik.service", timeout=900
      )

      with subtest("baseline: both consumers hold the OLD secret"):
          assert headscale_vps.succeed(f"cat {SECRET}").strip() == OLD
          headscale_vps.succeed(f"grep -qF 'HEADSCALE_OIDC_CLIENT_SECRET={OLD}' {ENVFILE}")

      # Identity of the running processes, to prove restarts happened rather
      # than the units merely remaining active across activation.
      hs_pid = headscale_vps.succeed(
          "systemctl show -p MainPID --value headscale").strip()
      ak_inv = headscale_vps.succeed(
          "systemctl show -p InvocationID --value authentik").strip()

      with subtest("a real activation rotates the secret"):
          try:
              # No `| tail`: the driver's shell has no pipefail, so a pipe
              # would report tail's exit 0 and a failed activation would slip
              # through with every later assertion blaming the wrong thing.
              # Capture instead and tail in python — succeed() then asserts
              # switch-to-configuration's own exit code.
              out = headscale_vps.succeed(
                  "/run/current-system/specialisation/rotated"
                  "/bin/switch-to-configuration test 2>&1"
              )
              print("\n".join(out.splitlines()[-20:]))
          except Exception:
              diag()
              raise
          val = headscale_vps.succeed(f"cat {SECRET}").strip()
          assert val == NEW, f"secret file was not rotated: {val!r}"
          headscale_vps.succeed(f"grep -qF 'HEADSCALE_OIDC_CLIENT_SECRET={NEW}' {ENVFILE}")

      with subtest("restartUnits restarted headscale"):
          # A stable render path means NOTHING else would restart this unit —
          # restartUnits is the only thing standing between a rotation and a
          # silently stale OIDC secret (the module comment, verified).
          headscale_vps.wait_until_succeeds(
              "systemctl is-active --quiet headscale", timeout=120
          )
          new_pid = headscale_vps.succeed(
              "systemctl show -p MainPID --value headscale").strip()
          assert new_pid != hs_pid and new_pid != "0", (
              f"headscale did not restart (pid {hs_pid} -> {new_pid})"
          )

      with subtest("restartUnits restarted authentik (compose reconverges)"):
          try:
              headscale_vps.wait_until_succeeds(
                  "systemctl is-active --quiet authentik.service", timeout=900
              )
          except Exception:
              diag()
              raise
          new_inv = headscale_vps.succeed(
              "systemctl show -p InvocationID --value authentik").strip()
          assert new_inv != ak_inv, "authentik.service was not restarted"

      with subtest("the rotated value reaches the worker environment"):
          # The blueprint's !Env reads the worker's environment; compose must
          # therefore have RECREATED the worker with the new EnvironmentFile,
          # not just left the old container running. If this holds but the
          # provider row still carries the old secret, the remaining gap is
          # blueprint re-application — checks.authentik owns that surface;
          # this suite pins the plumbing up to the container boundary.
          try:
              headscale_vps.wait_until_succeeds(
                  "docker exec authentik_worker printenv HEADSCALE_OIDC_CLIENT_SECRET"
                  f" | grep -qxF '{NEW}'",
                  timeout=120,
              )
          except Exception:
              diag()
              print(headscale_vps.execute(
                  "docker exec authentik_worker printenv | grep -i headscale")[1])
              raise
    '';
}
