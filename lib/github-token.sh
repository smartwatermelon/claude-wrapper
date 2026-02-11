#!/usr/bin/env bash
# GitHub token management for claude-wrapper
# Loads GitHub CLI token from secure file and configures multi-org token routing
# Requires: lib/logging.sh and lib/permissions.sh must be sourced first

readonly CLAUDE_GH_TOKEN_DIR_PATH="${HOME}/.config/claude-code"
readonly CLAUDE_GH_TOKEN_DEFAULT="${CLAUDE_GH_TOKEN_DIR_PATH}/gh-token"

# Determine the path to the token router module (sibling of this file)
_gh_token_router_path() {
  local this_dir
  this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "${this_dir}/gh-token-router.sh"
}

# Load GitHub CLI token with security checks and configure multi-org routing
load_github_token() {
  local token_loaded=false

  # Try default owner token first (CLAUDE_GH_DEFAULT_OWNER env var)
  if [[ -n "${CLAUDE_GH_DEFAULT_OWNER:-}" ]]; then
    local owner_file="${CLAUDE_GH_TOKEN_DIR_PATH}/gh-token.${CLAUDE_GH_DEFAULT_OWNER}"
    if [[ -f "${owner_file}" ]]; then
      if check_file_permissions "${owner_file}"; then
        GH_TOKEN="$(<"${owner_file}")"
        export GH_TOKEN
        token_loaded=true
        debug_log "GitHub token loaded from owner-specific file: ${owner_file}"
      else
        log_error "GitHub token file has insecure permissions: ${owner_file}"
        return 1
      fi
    fi
  fi

  # Fall back to default gh-token file
  if [[ "${token_loaded}" != "true" ]] && [[ -f "${CLAUDE_GH_TOKEN_DEFAULT}" ]]; then
    if check_file_permissions "${CLAUDE_GH_TOKEN_DEFAULT}"; then
      GH_TOKEN="$(<"${CLAUDE_GH_TOKEN_DEFAULT}")"
      export GH_TOKEN
      token_loaded=true
      debug_log "GitHub token loaded from default file: ${CLAUDE_GH_TOKEN_DEFAULT}"
    else
      log_error "GitHub token file has insecure permissions, refusing to load"
      return 1
    fi
  fi

  if [[ "${token_loaded}" != "true" ]]; then
    debug_log "No GitHub token file found in ${CLAUDE_GH_TOKEN_DIR_PATH}"
  fi

  # Export multi-org routing env vars for the gh wrapper
  local router_path
  router_path="$(_gh_token_router_path)"

  if [[ -d "${CLAUDE_GH_TOKEN_DIR_PATH}" ]]; then
    CLAUDE_GH_TOKEN_DIR="${CLAUDE_GH_TOKEN_DIR_PATH}"
    export CLAUDE_GH_TOKEN_DIR
    debug_log "Token router dir exported: ${CLAUDE_GH_TOKEN_DIR}"
  fi

  if [[ -f "${router_path}" ]]; then
    CLAUDE_GH_TOKEN_ROUTER="${router_path}"
    export CLAUDE_GH_TOKEN_ROUTER
    debug_log "Token router exported: ${CLAUDE_GH_TOKEN_ROUTER}"
  fi

  return 0
}

# Auto-load on source
load_github_token
