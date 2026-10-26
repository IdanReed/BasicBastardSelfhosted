# Recommendations for `decisions.md`

One recommendation per deferred decision (D-01 … D-64) and per accepted risk. Nothing here is applied.

**How to use it:** approve a bucket in bulk ("take bucket 2"), or override single items by ID ("all of
bucket 3 except D-20"). Where a recommendation differs from the one written in `decisions.md`, the line
says **(overrides)**.

Standing facts behind these calls:

- The fleet is live, and Komodo is the deploy plane: a push to Forgejo fires its `apply` procedure
  (`komodo/sync/fleet.toml`), which deploys the stacks that changed.
- `sopsgen apply` has **not** been run. Anything that adds, drops or fills a secret value is operator-gated.
- The branch being landed (`land-code-review`) stops at `fa0a49d`. It does **not** contain `23f35d3`
  (Jellyfin/Seerr/Bazarr + Firefly Passport, "needs sopsgen apply"). D-35 and the seerr half of D-08 are about
  that commit.

---

## 1. Keep current behaviour — no work, or a comment only (12)

- **D-19 · Eight byte-identical Postgres blocks** — **Recommendation:** leave; one directory = one deployable stack is the property both the deploy plane and the harness rely on.
- **D-29 · `postgis:17-3.5-alpine` moving tag** — **Recommendation:** keep, with a one-line "conscious exception, no patch-pinned alpine tag exists" comment; `images.nix` already makes drift visible.
- **D-30 · `scan-downloads.sh` quarantines partials** — **Recommendation:** leave; it fails safe and the alternative reopens the mtime hole.
- **D-33 · Vaultwarden `SSO_SIGNUPS_ALLOWED=true`** — **Recommendation:** keep `true`; the Authentik user list is the gate and a second one buys nothing for 7 users.
- **D-34 · Authentik `Admin` group = BookStack admin** — **Recommendation:** keep; the coupling is named in the blueprint comment and there is no second matching app.
- **D-36 · Actual OIDC DB flip** — **Recommendation:** keep manual and add the ownership-race sentence to the for-shame entry; here the manual step is the safety mechanism.
- **D-40 · Firefly headless PAT mint** — **Recommendation:** keep manual and amend the for-shame entry with the reason (no tinker, browser-only `createToken`); the persisted Passport keypair removes most of the pain.
- **D-41 · Immich `IMMICH_ALLOW_SETUP`** — **Recommendation:** leave unset; re-seed after a volume wipe is worth more than closing a loopback-only restore endpoint.
- **D-44 · tmpfiles rule order** — **Recommendation:** accept; same rules, ordering constraint preserved.
- **D-47 · `nixos-de/statix.toml`** — **Recommendation:** keep; it turns statix from noise into a gate, and the disabled classes are idiomatic NixOS.
- **D-52 · Renovate cannot bump the Caddy plugin half** — **Recommendation:** leave documented; plugin bumps are rare and a go-datasource manager is fiddly.

## 2. Do it — small, safe, repo-only (21)

Ships with a normal push / `./deploy`; no secret values, no live lookups.

- **D-04 · Backrest exempt from forward auth** — **Recommendation (overrides):** confirm the exemption with the real reason and add the `@backrest` and `@paperless` Caddyfile comments; Backrest is the restore tool for the VPS's Authentik, so forward auth would make recovery depend on the thing being recovered (and would silently retype the gatus path probe to a 302 check).
- **D-07 · No `no-new-privileges` anywhere** — **Recommendation:** pilot on `shelfmark` and `karakeep_chrome` only, one `run.sh stack <name>` each; they are the internet-facing scrapers and neither is an s6 image.
- **D-09 · CI runs on the production VM** — **Recommendation (overrides, adds):** record the "who can open a PR" boundary in the module header, and add `IPAddressDeny=localhost` to `gitea-runner-forgejo.service`; the runner reaches Forgejo via the tailnet URL and no workflow uses loopback, so this cuts jobs off every loopback publish at near-zero cost (verify with one `suites` run).
- **D-10 · `akadmin` + bootstrap token are permanent** — **Recommendation:** document as break-glass now in the three named docs; retire `akadmin` once the per-app OIDC UI steps are done.
- **D-12 · fail2ban can lock a tailnet device out of SSH** — **Recommendation:** add the tailnet ranges to `services.fail2ban.ignoreIP`; the reputation policy still scores per `(username, ip)`.
- **D-14 · Published desktop container ports bypass the firewall** — **Recommendation:** document the `127.0.0.1:PORT:PORT` convention in `containers.nix`; `iptables = false` breaks outbound networking.
- **D-25 · Where trimmed analysis lives** — **Recommendation:** move the three named passages (vaultwarden quoting, SimpleFIN walkthrough, rmfakecloud `sanitizeEmail`) from git history into `ServerNotes/designs/`; examples stay terse.
- **D-27 · Two unwired secret knobs** — **Recommendation (picks):** keep `FRIGATE_CAM_EXAMPLE` with an example comment; hardcode `1000` in `samba-init.sh` and drop the `SAMBA_SHARE_GID` indirection — it is in no env file, so this is a script-only edit.
- **D-28 · Paperless ordering + healthchecks** — **Recommendation:** add `pg_isready`/`redis-cli ping`, `condition: service_healthy`, and an app healthcheck on an endpoint checked against 2.20 (not `/`); gate on `./tests/run.sh paperless`.
- **D-31 · qBittorrent `_overview.md` says FwdAuth** — **Recommendation (picks):** correct the Auth cell to `--` (loopback via gluetun) now; add the blueprint and protected route later as one change.
- **D-48 · Delete `headscale/cloud-init.yml`** — **Recommendation:** delete, update both CLAUDE.md "Legacy directories" paragraphs and the ServerNotes issue line; it documents a known outage shape as if it were a reference.
- **D-49 · Pin `nix-prefetch-docker`** — **Recommendation:** pin via `nix-build tests -A pkgs.nix-prefetch-docker`; the pin generator must not drift from the harness.
- **D-53 · Nightly heavy suite fails silently** — **Recommendation:** add an `if: failure()` curl step to `https://ntfy.svc.idanreed.com/alerts` (the Caddy URL, so it survives D-09's loopback deny and gains a token if D-02 lands).
- **D-54 · `.gitignore` `*.claude`** — **Recommendation:** narrow to `.claude/settings.local.json` + `.claude/worktrees/`, and inspect `git status --ignored` before the next commit so nothing lands unreviewed.
- **D-55 · `--sudo` vs `--use-remote-sudo`** — **Recommendation:** standardise the docs on `--use-remote-sudo` (the code's spelling); revisit only if upstream drops the alias.
- **D-56 · Log-style docs** — **Recommendation:** move `DOC-DRIFT-REPORT.md` and `main-verification-status.md` to `ServerNotes/notes/` with a superseded header, retire `_todo.md` in favour of `deploy-status.md` (and update CLAUDE.md's pointer), and delete handbook §2.2 once the operator confirms the registrar transfer finished.
- **D-57 · README service tables duplicate `_overview.md`** — **Recommendation:** replace with a pointer; coordinate with the open `readme-rewrite` branch, which rewrites the root README.
- **D-58 · DocSpace auth contradicted** — **Recommendation:** set the `_overview.md` row to `Local` and reword the `UNAUTHENTICATED_OK` reason that cites SAML; SAML is separate work.
- **D-59 · Phantom `qbit_manage` row** — **Recommendation:** mark it Planned.
- **D-64 · VPS/desktop READMEs break a fresh install** — **Recommendation:** reduce both to a pointer at the canonical runbook plus host-specific notes; the VPS one reproduces the duplicate-`idan` lockout and the age-key-in-workspace anti-pattern. Do this one first in the bucket.

## 3. Do it — repo-only but larger (own change + suite run) (9)

- **D-06 · Backup key is passwordless root on the VPS** — **Recommendation:** forced command `vps-backup-pull` + a `security.sudo.extraRules` entry for its three calls; confirm with one real nightly backup, since failure is loud (`rc_vps=1` → ntfy).
- **D-08 · Shared `env_file` over-shares secrets** — **Recommendation (timing):** convert `gluetun`, `profilarr`, `frigate` to explicit `${VAR:-}` now; fold the seerr conversion into `23f35d3` **before** `sopsgen apply`, so the duplicate `API_KEY` target never reaches the real file; decide the lint afterwards.
- **D-20 · Generate the OIDC blueprints** — **Recommendation:** generator + committed artifacts + `blueprints-generated` lint, the `stack-dirs` pattern; 19 hand-edited copies is the VPS's largest silent-drift risk.
- **D-21 · Firewall coverage in the harness** — **Recommendation:** add `firewall-declared` and extend the tailnet negative sweep to every published port (Samba 445, Syncthing 22000 first) before writing another stack suite.
- **D-26 · `sopsgen rotate user/idan` misses four consumers** — **Recommendation:** all three options — rotation-reach table in `docs/deploy.md` §5.5 plus the for-shame row, detect-and-shout in Beszel and Windmill (Backrest via D-37), and a post-run report from `sopsgen rotate`; the current wording is what gets trusted mid-incident.
- **D-37 · Backrest template: seed or source of truth** — **Recommendation:** merge `auth.users[].passwordBcrypt` on every start now; document the file as a seed; defer the `repos`/`plans` merge until you decide who owns retention.
- **D-61 · for-shame vs manifest** — **Recommendation:** lint that every `class: pull` entry appears in `for-shame.md`; generation would lose the prose.
- **D-62 · Lint `_overview.md` columns** — **Recommendation:** extend `overview-sync` to the Volume column first (a restore depends on it), then the Auth-cell reverse leg that would have caught D-58.
- **D-63 · Nine undocumented bring-up steps** — **Recommendation:** add all nine to `deploy-handbook.md`, each with a Verify line; a from-scratch runbook that skips steps is the failure it exists to prevent.

## 4. Do it — needs operator / secret / live action (9)

Order matters: do D-35, D-08 (seerr), D-23, D-24 and D-02's SMTP choice **before or during** the first `sopsgen apply` / placeholder fill, so one sudo session covers them.

- **D-01 · Split the age recipient per host** — **Recommendation:** per-host keys with the operator key a recipient of everything, then delete the shared key from the VPS and VM disks (and do AS-18's cleanup, or the VM half is moot); the only internet-facing host currently decrypts the whole fleet. Escrow the operator key offline (AS-16) first.
- **D-02 · ntfy anonymous read-write + SMTP** — **Recommendation (overrides, sequencing):** during the placeholder fill set all three `NTFY_SMTP_*` values empty instead of filling `NTFY_SMTP_SENDER_PASS` (no publisher sends `X-Email`; the example supports empty), and replace the `TODO: decide` with an ACCEPTED reason; do deny-all + tokens with D-05, when a non-owned node joins.
- **D-03 · `trusted_proxies` spans the tailnet** — **Recommendation:** run `tailscale ip -4` on 10.0.0.3, narrow to that /32, `./deploy --vps`, then check one forward-auth route; fail2ban and the reputation policy currently key on a forgeable IP.
- **D-13 · Workstation FQDNs in public GitHub history** — **Recommendation:** after the branch lands on `main`, delete and recreate the GitHub mirror from the current tip; the mirror's history has no independent value and rewriting Forgejo is not needed.
- **D-23 · `TAILSCALE_AUTH_KEY_OLD`** — **Recommendation:** drop it from both real files, both `.example`s and the three fixtures, and from CLAUDE.md's secrets paragraph; an unreferenced live preauthkey is worse than a re-mint.
- **D-24 · Vestigial Windmill admin keys** — **Recommendation:** drop from `.sops.env`, `.example`, fixture and the suite assertion in one change; an unmanaged real password that nothing reads is pure liability.
- **D-35 · Jellyfin admin from sops** — **Recommendation:** land `23f35d3` whole (with D-08's seerr edit), then `sopsgen apply` + the hand-set config keys; bring-up from the repo is the goal and the rotation hazard fails loudly.
- **D-39 · Publish `grafana-vlogs`** — **Recommendation:** run the build workflow once, switch the `image:`, add the `update-images.sh` substitution, delete the for-shame entry.
- **D-45 · `targetDisk` placeholder** — **Recommendation:** fill in the by-id path after confirming the serial of the disk holding `disk-main-root`; the placeholder protects nothing and a wrong guess wipes Windows.

## 5. Defer — with a named trigger (9)

- **D-05 · Headscale ACL inert (no tags)** — **Recommendation:** add `--advertise-tags=tag:server` at the next planned re-image, or before any guest node joins, whichever is first.
- **D-15 · `trustedInterfaces = [ "tailscale0" ]`** — **Recommendation:** replace with per-port `interfaces.tailscale0` rules in the same change as D-05; it only matters once a non-owned peer exists.
- **D-32 · Paperless superuser-group variable** — **Recommendation:** keep the manual `/admin` grant; set the variable when a ≥3.1 bump is wanted for its own sake.
- **D-38 · Beszel OIDC provider PATCH** — **Recommendation:** leave the double login until it annoys; the role bug is already fixed.
- **D-42 · Stale MAC in `10-lan.link`** — **Recommendation:** keep both MACs; converge (and `qm set --net0` if needed) at the next maintenance window.
- **D-43 · `bootstrap-komodo`'s `sleep 5`** — **Recommendation:** `--wait` + `TimeoutStartSec`, landed together with a `gitops` run.
- **D-46 · nixfmt adoption** — **Recommendation:** leave non-fatal; if adopted, one standalone mechanical commit.
- **D-50 · `images-generated` drift lint** — **Recommendation:** add at the next full `update-images.sh` regeneration, bundled with D-51.
- **D-51 · Reshape `images.nix`** — **Recommendation:** same regeneration commit as D-50.

## 6. Needs your judgement (2)

- **D-11 · No patch cadence on the VPS** — **Recommendation (overrides):** a monthly `nfu` of `nixos/` + `headscale-vps/` then `./deploy --vps --vm`, written into `maintenance-handbook.md`; `system.autoUpgrade` against the committed lock applies no patches, and with `--update-input` the host runs a lock that is not in git (and the next `./deploy` rolls it back).

## 7. Drop / obsolete (2)

- **D-16 · VictoriaLogs loopback API unauthenticated** — **Recommendation:** close as done; the widened acceptance comment is applied (AS-9), and D-09's `IPAddressDeny` covers the runner better than an nftables `skuid` rule.
- **D-60 · `AA_MIRROR_URLS` unmanaged** — **Recommendation:** close as done; the branch added it to the manifest as `class: config`, which is correct since empty is a valid state (`pull` would nag).

---

## Accepted risks (9)

- **AS-16 · No off-host age-key escrow** — **Recommendation:** revisit — not "no action": do the offline escrow (operator) and correct `core-disaster-recovery.md` §1.1 that `secrets-recovery.sops.yaml` is not an escrow.
- **AS-17 · Syncthing 22000 reachable from the IoT VLAN** — **Recommendation:** keep accepted; apply the one-sentence addition to the `loopback-binding` exemption text.
- **AS-18 · Cloud-init age key persists in the guest** — **Recommendation:** revisit together with D-01; add the `qm set --delete cicustom` / snippet / guest-cache cleanup to `build_proxmox.sh`'s closing notes and run it once.
- **Forgejo OIDC client secret on argv** — **Recommendation:** keep accepted; upstream has no file/env path and the reader is already root-equivalent.
- **Syncthing GUI password on argv** — **Recommendation:** keep accepted; same reasoning, and the alternative re-implements `syncthing generate`.
- **`wheelNeedsPassword = false` + `trusted-users = [ "@wheel" ]`** — **Recommendation:** keep accepted; D-06's `extraRules` is the targeted narrowing for the one non-human key that needs sudo.
- **`rateLimitBurst = 0` with `SystemMaxUse=512M` on the VPS** — **Recommendation:** keep accepted; the log shipper moves ban evidence off the box.
- **Headscale blueprint re-asserts user passwords** — **Recommendation:** keep accepted; it is the recorded design for the user tiers.
- **DocSpace portal runs as `user: root`** — **Recommendation:** keep accepted; the upstream entrypoint needs root, and dropping it needs a real test.

---

## Cross-check

Decisions covered: D-01 … D-64, 64 of 64, each exactly once (12 + 21 + 9 + 9 + 9 + 2 + 2). Accepted risks
covered: 9 of 9. Unclassified: none.
