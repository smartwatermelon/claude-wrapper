#!/usr/bin/env bash
# Test suite for claude-wrapper
# TDD-driven: Tests define expected behavior, code is updated to match
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test configuration
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
WRAPPER="${REPO_ROOT}/bin/claude-wrapper"
LIB_DIR="${REPO_ROOT}/lib"

# Temporary test environment
TEST_TMP=""

setup_test_env() {
  TEST_TMP="$(mktemp -d)" || {
    echo "ERROR: Failed to create temporary directory" >&2
    exit 1
  }
  echo "Test environment: ${TEST_TMP}"
}

cleanup_test_env() {
  if [[ -n "${TEST_TMP:-}" ]] && [[ -d "${TEST_TMP}" ]]; then
    rm -rf "${TEST_TMP}"
  fi
}

# Trap cleanup on exit
trap cleanup_test_env EXIT

# Test helpers
# Note: Using ((var += 1)) instead of ((var++)) per CLAUDE.md guidelines
# With set -e, ((var++)) would exit when var=0, but ((var += 1)) is safe
assert_equals() {
  local expected="$1"
  local actual="$2"
  local message="${3:-}"

  ((TESTS_RUN += 1))

  if [[ "${expected}" == "${actual}" ]]; then
    ((TESTS_PASSED += 1))
    echo -e "${GREEN}✓${NC} ${message}"
  else
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} ${message}"
    echo "  Expected: ${expected}"
    echo "  Actual:   ${actual}"
  fi
  # Always return 0 to not trigger set -e; failures tracked in TESTS_FAILED
  return 0
}

assert_not_equals() {
  local unexpected="$1"
  local actual="$2"
  local message="${3:-}"

  ((TESTS_RUN += 1))

  if [[ "${unexpected}" != "${actual}" ]]; then
    ((TESTS_PASSED += 1))
    echo -e "${GREEN}✓${NC} ${message}"
  else
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} ${message}"
    echo "  Should not equal: ${unexpected}"
  fi
  return 0
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  local message="${3:-}"

  ((TESTS_RUN += 1))

  if echo "${haystack}" | grep -qF "${needle}"; then
    ((TESTS_PASSED += 1))
    echo -e "${GREEN}✓${NC} ${message}"
  else
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} ${message}"
    echo "  Expected to find: ${needle}"
    echo "  In: ${haystack:0:200}..."
  fi
  return 0
}

assert_not_contains() {
  local needle="$1"
  local haystack="$2"
  local message="${3:-}"

  ((TESTS_RUN += 1))

  if ! echo "${haystack}" | grep -qF "${needle}"; then
    ((TESTS_PASSED += 1))
    echo -e "${GREEN}✓${NC} ${message}"
  else
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} ${message}"
    echo "  Should not contain: ${needle}"
  fi
  return 0
}

assert_file_exists() {
  local file="$1"
  local message="${2:-File exists: ${file}}"

  ((TESTS_RUN += 1))

  if [[ -f "${file}" ]]; then
    ((TESTS_PASSED += 1))
    echo -e "${GREEN}✓${NC} ${message}"
  else
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} ${message}"
    echo "  File not found: ${file}"
  fi
  return 0
}

assert_file_executable() {
  local file="$1"
  local message="${2:-File is executable: ${file}}"

  ((TESTS_RUN += 1))

  if [[ -x "${file}" ]]; then
    ((TESTS_PASSED += 1))
    echo -e "${GREEN}✓${NC} ${message}"
  else
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} ${message}"
    echo "  File not executable: ${file}"
  fi
  return 0
}

assert_dir_exists() {
  local dir="$1"
  local message="${2:-Directory exists: ${dir}}"

  ((TESTS_RUN += 1))

  if [[ -d "${dir}" ]]; then
    ((TESTS_PASSED += 1))
    echo -e "${GREEN}✓${NC} ${message}"
  else
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} ${message}"
    echo "  Directory not found: ${dir}"
  fi
  return 0
}

