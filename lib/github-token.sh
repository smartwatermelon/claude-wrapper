#!/usr/bin/env bash
# GitHub token management for claude-wrapper
# Loads GitHub CLI token from secure file
# Requires: lib/logging.sh and lib/permissions.sh must be sourced first

readonly CLAUDE_GH_TOKEN_FILE="${HOME}/.config/claude-code/gh-token"

# Load GitHub CLI token with security checks
load_github_token() {
  if [[ -f "${CLAUDE_GH_TOKEN_FILE}" ]]; then
    if check_file_permissions "${CLAUDE_GH_TOKEN_FILE}"; then
      # Use Bash built-in read instead of cat
      GH_TOKEN="$(<"${CLAUDE_GH_TOKEN_FILE}")"
      export GH_TOKEN
      debug_log "GitHub token loaded successfully"
    else
      log_error "GitHub token file has insecure permissions, refusing to load"
      return 1
    fi
  else
    debug_log "GitHub token file not found: ${CLAUDE_GH_TOKEN_FILE}"
  fi
  return 0
}

# Auto-load on source
load_github_token
