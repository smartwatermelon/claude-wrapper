# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Bash wrapper around the Claude Code CLI (`claude`) that intercepts invocations to inject git identity, GitHub tokens, 1Password secrets, SSH key isolation, and automatic remote-control session naming before delegating to the real `claude` binary. Installed by symlinking `bin/claude-wrapper` to `~/.local/bin/claude` so it shadows the real binary in `$PATH`.

## Commands

### Run tests

```bash
bash tests/test-wrapper.sh
bash tests/test-gh-token-permissions.sh
bash tests/test-remote-session.sh
```

There is no test runner script — run individual test files directly. No `npm test` or `make test`.

### Lint

```bash
shellcheck --external-sources lib/*.sh bin/claude-wrapper tests/*.sh
```

Use `--external-sources` because lib files source each other via variables (`${WRAPPER_LIB}/logging.sh`), and plain `shellcheck` emits false SC1091 warnings.

### Debug mode

```bash
CLAUDE_DEBUG=true claude
```

Enables verbose `DEBUG:` output to stderr from all modules.

## Architecture

### Execution flow (`bin/claude-wrapper`)

The wrapper is a single orchestrator that sources modules in dependency order, then `exec`s the real binary:

1. **Resolve own path** — `realpath` to handle symlinks
2. **Source libs** — `logging.sh` → `permissions.sh` → `path-security.sh` → `launch-dir-check.sh` → `git-identity.sh` → `credentials.sh` → `secrets-loader.sh` → `binary-discovery.sh` → `pre-launch.sh` → `proxy-health.sh` → `remote-session.sh`. Sourcing `credentials.sh` has the side effect of fetching `OP_SERVICE_ACCOUNT_TOKEN` from the macOS Keychain and `GH_TOKEN` from the 1Password Automation vault (see below).
3. **Check launch directory** — `check_launch_dir` warns (non-blocking) if CWD is exactly `$HOME` or `$HOME/Developer`, since neither is a git repo and both carry an unrelated accumulated MCP server surface in `~/.claude/.claude.json`
4. **Find real claude binary** — scans `$PATH` for `claude`, skipping itself (the wrapper)
5. **Validate binary** — ownership and permission checks on the discovered binary
6. **Initialize secrets loader** — `init_secrets_loader` discovers per-project secrets files and authenticates if needed
7. **Build remote-control args** — `build_remote_control_args` computes `--remote-control <session-name>` for interactive sessions (applied later, at exec)
8. **Inject 1Password secrets** — if secrets are available, `inject_secrets` runs `op inject` to resolve `op://Automation/...` references from per-project `.claude/secrets.op`; authentication uses `OP_SERVICE_ACCOUNT_TOKEN` (no TouchID prompt)
9. **Run pre-launch hook** — if secrets are available, `run_pre_launch_hook` runs `.claude/pre-launch.sh` from the git root if it exists and passes security validation
10. **Check proxy health** — `check_proxy_health` verifies the Headroom proxy when `ANTHROPIC_BASE_URL` points at localhost, unsetting it on failure so the session falls back to the direct Anthropic API
11. **`exec`** — replaces the wrapper process with the real binary, applying the remote-control args from step 7

### Module dependency chain

Every `lib/*.sh` file assumes `logging.sh` is already sourced. `permissions.sh` and `path-security.sh` are foundational — other modules call their functions.

- **`credentials.sh`** — fetches `OP_SERVICE_ACCOUNT_TOKEN` from the macOS Keychain (service `op-service-account-claude-automation`) and `GH_TOKEN` from `op://Automation/GitHub - CCCLI/Token` via that service account, retrying `op read` with exponential backoff. Runs automatically as a side effect of being sourced (not invoked as a discrete step later in the flow). Both values are scoped to the wrapper process lifetime — they are not present in the interactive shell environment. Falls back to a keyring/no-op if the Keychain lookup or `op read` fails, logging a warning rather than aborting. Must be sourced before `secrets-loader.sh`, which depends on `OP_SERVICE_ACCOUNT_TOKEN`.
- **`secrets-loader.sh`** — discovers secrets files at two levels (project `.claude/secrets.op`, local `.claude/secrets.local.op`), validates permissions/paths, runs `op inject` to resolve `op://Automation/...` references against the Automation vault via service account. Invoked explicitly as `init_secrets_loader` and `inject_secrets` (see execution flow above).
- **`launch-dir-check.sh`** — `check_launch_dir` warns to stderr (never blocks) when CWD is exactly `$HOME` or `$HOME/Developer` — not subdirectories, which are legitimate git repos — since per-project secrets/pre-launch hooks are skipped there and an unrelated MCP server surface from `~/.claude/.claude.json` loads instead; recommends `--add-dir` for multi-repo work
- **`binary-discovery.sh`** — finds the real `claude` binary in `$PATH` excluding the wrapper itself, validates it isn't world-writable
- **`remote-session.sh`** — derives a session name from the git repo basename, injects `--remote-control` for interactive sessions only
- **`pre-launch.sh`** — runs a per-project hook (`.claude/pre-launch.sh`) with symlink rejection and path-containment checks
- **`proxy-health.sh`** — verifies the Headroom proxy (when `ANTHROPIC_BASE_URL` points at localhost) before exec, unsetting the variable on failure so the session falls back to the direct Anthropic API

