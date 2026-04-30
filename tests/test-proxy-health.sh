#!/usr/bin/env bash
# Test suite for lib/proxy-health.sh
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

# Captured output from logging stubs (one accumulator per level)
WARN_LOG=""
DEBUG_LOG_OUTPUT=""

debug_log() { DEBUG_LOG_OUTPUT+="$*"$'\n'; }
log_warn() { WARN_LOG+="$*"$'\n'; }
log_error() { :; }

# shellcheck source=../lib/proxy-health.sh
source "${LIB_DIR}/proxy-health.sh"

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

assert_contains() {
  local haystack="$1" needle="$2" message="${3:-}"
  ((TESTS_RUN += 1))
  if [[ "${haystack}" == *"${needle}"* ]]; then
    ((TESTS_PASSED += 1))
    echo -e "${GREEN}✓${NC} ${message}"
  else
    ((TESTS_FAILED += 1))
    echo -e "${RED}✗${NC} ${message}"
    echo "  Expected to contain: ${needle}"
    echo "  Actual: ${haystack}"
  fi
  return 0
}

reset_state() {
  WARN_LOG=""
  DEBUG_LOG_OUTPUT=""
  unset -f curl 2>/dev/null || true
  unset -f command 2>/dev/null || true
  unset ANTHROPIC_BASE_URL
}

echo ""
echo "=== check_proxy_health ==="

# Test 1: unset URL → no-op, no warning
reset_state
check_proxy_health
assert_equals "" "${ANTHROPIC_BASE_URL:-}" \
  "unset URL: still unset after"
assert_equals "" "${WARN_LOG}" \
  "unset URL: no warning"

# Test 2: remote URL → preserved, no warning, no curl call
reset_state
export ANTHROPIC_BASE_URL="https://api.anthropic.com"
# Stub curl to fail loudly if invoked — remote URLs must skip the check
curl() {
  echo "FAIL: curl invoked for remote URL" >&2
  return 99
}
check_proxy_health
assert_equals "https://api.anthropic.com" "${ANTHROPIC_BASE_URL}" \
  "remote URL: preserved"
assert_equals "" "${WARN_LOG}" \
  "remote URL: no warning"

# Test 3: localhost URL with healthy proxy → preserved
reset_state
export ANTHROPIC_BASE_URL="http://localhost:8787"
curl() { return 0; }
check_proxy_health
assert_equals "http://localhost:8787" "${ANTHROPIC_BASE_URL}" \
  "healthy proxy: URL preserved"
assert_equals "" "${WARN_LOG}" \
  "healthy proxy: no warning"

# Test 4: localhost URL refused (curl exit 7) → URL unset + warning
reset_state
export ANTHROPIC_BASE_URL="http://localhost:8787"
curl() { return 7; }
check_proxy_health
assert_equals "" "${ANTHROPIC_BASE_URL:-}" \
  "refused: ANTHROPIC_BASE_URL unset"
assert_contains "${WARN_LOG}" "localhost:8787" \
  "refused: warning mentions URL"

# Test 5: HTTP error (curl --fail exit 22) → URL unset + warning
reset_state
export ANTHROPIC_BASE_URL="http://127.0.0.1:8787"
curl() { return 22; }
check_proxy_health
assert_equals "" "${ANTHROPIC_BASE_URL:-}" \
  "HTTP error: ANTHROPIC_BASE_URL unset"
assert_contains "${WARN_LOG}" "127.0.0.1" \
  "HTTP error: warning mentions URL"

# Test 6: 127.0.0.1 also recognized as localhost
reset_state
export ANTHROPIC_BASE_URL="http://127.0.0.1:8787"
curl() { return 0; }
check_proxy_health
assert_equals "http://127.0.0.1:8787" "${ANTHROPIC_BASE_URL}" \
  "127.0.0.1 healthy: preserved"

# Test 7: missing curl → graceful degrade, no warning, URL preserved
reset_state
export ANTHROPIC_BASE_URL="http://localhost:8787"
# Override `command` builtin to claim curl is missing
command() {
  if [[ "${1:-}" == "-v" && "${2:-}" == "curl" ]]; then
    return 1
  fi
  builtin command "$@"
}
check_proxy_health
assert_equals "http://localhost:8787" "${ANTHROPIC_BASE_URL}" \
  "missing curl: URL preserved (graceful degrade)"
assert_equals "" "${WARN_LOG}" \
  "missing curl: no warning"

# Test 8: function does not abort under set -e on curl failure
# (This script runs with set -e; if check_proxy_health propagated the
# failure, the next line would never execute.)
reset_state
export ANTHROPIC_BASE_URL="http://localhost:8787"
curl() { return 7; }
check_proxy_health
((TESTS_RUN += 1))
((TESTS_PASSED += 1))
echo -e "${GREEN}✓${NC} set -e: function doesn't abort wrapper on curl failure"

# Test 9: trailing slash on URL handled (no double slash in /health request)
# We capture the URL passed to curl to verify it's well-formed.
reset_state
export ANTHROPIC_BASE_URL="http://localhost:8787/"
CAPTURED_URL=""
curl() {
  for arg in "$@"; do
    [[ "${arg}" == http* ]] && CAPTURED_URL="${arg}"
  done
  return 0
}
check_proxy_health
assert_equals "http://localhost:8787/health" "${CAPTURED_URL}" \
  "trailing slash on base URL stripped before /health"

echo ""
echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
if [[ "${TESTS_FAILED}" -gt 0 ]]; then
  exit 1
fi