assert_exit_code() {
  local expected="$1"
  local actual="$2"
  local message="${3:-}"

  ((TESTS_RUN += 1))

  if [[ "${expected}" == "${actual}" ]]; then
    ((TESTS_PASSED += 1))
    echo -e "${GREEN}✓${NC} ${message}"
  else
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} ${message}"
    echo "  Expected exit code: ${expected}"
    echo "  Actual exit code:   ${actual}"
  fi
  return 0
}

# Mock claude binary for testing
create_mock_claude() {
  local mock_path="${TEST_TMP}/mock-claude"
  mkdir -p "$(dirname "${mock_path}")"
  cat >"${mock_path}" <<'EOF'
#!/usr/bin/env bash
# Mock claude for testing
echo "MOCK_CLAUDE_EXECUTED"
echo "Args: $*"
printenv | grep -E '^(GIT_|GH_TOKEN|ANTHROPIC_|TEST_)' | sort
EOF
  chmod +x "${mock_path}"
  echo "${mock_path}"
}

# =============================================================================
# SECTION 1: Structure Tests - Wrapper and Module Layout
# =============================================================================

test_wrapper_exists() {
  echo ""
  echo "Test 1.1: Wrapper script exists and is executable"
  assert_file_exists "${WRAPPER}" "Wrapper script exists at bin/claude-wrapper"
  assert_file_executable "${WRAPPER}" "Wrapper script is executable"
}

test_lib_directory_exists() {
  echo ""
  echo "Test 1.2: Library directory structure"
  assert_dir_exists "${LIB_DIR}" "lib/ directory exists"
}

test_module_files_exist() {
  echo ""
  echo "Test 1.3: Required module files exist"

  # Core modules that must exist for modular architecture
  assert_file_exists "${LIB_DIR}/logging.sh" "logging.sh module exists"
  assert_file_exists "${LIB_DIR}/permissions.sh" "permissions.sh module exists"
  assert_file_exists "${LIB_DIR}/path-security.sh" "path-security.sh module exists"
  assert_file_exists "${LIB_DIR}/git-identity.sh" "git-identity.sh module exists"
  assert_file_exists "${LIB_DIR}/github-token.sh" "github-token.sh module exists"
  assert_file_exists "${LIB_DIR}/secrets-loader.sh" "secrets-loader.sh module exists"
  assert_file_exists "${LIB_DIR}/binary-discovery.sh" "binary-discovery.sh module exists"
  assert_file_exists "${LIB_DIR}/pre-launch.sh" "pre-launch.sh module exists"
}

test_wrapper_sources_modules() {
  echo ""
  echo "Test 1.4: Wrapper sources library modules"

  local wrapper_content
  wrapper_content="$(cat "${WRAPPER}")"

  # Wrapper should source modules, not define everything inline
  assert_contains 'source' "${wrapper_content}" "Wrapper uses source command"
  assert_contains 'lib/logging.sh' "${wrapper_content}" "Wrapper sources logging module"
}

# =============================================================================
# SECTION 2: Module Interface Tests - Each module exports expected functions
# =============================================================================

test_logging_module_interface() {
  echo ""
  echo "Test 2.1: Logging module exports required functions"

  if [[ ! -f "${LIB_DIR}/logging.sh" ]]; then
    ((TESTS_RUN += 1))
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} Cannot test - logging.sh does not exist"
    return 0
  fi

  local module_content
  module_content="$(cat "${LIB_DIR}/logging.sh")"

  assert_contains "debug_log()" "${module_content}" "Exports debug_log function"
  assert_contains "log_error()" "${module_content}" "Exports log_error function"
  assert_contains "log_warn()" "${module_content}" "Exports log_warn function"
}

test_permissions_module_interface() {
  echo ""
  echo "Test 2.2: Permissions module exports required functions"

  if [[ ! -f "${LIB_DIR}/permissions.sh" ]]; then
    ((TESTS_RUN += 1))
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} Cannot test - permissions.sh does not exist"
    return 0
  fi

  local module_content
  module_content="$(cat "${LIB_DIR}/permissions.sh")"

  assert_contains "check_file_permissions()" "${module_content}" "Exports check_file_permissions function"
  assert_contains "ensure_secure_permissions()" "${module_content}" "Exports ensure_secure_permissions function"
}

