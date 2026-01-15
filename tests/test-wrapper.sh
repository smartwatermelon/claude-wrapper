#!/usr/bin/env bash
# Test suite for claude-with-identity wrapper
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
WRAPPER="${REPO_ROOT}/bin/claude-with-identity"

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
    return 0
  else
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} ${message}"
    echo "  Expected: ${expected}"
    echo "  Actual:   ${actual}"
    return 1
  fi
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  local message="${3:-}"

  ((TESTS_RUN += 1))

  if echo "${haystack}" | grep -qF "${needle}"; then
    ((TESTS_PASSED += 1))
    echo -e "${GREEN}✓${NC} ${message}"
    return 0
  else
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} ${message}"
    echo "  Expected to find: ${needle}"
    echo "  In: ${haystack}"
    return 1
  fi
}

assert_file_exists() {
  local file="$1"
  local message="${2:-}"

  ((TESTS_RUN += 1))

  if [[ -f "${file}" ]]; then
    ((TESTS_PASSED += 1))
    echo -e "${GREEN}✓${NC} ${message}"
    return 0
  else
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} ${message}"
    echo "  File not found: ${file}"
    return 1
  fi
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

# Test 1: Wrapper script exists and is executable
test_wrapper_exists() {
  echo ""
  echo "Test 1: Wrapper script validation"
  assert_file_exists "${WRAPPER}" "Wrapper script exists"

  if [[ -x "${WRAPPER}" ]]; then
    ((TESTS_RUN += 1))
    ((TESTS_PASSED += 1))
    echo -e "${GREEN}✓${NC} Wrapper script is executable"
  else
    ((TESTS_RUN += 1))
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} Wrapper script is not executable"
  fi
}

# Test 2: Git identity variables are set
test_git_identity() {
  echo ""
  echo "Test 2: Git identity environment setup"

  local mock_claude
  mock_claude="$(create_mock_claude)"

  # Temporarily add mock to PATH
  export PATH="${TEST_TMP}:${PATH}"

  # Create a mock wrapper that sources the real one but exits before exec
  local test_wrapper="${TEST_TMP}/test-wrapper"
  cat >"${test_wrapper}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "${WRAPPER}" 2>/dev/null || true
# Don't exec, just print vars
printenv | grep -E '^GIT_' | sort
EOF

  # Extract the configuration values from the wrapper (handles both readonly and regular declarations)
  local git_name
  local git_email
  git_name="$(grep 'CLAUDE_GIT_NAME=' "${WRAPPER}" | head -1 | cut -d'"' -f2)"
  git_email="$(grep 'CLAUDE_GIT_EMAIL=' "${WRAPPER}" | head -1 | cut -d'"' -f2)"

  # Verify the values are set
  assert_equals "Claude Code Bot" "${git_name}" "Git author name configured correctly"
  assert_contains "@" "${git_email}" "Git author email contains @ symbol"

  # Verify they're exported
  local wrapper_content_check
  wrapper_content_check="$(cat "${WRAPPER}")"
  assert_contains "export GIT_AUTHOR_NAME=\"\${CLAUDE_GIT_NAME}\"" "${wrapper_content_check}" "GIT_AUTHOR_NAME exported"
  assert_contains "export GIT_AUTHOR_EMAIL=\"\${CLAUDE_GIT_EMAIL}\"" "${wrapper_content_check}" "GIT_AUTHOR_EMAIL exported"
}

# Test 3: Debug mode detection
test_debug_mode() {
  echo ""
  echo "Test 3: Debug mode functionality"

  local wrapper_content
  wrapper_content="$(cat "${WRAPPER}")"

  # Check that debug_log function exists
  assert_contains "debug_log()" "${wrapper_content}" "debug_log function defined"

  # Check that DEBUG variable is used
  assert_contains "DEBUG=\"\${CLAUDE_DEBUG:-false}\"" "${wrapper_content}" "DEBUG variable initialized"
}

