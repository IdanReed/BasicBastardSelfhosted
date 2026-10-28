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
#   - Accounts: idan is the one declared user and an Authentik superuser; the
#     six retired names are absent, and the never-logged-in guard on those
#     entries spares an invited account with the same name. invite-enrollment
#     refuses to run without an invitation; invite.sh's own API calls mint a
#     single-use 7-day invitation with the identity fixed; and that invitation
#     enrolls a user end to end through the flow executor — the fixed username
#     and email win over a tampered POST, the password policy bites, TOTP is
#     set up before the session exists, the user lands in headscale-users —
#     whose next login then asks for the TOTP device.
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

  # invite.sh's remote half, byte for byte: the heredoc it pipes to the VPS.
  # Run here as root against the real Authentik, so the API calls it makes are
  # the ones under test.
  inviteRemote = pkgs.writeText "invite-remote.sh" (
    let
      after = lib.elemAt (lib.splitString "<<'REMOTE'\n" (
        builtins.readFile ../../headscale-vps/invite.sh
      )) 1;
    in
    lib.head (lib.splitString "\nREMOTE\n" after)
  );
in
pkgs.testers.runNixOSTest {
  name = "authentik";

  # Authentik's 900-iteration polls can overrun the 3600s default on a slow
  # runner (iterations cost command duration + 1s, not 1s).
  globalTimeout = 7200;

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
              images."ghcr_io_goauthentik_server_2026_8_5"
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
    let
      # Subtest (b)'s key set, read off the module's OWN template: a variable
      # added there cannot leave the assertion behind on a stale hand-kept list.
      envKeys = lib.concatMap (
        line:
        let
          m = builtins.match "([A-Z][A-Z0-9_]*)=.*" line;
        in
        lib.optional (m != null) (builtins.head m)
      ) (lib.splitString "\n" nodes.vps.sops.templates."authentik.env".content);
    in
    ''
      import base64
      import hashlib
      import hmac
      import json
      import shlex
      import struct
      import time
      import urllib.parse
      from datetime import datetime, timedelta, timezone

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
      # blueprint !Env -> DB, exactly like headscale's. It is stored ONCE, in
      # secrets/shared.sops.json, which the services VM reads too; this suite
      # pins the VPS end and the immich suite the stack end, both against
      # tests/fixtures/shared.sops.json.
      IMMICH_OIDC_FIXTURE = "test_immich_oidc_client_secret_not_secret"
      # Same shape as immich: OUTLINE_OIDC_CLIENT_SECRET in the shared file.
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

              # One line per variable, bare values, nothing else: with the old
              # dotenv layout each placeholder expanded to the WHOLE decrypted
              # document (sops-nix never applies the per-key extraction for
              # dotenv — the finding that forced the migration to
              # secrets.sops.yaml), which the line count and the KEY=-inside-a-
              # value check below each catch. expected_keys is DERIVED from the
              # module's template, so it cannot drift out of date.
              expected_keys = set(json.loads('${builtins.toJSON envKeys}'))
              assert len(expected_keys) > 20, (
                  f"only {len(expected_keys)} keys parsed out of the module's "
                  f"template — the derivation has rotted, fix it before "
                  f"trusting this subtest"
              )
              lines = [l for l in headscale_vps.succeed(f"cat {tmpl}").splitlines() if l]
              assert len(lines) == len(expected_keys), (
                  f"{tmpl} has {len(lines)} non-empty lines for "
                  f"{len(expected_keys)} variables"
              )

              rendered = {}
              for line in lines:
                  key, sep, value = line.partition("=")
                  assert sep and key.isidentifier() and key.isupper(), \
                      f"not a KEY=value line: {line!r}"
                  assert key not in rendered, f"{key} rendered twice"
                  rendered[key] = value
              assert set(rendered) == expected_keys, (
                  f"template did not render the module's key set:\n"
                  f"missing: {expected_keys - set(rendered)}\n"
                  f"unexpected: {set(rendered) - expected_keys}"
              )
              for key, value in rendered.items():
                  assert value and value == value.strip(), \
                      f"{key} rendered empty or padded: {value!r}"
                  assert '"' not in value and "'" not in value, \
                      f"{key} rendered quoted: {value!r}"
                  assert not value.lower().startswith("changeme"), \
                      f"{key} is still a placeholder: {value!r}"
                  assert not any(f"{k}=" in value for k in expected_keys), \
                      f"{key}'s value carries another variable — the dotenv "\
                      f"whole-document expansion is back: {value!r}"
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
      # (c5) Accounts: idan is declared, everyone else enrolls by invitation
      # ---------------------------------------------------------------------
      # Flows go through Caddy on the public name: the session cookie is scoped
      # to AUTHENTIK_COOKIE_DOMAIN, so on 127.0.0.1 every request would start
      # a fresh plan and a single-use invitation would be spent by the first
      # one.
      AKPUB = "https://${authHost}"
      RETIRED = ["alondra", "cale", "zach", "rylan", "cameron", "justin"]
      # One of the retired names on purpose: the enrolled account must survive
      # the absent entries that delete the never-used one.
      INVITEE = "cale"
      INVITEE_EMAIL = "cale@example.com"
      INVITEE_NAME = "Cale Invited"
      INVITEE_PW = "invitee-test-password-not-secret"

      def users_named(name):
          out = json.loads(headscale_vps.succeed(
              f"{CURL} '{API}/core/users/?username={name}'"))
          return [u for u in out["results"] if u["username"] == name]

      def apply_blueprint(name):
          """Re-apply one blueprint and wait for the run to finish."""
          out = json.loads(headscale_vps.succeed(
              f"{CURL} '{API}/managed/blueprints/?name={name}'"))
          inst = [i for i in out["results"] if i["name"] == name]
          assert len(inst) == 1, f"blueprint instances named {name}: {inst}"
          pk, before = inst[0]["pk"], inst[0]["last_applied"]
          headscale_vps.succeed(
              f"{CURL} -X POST '{API}/managed/blueprints/{pk}/apply/' >/dev/null")
          headscale_vps.wait_until_succeeds(
              f"{CURL} '{API}/managed/blueprints/{pk}/' | jq -e "
              + shlex.quote(f'.last_applied != "{before}" and .status == "successful"'),
              timeout=180,
          )

      def run_flow(jar, slug, query="", body=None):
          """One flow-executor round trip; follows the executor's own redirects
          to the next challenge, as the SPA does."""
          cmd = (f"curl -sS {CA} --max-time 30 -L -c {jar} -b {jar} "
                 "-H 'Accept: application/json'")
          if body is not None:
              cmd += (" -H 'Content-Type: application/json' -d "
                      + shlex.quote(json.dumps(body)))
          url = f"{AKPUB}/api/v3/flows/executor/{slug}/?query=" + urllib.parse.quote(query)
          return json.loads(headscale_vps.succeed(f"{cmd} '{url}'"))

      def totp_now(config_url):
          """RFC 6238 code for the device's secret, at the VM's clock."""
          secret = urllib.parse.parse_qs(urllib.parse.urlparse(config_url).query)["secret"][0]
          key = base64.b32decode(secret + "=" * (-len(secret) % 8), casefold=True)
          now = int(headscale_vps.succeed("date +%s").strip())
          digest = hmac.new(key, struct.pack(">Q", now // 30), hashlib.sha1).digest()
          off = digest[-1] & 0x0F
          code = (struct.unpack(">I", digest[off:off + 4])[0] & 0x7FFFFFFF) % 1000000
          return f"{code:06d}"

      def prompt_body(username, email, password):
          return {"component": "ak-stage-prompt", "username": username,
                  "email": email, "name": INVITEE_NAME,
                  "password": password, "password_repeat": password}

      with subtest("idan is the one declared user, an Authentik superuser; the retired six are gone"):
          try:
              headscale_vps.wait_until_succeeds(
                  f"{CURL} '{API}/flows/instances/invite-enrollment/' >/dev/null",
                  timeout=300,
              )
              # Caddy's certificate, for the flows below.
              headscale_vps.wait_until_succeeds(
                  f"curl -sf {CA} --max-time 10 {AKPUB}/api/v3/root/config/ >/dev/null",
                  timeout=180,
              )
              idan = users_named("idan")
              assert len(idan) == 1 and idan[0]["is_superuser"] is True, (
                  f"idan is not an Authentik superuser (Admin group): {idan}")
              for name in RETIRED:
                  assert not users_named(name), f"retired account {name!r} exists"

              # The absent entries act on a real account: a never-logged-in
              # `zach` is deleted by the next apply.
              headscale_vps.succeed(
                  f"{CURL} -X POST -H 'Content-Type: application/json' -d "
                  + shlex.quote(json.dumps({"username": "zach", "name": "Zach",
                                            "path": "users"}))
                  + f" '{API}/core/users/' >/dev/null")
              assert users_named("zach")
              apply_blueprint("headscale-oidc")
              assert not users_named("zach"), "state: absent left zach in place"

              # Invitee edits are refused later; this is the tenant half.
              settings = json.loads(headscale_vps.succeed(f"{CURL} '{API}/admin/settings/'"))
              assert settings["default_user_change_email"] is False, settings
              assert settings["default_user_change_username"] is False, settings
          except Exception:
              authentik_diag()
              raise

      with subtest("invite-enrollment refuses to run without a valid invitation"):
          fl = json.loads(headscale_vps.succeed(
              f"{CURL} '{API}/flows/instances/invite-enrollment/'"))
          assert fl["designation"] == "enrollment", fl
          assert fl["authentication"] == "require_unauthenticated", fl
          for query in ["", "itoken=00000000-0000-4000-8000-000000000000"]:
              headscale_vps.succeed("rm -f /tmp/noinv.jar")
              c = run_flow("/tmp/noinv.jar", "invite-enrollment", query)
              assert c["component"] == "ak-stage-access-denied", (
                  f"enrollment with query {query!r} reached {c['component']}: {c}")

      with subtest("invite.sh mints a single-use 7-day invitation with the identity fixed"):
          try:
              out = headscale_vps.succeed(
                  f"bash ${inviteRemote} {INVITEE} {INVITEE_EMAIL} {shlex.quote(INVITEE_NAME)}")
              link = [l for l in out.split() if "itoken=" in l]
              assert len(link) == 1, f"invite.sh printed no single link:\n{out}"
              assert link[0].startswith(
                  "https://${authHost}/if/flow/invite-enrollment/?itoken="), link
              itoken = link[0].split("itoken=", 1)[1]

              inv = json.loads(headscale_vps.succeed(
                  f"{CURL} '{API}/stages/invitation/invitations/{itoken}/'"))
              assert inv["single_use"] is True, inv
              assert inv["flow_obj"]["slug"] == "invite-enrollment", inv
              assert inv["fixed_data"] == {"username": INVITEE, "email": INVITEE_EMAIL,
                                           "name": INVITEE_NAME}, inv["fixed_data"]
              vm_now = datetime.fromtimestamp(
                  int(headscale_vps.succeed("date +%s").strip()), timezone.utc)
              left = datetime.fromisoformat(inv["expires"].replace("Z", "+00:00")) - vm_now
              assert timedelta(days=7) - timedelta(minutes=10) < left <= timedelta(days=7), (
                  f"invitation expires in {left}, not 7 days")

              # A second run reprints the unused invitation instead of minting
              # another.
              again = headscale_vps.succeed(
                  f"bash ${inviteRemote} {INVITEE} {INVITEE_EMAIL} {shlex.quote(INVITEE_NAME)}")
              assert link[0] in again and "already has an unused invitation" in again, again

              # An existing username, or an existing email in any case, is refused.
              headscale_vps.fail("bash ${inviteRemote} idan someone@example.com Someone")
              headscale_vps.fail("bash ${inviteRemote} someone IDAN@idanreed.com Someone")
          except Exception:
              authentik_diag()
              raise

      with subtest("an invitation without fixed_data cannot enroll anyone"):
          # The read-only prompts hold whatever the invitation fixed — here,
          # nothing — and a posted username/email never replaces it.
          fl_pk = json.loads(headscale_vps.succeed(
              f"{CURL} '{API}/flows/instances/invite-enrollment/'"))["pk"]
          bare = json.loads(headscale_vps.succeed(
              f"{CURL} -X POST -H 'Content-Type: application/json' -d "
              + shlex.quote(json.dumps({"name": "bare", "flow": fl_pk,
                                        "single_use": True, "fixed_data": {}}))
              + f" '{API}/stages/invitation/invitations/'"))["pk"]
          headscale_vps.succeed("rm -f /tmp/bare.jar")
          c = run_flow("/tmp/bare.jar", "invite-enrollment", f"itoken={bare}")
          assert c["component"] == "ak-stage-prompt", c
          c = run_flow("/tmp/bare.jar", "invite-enrollment", f"itoken={bare}",
                   prompt_body("mallory", "mallory@example.com", INVITEE_PW))
          assert c["component"] == "ak-stage-prompt" and c.get("response_errors"), (
              f"an empty invitation got past the prompt: {c}")
          assert not users_named("mallory"), "an empty invitation created an account"

      with subtest("the invitation enrolls a user end to end, with the fixed identity and TOTP"):
          try:
              jar = "/tmp/enroll.jar"
              headscale_vps.succeed(f"rm -f {jar}")
              query = f"itoken={itoken}"

              c = run_flow(jar, "invite-enrollment", query)
              assert c["component"] == "ak-stage-prompt", c
              fields = {f["field_key"]: f for f in c["fields"]}
              for key, want in [("username", INVITEE), ("email", INVITEE_EMAIL)]:
                  assert fields[key]["type"] == "text_read_only", fields[key]
                  assert fields[key]["initial_value"] == want, fields[key]
              assert fields["name"]["initial_value"] == INVITEE_NAME, fields["name"]

              # The password policy bites before anything is written.
              c = run_flow(jar, "invite-enrollment", query,
                       prompt_body(INVITEE, INVITEE_EMAIL, "short"))
              assert c["component"] == "ak-stage-prompt" and c.get("response_errors"), c

              # A tampered POST: another username, and idan's email. The
              # invitation's values must be the ones written.
              c = run_flow(jar, "invite-enrollment", query,
                       prompt_body("mallory", "idan@idanreed.com", INVITEE_PW))
              assert c["component"] == "ak-stage-authenticator-totp", (
                  f"after the prompt the flow reached {c['component']}, not TOTP "
                  f"setup: {c}")
              # Written, but not logged in: no session before a device exists.
              assert users_named(INVITEE), "the user write stage did not run"
              whoami = headscale_vps.succeed(
                  f"curl -s {CA} -o /dev/null -w '%{{http_code}}' -b {jar} "
                  f"'{AKPUB}/api/v3/core/users/me/'"
              ).strip()
              assert whoami in ("401", "403"), (
                  f"a session exists before TOTP setup (users/me/ answered {whoami})")

              c = run_flow(jar, "invite-enrollment", query,
                       {"component": "ak-stage-authenticator-totp",
                        "code": totp_now(c["config_url"])})
              assert c["component"] == "xak-flow-redirect", (
                  f"enrollment did not finish after TOTP setup: {c}")
              # The positive control for the 401/403 above: the same jar now
              # carries a session, as the invitee.
              me = json.loads(headscale_vps.succeed(
                  f"curl -sf {CA} -b {jar} '{AKPUB}/api/v3/core/users/me/'"))
              assert me["user"]["username"] == INVITEE, me

              assert not users_named("mallory"), "the posted username was written"
              u = users_named(INVITEE)
              assert len(u) == 1, u
              u = u[0]
              assert u["email"] == INVITEE_EMAIL, f"email is {u['email']!r}"
              assert u["name"] == INVITEE_NAME and u["type"] == "internal" \
                  and u["path"] == "users" and u["is_active"], u
              groups = sorted(g["name"] for g in u["groups_obj"])
              assert groups == ["headscale-users"], f"{INVITEE} is in {groups}"
              assert u["last_login"], "enrollment did not log the user in"
              owners = json.loads(headscale_vps.succeed(
                  f"{CURL} '{API}/core/users/?email=idan@idanreed.com'"))["results"]
              assert [o["username"] for o in owners] == ["idan"], owners

              devices = json.loads(headscale_vps.succeed(
                  f"{CURL} '{API}/authenticators/admin/totp/'"))["results"]
              mine = [d for d in devices if d["user"]["pk"] == u["pk"]]
              assert len(mine) == 1 and mine[0]["confirmed"], devices

              # Single use: the link is spent.
              headscale_vps.succeed("rm -f /tmp/reuse.jar")
              c = run_flow("/tmp/reuse.jar", "invite-enrollment", query)
              assert c["component"] == "ak-stage-access-denied", c

              # And the absent entry for `cale` does not touch it.
              apply_blueprint("headscale-oidc")
              assert users_named(INVITEE), "the absent entry deleted an enrolled account"
          except Exception:
              authentik_diag()
              raise

      with subtest("the enrolled user's login asks for the TOTP device"):
          jar = "/tmp/login.jar"
          headscale_vps.succeed(f"rm -f {jar}")
          c = run_flow(jar, "default-authentication-flow")
          assert c["component"] == "ak-stage-identification", c
          c = run_flow(jar, "default-authentication-flow", body={
              "component": "ak-stage-identification", "uid_field": INVITEE})
          assert c["component"] == "ak-stage-password", c
          c = run_flow(jar, "default-authentication-flow", body={
              "component": "ak-stage-password", "password": INVITEE_PW})
          assert c["component"] == "ak-stage-authenticator-validate", (
              f"password login went to {c['component']} without asking for "
              f"the TOTP device: {c}")
          assert [d["device_class"] for d in c["device_challenges"]] == ["totp"], c

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

      # ---------------------------------------------------------------------
      # Every custom blueprint applied — not only the three checked above.
      # Authentik rolls a failing blueprint back and says so only in the
      # worker log, so status is read from the BlueprintInstance rows, and
      # the objects the OIDC wave added are checked by name.
      # ---------------------------------------------------------------------
      with subtest("every custom blueprint applied, with the -sso, SAML and Admin-binding objects"):
          check = "\n".join([
              "import json",
              "from authentik.blueprints.models import BlueprintInstance",
              "from authentik.core.models import Application",
              "from authentik.providers.saml.models import SAMLProvider",
              "from authentik.providers.proxy.models import ProxyProvider",
              "from authentik.policies.models import PolicyBinding",
              "bound = []",
              "for b in PolicyBinding.objects.filter(group__name='Admin'):",
              "    app = Application.objects.filter(pk=b.target.pk).first()",
              "    if app: bound.append(app.slug)",
              "print('JSON' + json.dumps({",
              "    'bp': {i.path: i.status for i in BlueprintInstance.objects.filter(path__startswith='custom/')},",
              "    'apps': sorted(Application.objects.values_list('slug', flat=True)),",
              "    'saml': sorted(SAMLProvider.objects.values_list('name', flat=True)),",
              "    'proxy': sorted(ProxyProvider.objects.values_list('name', flat=True)),",
              "    'bound': sorted(bound)}))",
          ])
          headscale_vps.succeed(
              "cat > /tmp/bpcheck.py <<'BPEOF'\n" + check + "\nBPEOF\n"
              "docker cp /tmp/bpcheck.py authentik_worker:/tmp/bpcheck.py"
          )

          def bpstate():
              out = headscale_vps.succeed(
                  "docker exec authentik_worker ak shell -c "
                  "\"exec(open('/tmp/bpcheck.py').read())\" 2>/dev/null"
              )
              line = [l for l in out.splitlines() if l.startswith("JSON")][-1]
              return json.loads(line[4:])

          try:
              deadline = time.time() + 300
              while True:
                  st = bpstate()
                  bad = {k: v for k, v in st["bp"].items() if v != "successful"}
                  if not bad or time.time() > deadline:
                      break
                  time.sleep(10)
              assert st["bp"] and not bad, f"custom blueprints not applied: {bad}"
              for slug in ["grafana-sso", "komodo-sso", "profilarr-sso",
                           "cleanuparr-sso", "beszel-sso", "windmill-sso",
                           "wger-sso", "docspace", "backrest"]:
                  assert slug in st["apps"], f"application {slug!r} missing: {st['apps']}"
              assert "jellyfin" not in st["apps"], "the retired jellyfin application exists"
              assert "docspace" in st["saml"], f"no docspace SAML provider: {st['saml']}"
              assert "backrest" in st["proxy"], f"no backrest proxy provider: {st['proxy']}"
              for slug in ["grafana-sso", "komodo-sso", "profilarr-sso",
                           "cleanuparr-sso", "beszel-sso"]:
                  assert slug in st["bound"], f"{slug} is not bound to Admin: {st['bound']}"
              for slug in ["windmill-sso", "wger-sso"]:
                  assert slug not in st["bound"], f"{slug} must stay open to all users"
          except Exception:
              authentik_diag()
              raise

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
