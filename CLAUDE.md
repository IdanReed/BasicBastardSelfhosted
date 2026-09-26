# Workflow

- Edit and commit in the working copy. Pushing is allowed, to any remote and any branch, in both repos. Never force-push.
- Pushing `main` to forgejo IS a deploy for `stacks/`: `stack-git-sync` pulls it onto the services VM within a minute. Push `main` only with lints green; host-level changes (`nixos/`, `headscale-vps/`) still need `./deploy` to go live.
