#!/usr/bin/env bash
# credentials.sh — inject CCCLI credentials from 1Password at wrapper launch
#
# Fetches OP_SERVICE_ACCOUNT_TOKEN from macOS Keychain and GH_TOKEN from the
# Automation vault. Both are scoped to the wrapper process lifetime only —
# they are not present in the interactive shell environment.
#
# Requires: lib/logging.sh must be sourced first.
# Must be sourced before lib/secrets-loader.sh (which needs OP_SERVICE_ACCOUNT_TOKEN).

# =========================================================
# CONFIGURATION
# =========================================================
readonly _CREDS_KEYCHAIN_SERVICE="op-service-account-claude-automation"
readonly _CREDS_GH_TOKEN_REF="op://Automation/GitHub - CCCLI/Token"

# =========================================================
# SERVICE ACCOUNT TOKEN
# =========================================================
# Fetch from Keychain into the wrapper environment. Uses timeout guard
# to prevent Keychain hangs from stalling CCCLI startup. id -un is more
# robust than $USER which can be unset or spoofed.
_load_service_account_token() {
  if [[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
    debug_log "OP_SERVICE_ACCOUNT_TOKEN already set, skipping Keychain lookup"
    return 0
  fi

  local token
  if command -v timeout &>/dev/null; then
    token="$(timeout 3 security find-generic-password \
      -a "$(id -un)" \
      -s "${_CREDS_KEYCHAIN_SERVICE}" \
      -w 2>/dev/null || true)"
  else
    token="$(security find-generic-password \
      -a "$(id -un)" \
      -s "${_CREDS_KEYCHAIN_SERVICE}" \
      -w 2>/dev/null || true)"
  fi

  if [[ -n "${token}" ]]; then
    export OP_SERVICE_ACCOUNT_TOKEN="${token}"
    debug_log "OP_SERVICE_ACCOUNT_TOKEN loaded from Keychain"
  else
    local current_user
    current_user="$(id -un)"
    log_warn "1Password service account token not found in Keychain — op inject will not work"
    debug_log "Keychain service: ${_CREDS_KEYCHAIN_SERVICE}, account: ${current_user}"
  fi
  unset token
}

# =========================================================
# GITHUB TOKEN
# =========================================================
# Fetch GH_TOKEN from Automation vault via service account.
# Only runs if OP_SERVICE_ACCOUNT_TOKEN is available.
# GH_TOKEN is the restricted-scope CCCLI PAT, separate from the
# personal token in gh's keyring.
_load_gh_token() {
  if [[ -n "${GH_TOKEN:-}" ]]; then
    debug_log "GH_TOKEN already set, skipping vault lookup"
    return 0
  fi

  if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
    debug_log "Skipping GH_TOKEN fetch: OP_SERVICE_ACCOUNT_TOKEN not available"
    return 0
  fi

  local token
  token="$(op read "${_CREDS_GH_TOKEN_REF}" 2>/dev/null || true)"

  if [[ -n "${token}" ]]; then
    export GH_TOKEN="${token}"
    debug_log "GH_TOKEN loaded from Automation vault"
  else
    log_warn "Failed to fetch GH_TOKEN from 1Password — gh CLI will use keyring fallback"
  fi
  unset token
}

# =========================================================
# MAIN
# =========================================================
_load_service_account_token
_load_gh_token
