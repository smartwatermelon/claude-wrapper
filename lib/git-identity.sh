#!/usr/bin/env bash
# Git identity configuration for claude-wrapper
# Sets up dedicated git identity for Claude Code operations
# Requires: lib/logging.sh must be sourced first

# Git identity for Claude Code operations
readonly CLAUDE_GIT_NAME="Claude Code Bot"
readonly CLAUDE_GIT_EMAIL="claude-code@smartwatermelon.github"
readonly CLAUDE_SSH_KEY="${HOME}/.ssh/id_ed25519_claude_code"

# Set Git author/committer identity
export GIT_AUTHOR_NAME="${CLAUDE_GIT_NAME}"
export GIT_AUTHOR_EMAIL="${CLAUDE_GIT_EMAIL}"
export GIT_COMMITTER_NAME="${CLAUDE_GIT_NAME}"
export GIT_COMMITTER_EMAIL="${CLAUDE_GIT_EMAIL}"

debug_log "Git identity: ${CLAUDE_GIT_NAME} <${CLAUDE_GIT_EMAIL}>"

# Use dedicated SSH key with proper quoting
if [[ -f "${CLAUDE_SSH_KEY}" ]]; then
  printf -v GIT_SSH_COMMAND 'ssh -i %q -o IdentitiesOnly=yes' "${CLAUDE_SSH_KEY}"
  export GIT_SSH_COMMAND
  debug_log "Using SSH key: ${CLAUDE_SSH_KEY}"
else
  debug_log "SSH key not found: ${CLAUDE_SSH_KEY}"
fi
