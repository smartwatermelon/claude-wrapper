#!/usr/bin/env bash
# Per-invocation GitHub token routing for multi-org support
# Sourced by the gh wrapper (~/.local/bin/gh) to select the correct
# fine-grained PAT based on the target repo owner.
#
# Requires env vars set by claude-wrapper:
#   CLAUDE_GH_TOKEN_DIR  — directory containing gh-token.* files
#   CLAUDE_GH_TOKEN_ROUTER — path to this file (used by gh wrapper to source it)
#
# This module is intentionally dependency-free (no logging.sh, permissions.sh)
# to keep the gh wrapper fast and self-contained.

# Detect the target repo owner from gh CLI arguments.
# Priority: --repo/-R flag > API path > git remote of cwd > empty (fallback)
# Usage: detect_repo_owner "$@"
# Outputs the owner name to stdout, or empty string if undetectable.
detect_repo_owner() {
  local owner=""

  # Strategy 1: --repo OWNER/REPO or -R OWNER/REPO
  local prev=""
  for arg in "$@"; do
    if [[ "${prev}" == "--repo" || "${prev}" == "-R" ]]; then
      # arg is OWNER/REPO — extract owner
      owner="${arg%%/*}"
      if [[ -n "${owner}" && "${owner}" != "${arg}" ]]; then
        printf '%s\n' "${owner}"
        return 0
      fi
    fi
    prev="${arg}"
  done

  # Strategy 2: API path containing repos/OWNER/... or orgs/OWNER/...
  for arg in "$@"; do
    if [[ "${arg}" =~ ^repos/([^/]+)/ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
    if [[ "${arg}" =~ ^orgs/([^/]+) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done

  # Strategy 3: Git remote of cwd
  local remote_url
  if remote_url="$(git remote get-url origin 2>/dev/null)"; then
    # Handle SSH: git@github.com:OWNER/REPO.git
    if [[ "${remote_url}" =~ github\.com[:/]([^/]+)/ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  fi

  # No owner detected — caller will use default token
  return 1
}

# Inline permission check for token files.
# Verifies no group or world permissions (middle and last digit are 0).
# Lighter than permissions.sh — no logging dependencies needed.
# Usage: _check_token_perms <file>
# Returns 0 if secure, 1 if insecure.
_check_token_perms() {
  local file="$1"
  local perms
  perms="$(stat -f '%A' "${file}" 2>/dev/null || stat -c '%a' "${file}" 2>/dev/null || echo "unknown")"

  if [[ "${perms}" == "unknown" ]]; then
    printf '[gh-token-router] Error: Cannot check permissions for %s\n' "${file}" >&2
    return 1
  fi

  # Middle digit (group) must be 0, last digit (world) must be 0
  if [[ "${perms:1:1}" != "0" || "${perms: -1}" != "0" ]]; then
    printf '[gh-token-router] Error: %s has insecure permissions (%s), refusing to load\n' "${file}" "${perms}" >&2
    return 1
  fi

  return 0
}

# Select and export the correct GH_TOKEN for this invocation.
# Tries owner-specific token file first, falls back to default.
# Usage: select_gh_token "$@"
select_gh_token() {
  local token_dir="${CLAUDE_GH_TOKEN_DIR:-}"

  # Bail if token dir not configured
  if [[ -z "${token_dir}" || ! -d "${token_dir}" ]]; then
    return 0
  fi

  local owner
  if owner="$(detect_repo_owner "$@")" && [[ -n "${owner}" ]]; then
    # Validate owner against GitHub username charset to prevent path traversal.
    # GitHub usernames must start with alphanumeric (rejects "..", ".", "-evil").
    if [[ ! "${owner}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
      printf '[gh-token-router] Error: Invalid owner name: %s\n' "${owner}" >&2
      return 1
    fi

    local owner_token_file="${token_dir}/gh-token.${owner}"

    if [[ -f "${owner_token_file}" ]]; then
      if _check_token_perms "${owner_token_file}"; then
        GH_TOKEN="$(<"${owner_token_file}")"
        export GH_TOKEN
        return 0
      else
        # Insecure permissions — do NOT fall back, fail explicitly
        return 1
      fi
    fi
    # No owner-specific file — fall through to default (already in env)
  fi

  # Default: whatever GH_TOKEN is already set (from github-token.sh)
  return 0
}

# Auto-invoke when sourced (follows github-token.sh pattern)
select_gh_token "$@"
