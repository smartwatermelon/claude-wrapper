#!/usr/bin/env bash
# Permission validation utilities for claude-wrapper
# Provides functions to check and fix file permissions
# Requires: lib/logging.sh must be sourced first

# Validate file permissions - BLOCKING (returns 1 if insecure)
check_file_permissions() {
  local file="$1"
  local perms

  # Get permissions (Darwin vs Linux stat syntax)
  perms="$(stat -f '%A' "${file}" 2>/dev/null || stat -c '%a' "${file}" 2>/dev/null || echo "unknown")"

  if [[ "${perms}" == "unknown" ]]; then
    log_error "Could not check permissions for ${file}"
    return 1
  fi

  # Check if group has ANY permissions (middle digit must be 0)
  if [[ "${perms:1:1}" != "0" ]]; then
    log_error "${file} has group permissions (${perms}), refusing to load"
    return 1
  fi

  # Check if world has ANY permissions (last digit must be 0)
  if [[ "${perms: -1}" != "0" ]]; then
    log_error "${file} has world permissions (${perms}), refusing to load"
    return 1
  fi

  # Verify file is owned by current user
  local file_owner
  local current_uid
  file_owner="$(stat -f '%u' "${file}" 2>/dev/null || stat -c '%u' "${file}" 2>/dev/null || echo "unknown")"
  current_uid="$(id -u)" || current_uid="unknown"
  if [[ "${file_owner}" != "${current_uid}" ]]; then
    log_error "${file} is not owned by current user (owner: ${file_owner}, current: ${current_uid})"
    return 1
  fi

  debug_log "File permissions OK for ${file}: ${perms}"
  return 0
}

# Ensure secure permissions - warns and fixes instead of blocking
# Usage: ensure_secure_permissions <file> <target_perms>
# Example: ensure_secure_permissions "/path/to/file" "700"
ensure_secure_permissions() {
  local file="$1"
  local target_perms="$2"
  local perms

  # Get permissions (Darwin vs Linux stat syntax)
  perms="$(stat -f '%A' "${file}" 2>/dev/null || stat -c '%a' "${file}" 2>/dev/null || echo "unknown")"

  if [[ "${perms}" == "unknown" ]]; then
    log_error "Could not check permissions for ${file}"
    return 1
  fi

  # Verify file is owned by current user first
  local file_owner
  local current_uid
  file_owner="$(stat -f '%u' "${file}" 2>/dev/null || stat -c '%u' "${file}" 2>/dev/null || echo "unknown")"
  current_uid="$(id -u)" || current_uid="unknown"
  if [[ "${file_owner}" != "${current_uid}" ]]; then
    log_error "${file} is not owned by current user (owner: ${file_owner}, current: ${current_uid})"
    return 1
  fi

  # Check if permissions need fixing (group or world has any permissions)
  local needs_fix=false
  if [[ "${perms:1:1}" != "0" ]]; then
    log_warn "${file} has group permissions (${perms})"
    needs_fix=true
  fi
  if [[ "${perms: -1}" != "0" ]]; then
    log_warn "${file} has world permissions (${perms})"
    needs_fix=true
  fi

  if [[ "${needs_fix}" == "true" ]]; then
    log_warn "Auto-fixing permissions: chmod ${target_perms} ${file}"
    if ! chmod "${target_perms}" "${file}"; then
      log_error "Failed to fix permissions on ${file}"
      return 1
    fi
    debug_log "Fixed permissions on ${file} to ${target_perms}"
  else
    debug_log "File permissions OK for ${file}: ${perms}"
  fi

  return 0
}
