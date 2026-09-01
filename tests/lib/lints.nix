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

  # ---------------------------------------------------------------------------
  # The one enumeration of /mnt bind mounts
  # ---------------------------------------------------------------------------
  # nixos/generate-stack-dirs.py both WRITES nixos/stack-dirs.nix and answers
  # "which /mnt directories does which stack need" for the lints below. Having
  # one implementation is the whole point: the previous arrangement had the
  # generator's job done by hand in hardware-configuration.nix and the checking
  # done by a hand-maintained COMPOSE_FILES list here, and the list named 17 of
  # 22 stacks — 13 bind sources with no tmpfiles rule, unnoticed for a campaign.
  #
  # The manifest is built from `composeFiles` (a readDir glob, not a list), so a
  # new stack enters both the generator and the checks by existing. authentik is
  # dropped: it runs on the VPS, whose filesystems are not this host's.
  stackDirsGenerator = "${repo + "/nixos/generate-stack-dirs.py"}";
  stackDirsManifest = pkgs.writeText "stack-dirs-manifest.json" (
    builtins.toJSON (
      map (c: { inherit (c) stack; path = "${c.path}"; }) (
        lib.filter (c: c.stack != "authentik") composeFiles
      )
    )
  );
  # Emits {sources, directories, byStack} for the manifest above. `sources` is
  # what a compose file literally binds; `directories` adds the parents, which
  # need rules of their own (tmpfiles creates a missing parent with default
  # ownership, not the rule's).
  stackDirsJson = "${py} ${stackDirsGenerator} --manifest ${stackDirsManifest} --json";

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

        # --- Outline: stacks/outline/compose.yaml <-> outline-oidc.yaml ----
        # Outline has NO local accounts, so this pair IS the login: a drifted
        # redirect_uri or client_id does not degrade anything, it makes the
        # service permanently unenterable — and it fails at login time, with
        # a HEALTHY container and nothing in any log. The client side is the
        # compose file's environment (Outline builds its callback as
        # <URL>/auth/oidc.callback, read out of the image's
        # plugins/oidc/server/auth/oidcRouter.js).
        with open("${(repo + "/stacks/outline/compose.yaml")}") as f:
            ocomp = yaml.safe_load(f)
        oenv = {}
        for e in ((ocomp.get("services") or {}).get("outline") or {}).get(
                "environment") or []:
            k, _, v = str(e).partition("=")
            oenv[k] = v

        with open("${(repo + "/headscale-vps/authentik/blueprints/custom/outline-oidc.yaml")}") as f:
            odoc = yaml.load(f, Loose)

        oprov = next((e for e in odoc["entries"]
                      if e["model"].endswith("oauth2provider")), None)
        if oprov is None:
            errs.append("outline: no oauth2provider entry in outline-oidc.yaml")
        else:
            oattrs = oprov["attrs"]
            if oattrs["client_id"] != oenv.get("OIDC_CLIENT_ID"):
                errs.append(
                    f"outline: client_id mismatch: compose has "
                    f"{oenv.get('OIDC_CLIENT_ID')!r}, blueprint has "
                    f"{oattrs['client_id']!r}")
            expected = oenv.get("URL", "").rstrip("/") + "/auth/oidc.callback"
            ouris = [u["url"] for u in oattrs["redirect_uris"]]
            if expected not in ouris:
                errs.append(
                    f"outline: URL {oenv.get('URL')!r} implies redirect_uri "
                    f"{expected!r}, blueprint offers {ouris!r} — strict "
                    f"matching, so this is fatal at login")

        oapp = next((e for e in odoc["entries"]
                     if e["model"] == "authentik_core.application"), None)
        if oapp is None:
            errs.append("outline: no application entry in outline-oidc.yaml")
        else:
            oslug = oapp["identifiers"]["slug"]
            # Authentik's authorize/token/userinfo endpoints are global; only
            # the per-application ones carry the slug, and the logout URI is
            # the one the compose file sets. A slug rename that misses it
            # leaves logout pointing at a 404.
            if f"/application/o/{oslug}/" not in oenv.get("OIDC_LOGOUT_URI", ""):
                errs.append(
                    f"outline: OIDC_LOGOUT_URI "
                    f"{oenv.get('OIDC_LOGOUT_URI')!r} does not reference the "
                    f"blueprint's application slug {oslug!r}")

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

      # 🚨 A `network_mode: host` service has NO ports: entry, so it is absent
      # from `published` and its route looks like a phantom 502 — the same
      # blind spot host-network-declared exists for, arriving through a third
      # door (loopback-binding and mk-stack-suite's probe were the first two).
      # It cannot be inferred from the compose file: where such a service binds
      # is decided by its OWN config (gatus.yaml's web.address/web.port), which
      # this lint does not read.
      #
      # So it is declared, port -> (stack, reason) — and the declaration is
      # checked against reality below rather than taken on trust.
      HOST_NETWORK_ROUTED = {
          "10450": ("gatus",
                    "network_mode: host with no ports: entry. It binds itself "
                    "down with web.address 127.0.0.1 / web.port 10450 in "
                    "gatus.yaml, which gives the same exposure a loopback "
                    "publish would — and tests/suites/gatus.nix proves that "
                    "from another machine, because no static check can."),
      }

      errs = []

      # A declaration is only honoured if that stack really does have a
      # host-networked service. Otherwise this table becomes a way to excuse an
      # ordinary missing publish, which is exactly the failure it exists to
      # report.
      host_net_stacks = set()
      for c in manifest:
          for line in open(c["path"]):
              if re.match(r"\s*network_mode:\s*host\s*$", line):
                  host_net_stacks.add(c["stack"])
      for port, (stack, _reason) in HOST_NETWORK_ROUTED.items():
          if stack not in host_net_stacks:
              errs.append(f"HOST_NETWORK_ROUTED claims {port} belongs to "
                          f"host-networked stack {stack!r}, but no service in "
                          f"that stack sets network_mode: host any more. "
                          f"Remove the entry — a stale one silently excuses "
                          f"whatever takes that port next")
          elif port not in routed:
              errs.append(f"HOST_NETWORK_ROUTED lists {port}, which the "
                          f"Caddyfile no longer routes. Remove the entry")

      for port in sorted(routed - set(published) - set(HOST_NETWORK_ROUTED)):
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
      print(f"Caddy routes OK ({len(routed)} routes, "
            f"{len(HOST_NETWORK_ROUTED)} host-networked)")
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

      # ---- Named exemptions -------------------------------------------------
      # A bare (0.0.0.0) publish is normally the exact thing this lint exists to
      # stop. A protocol whose peers must dial THIS host is the one case it
      # cannot serve, and the honest way to handle that is a per-entry
      # allow-list with the argument written down — not a blanket skip and not
      # a silent exception in one compose file.
      #
      # An entry must state why publishing that port grants nobody anything.
      # "It is inconvenient otherwise" is not a reason; "the protocol is
      # mutually authenticated before it does anything" is.
      #
      # Unused entries are an ERROR, not a nicety: a stale exemption is a
      # standing permission for a port nobody is publishing any more, and it
      # would silently cover the next stack that happens to reuse the number.
      EXEMPT = {
          ("notes-sync", "22000:22000/tcp"):
              "Syncthing BEP. Peers dial THIS host; a loopback publish makes "
              "the server undialable and leaves only the public relay pool, "
              "which needs egress and defeats the point. Safe because BEP is "
              "mutually authenticated by device certificate before anything "
              "else happens — every peer must be added by device ID and "
              "accepted on BOTH sides, so an unknown device is rejected at the "
              "TLS layer. Note 22000 IS LAN-reachable: docker DNATs in "
              "nat/PREROUTING, which the host firewall's INPUT-only filtering "
              "never sees. The device certificate is the only control in "
              "front of it.",
          ("notes-sync", "22000:22000/udp"):
              "Same as the tcp entry: BEP's QUIC transport.",
      }
      used = set()

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
              key = (c["stack"], spec)
              if key in EXEMPT:
                  used.add(key)
                  continue
              if len(parts) == 2:
                  errs.append(f"{c['stack']} compose.yaml:{n}: '{spec}' binds "
                              f"0.0.0.0 — reachable from the whole tailnet, "
                              f"bypassing Caddy. Use 127.0.0.1:{parts[0]}:{parts[1]}")
              elif len(parts) == 3 and parts[0] not in ("127.0.0.1",):
                  errs.append(f"{c['stack']} compose.yaml:{n}: '{spec}' binds "
                              f"{parts[0]} rather than 127.0.0.1")

      for key in sorted(EXEMPT.keys() - used):
          errs.append(f"stale loopback-binding exemption for {key[0]} "
                      f"'{key[1]}' — nothing publishes it any more. Remove the "
                      f"entry rather than leaving a standing permission that "
                      f"would silently cover the next stack to reuse the port.")

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
  # nixos/hardware-configuration.nix (plus the generated ./stack-dirs.nix it
  # imports) owns the production tmpfiles rules, and the VM suites REPLACE that
  # file with tmpfs stubs plus their own rules — so
  # nothing else evaluates it, and reverting 'd /srv/stacks 0755 1000 1000 -'
  # to root ownership (review finding #10) would keep every suite green while
  # killing GitOps delivery in production: Arcane runs as PUID/PGID 1000, so
  # under a root-owned /srv/stacks its git sync can never create a project
  # directory and its deploys cannot read the 0600 .env files. This asserts
  # the rule on servicesFullConfig, the one eval that includes the real
  # hardware config (see default.nix).
  tmpfiles-ownership =
    mkLint "tmpfiles-ownership" ''
      ${stackDirsJson} > dirs.json
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
      # Every /mnt directory the compose files imply must have a 'd' rule in
      # the EVALUATED services-VM config, or docker creates it root-owned on
      # first deploy (the seerr crash-loop class, review finding #14 — and
      # even root-is-fine stacks like immich want the parent dirs to exist
      # with deliberate ownership, not docker's).
      #
      # The enumeration comes from nixos/generate-stack-dirs.py over a
      # readDir'd manifest — there is NO list to extend. There used to be:
      # COMPOSE_FILES named 17 of 22 stacks, so backrest, caddy, forgejo,
      # ntfy and paperless were never checked and 13 bind sources had no rule
      # at all. A hand-maintained enumeration inside a lint is not a check,
      # it is a second thing to forget.
      #
      # This leg is NOT redundant with stack-dirs-generated (which compares
      # the generator's output to the checked-in file): it measures the other
      # end of the chain, the config that would actually be deployed. It is
      # what fails if hardware-configuration.nix stops importing
      # stack-dirs.nix, or if something mkForces the rule list away.
      enum = json.load(open("dirs.json"))
      d_paths = {r.split()[1] for r in rules
                 if len(r.split()) >= 5 and r.split()[0].lower().startswith("d")}
      for path, stacks in sorted(enum["directories"].items()):
          if path not in d_paths:
              errs.append(f"{'/'.join(stacks)} needs {path}, which has no "
                          "tmpfiles 'd' rule in the evaluated services-VM "
                          "config — docker will create it root-owned on first "
                          "deploy. Run nixos/generate-stack-dirs.sh (and check "
                          "hardware-configuration.nix still imports "
                          "./stack-dirs.nix).")

      if errs:
          print("/srv/stacks tmpfiles problems:", file=sys.stderr)
          for e in errs:
              print("  - " + e, file=sys.stderr)
          sys.exit(1)
      print("/srv/stacks tmpfiles ownership OK (1000:1000); "
            f"{len(enum['sources'])} bind sources across "
            f"{len(enum['byStack'])} stacks, {len(enum['directories'])} "
            "directories with them, all have 'd' rules")
      PY
    '';

  # ---------------------------------------------------------------------------
  # nixos/stack-dirs.nix is what the generator would write
  # ---------------------------------------------------------------------------
  # The services VM's ~112 per-stack `d /mnt/...` rules are GENERATED from the
  # compose files (nixos/generate-stack-dirs.sh) and checked in, because
  # nixos/ is its own flake root and a flake cannot reference ../stacks/ — the
  # same constraint that triplicates ssh-pubkeys.nix, and the same remedy:
  # regenerate here and byte-compare, so drift is a build failure instead of a
  # silent gap.
  #
  # Byte comparison, not rule-set equality, on purpose. The prose explaining
  # WHY mosquitto is 1883 or docspace's datadir is 999 is the load-bearing part
  # of those lines; a check that ignored comments would let it rot away from
  # the value it explains.
  #
  # What this does NOT prove: that an ownership is CORRECT for its image. Only
  # a suite that boots the container can, and each stack suite does.
  stack-dirs-generated =
    mkLint "stack-dirs-generated" ''
      ${py} ${stackDirsGenerator} --manifest ${stackDirsManifest} > generated.nix
      if ! diff -u ${repo + "/nixos/stack-dirs.nix"} generated.nix > diff.txt; then
        echo "nixos/stack-dirs.nix is not what the generator produces." >&2
        echo >&2
        sed -e 's/^/  /' diff.txt >&2
        echo >&2
        echo "Fix: run ./nixos/generate-stack-dirs.sh and commit the result." >&2
        echo "Do NOT hand-edit stack-dirs.nix; ownership and prose are decided" >&2
        echo "in nixos/generate-stack-dirs.py (DIR_NOTES / STACK_NOTES)." >&2
        exit 1
      fi
      echo "nixos/stack-dirs.nix matches the generator ($(grep -c '^    "d ' generated.nix) rules)"
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
  # network_mode must be declared, because it makes a service INVISIBLE
  # ---------------------------------------------------------------------------
  # `loopback-binding` and `mk-stack-suite`'s probe list are both built from
  # `ports:` entries. A service with `network_mode: host` has no `ports:`, so it
  # does not FAIL those checks — it passes them with an empty set, while being
  # bound to every interface the host has. `trustedInterfaces = ["tailscale0"]`
  # means there is no firewall backstop either. The same is true of
  # `network_mode: service:<x>`, which silently moves a service's publishing
  # decisions into another service's stanza.
  #
  # So host networking converts a decision into an invisibility, and the only
  # defence is to make the set enumerable: every non-default network_mode must
  # be listed here with the argument for it. An unused entry is an error — a
  # stale declaration is a standing permission for a service that no longer
  # exists, and it would silently cover the next one to take the name.
  host-network-declared =
    mkLint "host-network-declared" ''
      ${py} - <<'PY'
      import json, sys, yaml

      manifest = json.load(open("${manifest}"))

      DECLARED = {
          ("caddy", "caddy"):
              "host — the reverse proxy itself. It binds the tailnet IP "
              "directly ({$TAILNET_IP} in the Caddyfile) and terminates TLS "
              "for every vhost, so it cannot sit behind its own publish. Its "
              "`bind` directive IS the boundary that ports: would otherwise "
              "provide, which is why this one is safe to make invisible.",
          ("gatus", "gatus"):
              "host — the prober. Every stack in this fleet publishes on "
              "127.0.0.1:PORT, and a container on a bridge network CANNOT "
              "reach a loopback-bound host port (stacks/ntfy's header records "
              "that the old design's host.docker.internal webhooks failed for "
              "exactly this reason). The shared `homelab` network is not a "
              "workaround either: only backrest, ntfy and part of media join "
              "it. On the host, one prober sees every loopback publish, every "
              "vhost through Caddy on the tailnet IP, and the VPS across the "
              "tailnet. It binds itself back down with web.address 127.0.0.1 "
              "in gatus.yaml, which gives the same exposure a loopback publish "
              "would — and its suite asserts that from another machine, "
              "because the generic probe cannot.",
          ("beszel", "beszel-agent"):
              "host — the collector. Without the host namespace /proc/net/dev "
              "is the container's own and network stats come out EMPTY; CPU, "
              "memory and disk I/O are fine either way (/proc/stat, "
              "/proc/meminfo and /proc/diskstats are not namespaced) and there "
              "is no HOST_PROC/HOST_SYS override anywhere in the codebase, so "
              "this is the only lever. The exposure argument is unusually easy "
              "here: with DISABLE_SSH=true the agent has NO listener at all — "
              "it is outbound-only, dialling the hub's loopback publish over a "
              "websocket — which is why _overview's port cell for the agent "
              "row is `--` and 10453 was released. The hub itself is bridged "
              "and published 127.0.0.1:10452 like everything else.",
          ("samba", "samba"):
              "host — SMB, and unlike everything else in this fleet it is not "
              "a choice. Clients speak SMB on 445 directly; there is no vhost "
              "and never will be, because Caddy does not proxy SMB and "
              "discovery is multicast. Exposure is controlled by the firewall "
              "(445 is NOT opened, so this is tailnet-only via "
              "trustedInterfaces) and by smbd's own `interfaces` + `bind "
              "interfaces only` from SAMBA_INTERFACES — samba-init refuses to "
              "start if that list omits `lo`, because the healthcheck dials "
              "\\\\localhost and its absence makes a working server look "
              "dead. tests/suites/samba.nix asserts reachability from a "
              "second machine, since the generic probe cannot.",
          ("silverbullet", "silverbullet_gitsync"):
              "host — the git mirror sidecar, and it LISTENS ON NOTHING. It "
              "is a loop that pushes the SilverBullet space to Forgejo's "
              "LOOPBACK publish (127.0.0.1:10550), which a bridged container "
              "cannot reach (the same constraint that makes stacks/gatus "
              "host-networked). Doing it this way keeps the Forgejo PAT on "
              "the host, needs no DNS, no wildcard certificate and no Caddy "
              "hop, and means a tailnet outage cannot stop the mirror. There "
              "is no inbound surface to bind down: the container has no "
              "server in it at all, so the invisibility this lint guards "
              "against costs nothing here. The SilverBullet server itself is "
              "bridged and published 127.0.0.1:10202 like everything else.",
          ("media", "qbittorrent"):
              "service:gluetun — the kill-switch, and the whole point of the "
              "media stack's design. qbittorrent has no network namespace of "
              "its own, so if gluetun dies it has NO route at all rather than "
              "falling back to the host's. Its UI is published by gluetun's "
              "127.0.0.1:10057 entry, which loopback-binding does check.",
      }

      found, errs = set(), []
      for c in manifest:
          with open(c["path"]) as f:
              compose = yaml.safe_load(f)
          for name, svc in (compose.get("services") or {}).items():
              mode = (svc or {}).get("network_mode")
              if not mode:
                  continue
              key = (c["stack"], name)
              found.add(key)
              if key not in DECLARED:
                  errs.append(
                      f"{c['stack']}/{name} sets network_mode: {mode!r} but is "
                      f"not declared in host-network-declared. That makes it "
                      f"INVISIBLE to loopback-binding and to mk-stack-suite's "
                      f"port probe — they build their lists from `ports:`, so "
                      f"this service passes them with an empty set rather than "
                      f"failing. Add an entry with the reason, or give it a "
                      f"loopback publish instead.")

      for key in sorted(DECLARED.keys() - found):
          errs.append(f"stale host-network declaration for {key[0]}/{key[1]} — "
                      f"it no longer sets network_mode. Remove the entry rather "
                      f"than leaving a standing permission.")

      if errs:
          print("network_mode problems:", file=sys.stderr)
          for e in errs:
              print("  - " + e, file=sys.stderr)
          sys.exit(1)
      print(f"network_mode declarations OK ({len(found)} services)")
      PY
    '';

  # ---------------------------------------------------------------------------
  # Backup coverage: backup-prepare.sh <-> the compose files
  # ---------------------------------------------------------------------------
  # `sqlite_backup` returns 0 for a MISSING source — `[ -f "$src" ] || return 0`
  # — so a wrong path backs up nothing, forever, with a clean exit and no
  # notification. That is not hypothetical: the Karakeep line pointed at
  # /mnt/fast/karakeep/data.db, a file the app never creates, and nothing
  # noticed until someone read the script. The pg_dumpall loop has the mirror
  # problem: it builds `container_name` as "<svc>_db" and runs
  # `pg_dumpall -U <svc>`, so a stack that names its database container
  # anything else is silently skipped by `running "$container" || continue`.
  #
  # This lint checks the halves that are checkable without a running host:
  # every sqlite path must live under a directory some compose file actually
  # bind-mounts, and every service in the pg loop must have a compose service
  # with the matching container_name AND POSTGRES_USER. Whether the file is
  # really THERE is a suite assertion — each stack suite asserts its own paths.
  #
  # Services named in the loop but not yet built are a WARNING, not an error:
  # the loop legitimately runs ahead of the campaign.
  #
  # ---------------------------------------------------------------------------
  # And the REVERSE direction, which is the one that actually lost data
  # ---------------------------------------------------------------------------
  # Everything above walks FROM backup-prepare.sh TO the compose files, so it
  # can only find a declaration that is wrong. A stack nobody ever mentioned
  # passes it in silence — which is exactly what happened to Forgejo, the git
  # root for the whole homelab: no dump line, so its WAL-mode sqlite database
  # was in the backups only as a torn file copy, and no check had an opinion
  # because no check ever started from the list of stacks.
  #
  # The three reverse legs below start from the compose files instead, using
  # the same enumeration the tmpfiles rules are generated from
  # (nixos/generate-stack-dirs.py), so a new stack enters them by existing:
  #
  #   1. every /mnt bind source is either inside a Backrest plan and not
  #      swallowed by one of its excludes, or covered by a dump, or explicitly
  #      allowlisted with a reason;
  #   2. every stack has at least one dump, or is allowlisted with a reason
  #      saying why a raw file copy is consistent for it;
  #   3. every container running a real database ENGINE is dumped logically —
  #      a file-level copy of a live datadir generally does not restore.
  #
  # Both allowlists are stale-checked: an entry that stops being needed is an
  # error, so they cannot silently become a list of things nobody rechecked.
  backup-coverage =
    mkLint "backup-coverage" ''
      ${stackDirsJson} > dirs.json
      ${py} - <<'PY'
      import json, re, sys, os

      manifest = json.load(open("${manifest}"))
      script = open("${(repo + "/nixos/backup-prepare.sh")}").read()

      import yaml
      # Every /mnt bind-mount source across every compose file, plus each
      # service's container_name and environment.
      #
      # 🚨 WHOLE-TIER MOUNTS ARE EXCLUDED, and without that this lint is
      # VACUOUS. stacks/backrest declares `- /mnt/fast:/mnt/fast:ro` so it can
      # snapshot everything, which means EVERY path under /mnt/fast sits inside
      # a declared bind mount — including the Karakeep path that pointed at a
      # file the app never creates. The first version of this check passed that
      # bug happily. Only a SERVICE-SPECIFIC mount is evidence that some
      # container actually writes there.
      TIER_MOUNTS = {"/mnt", "/mnt/fast", "/mnt/slow"}
      mounts = set()
      containers = {}   # container_name -> {stack, env, mounts, image}
      nameless = []     # services WITHOUT container_name — invisible to
                        # every container-keyed leg below, so leg 3 checks
                        # them separately
      for c in manifest:
          with open(c["path"]) as f:
              compose = yaml.safe_load(f)
          for name, svc in (compose.get("services") or {}).items():
              svc_mounts = set()
              for v in svc.get("volumes") or []:
                  src = v.split(":")[0] if isinstance(v, str) else (v.get("source") or "")
                  if src.startswith("/mnt/"):
                      src = src.rstrip("/")
                      if src not in TIER_MOUNTS:
                          mounts.add(src)
                          svc_mounts.add(src)
              env = {}
              raw = svc.get("environment") or []
              if isinstance(raw, dict):
                  env = {k: str(v) for k, v in raw.items()}
              else:
                  for e in raw:
                      k, _, v = str(e).partition("=")
                      env[k] = v
              cn = svc.get("container_name")
              if cn:
                  containers[cn] = {
                      "stack": c["stack"],
                      "env": env,
                      "mounts": svc_mounts,
                      "image": svc.get("image") or "",
                  }
              else:
                  nameless.append({
                      "stack": c["stack"],
                      "service": name,
                      "image": svc.get("image") or "",
                  })

      errs, warns = [], []

      # --- sqlite_backup <name> <path> ------------------------------------
      calls = re.findall(r"^sqlite_backup\s+(\S+)\s+(\S+)\s*$", script, re.M)
      if not calls:
          errs.append("no sqlite_backup calls parsed from backup-prepare.sh — "
                      "the parser has rotted; fix it before trusting this lint")
      for name, path in calls:
          if not path.startswith("/mnt/"):
              errs.append(f"sqlite_backup {name}: {path} is not under /mnt")
              continue
          # The path must sit inside (or at) some declared bind-mount source.
          if not any(path == m or path.startswith(m + "/") for m in mounts):
              errs.append(
                  f"sqlite_backup {name} reads {path}, which is not inside any "
                  f"SERVICE-SPECIFIC /mnt bind mount declared by a compose "
                  f"file (whole-tier mounts like backrest's /mnt/fast:ro do "
                  f"not count — they would make this check vacuous). "
                  f"sqlite_backup returns 0 for a missing source, so this line "
                  f"backs up NOTHING and exits clean.")

      # --- the pg_dumpall loop --------------------------------------------
      m = re.search(r"^for svc in ([^;]+); do", script, re.M)
      if not m:
          errs.append("could not parse the pg_dumpall `for svc in ...` loop — "
                      "the parser has rotted")
      else:
          for svc in m.group(1).split():
              cn = f"{svc}_db"
              if cn not in containers:
                  warns.append(
                      f"pg_dumpall loop names '{svc}' but no compose file has "
                      f"container_name: {cn} — expected while that stack is "
                      f"still on the roadmap, a silent no-dump once it exists")
                  continue
              stack, env = containers[cn]["stack"], containers[cn]["env"]
              if env.get("POSTGRES_USER") != svc:
                  errs.append(
                      f"{stack}: {cn} has POSTGRES_USER="
                      f"{env.get('POSTGRES_USER')!r}, but backup-prepare.sh "
                      f"runs `pg_dumpall -U {svc}`. The dump fails and the "
                      f"only signal is rc=1 in a unit nobody reads.")

      # =====================================================================
      # REVERSE LEG: start from the stacks, not from the backup script
      # =====================================================================
      enum = json.load(open("dirs.json"))
      plans = json.load(open("${(repo + "/stacks/backrest/config.template.json")}"))["plans"]

      def swallowed(path, excludes):
          """Is EVERYTHING under `path` excluded from this plan?

          Restic's excludes are path globs; the two shapes that occur here are
          a literal prefix (/mnt/fast/karakeep/meili/**) and a name anywhere
          (**/cache/**). A pattern that only matches files inside the
          directory (**/*.log) is not swallowing, and is ignored.
          """
          for pat in excludes:
              p = pat[:-3] if pat.endswith("/**") else pat
              if p.startswith("**/"):
                  tail = p[3:]
                  if "*" in tail:
                      continue
                  parts = path.split("/")
                  for i in range(len(parts)):
                      if "/".join(parts[:i + 1]).endswith("/" + tail):
                          return pat
              elif path == p or path.startswith(p + "/"):
                  return pat
          return None

      # --- what the dumps cover -------------------------------------------
      # A dump covers a bind source when it reads a file inside it (sqlite) or
      # when it dumps a container that mounts it (pg/mysql: the dump lands in
      # /mnt/fast/_dumps, so the datadir itself is what the coverage is FOR).
      dumped_containers = {cn for cn in containers if re.search(
          r"(?:docker exec|require_running)\s+" + re.escape(cn) + r"\b", script)}
      if m:
          dumped_containers |= {f"{s}_db" for s in m.group(1).split()
                                if f"{s}_db" in containers}
      # authentik_db is dumped over ssh from the VPS in the same script; it is
      # in `containers` via headscale-vps/authentik/compose.yaml but has no
      # /mnt mount on this host, so it never reaches the path legs below.

      dump_covered = set()
      for _name, path in calls:
          for src in mounts:
              if path == src or path.startswith(src + "/"):
                  dump_covered.add(src)
      for cn in dumped_containers:
          dump_covered |= containers[cn]["mounts"]

      # --- 1. every bind source is backed up, or explicitly is not ---------
      # Keys are checked for staleness below: when a path stops being a bind
      # source, or starts being backed up, its entry here becomes an error.
      NOT_BACKED_UP = {
          "/mnt/slow/data":
              "The media library and the download scratch beneath it. Tens to "
              "hundreds of GB of re-acquirable content, and the slow-volume "
              "plan is an explicit include list this is deliberately not on. "
              "The *arr databases that DESCRIBE the library are dumped, so a "
              "restore rebuilds the metadata and re-acquires the files.",
          "/mnt/slow/data/downloads": "See /mnt/slow/data — in-flight torrents.",
          "/mnt/slow/data/media": "See /mnt/slow/data — the library itself.",
          "/mnt/slow/frigate":
              "Recordings, clips and exports: re-recordable by definition and "
              "the largest thing on the host. frigate.db, the event/review "
              "index that gives them meaning, IS dumped. Adding this path "
              "would blow the retention budget for everything else.",
          "/mnt/slow/beszel-fsprobe":
              "An intentionally EMPTY marker directory. Beszel's agent "
              "statfs()es it to report the slow tier's usage; there is "
              "nothing in it to back up, now or ever.",
          "/mnt/fast/backrest/cache":
              "restic's own cache (XDG_CACHE_HOME), rebuilt from the "
              "repository on demand. Backing a backup tool's cache up into "
              "the repository it caches is circular.",
          "/mnt/fast/backrest/data":
              "Backrest's operation log — the UI's history of past runs. Not "
              "needed to restore: restic reads the repository itself, and the "
              "credentials for it (RESTIC_PASSWORD, the storage-box key) come "
              "from sops, not from here.",
          "/mnt/fast/jellyfin/cache":
              "Transcodes and image cache, regenerated on demand. "
              "jellyfin.db and library.db are dumped separately.",
          "/mnt/fast/ntfy/cache":
              "ntfy's message cache (cache-file): the recent-message buffer "
              "for clients that were offline, minutes to hours of value. The "
              "auth/ACL database in lib/ is the part that matters and it is "
              "dumped.",
          "/mnt/fast/shelfmark/tmp":
              "Download scratch; shelfmark's entrypoint repairs it at every "
              "start.",
          "/mnt/fast/immich/model-cache":
              "The CLIP/face-recognition model weights — several GB, "
              "re-downloaded on first use, identical for every install.",
          "/mnt/fast/karakeep/meili":
              "The Meilisearch index, rebuilt from karakeep's sqlite database "
              "(which is dumped). Restoring a search index is slower than "
              "reindexing it.",
          "/mnt/fast/docspace/logs":
              "Log output from the monolith's supervisord children.",
          "/mnt/slow/loki":
              "Loki's entire store — chunks, tsdb index, WAL and compactor "
              "state — capped at 100 GB by a 720h retention_period plus the "
              "loki-retention-check alarm. Not backed up on purpose, and the "
              "reason is stronger than 'it is big': these are OBSERVATIONS "
              "ABOUT a fleet whose real state is backed up elsewhere. A "
              "restore replaying 30 days of logs from a host that no longer "
              "exists is not neutral, it is misleading — every dashboard "
              "would show a period the rebuilt system did not live through. "
              "The slow-volume plan is an explicit include list and this is "
              "deliberately not on it; grafana.db (the dashboards and saved "
              "queries that give the logs meaning) IS dumped, so a restore "
              "comes back with the tooling and an honest empty window.",
      }
      uncovered = []
      for src in sorted(enum["sources"]):
          stacks = "/".join(enum["sources"][src])
          if src in dump_covered:
              continue
          why_not = "no Backrest plan includes it"
          for plan in plans:
              if not any(src == p or src.startswith(p.rstrip("/") + "/")
                         for p in plan["paths"]):
                  continue
              hit = swallowed(src, plan.get("excludes") or [])
              if not hit:
                  why_not = None
                  break
              why_not = f"plan {plan['id']} excludes it ({hit})"
          if why_not is None:
              continue
          if src in NOT_BACKED_UP:
              continue
          uncovered.append(
              f"{stacks}: {src} holds persistent data and is in NO backup — "
              f"{why_not}, and no dump in backup-prepare.sh reads it. Either "
              f"add it (a Backrest plan path, or a dump if it is a live "
              f"database) or add it to NOT_BACKED_UP in this lint with the "
              f"reason it is worth nothing. Silence is what lost Forgejo.")
      errs += uncovered

      for src in sorted(set(NOT_BACKED_UP) - set(enum["sources"])):
          errs.append(f"stale NOT_BACKED_UP entry {src}: no compose file "
                      f"bind-mounts it any more. Remove it rather than "
                      f"leaving a standing exemption.")
      for src in sorted(set(NOT_BACKED_UP) & dump_covered):
          errs.append(f"{src} is in NOT_BACKED_UP but backup-prepare.sh now "
                      f"dumps from it. Remove the exemption.")

      # --- 2. every stack has a dump, or says why it does not --------------
      # A raw file copy is only consistent for data nothing is writing through
      # a journal. This is the leg Forgejo needed: its tree WAS in the
      # fast-volume plan, so leg 1 was happy, and the file it was copying was a
      # live WAL-mode sqlite database.
      STACKS_WITHOUT_DUMPS = {
          "backrest":
              "No database. config.json is re-seeded from "
              "config.template.json + .sops.env by config-init on every "
              "deploy, and nothing else here is needed to restore FROM the "
              "repository.",
          "caddy":
              "No database. data/ holds the ACME account key and issued "
              "certificates and config/ holds Caddy's autosave — both are "
              "re-obtained from Let's Encrypt on a fresh start (DNS-01, "
              "credentials in sops). Raw-copied by the fast-volume plan "
              "anyway.",
          "notes-sync":
              "No database engine. rmfakecloud's store and syncthing's "
              "config and synced trees are plain files, consistent as a raw "
              "copy; syncthing's index-v2 is excluded from the plan and "
              "rebuilt from the files themselves.",
          "silverbullet":
              "No database engine at all: the space is a directory of "
              "markdown files, which is the entire point of the app, and a "
              "raw copy of markdown is consistent. The fast-volume plan "
              "includes /mnt/fast/silverbullet/space with no exclude "
              "touching it. The git mirror in Forgejo is NOT the backup and "
              "does not excuse this — it only holds what has been committed "
              "and pushed, and it lives on the same host.",
          "samba":
              "No database — it is a file share. Its tree is "
              "/mnt/slow/samba/shared, which slow-volume-selective includes "
              "by name.",
      }
      stacks_with_dumps = {s for src in dump_covered
                           for s in enum["sources"].get(src, [])}
      for stack in sorted(enum["byStack"]):
          if stack in stacks_with_dumps or stack in STACKS_WITHOUT_DUMPS:
              continue
          errs.append(
              f"stack {stack!r} keeps persistent data in "
              f"{', '.join(enum['byStack'][stack])} and backup-prepare.sh "
              f"dumps NOTHING for it. If it has a database, a raw copy of it "
              f"inside the Backrest plan is a torn snapshot, not a backup "
              f"(Forgejo, for a year). If it genuinely has none, add it to "
              f"STACKS_WITHOUT_DUMPS with the reason.")
      for stack in sorted(set(STACKS_WITHOUT_DUMPS) - set(enum["byStack"])):
          errs.append(f"stale STACKS_WITHOUT_DUMPS entry {stack!r}: it has no "
                      f"/mnt bind mounts any more. Remove it.")
      for stack in sorted(set(STACKS_WITHOUT_DUMPS) & stacks_with_dumps):
          errs.append(f"{stack} is in STACKS_WITHOUT_DUMPS but now has a dump. "
                      f"Remove the exemption.")

      # --- 3. every database ENGINE is dumped logically --------------------
      # Redis is deliberately not on this list: the two instances that persist
      # anything (dawarich's sidekiq queue, wger's cache) hold reconstructible
      # state, and their append-only files raw-copy acceptably.
      ENGINE_RE = re.compile(r"(postgres|postgis|mariadb|mysql)", re.I)
      for cn, info in sorted(containers.items()):
          if not ENGINE_RE.search(info["image"]) or cn in dumped_containers:
              continue
          errs.append(
              f"{info['stack']}: {cn} runs a database engine "
              f"({info['image']}) that backup-prepare.sh never dumps. A "
              f"file-level copy of a live datadir does not reliably restore, "
              f"and the plans exclude **/pgdata/** precisely because of that "
              f"— so this database is currently in no backup at all.")
      # A service without container_name never enters `containers`, so the
      # loop above cannot see it — and backup-prepare.sh execs FIXED names, so
      # a compose-generated one can never be dumped at all. For an engine the
      # missing name is therefore itself the defect (and legs 1/2 do not
      # catch it: a whole-tier raw copy satisfies leg 1 and any other dump in
      # the stack satisfies leg 2 — the Forgejo shape again).
      for info in sorted(nameless, key=lambda i: (i["stack"], i["service"])):
          if not ENGINE_RE.search(info["image"]):
              continue
          errs.append(
              f"{info['stack']}: service {info['service']!r} runs a database "
              f"engine ({info['image']}) but sets no container_name, so "
              f"backup-prepare.sh cannot exec it and the database can never "
              f"be dumped. Give it a container_name and wire a dump.")

      for w in warns:
          print("  WARN " + w, file=sys.stderr)
      if errs:
          print("Backup coverage problems:", file=sys.stderr)
          for e in errs:
              print("  - " + e, file=sys.stderr)
          sys.exit(1)
      print(f"Backup coverage OK ({len(calls)} sqlite paths, "
            f"{len(warns)} not-yet-built); reverse leg: "
            f"{len(enum['sources'])} bind sources across "
            f"{len(enum['byStack'])} stacks, "
            f"{len(NOT_BACKED_UP)} paths and {len(STACKS_WITHOUT_DUMPS)} "
            f"stacks exempt by name, "
            f"{len(dumped_containers)} database containers dumped")
      PY
    '';

  # ---------------------------------------------------------------------------
  # _overview.md's Auth column <-> what is actually configured
  # ---------------------------------------------------------------------------
  # The inventory's Auth cell is the only place the intended posture for a
  # service is written down, and it has been wrong three times in one campaign:
  # rmfakecloud was marked FwdAuth when forward auth would break the tablet
  # entirely, Syncthing was marked LDAP, and ExcaliDash was marked FwdAuth when
  # it drives its own OIDC. Each was caught by a human reading the row, which
  # is not a control.
  #
  # This checks the direction that is mechanically decidable: a row that claims
  # FwdAuth must have a Caddy handle that imports `protected`. The reverse
  # direction (a protected host with no row) is already covered by
  # overview-sync, and the blueprint half by forward-auth-coverage.
  #
  # A row whose service has NO Caddy route at all is a WARNING: the inventory
  # is deliberately a roadmap, and rows routinely land before stacks do.
  auth-column-parity =
    mkLint "auth-column-parity" ''
      ${py} - <<'PY'
      import re, sys

      overview = open("${../../../ServerNotes/designs/_overview.md}").read()
      caddyfile = open("${(repo + "/stacks/caddy/Caddyfile")}").read()

      # --- Caddyfile: upstream PORT -> (host, does its handle import protected?)
      # Keyed on the port rather than on the row's NAME. Names do not survive
      # the trip: "Firefly III" is served at firefly.svc, "OnlyOffice DocSpace"
      # at onlyoffice.svc, and any slug heuristic silently degrades those to a
      # warning — i.e. to no coverage at all, for exactly the rows most worth
      # covering. The port is in both files and is unambiguous.
      matchers, routes = {}, {}
      current, current_depth, depth = None, 0, 0
      for raw in caddyfile.splitlines():
          line = re.sub(r"#.*$", "", raw)
          m = re.match(r"\s*@(\S+)\s+host\s+(\S+)", line)
          if m:
              matchers[m.group(1)] = m.group(2)
          h = re.match(r"\s*handle\s+@(\S+)\s*\{", line)
          if h and current is None:
              current, current_depth = h.group(1), depth
          if current is not None:
              if re.match(r"\s*import\s+protected\s*$", line):
                  routes.setdefault(current, {"protected": False})["protected"] = True
              p = re.search(r"\breverse_proxy\s+localhost:(\d+)", line)
              if p:
                  r = routes.setdefault(current, {"protected": False})
                  r["port"] = int(p.group(1))
                  r["host"] = matchers.get(current)
          depth += line.count("{") - line.count("}")
          if current is not None and depth <= current_depth:
              current = None

      by_port = {}
      for name, r in routes.items():
          if "port" in r:
              # A handle may hold several reverse_proxy lines (vaultwarden
              # splits /admin from the rest); `protected` is true if ANY path
              # in it is protected, which is what the row can honestly claim.
              prev = by_port.get(r["port"])
              by_port[r["port"]] = {
                  "host": r.get("host") or (prev or {}).get("host"),
                  "protected": r["protected"] or bool((prev or {}).get("protected")),
              }

      assert by_port.get(10401, {}).get("protected"), (
          "auth-column-parity found no protected bentopdf pilot on 10401 — the "
          "Caddyfile parser has rotted; fix it before trusting this lint")

      # --- _overview rows --------------------------------------------------
      errs, warns, checked = [], [], 0
      for line in overview.splitlines():
          cells = [c.strip() for c in line.strip().strip("|").split("|")]
          if len(cells) < 5 or not re.search(r"\d", cells[2] or ""):
              continue
          name, port_cell, auth = cells[0], cells[2], cells[3]
          # Struck-through rows are parked/deferred by design.
          if name.startswith("~~"):
              continue
          if "FwdAuth" not in auth:
              continue
          checked += 1
          ports = [int(p) for p in re.findall(r"\b(\d{4,5})\b", port_cell)]
          hit = next((by_port[p] for p in ports if p in by_port), None)
          if hit is None:
              warns.append(f"{name!r} is marked FwdAuth but no Caddy handle "
                           f"proxies any of its ports {ports} — expected while "
                           f"the stack is still on the roadmap")
              continue
          if not hit["protected"]:
              errs.append(
                  f"{name!r} is marked FwdAuth in _overview.md but the Caddy "
                  f"handle for {hit['host']} does not `import protected` — the "
                  f"inventory claims an authentication that is not there.")

      for w in warns:
          print("  WARN " + w, file=sys.stderr)
      if errs:
          print("Auth column problems:", file=sys.stderr)
          for e in errs:
              print("  - " + e, file=sys.stderr)
          sys.exit(1)
      print(f"Auth column OK ({checked} FwdAuth rows, {len(warns)} not routed yet)")
      PY
    '';

  # ---------------------------------------------------------------------------
  # Gatus target coverage
  # ---------------------------------------------------------------------------
  # Every vhost in the Caddyfile must be probed by Gatus BOTH ways, because
  # each probe is blind to exactly what the other catches:
  #
  #   path probe    https://<host>/ with the real Host: header — proves Caddy,
  #                 the wildcard cert, DNS, and (for protected routes) the
  #                 tailnet and the VPS outpost. Blind to the service itself
  #                 when the route 302s before reaching it.
  #   service probe http://127.0.0.1:<port>/ — proves the app answers. Blind to
  #                 Caddy, TLS, host routing and forward auth.
  #
  # This exists because adding a vhost is a two-file change that nothing
  # previously enforced, and the failure mode is silent: the service works and
  # is simply never watched. A monitoring gap has no symptom until the outage
  # it would have caught.
  #
  # The path-probe half is also the only structural guard on findings #27 and
  # #15 — Dawarich's host_authorization and qBittorrent's Host-port 401 are
  # both "healthy container, every browser request fails", which a container
  # healthcheck is incapable of seeing because it dials loopback with the
  # wrong Host.
  gatus-target-coverage =
    mkLint "gatus-target-coverage" ''
      ${py} - <<'PY'
      import re, sys, yaml

      caddyfile = open("${(repo + "/stacks/caddy/Caddyfile")}").read()
      gatus = yaml.safe_load(open("${(repo + "/stacks/gatus/gatus.yaml")}"))

      # The same parser as auth-column-parity, deliberately: two lints
      # disagreeing about what the Caddyfile says would be worse than either
      # one being wrong.
      matchers, routes = {}, {}
      current, current_depth, depth = None, 0, 0
      for raw in caddyfile.splitlines():
          line = re.sub(r"#.*$", "", raw)
          m = re.match(r"\s*@(\S+)\s+host\s+(\S+)", line)
          if m:
              matchers[m.group(1)] = m.group(2)
          h = re.match(r"\s*handle\s+@(\S+)\s*\{", line)
          if h and current is None:
              current, current_depth = h.group(1), depth
          if current is not None:
              p = re.search(r"\breverse_proxy\s+localhost:(\d+)", line)
              if p:
                  r = routes.setdefault(current, {"ports": set()})
                  r["ports"].add(int(p.group(1)))
                  r["host"] = matchers.get(current)
          depth += line.count("{") - line.count("}")
          if current is not None and depth <= current_depth:
              current = None

      vhosts = {}
      for r in routes.values():
          if r.get("host"):
              vhosts.setdefault(r["host"], set()).update(r["ports"])
      if "bentopdf.svc.idanreed.com" not in vhosts:
          sys.exit("gatus-target-coverage found no bentopdf vhost — the "
                   "Caddyfile parser has rotted; fix it before trusting this "
                   "lint")

      probed_hosts, probed_ports = set(), set()
      for e in gatus.get("endpoints") or []:
          url = e.get("url") or ""
          m = re.match(r"https://([^/]+)", url)
          if m:
              probed_hosts.add(m.group(1))
          m = re.match(r"http://127\.0\.0\.1:(\d+)", url)
          if m:
              probed_ports.add(int(m.group(1)))

      # Named exemptions, port -> reason. A SERVICE probe may be skipped where a
      # loopback fetch cannot mean anything; the PATH probe is never exempt,
      # because that is the half catching the host-header class of bug.
      EXEMPT_SERVICE = {
          10450: "gatus itself. A service probe here is a tautology — if gatus "
                 "can run the check, the answer is yes — so it would satisfy "
                 "this lint while proving nothing. Its PATH probe is not "
                 "exempt and does real work: it traverses Caddy, so it covers "
                 "the route, the wildcard cert and the outpost, none of which "
                 "gatus can see from the inside.",
      }

      errs = []
      for host in sorted(vhosts):
          if host not in probed_hosts:
              errs.append(
                  f"{host} is routed by Caddy but has NO gatus path probe. Add "
                  f"an endpoint for https://{host}/ in stacks/gatus/gatus.yaml "
                  f"— and if that route imports `protected`, its conditions "
                  f"must be [STATUS] == 302 with client.ignore-redirect, NOT "
                  f"200: an unauthenticated request is supposed to redirect, "
                  f"and accepting 200-399 turns the probe into an Authentik "
                  f"liveness check wearing the service's name")
          for port in sorted(vhosts[host]):
              if port in probed_ports or port in EXEMPT_SERVICE:
                  continue
              errs.append(
                  f"{host} proxies to localhost:{port} but gatus has NO "
                  f"service probe for it. The path probe alone is blind to the "
                  f"app whenever a protected route 302s first — it would stay "
                  f"green with the service dead")

      # An exemption that no longer applies is a silent hole — the same
      # discipline host-network-declared enforces on its DECLARED dict.
      routed_ports = {p for ports in vhosts.values() for p in ports}
      for port in EXEMPT_SERVICE:
          if port not in routed_ports:
              errs.append(
                  f"EXEMPT_SERVICE lists {port}, but no Caddy handle proxies "
                  f"to it any more. Remove the entry — a stale exemption "
                  f"quietly excuses whatever takes that port next")

      if errs:
          print("gatus target coverage problems:", file=sys.stderr)
          for e in errs:
              print("  - " + e, file=sys.stderr)
          sys.exit(1)
      n_ports = sum(len(p) for p in vhosts.values())
      print(f"Gatus target coverage OK ({len(vhosts)} vhosts, {n_ports} "
            f"upstream ports, all probed both ways)")
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
