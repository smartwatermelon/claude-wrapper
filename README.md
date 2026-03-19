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

#### GitHub Token (Optional)

Create a GitHub fine-grained PAT for Claude CLI operations:

```bash
# Create token at: https://github.com/settings/personal-access-tokens/new
# Required permissions: Contents (R/W), Pull requests (R/W), Actions (R)

# Save token (single account)
mkdir -p ~/.config/claude-code
echo "your_github_token_here" > ~/.config/claude-code/gh-token
chmod 600 ~/.config/claude-code/gh-token
```

#### Multi-Org Token Routing (Optional)

Fine-grained PATs are scoped to a single owner (user or organization). To work
with repos across multiple owners, create one token per owner:

```bash
# Personal repos (resource owner: your username)
echo "github_pat_personal..." > ~/.config/claude-code/gh-token.smartwatermelon
chmod 600 ~/.config/claude-code/gh-token.smartwatermelon

# Organization repos (resource owner: the org)
echo "github_pat_org..." > ~/.config/claude-code/gh-token.nightowlstudiollc
chmod 600 ~/.config/claude-code/gh-token.nightowlstudiollc

# Keep a default fallback (or copy one of the above)
cp ~/.config/claude-code/gh-token.smartwatermelon ~/.config/claude-code/gh-token
```

The wrapper detects the target repo owner from `gh` CLI arguments (e.g.,
`--repo owner/repo`, API paths like `repos/owner/...`) or the git remote of
the current directory, then loads the matching `gh-token.<owner>` file. If no
owner-specific file exists, it falls back to `gh-token`.

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

# Run with verbose output
VERBOSE=true ./tests/test-wrapper.sh
```

### Project Structure

```
claude-wrapper/
├── bin/
│   └── claude-wrapper          # Main entry point (orchestrates modules)
├── lib/
│   ├── logging.sh              # Debug/error/warning logging
│   ├── permissions.sh          # File permission validation
│   ├── path-security.sh        # Path canonicalization and traversal protection
│   ├── git-identity.sh         # Git author/committer identity
│   ├── github-token.sh         # GitHub CLI token loading + multi-org routing setup
│   ├── gh-token-router.sh     # Per-invocation token selection (sourced by gh wrapper)
│   ├── secrets-loader.sh       # 1Password integration
│   ├── binary-discovery.sh     # Claude binary search/validation
│   ├── pre-launch.sh           # Project-specific pre-launch hooks
│   └── remote-session.sh       # Automatic remote control session naming
├── docs/
│   ├── SECRETS.md              # 1Password documentation
│   └── SECURITY.md             # Security hardening documentation
├── tests/
│   ├── test-wrapper.sh         # Test suite
│   ├── test-remote-session.sh  # Remote session module tests
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
