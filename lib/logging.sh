#!/usr/bin/env bash
# Logging utilities for claude-wrapper
# Provides debug, error, and warning logging functions

# Debug mode (set CLAUDE_DEBUG=true for verbose output)
DEBUG="${CLAUDE_DEBUG:-false}"

# Debug logging - only outputs when CLAUDE_DEBUG=true
debug_log() {
  if [[ "${DEBUG}" == "true" ]]; then
    echo "DEBUG: $*" >&2
  fi
}

# Error logging - always outputs to stderr
log_error() {
  echo "ERROR: $*" >&2
}

# Warning logging - always outputs to stderr
log_warn() {
  echo "WARNING: $*" >&2
}

# Alias for backward compatibility with pre-launch scripts
warn_log() {
  log_warn "$@"
}