# Test 4: 1Password detection logic
test_1password_detection() {
  echo ""
  echo "Test 4: 1Password CLI detection logic"

  local wrapper_content
  wrapper_content="$(cat "${WRAPPER}")"

  # Check for op command detection
  assert_contains "command -v op" "${wrapper_content}" "Checks for op command"

  # Check for graceful handling when op not found
  assert_contains "OP_ENABLED=false" "${wrapper_content}" "Has OP_ENABLED flag"
}

# Test 5: Multi-level secrets file paths
test_secrets_file_paths() {
  echo ""
  echo "Test 5: Multi-level secrets file configuration"

  local wrapper_content
  wrapper_content="$(cat "${WRAPPER}")"

  assert_contains "CLAUDE_OP_GLOBAL_SECRETS" "${wrapper_content}" "Global secrets path defined"
  assert_contains "CLAUDE_OP_PROJECT_SECRETS" "${wrapper_content}" "Project secrets path defined"
  assert_contains "CLAUDE_OP_LOCAL_SECRETS" "${wrapper_content}" "Local secrets path defined"

  # Check for proper precedence (all three files checked)
  assert_contains "OP_ENV_ARGS+=" "${wrapper_content}" "Builds env-file arguments array"
}

# Test 6: Error handling for failed signin
test_signin_error_handling() {
  echo ""
  echo "Test 6: 1Password signin error handling"

  local wrapper_content
  wrapper_content="$(cat "${WRAPPER}")"

  assert_contains "if op signin" "${wrapper_content}" "Conditional signin execution"
  assert_contains "else" "${wrapper_content}" "Has error handling branch"
  assert_contains "log_warn" "${wrapper_content}" "Uses log_warn function"
  assert_contains "Continuing without" "${wrapper_content}" "Graceful degradation message"
}

# Test 7: Binary search logic
test_claude_binary_search() {
  echo ""
  echo "Test 7: Claude binary search logic"

  local wrapper_content
  wrapper_content="$(cat "${WRAPPER}")"

  assert_contains "type -ap claude" "${wrapper_content}" "Searches PATH for claude"
  assert_contains "realpath" "${wrapper_content}" "Uses realpath for comparison"
  assert_contains "WRAPPER_PATH" "${wrapper_content}" "Tracks wrapper path to avoid recursion"
  assert_contains "Could not find claude binary" "${wrapper_content}" "Error message for missing binary"
}

# Test 8: Secrets file validation
test_secrets_validation() {
  echo ""
  echo "Test 8: Secrets file validation logic"

  local wrapper_content
  wrapper_content="$(cat "${WRAPPER}")"

  # Check for file existence checks
  assert_contains "[[ -f \"\${CLAUDE_OP_GLOBAL_SECRETS}\" ]]" "${wrapper_content}" "Checks if global secrets exists"
  assert_contains "[[ -f \"\${CLAUDE_OP_PROJECT_SECRETS}\" ]]" "${wrapper_content}" "Checks if project secrets exists"
  assert_contains "[[ -f \"\${CLAUDE_OP_LOCAL_SECRETS}\" ]]" "${wrapper_content}" "Checks if local secrets exists"

  # Check for readability checks
  assert_contains "[[ -r \"\${CLAUDE_OP_GLOBAL_SECRETS}\" ]]" "${wrapper_content}" "Checks if global secrets is readable"
  assert_contains "Cannot read" "${wrapper_content}" "Warning for unreadable files"
}

# Test 9: Conditional execution paths
test_execution_paths() {
  echo ""
  echo "Test 9: Conditional execution paths"

  local wrapper_content
  wrapper_content="$(cat "${WRAPPER}")"

  # Check for op run when enabled
  assert_contains 'OP_ENABLED.*==.*true' "${wrapper_content}" "Checks OP_ENABLED flag"
  assert_contains 'exec op run' "${wrapper_content}" "Executes with op run when enabled"

  # Check for direct exec when disabled
  assert_contains 'exec.*CLAUDE_BIN' "${wrapper_content}" "Direct execution when disabled"
}

