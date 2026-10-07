#!/usr/bin/env bash
# reload.sh - relaunch claude when /reload asks (see CLAUDE.md, "Reload")
# Requires: lib/logging.sh must be sourced first

# Flags that take one value, from `claude --help` (2.1.293). The arg after one
# is its value, not a prompt.
_RELOAD_VALUE_FLAGS=(
  --agent --agents --append-system-prompt --append-system-prompt-file
  --autocompact --cloud -d --debug --debug-file --effort --environment
  --fallback-model --from-pr --input-format --json-schema --max-budget-usd
  --model -n --name --output-format --permission-mode --permission-prompts
  --plugin-dir --plugin-url --prompt-suggestions --remote-control
  --remote-control-session-name-prefix -r --resume --session-id
  --setting-sources --settings --system-prompt --system-prompt-file
  --system-prompt-snapshot --teleport -w --worktree
)

# Variadic flags (`<x...>` in --help): every non-flag arg after one is a value
_RELOAD_VARIADIC_FLAGS=(
  --add-dir --allowedTools --allowed-tools --betas --disallowedTools
  --disallowed-tools --file --mcp-config --tools
)

# A relaunch with these starts somewhere new instead of resuming, so they get
# no reload
_RELOAD_UNSUPPORTED_FLAGS=(
  -w --worktree --tmux --teleport --cloud --bg --background --desktop
)

_reload_in_list() {
  local candidate="$1" item
  shift
  for item in "$@"; do
    [[ "${candidate}" == "${item}" ]] && return 0
  done
  return 1
}

# Returns 0 if a reloaded session can resume these args in place.
reload_supported() {
  local arg flag
  for arg in "$@"; do
    for flag in "${_RELOAD_UNSUPPORTED_FLAGS[@]}"; do
      if [[ "${arg}" == "${flag}" || "${arg}" == "${flag}="* ]]; then
        return 1
      fi
    done
  done
  return 0
}

# Sets RELOAD_BASE_ARGS: the args minus prompts and resume flags. A global
# array, so values with newlines survive.
reload_base_args() {
  RELOAD_BASE_ARGS=()
  # mode: what a following non-flag arg is -- none (a prompt), one, many, drop
  local mode="none" arg
  for arg in "$@"; do
    if [[ "${arg}" != -* ]]; then
      case "${mode}" in
        one)
          RELOAD_BASE_ARGS+=("${arg}")
          mode="none"
          ;;
        many) RELOAD_BASE_ARGS+=("${arg}") ;;
        drop) mode="none" ;; # the old --resume/--session-id value
        *) ;;                # none: a prompt, already sent once
      esac
      continue
    fi

    mode="none"
    case "${arg}" in
      -c | --continue | --fork-session | --resume=* | --session-id=*) ;;
      -r | --resume | --session-id) mode="drop" ;;
      *)
        RELOAD_BASE_ARGS+=("${arg}")
        if _reload_in_list "${arg}" "${_RELOAD_VARIADIC_FLAGS[@]}"; then
          mode="many"
        elif _reload_in_list "${arg}" "${_RELOAD_VALUE_FLAGS[@]}"; then
          mode="one"
        fi
        ;;
    esac
  done
}

# Directory for reload markers, one file per wrapper PID
reload_marker_dir() {
  echo "${CLAUDE_WRAPPER_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/claude-wrapper}/reload"
}

