# 1Password Secrets Integration

## Overview

The Claude Code wrapper provides seamless integration with 1Password CLI, allowing Claude to access API keys, tokens, and other secrets stored securely in your 1Password vault. This eliminates the need to store plaintext credentials in configuration files or environment variables.

## Features

- **Minimal TouchID prompts**: Authenticate once per session, session persists across multiple wrapper invocations
- **Multi-level secrets**: Global, project-specific, and local overrides
- **Graceful degradation**: Wrapper works with or without 1Password
- **Subprocess inheritance**: Git hooks, agents, and scripts automatically receive secrets
- **Secret masking**: 1Password CLI automatically conceals secrets in stdout/stderr
- **Debug mode**: Comprehensive logging for troubleshooting

## Quick Start

### 1. Install 1Password CLI

```bash
brew install --cask 1password-cli
```

### 2. Enable App Integration

1. Open 1Password app
2. Go to Settings → Security → Enable Touch ID
3. Go to Settings → Developer → Enable "Integrate with 1Password CLI"

### 3. Create Global Secrets File

```bash
mkdir -p ~/.config/claude-code
touch ~/.config/claude-code/secrets.op
```

### 4. Add Secret References

Edit `~/.config/claude-code/secrets.op`:

```bash
# 1Password secret reference format: op://vault/item/field
ANTHROPIC_API_KEY=op://Personal/Claude-API/credential
GITHUB_TOKEN=op://Personal/GitHub-Claude-Bot/token
OPENAI_API_KEY=op://Personal/OpenAI/api-key
```

### 5. Verify Setup

```bash
# Enable debug mode to see what's loaded
CLAUDE_DEBUG=true claude --version

# You should see:
# DEBUG: 1Password CLI detected (version: X.X.X)
# DEBUG: Added global secrets: /Users/you/.config/claude-code/secrets.op
# DEBUG: 1Password enabled with 1 secrets file(s)
```

## Secrets File Format

### Basic Reference Syntax

```bash
VARIABLE_NAME=op://vault-name/item-name/field-name
```

**Examples:**

```bash
# Simple credential
API_KEY=op://Personal/MyApp/password

# Specific field in item
DATABASE_URL=op://Work/PostgreSQL/connection-string

# Username field
DB_USER=op://Production/Database/username
```

### Section-Specific Fields

If your 1Password item has sections:

```bash
# Reference field in specific section
AWS_ACCESS_KEY=op://Personal/AWS/Access Keys/access-key-id
AWS_SECRET_KEY=op://Personal/AWS/Access Keys/secret-access-key
```

### Environment-Aware References

Use shell variable expansion for multi-environment setups:

```bash
# Define environment
export APP_ENV="production"

# In secrets.op file
DATABASE_URL=op://$APP_ENV/database/url
API_KEY=op://$APP_ENV/api/key
REDIS_URL=op://$APP_ENV/redis/connection
```

When `APP_ENV=production`, resolves to `op://production/database/url`

When `APP_ENV=staging`, resolves to `op://staging/database/url`

### Comments and Blank Lines

```bash
# This is a comment - ignored by 1Password CLI

# API Keys
ANTHROPIC_API_KEY=op://Personal/Claude/api-key

# Database Credentials
DATABASE_URL=op://Production/PostgreSQL/url
```

## Multi-Level Secrets

The wrapper loads secrets in this order (later files override earlier):

1. **Global** (`~/.config/claude-code/secrets.op`)
2. **Project** (`./.claude/secrets.op`)
3. **Local** (`./.claude/secrets.local.op`)

### Use Cases

**Global secrets**: Personal API keys used across all projects

```bash
# ~/.config/claude-code/secrets.op
ANTHROPIC_API_KEY=op://Personal/Claude/api-key
OPENAI_API_KEY=op://Personal/OpenAI/api-key
```

**Project secrets**: Credentials specific to one repository

```bash
# ./.claude/secrets.op (committed to git)
DATABASE_URL=op://ProjectName/Database/url
API_ENDPOINT=op://ProjectName/API/endpoint
```

**Local overrides**: Development/testing credentials (gitignored)

