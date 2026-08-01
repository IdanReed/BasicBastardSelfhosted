# Claude Code multi-agent MR/PR review workflows

Research notes (Aug 2026) for the ideal loop:

> Multiple Claude Code sessions in parallel git worktrees → each opens a PR/MR →
> I review from the terminal (neovim or Zed) → hand-edit the branch directly →
> send notes back to the originating session.

Constraint: some projects live on **GitHub**, some on **GitLab**, so every piece
is graded on both forges.

---

## TL;DR recommendations

- **Orchestration**: use Claude Code's now-first-party primitives (`claude --worktree`,
  `claude --bg`, `claude agents` dashboard). Third-party orchestrators (claude-squad,
  uzi, vibe-kanban, Crystal) are either redundant or dying.
- **Review in neovim**: `octo.nvim` with `use_local_fs = true` for GitHub,
  `gitlab.nvim` for GitLab. Both follow the same model: MR branch checked out
  locally → diff shows *real editable files with LSP* → forge comment threads
  overlaid. Shared muscle memory for the diff/edit half via `diffview.nvim`.
- **Zed**: best-in-class for the *agent* half (parallel agent threads, each pinned to
  its own worktree, per-hunk accept/reject), but has **zero forge review** support
  (no PR/MR comments, no submitting reviews, extensions can't add it). Usable as an
  orchestration cockpit, not as an MR viewer.
- **Feedback loop**: on GitHub `claude --from-pr <n>` reopens the exact session that
  made the PR. On GitLab there's no auto-linking — resume by session and pipe
  `glab mr view -c` output in. Both forges have an official @claude comment bot for
  the async variant.

---

## Building blocks

### 1. Claude Code first-party (most of the loop is now built in)

| Primitive | What it does | Forge |
|---|---|---|
| `claude --worktree <name>` / `-w` | Session in `.claude/worktrees/<name>` on its own branch; resume returns to the worktree; `.worktreeinclude` copies `.env`-style files | any |
| `claude --worktree "#1234"` | Worktree created **from a PR** (fetches `pull/N/head`) — instant hand-edit checkout | GitHub only |
| `claude --bg "<prompt>"` | Dispatch background session, auto-worktree | any |
| `claude agents` | TUI dashboard of all sessions (needs-input/working/done, linked PR numbers); `Space` = peek + reply without attaching | PR links GitHub |
| PR↔session auto-link | Session that runs `gh pr create` is linked; `claude --from-pr <n>` (or PR URL in `/resume` picker) reopens it | GitHub only |
| `claude -p --resume <id> "msg"` | Scripted follow-up into an existing session; re-enters its worktree | any |
| Agent teams (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) | Lead + teammates, shared tasks, tmux split panes | any |

Docs: [worktrees](https://code.claude.com/docs/en/worktrees) ·
[agent view](https://code.claude.com/docs/en/agent-view) ·
[sessions](https://code.claude.com/docs/en/sessions) ·
[common workflows](https://code.claude.com/docs/en/common-workflows)

GitLab gap: no `--from-pr`/auto-link equivalent for MRs
([open request](https://github.com/anthropics/claude-code/issues/26932)).
Manual equivalent: `glab mr checkout <n>` (or `git fetch origin merge-requests/<n>/head`)
inside a worktree, and track session↔MR mapping yourself (a note in the MR
description with the session id works). `glab mcp serve` exposes all glab commands
to Claude Code as MCP tools
([MR !2361](https://gitlab.com/gitlab-org/cli/-/merge_requests/2361)).

### 2. Neovim review layer

Rubric: (a) inline forge comments in diff · (b) submit reviews/approve ·
(c) edit real checked-out files mid-review · (d) worktree-friendly.

| Tool | Forge | a | b | c | d | Status (Aug 2026) |
|---|---|---|---|---|---|---|
| [octo.nvim](https://github.com/pwntester/octo.nvim) | GitHub | ✅ | ✅ full lifecycle | ✅ with `use_local_fs = true` + PR branch checked out | works, undocumented | de-facto standard, very active |
| [gitlab.nvim](https://github.com/harrisoncramer/gitlab.nvim) | GitLab | ✅ | ✅ approve/revoke/merge/pipelines | ✅ (checks out MR branch, diffview-based) | expected OK | active; heavyweight install (Go binary) |
| [diffview.nvim](https://github.com/sindrets/diffview.nvim) | any (git-only) | ❌ | ❌ | ✅ | ✅ | active; the shared diff/edit layer |
| [gh-review.nvim](https://github.com/gh-tui-tools/gh-review.nvim) | GitHub | ✅ | ✅ | ✅ (editable head buffer, push from review) | untested | young (24★) but purpose-built for exactly this |
| [gh.nvim](https://github.com/ldelossa/gh.nvim) | GitHub | ✅ | ✅ | ✅ by design | ❌ (switches your checkout) | single-maintainer, slow; skip |
| [codereview.nvim](https://github.com/afewyards/codereview.nvim) | **both** (auto-detects remote) | ✅ | ✅ | unverified | unverified | only forge-agnostic option; young (84★) |
| [gh-dash](https://github.com/dlvhdr/gh-dash) | GitHub | ❌ | approve only | ❌ | ✅ | triage dashboard, not a review surface |
| gh / glab CLI | each | ❌ | MR-level only | ✅ via checkout | ✅ | plumbing baseline |

### 3. Sending notes to a session from neovim

- [claudecode.nvim](https://github.com/coder/claudecode.nvim) (coder, 3k★, active) —
  speaks the official IDE WebSocket/MCP protocol. `:ClaudeCodeSend` sends a visual
  selection; `:ClaudeCodeAdd <file> [range]`; native accept/reject diffs. Key config:
  `provider = "none"` connects to a Claude CLI running **in a separate tmux pane**,
  so the agent session lives outside nvim but receives your selections/notes.
- [sidekick.nvim](https://github.com/folke/sidekick.nvim) (folke, active) — prompt
  templates with `{file}` `{selection}` `{diagnostics}`; tmux/zellij backends so the
  CLI session survives nvim restarts.
- No plugin: `claude -p --resume <id> "…"` or the `claude agents` peek-reply.

### 4. Zed (evaluated as alternative editor/MR viewer)

- **Agent half — excellent**: Parallel Agents (Apr 2026) = multiple agent threads in
  one window, each thread optionally pinned to **its own linked git worktree** with a
  title-bar worktree picker; Claude Code runs via ACP; "Review Changes" multibuffer
  with per-hunk keep/reject; Terminal Threads for stock CLI sessions per worktree.
  [parallel agents](https://zed.dev/docs/ai/parallel-agents) ·
  [claude via ACP](https://zed.dev/blog/claude-code-via-acp)
- **Forge half — nothing**: no PR/MR comment display, no review submission, on either
  forge. Extension API cannot host it (no UI panels;
  [Visual Extension API RFC](https://github.com/zed-industries/zed/discussions/53403)
  unimplemented). Native PR review is the community's top request
  ([#34759](https://github.com/zed-industries/zed/discussions/34759), ~479 reactions,
  no roadmap commitment). Hunk-anchored "comment on agent diff → feeds thread" is
  also just a request ([#59157](https://github.com/zed-industries/zed/issues/59157)).
- ACP caveats: no plan mode, `/compact` broken, context capped ~200k
  ([#51648](https://github.com/zed-industries/zed/issues/51648)).

### 5. Forge-side async bots (both forges ✅)

- GitHub: [claude-code-action](https://github.com/anthropics/claude-code-action) —
  @claude in PR/review comments → runner implements changes, pushes to the PR branch.
- GitLab: [official CI/CD integration](https://code.claude.com/docs/en/gitlab-ci-cd) —
  @claude in MR comments via webhook + pipeline; iterates on follow-ups. Community
  alternative: [claude-code-for-gitlab](https://github.com/RealMikeChong/claude-code-for-gitlab).
- Caveat: these spawn a *fresh* context server-side, not your local session — good
  for async "fix the nits while I'm away", not a replacement for the local loop.

### 6. Third-party orchestrators (mostly superseded)

- [claude-squad](https://github.com/smtg-ai/claude-squad) (8k★, active) — tmux+worktree
  per agent; fine, but `claude agents` now covers most of it first-party.
- [uzi](https://github.com/devflowinc/uzi) — `uzi broadcast` (message *all* agents) is
  its unique trick.
- vibe-kanban — was the only tool closing the full loop (inline diff comments → agent
  revises) but is **sunsetting**. Crystal → deprecated (became Nimbalyst, GUI).
  Conductor — Mac-only GUI. [gwq](https://github.com/d-kuro/gwq) — nice low-level
  worktree/tmux manager if wanted.

---

## Candidate setups

### Setup A — terminal-native, neovim (recommended)

The maximal version of the current direction; everything maintained, mostly first-party.

1. **Dispatch**: `claude --bg "task…"` per task (auto-worktree), or `claude -w <name>`
   in tmux panes. Monitor with `claude agents`; quick nudges via peek-reply.
2. **Agent opens PR/MR**: sessions end with `gh pr create` (auto-links session↔PR) /
   `glab mr create`.
3. **Review in nvim**:
   - GitHub: `:Octo review start` (with `use_local_fs = true` and the PR branch
     checked out in the worktree) — inline threads, suggestions, approve/request-changes.
   - GitLab: `gitlab.nvim` — same model, diffview-backed reviewer pane.
   - Both: `:DiffviewOpen origin/main...HEAD` as the forge-free diff/edit view.
4. **Hand-edit**: files in the review are the real worktree files — edit with full
   LSP, commit, push to the PR/MR branch directly.
5. **Send notes back**:
   - GitHub: `claude --from-pr 1234` → "address my review comments (`gh pr view -c`)".
   - GitLab: `claude -p --resume <id> "address review: $(glab mr view <n> -c)"`.
   - From inside nvim: claudecode.nvim `:ClaudeCodeSend` on a visual selection to the
     session's tmux pane.
6. **Async fallback**: leave @claude comments on the forge; the CI bot handles nits
   without you at the keyboard.

Cost: two forge plugins with different keymaps (octo vs gitlab.nvim). The diff/edit
half (diffview) and everything else is identical across forges.

### Setup B — Zed cockpit + terminal review (hybrid)

Zed window per repo; one agent thread per task, each on its own linked worktree;
review *agent* diffs with Zed's per-hunk keep/reject; follow-ups typed into the
thread. When a PR/MR is up, drop to terminal nvim (Setup A step 3) or the browser
for forge review, since Zed can't do it.

Worth it if the Zed agent UX outweighs living in two editors. Watch
[#34759](https://github.com/zed-industries/zed/discussions/34759) /
[#59157](https://github.com/zed-industries/zed/issues/59157) — if Zed ships forge
review + diff-anchored agent comments, this becomes the strongest setup.

### Setup C — forge-driven async loop

All feedback happens as PR/MR comments; @claude CI bots on both forges do the
revisions. You review from anything (nvim, browser, phone). Simplest to run on both
forges uniformly, but: fresh context per run (loses local session state), CI minutes,
and round-trip latency. Best as a complement to A, not a replacement.

### Setup D — one plugin for both forges (experimental)

[codereview.nvim](https://github.com/afewyards/codereview.nvim) alone: auto-detects
GitHub/GitLab from the remote, one set of keymaps, inline threads, approve/submit,
CI view, even built-in Claude-powered review. Young project, small bus factor, and
the edit-real-files-mid-review story is unverified. Try it in one repo; keep Setup A
as the fallback.

---

## Feedback-loop cheat sheet

| Action | GitHub | GitLab |
|---|---|---|
| Check out PR/MR into worktree | `claude --worktree "#123"` or `gh pr checkout` in a worktree | `glab mr checkout 123` in a worktree |
| Reopen owning session | `claude --from-pr 123` | manual: `claude --resume <id>` (track mapping yourself) |
| Pipe review comments to session | `gh pr view 123 --comments` | `glab mr view 123 --comments` |
| Line-level comment from CLI | `gh api …/pulls/N/comments` | [glab-discussion](https://github.com/fprochazka/glab-discussion) |
| Async @claude bot | claude-code-action | official GitLab CI/CD integration |

## Parity: NixOS (home) vs Windows (work)

Goal: same muscle memory on both machines. The differences that matter, ranked by
how much drift they cause, and how to minimize each.

### Strategy 1 — WSL2 + Nix (max parity, recommended)

Run the entire terminal stack inside WSL2 and manage it with the same tooling as
home:

- **NixOS-WSL** (or plain WSL Ubuntu + standalone Nix) + **home-manager**, reusing
  the same `home.nix` modules from this repo. The nvim config, tmux config, claude
  settings, gh/glab, aliases — literally the same files, applied with the same `hms`
  flow. Factor the home-manager config into `modules/home/*` that don't assume NixOS
  (already mostly true here) and import them from a WSL host config.
- Claude Code, worktrees, tmux, octo/gitlab.nvim, diffview: all identical inside WSL.
- The only Windows-native pieces left are the terminal emulator (Windows Terminal or
  WezTerm as a front-end — keybinds configurable to match) and the browser.
- Caveats: repos should live on the WSL filesystem (NTFS-mounted repos are slow and
  break file-watchers); corporate VPN/proxy and credential helpers (`gh auth`,
  `glab auth`) need per-machine setup once.

Result: Setups A–D behave identically on both machines; parity is ~95%.

### Strategy 2 — native Windows (if WSL is blocked at work)

Everything in the loop *runs* natively, but with drift:

- Claude Code supports native Windows (PowerShell/Git Bash); `--worktree`, `--bg`,
  `claude agents` all work. Neovim + the plugin stack works natively too.
- **No tmux.** The pane/mux layer becomes Windows Terminal panes or WezTerm's
  built-in multiplexing — different keybinds, and claudecode.nvim's
  "CLI in a neighboring tmux pane" trick needs the WezTerm equivalent (or run the
  CLI via sidekick.nvim inside nvim instead, which is cross-platform).
- Config sharing without home-manager: keep nvim/claude/gh configs in a dotfiles
  repo consumed by both home-manager (home) and a symlink script or chezmoi (work).
  More moving parts, more drift.

### Parity notes per setup

- **Setup A** (nvim terminal loop): full parity under Strategy 1; under Strategy 2
  the tmux layer is the main divergence — consider standardizing on **WezTerm on
  both machines** (it runs on NixOS and Windows with one Lua config, and its mux
  replaces tmux) if native Windows is forced.
- **Setup B** (Zed cockpit): Zed ships on Windows now, and settings are one JSON —
  low-drift across OSes. Agent threads + worktrees behave the same.
- **Setup C** (forge bots): zero parity cost — it's all server-side; identical from
  any machine including the work laptop's browser.
- Keep forge asymmetry (GitHub vs GitLab) orthogonal to OS asymmetry: the per-forge
  choices (octo vs gitlab.nvim, `--from-pr` vs manual resume) are the same on both
  machines, so the matrix stays 2×2 instead of exploding.

## Watch list

- Zed native PR review ([#34759](https://github.com/zed-industries/zed/discussions/34759))
  and diff-anchored agent feedback ([#59157](https://github.com/zed-industries/zed/issues/59157))
- Claude Code GitLab MR support for `--from-pr`/code-review
  ([anthropics/claude-code#26932](https://github.com/anthropics/claude-code/issues/26932))
- [gh-review.nvim](https://github.com/gh-tui-tools/gh-review.nvim) maturing (its
  editable-checkout review model is exactly the target UX)
- octo.nvim `use_local_fs` hardening
