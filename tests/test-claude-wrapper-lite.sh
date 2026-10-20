#!/usr/bin/env bash
# Test suite for bin/claude-wrapper-lite
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
LITE="${REPO_ROOT}/bin/claude-wrapper-lite"

# The copy must sit beside the real script, which finds its lib at "<own dir>/../lib".
# Only its caffeinate path differs.
LITE_COPY="${REPO_ROOT}/bin/.test-claude-wrapper-lite.$$"

TMP="$(mktemp -d)"
trap 'rm -r "${TMP}"; rm -f "${LITE_COPY}" "${LITE_COPY}.bak"' EXIT
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

# --- Stubs ---

# Stub claude, first on PATH: prints its argv on one line, then the vars the
# full wrapper would set.
STUB_BIN="${TMP}/stub-bin"
mkdir -p "${STUB_BIN}"
cat >"${STUB_BIN}/claude" <<'EOF'
#!/usr/bin/env bash
printf 'ARGV:'
if [[ $# -gt 0 ]]; then
  printf ' [%s]' "$@"
fi
printf '\n'
printf 'GIT_AUTHOR_NAME=%s\n' "${GIT_AUTHOR_NAME:-}"
printf 'GIT_COMMITTER_NAME=%s\n' "${GIT_COMMITTER_NAME:-}"
printf 'GIT_SSH_COMMAND=%s\n' "${GIT_SSH_COMMAND:-}"
printf 'GH_TOKEN=%s\n' "${GH_TOKEN:-}"
printf 'OP_SERVICE_ACCOUNT_TOKEN=%s\n' "${OP_SERVICE_ACCOUNT_TOKEN:-}"
EOF

# Stub op and security: the full wrapper calls both to fetch secrets. Any call
# is logged, so the suite can check that lite makes none.
CALL_LOG="${TMP}/secret-calls.log"
: >"${CALL_LOG}"
for tool in op security; do
  cat >"${STUB_BIN}/${tool}" <<EOF
#!/usr/bin/env bash
echo "${tool} \$*" >>"${CALL_LOG}"
exit 1
EOF
done

# A stub caffeinate, since CI runs on Linux. It checks for -is, then runs the rest.
cat >"${STUB_BIN}/caffeinate" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-is" ]] || { echo "STUB CAFFEINATE: expected -is, got ${1:-}" >&2; exit 97; }
shift
exec "$@"
EOF
chmod 755 "${STUB_BIN}/claude" "${STUB_BIN}/op" "${STUB_BIN}/security" "${STUB_BIN}/caffeinate"

dollar='$'
sed "s|^CAFF_BIN=\"/usr/bin/caffeinate\"${dollar}|CAFF_BIN=\"${STUB_BIN}/caffeinate\"|" "${LITE}" >"${LITE_COPY}"
chmod 755 "${LITE_COPY}"

# Invoked through a symlink, as from ~/.local/bin
LINK_DIR="${TMP}/local-bin"
mkdir -p "${LINK_DIR}"
ln -s "${LITE_COPY}" "${LINK_DIR}/claude-wrapper-lite"

# Runs lite with no inherited identity or secrets.
run_lite_env() {
  env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    -u GIT_SSH_COMMAND -u GH_TOKEN -u OP_SERVICE_ACCOUNT_TOKEN -u CLAUDE_WRAPPER_VAULT_VARS \
    PATH="${STUB_BIN}:${PATH}" "$@" 2>/dev/null
}
# Runs lite; sets RESULT to the stub's ARGV line, then rc=N.
RESULT=""
run_lite() {
  local out argv rc=0
  out="$(run_lite_env "${LITE_COPY}" "$@")" || rc=$?
  argv="$(grep '^ARGV:' <<<"${out}" || true)"
  RESULT="${argv} rc=${rc}"
}

echo ""
echo "=== static checks on bin/claude-wrapper-lite ==="

assert_equals "1" "$(grep -cxF 'CAFF_BIN="/usr/bin/caffeinate"' "${LITE}" || true)" \
  "caffeinate path is hardcoded"
assert_equals "1" "$(grep -cF "CAFF_BIN=\"${STUB_BIN}/caffeinate\"" "${LITE_COPY}" || true)" \
  "test copy uses the stub caffeinate (the substitution matched)"
assert_equals "0" "$(grep -cF 'command -v caffeinate' "${LITE}" || true)" \
  "caffeinate is not resolved via PATH"
TOTAL_EXECS="$(grep -cE '^[[:space:]]*exec ' "${LITE}" || true)"
CAFF_EXECS="$(grep -cF "exec \"${dollar}{CAFF_BIN}\" -is \"${dollar}{CLAUDE_BIN}\"" "${LITE}" || true)"
assert_equals "${TOTAL_EXECS}" "${CAFF_EXECS}" \
  "every exec goes through caffeinate -is (${CAFF_EXECS} of ${TOTAL_EXECS})"