```bash
# ./.claude/secrets.local.op (in .gitignore)
DATABASE_URL=op://Local/TestDB/url
DEBUG_MODE=true
```

### .gitignore Configuration

Add to project `.gitignore`:

```gitignore
# Local secrets override
.claude/secrets.local.op
```

Project secrets (`.claude/secrets.op`) can be committed if:

- They reference shared team vaults
- Team members have 1Password access
- No plaintext credentials in file

## Authentication & Sessions

### First Invocation

```
$ claude
Authenticating with 1Password (once per session)...
[TouchID prompt appears]
✓ Authentication successful
[Claude starts]
```

### Subsequent Invocations

```
$ claude
[No prompt - uses existing session]
[Claude starts immediately]
```

### Session Duration

- Desktop app integration: ~30 minutes of idle time
- Biometric signin: Persistent until app logs out
- Manual signin: Persistent for 30 minutes

### Manual Session Check

```bash
# Check if session active
op account get

# Force new signin
eval $(op signin)
```

## Debug Mode

Enable detailed logging to troubleshoot secrets loading:

```bash
CLAUDE_DEBUG=true claude
```

**Output example:**

```
DEBUG: Git identity: Claude Code Bot <claude-code@smartwatermelon.github>
DEBUG: Using SSH key: /Users/you/.ssh/id_ed25519_claude_code
DEBUG: GitHub token loaded from: /Users/you/.config/claude-code/gh-token
DEBUG: 1Password CLI detected (version: 2.32.0)
DEBUG: Active 1Password session detected
DEBUG: Added global secrets: /Users/you/.config/claude-code/secrets.op
DEBUG: Added project secrets: ./.claude/secrets.op
DEBUG: 1Password enabled with 2 secrets file(s)
DEBUG: Executing: op run --env-file=/Users/you/.config/claude-code/secrets.op --env-file=./.claude/secrets.op -- /opt/homebrew/bin/claude
```

## Security Best Practices

### ✓ DO

- Store all secrets in 1Password vault
- Use descriptive item names for easy reference
- Create separate vaults for different security levels (Personal, Work, Production)
- Add `.claude/secrets.local.op` to `.gitignore`
- Use environment variables for environment selection (`$APP_ENV`)
- Verify secret references before committing
- Use service accounts with limited vault access for CI/CD

### ✗ DON'T

- Store plaintext credentials in secrets.op files
- Commit `.claude/secrets.local.op` to git
- Share 1Password session tokens
- Use the same credentials for dev and production
- Bypass the wrapper by calling claude directly when secrets are needed
- Use `--no-masking` in production scripts

## Troubleshooting

### "1Password authentication failed"

**Cause**: App integration not enabled or 1Password app not running

**Solution**:

1. Open 1Password app
2. Check Settings → Developer → "Integrate with 1Password CLI" is ON
3. Restart wrapper

### "WARNING: Cannot read <secrets-file>"

**Cause**: Secrets file exists but isn't readable

**Solution**:

```bash
chmod 600 ~/.config/claude-code/secrets.op
```

### Secrets not available to Claude

**Verify secrets loading**:

```bash
CLAUDE_DEBUG=true claude -c "printenv | grep -E 'API_KEY|TOKEN'"
```

Expected: Variables should be set but values masked

**Verify secret reference syntax**:

```bash
# Test specific secret
op read "op://Personal/MyApp/password"
```

### TouchID prompting too frequently

**Cause**: Session timeout or app integration disabled

**Solution**:

1. Check 1Password app is running
2. Verify Settings → Security → Touch ID is enabled
3. Check Settings → Developer → CLI integration is ON

### Wrong secrets loaded

**Check precedence**:

```bash
CLAUDE_DEBUG=true claude --version 2>&1 | grep "Added"
```

Output shows which files loaded in order. Last file wins for duplicate variables.

## Environment Variables Reference

### User-Controlled

| Variable | Default | Purpose |
|----------|---------|---------|
| `CLAUDE_DEBUG` | `false` | Enable verbose logging |
| `APP_ENV` | - | Environment selector for multi-env setups |

### Set by Wrapper

