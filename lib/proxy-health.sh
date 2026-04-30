#!/usr/bin/env bash
# Headroom proxy health check for claude-wrapper
# If ANTHROPIC_BASE_URL points at a localhost proxy that isn't responding,
# unset it so the session falls back to talking to Anthropic directly.
# Requires: lib/logging.sh must be sourced first.

# Always returns 0 — never aborts the wrapper, even under set -e.
check_proxy_health() {
  local url="${ANTHROPIC_BASE_URL:-}"

  if [[ -z "${url}" ]]; then
    return 0
  fi

  if [[ ! "${url}" =~ ^https?://(localhost|127\.0\.0\.1)(:|/|$) ]]; then
    debug_log "ANTHROPIC_BASE_URL is non-local (${url}); skipping proxy health check"
    return 0
  fi

  if ! command -v curl &>/dev/null; then
    debug_log "curl not available; skipping proxy health check"
    return 0
  fi

  local health_url="${url%/}/health"

  if curl --silent --fail --max-time 1 "${health_url}" >/dev/null 2>&1; then
    debug_log "Headroom proxy healthy at ${url}"
    return 0
  fi

  log_warn "Headroom proxy at ${url} is not responding to ${health_url}"
  log_warn "Unsetting ANTHROPIC_BASE_URL — session will talk to Anthropic directly"
  unset ANTHROPIC_BASE_URL
  return 0
}
