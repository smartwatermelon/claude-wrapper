#!/usr/bin/env bash
# Launch directory check for claude-wrapper
# Warns when launched from $HOME or $HOME/Developer exactly (not subdirectories)
# Requires: lib/logging.sh must be sourced first

# Warn if CWD is exactly $HOME or $HOME/Developer.
# Both paths have their own project entries in ~/.claude/.claude.json holding
# local-scope MCP servers that load unexpectedly, and neither is a git repo,
# so get_git_root returns empty, run_pre_launch_hook never fires, and
# per-project secrets injection is skipped. This is informational only and
# never blocks launch.
# Arguments: $1 = current working directory (optional, defaults to $PWD)
check_launch_dir() {
  local cwd="${1:-${PWD}}"

  if [[ "${cwd}" != "${HOME}" && "${cwd}" != "${HOME}/Developer" ]]; then
    debug_log "Launch directory ${cwd} is not \$HOME or \$HOME/Developer, skipping warning"
    return 0
  fi

  log_warn "Launching from ${cwd} — this is not a project directory."
  log_warn "(a) No per-project secrets or pre-launch hook will run from here."
  log_warn "(b) ${HOME}/.claude/.claude.json has an accumulated custom MCP server surface for this directory that will load."
  log_warn "(c) For multi-repo work, use --add-dir instead of launching from a parent directory."
  log_warn "Proceeding anyway — this warning is informational only."

  return 0
}