`GH_TOKEN` is fetched by `credentials.sh` at wrapper launch (`op://Automation/GitHub - CCCLI/Token`, via the service account token loaded from Keychain), scoped to the wrapper process only — it is not exported into the interactive shell environment. This supersedes the previous flat-file `github-token.sh` module, which no longer exists in this repo.

### Security model

All secret files (`.op` files) must be owner-only permissions (no group/world). Symlinks to secrets are rejected. Paths are canonicalized before use. The binary itself is validated for ownership and permissions before exec.

### Config file locations

| File | Purpose |
| ------ | ------- |
| `.claude/secrets.op` | Per-project 1Password secrets (committed); references `op://Automation/...` |
| `.claude/secrets.local.op` | Per-project local overrides (gitignored) |

`GH_TOKEN` is fetched by the wrapper itself, via `lib/credentials.sh`, from `op://Automation/GitHub - CCCLI/Token` — not from a flat file, and not sourced by shell startup.

## Headroom Learned Patterns

*Auto-generated by `headroom learn` on 2026-04-07 — prefer running `headroom learn` to refresh this section, but manual edits are fine when accuracy requires it*

### File Paths & Sizes

*~800 tokens/session saved*

- Key lib files: `lib/secrets-loader.sh`, `lib/pre-launch.sh`, `lib/remote-session.sh`
- Per-project secrets: `.claude/secrets.op` (committed), `.claude/secrets.local.op` (gitignored)
- Use the plural `clients/` directory name for client repos, not singular `client/` — the singular form causes file_not_found errors
- `tests/test-wrapper.sh` exceeds the 10,000-token read limit (~10,746 tokens); always use `offset` and `limit` params or `grep` to read specific portions
- `lib/secrets-loader.sh` is large (~13,000-15,000 tokens); read with offset/limit when possible

### PR & Merge Workflow

*~600 tokens/session saved*

- `gh pr create` must be run with `cd /path/to/repo &&` prefix (not `gh pr create --repo` + `-C` flag) to avoid 'head branch same as base' errors when the wrong repo context is inferred
- Merge authorization is **human-only**: Claude must never run `merge-lock.sh authorize`; ask the user to run it in their terminal. After authorization, wait for user to say 'approved' before attempting merge.
- Use `gh pr merge <N> --squash --delete-branch` (run from repo dir, not with `--repo` flag when merge-lock is active); if pre-merge hook blocks, the user must authorize via `merge-lock auth <N> "reason"` then Claude retries

### Secrets & Token Config

*~500 tokens/session saved*

- `GH_TOKEN` is fetched by the wrapper itself, via `lib/credentials.sh`, from `op://Automation/GitHub - CCCLI/Token`; no flat token files exist
- Per-project secrets live in `.claude/secrets.op` (committed) referencing `op://Automation/...`; resolved by `secrets-loader.sh` via `OP_SERVICE_ACCOUNT_TOKEN` (no TouchID)
- The global `~/.config/claude-code/secrets.op` no longer exists
- `opp <args>` runs `op` as your personal account (unsets service account token for that subprocess); needed for Personal vault access (e.g. prep-airdrop.sh)

### Pre-commit Hooks

*~500 tokens/session saved*

- A global pre-commit hook runs at `~/.config/pre-commit/config.yaml` on every commit; shell scripts must be executable (`chmod +x`) and pass `shellcheck`; markdown files must pass `markdownlint`
- Markdownlint uses global config at `~/.markdownlint.json` (no project-level config in this repo). Validate before committing: `npx markdownlint-cli --config ~/.markdownlint.json <files>`
- Common error: MD060 `table-column-style` — table pipe must have space to the left for compact style
- If pre-commit fails, fix the issues and re-run `git commit` — do not bypass

### Test Commands

*~400 tokens/session saved*

- Run tests with `bash tests/test-wrapper.sh` (not `bash tests/run-tests.sh` — that file does not exist)
- Specialized test scripts exist: `tests/test-gh-token-permissions.sh`, `tests/test-remote-session.sh`
- No `.bats` test files exist in this repo

### ShellCheck

*~400 tokens/session saved*

- Run `shellcheck --external-sources <file>` (not plain `shellcheck`) for files that source other scripts via variables (e.g., `source "${WRAPPER_LIB}/logging.sh"`). Plain shellcheck produces SC1091 errors that are not real failures.
- `shellcheck` on `bin/claude-wrapper` produces SC1091 errors for sourced lib files; suppress with `--exclude=SC1091` or use `shellcheck --external-sources lib/file.sh` instead
- Always run `shellcheck` before committing shell script changes

### Git Workflow

*~400 tokens/session saved*

- Branch naming convention: `claude/<description>-$(date +%s | tail -c5)` or `claude/<description>`
- Always use `git -C <repo-path> <cmd>` rather than `cd && git`
- After squash-merge, deleted remote branches still require `git branch -D` (not `-d`) locally because squash commits don't share history

### CI / Post-Push Loop

*~300 tokens/session saved*

- Use `bash ~/.claude/scripts/post-push-status.sh <PR_NUM>` to poll CI status; script returns `FINDING source=...` lines
- `gh pr checks <N> --watch` is an alternative for simpler pass/fail monitoring
- CI checks include: CodeQL, claude-review, Seer Code Review (Seer may be unreliable/removed)
