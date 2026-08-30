# Pure contract checks. No VM, no images, sub-second.
#
# These exist because the VM suites have to override the environment-specific
# values — server_url, the ACME endpoint, the sops file — and therefore cannot
# assert anything about the *production* values of those. Each lint here checks
# a contract that spans two files which nothing else keeps in sync, using the
# real values.
#
# Everything is a derivation that fails its build on violation, so `nix-build
# tests -A checks.lints` is the whole gate.

{
  pkgs,
  lib,
  vpsConfig,
  servicesConfig,
  # servicesConfig plus nixos/hardware-configuration.nix (fileSystems and grub
  # stubbed — see default.nix). Needed because the VM suites replace the
  # hardware config, so its tmpfiles rules are otherwise never evaluated.
  servicesFullConfig,
  # The relative-path module list default.nix evaluates for the VPS, for
  # cross-checking against headscale-vps/flake.nix (module-list-parity).
  vpsModuleFiles,
  images,
}:

let
  inherit (pkgs) runCommand;

  py = "${pkgs.python3.withPackages (p: [ p.pyyaml ])}/bin/python3";

  repo = ../..;

  # Stack directories, discovered rather than listed, so a new stack is covered
  # the moment it exists.
  stackNames = lib.attrNames (
    lib.filterAttrs (n: t: t == "directory" && builtins.pathExists (repo + "/stacks/${n}/compose.yaml")) (
      builtins.readDir (repo + "/stacks")
    )
  );

  composeFiles =
    (map (n: {
      stack = n;
      path = repo + "/stacks/${n}/compose.yaml";
      dir = repo + "/stacks/${n}";
    }) stackNames)
    ++ [
      {
        stack = "arcane";
        path = repo + "/arcane/compose.yaml";
        dir = repo + "/arcane";
      }
      {
        stack = "authentik";
        path = repo + "/headscale-vps/authentik/compose.yaml";
        dir = repo + "/headscale-vps/authentik";
      }
    ];

  # Keys of a dotenv file, or null when the file does not exist (null vs []
  # matters: stack-env-drift must distinguish "file absent" from "file empty").
  # Works on encrypted .sops.env too — sops encrypts dotenv VALUES but leaves
  # the KEYS plaintext, so drift is checkable without any decryption key. The
  # 'sops_' prefix filters out the metadata lines sops appends on encryption.
  dotenvKeys =
    path:
    if builtins.pathExists path then
      lib.filter (s: s != "" && !lib.hasPrefix "sops_" s) (
        map (m: builtins.head m) (
          lib.filter (m: m != null) (
            map (l: builtins.match "^([A-Za-z_][A-Za-z0-9_]*)=.*" l) (
              lib.splitString "\n" (builtins.readFile path)
            )
          )
        )
      )
    else
      null;

  manifest = pkgs.writeText "compose-manifest.json" (
    builtins.toJSON (
      map (c: {
        inherit (c) stack;
        path = "${c.path}";
        hasSopsEnv = builtins.pathExists (c.dir + "/.sops.env");
        hasSopsExample = builtins.pathExists (c.dir + "/.sops.env.example");
        sopsEnvKeys = dotenvKeys (c.dir + "/.sops.env");
        sopsExampleKeys = dotenvKeys (c.dir + "/.sops.env.example");
        fixtureKeys = dotenvKeys (../fixtures + "/${c.stack}.sops.env");
      }) composeFiles
    )
  );

  mkLint =
    name: script:
    runCommand "lint-${name}"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        set -eu
        ${script}
        touch $out
      '';