| Variable | Value | Purpose |
|----------|-------|---------|
| `GIT_AUTHOR_NAME` | `Claude Code Bot` | Git commit author |
| `GIT_AUTHOR_EMAIL` | `claude-code@smartwatermelon.github` | Git commit email |
| `GIT_COMMITTER_NAME` | `Claude Code Bot` | Git committer |
| `GIT_COMMITTER_EMAIL` | `claude-code@smartwatermelon.github` | Git committer email |
| `GIT_SSH_COMMAND` | `ssh -i ~/.ssh/id_ed25519_claude_code ...` | SSH key for git |
| `GH_TOKEN` | From `~/.config/claude-code/gh-token` | GitHub CLI token |

### Loaded from secrets.op

User-defined based on secret references

## Advanced Patterns

### Team Shared Secrets

Create team-accessible vault in 1Password:

```bash
# .claude/secrets.op (committed)
SHARED_API_KEY=op://TeamVault/SharedAPI/key
```

Requirements:

- All team members have 1Password
- All team members have access to TeamVault
- Wrapper installed on all dev machines

### Multi-Environment Workflow

```bash
# .claude/secrets.op
DATABASE_URL=op://$DEPLOY_ENV/database/url
API_KEY=op://$DEPLOY_ENV/api/key

# Local terminal
export DEPLOY_ENV="development"
claude  # Uses development vault

# CI/CD environment
export DEPLOY_ENV="production"
claude  # Uses production vault
```

### Service Account for CI/CD

1. Create 1Password service account
2. Grant access to specific vault only
3. Use service account token in CI:

```bash
# CI environment
export OP_SERVICE_ACCOUNT_TOKEN="ops_..."
claude  # Uses service account session
```

### Conditional Secrets

```bash
# Only load expensive secrets in production
if [[ "${ENVIRONMENT}" == "production" ]]; then
    EXTERNAL_API_KEY=op://Production/External/api-key
fi
```

## Migration from Plaintext

### Step 1: Audit Current Secrets

```bash
# Find potential secrets in your shell configs
grep -rE 'API_KEY|TOKEN|PASSWORD|SECRET' ~/.bashrc ~/.zshrc ~/.profile
```

### Step 2: Move to 1Password

For each secret:

1. Create 1Password item
2. Add credential to item
3. Note vault/item/field path

### Step 3: Create secrets.op

```bash
# Map old environment variables to 1Password references
ANTHROPIC_API_KEY=op://Personal/Claude/api-key
GITHUB_TOKEN=op://Personal/GitHub/token
```

### Step 4: Remove Plaintext

```bash
# Remove from shell configs
sed -i '' '/API_KEY=/d' ~/.bashrc
sed -i '' '/GITHUB_TOKEN=/d' ~/.bashrc
```

### Step 5: Verify

```bash
# Test wrapper with secrets
CLAUDE_DEBUG=true claude -c "printenv | grep API_KEY"
```

## Related Documentation

- [1Password CLI Documentation](https://developer.1password.com/docs/cli/)
- [Secret References Syntax](https://developer.1password.com/docs/cli/secret-reference)
- [App Integration Guide](https://developer.1password.com/docs/cli/app-integration/)
- [Service Accounts](https://developer.1password.com/docs/service-accounts/)

## FAQ

**Q: Do secrets persist after wrapper exits?**

A: No. Secrets are only available to the Claude process and its children. Once the process exits, secrets are cleared from the environment.

**Q: Can I use this without 1Password?**

A: Yes. If 1Password CLI is not installed or no secrets files exist, the wrapper works normally without secrets injection.

**Q: Do git hooks have access to secrets?**

A: Yes. Hooks run as subprocesses of git, which runs under the wrapper, so they inherit the secrets-injected environment.

**Q: How do I share secrets with team members?**

A: Create a shared vault in 1Password, add secrets there, and reference them in `.claude/secrets.op`. All team members with vault access can use the same references.

**Q: What happens if a secret reference is invalid?**

A: `op run` will fail with an error message indicating which reference couldn't be resolved. The wrapper will not start Claude.

**Q: Can I use this for other CLI tools?**

A: The wrapper is Claude-specific, but the secrets.op files can be used with `op run` directly:

```bash
op run --env-file=~/.config/claude-code/secrets.op -- your-command
```
