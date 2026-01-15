# Separating Claude Code CLI Git Identity from Personal Identity

## Problem Statement

When using Claude Code CLI (CCCLI) for development, it inherits your personal Git identity and GitHub credentials. This creates two issues:

1. **Attribution ambiguity**: Commits made by CCCLI appear as if *you* made them, making it impossible to distinguish AI-assisted work from direct human work in the git history.

2. **Over-permissioning**: CCCLI has access to the same "all repos" SSH key and GitHub token as you, when it typically only needs access to the current project.

## Solution Architecture

The solution uses Git's environment variable overrides combined with SSH key management and fine-grained GitHub PATs:

```
┌─────────────────────────────────────────────────────────────────┐
│                     Your Terminal Session                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────────┐      ┌────────────────────────────────┐   │
│  │   Direct `git`   │      │       `claude` command         │   │
│  │   commands       │      │     (via wrapper script)       │   │
│  └────────┬─────────┘      └───────────────┬────────────────┘   │
│           │                                 │                    │
│           ▼                                 ▼                    │
│  ┌──────────────────┐      ┌────────────────────────────────┐   │
│  │ Identity:        │      │ Identity:                      │   │
│  │  Andrew Rich     │      │  Claude Code Bot               │   │
│  │  andrew.rich@... │      │  claude-code@smartwatermelon   │   │
│  │                  │      │                                │   │
│  │ SSH Key:         │      │ SSH Key:                       │   │
│  │  id_ed25519      │      │  id_ed25519_claude_code        │   │
│  │                  │      │                                │   │
│  │ GH Token:        │      │ GH Token:                      │   │
│  │  (via gh auth)   │      │  Fine-grained PAT              │   │
│  └──────────────────┘      └────────────────────────────────┘   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Implementation Steps

### Step 1: Generate a Dedicated SSH Key

```bash
# Generate a new ed25519 key specifically for Claude Code
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_claude_code -C "claude-code@$(hostname)"

# When prompted for passphrase, you can:
#   - Leave empty for automated use (less secure)
#   - Set a passphrase and use ssh-agent (more secure)
```

### Step 2: Add the Key to Your GitHub Account

1. Copy the public key:

   ```bash
   cat ~/.ssh/id_ed25519_claude_code.pub | pbcopy
   ```

2. Go to GitHub → Settings → SSH and GPG keys → New SSH key

3. Name it something clear like "Claude Code CLI - [Machine Name]"

4. Paste the public key and save

> **Note**: This key is tied to your account but with a distinct name. Commits will still push to your repos, but you'll be able to identify which key was used if needed.

### Step 3: Update SSH Config

Add to `~/.ssh/config`:

```
# Claude Code CLI - uses dedicated key
Host github.com-claude
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_claude_code
    IdentitiesOnly yes
```

### Step 4: Create a Fine-Grained Personal Access Token

1. Go to GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens

2. Click "Generate new token"

3. Configure:
   - **Token name**: `claude-code-cli`
   - **Expiration**: 90 days (or your preference)
   - **Repository access**: "Only select repositories" - choose the repos CCCLI should access
   - **Permissions** (minimal set for typical development):
     - Contents: Read and write
     - Metadata: Read-only
     - Pull requests: Read and write (if CCCLI creates PRs)

4. Generate and copy the token

### Step 5: Create the Wrapper Script

Create `~/.local/bin/claude-with-identity`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Claude Code CLI Wrapper - Isolated Git Identity
# ============================================================================
# This wrapper sets up a separate Git identity for Claude Code CLI operations,
# ensuring commits are attributed to a distinct user and use a dedicated SSH key.
# ============================================================================

# CONFIGURATION
# =============
# Git identity for Claude Code operations
export GIT_AUTHOR_NAME="Claude Code Bot"
export GIT_AUTHOR_EMAIL="claude-code@smartwatermelon.github"
export GIT_COMMITTER_NAME="Claude Code Bot"
export GIT_COMMITTER_EMAIL="claude-code@smartwatermelon.github"

# Use the dedicated SSH key for Git operations
export GIT_SSH_COMMAND="ssh -i ${HOME}/.ssh/id_ed25519_claude_code -o IdentitiesOnly=yes"

# GitHub CLI token (fine-grained PAT with limited permissions)
# Stored in a separate file for security - create this file manually
CLAUDE_GH_TOKEN_FILE="${HOME}/.config/claude-code/gh-token"
if [[ -f "${CLAUDE_GH_TOKEN_FILE}" ]]; then
    export GH_TOKEN
    GH_TOKEN="$(cat "${CLAUDE_GH_TOKEN_FILE}")"
fi

# Optional: Override gh config directory to use separate auth entirely
# export GH_CONFIG_DIR="${HOME}/.config/claude-code/gh"

# EXECUTION
# =========
# Find the real claude binary (skip this wrapper)
CLAUDE_BIN=""
while IFS= read -r -d '' path; do
    if [[ "${path}" != "${BASH_SOURCE[0]}" ]] && [[ -x "${path}" ]]; then
        CLAUDE_BIN="${path}"
        break
    fi
done < <(type -ap claude 2>/dev/null | tr '\n' '\0')

# Fallback locations
if [[ -z "${CLAUDE_BIN}" ]]; then
    for candidate in \
        "${HOME}/.claude/local/claude" \
        "${HOME}/.npm-global/bin/claude" \
        "/opt/homebrew/bin/claude" \
        "/usr/local/bin/claude"; do
        if [[ -x "${candidate}" ]]; then
            CLAUDE_BIN="${candidate}"
            break
        fi
    done
fi

if [[ -z "${CLAUDE_BIN}" ]]; then
    echo "Error: Could not find claude binary" >&2
    exit 1
fi

# Execute claude with the modified environment
exec "${CLAUDE_BIN}" "$@"
```

