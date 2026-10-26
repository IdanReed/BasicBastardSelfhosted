---
name: app-setup
description: Drive a fleet app's web UI through the `browser` MCP (Playwright) to do a per-app setup step that has no env/API knob — OIDC toggles, first-run wizards, admin settings, minting a token. Use when a step in oidc-rollout.md, for-shame.md or decisions.md says "in the UI". Not for anything a compose env var, blueprint or API call can do — those belong in the repo.
---

# Per-app UI setup through the browser MCP

The `browser` MCP server (`playwright-mcp`, wired in `nixos-de/home.nix`) is a
**headed** Chromium on a persistent profile at
`~/.local/state/claude-browser/profile`. Everything below assumes the operator
can see that window.

## Before the first app

1. `browser_navigate` to `https://auth.idanreed.com` and take a snapshot.
2. If it shows a login form, **stop and ask the operator to log in as `idan`
   in the browser window** (password + TOTP). Never type Authentik
   credentials, never ask for them in chat, never log in as `akadmin`.
3. The session persists in the profile, so every `*.svc.idanreed.com` app's
   "Sign in with Authentik" completes without further prompts.

## Where the steps come from

The repo is the source of truth — do not improvise a setup step.

- `ServerNotes/designs/oidc-rollout.md` — per-app OIDC UI steps (Kavita
  `Provision Accounts`, Actual's OIDC flip, …)
- `BasicBastardSelfhosted/docs/for-shame.md` — every residual manual step
- `BasicBastardSelfhosted/docs/decisions.md` (review branch) — some items are
  decisions, not steps: a `D-nn` item needs the operator's answer first
- `ServerNotes/designs/_overview.md` — the app's URL (`<service>.svc.idanreed.com`)

If a step could be done declaratively (env var, blueprint, init container,
API call from a oneshot), say so and propose the repo change instead — a UI
click is the fallback, not the default.

## Per app

1. State the step you are about to perform and where it is documented.
2. Navigate, `browser_snapshot`, act. Prefer snapshot refs over coordinates.
3. Change **only** what the documented step names. Anything else you notice
   (a wrong default, a warning banner) goes in the report, not a click.
4. Verify: reload the page and snapshot again, or exercise the result (e.g.
   log out and back in through OIDC). Save a screenshot as evidence.
5. Destructive or irreversible actions (delete, reset, transfer ownership,
   "first OIDC login becomes owner") — stop and confirm with the operator.

## Secrets

- Never echo a secret into chat or a file in the workspace.
- A step that needs a secret *typed in*: ask the operator to type it in the
  browser window.
- A step that *mints* a secret (API token, PAT): stop before revealing it;
  the operator copies it straight into `sopsedit <file>`. The value lands in
  a sops file (a stack's `secrets.sops.json`, `secrets/shared.sops.json`, or a
  host's `secrets.sops.yaml`), never anywhere else.

## After each app

Record the outcome in the doc the step came from (tick it off, or move it
out of `for-shame.md` when it is gone for good) — as a rule, not a log entry.
Dates and incident notes go in `ServerNotes/designs/deploy-status.md` only.
