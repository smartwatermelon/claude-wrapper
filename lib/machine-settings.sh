#!/usr/bin/env bash
# machine-settings.sh - per-machine settings over the shared ~/.claude/settings.json
# Needs logging, permissions, remote-session

# The file this machine layers on top. Not in any repo.
machine_settings_file() {
  printf '%s\n' "${CLAUDE_MACHINE_SETTINGS:-${HOME}/.config/claude-code/machine-settings.json}"
}

# Prints "--settings" and the path, one per line, and returns 0 to add them; else returns 1. Never blocks.
build_machine_settings_args() {
  local file perms arg
  file="$(machine_settings_file)"
  [[ -f "${file}" ]] || return 1

  # Interactive only, like remote control: review hooks and scripts keep the shared settings.
  if ! is_interactive_session "$@"; then
    debug_log "Non-interactive invocation, not adding ${file}"
    return 1
  fi
  for arg in "$@"; do
    case "${arg}" in
      --settings | --settings=*)
        debug_log "--settings given on the command line, not adding ${file}"
        return 1
        ;;
      *) ;;
    esac
  done

  # A settings file can define hooks, which run commands: only one you own that nobody else can write.
  if [[ "$(_stat_owner_uid "${file}")" != "$(id -u)" ]]; then
    log_warn "${file} is not owned by you; skipping machine settings"
    return 1
  fi
  perms="$(_stat_perms "${file}")"
  if [[ "${perms}" == "unknown" ]] || ((8#${perms} & 8#022)); then
    log_warn "${file} is writable by group or others (${perms}); skipping machine settings. Fix: chmod go-w '${file}'"
    return 1
  fi

  # Invalid JSON would stop claude from starting; skip it instead, and skip it unchecked without jq.
  if ! command -v jq >/dev/null 2>&1; then
    log_warn "jq not found, so ${file} cannot be checked; skipping machine settings"
    return 1
  fi
  if ! jq -e 'type == "object"' "${file}" >/dev/null 2>&1; then
    log_warn "${file} is not a JSON object; skipping machine settings"
    return 1
  fi

  debug_log "Adding machine settings: ${file}"
  printf '%s\n' "--settings" "${file}"
  return 0
}