Make it executable:

```bash
chmod +x ~/.local/bin/claude-with-identity
```

### Step 6: Store the GitHub Token

```bash
# Create the config directory
mkdir -p ~/.config/claude-code

# Store the token (paste your fine-grained PAT)
read -r -s -p "Enter your Claude Code fine-grained PAT: " token
echo "${token}" > ~/.config/claude-code/gh-token
chmod 600 ~/.config/claude-code/gh-token
unset token
```

### Step 7: Create a Shell Alias

Add to your `~/.config/bash/aliases.sh`:

```bash
# Claude Code CLI with isolated identity
alias claude-ai='~/.local/bin/claude-with-identity'

# Or if you want to completely replace the default:
# alias claude='~/.local/bin/claude-with-identity'
```

Reload your shell:

```bash
source ~/.bash_profile
```

## Usage

### Using the Isolated Identity

```bash
# Use the wrapper explicitly
claude-ai "implement the login feature"

# Or if you aliased it to `claude`:
claude "implement the login feature"
```

### Verifying the Setup

Test that the identity is correctly applied:

```bash
# Test SSH key
GIT_SSH_COMMAND="ssh -i ~/.ssh/id_ed25519_claude_code -o IdentitiesOnly=yes" \
    ssh -T git@github.com
# Should show: Hi smartwatermelon! You've successfully authenticated...

# Test git identity
GIT_AUTHOR_NAME="Claude Code Bot" \
GIT_AUTHOR_EMAIL="claude-code@smartwatermelon.github" \
    git config user.name
# Won't show anything (env vars don't affect config), but verify with:
GIT_AUTHOR_NAME="Claude Code Bot" \
GIT_AUTHOR_EMAIL="claude-code@smartwatermelon.github" \
    git var GIT_AUTHOR_IDENT
# Should show: Claude Code Bot <claude-code@smartwatermelon.github> ...

# Test GH CLI token
GH_TOKEN="$(cat ~/.config/claude-code/gh-token)" gh auth status
# Should show your fine-grained token's permissions
```

## Identifying Claude Code Commits

After implementing this solution, commits made through Claude Code CLI will show:

```
commit abc123...
Author: Claude Code Bot <claude-code@smartwatermelon.github>
Date:   Sun Jan 11 2026 12:00:00 -0800

    feat: implement user authentication
    
    Co-Authored-By: Claude <noreply@anthropic.com>
```

You can filter commits by author:

```bash
# Show only Claude Code commits
git log --author="Claude Code Bot"

# Show only your personal commits
git log --author="Andrew Rich"

# Count commits by author
git shortlog -sn
```

## Security Considerations

1. **Token Storage**: The fine-grained PAT is stored in a file readable only by you (`chmod 600`). For higher security, consider using a secrets manager or macOS Keychain.

2. **Repository Scope**: The fine-grained PAT should be limited to only the repositories Claude Code needs to access. Update the token when you start new projects.

3. **Token Rotation**: Set a reasonable expiration (90 days suggested) and rotate tokens regularly.

4. **SSH Key Passphrase**: If you add a passphrase to the Claude Code SSH key, ensure it's loaded into ssh-agent for seamless operation.

## Alternative Approaches Considered

### Machine User Account

Creating a separate GitHub account (e.g., `smartwatermelon-bot`) would provide complete isolation but adds complexity:

- Requires a second email address
- Need to add as collaborator to each repo
- More overhead to manage

This approach is better for team/org scenarios where multiple people share the bot identity.

### GitHub App

A GitHub App provides the most granular control but is overkill for personal use:

- Complex setup with JWT authentication
- Better suited for automated systems, not interactive CLI tools

### Directory-Based Identity (Conditional Includes)

Git's `includeIf` feature switches identity based on directory, but doesn't work here because:

- Claude Code operates in the same directories as you
- You want identity based on *who* is making the commit, not *where*

## Troubleshooting

### "Permission denied (publickey)"

Ensure the SSH key is added to your GitHub account and the key file permissions are correct:

```bash
chmod 600 ~/.ssh/id_ed25519_claude_code
```

### "GH_TOKEN invalid or expired"

Regenerate the fine-grained PAT in GitHub settings and update the token file.

### Commits still show your personal identity

Verify the environment variables are being set by the wrapper. Add this debug line to the wrapper script temporarily:

```bash
env | grep -E "^GIT_|^GH_"
```

### Claude command not found in wrapper

Update the fallback paths in the wrapper script to match your actual Claude Code installation location.
