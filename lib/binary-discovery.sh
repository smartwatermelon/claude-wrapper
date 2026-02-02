#!/usr/bin/env bash
# Claude binary discovery for claude-wrapper
# Finds and validates the real claude binary
# Requires: lib/logging.sh and lib/path-security.sh must be sourced first

# Find the real claude binary, excluding the wrapper itself
find_claude_binary() {
  local wrapper_path="$1"
  local claude_bin=""

  debug_log "Searching for claude binary (excluding ${wrapper_path})"

  # Search PATH first
  while IFS= read -r candidate; do
    local candidate_real
    candidate_real="$(realpath "${candidate}" 2>/dev/null || echo "${candidate}")"
    if [[ "${candidate_real}" != "${wrapper_path}" ]] && [[ -x "${candidate}" ]]; then
      claude_bin="${candidate}"
      debug_log "Found claude binary via PATH: ${claude_bin}"
      break
    fi
  done < <(type -ap claude 2>/dev/null || true)

  # Fallback to known locations
  if [[ -z "${claude_bin}" ]]; then
    local candidate
    for candidate in "${HOME}/.local/bin/claude" "${HOME}/.claude/local/claude" "${HOME}/.npm-global/bin/claude" "/opt/homebrew/bin/claude" "/usr/local/bin/claude"; do
      if [[ -x "${candidate}" ]]; then
        local candidate_real
        candidate_real="$(realpath "${candidate}" 2>/dev/null || echo "${candidate}")"
        if [[ "${candidate_real}" != "${wrapper_path}" ]]; then
          claude_bin="${candidate}"
          debug_log "Found claude binary at fallback location: ${claude_bin}"
          break
        fi
      fi
    done
  fi

  if [[ -z "${claude_bin}" ]]; then
    log_error "Could not find claude binary"
    debug_log "Search paths exhausted, no claude binary found"
    return 1
  fi

  echo "${claude_bin}"
  return 0
}

# Validate claude binary before executing
validate_claude_binary() {
  local binary="$1"
  local binary_owner
  local binary_perms

  # Get canonical path
  binary="$(realpath "${binary}" 2>/dev/null || echo "${binary}")"

  # Must be executable
  if [[ ! -x "${binary}" ]]; then
    log_error "Claude binary is not executable: ${binary}"
    return 1
  fi

  # Check owner (should be current user or root)
  local current_uid
  binary_owner="$(stat -f '%u' "${binary}" 2>/dev/null || stat -c '%u' "${binary}" 2>/dev/null || echo "unknown")"
  current_uid="$(id -u)" || current_uid="unknown"
  if [[ "${binary_owner}" != "${current_uid}" ]] && [[ "${binary_owner}" != "0" ]]; then
    log_error "Claude binary has unexpected owner (${binary_owner}): ${binary}"
    return 1
  fi

  # Check permissions (should not be world-writable)
  binary_perms="$(stat -f '%A' "${binary}" 2>/dev/null || stat -c '%a' "${binary}" 2>/dev/null || echo "unknown")"
  if [[ "${binary_perms: -1}" =~ [2367] ]]; then
    log_error "Claude binary is world-writable (${binary_perms}): ${binary}"
    return 1
  fi

  debug_log "Claude binary validated: ${binary} (owner: ${binary_owner}, perms: ${binary_perms})"
  return 0
}