# Reads and removes the marker; prints a session ID, "new", or nothing.
# Returns 1 when there is no marker: do not relaunch.
reload_consume_marker() {
  local marker="$1"
  [[ -f "${marker}" && ! -L "${marker}" ]] || return 1

  local session_id=""
  session_id="$(head -n 1 "${marker}" 2>/dev/null)" || session_id=""
  rm -f "${marker}"

  # The marker value becomes a claude arg, so pass only a UUID or "new"
  if [[ "${session_id}" == "new" ]] \
    || [[ "${session_id}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo "${session_id}"
  else
    [[ -n "${session_id}" ]] && log_warn "Ignoring malformed session ID in reload marker; resuming with --continue"
  fi
  return 0
}

# Usage: run_with_reload <launcher...> -- <claude args...>
# Relaunches while the session asks to; returns the last exit code.
run_with_reload() {
  local -a launcher=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    launcher+=("$1")
    shift
  done
  [[ $# -gt 0 ]] && shift # drop the "--"
  local -a original_args=("$@")

  if ! reload_supported "${original_args[@]}"; then
    debug_log "Reload not supported for these args; launching without it"
    unset CLAUDE_WRAPPER_PID CLAUDE_WRAPPER_RELOAD_FILE CLAUDE_WRAPPER_RELOAD_CMD
    "${launcher[@]}" "${original_args[@]}"
    return
  fi

  local marker_dir marker
  marker_dir="$(reload_marker_dir)"
  if ! mkdir -p "${marker_dir}" || ! chmod 700 "${marker_dir}"; then
    log_warn "Could not create reload marker directory ${marker_dir}; /reload is unavailable"
    unset CLAUDE_WRAPPER_PID CLAUDE_WRAPPER_RELOAD_FILE CLAUDE_WRAPPER_RELOAD_CMD
    "${launcher[@]}" "${original_args[@]}"
    return
  fi
  # BASHPID, not $$: in a subshell $$ is the parent, and the requester would
  # signal the wrong PID
  marker="${marker_dir}/${BASHPID}"
  rm -f "${marker}" # a stale marker from a reused PID must not trigger a loop

  export CLAUDE_WRAPPER_PID="${BASHPID}"
  export CLAUDE_WRAPPER_RELOAD_FILE="${marker}"
  # The /reload skill finds the requester here, with no PATH entry
  export CLAUDE_WRAPPER_RELOAD_CMD="${WRAPPER_DIR:-$(dirname "${BASH_SOURCE[0]}")/../bin}/claude-reload"

  # Stop a session that reloads as soon as it starts from looping forever
  local min_seconds="${CLAUDE_RELOAD_MIN_SECONDS:-10}"
  local max_quick_reloads=3 quick_reloads=0

  local -a args=("${original_args[@]}")
  local rc session_id started
  while true; do
    started="${SECONDS}"
    # `if` keeps set -e from exiting the wrapper on a non-zero claude exit
    if "${launcher[@]}" "${args[@]}"; then rc=0; else rc=$?; fi

    if ! session_id="$(reload_consume_marker "${marker}")"; then
      return "${rc}"
    fi

    if ((SECONDS - started < min_seconds)); then
      ((quick_reloads += 1))
    else
      quick_reloads=0
    fi
    if ((quick_reloads >= max_quick_reloads)); then
      log_error "Stopped after ${quick_reloads} reloads in a row within ${min_seconds}s of launch; not relaunching"
      return "${rc}"
    fi

    reload_base_args "${original_args[@]}"
    local prompt="${CLAUDE_RELOAD_PROMPT-Claude Code restarted via /reload and the restart is complete. Do not run /reload again. Continue where you left off.}"
    if [[ "${session_id}" == "new" ]]; then
      # Nothing to resume or continue, so no prompt either
      args=("${RELOAD_BASE_ARGS[@]}")
      prompt=""
    elif [[ -n "${session_id}" ]]; then
      args=("${RELOAD_BASE_ARGS[@]}" --resume "${session_id}")
    else
      args=("${RELOAD_BASE_ARGS[@]}" --continue)
    fi
    [[ -n "${prompt}" ]] && args+=("${prompt}")

    echo "Reloading Claude Code (exit ${rc})..." >&2
    debug_log "Relaunching with ${#args[@]} args"
    # Claude can still be releasing the terminal when the wrapper sees it exit
    sleep 0.5
  done
}
