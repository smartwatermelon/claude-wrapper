#!/usr/bin/env bash
# credentials.sh — inject CCCLI credentials from 1Password at wrapper launch
#
# Fetches OP_SERVICE_ACCOUNT_TOKEN from macOS Keychain and GH_TOKEN from the
# Automation vault. Both are exported into the wrapper process and inherited
# by everything it launches, including the agent's own shell — they are not
# present in the user's login shell, but they ARE visible to child processes.
#
# If the vault fetch fails, GH_TOKEN is set to a deliberately invalid sentinel
# rather than left unset, so gh fails closed instead of falling back to the
# keyring OAuth token (which holds admin:org). See _load_gh_token.
#
# Requires: lib/logging.sh must be sourced first.
# Must be sourced before lib/secrets-loader.sh (which needs OP_SERVICE_ACCOUNT_TOKEN).

# Source guard — avoid "readonly variable" errors if sourced twice.
[[ -n "${_CREDENTIALS_SH_LOADED:-}" ]] && return 0
readonly _CREDENTIALS_SH_LOADED=1

# =========================================================
# CONFIGURATION
# =========================================================
readonly _CREDS_KEYCHAIN_SERVICE="op-service-account-claude-automation"

# GH_TOKEN is selected per GitHub resource owner, not fixed. A fine-grained PAT
# is bound to exactly one resource owner at creation and cannot be repointed
# afterward, so covering three owners requires three tokens. The 2026-09 org
# migration moved repos out from under the personal token, which is why a
# single ref stopped working — see issue #120.
#
# The personal ref is also the fallback for "owner unknown" (not a git repo, no
# remote, or a non-GitHub remote), which preserves the pre-#120 behavior for
# sessions launched outside a repo.
readonly _CREDS_GH_TOKEN_REF_PERSONAL="op://Automation/GitHub - CCCLI/Token"
readonly _CREDS_GH_TOKEN_REF_SMARTWATERMELON="op://Automation/CCCLI-SWM/token"
readonly _CREDS_GH_TOKEN_REF_NIGHTOWLSTUDIOLLC="op://Automation/CCCLI-NOS/token"

# Sentinel exported when the vault fetch fails, so gh fails closed instead of
# falling back to the keyring OAuth token. Must be non-empty (an empty value
# would re-enable the keyring fallback) and must not be a valid credential.
readonly _CREDS_GH_TOKEN_FETCH_FAILED="invalid-cccli-token-vault-fetch-failed"

# Computed once so both credential-fetch functions below don't each re-run
# `command -v timeout` on every invocation.
_CREDS_HAS_TIMEOUT=false
command -v timeout &>/dev/null && _CREDS_HAS_TIMEOUT=true
readonly _CREDS_HAS_TIMEOUT

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

  if ! command -v security &>/dev/null; then
    debug_log "security command not available (non-macOS), skipping Keychain lookup"
    return 0
  fi

  local token
  if "${_CREDS_HAS_TIMEOUT}"; then
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
# Derive the GitHub resource owner from a directory's origin remote.
#
# Prints the owner on stdout, or nothing when it cannot be determined: not a
# git repo, no origin remote, or a remote that is not GitHub. Callers treat
# empty as "use the personal token."
#
# Parsed by prefix match rather than a sed substitution. A non-matching sed
# expression passes its input through unchanged, so a GitLab remote would
# yield the entire URL as the "owner" — harmless at the case statement, but it
# would print a URL into the debug log where an owner name belongs. Explicit
# prefixes also handle ssh://git@github.com/owner/repo, which the scp-style
# pattern alone does not match.
_creds_github_owner_for_dir() {
  local dir="$1" url owner

  url="$(git -C "${dir}" remote get-url origin 2>/dev/null)" || return 0
  [[ -z "${url}" ]] && return 0

  case "${url}" in
    git@github.com:*) owner="${url#git@github.com:}" ;;
    ssh://git@github.com/*) owner="${url#ssh://git@github.com/}" ;;
    https://github.com/*) owner="${url#https://github.com/}" ;;
    *) return 0 ;;
  esac

  owner="${owner%%/*}"
  # Reject anything that is not a plausible GitHub login, so a malformed
  # remote cannot inject arbitrary text into the debug log or the case below.
  [[ "${owner}" =~ ^[A-Za-z0-9._-]+$ ]] || return 0

  printf '%s' "${owner}"
}

# Map a resource owner to its vault item. Unknown owners fall back to the
# personal token, which is correct for twistedmelonman repos and fails loudly
# with a permissions error for anything else — preferable to silently trying a
# token that cannot work.
_creds_gh_token_ref_for_owner() {
  case "$1" in
    smartwatermelon) printf '%s' "${_CREDS_GH_TOKEN_REF_SMARTWATERMELON}" ;;
    nightowlstudiollc) printf '%s' "${_CREDS_GH_TOKEN_REF_NIGHTOWLSTUDIOLLC}" ;;
    *) printf '%s' "${_CREDS_GH_TOKEN_REF_PERSONAL}" ;;
  esac
}

# Read one vault reference, with bounded retries. Prints the token on stdout
# and returns 1 if every attempt failed. Callers decide what a failure means;
# this function never exports anything and never logs the value.
_creds_read_token_ref() {
  local token_ref="$1"
  local token
  local -a backoff=(2 4 8)
  local wait_secs

  if "${_CREDS_HAS_TIMEOUT}"; then
    for wait_secs in "${backoff[@]}"; do
      token="$(timeout "${wait_secs}" op read "${token_ref}" 2>/dev/null || true)"
      if [[ -n "${token}" ]]; then
        printf '%s' "${token}"
        return 0
      fi
      debug_log "op read failed (timeout ${wait_secs}s)"
    done
  else
    # No timeout command available to bound each attempt, so retrying would
    # only multiply the hang risk (an unbounded op read blocks forever on
    # the first try, making retries unreachable) with no upside. Attempt
    # exactly once instead of the usual backoff loop.
    debug_log "timeout command unavailable, skipping retries (single attempt only)"
    token="$(op read "${token_ref}" 2>/dev/null || true)"
    if [[ -n "${token}" ]]; then
      printf '%s' "${token}"
      return 0
    fi
    debug_log "op read failed (no timeout available)"
  fi

  return 1
}

