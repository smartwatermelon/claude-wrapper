#!/usr/bin/env bash
# remote-session.sh - Automatic remote control for interactive claude sessions
# Requires: lib/logging.sh must be sourced first

# Derive a human-readable session name from the current git repo or directory
get_remote_session_name() {
  local git_root
  git_root="$(git rev-parse --show-toplevel 2>/dev/null)" || true

  if [[ -n "${git_root}" ]]; then
    basename "${git_root}"
  else
    basename "${PWD}"
  fi
}

# Returns 0 if the args represent an interactive claude session (should inject --remote-control)
# Returns 1 if this looks like a non-interactive invocation
#
# Non-interactive signals:
#   --print / -p         : print mode
#   --version            : version check
#   --help / -h          : help output
#   --remote-control/--rc: already has remote control
#   --no-session-persistence: focused analysis task (scripts, CI)
#   Any positional arg   : subcommand (e.g. remote-control, mcp, help, update)
is_interactive_session() {
  local found_double_dash=0

  for arg in "$@"; do
    if [[ "${found_double_dash}" -eq 1 ]]; then
      # After --, everything is positional — treat as non-interactive
      return 1
    fi

    case "${arg}" in
      --)
        found_double_dash=1
        ;;
      --print | -p | --version | --help | -h)
        return 1
        ;;
      --remote-control | --rc)
        return 1
        ;;
      --no-session-persistence)
        return 1
        ;;
      -*)
        # Other flags are fine; skip (handles --flag value pairs conservatively)
        ;;
      *)
        # Bare positional arg → subcommand; not interactive
        return 1
        ;;
    esac
  done

  return 0
}

# Build extra args to prepend for remote control.
# Outputs nothing and returns 1 if remote control should not be injected.
# Outputs "--remote-control" and "session-name" (newline-separated) and returns 0 if it should.
build_remote_control_args() {
  # Allow opt-out via environment variable
  if [[ "${CLAUDE_NO_REMOTE_CONTROL:-}" == "true" ]]; then
    debug_log "Remote control disabled via CLAUDE_NO_REMOTE_CONTROL"
    return 1
  fi

  if ! is_interactive_session "$@"; then
    debug_log "Non-interactive invocation detected, skipping remote control injection"
    return 1
  fi

  local session_name
  session_name="$(get_remote_session_name)"
  debug_log "Injecting --remote-control with session name: ${session_name}"

  printf '%s\n' "--remote-control" "${session_name}"
  return 0
}
