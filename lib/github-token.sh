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

# Detect repo owner from cwd's git remote.
# Outputs the lowercase owner name, or empty if not in a git repo / no GitHub remote.
_detect_cwd_owner() {
  local remote_url
  if remote_url="$(git remote get-url origin 2>/dev/null)"; then
    if [[ "${remote_url}" =~ github\.com[:/]([^/]+)/ ]]; then
      printf '%s\n' "${BASH_REMATCH[1],,}"
      return 0
    fi
  fi
  return 1
}

# Try to load a token for a specific owner.
# Checks GH_TOKEN_{OWNER} env var first (set by 1Password secrets injection),
# then falls back to flat file gh-token.{owner}.
# Returns 0 and exports GH_TOKEN on success, 1 on failure.
_load_owner_token() {
  local owner="$1"

  # Check 1Password-injected env var
  local normalized="${owner^^}"
  normalized="${normalized//[.-]/_}"
  local env_var_name="GH_TOKEN_${normalized}"
  if [[ -n "${!env_var_name:-}" ]]; then
    GH_TOKEN="${!env_var_name}"
    export GH_TOKEN
    debug_log "GitHub token loaded from env var: ${env_var_name}"
    return 0
  fi

  # Fall back to flat file
  local owner_file="${CLAUDE_GH_TOKEN_DIR_PATH}/gh-token.${owner}"
  if [[ -f "${owner_file}" ]]; then
    if check_file_permissions "${owner_file}"; then
      GH_TOKEN="$(<"${owner_file}")"
      export GH_TOKEN
      debug_log "GitHub token loaded from file: ${owner_file}"
      return 0
    else
      log_error "GitHub token file has insecure permissions: ${owner_file}"
      return 1
    fi
  fi

  return 1
}

# Load GitHub CLI token with security checks and configure multi-org routing.
# Token selection priority:
#   1. CLAUDE_GH_DEFAULT_OWNER env var (explicit override)
#   2. cwd git remote owner (auto-detect)
#   3. Default gh-token file (legacy fallback)
load_github_token() {
  local token_loaded=false
  local owner=""

  # Priority 1: Explicit owner override
  if [[ -n "${CLAUDE_GH_DEFAULT_OWNER:-}" ]]; then
    owner="${CLAUDE_GH_DEFAULT_OWNER}"
    debug_log "Using explicit default owner: ${owner}"
  fi

  # Priority 2: Detect from cwd git remote
  if [[ -z "${owner}" ]]; then
    if owner="$(_detect_cwd_owner)"; then
      debug_log "Detected cwd owner from git remote: ${owner}"
    else
      owner=""
    fi
  fi

  # Load owner-specific token
  if [[ -n "${owner}" ]] && _load_owner_token "${owner}"; then
    token_loaded=true
  fi

  # Priority 3: Legacy default file
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

# NOTE: Do not auto-load here. The wrapper calls load_github_token explicitly
# after inject_secrets so that 1Password-injected GH_TOKEN_* env vars are
# available for owner-based token selection.