# Fetch GH_TOKEN from Automation vault via service account.
# Only runs if OP_SERVICE_ACCOUNT_TOKEN is available.
# GH_TOKEN is the restricted-scope CCCLI PAT, separate from the
# personal token in gh's keyring.
_load_gh_token() {
  # A previously-exported failure sentinel is not a real token: treat it as
  # unset so a retry can still reach the vault rather than being skipped.
  if [[ -n "${GH_TOKEN:-}" && "${GH_TOKEN}" != "${_CREDS_GH_TOKEN_FETCH_FAILED}" ]]; then
    debug_log "GH_TOKEN already set, skipping vault lookup"
    return 0
  fi

  if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
    debug_log "Skipping GH_TOKEN fetch: OP_SERVICE_ACCOUNT_TOKEN not available"
    return 0
  fi

  local token owner token_ref

  # ${PWD} is the user's launch directory: bin/claude-wrapper never changes
  # directory before sourcing this file, so the cwd it inherits is the one the
  # session was started from.
  owner="$(_creds_github_owner_for_dir "${PWD}")"
  token_ref="$(_creds_gh_token_ref_for_owner "${owner}")"
  debug_log "GitHub owner: ${owner:-<none>} -> token ref: ${token_ref}"

  if token="$(_creds_read_token_ref "${token_ref}")"; then
    export GH_TOKEN="${token}"
    debug_log "GH_TOKEN loaded from Automation vault (${token_ref})"
  else
    # Fail closed. Leaving GH_TOKEN unset makes gh fall back to the user's
    # keyring OAuth token, which carries repo/workflow/admin:org/delete_repo —
    # far wider than the restricted CCCLI PAT this function exists to inject.
    # A transient op failure (locked vault, missing service account token,
    # network blip, backoff exhausted) must not silently upgrade the agent's
    # GitHub privileges. Export a deliberately invalid sentinel instead: gh
    # then fails with a clear auth error rather than quietly succeeding with
    # more access than intended.
    export GH_TOKEN="${_CREDS_GH_TOKEN_FETCH_FAILED}"
    log_warn "Failed to fetch GH_TOKEN from 1Password — gh disabled for this session (keyring fallback deliberately blocked)"
  fi
  unset token
}

# Load every owner's token as GH_TOKEN_<SUFFIX>, so a session can act for an
# owner other than the one its launch directory happens to name.
#
# A fine-grained PAT is bound to one resource owner at creation, so no single
# token can cover the fleet: reading an org's repos with the personal token
# fails 403 on protection and 404 on the repo itself, whether that repo is
# public or private — the boundary is ownership, not visibility. Selecting one
# token per session (above) therefore guarantees the wrong credential for any
# cross-owner work, which fleet probes and rollouts are by definition.
#
# Fetched once at launch rather than per use. A 42-repo probe would otherwise
# mean dozens of vault reads, making the correct path slower than the keyring
# fallback it replaces — which is how workarounds get entrenched.
#
# These are additive: GH_TOKEN keeps its launch-directory selection, so nothing
# that reads it changes. See claude-wrapper#126 for the eventual target, where
# gh-wrapper.sh selects among these per invocation from the target repo's owner.
_load_owner_gh_tokens() {
  if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
    debug_log "Skipping per-owner token fetch: OP_SERVICE_ACCOUNT_TOKEN not available"
    return 0
  fi

  local spec var token_ref token loaded=0
  # var:ref pairs. The refs are the same constants _load_gh_token selects from.
  local -a specs=(
    "GH_TOKEN_SWM:${_CREDS_GH_TOKEN_REF_SMARTWATERMELON}"
    "GH_TOKEN_NOS:${_CREDS_GH_TOKEN_REF_NIGHTOWLSTUDIOLLC}"
    "GH_TOKEN_TWM:${_CREDS_GH_TOKEN_REF_PERSONAL}"
  )

  for spec in "${specs[@]}"; do
    var="${spec%%:*}"
    token_ref="${spec#*:}"

    # Respect a value already in the environment, matching _load_gh_token.
    if [[ -n "${!var:-}" && "${!var}" != "${_CREDS_GH_TOKEN_FETCH_FAILED}" ]]; then
      debug_log "${var} already set, skipping vault lookup"
      ((loaded += 1))
      continue
    fi

    if token="$(_creds_read_token_ref "${token_ref}")"; then
      export "${var}=${token}"
      debug_log "${var} loaded from Automation vault (${token_ref})"
      ((loaded += 1))
    else
      # Same fail-closed reasoning as GH_TOKEN: a caller that substitutes an
      # empty value would fall through to the keyring OAuth token, silently
      # widening scope. The sentinel makes gh fail with an auth error instead.
      export "${var}=${_CREDS_GH_TOKEN_FETCH_FAILED}"
      log_warn "Failed to fetch ${var} from 1Password — cross-owner gh calls for that owner will fail closed"
    fi
    unset token
  done

  debug_log "Per-owner tokens available: ${loaded}/${#specs[@]}"
}

# =========================================================
# MAIN
# =========================================================
_load_service_account_token
_load_gh_token
_load_owner_gh_tokens
