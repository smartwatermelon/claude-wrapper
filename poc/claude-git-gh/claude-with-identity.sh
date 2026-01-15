#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Claude Code CLI Wrapper - Isolated Git Identity
# ============================================================================
#
# This wrapper sets up a separate Git identity for Claude Code CLI operations,
# ensuring commits are attributed to a distinct user and use a dedicated SSH key.
#
# Installation:
#   1. Save to ~/.local/bin/claude-with-identity
#   2. chmod +x ~/.local/bin/claude-with-identity
#   3. Create alias: alias claude-ai='~/.local/bin/claude-with-identity'
#
# Prerequisites:
#   - SSH key at ~/.ssh/id_ed25519_claude_code (added to GitHub)
#   - Fine-grained PAT at ~/.config/claude-code/gh-token
#
# ============================================================================

# CONFIGURATION
# =============

# Git identity for Claude Code operations
# Change these to match your preferred attribution
CLAUDE_GIT_NAME="Claude Code Bot"
CLAUDE_GIT_EMAIL="claude-code@smartwatermelon.github"

# SSH key dedicated to Claude Code
CLAUDE_SSH_KEY="${HOME}/.ssh/id_ed25519_claude_code"

# ENVIRONMENT SETUP
# =================

# Set Git author/committer identity
export GIT_AUTHOR_NAME="${CLAUDE_GIT_NAME}"
export GIT_AUTHOR_EMAIL="${CLAUDE_GIT_EMAIL}"
export GIT_COMMITTER_NAME="${CLAUDE_GIT_NAME}"
export GIT_COMMITTER_EMAIL="${CLAUDE_GIT_EMAIL}"

# Use dedicated SSH key for Git operations
if [[ -f "${CLAUDE_SSH_KEY}" ]]; then
  export GIT_SSH_COMMAND="ssh -i ${CLAUDE_SSH_KEY} -o IdentitiesOnly=yes"
else
  echo "Warning: Claude Code SSH key not found at ${CLAUDE_SSH_KEY}" >&2
  echo "         Git operations will use default SSH key" >&2
fi

# FIND CLAUDE BINARY
# ==================

# Get the absolute path of this wrapper to exclude it from search
WRAPPER_PATH="$(realpath "${BASH_SOURCE[0]}")"

# Find the real claude binary
CLAUDE_BIN=""

# Method 1: Search PATH, excluding this wrapper
while IFS= read -r candidate; do
  candidate_real="$(realpath "${candidate}" 2>/dev/null || echo "${candidate}")"
  if [[ "${candidate_real}" != "${WRAPPER_PATH}" ]] && [[ -x "${candidate}" ]]; then
    CLAUDE_BIN="${candidate}"
    break
  fi
done < <(type -ap claude 2>/dev/null)

# Method 2: Check common installation locations
if [[ -z "${CLAUDE_BIN}" ]]; then
  for candidate in \
    "${HOME}/.claude/local/claude" \
    "${HOME}/.npm-global/bin/claude" \
    "/opt/homebrew/bin/claude" \
    "/usr/local/bin/claude" \
    "${HOME}/.local/bin/claude-original"; do
    if [[ -x "${candidate}" ]]; then
      candidate_real="$(realpath "${candidate}" 2>/dev/null || echo "${candidate}")"
      if [[ "${candidate_real}" != "${WRAPPER_PATH}" ]]; then
        CLAUDE_BIN="${candidate}"
        break
      fi
    fi
  done
fi

# Bail if we can't find claude
if [[ -z "${CLAUDE_BIN}" ]]; then
  echo "Error: Could not find claude binary" >&2
  echo "       Ensure Claude Code CLI is installed and in your PATH" >&2
  echo "       This wrapper is at: ${WRAPPER_PATH}" >&2
  exit 1
fi

# DEBUG OUTPUT (uncomment to troubleshoot)
# echo "Using claude binary: ${CLAUDE_BIN}" >&2
# echo "Git identity: ${GIT_AUTHOR_NAME} <${GIT_AUTHOR_EMAIL}>" >&2
# echo "SSH command: ${GIT_SSH_COMMAND:-default}" >&2

# EXECUTE
# =======
exec "${CLAUDE_BIN}" "$@"
