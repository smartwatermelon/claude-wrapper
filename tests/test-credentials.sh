#!/usr/bin/env bash
# Test suite for lib/credentials.sh
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

# Every stub dir this suite creates nests under TEST_TMP, so the single
# EXIT trap below sweeps all of them even if a test fails partway through
# under set -euo pipefail — see issue #70.
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "${TEST_TMP}"' EXIT

# --- Helpers ---

# Builds a stub bin dir containing only the named real binaries (symlinked),
# so `command -v <bin>` genuinely fails for anything not listed. Called via
# command substitution (a subshell), so it can't rely on a shared counter
# variable to keep names unique — mktemp -d under TEST_TMP does that instead.
make_stub_dir() {
  local stub_dir
  stub_dir="$(mktemp -d "${TEST_TMP}/stub.XXXXXX")"
  local bin real_bin
  for bin in "$@"; do
    real_bin="$(command -v "${bin}" 2>/dev/null || true)"
    [[ -n "${real_bin}" ]] && ln -s "${real_bin}" "${stub_dir}/${bin}"
  done
  echo "${stub_dir}"
}

assert_equals() {
  local expected="$1" actual="$2" message="$3"
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
  local needle="$1" haystack="$2" message="$3"
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

# --- Tests: _load_service_account_token ---

echo ""
echo "=== _load_service_account_token ==="

# OP_SERVICE_ACCOUNT_TOKEN already set -> Keychain lookup skipped entirely.
debug_output="$(
  OP_SERVICE_ACCOUNT_TOKEN="preset-token" \
    CLAUDE_DEBUG=true \
    bash -c "source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/credentials.sh'" 2>&1 1>/dev/null
)"
assert_contains "already set, skipping Keychain lookup" "${debug_output}" \
  "OP_SERVICE_ACCOUNT_TOKEN preset -> Keychain lookup skipped"

# Non-macOS guard (issue #63): `security` unavailable -> quiet debug_log,
# no misleading log_warn about the Keychain. This is the exact code path
# introduced alongside the guard and previously had no test coverage.
stub_dir="$(make_stub_dir env bash cat op)"
debug_output="$(
  PATH="${stub_dir}" \
    CLAUDE_DEBUG=true \
    bash -c "unset OP_SERVICE_ACCOUNT_TOKEN GH_TOKEN; source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/credentials.sh'" 2>&1 1>/dev/null
)"
assert_contains "security command not available (non-macOS), skipping Keychain lookup" "${debug_output}" \
  "security unavailable -> debug_log notes non-macOS, lookup skipped"
assert_equals "" "$(grep -i "not found in Keychain" <<<"${debug_output}" || true)" \
  "security unavailable -> no misleading 'not found in Keychain' warning"

# security present but the lookup fails (e.g. no matching Keychain entry) ->
# warns, doesn't export OP_SERVICE_ACCOUNT_TOKEN.
stub_dir="$(make_stub_dir env bash cat id timeout)"
cat >"${stub_dir}/security" <<'EOF'
#!/usr/bin/env bash
exit 44
EOF
chmod +x "${stub_dir}/security"
debug_output="$(
  PATH="${stub_dir}" \
    CLAUDE_DEBUG=true \
    bash -c "unset OP_SERVICE_ACCOUNT_TOKEN GH_TOKEN; source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/credentials.sh'; echo \"RESULT=\${OP_SERVICE_ACCOUNT_TOKEN:-unset}\"" 2>&1
)"
assert_contains "RESULT=unset" "${debug_output}" \
  "Keychain lookup fails -> OP_SERVICE_ACCOUNT_TOKEN stays unset"
assert_contains "1Password service account token not found in Keychain" "${debug_output}" \
  "Keychain lookup fails -> warns"

# security present and succeeds -> token exported.
stub_dir="$(make_stub_dir env bash cat id timeout)"
cat >"${stub_dir}/security" <<'EOF'
#!/usr/bin/env bash
echo "found-token-value"
EOF
chmod +x "${stub_dir}/security"
result="$(
  PATH="${stub_dir}" \
    bash -c "unset OP_SERVICE_ACCOUNT_TOKEN GH_TOKEN; source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/credentials.sh'; echo \"\${OP_SERVICE_ACCOUNT_TOKEN:-unset}\"" 2>/dev/null
)"
assert_equals "found-token-value" "${result}" \
  "Keychain lookup succeeds -> OP_SERVICE_ACCOUNT_TOKEN exported"

# --- Tests: _load_gh_token ---

echo ""
echo "=== _load_gh_token ==="

# GH_TOKEN already set -> vault lookup skipped.
debug_output="$(
  GH_TOKEN="preset-gh-token" \
    OP_SERVICE_ACCOUNT_TOKEN="dummy" \
    CLAUDE_DEBUG=true \
    bash -c "source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/credentials.sh'" 2>&1 1>/dev/null
)"
assert_contains "GH_TOKEN already set, skipping vault lookup" "${debug_output}" \
  "GH_TOKEN preset -> vault lookup skipped"

# OP_SERVICE_ACCOUNT_TOKEN unavailable -> GH_TOKEN fetch skipped (no op call).
# `security` is deliberately omitted from the stub PATH so the Keychain
# lookup can't populate OP_SERVICE_ACCOUNT_TOKEN from a real dev-machine
# entry — this test needs it to genuinely stay unset.
stub_dir="$(make_stub_dir env bash cat id timeout)"
call_log="${stub_dir}/op-calls.log"
cat >"${stub_dir}/op" <<EOF
#!/usr/bin/env bash
echo "call" >>"${call_log}"
exit 1
EOF
chmod +x "${stub_dir}/op"
debug_output="$(
  PATH="${stub_dir}" \
    CLAUDE_DEBUG=true \
    bash -c "unset OP_SERVICE_ACCOUNT_TOKEN GH_TOKEN; source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/credentials.sh'" 2>&1 1>/dev/null
)"
assert_contains "Skipping GH_TOKEN fetch: OP_SERVICE_ACCOUNT_TOKEN not available" "${debug_output}" \
  "No OP_SERVICE_ACCOUNT_TOKEN -> GH_TOKEN fetch skipped"
assert_equals "" "$([[ -f "${call_log}" ]] && cat "${call_log}" || true)" \
  "No OP_SERVICE_ACCOUNT_TOKEN -> op never invoked"

# OP_SERVICE_ACCOUNT_TOKEN available, op read succeeds on first try (with
# timeout available) -> GH_TOKEN exported, single call.
stub_dir="$(make_stub_dir env bash cat id security timeout)"
call_log="${stub_dir}/op-calls.log"
cat >"${stub_dir}/op" <<EOF
#!/usr/bin/env bash
echo "call" >>"${call_log}"
echo "vault-gh-token"
EOF
chmod +x "${stub_dir}/op"
result="$(
  PATH="${stub_dir}" \
    OP_SERVICE_ACCOUNT_TOKEN="dummy" \
    bash -c "unset GH_TOKEN; source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/credentials.sh'; echo \"\${GH_TOKEN:-unset}\"" 2>/dev/null
)"
assert_equals "vault-gh-token" "${result}" \
  "op read succeeds -> GH_TOKEN exported from vault"
assert_equals "1" "$(wc -l <"${call_log}" | tr -d ' ')" \
  "op read succeeds on first attempt -> called exactly once"

# --- Summary ---

echo ""
echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
if [[ "${TESTS_FAILED}" -gt 0 ]]; then
  exit 1
fi
