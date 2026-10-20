# Claude Wrapper

Custom wrapper for Claude Code CLI with identity management and 1Password secrets integration.

## Features

- **Auto Remote Control**: Every interactive session is automatically named and accessible from claude.ai/code and the Claude mobile app
- **Git Identity Management**: Separate git identity for Claude Code operations
- **SSH Key Isolation**: Dedicated SSH key for Claude git operations
- **GitHub Token Management**: Separate GitHub CLI token
- **1Password Integration**: Secure secrets management with minimal TouchID prompts
- **Multi-Level Secrets**: Global, project, and local secrets support
- **Debug Mode**: Comprehensive logging for troubleshooting
- **Graceful Degradation**: Works with or without 1Password
- **Modular Architecture**: Clean separation of concerns for maintainability

## Quick Start

### Installation

1. Clone this repository:

   ```bash
   git clone https://github.com/smartwatermelon/claude-wrapper.git ~/.claude-wrapper
   ```

2. Symlink the wrapper to your local bin:

   ```bash
   mkdir -p ~/.local/bin
   ln -sf ~/.claude-wrapper/bin/claude-wrapper ~/.local/bin/claude
   ```

3. Ensure `~/.local/bin` is in your PATH:

   ```bash
   echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc  # or ~/.zshrc
   ```

4. Verify installation:

   ```bash
   which claude  # Should show ~/.local/bin/claude
   claude --version
   ```

### Configuration

#### Git Identity (Required)

The wrapper automatically sets up a dedicated git identity for Claude Code:

- Name: `Claude Code Bot`
- Email: `claude-code@smartwatermelon.github`

#### SSH Key (Optional)

Create a dedicated SSH key for Claude git operations:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_claude_code -C "claude-code@smartwatermelon.github"

# Add to GitHub
cat ~/.ssh/id_ed25519_claude_code.pub
# Copy and add to https://github.com/settings/keys
```

#### GitHub Token

The wrapper fetches `GH_TOKEN` itself at launch, via `lib/credentials.sh`. It
reads `OP_SERVICE_ACCOUNT_TOKEN` from the macOS Keychain, then resolves a token
from the 1Password Automation vault. No shell-startup setup is required — if
`GH_TOKEN` is already set in your environment, the wrapper leaves it alone and
skips the vault lookup. The exception is a token a parent wrapper fetched. The
wrapper lists the vars it filled in `CLAUDE_WRAPPER_VAULT_VARS`, and a nested
launch fetches those again for its own launch directory rather than inheriting
them.

Which token it resolves depends on the GitHub owner of the launch directory's
`origin` remote, because a fine-grained PAT is bound to a single resource owner
and cannot cover a personal account and two orgs at once:

| Owner | Vault item |
| ------ | ------- |
| `smartwatermelon` | `op://Automation/CCCLI-SWM/token` |
| `nightowlstudiollc` | `op://Automation/CCCLI-NOS/token` |
| anything else, or not derivable | `op://Automation/GitHub - CCCLI/Token` |

Only one item is read per launch. A directory that is not a git repo, has no
`origin`, or has a non-GitHub remote falls back to the personal token. Run with
`CLAUDE_DEBUG=true` to see which owner and vault item were selected.

The wrapper does not load flat token files.

#### 1Password Secrets (Optional)

See [SECRETS.md](docs/SECRETS.md) for comprehensive 1Password setup guide.

**Quick setup:**

```bash
# 1. Install 1Password CLI
brew install --cask 1password-cli

# 2. Enable app integration in 1Password settings

# 3. Create secrets file
mkdir -p ~/.config/claude-code
cat > ~/.config/claude-code/secrets.op <<EOF
ANTHROPIC_API_KEY=op://Personal/Claude-API/credential
GITHUB_TOKEN=op://Personal/GitHub/token
EOF
```

## Usage

Use `claude` command as normal:

```bash
# Normal usage — automatically starts a named remote session
claude

# With debug output
CLAUDE_DEBUG=true claude

# Pass arguments
claude -c "your command here"
claude --version

# Opt out of remote control for one session
CLAUDE_NO_REMOTE_CONTROL=true claude

# Already has --remote-control? Wrapper skips injection
claude --remote-control "Custom Name"
```

The wrapper:

1. Sets git identity
2. Authenticates with 1Password (once per session)
3. Loads secrets from multi-level files
4. Injects `--remote-control <session-name>` for interactive sessions
5. Passes through to real Claude CLI

### Remote Control

