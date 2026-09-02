# Authentik: the OIDC provider, its blueprints, and the secret contract with
# Headscale.
#
# Heavy tier — the Authentik image is over a gigabyte and first start runs the
# full DB migration suite, so this takes minutes, not seconds. What is
# genuinely under test:
#   - authentik.service (modules/authentik.nix) converging: `compose up -d
#     --wait` against the real healthchecks, all four containers healthy, and
#     the project name pinned to "authentik" — the store-path contract the
#     module's comments stake out (without -p, compose derives the project
#     from the /nix/store directory name, which changes every rebuild and
#     orphans the previous containers)
#   - sops.templates rendering bare per-key values into the EnvironmentFile
#     (the dotenv whole-document failure mode, this time on the template path)
#   - the headscale-oidc blueprint applying against the *pinned* Authentik:
#     provider, application, group, user — and the override-by-name of the
#     built-in MFA stage, which is version-sensitive by construction
#   - the immich-oidc blueprint applying independently (findings #7/#9 are
#     per-file failure modes, so one blueprint converging proves nothing
#     about the other): provider, application, the three strict redirect
#     URIs, and the client_secret round-tripping !Env -> DB
#   - THE three-way secret contract: the fixture value, headscale's
#     client_secret_path, and the provider row Authentik stores must all be
#     equal. The value travels two independent paths (sops -> headscale's
#     secret file; sops -> template -> worker env -> blueprint !Env -> DB) and
#     nothing else ever compares the two ends.
#   - OIDC discovery end to end: headscale restarted after Authentik is
#     healthy sets up its OIDC provider through Caddy over verified TLS.
#
# The vps suite covers everything else about this host (firewall, ssh, tailnet,
# ACME details); it stands in a nginx stub for :9000. This suite is the stub
# made real.
#
# What is overridden and why lives in ../lib/profiles.nix. The only suite-local
# override is the ACME endpoint, same as vps.nix: Let's Encrypt is unreachable
# from a sandboxed VM, so Caddy is pointed at Pebble. The client, the HTTP-01
# challenge and the certificate installation are all real.

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
  name = "authentik";

  nodes = {
    # ---------------------------------------------------------------------
    # The host under test — the full VPS, Authentik included
    # ---------------------------------------------------------------------
    vps =
      { config, nodes, pkgs, ... }:
      {
        imports = [
          sopsModule
          ../../headscale-vps/configuration.nix
          ../../headscale-vps/modules/caddy.nix
          ../../headscale-vps/modules/headscale.nix
          ../../headscale-vps/modules/authentik.nix

          profiles.noBootloader
          profiles.noDhcp
          # The fixture TAILSCALE_AUTH_KEY is a placeholder; letting
          # tailscale-autoconnect run at boot would retry forever and hold up
          # multi-user.target. The tailnet join itself is the vps suite's job.
          profiles.manualTailscaleAutoconnect
          (profiles.sopsFixture ../fixtures/vps.sops.yaml)
          (profiles.pebbleTrust {
            caDomain = nodes.acme.test-support.acme.caDomain;
            caCert = nodes.acme.test-support.acme.caCert;
          })
          # Authentik will not finish its migrations below ~3GB, and postgres +
          # redis + two Authentik processes need headroom on top. The disk
          # holds the multi-GB image tarballs plus pgdata.
          (profiles.sized {
            memoryMB = 4096;
            diskMB = 16384;
          })
          # authentik.service is wantedBy multi-user.target and its compose
          # `up --wait` runs during boot, before the test script has control —
          # so the images must be in docker before it starts. The pull in its
          # ExecStartPre is best-effort ("-" prefix) and fails harmlessly
          # offline.
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

        # Point Caddy's ACME client at Pebble — same single behavioural
        # override as vps.nix. Coverage lost: the production ACME endpoint and
        # the public A records, verifiable only against real DNS.
        services.caddy.globalConfig = lib.mkAfter ''
          acme_ca https://${nodes.acme.test-support.acme.caDomain}/dir
        '';

        security.pki.certificateFiles = [ nodes.acme.test-support.acme.caCert ];

        # Both public names live on this host; /etc/hosts stands in for DNS.
        # This is also what lets headscale's OIDC setup and the test script
        # reach auth.idanreed.com through the local Caddy.
        networking.hosts."127.0.0.1" = [
          headscaleHost
          authHost
        ];
      };

    # ---------------------------------------------------------------------
    # Pebble, standing in for Let's Encrypt
    # ---------------------------------------------------------------------
    acme =
      { nodes, ... }:
      {
        imports = [ acmeServerModule ];

        # Pebble validates HTTP-01 by connecting to the requested name on :80,
        # so both names must resolve to the VPS.
        networking.hosts.${nodes.vps.networking.primaryIPAddress} = [
          headscaleHost
          authHost
        ];
      };
  };

  testScript =
    { nodes, ... }:
    ''
      import json

      # Pebble's issuing root is fetched at runtime by profiles.pebbleTrust.
      # Never -k on these names: an unverified 200 would hide a wrong-name or
      # wrong-chain certificate.
      CA = "--cacert /var/lib/test-ca/bundle.pem"

      # Fixture values from ../fixtures/vps.sops.yaml (plaintext is readable
      # with the committed test key). The bootstrap token is consumed by the
      # worker on first start to mint an API token for akadmin — which is what
      # authenticates every API assertion below.
      TOKEN = "test0bootstrap0token0deadbeef0deadbeef0deadbeef"
      OIDC_FIXTURE = "test0oidc0client0secret0deadbeef0deadbeef0dead"
      # The immich provider's secret travels sops -> template -> worker env ->
      # blueprint !Env -> DB, exactly like headscale's — but its OTHER copy
      # lives in stacks/immich/.sops.env on a different host, so this suite can
      # only pin the VPS end against the fixture; the immich suite pins the
      # stack end against ITS fixture, and the two fixtures agreeing is what
      # closes the loop.
      IMMICH_OIDC_FIXTURE = "test_immich_oidc_client_secret_not_secret"
      # Same twin shape as immich: the other copy lives in
      # stacks/outline/.sops.env (fixture tests/fixtures/outline.sops.env),
      # and the two fixtures agreeing closes the loop.
      OUTLINE_OIDC_FIXTURE = "test_outline_oidc_client_secret_not_secret"

      API = "http://127.0.0.1:9000/api/v3"
      CURL = f"curl -sf --max-time 10 -H 'Authorization: Bearer {TOKEN}'"
      # Same but without -f, for diagnostics that need the HTTP status of a
      # failing response rather than a silent nonzero exit.
      CURL_RAW = f"curl -s --max-time 10 -H 'Authorization: Bearer {TOKEN}'"

      CONTAINERS = ["authentik_db", "authentik_redis",
                    "authentik_server", "authentik_worker"]


      def authentik_diag():
          # A silent multi-minute grind tells you nothing. Blueprint errors in
          # particular appear ONLY in the worker's logs — the API just never
          # grows the objects — so always dump them on the way out.
          for label, cmd in [
              ("docker ps", "docker ps -a"),
              ("compose projects", "docker compose ls -a"),
              ("authentik.service", "journalctl -u authentik --no-pager | tail -60"),
              ("worker logs", "docker logs authentik_worker 2>&1 | tail -100"),
              ("server logs", "docker logs authentik_server 2>&1 | tail -40"),
              ("db logs", "docker logs authentik_db 2>&1 | tail -20"),
          ]:
              print(f"=== {label} ===")
              print(headscale_vps.execute(cmd)[1])


      start_all()

      acme.wait_for_unit("pebble.service")

      # ---------------------------------------------------------------------
      # (a) The unit converges and the project name is pinned
      # ---------------------------------------------------------------------
      with subtest("authentik.service reaches active"):
          # Not wait_for_unit: the unit is Restart=on-failure, and a transient
          # failed state mid-retry would abort the wait instead of riding it
          # out. `up -d --wait` blocks on healthchecks with a 10min
          # TimeoutStartSec, and first start runs every DB migration — so be
          # generous, and dump diagnostics rather than grinding silently.
          try:
              headscale_vps.wait_until_succeeds(
                  "systemctl is-active --quiet authentik.service", timeout=900
              )
          except Exception:
              authentik_diag()
              raise

      with subtest("all four containers are up and healthy"):
          # `up --wait` returning proves this once, but assert it directly so
          # a container that crashes right after the unit settles is caught
          # here and not three subtests later. All four define healthchecks.
          # This is exactly the case where the one-line inspect state is not
          # enough — dump the container logs on the way out.
          try:
              for c in CONTAINERS:
                  state = headscale_vps.succeed(
                      f"docker inspect -f '{{{{.State.Status}}}} {{{{.State.Health.Status}}}}' {c}"
                  ).strip()
                  assert state == "running healthy", f"{c} is {state!r}"
          except Exception:
              authentik_diag()
              raise

      with subtest("the compose project is named exactly 'authentik'"):
          # The store-path pinning contract from modules/authentik.nix: without
          # `-p authentik`, compose derives the project from the /nix/store
          # directory name, which changes on every rebuild and would orphan
          # the previous generation's containers.
          projects = json.loads(
              headscale_vps.succeed("docker compose ls --format json")
          )
          names = sorted(p["Name"] for p in projects)
          assert names == ["authentik"], f"compose projects: {names}"

      # ---------------------------------------------------------------------
      # (b) The sops template renders bare per-key values
      # ---------------------------------------------------------------------
      with subtest("the rendered EnvironmentFile is 0400 with bare values"):
          try:
              tmpl = "${nodes.vps.sops.templates."authentik.env".path}"
              mode = headscale_vps.succeed(f"stat -c '%a' {tmpl}").strip()
              assert mode == "400", f"{tmpl} is mode {mode}, expected 400"

              # Exact set equality on purpose: with the old dotenv layout each
              # placeholder expanded to the WHOLE decrypted document (sops-nix
              # never applies the per-key extraction for dotenv — the finding
              # that forced the migration to secrets.sops.yaml). One line per
              # variable, bare values, nothing else, is what keeps that fixed.
              lines = set(headscale_vps.succeed(f"cat {tmpl}").splitlines()) - {""}
              expected = {
                  "PG_PASS=test_pg_password_not_secret",
                  "AUTHENTIK_SECRET_KEY=test_authentik_secret_key_not_secret_0000000000",
                  "HEADSCALE_OIDC_CLIENT_SECRET=test0oidc0client0secret0deadbeef0deadbeef0dead",
                  "AUTHENTIK_BOOTSTRAP_PASSWORD=test_bootstrap_password",
                  "AUTHENTIK_BOOTSTRAP_TOKEN=test0bootstrap0token0deadbeef0deadbeef0deadbeef",
                  "IMMICH_OIDC_CLIENT_SECRET=test_immich_oidc_client_secret_not_secret",
                  "OUTLINE_OIDC_CLIENT_SECRET=test_outline_oidc_client_secret_not_secret",
              }
              assert lines == expected, (
                  f"template did not render bare per-key values:\n"
                  f"missing: {expected - lines}\nunexpected: {lines - expected}"
              )
          except Exception:
              authentik_diag()
              raise

      # ---------------------------------------------------------------------
      # (c) The blueprint actually applied
      # ---------------------------------------------------------------------
      # Blueprints are discovered and applied by the worker asynchronously
      # AFTER its healthcheck passes, so "service active" does not mean
      # "objects exist" — poll, generously. The entries apply in file order
      # with the user last, so the group membership converging implies the
      # rest of the file was processed.
      with subtest("the headscale-oidc blueprint has been applied"):
          for what, cmd in [
              # Exact-name selection, not .results[0]: the ?name= filter is
              # fuzzy-at-best, and with the immich provider in the same DB
              # the first row is whichever sorts first (sweep-12 lesson).
              ("oauth2 provider 'headscale' with client_id 'headscale'",
               f"{CURL} '{API}/providers/oauth2/?name=headscale' "
               "| jq -e '[.results[] | select(.name == \"headscale\")] "
               "| length == 1 and .[0].client_id == \"headscale\"'"),
              ("application with slug 'headscale'",
               f"{CURL} '{API}/core/applications/headscale/' "
               "| jq -e '.slug == \"headscale\"'"),
              ("group 'headscale-users' containing user 'idan'",
               f"{CURL} '{API}/core/groups/?name=headscale-users&include_users=true' "
               "| jq -e '[.results[] | select(.name == \"headscale-users\")] "
               "| length == 1 and (.[0].users_obj | map(.username) "
               "| index(\"idan\") != null)'"),
          ]:
              try:
                  headscale_vps.wait_until_succeeds(cmd, timeout=300)
              except Exception:
                  print(f"blueprint object never appeared: {what}")
                  # Distinguish the three ways this fails: the poll's auth is
                  # broken (HTTP status), the blueprint was never DISCOVERED
                  # (instance list empty of it), or it was discovered but
                  # failed to APPLY (instance status/logs).
                  for label, dcmd in [
                      ("api status, raw",
                       f"{CURL_RAW} -i '{API}/providers/oauth2/?name=headscale' | head -30"),
                      ("blueprint instances",
                       f"{CURL} '{API}/managed/blueprints/' "
                       "| jq '.results[] | {name, path, status, last_applied}'"),
                      ("custom dir in worker",
                       "docker exec authentik_worker ls -la /blueprints/custom"),
                      ("worker log: custom blueprint",
                       "docker logs authentik_worker 2>&1 "
                       "| grep -iE 'headscale|custom|discover' | tail -30"),
                      ("headscale-oidc instance object",
                       f"{CURL} '{API}/managed/blueprints/' "
                       "| jq '.results[] | select(.name | test(\"headscale\"))'"),
                      ("worker errors",
                       "docker logs authentik_worker 2>&1 "
                       "| grep -iE '\"level\": \"(error|warning)\"|Traceback|exc_type' "
                       "| tail -40"),
                  ]:
                      print(f"=== {label} ===")
                      print(headscale_vps.execute(dcmd)[1])
                  authentik_diag()
                  raise

      # ---------------------------------------------------------------------
      # (c2) The immich-oidc blueprint applied — the second custom blueprint,
      # with its own poll because findings #7/#9 are PER-FILE failure modes: a
      # bad extension or one comment-only key silently kills one blueprint
      # while the other applies fine, so headscale-oidc converging proves
      # nothing about this file.
      # ---------------------------------------------------------------------
      with subtest("the immich-oidc blueprint has been applied"):
          for what, cmd in [
              # Exact-name selection, NOT .results[0]: the list endpoint's
              # ?name= filter is fuzzy-at-best (the forward-auth suite watched
              # it return bazarr first once the media providers existed), so
              # whatever sorts first proves nothing about 'immich'.
              ("oauth2 provider 'immich' with client_id 'immich'",
               f"{CURL} '{API}/providers/oauth2/?name=immich' "
               "| jq -e '[.results[] | select(.name == \"immich\")] "
               "| length == 1 and .[0].client_id == \"immich\"'"),
              ("application with slug 'immich'",
               f"{CURL} '{API}/core/applications/immich/' "
               "| jq -e '.slug == \"immich\"'"),
          ]:
              try:
                  headscale_vps.wait_until_succeeds(cmd, timeout=300)
              except Exception:
                  print(f"blueprint object never appeared: {what}")
                  # Same disambiguation as the headscale leg: auth broken
                  # (HTTP status), never DISCOVERED (instance list), or
                  # discovered but failed to APPLY (worker logs).
                  for label, dcmd in [
                      ("api status, raw",
                       f"{CURL_RAW} -i '{API}/providers/oauth2/?name=immich' | head -30"),
                      ("blueprint instances",
                       f"{CURL} '{API}/managed/blueprints/' "
                       "| jq '.results[] | {name, path, status, last_applied}'"),
                      ("custom dir in worker",
                       "docker exec authentik_worker ls -la /blueprints/custom"),
                      ("worker log: immich blueprint",
                       "docker logs authentik_worker 2>&1 "
                       "| grep -iE 'immich|custom|discover' | tail -30"),
                      ("worker errors",
                       "docker logs authentik_worker 2>&1 "
                       "| grep -iE '\"level\": \"(error|warning)\"|Traceback|exc_type' "
                       "| tail -40"),
                  ]:
                      print(f"=== {label} ===")
                      print(headscale_vps.execute(dcmd)[1])
                  authentik_diag()
                  raise

      with subtest("immich provider: redirect URIs and the fixture secret"):
          # The client half of these URIs lives in stacks/immich/
          # immich.json.template on ANOTHER host; the oidc-contract lint ties
          # the two files statically, this asserts the provider Authentik
          # actually stores. All three are matching_mode: strict, so a missing
          # one is a hard login failure, not a degraded flow.
          try:
              providers = json.loads(headscale_vps.succeed(
                  f"{CURL} '{API}/providers/oauth2/?name=immich'"
              ))
              matches = [p for p in providers["results"] if p["name"] == "immich"]
              assert len(matches) == 1, (
                  f"expected exactly one provider named 'immich', got "
                  f"{[p['name'] for p in providers['results']]}"
              )
              detail = json.loads(headscale_vps.succeed(
                  f"{CURL} '{API}/providers/oauth2/{matches[0]['pk']}/'"
              ))

              uris = [u["url"] for u in detail["redirect_uris"]]
              for uri in ["https://immich.svc.idanreed.com/auth/login",
                          "https://immich.svc.idanreed.com/user-settings",
                          "app.immich:///oauth-callback"]:
                  assert uri in uris, (
                      f"provider is missing strict redirect_uri {uri!r} "
                      f"(has {uris!r}) — that flow 400s at the authorize "
                      "step, at login time"
                  )

              # Fixture -> template -> worker env -> !Env -> DB row. The
              # classic break is the !Env tag surviving as a literal string;
              # then immich's token exchange 401s while everything looks
              # healthy. Same API-then-Django-shell fallback as the headscale
              # leg: some versions redact client_secret even for superusers.
              stored = detail.get("client_secret") or ""
              if not stored:
                  stored = headscale_vps.succeed(
                      "docker exec authentik_worker ak shell -c "
                      "\"from authentik.providers.oauth2.models import OAuth2Provider; "
                      "print(OAuth2Provider.objects.get(name='immich').client_secret)\""
                  ).strip().splitlines()[-1]
              assert stored == IMMICH_OIDC_FIXTURE, (
                  f"Authentik stores a different immich client_secret than "
                  f"the fixture: {stored!r}"
              )
          except Exception:
              authentik_diag()
              raise

      # ---------------------------------------------------------------------
      # (c4) The outline-oidc blueprint applied — third custom blueprint,
      # own poll for the same per-file reason as (c2). Outline has NO local
      # accounts, so this provider IS the login: the stored secret matching
      # the fixture is the whole ballgame, not a detail.
      # ---------------------------------------------------------------------
      with subtest("the outline-oidc blueprint has been applied"):
          for what, cmd in [
              ("oauth2 provider 'outline' with client_id 'outline'",
               f"{CURL} '{API}/providers/oauth2/?name=outline' "
               "| jq -e '[.results[] | select(.name == \"outline\")] "
               "| length == 1 and .[0].client_id == \"outline\"'"),
              ("application with slug 'outline'",
               f"{CURL} '{API}/core/applications/outline/' "
               "| jq -e '.slug == \"outline\"'"),
          ]:
              try:
                  headscale_vps.wait_until_succeeds(cmd, timeout=300)
              except Exception:
                  print(f"blueprint object never appeared: {what}")
                  for label, dcmd in [
                      ("api status, raw",
                       f"{CURL_RAW} -i '{API}/providers/oauth2/?name=outline' | head -30"),
                      ("blueprint instances",
                       f"{CURL} '{API}/managed/blueprints/' "
                       "| jq '.results[] | {name, path, status, last_applied}'"),
                      ("worker log: outline blueprint",
                       "docker logs authentik_worker 2>&1 "
                       "| grep -iE 'outline|custom|discover' | tail -30"),
                      ("worker errors",
                       "docker logs authentik_worker 2>&1 "
                       "| grep -iE '\"level\": \"(error|warning)\"|Traceback|exc_type' "
                       "| tail -40"),
                  ]:
                      print(f"=== {label} ===")
                      print(headscale_vps.execute(dcmd)[1])
                  authentik_diag()
                  raise

      with subtest("outline provider stores the fixture secret"):
          # Fixture -> template -> worker env -> !Env -> DB row, same chain
          # as immich; a literal-!Env break here 401s every login with a
          # healthy container and empty logs.
          try:
              providers = json.loads(headscale_vps.succeed(
                  f"{CURL} '{API}/providers/oauth2/?name=outline'"
              ))
              matches = [p for p in providers["results"] if p["name"] == "outline"]
              assert len(matches) == 1, (
                  f"expected exactly one provider named 'outline', got "
                  f"{[p['name'] for p in providers['results']]}"
              )
              detail = json.loads(headscale_vps.succeed(
                  f"{CURL} '{API}/providers/oauth2/{matches[0]['pk']}/'"
              ))
              stored = detail.get("client_secret") or ""
              if not stored:
                  stored = headscale_vps.succeed(
                      "docker exec authentik_worker ak shell -c "
                      "\"from authentik.providers.oauth2.models import OAuth2Provider; "
                      "print(OAuth2Provider.objects.get(name='outline').client_secret)\""
                  ).strip().splitlines()[-1]
              assert stored == OUTLINE_OIDC_FIXTURE, (
                  f"Authentik stores a different outline client_secret than "
                  f"the fixture: {stored!r}"
              )
          except Exception:
              authentik_diag()
              raise

      # ---------------------------------------------------------------------
      # (f) The MFA override-by-name took effect
      # ---------------------------------------------------------------------
      with subtest("the built-in MFA stage is overridden to 'configure'"):
          # The blueprint overrides authentik's OWN default-authentication-
          # mfa-validation stage in place, by name, rather than binding a
          # second stage into the flow. That works only as long as the pinned
          # Authentik still ships a stage under exactly that name with
          # not_configured_action=skip — a bump of the image tag can silently
          # turn mandatory 2FA back into optional, which is precisely what
          # this assertion exists to catch.
          try:
              headscale_vps.wait_until_succeeds(
                  f"{CURL} '{API}/stages/authenticator/validate/"
                  "?name=default-authentication-mfa-validation' "
                  "| jq -e '[.results[] | select(.name == "
                  "\"default-authentication-mfa-validation\")] "
                  "| length == 1 and .[0].not_configured_action == \"configure\"'",
                  timeout=180,
              )
          except Exception:
              authentik_diag()
              raise

      # ---------------------------------------------------------------------
      # (c3) The login-hardening blueprint applied and BOUND into the flow
      # ---------------------------------------------------------------------
      # Layer 2 of the login-hardening pair (layer 1 is the fail2ban jail,
      # covered by the vps suite). A reputation policy is inert unless it is
      # bound into the authentication flow through a conditional deny stage —
      # and a mis-bound policy is finding-#9-silent: the object exists, the API
      # shows it, and nothing gates. So this does not stop at "policy exists";
      # it walks policy -> policybinding -> flowstagebinding -> flow and pins
      # the whole chain to default-authentication-flow.
      with subtest("the login-hardening reputation policy exists"):
          # Exact-name selection, never results[0]: ?name= is fuzzy and other
          # policies share the DB.
          try:
              headscale_vps.wait_until_succeeds(
                  f"{CURL} '{API}/policies/reputation/?name=login-reputation' "
                  "| jq -e '[.results[] | select(.name == \"login-reputation\")] "
                  "| length == 1 and .[0].check_ip == true "
                  "and .[0].check_username == true and .[0].threshold == -10'",
                  timeout=300,
              )
          except Exception:
              authentik_diag()
              raise

      with subtest("the reputation policy is bound to default-authentication-flow"):
          try:
              # 1. reputation policy pk, by exact name.
              pols = json.loads(headscale_vps.succeed(
                  f"{CURL} '{API}/policies/reputation/?name=login-reputation'"
              ))
              pol = [p for p in pols["results"] if p["name"] == "login-reputation"]
              assert len(pol) == 1, f"policy count: {[p['name'] for p in pols['results']]}"
              policy_pk = pol[0]["pk"]

              # 2. the policybinding that attaches it — filtered by THIS
              # policy's pk, so it cannot resolve to some other policy's
              # binding. Its target is a flowstagebinding uuid.
              binds = json.loads(headscale_vps.succeed(
                  f"{CURL} '{API}/policies/bindings/?policy={policy_pk}'"
              ))
              assert len(binds["results"]) == 1, (
                  f"expected exactly one binding of login-reputation, got "
                  f"{len(binds['results'])}"
              )
              fsb_pk = binds["results"][0]["target"]

              # 3. the flowstagebinding itself: it must target the default
              # authentication flow, sit at the conditional order, run the
              # deny stage, and carry the evaluate_on_plan/re_evaluate pair
              # that makes reputation re-check post-identification. Get either
              # flag wrong and the policy runs at plan time with an anonymous
              # user — check_username goes silently inert.
              fsb = json.loads(headscale_vps.succeed(
                  f"{CURL} '{API}/flows/bindings/{fsb_pk}/'"
              ))
              flow = json.loads(headscale_vps.succeed(
                  f"{CURL} '{API}/flows/instances/default-authentication-flow/'"
              ))
              assert fsb["target"] == flow["pk"], (
                  f"reputation deny stage is bound to flow {fsb['target']!r}, "
                  f"not default-authentication-flow ({flow['pk']!r})"
              )
              assert fsb["stage_obj"]["name"] == "login-reputation-deny", (
                  f"conditional binding runs the wrong stage: "
                  f"{fsb['stage_obj']['name']!r}"
              )
              assert fsb["evaluate_on_plan"] is False, \
                  "evaluate_on_plan must be false or check_username is inert"
              assert fsb["re_evaluate_policies"] is True, \
                  "re_evaluate_policies must be true or the deny never re-checks"
          except Exception:
              authentik_diag()
              raise

      # ---------------------------------------------------------------------
      # (d) The three-way secret contract
      # ---------------------------------------------------------------------
      with subtest("fixture == headscale's secret file == Authentik's provider row"):
          # The OIDC client secret travels two independent paths from the same
          # sops value: sops -> headscale's client_secret_path, and sops ->
          # template -> worker env -> blueprint !Env -> the DB row. A break on
          # either path (the !Env tag becoming a literal string is the classic
          # one) fails only at human login time, silently, because
          # only_start_if_oidc_is_available is false.
          try:
              hs_secret = headscale_vps.succeed(
                  "cat ${nodes.vps.sops.secrets.HEADSCALE_OIDC_CLIENT_SECRET.path}"
              ).strip()
              assert hs_secret == OIDC_FIXTURE, (
                  f"headscale's secret file is not the fixture value: {hs_secret!r}"
              )

              providers = json.loads(headscale_vps.succeed(
                  f"{CURL} '{API}/providers/oauth2/?name=headscale'"
              ))
              # Exact-name, not results[0]: two providers live here now.
              matches = [p for p in providers["results"]
                         if p["name"] == "headscale"]
              assert len(matches) == 1, (
                  f"expected exactly one provider named 'headscale', got "
                  f"{[p['name'] for p in providers['results']]}"
              )
              pk = matches[0]["pk"]
              detail = json.loads(headscale_vps.succeed(
                  f"{CURL} '{API}/providers/oauth2/{pk}/'"
              ))

              stored = detail.get("client_secret") or ""
              if not stored:
                  # Some Authentik versions redact client_secret in the API
                  # even for superusers. Fall back to reading the DB row
                  # through the worker's Django shell — same source of truth,
                  # uglier plumbing.
                  stored = headscale_vps.succeed(
                      "docker exec authentik_worker ak shell -c "
                      "\"from authentik.providers.oauth2.models import OAuth2Provider; "
                      "print(OAuth2Provider.objects.get(name='headscale').client_secret)\""
                  ).strip().splitlines()[-1]

              assert stored == OIDC_FIXTURE, (
                  f"Authentik stores a different client_secret than the fixture: {stored!r}"
              )
              assert hs_secret == stored, (
                  f"the two ends diverge: headscale={hs_secret!r} authentik={stored!r}"
              )
          except Exception:
              authentik_diag()
              raise

      # ---------------------------------------------------------------------
      # (e) OIDC discovery end to end
      # ---------------------------------------------------------------------
      with subtest("discovery through Caddy serves the issuer headscale expects"):
          # Full public path: Caddy's Pebble-issued cert, verified, proxying
          # Authentik's discovery document for the application the blueprint
          # created. Issuance races startup, so allow Caddy its retries.
          disc_cmd = (
              f"curl -sf {CA} --max-time 10 "
              "https://${authHost}/application/o/headscale/.well-known/openid-configuration"
          )
          try:
              out = headscale_vps.wait_until_succeeds(disc_cmd, timeout=180)
          except Exception:
              print("=== caddy journal ===")
              print(headscale_vps.execute(
                  "journalctl -u caddy --no-pager -o cat | tail -40")[1])
              authentik_diag()
              raise
          issuer = json.loads(out)["issuer"]
          assert issuer == "https://${authHost}/application/o/headscale/", (
              f"discovery issuer is {issuer!r} — headscale.nix pins the other "
              "spelling, and a mismatch (trailing slash included) fails token "
              "validation"
          )

      with subtest("headscale sets up its OIDC provider against the live issuer"):
          # At first boot headscale raced Authentik and its OIDC setup failed
          # by design (only_start_if_oidc_is_available = false keeps the
          # control plane bootable when the IdP is down). Now that the issuer
          # answers, a restart must succeed at it — journalled failures since
          # the restart are the silent-broken-login state.
          cursor = headscale_vps.succeed(
              "journalctl -u headscale -n 0 --show-cursor"
          ).strip().split("-- cursor: ", 1)[1]

          headscale_vps.succeed("systemctl restart headscale.service")
          headscale_vps.wait_for_unit("headscale.service")
          headscale_vps.wait_until_succeeds(
              f"curl -sf {CA} --max-time 5 https://${headscaleHost}/health",
              timeout=60,
          )
          # OIDC setup happens during startup, but give the logs a beat to
          # flush before declaring their silence meaningful.
          headscale_vps.sleep(5)

          journal = headscale_vps.succeed(
              f"journalctl -u headscale --after-cursor '{cursor}' --no-pager"
          )
          assert "failed to set up OIDC provider" not in journal, (
              f"headscale could not set up OIDC after restart:\n{journal[-2000:]}"
          )
    '';
}
