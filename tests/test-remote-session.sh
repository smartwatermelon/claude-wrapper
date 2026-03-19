#!/usr/bin/env bash
# Test suite for lib/remote-session.sh
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

# Minimal stubs required before sourcing remote-session.sh
debug_log() { :; }

# Source the module under test
# shellcheck source=../lib/remote-session.sh
source "${LIB_DIR}/remote-session.sh"

# --- Helpers ---
assert_equals() {
  local expected="$1" actual="$2" message="${3:-}"
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
  return 0
}

assert_true() {
  local actual="$1" message="${2:-}"
  assert_equals "0" "${actual}" "${message}"
}

assert_false() {
  local actual="$1" message="${2:-}"
  ((TESTS_RUN += 1))
  if [[ "${actual}" != "0" ]]; then
    ((TESTS_PASSED += 1))
    echo -e "${GREEN}✓${NC} ${message}"
  else
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} ${message}"
    echo "  Expected non-zero (false), got 0 (true)"
  fi
  return 0
}

run_is_interactive() {
  is_interactive_session "$@" && echo 0 || echo $?
}

# --- Tests: is_interactive_session ---

echo ""
echo "=== is_interactive_session ==="

assert_true "$(run_is_interactive)" \
  "no args → interactive"

assert_true "$(run_is_interactive --dangerouslySkipPermissions)" \
  "unknown flags only → interactive"

assert_true "$(run_is_interactive --continue)" \
  "--continue flag → interactive"

assert_false "$(run_is_interactive --print)" \
  "--print → non-interactive"

assert_false "$(run_is_interactive -p)" \
  "-p → non-interactive"

assert_false "$(run_is_interactive --version)" \
  "--version → non-interactive"

assert_false "$(run_is_interactive --help)" \
  "--help → non-interactive"

assert_false "$(run_is_interactive -h)" \
  "-h → non-interactive"

assert_false "$(run_is_interactive --remote-control)" \
  "--remote-control already present → skip injection"

assert_false "$(run_is_interactive --rc)" \
  "--rc already present → skip injection"

assert_false "$(run_is_interactive --no-session-persistence)" \
  "--no-session-persistence (focused analysis task) → non-interactive"

assert_false "$(run_is_interactive remote-control)" \
  "subcommand 'remote-control' → non-interactive"

assert_false "$(run_is_interactive mcp)" \
  "subcommand 'mcp' → non-interactive"

assert_false "$(run_is_interactive help)" \
  "subcommand 'help' → non-interactive"

assert_false "$(run_is_interactive -- --flag)" \
  "args after -- → non-interactive"

# --- Tests: get_remote_session_name ---

echo ""
echo "=== get_remote_session_name ==="

# In-repo: should return the git repo name
REPO_NAME="$(basename "$(git -C "${REPO_ROOT}" rev-parse --show-toplevel 2>/dev/null)")"
SESSION_NAME="$(cd "${REPO_ROOT}" && get_remote_session_name)"
assert_equals "${REPO_NAME}" "${SESSION_NAME}" \
  "inside git repo → returns repo name"

# Outside repo: should return dirname
TMPDIR_NAME="$(mktemp -d)"
OUTER_SESSION_NAME="$(cd "${TMPDIR_NAME}" && get_remote_session_name)"
assert_equals "$(basename "${TMPDIR_NAME}")" "${OUTER_SESSION_NAME}" \
  "outside git repo → returns dirname"
rmdir "${TMPDIR_NAME}"

# --- Tests: build_remote_control_args ---

echo ""
echo "=== build_remote_control_args ==="

# Interactive session → outputs two lines: --remote-control and session name
OUTPUT="$(build_remote_control_args)"
assert_equals "--remote-control" "$(echo "${OUTPUT}" | head -1)" \
  "interactive: first output line is --remote-control"
assert_equals "${REPO_NAME}" "$(echo "${OUTPUT}" | tail -1)" \
  "interactive: second output line is session name"

# Non-interactive → outputs nothing, returns 1
OUTPUT="$(build_remote_control_args --print || true)"
assert_equals "" "${OUTPUT}" \
  "--print: no output"

# Opt-out env var
OUTPUT="$(CLAUDE_NO_REMOTE_CONTROL=true build_remote_control_args || true)"
assert_equals "" "${OUTPUT}" \
  "CLAUDE_NO_REMOTE_CONTROL=true: no output"

# Already has --remote-control
OUTPUT="$(build_remote_control_args --remote-control || true)"
assert_equals "" "${OUTPUT}" \
  "--remote-control already present: no output"

# --- Summary ---

echo ""
echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
if [[ "${TESTS_FAILED}" -gt 0 ]]; then
  exit 1
fi
