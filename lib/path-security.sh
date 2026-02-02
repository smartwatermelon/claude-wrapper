#!/usr/bin/env bash
# Path security utilities for claude-wrapper
# Provides path canonicalization and traversal protection
# Requires: lib/logging.sh must be sourced first

# Canonicalize and validate path - prevents traversal attacks
# NOTE: Rejects symlinks to prevent symlink-based attacks. If you need to
# follow symlinks, resolve them before calling this function.
canonicalize_path() {
  local path="$1"
  local canonical

  # Reject symlinks FIRST before any other processing
  # This prevents attacks where symlinks point to sensitive files
  if [[ -L "${path}" ]]; then
    log_error "Refusing to load from symlink: ${path}"
    return 1
  fi

  # Check if file exists
  if [[ ! -e "${path}" ]]; then
    return 1
  fi

  # Get canonical path (resolves .., removes redundant slashes, etc)
  canonical="$(realpath "${path}" 2>/dev/null || readlink -f "${path}" 2>/dev/null || echo "")"

  if [[ -z "${canonical}" ]]; then
    log_error "Could not canonicalize path: ${path}"
    return 1
  fi

  echo "${canonical}"
  return 0
}

# Check if path is contained within parent directory
# IMPORTANT: Both paths must already be canonicalized (no .., no symlinks).
# Use canonicalize_path() first if needed.
path_is_under() {
  local child="$1"
  local parent="$2"

  # Must be equal or have parent as prefix with trailing slash
  [[ "${child}" == "${parent}" ]] || [[ "${child}" == "${parent}/"* ]]
}
