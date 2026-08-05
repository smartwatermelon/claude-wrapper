#!/usr/bin/env bash
# Test suite for lib/launch-dir-check.sh
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
LIB_DIR="${REPO_ROOT}/lib"

# Minimal stubs required before sourcing launch-dir-check.sh
debug_log() { :; }
log_warn() { echo "WARNING: $*" >&2; }

# Source the module under test
# shellcheck source=../lib/launch-dir-check.sh
source "${LIB_DIR}/launch-dir-check.sh"

# --- Helpers ---
assert_warns() {
  local cwd="$1" message="$2"
  local stderr_output
  ((TESTS_RUN += 1))
  stderr_output="$(check_launch_dir "${cwd}" 2>&1 >/dev/null)"
  if [[ -n "${stderr_output}" ]]; then
    ((TESTS_PASSED += 1))
    echo -e "${GREEN}✓${NC} ${message}"
  else
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} ${message}"
    echo "  Expected a warning on stderr, got none"
  fi
  return 0
}

assert_no_warn() {
  local cwd="$1" message="$2"
  local stderr_output
  ((TESTS_RUN += 1))
  stderr_output="$(check_launch_dir "${cwd}" 2>&1 >/dev/null)"
  if [[ -z "${stderr_output}" ]]; then
    ((TESTS_PASSED += 1))
    echo -e "${GREEN}✓${NC} ${message}"
  else
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} ${message}"
    echo "  Expected no warning, got:"
    echo "  ${stderr_output}"
  fi
  return 0
}

# --- Tests: check_launch_dir ---

echo ""
echo "=== check_launch_dir ==="

assert_warns "${HOME}" \
  "CWD exactly \$HOME → warns"

assert_warns "${HOME}/Developer" \
  "CWD exactly \$HOME/Developer → warns"

assert_no_warn "${HOME}/Developer/claude-wrapper" \
  "CWD is a subdirectory of \$HOME/Developer → does not warn"

assert_no_warn "${HOME}/Documents" \
  "CWD unrelated to \$HOME/Developer → does not warn"

assert_no_warn "/tmp" \
  "CWD entirely unrelated path → does not warn"

# Always returns success (non-blocking), regardless of warning
((TESTS_RUN += 1))
if check_launch_dir "${HOME}" >/dev/null 2>&1; then
  ((TESTS_PASSED += 1))
  echo -e "${GREEN}✓${NC} check_launch_dir never blocks (returns 0) even when warning"
else
  ((TESTS_FAILED += 1))
  echo -e "${RED}✗${NC} check_launch_dir never blocks (returns 0) even when warning"
fi

# --- Summary ---

echo ""
echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
if [[ "${TESTS_FAILED}" -gt 0 ]]; then
  exit 1
fi