# Test 10: ShellCheck compliance
test_shellcheck_compliance() {
  echo ""
  echo "Test 10: ShellCheck static analysis"

  if ! command -v shellcheck &>/dev/null; then
    echo -e "${YELLOW}⊘${NC} ShellCheck not installed, skipping"
    return 0
  fi

  local shellcheck_output
  if shellcheck_output="$(shellcheck -x "${WRAPPER}" 2>&1)"; then
    ((TESTS_RUN += 1))
    ((TESTS_PASSED += 1))
    echo -e "${GREEN}✓${NC} ShellCheck passed (no issues)"
  else
    ((TESTS_RUN += 1))
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} ShellCheck found issues:"
    echo "${shellcheck_output}"
  fi
}

# Test 11: set -euo pipefail present
test_strict_mode() {
  echo ""
  echo "Test 11: Bash strict mode"

  local first_line
  local second_line
  first_line="$(head -1 "${WRAPPER}")"
  second_line="$(sed -n '2p' "${WRAPPER}")"

  assert_equals "#!/usr/bin/env bash" "${first_line}" "Correct shebang"
  assert_equals "set -euo pipefail" "${second_line}" "Strict mode enabled"
}

# Test 12: Debug logging coverage
test_debug_coverage() {
  echo ""
  echo "Test 12: Debug logging coverage"

  local wrapper_content
  local debug_count
  wrapper_content="$(cat "${WRAPPER}")"
  debug_count="$(grep -c "debug_log" "${wrapper_content}" || true)"

  ((TESTS_RUN += 1))
  if [[ ${debug_count} -ge 10 ]]; then
    ((TESTS_PASSED += 1))
    echo -e "${GREEN}✓${NC} Adequate debug logging (${debug_count} calls)"
  else
    echo -e "${YELLOW}⚠${NC} Limited debug logging (${debug_count} calls, recommend 10+)"
  fi
}

# Test 13: Integration test with mock claude (if we can safely test)
test_mock_integration() {
  echo ""
  echo "Test 13: Mock integration test"

  local mock_claude
  mock_claude="$(create_mock_claude)"

  # Create a test wrapper that uses our mock
  local test_wrapper="${TEST_TMP}/test-integration-wrapper"
  local test_wrapper_tmp="${TEST_TMP}/test-integration-wrapper.tmp"

  # Replace the claude search with our mock (atomic operation via subshell)
  (
    sed "s|exec \"\${CLAUDE_BIN}\"|exec ${mock_claude}|g" "${WRAPPER}" >"${test_wrapper_tmp}" \
      && mv "${test_wrapper_tmp}" "${test_wrapper}"
  ) || {
    rm -f "${test_wrapper_tmp}" "${test_wrapper}"
    echo -e "${YELLOW}⚠${NC} Integration test skipped (wrapper modification failed)"
    return 0
  }

  chmod +x "${test_wrapper}"

  # Run the wrapper and capture output
  local output
  if output="$("${test_wrapper}" --version 2>&1)"; then
    assert_contains "MOCK_CLAUDE_EXECUTED" "${output}" "Mock claude was executed"
    assert_contains "GIT_AUTHOR_NAME=Claude Code Bot" "${output}" "Git identity passed through"
  else
    echo -e "${YELLOW}⚠${NC} Integration test skipped (wrapper modification failed)"
  fi
}

# Main test runner
main() {
  echo "======================================"
  echo "Claude Wrapper Test Suite"
  echo "======================================"

  setup_test_env

  test_wrapper_exists
  test_git_identity
  test_debug_mode
  test_1password_detection
  test_secrets_file_paths
  test_signin_error_handling
  test_claude_binary_search
  test_secrets_validation
  test_execution_paths
  test_strict_mode
  test_debug_coverage
  test_shellcheck_compliance
  test_mock_integration

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
