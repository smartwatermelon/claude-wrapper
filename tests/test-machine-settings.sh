#!/usr/bin/env bash
# Test suite for lib/machine-settings.sh
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

# shellcheck source=lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=lib/permissions.sh
source "${LIB_DIR}/permissions.sh"
# shellcheck source=lib/remote-session.sh
source "${LIB_DIR}/remote-session.sh"
# shellcheck source=lib/machine-settings.sh
source "${LIB_DIR}/machine-settings.sh"

TMP="$(mktemp -d)"
trap 'rm -r "${TMP}"' EXIT
export HOME="${TMP}/home"
mkdir -p "${HOME}/.config/claude-code"
unset CLAUDE_MACHINE_SETTINGS
FILE="${HOME}/.config/claude-code/machine-settings.json"

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

# Prints the args on one line, then rc=N.
run_build() {
  local out rc=0
  out="$(build_machine_settings_args "$@" 2>/dev/null)" || rc=$?
  printf '%s rc=%s' "$(printf '%s' "${out}" | tr '\n' ' ')" "${rc}"
}

echo ""
echo "=== build_machine_settings_args ==="

assert_equals "${FILE}" "$(machine_settings_file)" \
  "default path is ~/.config/claude-code/machine-settings.json"

assert_equals " rc=1" "$(run_build)" \
  "no file: nothing added"

printf '{"enabledPlugins": {"cloudflare@cloudflare": true}}\n' >"${FILE}"
chmod 644 "${FILE}"
assert_equals "--settings ${FILE} rc=0" "$(run_build)" \
  "file present, interactive: --settings <file>"

assert_equals "--settings ${FILE} rc=0" "$(run_build --continue)" \
  "interactive with flags: --settings <file>"

assert_equals " rc=1" "$(run_build -p "hello")" \
  "print mode: nothing added"

assert_equals " rc=1" "$(run_build mcp list)" \
  "subcommand: nothing added"

assert_equals " rc=1" "$(run_build --settings /other.json)" \
  "--settings on the command line: nothing added"

assert_equals " rc=1" "$(run_build --settings=/other.json)" \
  "--settings= on the command line: nothing added"

chmod 664 "${FILE}"
assert_equals " rc=1" "$(run_build)" \
  "group-writable file: skipped"
WARN="$(build_machine_settings_args 2>&1 >/dev/null || true)"
assert_equals "1" "$(grep -c 'chmod go-w' <<<"${WARN}" || true)" \
  "group-writable file: warning names the fix"

chmod 646 "${FILE}"
assert_equals " rc=1" "$(run_build)" \
  "world-writable file: skipped"

chmod 600 "${FILE}"
assert_equals "--settings ${FILE} rc=0" "$(run_build)" \
  "mode 600: used"

printf '{"enabledPlugins": \n' >"${FILE}"
assert_equals " rc=1" "$(run_build)" \
  "invalid JSON: skipped"
printf '[1, 2]\n' >"${FILE}"
assert_equals " rc=1" "$(run_build)" \
  "JSON that is not an object: skipped"

# A PATH with the tools the earlier checks need, but no jq.
NOJQ="${TMP}/nojq-bin"
mkdir -p "${NOJQ}"
for tool in stat id tr; do
  ln -s "$(command -v "${tool}")" "${NOJQ}/${tool}"
done
printf '{}\n' >"${FILE}"
WARN="$(PATH="${NOJQ}" build_machine_settings_args 2>&1 >/dev/null || true)"
assert_equals " rc=1" "$(PATH="${NOJQ}" run_build)" \
  "no jq on PATH: skipped, not passed unchecked"
assert_equals "1" "$(grep -c 'jq not found' <<<"${WARN}" || true)" \
  "no jq on PATH: skipped by the jq check, not an earlier one"

OTHER="${TMP}/other.json"
printf '{}\n' >"${OTHER}"
chmod 644 "${OTHER}"
assert_equals "--settings ${OTHER} rc=0" "$(CLAUDE_MACHINE_SETTINGS="${OTHER}" run_build)" \
  "CLAUDE_MACHINE_SETTINGS overrides the path"

# --- Summary ---

echo ""
echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
if [[ "${TESTS_FAILED}" -gt 0 ]]; then
  exit 1
fi
