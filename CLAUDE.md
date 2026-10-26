# Workflow

- Edit and commit in the working copy. Pushing is allowed, to any remote and any branch, in both repos. Never force-push.
- Pushing `main` to forgejo IS a deploy for `stacks/`: Forgejo's push webhook runs Komodo's `apply` procedure, which deploys every stack whose files changed. Push `main` only with lints green. Host-level changes (`nixos/`, `headscale-vps/`, `komodo/`, `forgejo/`) and every secret go live with `nixos-rebuild switch` (`nrs-vm`, `nrs-vps`) — switch BEFORE pushing a secret change, or the stack redeploys with its old env.
- The git root of this repo is **Forgejo**. Push with `git push forgejo main`; GitHub is only a push mirror, and Komodo never sees a push that lands only there.
