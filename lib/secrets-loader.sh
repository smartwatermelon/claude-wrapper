#!/usr/bin/env bash
# 1Password secrets loader for claude-wrapper
# Handles secrets file discovery, validation, and injection
# Requires: lib/logging.sh, lib/permissions.sh, lib/path-security.sh must be sourced first

# 1Password secrets configuration
readonly CLAUDE_OP_GLOBAL_SECRETS="${HOME}/.config/claude-code/secrets.op"
readonly CLAUDE_OP_PROJECT_SECRETS=".claude/secrets.op"
readonly CLAUDE_OP_LOCAL_SECRETS=".claude/secrets.local.op"

# State variables
OP_ENABLED=false
OP_ENV_ARGS=()
SKIP_OP_AUTH=false
GIT_ROOT=""

# Normalize env file by quoting unquoted values
# This ensures values with special characters (like \n in private keys) pass safety checks
normalize_env_file() {
  local input_file="$1"
  local output_file="$2"
  local line key value

  while IFS= read -r line || [[ -n "${line}" ]]; do
    # Skip blank lines and comments
    if [[ -z "${line}" ]] || [[ "${line}" =~ ^[[:space:]]*# ]]; then
      echo "${line}"
      continue
    fi

    # Match KEY=value pattern
    if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"

      # If already quoted (starts and ends with matching quotes), pass through
      if [[ "${value}" =~ ^\".*\"$ ]] || [[ "${value}" =~ ^\'.*\'$ ]]; then
        echo "${line}"
      else
        # Wrap in single quotes, escaping any internal single quotes
        value="${value//\'/\'\\\'\'}"
        echo "${key}='${value}'"
      fi
    else
      # Non-assignment lines pass through unchanged
      echo "${line}"
    fi
  done <"${input_file}" >"${output_file}"
}

# Validate env file content - simple sanity checks
# Catches corruption, malformed lines, and obvious injection attempts
# We trust normalize_env_file output, so this is defense-in-depth, not primary security
validate_env_content() {
  local file="$1"
  local line_num=0
  local line

  while IFS= read -r line || [[ -n "${line}" ]]; do
    ((line_num += 1))

    # Skip empty lines and comments
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*$ ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue

    # Must be VAR=something format
    if ! [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      debug_log "Line ${line_num}: not a valid assignment"
      return 1
    fi

    # Extract value part
    local value="${line#*=}"

    # Reject command substitution patterns - primary injection vector
    # Single-quoted values can't execute these, but double-quoted can
    if [[ "${value}" =~ \$\( ]] || [[ "${value}" =~ \`.*\` ]]; then
      debug_log "Line ${line_num}: contains command substitution pattern"
      return 1
    fi

  done <"${file}"

  return 0
}

# Validate secrets file with path canonicalization
validate_secrets_file() {
  local file="$1"
  local canonical

  if [[ ! -f "${file}" ]]; then
    return 1
  fi

  # Canonicalize path to prevent traversal
  if ! canonical="$(canonicalize_path "${file}")"; then
    return 1
  fi
  if [[ -z "${canonical}" ]]; then
    return 1
  fi

  if [[ ! -r "${canonical}" ]]; then
    log_error "Cannot read ${canonical}"
    return 1
  fi

  # Ensure secure permissions (warns and auto-fixes if needed)
  if ! ensure_secure_permissions "${canonical}" "400"; then
    log_error "Refusing to load secrets from ${canonical} due to permission issues"
    return 1
  fi

  # Return canonical path via stdout for caller to use
  echo "${canonical}"
  return 0
}

# Detect non-interactive/automated contexts where 1Password should be skipped
detect_op_skip_conditions() {
  SKIP_OP_AUTH=false

  # Check for explicit skip flag
  if [[ "${CLAUDE_SKIP_OP_AUTH:-false}" == "true" ]]; then
    SKIP_OP_AUTH=true
    debug_log "1Password auth skipped: CLAUDE_SKIP_OP_AUTH=true"
    return
  fi

  # Check if stdin is NOT a TTY (non-interactive context)
  if [[ ! -t 0 ]]; then
    SKIP_OP_AUTH=true
    debug_log "1Password auth skipped: stdin is not a TTY (non-interactive context)"
    return
  fi

  # Additional checks for CI environments that may allocate PTYs
  if [[ "${CI:-false}" == "true" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]] || [[ -n "${GITLAB_CI:-}" ]]; then
    SKIP_OP_AUTH=true
    debug_log "1Password auth skipped: running in CI environment"
    return
  fi
}

# Check for secrets files before authenticating
check_secrets_files_exist() {
  local has_secrets=false

  # Check global secrets
  if [[ -f "${CLAUDE_OP_GLOBAL_SECRETS}" ]]; then
    has_secrets=true
    debug_log "Found global secrets file: ${CLAUDE_OP_GLOBAL_SECRETS}"
  fi

  # Check project/local secrets (if in a git repo)
  if git rev-parse --git-dir &>/dev/null; then
    local git_root_check
    git_root_check="$(git rev-parse --show-toplevel 2>/dev/null)"
    if [[ -n "${git_root_check}" ]]; then
      if [[ -f "${git_root_check}/${CLAUDE_OP_PROJECT_SECRETS}" ]]; then
        has_secrets=true
        debug_log "Found project secrets file: ${git_root_check}/${CLAUDE_OP_PROJECT_SECRETS}"
      fi
      if [[ -f "${git_root_check}/${CLAUDE_OP_LOCAL_SECRETS}" ]]; then
        has_secrets=true
        debug_log "Found local secrets file: ${git_root_check}/${CLAUDE_OP_LOCAL_SECRETS}"
      fi
    fi
  fi

  [[ "${has_secrets}" == "true" ]]
}

# Initialize 1Password and discover secrets files
init_secrets_loader() {
  detect_op_skip_conditions
  OP_ENABLED=false
  OP_ENV_ARGS=()
  GIT_ROOT=""

  if ! command -v op &>/dev/null; then
    debug_log "1Password CLI not found in PATH"
    return 0
  fi

  if [[ "${SKIP_OP_AUTH}" == "true" ]]; then
    debug_log "1Password authentication skipped (automated/non-interactive context)"
    return 0
  fi

  local op_version
  op_version="$(op --version 2>/dev/null)" || op_version="unknown"
  debug_log "1Password CLI detected (version: ${op_version})"

  # Check if any secrets files exist before prompting for auth
  if ! check_secrets_files_exist; then
    debug_log "No secrets files found, skipping 1Password authentication"
    return 0
  fi

  # Authenticate with 1Password
  echo "[Claude wrapper] Checking 1Password authentication..." >&2

  if ! op account get &>/dev/null; then
    debug_log "No active 1Password session, attempting signin..."
    op signin || true
  fi

  # Check if we have a valid session
  if ! op account get &>/dev/null; then
    log_warn "1Password authentication failed or cancelled - continuing without secrets"
    debug_log "No active 1Password session, proceeding without secrets"
    return 0
  fi

  debug_log "1Password session active"

  # Discover and validate secrets files
  local validated_path

  # Global secrets (always absolute path, safe)
  if validated_path="$(validate_secrets_file "${CLAUDE_OP_GLOBAL_SECRETS}")"; then
    OP_ENV_ARGS+=(--env-file="${validated_path}")
    debug_log "Added global secrets (validated)"
  fi

  # Project secrets - only load if we're in a git repository
  if git rev-parse --git-dir &>/dev/null; then
    local git_root_raw
    git_root_raw="$(git rev-parse --show-toplevel 2>/dev/null)"
    if [[ -n "${git_root_raw}" ]]; then
      # Canonicalize git root to handle symlinks
      GIT_ROOT="$(realpath "${git_root_raw}" 2>/dev/null || echo "${git_root_raw}")"

      local project_secrets="${GIT_ROOT}/${CLAUDE_OP_PROJECT_SECRETS}"
      if validated_path="$(validate_secrets_file "${project_secrets}")"; then
        if path_is_under "${validated_path}" "${GIT_ROOT}"; then
          OP_ENV_ARGS+=(--env-file="${validated_path}")
          debug_log "Added project secrets (validated)"
        else
          log_error "Project secrets path escapes git repository, refusing to load"
        fi
      fi

      local local_secrets="${GIT_ROOT}/${CLAUDE_OP_LOCAL_SECRETS}"
      if validated_path="$(validate_secrets_file "${local_secrets}")"; then
        if path_is_under "${validated_path}" "${GIT_ROOT}"; then
          OP_ENV_ARGS+=(--env-file="${validated_path}")
          debug_log "Added local secrets (validated)"
        else
          log_error "Local secrets path escapes git repository, refusing to load"
        fi
      fi
    fi
  else
    debug_log "Not in a git repository, skipping project/local secrets"
  fi

  # Enable 1Password if we have at least one secrets file
  if [[ ${#OP_ENV_ARGS[@]} -gt 0 ]]; then
    OP_ENABLED=true
    debug_log "1Password enabled with ${#OP_ENV_ARGS[@]} secrets file(s)"
  else
    debug_log "No secrets files found, 1Password disabled"
  fi

  return 0
}

# Inject secrets from all discovered files
# Must be called after init_secrets_loader and only if OP_ENABLED=true
inject_secrets() {
  if [[ "${OP_ENABLED}" != "true" ]]; then
    debug_log "1Password not enabled, skipping secrets injection"
    return 0
  fi

  debug_log "Loading secrets from ${#OP_ENV_ARGS[@]} file(s)"

  # Extract file paths from --env-file=path arguments
  declare -a secret_files=()
  for arg in "${OP_ENV_ARGS[@]}"; do
    secret_files+=("${arg#--env-file=}")
  done

  # Create temp directory with restrictive permissions (only current user can access)
  local temp_dir
  temp_dir="$(mktemp -d)" || {
    log_error "Failed to create temp directory for secret resolution"
    return 1
  }
  chmod 700 "${temp_dir}"

  # Process each secrets file using op inject
  for secrets_file in "${secret_files[@]}"; do
    debug_log "Injecting secrets from: ${secrets_file}"

    if [[ ! -r "${secrets_file}" ]]; then
      log_error "Cannot read secrets file: ${secrets_file}"
      rm -rf "${temp_dir}"
      return 1
    fi

    # Strip comments before passing to op inject
    local stripped_file
    stripped_file="${temp_dir}/stripped-$(basename "${secrets_file}")"
    grep -v '^[[:space:]]*#' "${secrets_file}" >"${stripped_file}" || true

    # Create temp file for resolved secrets
    local resolved_file
    resolved_file="${temp_dir}/resolved-$(basename "${secrets_file}")"

    # Inject 1Password references (suppress stderr to avoid leaking reference names)
    if ! op inject --in-file="${stripped_file}" --out-file="${resolved_file}" 2>/dev/null; then
      log_error "Failed to inject secrets from ${secrets_file} - check 1Password references"
      rm -rf "${temp_dir}"
      return 1
    fi

    # Normalize resolved file: quote unquoted values
    local normalized_file
    normalized_file="${temp_dir}/normalized-$(basename "${secrets_file}")"
    normalize_env_file "${resolved_file}" "${normalized_file}"
    mv "${normalized_file}" "${resolved_file}"

    # Validate resolved file - simple checks for obvious problems
    # We trust normalize_env_file output, but catch corruption/malformed content
    if ! validate_env_content "${resolved_file}"; then
      log_error "Resolved secrets file contains invalid content: ${secrets_file}"
      rm -rf "${temp_dir}"
      return 1
    fi

    # Source the resolved env file with proper variable export
    # Note: SC1090 disabled - file is generated by normalize_env_file and validated
    set -a
    # shellcheck disable=SC1090
    if ! source "${resolved_file}"; then
      log_error "Failed to source resolved secrets from ${secrets_file}"
      set +a
      rm -rf "${temp_dir}"
      return 1
    fi
    set +a

    debug_log "Loaded secrets from ${secrets_file}"
  done

  # Clean up temp directory
  rm -rf "${temp_dir}"
  return 0
}

# Get the discovered git root (set by init_secrets_loader)
get_git_root() {
  echo "${GIT_ROOT}"
}

# Check if secrets are available
secrets_available() {
  [[ "${OP_ENABLED}" == "true" ]]
}