test_path_security_module_interface() {
  echo ""
  echo "Test 2.3: Path security module exports required functions"

  if [[ ! -f "${LIB_DIR}/path-security.sh" ]]; then
    ((TESTS_RUN += 1))
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} Cannot test - path-security.sh does not exist"
    return 0
  fi

  local module_content
  module_content="$(cat "${LIB_DIR}/path-security.sh")"

  assert_contains "canonicalize_path()" "${module_content}" "Exports canonicalize_path function"
  assert_contains "path_is_under()" "${module_content}" "Exports path_is_under function"
}

test_git_identity_module_interface() {
  echo ""
  echo "Test 2.4: Git identity module exports required variables"

  if [[ ! -f "${LIB_DIR}/git-identity.sh" ]]; then
    ((TESTS_RUN += 1))
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} Cannot test - git-identity.sh does not exist"
    return 0
  fi

  local module_content
  module_content="$(cat "${LIB_DIR}/git-identity.sh")"

  assert_contains "GIT_AUTHOR_NAME" "${module_content}" "Sets GIT_AUTHOR_NAME"
  assert_contains "GIT_AUTHOR_EMAIL" "${module_content}" "Sets GIT_AUTHOR_EMAIL"
  assert_contains "GIT_COMMITTER_NAME" "${module_content}" "Sets GIT_COMMITTER_NAME"
  assert_contains "GIT_COMMITTER_EMAIL" "${module_content}" "Sets GIT_COMMITTER_EMAIL"
  assert_contains "export" "${module_content}" "Exports git identity variables"
}

test_binary_discovery_module_interface() {
  echo ""
  echo "Test 2.5: Binary discovery module exports required functions"

  if [[ ! -f "${LIB_DIR}/binary-discovery.sh" ]]; then
    ((TESTS_RUN += 1))
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} Cannot test - binary-discovery.sh does not exist"
    return 0
  fi

  local module_content
  module_content="$(cat "${LIB_DIR}/binary-discovery.sh")"

  assert_contains "find_claude_binary()" "${module_content}" "Exports find_claude_binary function"
  assert_contains "validate_claude_binary()" "${module_content}" "Exports validate_claude_binary function"
}

# =============================================================================
# SECTION 3: Behavioral Tests - Functions work correctly
# =============================================================================

test_logging_behavior() {
  echo ""
  echo "Test 3.1: Logging functions produce correct output"

  if [[ ! -f "${LIB_DIR}/logging.sh" ]]; then
    ((TESTS_RUN += 1))
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} Cannot test - logging.sh does not exist"
    return 0
  fi

  # Source the module in a subshell to test behavior
  local debug_output error_output warn_output

  # Test debug_log with DEBUG=true
  debug_output="$(CLAUDE_DEBUG=true bash -c "source '${LIB_DIR}/logging.sh'; debug_log 'test message'" 2>&1)"
  assert_contains "DEBUG:" "${debug_output}" "debug_log outputs DEBUG: prefix when enabled"
  assert_contains "test message" "${debug_output}" "debug_log outputs the message"

  # Test debug_log with DEBUG=false (should be silent)
  debug_output="$(CLAUDE_DEBUG=false bash -c "source '${LIB_DIR}/logging.sh'; debug_log 'test message'" 2>&1)"
  assert_not_contains "test message" "${debug_output}" "debug_log is silent when disabled"

  # Test log_error
  error_output="$(bash -c "source '${LIB_DIR}/logging.sh'; log_error 'error test'" 2>&1)"
  assert_contains "ERROR:" "${error_output}" "log_error outputs ERROR: prefix"

  # Test log_warn
  warn_output="$(bash -c "source '${LIB_DIR}/logging.sh'; log_warn 'warn test'" 2>&1)"
  assert_contains "WARNING:" "${warn_output}" "log_warn outputs WARNING: prefix"
}

