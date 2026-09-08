# Workflow

- Edit and commit in the working copy. Pushing is allowed, to any remote and any branch, in both repos. Never force-push.
- Pushing `main` to forgejo IS a deploy for `stacks/`: `stack-git-sync` pulls it onto the services VM within a minute. Push `main` only with lints green; host-level changes (`nixos/`, `headscale-vps/`) still need `./deploy` to go live.
- The git root of this repo is **Forgejo**. Push with `git push forgejo main`; GitHub is only a push mirror, and `stack-git-sync` never sees a push that lands only there.