Every interactive `claude` invocation automatically registers a remote session named after the current git repository (or directory when outside a git repo). This lets you pick up any session from [claude.ai/code](https://claude.ai/code) or the Claude mobile app.

```
~/Developer/my-app $ claude
# → equivalent to: claude --remote-control "my-app"
```

Session naming priority (per Claude docs):

1. Name injected by the wrapper (repo or directory name)
2. `/rename` inside the session
3. Last meaningful message in conversation history
4. Your first prompt

**Opt-out options:**

| Method | Scope |
| ------ | ----- |
| `CLAUDE_NO_REMOTE_CONTROL=true claude` | Single session |
| `export CLAUDE_NO_REMOTE_CONTROL=true` | Shell session |
| `/config` → "Enable Remote Control for all sessions" → `false` | Persisted in Claude config |

Remote control is skipped automatically for non-interactive invocations: `--print`/`-p`, `--version`, `--help`, subcommands (`remote-control`, `mcp`, etc.), and script automation (`--no-session-persistence`).

> **Requirements**: Claude Code v2.1.51+, claude.ai authentication (not API key), Pro/Max/Team/Enterprise plan.

### Per-Machine Settings

`~/.claude/settings.json` is shared across machines, and Claude Code has no user-level `settings.local.json`. For a setting only some machines need (a plugin, for example), put it in `~/.config/claude-code/machine-settings.json` on those machines. The wrapper passes that file with `--settings`, and Claude Code merges it over the shared settings: `enabledPlugins` merges key by key, so the shared plugins stay enabled.

```json
{ "enabledPlugins": { "cloudflare@cloudflare": true } }
```

A plugin from a marketplace not listed in the shared file also needs that marketplace on the machine once: `claude plugin marketplace add cloudflare/skills`. That is recorded in the machine's own plugin state, not in `settings.json`.

How Claude Code merges a `--settings` file over `~/.claude/settings.json`, measured with Claude Code 2.1.305 on 2026-10-20:

- **Objects merge by key.** An `env` var set in `settings.json` survived an `env` block in the `--settings` file, and `enabledPlugins` merges plugin by plugin. (`extraKnownMarketplaces` is an object too, but was not measured on its own.)
- **Arrays concatenate.** The same 25-entry `autoMode.environment` in both files gave 50 entries. Put an array in one file only, or its entries double.
- **`--settings` does not stack.** With two `--settings` flags, only the last applies. This is why the wrapper adds none when one is already on the command line.
- **`autoMode` is honored from `--settings`.** The auto mode classifier reads `autoMode` only from `~/.claude/settings.json`, managed settings, and `--settings`, so the machine file is a valid place for it.

- Interactive sessions only, the same rule as remote control. `-p`, subcommands and scripts see the shared settings alone.
- Skipped if `--settings` is already on the command line.
- Skipped with a warning, never blocking the launch, if the file is not owned by you, is writable by group or others, or is not a JSON object.
- `CLAUDE_MACHINE_SETTINGS=/path/to/file` uses another file.

### claude-wrapper-lite

`bin/claude-wrapper-lite` is a second entry point for a machine that should get the per-machine settings and nothing else from this repo. It uses the same `lib/machine-settings.sh`, so the rules above apply unchanged.

What it does:

- Finds the real `claude` on `PATH` (or a known install location), skipping itself, and validates its owner and permissions, the same way the full wrapper does.
- Adds `--settings ~/.config/claude-code/machine-settings.json` under the rules above.
- Execs `claude` through `/usr/bin/caffeinate -is`, so the system does not idle-sleep during a session.

What it does not do: load 1Password or Keychain secrets, set `GH_TOKEN`, set a git identity or SSH key, add `--remote-control`, warn about the launch directory, or run a project's `.claude/pre-launch.sh`.

Install it under its own name, not as `claude`:

```bash
ln -s /path/to/claude-wrapper/bin/claude-wrapper-lite ~/.local/bin/claude-wrapper-lite
```

It execs the first `claude` it finds that is not itself. Use it on a machine where the full wrapper is not installed as `claude`; where it is, lite finds the full wrapper and runs that.

## Documentation

- **[SECRETS.md](docs/SECRETS.md)**: Comprehensive 1Password integration guide
  - Setup and configuration
  - Secret reference syntax
  - Multi-level secrets
  - Team workflows
  - Troubleshooting

- **[SECURITY.md](docs/SECURITY.md)**: Security hardening documentation
  - Permission validation
  - Path security
  - Binary validation

- **[tests/README.md](tests/README.md)**: Test suite documentation
  - Running tests
  - Manual testing scenarios
  - Adding new tests

## Development

### Running Tests

```bash
# Run all automated tests
./tests/test-wrapper.sh
./tests/test-remote-session.sh
./tests/test-machine-settings.sh
./tests/test-claude-wrapper-lite.sh

# Run with verbose output
VERBOSE=true ./tests/test-wrapper.sh
```

### Project Structure

```
claude-wrapper/
├── bin/
│   ├── claude-wrapper          # Main entry point (orchestrates modules)
│   └── claude-wrapper-lite     # Machine settings only (no secrets or identity)
├── lib/
│   ├── logging.sh              # Debug/error/warning logging
│   ├── permissions.sh          # File permission validation
│   ├── path-security.sh        # Path canonicalization and traversal protection
│   ├── git-identity.sh         # Git author/committer identity
│   ├── secrets-loader.sh       # 1Password integration
│   ├── binary-discovery.sh     # Claude binary search/validation
│   ├── pre-launch.sh           # Project-specific pre-launch hooks
│   ├── remote-session.sh       # Automatic remote control session naming
│   └── machine-settings.sh     # Per-machine --settings layered on shared settings
├── docs/
│   ├── SECRETS.md              # 1Password documentation
│   └── SECURITY.md             # Security hardening documentation
├── tests/
│   ├── test-wrapper.sh         # Test suite
│   ├── test-remote-session.sh  # Remote session module tests
│   ├── test-machine-settings.sh # Machine settings module tests
│   ├── test-claude-wrapper-lite.sh # Lite entry point tests
│   └── README.md               # Test documentation
├── .claude/                    # Project-specific Claude config
├── .gitignore
└── README.md                   # This file
```

### Code Quality

This is security-critical infrastructure code. All changes require:

1. **ShellCheck compliance**: Zero warnings or errors
2. **Test coverage**: All new features must have tests
3. **Code review**: AI-assisted review before commit
4. **Security review**: Adversarial review for security changes

```bash
# Run ShellCheck on all modules
shellcheck bin/claude-wrapper lib/*.sh

# Run tests
./tests/test-wrapper.sh

# Run code review (requires Claude Code)
claude --agent code-reviewer bin/claude-wrapper lib/
```

## Security

### What Gets Access to Secrets?

- **Claude CLI process**: Yes
- **Git hooks**: Yes (subprocesses inherit environment)
- **Spawned agents**: Yes (subprocesses inherit environment)
- **Other terminal windows**: No
- **After Claude exits**: No (environment cleared)

### Secret Storage

- **1Password vault**: ✓ Encrypted, secure
- **secrets.op files**: ✓ Only references, not actual secrets
- **Process environment**: ✓ Temporary, cleared on exit
- **Shell history**: ✓ Not stored (not exported to shell)

### Best Practices

- Never commit `.claude/secrets.local.op`
- Use separate vaults for different security levels
- Review secrets file permissions: `chmod 600 ~/.config/claude-code/secrets.op`
- Use service accounts for CI/CD
- Enable TouchID for 1Password app

## Troubleshooting

### Remote control not connecting

```bash
# Verify Claude Code version (requires v2.1.51+)
claude --version

# Check you're using claude.ai auth (not API key)
# API keys do not support Remote Control

# Disable and re-enable for one session
CLAUDE_NO_REMOTE_CONTROL=true claude

# Debug injection
CLAUDE_DEBUG=true claude --version 2>&1 | grep -i remote
```

If you're on a Team or Enterprise plan, an admin must enable the Remote Control toggle in [Claude Code admin settings](https://claude.ai/admin-settings/claude-code).

### Wrapper not found

```bash
# Check symlink
ls -la ~/.local/bin/claude

# Verify PATH
echo $PATH | grep -o "\.local/bin"

# Recreate symlink
ln -sf ~/.claude-wrapper/bin/claude-wrapper ~/.local/bin/claude
```

### Git identity not applied

```bash
# Check git log shows bot identity
git log -1 --format='%an <%ae>'

# Should show: Claude Code Bot <claude-code@smartwatermelon.github>

# Debug wrapper
CLAUDE_DEBUG=true claude -c "git log -1"
```

### 1Password prompting too often

```bash
# Verify app integration
op account get

# Check 1Password app settings:
# - Settings → Security → Touch ID: ON
# - Settings → Developer → Integrate with CLI: ON
```

### Secrets not available

```bash
# Enable debug mode
CLAUDE_DEBUG=true claude -c "printenv | grep API_KEY"

# Verify secret reference
op read "op://Personal/Claude-API/credential"

# Check secrets files exist
ls -la ~/.config/claude-code/secrets.op
```

See [SECRETS.md](docs/SECRETS.md) for comprehensive troubleshooting.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests: `./tests/test-wrapper.sh`
5. Run ShellCheck: `shellcheck bin/claude-wrapper lib/*.sh`
6. Submit a pull request

## License

MIT License - see LICENSE file for details

## Related Projects

- [Claude Code](https://claude.ai/code) - Official Claude Code CLI
- [1Password CLI](https://developer.1password.com/docs/cli/) - 1Password command-line tool
- [GitHub CLI](https://cli.github.com/) - GitHub command-line tool

## Changelog

### v3.1.0 (2026-03-19)

- **Auto Remote Control**: Every interactive `claude` invocation now automatically registers a named remote session
  - Session named after the git repository root (or current directory outside a repo)
  - Skipped automatically for non-interactive uses (`--print`, `--version`, subcommands, `--no-session-persistence`)
  - Opt-out via `CLAUDE_NO_REMOTE_CONTROL=true`
- New module: `lib/remote-session.sh`
- New test suite: `tests/test-remote-session.sh` (22 tests)

### v3.0.0 (2026-02-01)

- Renamed from `claude-custom` to `claude-wrapper`
- Modularized architecture: split into 8 focused modules in `lib/`
- Each module is independently testable
- Improved test suite with TDD approach
- Full ShellCheck compliance across all modules

### v2.0.0 (2026-01-14)

- Added 1Password secrets integration
- Multi-level secrets support (global, project, local)
- Enhanced error handling
- Debug mode
- Comprehensive test suite
- Full documentation

### v1.0.0 (Initial)

- Git identity management
- SSH key isolation
- GitHub token support
- Binary discovery logic