in
{
  # ---------------------------------------------------------------------------
  # OIDC: each native-OIDC consumer <-> its Authentik blueprint
  # ---------------------------------------------------------------------------
  # Values have to agree across files that nothing links. With matching_mode:
  # strict on the redirect URIs, a mismatch is not a warning — login simply
  # fails, and silently at login time rather than at startup (headscale:
  # oidc.only_start_if_oidc_is_available is false; immich: the config file is
  # applied without validation against the IdP).
  #
  # The headscale leg does NOT auto-cover other providers — it reads
  # vpsConfig's headscale settings and the headscale blueprint specifically —
  # so every new OIDC pair needs its own leg here. Immich's pair is
  # stacks/immich/immich.json.template (client side) vs immich-oidc.yaml
  # (provider side); the client secret VALUE contract (VPS sops copy == stack
  # .env copy) is not checkable without keys and stays a suite concern.
  oidc-contract =
    mkLint "oidc-contract" # bash
      ''
        ${py} - <<'PY'
        import sys, yaml

        server_url = ${builtins.toJSON vpsConfig.services.headscale.settings.server_url}
        client_id  = ${builtins.toJSON vpsConfig.services.headscale.settings.oidc.client_id}
        issuer     = ${builtins.toJSON vpsConfig.services.headscale.settings.oidc.issuer}

        with open("${(repo + "/headscale-vps/authentik/blueprints/custom/headscale-oidc.yaml")}") as f:
            # The blueprint uses !Find / !KeyOf / !Env tags that PyYAML does not
            # know. They are irrelevant here, so resolve every unknown tag to
            # its raw scalar/sequence rather than failing to parse.
            class Loose(yaml.SafeLoader):
                pass
            Loose.add_multi_constructor("!", lambda loader, suffix, node: None)
            doc = yaml.load(f, Loose)

        errs = []

        prov = next((e for e in doc["entries"]
                     if e["model"].endswith("oauth2provider")), None)
        if prov is None:
            errs.append("no oauth2provider entry in the blueprint")
        else:
            attrs = prov["attrs"]

            if attrs["client_id"] != client_id:
                errs.append(
                    f"client_id mismatch: headscale.nix has {client_id!r}, "
                    f"blueprint has {attrs['client_id']!r}")

            expected_redirect = server_url.rstrip("/") + "/oidc/callback"
            uris = [u["url"] for u in attrs["redirect_uris"]]
            if expected_redirect not in uris:
                errs.append(
                    f"redirect_uri mismatch: server_url {server_url!r} implies "
                    f"{expected_redirect!r}, blueprint offers {uris!r}")

            modes = {u.get("matching_mode") for u in attrs["redirect_uris"]}
            if modes == {"strict"} and expected_redirect not in uris:
                errs.append("matching_mode is strict, so the above is fatal at login")

        app = next((e for e in doc["entries"]
                    if e["model"] == "authentik_core.application"), None)
        if app is None:
            errs.append("no application entry in the blueprint")
        else:
            slug = app["identifiers"]["slug"]
            # Headscale's issuer must point at this application's OIDC path.
            if f"/application/o/{slug}/" not in issuer:
                errs.append(
                    f"issuer {issuer!r} does not reference the blueprint's "
                    f"application slug {slug!r}")

        # --- Immich: immich.json.template <-> immich-oidc.yaml -------------
        # The client side here is a FILE, not a nix config: immich-config-init
        # renders the template verbatim (only the secret substituted), so the
        # template's oauth block is exactly what the server will present.
        import json
        with open("${(repo + "/stacks/immich/immich.json.template")}") as f:
            tmpl = json.load(f)
        with open("${(repo + "/headscale-vps/authentik/blueprints/custom/immich-oidc.yaml")}") as f:
            idoc = yaml.load(f, Loose)

        oauth = tmpl.get("oauth") or {}
        external = (tmpl.get("server") or {}).get("externalDomain", "").rstrip("/")

        iprov = next((e for e in idoc["entries"]
                      if e["model"].endswith("oauth2provider")), None)
        if iprov is None:
            errs.append("immich: no oauth2provider entry in immich-oidc.yaml")
        else:
            iattrs = iprov["attrs"]
            if iattrs["client_id"] != oauth.get("clientId"):
                errs.append(
                    f"immich: client_id mismatch: template has "
                    f"{oauth.get('clientId')!r}, blueprint has "
                    f"{iattrs['client_id']!r}")

            uris = [u["url"] for u in iattrs["redirect_uris"]]
            # Web login + user-settings link flow derive from externalDomain;
            # the mobile custom scheme is fixed. All strict, so a miss is
            # fatal at login, not degraded.
            expected = [external + "/auth/login",
                        external + "/user-settings",
                        "app.immich:///oauth-callback"]
            for uri in expected:
                if uri not in uris:
                    errs.append(
                        f"immich: template externalDomain {external!r} "
                        f"implies redirect_uri {uri!r}, blueprint offers "
                        f"{uris!r}")

        iapp = next((e for e in idoc["entries"]
                     if e["model"] == "authentik_core.application"), None)
        if iapp is None:
            errs.append("immich: no application entry in immich-oidc.yaml")
        else:
            islug = iapp["identifiers"]["slug"]
            if f"/application/o/{islug}/" not in oauth.get("issuerUrl", ""):
                errs.append(
                    f"immich: issuerUrl {oauth.get('issuerUrl')!r} does not "
                    f"reference the blueprint's application slug {islug!r}")

        # --- !Env links: blueprint <-> worker env <-> sops template ---------
        # The Loose loader above resolves EVERY unknown tag to None, so the
        # structural checks are blind to !Env — the one tag whose argument is
        # a contract with two other files. Scan the raw text instead: each
        # name a custom blueprint reads with !Env must be set in the worker's
        # compose environment (otherwise !Env resolves against an unset
        # variable and the provider row is stored with an empty secret —
        # every token exchange 401s, at login time, silently) AND rendered
        # into modules/authentik.nix's sops template (otherwise compose's
        # :?-guard on the variable aborts authentik.service at boot).
        # All custom blueprints are scanned, not just immich's: the next
        # !Env-using blueprint is covered the moment it exists.
        import re, glob, os

        with open("${(repo + "/headscale-vps/authentik/compose.yaml")}") as f:
            compose_doc = yaml.safe_load(f)
        worker_env = ((compose_doc.get("services") or {})
                      .get("worker") or {}).get("environment") or {}
        # compose allows both mapping and "KEY=value" list form for
        # environment; normalise to the set of variable names.
        if isinstance(worker_env, list):
            worker_env = {e.split("=", 1)[0] for e in worker_env}
        else:
            worker_env = set(worker_env)

        with open("${(repo + "/headscale-vps/modules/authentik.nix")}") as f:
            module_src = f.read()

        for bp in sorted(glob.glob(
                "${(repo + "/headscale-vps/authentik/blueprints/custom")}/*.yaml")):
            base = os.path.basename(bp)
            with open(bp) as f:
                # The blueprints DISCUSS !Env in comments ("!Env reads from
                # the worker's environment...") — strip the comment tail of
                # each line so only actual tag usage is captured. Good enough
                # here: no blueprint value legitimately contains " #".
                raw = "\n".join(
                    re.sub(r"(^|\s)#.*$", "", line) for line in f)
            # Only the scalar form (!Env NAME) is parsed; the list form
            # (!Env [NAME, default]) would slip through the regex, so fail
            # loudly if it ever appears rather than silently not checking it.
            if re.search(r"!Env\s*\[", raw):
                errs.append(
                    f"{base}: uses the list form '!Env [...]', which this "
                    f"lint does not parse — extend the scan before using it")
            for name in re.findall(r"!Env\s+(\w+)", raw):
                if name not in worker_env:
                    errs.append(
                        f"{base}: reads !Env {name}, but the worker "
                        f"environment in authentik/compose.yaml never sets "
                        f"it — the blueprint applies against an unset "
                        f"variable, the provider row stores an empty "
                        f"secret, and login fails at token exchange, "
                        f"silently")
                # sops-nix renders placeholders to sentinel strings before
                # eval can see them (see sops-declared), so the template
                # CONTENT is only checkable as source text. Word boundary,
                # not substring: placeholder.FOO must not satisfy a check
                # for placeholder.FOO_V2's prefix (or vice versa).
                if not re.search(
                        rf"placeholder\.{re.escape(name)}\b", module_src):
                    errs.append(
                        f"{base}: reads !Env {name}, but modules/"
                        f"authentik.nix's sops template never renders it — "
                        f"the compose :?-guard on the variable aborts "
                        f"authentik.service at boot, taking the whole IdP "
                        f"down")

        if errs:
            print("OIDC contract violations:", file=sys.stderr)
            for e in errs:
                print("  - " + e, file=sys.stderr)
            sys.exit(1)
        print("OIDC contract OK")
        PY
      '';

  # ---------------------------------------------------------------------------
  # Secrets declared in Nix must exist in the encrypted file
  # ---------------------------------------------------------------------------
  # sops-nix fails at activation, not at build, when a declared secret is
  # missing from the sops file — so this turns a first-boot failure into an
  # eval-time one.
  #
  # Three files are compared per host, and sops-yaml makes all three checkable:
  # values are encrypted but TOP-LEVEL KEYS stay plaintext, so even the real
  # production secrets.sops.yaml can be verified without the production key.
  #   1. secrets.sops.yaml          — what the host will actually decrypt
  #   2. secrets.sops.yaml.example  — the documented template
  #   3. tests/fixtures/*.sops.yaml — what the suites exercise
  # Any drift between the declared sops.secrets/template placeholders and any
  # of the three fails.
  sops-declared =
    let
      declared = cfg: lib.attrNames cfg.sops.secrets;
      # No separate leg for sops.templates placeholders: a template can only
      # interpolate config.sops.placeholder.<name>, and sops-nix defines that
      # attrset from sops.secrets — referencing an undeclared name fails
      # evaluation outright, so every placeholder is already a declared secret
      # and the declared-secrets comparison below covers it. (An earlier leg
      # tried to regex `placeholder.NAME` back out of t.content, but by the
      # time content is a string the placeholders are rendered sentinel
      # strings — it matched nothing and vacuously asserted nothing.)
    in
    mkLint "sops-declared" ''
      ${py} - <<'PY'
      import sys, yaml

      def keys(path):
          with open(path) as f:
              doc = yaml.safe_load(f)
          if not isinstance(doc, dict):
              print(f"{path}: not a yaml mapping", file=sys.stderr)
              sys.exit(1)
          # 'sops' is the metadata block sops appends on encryption.
          return {k for k in doc if k != "sops"}

      cases = [
          ("headscale-vps",
           "${(repo + "/headscale-vps/secrets.sops.yaml")}",
           "${(repo + "/headscale-vps/secrets.sops.yaml.example")}",
           "${../fixtures/vps.sops.yaml}",
           ${builtins.toJSON (declared vpsConfig)}),
          ("nixos",
           "${(repo + "/nixos/secrets.sops.yaml")}",
           "${(repo + "/nixos/secrets.sops.yaml.example")}",
           "${../fixtures/services-vm.sops.yaml}",
           ${builtins.toJSON (declared servicesConfig)}),
      ]

      errs = []
      for host, real, example, fixture, needed in cases:
          real_keys, ex_keys, fix_keys = keys(real), keys(example), keys(fixture)

          missing = sorted(set(needed) - real_keys)
          if missing:
              errs.append(f"{host}: declared in Nix but absent from the real "
                          f"secrets.sops.yaml (activation will fail): {missing}")

          for label, other in [("example", ex_keys), ("test fixture", fix_keys)]:
              if other != real_keys:
                  extra = sorted(other - real_keys)
                  gone = sorted(real_keys - other)
                  errs.append(f"{host}: {label} drifted from secrets.sops.yaml "
                              f"(extra: {extra}, missing: {gone})")

      if errs:
          print("SOPS declaration problems:", file=sys.stderr)
          for e in errs:
              print("  - " + e, file=sys.stderr)
          sys.exit(1)
      print("SOPS declarations OK (real file, example and fixture all agree)")
      PY
    '';

  # ---------------------------------------------------------------------------
  # sops-nix ignores the per-secret key for dotenv files
  # ---------------------------------------------------------------------------
  # sops-install-secrets treats dotenv exactly like binary:
  #
  #   switch s.Format {
  #   case Binary, Dotenv, Ini:
  #       s.value = sourceFile.binary      // whole file; s.Key is never applied
  #
  # (pkgs/sops-install-secrets/main.go). validateSopsFile skips key validation
  # for the same three formats, so nothing warns either. The option
  # documentation says only "ignored if format is binary", which is what makes
  # this easy to walk into.
  #
  # Consequence for this repo: with defaultSopsFormat = "dotenv", every
  # /run/secrets/<name> contains the ENTIRE decrypted document rather than that
  # key's value. Concretely —
  #
  #   nixos/configuration.nix    tailscale up --authkey "$(cat …)" is handed a
  #                              multi-line dotenv file; registration fails.
  #   modules/headscale.nix      oidc.client_secret_path likewise; OIDC login
  #                              breaks, and silently, because
  #                              only_start_if_oidc_is_available = false.
  #   modules/authentik.nix      sops.templates substitutes the secret's value,
  #                              so PG_PASS becomes the whole document and the
  #                              database password is garbage.
  #
  # decrypt-sops-envs.service on the services VM is NOT affected: it shells out
  # to the sops CLI, where the whole file genuinely is the artifact.
  #
  # Fix: per-key extraction needs yaml or json. Keep dotenv only where the whole
  # file is what you want (the stack .env files), and move the OS-level secrets
  # that sops-nix extracts individually into a .sops.yaml with
  # defaultSopsFormat = "yaml".
  sops-dotenv-extraction =
    let
      offenders =
        host: cfg:
        let
          fmt = cfg.sops.defaultSopsFormat;
          perKey = lib.attrNames (lib.filterAttrs (_: s: s.key != "") cfg.sops.secrets);
          usesTemplates = cfg.sops.templates != { };
        in
        lib.optional (fmt == "dotenv" && (perKey != [ ] || usesTemplates)) {
          inherit host;
          format = fmt;
          secrets = perKey;
          templates = lib.attrNames cfg.sops.templates;
        };
      bad = offenders "headscale-vps" vpsConfig ++ offenders "nixos" servicesConfig;
    in
    mkLint "sops-dotenv-extraction" ''
      ${py} - <<'PY'
      import json, sys
      bad = json.loads(${builtins.toJSON (builtins.toJSON bad)})
      if bad:
          print("sops-nix will not extract per-key values from a dotenv file.",
                file=sys.stderr)
          print("sops-install-secrets treats dotenv like binary, so each of "
                "these secrets receives the WHOLE decrypted document:",
                file=sys.stderr)
          for b in bad:
              print(f"  {b['host']} (defaultSopsFormat = {b['format']!r})",
                    file=sys.stderr)
              for s in b["secrets"]:
                  print(f"    secret   {s}", file=sys.stderr)
              for t in b["templates"]:
                  print(f"    template {t}  (placeholders get the whole file)",
                        file=sys.stderr)
          print("", file=sys.stderr)
          print("Fix: move these into a .sops.yaml with "
                "defaultSopsFormat = \"yaml\". Keep dotenv only for the stack "
                ".env files, which are consumed whole by the sops CLI in "
                "decrypt-sops-envs.service and are unaffected.",
                file=sys.stderr)
          sys.exit(1)
      print("sops dotenv extraction OK")
      PY
    '';

  # ---------------------------------------------------------------------------
  # Image pins resolve, and match what compose asks for
  # ---------------------------------------------------------------------------
  # A tag that does not exist in its registry cannot be pulled on the real host
  # either. Three such references were already shipped in this repo, so this is
  # not hypothetical.
  image-pins =
    mkLint "image-pins" ''
      ${py} - <<'PY'
      import json, re, sys

      manifest = json.load(open("${manifest}"))
      pinned   = json.loads(${builtins.toJSON (builtins.toJSON (removeAttrs images [ "_unresolved" "_skipped" ]))})
      unresolved = json.loads(${builtins.toJSON (builtins.toJSON images._unresolved or [ ])})
      skipped    = json.loads(${builtins.toJSON (builtins.toJSON images._skipped or [ ])})

      errs = []
      if unresolved:
          errs.append("image references that do not exist in their registry "
                      "(deploy-blocking): " + ", ".join(unresolved))

      refs = set()
      for c in manifest:
          for line in open(c["path"]):
              m = re.match(r"\s*image:\s*(\S+)", line)
              if m:
                  refs.add(m.group(1))

      pinned_refs = {v["composeRef"] for v in pinned.values()}
      missing = sorted(refs - pinned_refs - set(skipped) - set(unresolved))
      if missing:
          errs.append("compose references with no pin in tests/lib/images.nix "
                      "(run tests/update-images.sh): " + ", ".join(missing))

      stale = sorted(pinned_refs - refs)
      if stale:
          errs.append("pins for images no longer referenced by any compose "
                      "file: " + ", ".join(stale))

      if errs:
          print("Image pin problems:", file=sys.stderr)
          for e in errs:
              print("  - " + e, file=sys.stderr)
          sys.exit(1)
      print(f"Image pins OK ({len(pinned_refs)} pinned, {len(skipped)} skipped)")
      PY
    '';

  # ---------------------------------------------------------------------------
  # env_file coverage
  # ---------------------------------------------------------------------------
  # decrypt-sops-envs.service only writes a .env when a .sops.env exists beside
  # it. A compose file naming `env_file: .env` with no .sops.env in the same
  # directory aborts `docker compose up` on the real host with "env file not
  # found" — and the stack simply never starts.
  env-file-coverage =
    mkLint "env-file-coverage" ''
      ${py} - <<'PY'
      import json, re, sys

      manifest = json.load(open("${manifest}"))
      errs, warns = [], []

      for c in manifest:
          text = open(c["path"]).read()
          if not re.search(r"^\s*env_file:", text, re.M):
              continue
          if c["hasSopsEnv"]:
              continue
          if c["hasSopsExample"]:
              warns.append(f"{c['stack']}: compose declares env_file but only "
                           f".sops.env.example exists — `docker compose up` "
                           f"will fail until the real .sops.env is created")
          else:
              errs.append(f"{c['stack']}: compose declares env_file and the "
                          f"stack has neither .sops.env nor .sops.env.example")

      for w in warns:
          print("WARN: " + w)
      if errs:
          print("env_file coverage problems:", file=sys.stderr)
          for e in errs:
              print("  - " + e, file=sys.stderr)
          sys.exit(1)
      print("env_file coverage OK")
      PY
    '';

  # ---------------------------------------------------------------------------
  # Caddy routes vs published ports
  # ---------------------------------------------------------------------------
  # Caddy is now the only path in on both hosts, so a route pointing at a port
  # nothing publishes is a 502 with no other symptom, and a service that
  # publishes a port with no route is unreachable.
  caddy-routes =
    mkLint "caddy-routes" ''
      ${py} - <<'PY'
      import json, re, sys

      manifest = json.load(open("${manifest}"))
      caddyfile = open("${(repo + "/stacks/caddy/Caddyfile")}").read()
      # Strip comments. The file documents a not-yet-enabled forward-auth
      # snippet with a sample reverse_proxy in it; matching that would report a
      # route to a service nobody has deployed.
      caddyfile = "\n".join(re.sub(r"#.*$", "", l) for l in caddyfile.splitlines())

      # Ports published by any services-VM stack, as host-side port numbers.
      published = {}
      for c in manifest:
          if c["stack"] == "authentik":
              continue  # VPS host, fronted by its own Caddy
          for line in open(c["path"]):
              # Optional /tcp|/udp suffix (mirrors lib/mk-stack-suite.nix):
              # without it a suffixed publish — Phase-4 media will use UDP —
              # silently drops out of `published` and its route reports as a
              # phantom 502.
              m = re.search(
                  r"^\s*-\s*['\"]?(?:127\.0\.0\.1:)?(\d+):(\d+)(?:/(?:tcp|udp))?['\"]?\s*$",
                  line)
              if m:
                  published[m.group(1)] = c["stack"]

      routed = set(re.findall(r"reverse_proxy\s+localhost:(\d+)", caddyfile))

      errs = []
      for port in sorted(routed - set(published)):
          errs.append(f"Caddyfile reverse_proxies localhost:{port}, which no "
                      f"compose file publishes -> 502")

      unrouted = sorted(set(published) - routed)
      for port in unrouted:
          print(f"NOTE: {published[port]} publishes {port} with no Caddy route "
                f"(unreachable, may be intentional)")

      if errs:
          print("Caddy routing problems:", file=sys.stderr)
          for e in errs:
              print("  - " + e, file=sys.stderr)
          sys.exit(1)
      print(f"Caddy routes OK ({len(routed)} routes)")
      PY
    '';

  # ---------------------------------------------------------------------------
  # Forward-auth coverage: every protected Caddy host has a blueprint entry
  # ---------------------------------------------------------------------------
  # The Caddyfile's (protected) snippet forward_auths to authentik's embedded
  # outpost, which routes BY X-Forwarded-Host against the external_host of the
  # providers assigned to it. A route that imports `protected` for a host the
  # blueprint does not know is therefore a production LOCKOUT, not a login
  # page: the outpost matches nothing and every request 404s or redirect-loops
  # (the Caddyfile header mandates blueprint-first rollout for exactly this
  # reason — and six media routes were once flipped without entries anyway,
  # which is why this lint exists). Two files nothing else links:
  # stacks/caddy/Caddyfile and headscale-vps/authentik/blueprints/custom/
  # forward-auth.yaml. This makes the sync a failing check instead of a
  # comment.
  #
  # Also enforced: every proxyprovider in the blueprint is listed in the
  # embedded outpost's `providers:` — that list REPLACES on apply, so an
  # entry added without extending it is the same lockout by another door.
  #
  # Warn-only leg: _overview.md rows whose Auth column says FwdAuth but whose
  # service is not (yet) behind `import protected` — roadmap visibility, not
  # drift, so it prints without failing (mirrors overview-sync's
  # one-directional stance).
  forward-auth-coverage =
    mkLint "forward-auth-coverage" ''
      ${py} - <<'PY'
      import re, sys, yaml

      # --- Caddyfile: hosts whose handle block imports `protected` ---------
      matchers = {}    # matcher name -> host
      protected = {}   # matcher name -> host (or None if matcher unknown)
      current = None   # matcher of the handle block we are inside, if any
      current_depth = 0
      depth = 0
      for raw in open("${(repo + "/stacks/caddy/Caddyfile")}"):
          # Comments stripped first: the header documents `import protected`
          # in prose and sample blocks, which must not count as routes.
          line = re.sub(r"#.*$", "", raw)
          m = re.match(r"\s*@(\S+)\s+host\s+(\S+)", line)
          if m:
              matchers[m.group(1)] = m.group(2)
          h = re.match(r"\s*handle\s+@(\S+)\s*\{", line)
          if h and current is None:
              current, current_depth = h.group(1), depth
          if current is not None and re.match(r"\s*import\s+protected\s*$", line):
              protected[current] = matchers.get(current)
          # Depth tracked per line; inline {$VAR}/{env.*} placeholders open
          # and close on the same line so they cancel out.
          depth += line.count("{") - line.count("}")
          if current is not None and depth <= current_depth:
              current = None

      errs = []
      for name, host in sorted(protected.items()):
          if host is None:
              errs.append(f"handle @{name} imports protected but no "
                          f"'@{name} host ...' matcher was found — cannot "
                          f"verify its blueprint coverage")
      caddy_hosts = {h for h in protected.values() if h}

      # Parser-rot sentinel: the bentopdf pilot is permanently protected, so
      # an empty/pilot-less parse means the regexes no longer match the
      # Caddyfile's shape — that would be a false green on every lockout this
      # lint exists to catch.
      assert "bentopdf.svc.idanreed.com" in caddy_hosts, (
          f"forward-auth-coverage parser found {sorted(caddy_hosts)} but not "
          "the bentopdf pilot — the Caddyfile parser has rotted; fix it "
          "before trusting this lint"
      )

      # --- Blueprint: external_host per provider, outpost assignment -------
      with open("${(repo + "/headscale-vps/authentik/blueprints/custom/forward-auth.yaml")}") as f:
          # !Find / !KeyOf are authentik tags PyYAML lacks. Unlike
          # oidc-contract we must KEEP !KeyOf's scalar (the provider id) to
          # check the outpost list, so unknown tags resolve to their raw
          # scalar rather than None.
          class Loose(yaml.SafeLoader):
              pass
          def keep_scalar(loader, suffix, node):
              if isinstance(node, yaml.ScalarNode):
                  return loader.construct_scalar(node)
              return None
          Loose.add_multi_constructor("!", keep_scalar)
          doc = yaml.load(f, Loose)

      provider_hosts = {}   # bare hostname -> provider entry id
      provider_ids = set()
      outpost_providers = None
      for e in doc.get("entries", []):
          model = e.get("model", "")
          if model == "authentik_providers_proxy.proxyprovider":
              provider_ids.add(e.get("id"))
              eh = (e.get("attrs") or {}).get("external_host", "")
              host = re.sub(r"^https?://", "", eh).rstrip("/")
              if host:
                  provider_hosts[host] = e.get("id")
          elif model == "authentik_outposts.outpost":
              outpost_providers = ((e.get("attrs") or {}).get("providers")) or []

      for host in sorted(caddy_hosts - set(provider_hosts)):
          errs.append(
              f"Caddyfile imports (protected) for {host} but "
              f"forward-auth.yaml has no proxyprovider with that "
              f"external_host — the outpost cannot match the forwarded Host, "
              f"so on the next caddy-stack sync EVERY request to {host} 404s "
              f"or redirect-loops (production lockout). Add the blueprint "
              f"entry AND deploy the VPS before the route goes live.")

      if outpost_providers is None:
          errs.append("forward-auth.yaml has no authentik_outposts.outpost "
                      "entry — no provider is assigned anywhere")
      else:
          for pid in sorted(provider_ids - set(outpost_providers)):
              errs.append(
                  f"provider entry {pid!r} is not in the embedded outpost's "
                  f"providers list — that list REPLACES on apply, so this "
                  f"provider is unassigned and its host locks out exactly "
                  f"like a missing entry")

      # --- Warn-only: overview FwdAuth rows not yet behind protected -------
      overview = open("${../../../ServerNotes/designs/_overview.md}").read()
      norm = lambda s: re.sub(r"[^a-z0-9]", "", s.lower())
      protected_labels = {norm(h.split(".")[0]) for h in caddy_hosts}
      for line in overview.splitlines():
          cells = [c.strip() for c in line.strip().strip("|").split("|")]
          if len(cells) >= 5 and cells[3].strip("* ") == "FwdAuth":
              if norm(cells[0]) not in protected_labels:
                  print(f"WARN: _overview row '{cells[0]}' is marked FwdAuth "
                        f"but no Caddy route imports protected for it yet "
                        f"(roadmap, not drift)")

      if errs:
          print("forward-auth coverage problems:", file=sys.stderr)
          for e in errs:
              print("  - " + e, file=sys.stderr)
          sys.exit(1)
      print(f"forward-auth coverage OK ({len(caddy_hosts)} protected hosts, "
            f"{len(provider_hosts)} blueprint hosts, all assigned)")
      PY
    '';

  # ---------------------------------------------------------------------------
  # Loopback binding
  # ---------------------------------------------------------------------------
  # nixos/configuration.nix trusts tailscale0 wholesale, so the host firewall
  # does not filter tailnet traffic at all. The only thing keeping a stack off
  # the tailnet is binding its published port to 127.0.0.1. A bare "10100:8000"
  # silently republishes to every tailnet peer, bypassing Caddy and any forward
  # auth in front of it.
  loopback-binding =
    mkLint "loopback-binding" ''
      ${py} - <<'PY'
      import json, re, sys

      manifest = json.load(open("${manifest}"))
      errs = []

      for c in manifest:
          for n, line in enumerate(open(c["path"]), 1):
              # Long-form ports entries put host_ip on a DIFFERENT line, so a
              # line-oriented scan cannot check the binding. Skipping silently
              # would let a long-form 0.0.0.0 publish onto the tailnet with a
              # green lint, so an unparseable 'published:' is an error, not a
              # gap: use the short form (or teach this lint real YAML first).
              if re.match(r"\s*-?\s*published:", line):
                  errs.append(f"{c['stack']} compose.yaml:{n}: long-form ports "
                              f"entry ('published:') — this line-based lint "
                              f"cannot verify its host_ip; use the short form "
                              f"'127.0.0.1:HOST:CONTAINER[/tcp|/udp]'")
                  continue
              # Optional /tcp|/udp suffix (mirrors lib/mk-stack-suite.nix):
              # without it a suffixed publish — Phase-4 media will use UDP —
              # escapes the loopback check entirely.
              m = re.search(
                  r"^\s*-\s*['\"]?([0-9.:]+):(\d+)(?:/(?:tcp|udp))?['\"]?\s*$",
                  line)
              if not m:
                  continue
              # Split on ':' only — a /tcp|/udp suffix rides along on the last
              # part and does not affect the host-address check.
              spec = m.group(0).strip().lstrip("- ").strip("'\"")
              parts = spec.split(":")
              if len(parts) == 2:
                  errs.append(f"{c['stack']} compose.yaml:{n}: '{spec}' binds "
                              f"0.0.0.0 — reachable from the whole tailnet, "
                              f"bypassing Caddy. Use 127.0.0.1:{parts[0]}:{parts[1]}")
              elif len(parts) == 3 and parts[0] not in ("127.0.0.1",):
                  errs.append(f"{c['stack']} compose.yaml:{n}: '{spec}' binds "
                              f"{parts[0]} rather than 127.0.0.1")

      if errs:
          print("Port binding problems:", file=sys.stderr)
          for e in errs:
              print("  - " + e, file=sys.stderr)
          sys.exit(1)
      print("Port bindings OK")
      PY
    '';

  # ---------------------------------------------------------------------------
  # Overview inventory sync
  # ---------------------------------------------------------------------------
  # ServerNotes/designs/_overview.md is the authoritative service inventory and
  # CLAUDE.md says it is kept in sync with stacks/ BY HAND. This makes the sync
  # a failing check instead of a memory: every host-published port in a compose
  # file must have an inventory row, and where a row pins an image tag it must
  # match the compose tag. One-directional on purpose — inventory rows for
  # not-yet-built services are the roadmap, not drift.
  overview-sync =
    mkLint "overview-sync" ''
      ${py} - <<'PY'
      import json, re, sys

      manifest = json.load(open("${manifest}"))
      overview = open("${../../../ServerNotes/designs/_overview.md}").read()

      # Inventory rows: | Name | Volume | Port | Auth | Image | ...
      rows = []
      for line in overview.splitlines():
          cells = [c.strip() for c in line.strip().strip("|").split("|")]
          if len(cells) >= 5 and re.search(r"\d", cells[2] or ""):
              rows.append({"name": cells[0], "port": cells[2],
                           "image": cells[4].strip("`")})

      def row_ports(r):
          # "127.0.0.1:10000" and "10050-10057" style cells both appear.
          out = set()
          for m in re.finditer(r"(\d{4,5})", r["port"]):
              out.add(m.group(1))
          return out

      inv_ports = {}
      for r in rows:
          for p in row_ports(r):
              inv_ports.setdefault(p, []).append(r)

      errs = []
      for c in manifest:
          if c["stack"] == "authentik":
              continue  # VPS host: inventoried under its own section semantics
          text = open(c["path"]).read()
          # Optional /tcp|/udp suffix (mirrors lib/mk-stack-suite.nix): a
          # suffixed publish — Phase-4 media will use UDP — must still demand
          # an inventory row rather than silently skipping the check.
          for m in re.finditer(
              r"^\s*-\s*['\"]?(?:127\.0\.0\.1:)?(\d{4,5}):\d+(?:/(?:tcp|udp))?['\"]?\s*$",
              text, re.M):
              port = m.group(1)
              hits = inv_ports.get(port)
              if not hits:
                  errs.append(f"{c['stack']}: publishes {port} but "
                              f"_overview.md has no row with that port")
                  continue
              # Tag agreement, when the row pins one.
              for r in hits:
                  if ":" in r["image"]:
                      img_re = re.escape(r["image"])
                      if not re.search(img_re, text):
                          errs.append(
                              f"{c['stack']}: _overview row '{r['name']}' pins "
                              f"image {r['image']!r} but the compose file does "
                              f"not contain it")

      if errs:
          print("Inventory drift (_overview.md vs compose):", file=sys.stderr)
          for e in errs:
              print("  - " + e, file=sys.stderr)
          sys.exit(1)
      print(f"Overview sync OK ({len(rows)} inventory rows checked)")
      PY
    '';

  # ---------------------------------------------------------------------------
  # Flake input parity across the host flakes
  # ---------------------------------------------------------------------------
  # The harness pins its sources from headscale-vps/flake.lock. Every input
  # the two locks SHARE must agree, not just nixpkgs: the sops-dotenv-
  # extraction lint, for one, asserts behaviour of sops-nix internals, so a
  # sops-nix that drifted on the nixos/ side would be reasoned about from the
  # wrong revision — with the suites still green. Inputs are resolved through
  # each lock's root inputs mapping rather than top-level node labels, because
  # an input's name is not its node label (`follows`/duplicates yield labels
  # like "nixpkgs_2") and comparing labels can silently compare a transitive
  # input instead of the flake's own.
  flake-input-parity =
    mkLint "flake-input-parity" ''
      ${py} - <<'PY'
      import json, sys

      locks = {
          "headscale-vps": "${(repo + "/headscale-vps/flake.lock")}",
          "nixos":         "${(repo + "/nixos/flake.lock")}",
      }

      # Both flakes commit their lock, so a missing one is a broken checkout,
      # not a host that has "not locked yet" — hard error, no skip.
      data = {host: json.load(open(path)) for host, path in locks.items()}

      def root_inputs(lock):
          return lock["nodes"][lock["root"]]["inputs"]

      def rev(lock, name):
          label = root_inputs(lock)[name]
          if not isinstance(label, str):
              # A list is a follows-path; top-level inputs are plain labels.
              sys.exit(f"root input {name!r} is a follows path — lock shape "
                       f"unsupported by this lint")
          return lock["nodes"][label]["locked"]["rev"]

      common = sorted(set.intersection(
          *(set(root_inputs(l)) for l in data.values())))

      errs = []
      for name in common:
          revs = {host: rev(lock, name) for host, lock in data.items()}
          if len(set(revs.values())) > 1:
              detail = ", ".join(f"{h}={r[:12]}" for h, r in revs.items())
              errs.append(f"input '{name}' drifted: {detail}")

      if errs:
          print("flake input drift between the host locks:", file=sys.stderr)
          for e in errs:
              print("  - " + e, file=sys.stderr)
          print("The harness pins from headscale-vps, so the nixos host is "
                "tested against different inputs than it is built with.",
                file=sys.stderr)
          sys.exit(1)
      print(f"flake input parity OK ({', '.join(common)})")
      PY
    '';

  # ---------------------------------------------------------------------------
  # fail2ban <-> docker journald tag contract
  # ---------------------------------------------------------------------------
  # Three strings must agree or the authentik jail reads zero journal lines
  # FOREVER while fail2ban-client still lists it active: the compose logging
  # tag on the server container, the jail's journalmatch, and the filter
  # file's journalmatch. Nothing else couples them — rename any one and every
  # suite stays green (the fail2ban-regex drift leg feeds the filter a FILE,
  # not the journal), which is exactly the silent-death mode the jail exists
  # to prevent.
  fail2ban-journal-contract =
    mkLint "fail2ban-journal-contract" ''
      ${py} - <<'PY'
      import sys, yaml

      with open("${repo + "/headscale-vps/authentik/compose.yaml"}") as f:
          doc = yaml.safe_load(f)
      server = doc["services"]["server"]
      logging = server.get("logging") or {}

      errs = []
      if logging.get("driver") != "journald":
          errs.append("the server container's logging driver is "
                      f"{logging.get('driver')!r}, not journald — fail2ban's "
                      "systemd backend cannot see json-file logs")
      tag = (logging.get("options") or {}).get("tag")
      if not tag:
          errs.append("the server container's journald logging has no tag — "
                      "the jail's journalmatch has nothing to match")

      with open("${repo + "/headscale-vps/configuration.nix"}") as f:
          cfg = f.read()
      # Both consumers, exact forms: the jail setting (nix string) and the
      # filter file line (raw INI inside the etc text).
      if tag:
          want = f"CONTAINER_TAG={tag}"
          jail = f'journalmatch = "{want}"'
          filt = f"journalmatch = {want}"
          if jail not in cfg:
              errs.append(f"jail journalmatch does not pin {want!r} — the "
                          "jail watches a tag nothing emits")
          if filt not in cfg:
              errs.append(f"filter-file journalmatch does not pin {want!r}")

      if errs:
          print("fail2ban journal contract violations:", file=sys.stderr)
          for e in errs:
              print("  - " + e, file=sys.stderr)
          sys.exit(1)
      print(f"fail2ban journal contract OK (tag {tag!r}, jail + filter agree)")
      PY
    '';

  # ---------------------------------------------------------------------------
  # /srv/stacks tmpfiles ownership
  # ---------------------------------------------------------------------------
  # nixos/hardware-configuration.nix owns the production tmpfiles rules, and
  # the VM suites REPLACE that file with tmpfs stubs plus their own rules — so
  # nothing else evaluates it, and reverting 'd /srv/stacks 0755 1000 1000 -'
  # to root ownership (review finding #10) would keep every suite green while
  # killing GitOps delivery in production: Arcane runs as PUID/PGID 1000, so
  # under a root-owned /srv/stacks its git sync can never create a project
  # directory and its deploys cannot read the 0600 .env files. This asserts
  # the rule on servicesFullConfig, the one eval that includes the real
  # hardware config (see default.nix).
  tmpfiles-ownership =
    mkLint "tmpfiles-ownership" ''
      ${py} - <<'PY'
      import json, sys

      rules = json.loads(${builtins.toJSON (builtins.toJSON servicesFullConfig.systemd.tmpfiles.rules)})

      # tmpfiles rule fields: type path mode user group age [argument]
      srv = [r.split() for r in rules
             if len(r.split()) >= 5 and r.split()[1] == "/srv/stacks"]

      errs = []
      # A 'd' rule specifically: configuration.nix also carries a 'Z' (chown)
      # rule for /srv/stacks, which adjusts but never CREATES — losing the 'd'
      # rule alone would leave first boot with no /srv/stacks at all.
      if not any(f[0].lower().startswith("d") for f in srv):
          errs.append("no tmpfiles 'd' rule creates /srv/stacks — Arcane's "
                      "git sync has nowhere to deliver stacks on first boot")
      for f in srv:
          if (f[3], f[4]) != ("1000", "1000"):
              errs.append(f"rule {' '.join(f)!r} gives /srv/stacks to "
                          f"{f[3]}:{f[4]}, not 1000:1000 — Arcane (PUID 1000) "
                          f"cannot create project directories or read the "
                          f"0600 .env files, so GitOps delivery is silently "
                          f"dead (review finding #10)")

      # --- bind-source parity ---------------------------------------------
      # hardware-configuration.nix's per-stack tmpfiles rules are kept in
      # sync with the compose files BY HAND; this leg pins the half that
      # matters in production: every /mnt/{fast,slow} bind source in the
      # listed compose files must have a 'd' rule, or docker creates it
      # root-owned on first deploy (the seerr crash-loop class, review
      # finding #14 — and even root-is-fine stacks like immich want the
      # parent dirs to exist with deliberate ownership, not docker's).
      # COMPOSE_FILES is the one list to extend when a new stack gains
      # /mnt bind mounts; the parsing below is shared, not copied.
      import yaml, re
      COMPOSE_FILES = [
          ("media", "${repo + "/stacks/media/compose.yaml"}"),
          ("immich", "${repo + "/stacks/immich/compose.yaml"}"),
          ("books", "${repo + "/stacks/books/compose.yaml"}"),
      ]
      d_paths = {r.split()[1] for r in rules
                 if len(r.split()) >= 5 and r.split()[0].lower().startswith("d")}
      sources = set()
      for stack, path in COMPOSE_FILES:
          with open(path) as f:
              compose = yaml.safe_load(f)
          stack_sources = set()
          for svc in (compose.get("services") or {}).values():
              for v in svc.get("volumes") or []:
                  src = v.split(":")[0] if isinstance(v, str) else (v.get("source") or "")
                  if re.match(r"/mnt/(fast|slow)/", src):
                      stack_sources.add(src.rstrip("/"))
          for src in sorted(stack_sources - d_paths):
              errs.append(f"{stack} bind source {src} has no tmpfiles 'd' rule "
                          "in nixos/hardware-configuration.nix — docker will "
                          "create it root-owned on first deploy")
          sources |= stack_sources

      if errs:
          print("/srv/stacks tmpfiles problems:", file=sys.stderr)
          for e in errs:
              print("  - " + e, file=sys.stderr)
          sys.exit(1)
      print("/srv/stacks tmpfiles ownership OK (1000:1000); "
            f"{len(sources)} bind sources across {len(COMPOSE_FILES)} stacks "
            "all have 'd' rules")
      PY
    '';

  # ---------------------------------------------------------------------------
  # Stack dotenv key drift (fixture vs real vs example)
  # ---------------------------------------------------------------------------
  # Three dotenv surfaces can exist per stack — the encrypted production
  # .sops.env, its .sops.env.example template, and the test fixture the suites
  # decrypt instead — and nothing else compares them (sops-declared covers
  # only the yaml OS secrets). Drift fails silently at the worst spot: docker
  # compose substitutes an EMPTY STRING for any env_file variable the
  # delivered .env lacks, so a key present in the fixture (suite green) but
  # missing from the real .sops.env starts the production container with the
  # variable unset and no error anywhere. Keys are plaintext in encrypted
  # dotenv files, so all three are comparable without a decryption key.
  stack-env-drift =
    mkLint "stack-env-drift" ''
      ${py} - <<'PY'
      import json, sys

      manifest = json.load(open("${manifest}"))
      errs = []

      for c in manifest:
          # null = file absent (nothing to compare); [] = file exists, empty.
          present = {label: set(ks) for label, ks in [
              ("stacks/" + c["stack"] + "/.sops.env", c["sopsEnvKeys"]),
              ("stacks/" + c["stack"] + "/.sops.env.example", c["sopsExampleKeys"]),
              ("tests/fixtures/" + c["stack"] + ".sops.env", c["fixtureKeys"]),
          ] if ks is not None}
          if len(present) < 2:
              continue
          labels = sorted(present)
          for i, a in enumerate(labels):
              for b in labels[i + 1:]:
                  only_a = sorted(present[a] - present[b])
                  only_b = sorted(present[b] - present[a])
                  if only_a or only_b:
                      errs.append(f"{c['stack']}: {a} vs {b} — "
                                  f"only in former: {only_a}, "
                                  f"only in latter: {only_b}")

      if errs:
          print("dotenv key drift (compose substitutes an empty string for "
                "missing keys — the container starts with the variable "
                "silently unset):", file=sys.stderr)
          for e in errs:
              print("  - " + e, file=sys.stderr)
          sys.exit(1)
      print("stack dotenv keys OK (fixture, real and example agree per stack)")
      PY
    '';

  # ---------------------------------------------------------------------------
  # VPS module list parity with headscale-vps/flake.nix
  # ---------------------------------------------------------------------------
  # tests/default.nix re-evaluates the VPS from its own hand-mirrored module
  # list (the harness is deliberately not a flake, so it cannot import the
  # real one). A module added to headscale-vps/flake.nix alone would be
  # deployed yet invisible to every lint here — its sops.secrets, ports and
  # settings simply absent from vpsConfig — so the flake's text is scanned for
  # ./configuration.nix and ./modules/*.nix entries and compared to the list
  # the harness evaluates. disk-config.nix is excluded by the regex on
  # purpose: it needs disko's module, which evalHost does not load, and
  # diskoTest covers it instead. Only headscale-vps is checked: nixos/
  # composes an inline baseModule whose only file modules are
  # configuration.nix + hardware-configuration.nix, both already evaluated
  # (servicesConfig / servicesFullConfig), so there is no list to drift.
  module-list-parity =
    mkLint "module-list-parity" ''
      ${py} - <<'PY'
      import json, re, sys

      flake = open("${(repo + "/headscale-vps/flake.nix")}").read()
      in_flake = set(re.findall(
          r"\./((?:configuration|modules/[A-Za-z0-9_.-]+)\.nix)", flake))
      evaluated = set(json.loads(${builtins.toJSON (builtins.toJSON vpsModuleFiles)}))

      errs = []
      for m in sorted(in_flake - evaluated):
          errs.append(f"{m} is deployed by headscale-vps/flake.nix but not in "
                      f"tests/default.nix's vpsModuleFiles — every lint is "
                      f"blind to whatever it configures")
      for m in sorted(evaluated - in_flake):
          errs.append(f"{m} is evaluated by tests/default.nix but not "
                      f"deployed by headscale-vps/flake.nix — the lints "
                      f"assert a config the host does not run")

      if errs:
          print("module list drift (tests/default.nix vs "
                "headscale-vps/flake.nix):", file=sys.stderr)
          for e in errs:
              print("  - " + e, file=sys.stderr)
          sys.exit(1)
      print(f"module list parity OK ({len(evaluated)} modules)")
      PY
    '';

  # ---------------------------------------------------------------------------
  # ssh-pubkeys.nix parity across the three flakes
  # ---------------------------------------------------------------------------
  # nixos-de/ssh-pubkeys.nix is the canonical identity list; nixos/ and
  # headscale-vps/ carry byte-identical copies because a flake cannot
  # reference paths outside its own root. Nothing else links the three, and a
  # drifted copy fails at the worst spot: a pubkey updated in one place only
  # means the next deploy of the other host silently authorises a stale key
  # (or none), and the mismatch surfaces as an ssh refusal long after the
  # edit. Byte comparison, not attrset equality, on purpose — the comments
  # carry the where-do-private-halves-live contract and must not rot apart
  # either.
  #
  # Warn-only leg: entries still null (keypair not generated yet). Consumers
  # filter nulls so this is "no access granted", not breakage — roadmap
  # visibility, mirroring overview-sync's stance.
  ssh-pubkey-parity =
    let
      readOrNull = f: if builtins.pathExists (repo + "/${f}") then builtins.readFile (repo + "/${f}") else null;
      # Canonical copy FIRST: the python below compares the rest against
      # element 0 and reports drift relative to it.
      copies = map (f: {
        name = f;
        text = readOrNull f;
      }) [
        "nixos-de/ssh-pubkeys.nix"
        "nixos/ssh-pubkeys.nix"
        "headscale-vps/ssh-pubkeys.nix"
      ];
    in
    mkLint "ssh-pubkey-parity" ''
      ${py} - <<'PY'
      import json, re, sys

      copies = json.loads(${builtins.toJSON (builtins.toJSON copies)})
      canonical = copies[0]

      errs = []
      for c in copies:
          if c["text"] is None:
              errs.append(f"{c['name']} does not exist — every flake must "
                          f"carry its byte-identical copy of the identity "
                          f"list (canonical: {canonical['name']})")
      if canonical["text"] is not None:
          for c in copies[1:]:
              if c["text"] is not None and c["text"] != canonical["text"]:
                  errs.append(f"{c['name']} drifted from {canonical['name']} "
                              f"(byte comparison) — re-copy the canonical "
                              f"file; a stale copy deploys stale authorized "
                              f"keys")

      # WARN leg: null identities in the canonical copy (or the first
      # existing one, so the warn still prints while the canonical is the
      # missing file).
      source = next((c for c in copies if c["text"] is not None), None)
      if source is not None:
          nulls = re.findall(r"^\s*([A-Za-z0-9_-]+)\s*=\s*null\s*;",
                             source["text"], re.M)
          for n in nulls:
              print(f"WARN: identity '{n}' is still null in {source['name']} "
                    f"— keypair not generated yet, no access granted")

      if errs:
          print("ssh-pubkeys.nix parity problems:", file=sys.stderr)
          for e in errs:
              print("  - " + e, file=sys.stderr)
          sys.exit(1)
      print(f"ssh-pubkeys parity OK ({len(copies)} byte-identical copies)")
      PY
    '';

  # ---------------------------------------------------------------------------
  # Headscale ACL policy
  # ---------------------------------------------------------------------------
  # policy.hujson switches the tailnet to default-deny. A syntax error or an
  # unresolvable user reference means headscale refuses to load the policy, and
  # the failure mode is "nothing on the tailnet can reach anything".
  headscale-policy =
    runCommand "lint-headscale-policy"
      {
        nativeBuildInputs = [ pkgs.headscale ];
      }
      ''
        set -eu
        cp ${repo + "/headscale-vps/policy.hujson"} ./policy.hujson
        echo "==> headscale version: $(headscale version 2>&1 | head -1)"
        if headscale policy check --file ./policy.hujson; then
          echo "policy OK"
        else
          echo "headscale policy check failed" >&2
          exit 1
        fi
        touch $out
      '';
}