for lib in credentials secrets-loader git-identity pre-launch path-security launch-dir-check; do
  assert_equals "0" "$(grep -cF "/${lib}.sh" "${LITE}" || true)" \
    "does not source ${lib}.sh"
done
assert_equals "0" "$(grep -cE 'build_remote_control_args|run_pre_launch_hook|inject_secrets' "${LITE}" || true)" \
  "does not call remote control, pre-launch, or secrets functions"

echo ""
echo "=== machine settings through lite ==="

run_lite
assert_equals "ARGV: rc=0" "${RESULT}" \
  "no file: argv unchanged"

printf '{"enabledPlugins": {"cloudflare@cloudflare": true}}\n' >"${FILE}"
chmod 644 "${FILE}"
run_lite
assert_equals "ARGV: [--settings] [${FILE}] rc=0" "${RESULT}" \
  "valid file: --settings <file> added"
run_lite --continue
assert_equals "ARGV: [--settings] [${FILE}] [--continue] rc=0" "${RESULT}" \
  "valid file, caller args kept after the injected ones"
run_lite "fix the deploy"
assert_equals "ARGV: [--settings] [${FILE}] [fix the deploy] rc=0" "${RESULT}" \
  "argument with spaces passed as one argument"

run_lite -p hello
assert_equals "ARGV: [-p] [hello] rc=0" "${RESULT}" \
  "-p: argv unchanged"
run_lite --settings /other.json
assert_equals "ARGV: [--settings] [/other.json] rc=0" "${RESULT}" \
  "caller-supplied --settings: argv unchanged"
run_lite --settings=/other.json
assert_equals "ARGV: [--settings=/other.json] rc=0" "${RESULT}" \
  "caller-supplied --settings=: argv unchanged"

chmod 664 "${FILE}"
run_lite
assert_equals "ARGV: rc=0" "${RESULT}" \
  "group-writable file: argv unchanged"
chmod 644 "${FILE}"

printf '{"enabledPlugins": \n' >"${FILE}"
run_lite
assert_equals "ARGV: rc=0" "${RESULT}" \
  "invalid JSON: argv unchanged"
printf '{}\n' >"${FILE}"

echo ""
echo "=== invocation and isolation ==="

OUT="$(run_lite_env "${LINK_DIR}/claude-wrapper-lite" --continue)" || true
assert_equals "ARGV: [--settings] [${FILE}] [--continue]" "$(grep '^ARGV:' <<<"${OUT}" || true)" \
  "through a symlink: lib found, --settings <file> added"

assert_equals "0" "$(grep -c -- '--remote-control' <<<"${OUT}" || true)" \
  "no --remote-control added"
for var in GIT_AUTHOR_NAME GIT_COMMITTER_NAME GIT_SSH_COMMAND GH_TOKEN OP_SERVICE_ACCOUNT_TOKEN; do
  assert_equals "${var}=" "$(grep "^${var}=" <<<"${OUT}" || true)" \
    "${var} not set"
done
CALLS="$(<"${CALL_LOG}")"
assert_equals "" "${CALLS}" \
  "op and security never called"

# --- Summary ---

echo ""
echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
if [[ "${TESTS_FAILED}" -gt 0 ]]; then
  exit 1
fi