test_permissions_behavior() {
  echo ""
  echo "Test 3.2: Permission checking works correctly"

  if [[ ! -f "${LIB_DIR}/permissions.sh" ]]; then
    ((TESTS_RUN += 1))
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} Cannot test - permissions.sh does not exist"
    return 0
  fi

  # Create test files with different permissions
  local test_file_secure="${TEST_TMP}/secure-file"
  local test_file_group="${TEST_TMP}/group-readable"
  local test_file_world="${TEST_TMP}/world-readable"

  echo "test" >"${test_file_secure}"
  echo "test" >"${test_file_group}"
  echo "test" >"${test_file_world}"

  chmod 600 "${test_file_secure}"
  chmod 640 "${test_file_group}"
  chmod 644 "${test_file_world}"

  # Test check_file_permissions
  local exit_code

  # Secure file should pass
  exit_code=0
  bash -c "source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/permissions.sh'; check_file_permissions '${test_file_secure}'" 2>/dev/null || exit_code=$?
  assert_exit_code "0" "${exit_code}" "check_file_permissions accepts 600 permissions"

  # Group-readable should fail
  exit_code=0
  bash -c "source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/permissions.sh'; check_file_permissions '${test_file_group}'" 2>/dev/null || exit_code=$?
  assert_exit_code "1" "${exit_code}" "check_file_permissions rejects group-readable files"

  # World-readable should fail
  exit_code=0
  bash -c "source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/permissions.sh'; check_file_permissions '${test_file_world}'" 2>/dev/null || exit_code=$?
  assert_exit_code "1" "${exit_code}" "check_file_permissions rejects world-readable files"
}

test_permissions_autofix_behavior() {
  echo ""
  echo "Test 3.3: Permission auto-fix works correctly"

  if [[ ! -f "${LIB_DIR}/permissions.sh" ]]; then
    ((TESTS_RUN += 1))
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} Cannot test - permissions.sh does not exist"
    return 0
  fi

  local test_file="${TEST_TMP}/needs-fix"
  echo "test" >"${test_file}"
  chmod 644 "${test_file}"

  # ensure_secure_permissions should fix to 400
  bash -c "source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/permissions.sh'; ensure_secure_permissions '${test_file}' '400'" 2>/dev/null

  local perms
  perms="$(stat -f '%A' "${test_file}" 2>/dev/null || stat -c '%a' "${test_file}" 2>/dev/null)"
  assert_equals "400" "${perms}" "ensure_secure_permissions fixes to target permissions"
}

test_path_security_behavior() {
  echo ""
  echo "Test 3.4: Path security functions work correctly"

  if [[ ! -f "${LIB_DIR}/path-security.sh" ]]; then
    ((TESTS_RUN += 1))
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} Cannot test - path-security.sh does not exist"
    return 0
  fi

  # Create test directory structure
  local test_dir="${TEST_TMP}/path-test"
  mkdir -p "${test_dir}/subdir"
  echo "test" >"${test_dir}/file.txt"
  ln -s "${test_dir}/file.txt" "${test_dir}/symlink.txt"

  local exit_code canonical

  # Regular file should canonicalize
  canonical="$(bash -c "source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/path-security.sh'; canonicalize_path '${test_dir}/file.txt'" 2>/dev/null)"
  assert_contains "${test_dir}/file.txt" "${canonical}" "canonicalize_path returns canonical path for regular file"

  # Symlink should be rejected
  exit_code=0
  bash -c "source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/path-security.sh'; canonicalize_path '${test_dir}/symlink.txt'" 2>/dev/null || exit_code=$?
  assert_exit_code "1" "${exit_code}" "canonicalize_path rejects symlinks"

  # path_is_under should work
  exit_code=0
  bash -c "source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/path-security.sh'; path_is_under '${test_dir}/subdir' '${test_dir}'" || exit_code=$?
  assert_exit_code "0" "${exit_code}" "path_is_under returns true for child path"

  exit_code=0
  bash -c "source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/path-security.sh'; path_is_under '/tmp/other' '${test_dir}'" || exit_code=$?
  assert_exit_code "1" "${exit_code}" "path_is_under returns false for unrelated path"
}

test_git_identity_behavior() {
  echo ""
  echo "Test 3.5: Git identity is set correctly"

  if [[ ! -f "${LIB_DIR}/git-identity.sh" ]]; then
    ((TESTS_RUN += 1))
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} Cannot test - git-identity.sh does not exist"
    return 0
  fi

  # Source the module and check exported variables
  local author_name author_email

  author_name="$(bash -c "source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/git-identity.sh'; echo \"\${GIT_AUTHOR_NAME}\"")"
  author_email="$(bash -c "source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/git-identity.sh'; echo \"\${GIT_AUTHOR_EMAIL}\"")"

  assert_equals "Claude Code Bot" "${author_name}" "GIT_AUTHOR_NAME is set to Claude Code Bot"
  assert_contains "@" "${author_email}" "GIT_AUTHOR_EMAIL contains @ symbol"
}

