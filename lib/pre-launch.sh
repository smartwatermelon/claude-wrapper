#!/usr/bin/env bash
# Pre-launch hook execution for claude-wrapper
# Runs project-specific pre-launch hooks
# Requires: lib/logging.sh, lib/permissions.sh, lib/path-security.sh must be sourced first

# Run project-specific pre-launch hook if it exists
# Arguments: $1 = git root directory (required)
run_pre_launch_hook() {
  local git_root="$1"
  local pre_launch_hook="${git_root}/.claude/pre-launch.sh"

  if [[ -z "${git_root}" ]]; then
    debug_log "No git root provided, skipping pre-launch hook"
    return 0
  fi

  if [[ ! -f "${pre_launch_hook}" ]]; then
    debug_log "No pre-launch hook found at ${pre_launch_hook}"
    return 0
  fi

  # Canonicalize and validate hook path (prevent symlink escape)
  local validated_hook
  if ! validated_hook="$(canonicalize_path "${pre_launch_hook}" 2>/dev/null)"; then
    debug_log "Could not canonicalize pre-launch hook path"
    return 0
  fi

  if ! path_is_under "${validated_hook}" "${git_root}"; then
    log_error "Pre-launch hook path escapes git repository: ${validated_hook}"
    log_error "Remove the symlink or use a hook file within the repository"
    return 1
  fi

  # Ensure secure permissions (warns and auto-fixes to 700 if needed)
  if ! ensure_secure_permissions "${validated_hook}" "700"; then
    log_error "Cannot fix permissions on pre-launch hook: ${validated_hook}"
    return 1
  fi

  # After ensure_secure_permissions with 700, file should be executable
  # Double-check executability in case the file was created with wrong perms
  if [[ ! -x "${validated_hook}" ]]; then
    log_warn "Pre-launch hook is not executable, fixing: ${validated_hook}"
    if ! chmod +x "${validated_hook}"; then
      log_error "Failed to make pre-launch hook executable: ${validated_hook}"
      return 1
    fi
  fi

  debug_log "Running project pre-launch hook: ${validated_hook}"
  # shellcheck source=/dev/null
  if ! source "${validated_hook}"; then
    log_error "Pre-launch hook failed: ${validated_hook}"
    log_error "Fix the hook script or remove it to start Claude"
    return 1
  fi

  return 0
}
