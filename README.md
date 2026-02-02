# Claude Wrapper

Custom wrapper for Claude Code CLI with identity management and 1Password secrets integration.

## Features

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

Create a GitHub token for Claude CLI operations:

```bash
# Create token at: https://github.com/settings/tokens
# Required scopes: repo, workflow

# Save token
mkdir -p ~/.config/claude-code
echo "your_github_token_here" > ~/.config/claude-code/gh-token
chmod 600 ~/.config/claude-code/gh-token
```

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
# Normal usage
claude

# With debug output
CLAUDE_DEBUG=true claude

# Pass arguments
claude -c "your command here"
claude --version
```

The wrapper:

1. Sets git identity
2. Authenticates with 1Password (once per session)
3. Loads secrets from multi-level files
4. Passes through to real Claude CLI

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
│   ├── github-token.sh         # GitHub CLI token loading
│   ├── secrets-loader.sh       # 1Password integration
│   ├── binary-discovery.sh     # Claude binary search/validation
│   └── pre-launch.sh           # Project-specific pre-launch hooks
├── docs/
│   ├── SECRETS.md              # 1Password documentation
│   └── SECURITY.md             # Security hardening documentation
├── tests/
│   ├── test-wrapper.sh         # Test suite
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