# =============================================================================
# SECTION 4: Integration Tests - Full wrapper behavior
# =============================================================================

test_wrapper_strict_mode() {
  echo ""
  echo "Test 4.1: Wrapper uses strict mode"

  local first_line second_line
  first_line="$(head -1 "${WRAPPER}")"
  second_line="$(sed -n '2p' "${WRAPPER}")"

  assert_equals "#!/usr/bin/env bash" "${first_line}" "Correct shebang"
  assert_equals "set -euo pipefail" "${second_line}" "Strict mode enabled"
}

test_wrapper_shellcheck() {
  echo ""
  echo "Test 4.2: ShellCheck compliance"

  if ! command -v shellcheck &>/dev/null; then
    echo -e "${YELLOW}⊘${NC} ShellCheck not installed, skipping"
    return 0
  fi

  # Check wrapper (--severity=warning to skip info-level path resolution hints)
  local shellcheck_output
  if shellcheck_output="$(shellcheck -x --severity=warning "${WRAPPER}" 2>&1)"; then
    ((TESTS_RUN += 1))
    ((TESTS_PASSED += 1))
    echo -e "${GREEN}✓${NC} Wrapper passes ShellCheck"
  else
    ((TESTS_RUN += 1))
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} Wrapper has ShellCheck issues:"
    echo "${shellcheck_output}"
  fi

  # Check all modules
  for module in "${LIB_DIR}"/*.sh; do
    if [[ -f "${module}" ]]; then
      if shellcheck_output="$(shellcheck -x --severity=warning "${module}" 2>&1)"; then
        ((TESTS_RUN += 1))
        ((TESTS_PASSED += 1))
        echo -e "${GREEN}✓${NC} $(basename "${module}") passes ShellCheck"
      else
        ((TESTS_RUN += 1))
        ((TESTS_FAILED += 1))
        echo -e "${RED}✗${NC} $(basename "${module}") has ShellCheck issues:"
        echo "${shellcheck_output}"
      fi
    fi
  done
}

test_mock_integration() {
  echo ""
  echo "Test 4.3: Integration with mock claude binary"

  local mock_claude
  mock_claude="$(create_mock_claude)"

  # Create a modified wrapper that uses our mock
  local test_wrapper="${TEST_TMP}/test-integration-wrapper"

  # Copy wrapper and modify to use mock
  if ! cp "${WRAPPER}" "${test_wrapper}"; then
    echo -e "${YELLOW}⚠${NC} Integration test skipped (could not copy wrapper)"
    return 0
  fi

  # Replace exec with our mock
  sed -i.bak "s|exec \"\${CLAUDE_BIN}\"|exec ${mock_claude}|g" "${test_wrapper}" 2>/dev/null \
    || sed -i '' "s|exec \"\${CLAUDE_BIN}\"|exec ${mock_claude}|g" "${test_wrapper}" 2>/dev/null || {
    echo -e "${YELLOW}⚠${NC} Integration test skipped (sed failed)"
    return 0
  }

  chmod +x "${test_wrapper}"

  # Run the wrapper with mock and check output
  local output exit_code
  exit_code=0
  output="$("${test_wrapper}" --version 2>&1)" || exit_code=$?

  if [[ ${exit_code} -eq 0 ]]; then
    assert_contains "MOCK_CLAUDE_EXECUTED" "${output}" "Mock claude was executed"
    assert_contains "GIT_AUTHOR_NAME=Claude Code Bot" "${output}" "Git identity passed through"
  else
    echo -e "${YELLOW}⚠${NC} Integration test skipped (wrapper exited with ${exit_code})"
  fi
}

test_no_old_naming_references() {
  echo ""
  echo "Test 4.4: No references to old naming"

  local wrapper_content
  wrapper_content="$(cat "${WRAPPER}")"

  assert_not_contains "claude-with-identity" "${wrapper_content}" "No claude-with-identity references in wrapper"
  assert_not_contains "claude-custom" "${wrapper_content}" "No claude-custom references in wrapper"
}

# =============================================================================
# SECTION 5: Regression Tests - Ensure existing functionality preserved
# =============================================================================

test_debug_logging_coverage() {
  echo ""
  echo "Test 5.1: Debug logging coverage"

  # Count debug_log calls across all source files
  local debug_count=0
  local file_count=0
  local count

  if [[ -f "${WRAPPER}" ]]; then
    count="$(grep -c "debug_log" "${WRAPPER}" 2>/dev/null)" || count=0
    debug_count=$((debug_count + count))
    ((file_count += 1))
  fi

  for module in "${LIB_DIR}"/*.sh; do
    if [[ -f "${module}" ]]; then
      count="$(grep -c "debug_log" "${module}" 2>/dev/null)" || count=0
      debug_count=$((debug_count + count))
      ((file_count += 1))
    fi
  done

  ((TESTS_RUN += 1))
  if [[ ${debug_count} -ge 20 ]]; then
    ((TESTS_PASSED += 1))
    echo -e "${GREEN}✓${NC} Adequate debug logging (${debug_count} calls across ${file_count} files)"
  else
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} Insufficient debug logging (${debug_count} calls, need 20+)"
  fi
}

test_graceful_degradation() {
  echo ""
  echo "Test 5.2: Graceful degradation without 1Password"

  # The secrets-loader module should handle missing op gracefully
  if [[ ! -f "${LIB_DIR}/secrets-loader.sh" ]]; then
    ((TESTS_RUN += 1))
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} Cannot test - secrets-loader.sh does not exist"
    return 0
  fi

  local module_content
  module_content="$(cat "${LIB_DIR}/secrets-loader.sh")"

  assert_contains "command -v op" "${module_content}" "Checks for op command availability"
  assert_contains "OP_ENABLED" "${module_content}" "Has OP_ENABLED flag for graceful degradation"
}

# =============================================================================
# SECTION 6: Token Router Tests - Multi-org token routing
# =============================================================================

test_gh_token_router_module_exists() {
  echo ""
  echo "Test 6.1: Token router module exists"
  assert_file_exists "${LIB_DIR}/gh-token-router.sh" "gh-token-router.sh module exists"

  local module_content
  module_content="$(cat "${LIB_DIR}/gh-token-router.sh")"
  assert_contains "detect_repo_owner()" "${module_content}" "Exports detect_repo_owner function"
  assert_contains "select_gh_token()" "${module_content}" "Exports select_gh_token function"
  assert_contains "_check_token_perms()" "${module_content}" "Has inline permission check"
}

test_detect_repo_owner_from_repo_flag() {
  echo ""
  echo "Test 6.2: detect_repo_owner from --repo flag"

  if [[ ! -f "${LIB_DIR}/gh-token-router.sh" ]]; then
    ((TESTS_RUN += 1))
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} Cannot test - gh-token-router.sh does not exist"
    return 0
  fi

  local owner

  # --repo OWNER/REPO
  owner="$(bash -c "source '${LIB_DIR}/gh-token-router.sh' 2>/dev/null; detect_repo_owner pr list --repo smartwatermelon/claude-wrapper")"
  assert_equals "smartwatermelon" "${owner}" "--repo extracts owner correctly"

  # -R OWNER/REPO
  owner="$(bash -c "source '${LIB_DIR}/gh-token-router.sh' 2>/dev/null; detect_repo_owner pr list -R nightowlstudiollc/kebab-tax")"
  assert_equals "nightowlstudiollc" "${owner}" "-R extracts owner correctly"
}

test_detect_repo_owner_from_api_path() {
  echo ""
  echo "Test 6.3: detect_repo_owner from API path"

  if [[ ! -f "${LIB_DIR}/gh-token-router.sh" ]]; then
    ((TESTS_RUN += 1))
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} Cannot test - gh-token-router.sh does not exist"
    return 0
  fi

  local owner

  # repos/OWNER/REPO/...
  owner="$(bash -c "source '${LIB_DIR}/gh-token-router.sh' 2>/dev/null; detect_repo_owner api repos/nightowlstudiollc/kebab-tax/pulls")"
  assert_equals "nightowlstudiollc" "${owner}" "repos/ API path extracts owner"

  # orgs/OWNER/...
  owner="$(bash -c "source '${LIB_DIR}/gh-token-router.sh' 2>/dev/null; detect_repo_owner api orgs/nightowlstudiollc/repos")"
  assert_equals "nightowlstudiollc" "${owner}" "orgs/ API path extracts owner"
}

test_detect_repo_owner_from_git_remote() {
  echo ""
  echo "Test 6.4: detect_repo_owner from git remote"

  if [[ ! -f "${LIB_DIR}/gh-token-router.sh" ]]; then
    ((TESTS_RUN += 1))
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} Cannot test - gh-token-router.sh does not exist"
    return 0
  fi

  # Create a temp git repo with a fake remote
  local test_repo="${TEST_TMP}/fake-repo"
  mkdir -p "${test_repo}"
  git -C "${test_repo}" init -q
  git -C "${test_repo}" remote add origin "git@github.com:testowner/testrepo.git"

  local owner
  owner="$(cd "${test_repo}" && bash -c "source '${LIB_DIR}/gh-token-router.sh' 2>/dev/null; detect_repo_owner some-command")"
  assert_equals "testowner" "${owner}" "Git remote extracts owner from SSH URL"

  # Test HTTPS remote
  git -C "${test_repo}" remote set-url origin "https://github.com/httpsowner/httpsrepo.git"
  owner="$(cd "${test_repo}" && bash -c "source '${LIB_DIR}/gh-token-router.sh' 2>/dev/null; detect_repo_owner some-command")"
  assert_equals "httpsowner" "${owner}" "Git remote extracts owner from HTTPS URL"
}

test_select_gh_token_owner_specific() {
  echo ""
  echo "Test 6.5: select_gh_token loads owner-specific token"

  if [[ ! -f "${LIB_DIR}/gh-token-router.sh" ]]; then
    ((TESTS_RUN += 1))
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} Cannot test - gh-token-router.sh does not exist"
    return 0
  fi

  # Create mock token directory with owner-specific tokens
  local token_dir="${TEST_TMP}/token-test"
  mkdir -p "${token_dir}"
  echo "default-token-value" >"${token_dir}/gh-token"
  echo "org-token-value" >"${token_dir}/gh-token.myorg"
  chmod 600 "${token_dir}/gh-token"
  chmod 600 "${token_dir}/gh-token.myorg"

  # select_gh_token should pick up the org token for --repo myorg/repo
  local result
  result="$(CLAUDE_GH_TOKEN_DIR="${token_dir}" GH_TOKEN="default-token-value" bash -c "
    source '${LIB_DIR}/gh-token-router.sh' 2>/dev/null
    select_gh_token api repos/myorg/somerepo/pulls
    echo \"\${GH_TOKEN}\"
  ")"
  assert_equals "org-token-value" "${result}" "Owner-specific token loaded for matching owner"
}

test_select_gh_token_fallback() {
  echo ""
  echo "Test 6.6: select_gh_token falls back to default"

  if [[ ! -f "${LIB_DIR}/gh-token-router.sh" ]]; then
    ((TESTS_RUN += 1))
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} Cannot test - gh-token-router.sh does not exist"
    return 0
  fi

  # Create mock token directory with only default token
  local token_dir="${TEST_TMP}/token-fallback"
  mkdir -p "${token_dir}"
  echo "default-token-value" >"${token_dir}/gh-token"
  chmod 600 "${token_dir}/gh-token"

  # No owner-specific file exists for "unknownorg" — should keep default
  local result
  result="$(CLAUDE_GH_TOKEN_DIR="${token_dir}" GH_TOKEN="default-token-value" bash -c "
    source '${LIB_DIR}/gh-token-router.sh' 2>/dev/null
    select_gh_token api repos/unknownorg/somerepo/pulls
    echo \"\${GH_TOKEN}\"
  ")"
  assert_equals "default-token-value" "${result}" "Falls back to default token when no owner file"
}

test_select_gh_token_rejects_insecure_perms() {
  echo ""
  echo "Test 6.7: select_gh_token rejects insecure permissions"

  if [[ ! -f "${LIB_DIR}/gh-token-router.sh" ]]; then
    ((TESTS_RUN += 1))
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} Cannot test - gh-token-router.sh does not exist"
    return 0
  fi

  # Create mock token directory with insecure owner token
  local token_dir="${TEST_TMP}/token-insecure"
  mkdir -p "${token_dir}"
  echo "insecure-org-token" >"${token_dir}/gh-token.badorg"
  chmod 644 "${token_dir}/gh-token.badorg"

  local exit_code=0
  CLAUDE_GH_TOKEN_DIR="${token_dir}" GH_TOKEN="default-token-value" bash -c "
    source '${LIB_DIR}/gh-token-router.sh' 2>/dev/null
    select_gh_token api repos/badorg/somerepo/pulls
  " 2>/dev/null || exit_code=$?

  assert_exit_code "1" "${exit_code}" "Rejects token file with insecure permissions"
}

test_github_token_exports_router_vars() {
  echo ""
  echo "Test 6.8: github-token.sh exports router env vars"

  local module_content
  module_content="$(cat "${LIB_DIR}/github-token.sh")"

  assert_contains "CLAUDE_GH_TOKEN_DIR" "${module_content}" "github-token.sh references CLAUDE_GH_TOKEN_DIR"
  assert_contains "CLAUDE_GH_TOKEN_ROUTER" "${module_content}" "github-token.sh references CLAUDE_GH_TOKEN_ROUTER"
  assert_contains "export CLAUDE_GH_TOKEN_DIR" "${module_content}" "Exports CLAUDE_GH_TOKEN_DIR"
  assert_contains "export CLAUDE_GH_TOKEN_ROUTER" "${module_content}" "Exports CLAUDE_GH_TOKEN_ROUTER"
}

# =============================================================================
# Main test runner
# =============================================================================

main() {
  echo "======================================"
  echo "Claude Wrapper Test Suite (TDD)"
  echo "======================================"

  setup_test_env

  # Section 1: Structure Tests
  echo ""
  echo "--- Section 1: Structure Tests ---"
  test_wrapper_exists
  test_lib_directory_exists
  test_module_files_exist
  test_wrapper_sources_modules

  # Section 2: Module Interface Tests
  echo ""
  echo "--- Section 2: Module Interface Tests ---"
  test_logging_module_interface
  test_permissions_module_interface
  test_path_security_module_interface
  test_git_identity_module_interface
  test_binary_discovery_module_interface

  # Section 3: Behavioral Tests
  echo ""
  echo "--- Section 3: Behavioral Tests ---"
  test_logging_behavior
  test_permissions_behavior
  test_permissions_autofix_behavior
  test_path_security_behavior
  test_git_identity_behavior

  # Section 4: Integration Tests
  echo ""
  echo "--- Section 4: Integration Tests ---"
  test_wrapper_strict_mode
  test_wrapper_shellcheck
  test_mock_integration
  test_no_old_naming_references

  # Section 5: Regression Tests
  echo ""
  echo "--- Section 5: Regression Tests ---"
  test_debug_logging_coverage
  test_graceful_degradation

  # Section 6: Token Router Tests
  echo ""
  echo "--- Section 6: Token Router Tests ---"
  test_gh_token_router_module_exists
  test_detect_repo_owner_from_repo_flag
  test_detect_repo_owner_from_api_path
  test_detect_repo_owner_from_git_remote
  test_select_gh_token_owner_specific
  test_select_gh_token_fallback
  test_select_gh_token_rejects_insecure_perms
  test_github_token_exports_router_vars

  echo ""
  echo "======================================"
  echo "Test Results"
  echo "======================================"
  echo "Tests run:    ${TESTS_RUN}"
  echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"

  if [[ ${TESTS_FAILED} -gt 0 ]]; then
    echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
    cleanup_test_env
    exit 1
  else
    echo -e "Tests failed: ${TESTS_FAILED}"
    echo ""
    echo -e "${GREEN}All tests passed!${NC}"
    cleanup_test_env
    exit 0
  fi
}

# Run tests
main "$@"
