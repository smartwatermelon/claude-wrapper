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

# shellcheck source=tests/lib/op-guard.sh
source "${TEST_DIR}/lib/op-guard.sh"

# Every stub dir this suite creates nests under TEST_TMP, so the single
# EXIT trap below sweeps all of them even if a test fails partway through
# under set -euo pipefail — see issue #70. op_guard_verify runs first so it
# still catches a clobbered system `op` even on early failure (see #79).
TEST_TMP="$(mktemp -d)"
trap 'op_guard_verify; rm -rf "${TEST_TMP}"' EXIT
op_guard_snapshot

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
    # `command -v` returns the NAME, not a path, when the caller's shell has a
    # function or alias of that name — a symlink to that string is broken, and
    # the binary then appears absent inside the stub. `type -P` searches PATH
    # only, so it always yields a real executable path or nothing.
    real_bin="$(type -P "${bin}" 2>/dev/null || true)"
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
#
# The per-owner vars are preset so _load_owner_gh_tokens takes its already-set
# path and reads nothing: this assertion counts _load_gh_token's calls, and a
# shared call log would otherwise attribute all four reads to it. Presetting
# rather than filtering keeps the count exact instead of merely plausible.
# They must be set explicitly here — inheriting them from the developer's live
# environment is what let this pass locally while failing in CI.
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
    GH_TOKEN_SWM="preset" GH_TOKEN_NOS="preset" GH_TOKEN_TWM="preset" \
    bash -c "unset GH_TOKEN; source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/credentials.sh'; echo \"\${GH_TOKEN:-unset}\"" 2>/dev/null
)"
assert_equals "vault-gh-token" "${result}" \
  "op read succeeds -> GH_TOKEN exported from vault"
# shellcheck disable=SC2312  # exit status of wc/tr intentionally discarded; this assertion checks captured output, not command success
assert_equals "1" "$(wc -l <"${call_log}" | tr -d ' ')" \
  "op read succeeds on first attempt -> called exactly once"

# op read fails (all attempts) -> GH_TOKEN exported as the invalid sentinel,
# NOT left unset. Leaving it unset would let gh fall back to the user's keyring
# OAuth token (repo/workflow/admin:org), silently widening the agent's access
# on any transient vault failure. Fail closed instead.
stub_dir="$(make_stub_dir env bash cat id security timeout)"
cat >"${stub_dir}/op" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "${stub_dir}/op"
result="$(
  PATH="${stub_dir}" \
    OP_SERVICE_ACCOUNT_TOKEN="dummy" \
    bash -c "unset GH_TOKEN; source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/credentials.sh'; echo \"\${GH_TOKEN:-unset}\"" 2>/dev/null
)"
assert_equals "invalid-cccli-token-vault-fetch-failed" "${result}" \
  "op read fails -> GH_TOKEN set to invalid sentinel (fails closed, no keyring fallback)"

# The same failure must warn, so a degraded session is visible rather than silent.
warn_output="$(
  PATH="${stub_dir}" \
    OP_SERVICE_ACCOUNT_TOKEN="dummy" \
    bash -c "unset GH_TOKEN; source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/credentials.sh'" 2>&1 1>/dev/null
)"
assert_contains "gh disabled for this session" "${warn_output}" \
  "op read fails -> warns that gh is disabled"

# A previously-set sentinel must not short-circuit a later retry: it is a
# failure marker, not a real token.
stub_dir="$(make_stub_dir env bash cat id security timeout)"
cat >"${stub_dir}/op" <<'EOF'
#!/usr/bin/env bash
echo "recovered-gh-token"
EOF
chmod +x "${stub_dir}/op"
result="$(
  PATH="${stub_dir}" \
    OP_SERVICE_ACCOUNT_TOKEN="dummy" \
    GH_TOKEN="invalid-cccli-token-vault-fetch-failed" \
    bash -c "source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/credentials.sh'; echo \"\${GH_TOKEN:-unset}\"" 2>/dev/null
)"
assert_equals "recovered-gh-token" "${result}" \
  "sentinel present -> vault lookup still runs (sentinel is not a valid preset)"

# --- Tests: owner-keyed token selection ---

echo ""
echo "=== owner-keyed token selection ==="

# Builds a git repo whose origin remote is $1, so owner derivation has a real
# remote to read. `git init -q` is enough — nothing here needs a commit.
# `git init` output is discarded rather than captured: an init hook or template
# on the developer's machine can print a banner to stdout, which would
# otherwise be concatenated onto the directory path this function returns.
make_repo_with_remote() {
  local url="$1" dir
  dir="$(mktemp -d "${TEST_TMP}/repo.XXXXXX")"
  git -C "${dir}" init -q >/dev/null 2>&1
  [[ -n "${url}" ]] && git -C "${dir}" remote add origin "${url}" >/dev/null 2>&1
  printf '%s' "${dir}"
}

# Resolves the vault ref chosen when the wrapper is sourced from $1. The op
# stub echoes the ref it was asked for, so the exported GH_TOKEN *is* the ref
# — which is what these assertions check.
ref_selected_from() {
  local dir="$1" stub
  stub="$(make_stub_dir env bash cat id security timeout git)"
  cat >"${stub}/op" <<'EOF'
#!/usr/bin/env bash
# Echo the requested ref back so the caller can assert on it. `op read REF`
# puts the ref in $2.
echo "$2"
EOF
  chmod +x "${stub}/op"
  (
    cd "${dir}" || exit 1
    PATH="${stub}" \
      OP_SERVICE_ACCOUNT_TOKEN="dummy" \
      bash -c "unset GH_TOKEN; source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/credentials.sh'; echo \"\${GH_TOKEN:-unset}\"" 2>/dev/null
  )
}

# An org remote selects that org's token, not the personal one. This is the
# regression in #120: a single personal-owner PAT cannot see org repos at all.
repo_dir="$(make_repo_with_remote "git@github.com:smartwatermelon/claude-wrapper.git")"
assert_equals "op://Automation/CCCLI-SWM/token" "$(ref_selected_from "${repo_dir}")" \
  "smartwatermelon remote -> SWM token ref"

repo_dir="$(make_repo_with_remote "git@github.com:nightowlstudiollc/night-owl-studio.git")"
assert_equals "op://Automation/CCCLI-NOS/token" "$(ref_selected_from "${repo_dir}")" \
  "nightowlstudiollc remote -> NOS token ref"

# The personal owner keeps the original ref — it still covers ~33 repos.
repo_dir="$(make_repo_with_remote "git@github.com:twistedmelonman/something.git")"
assert_equals "op://Automation/GitHub - CCCLI/Token" "$(ref_selected_from "${repo_dir}")" \
  "twistedmelonman remote -> personal token ref"

# https remotes must parse identically to scp-style ones.
repo_dir="$(make_repo_with_remote "https://github.com/smartwatermelon/claude-wrapper.git")"
assert_equals "op://Automation/CCCLI-SWM/token" "$(ref_selected_from "${repo_dir}")" \
  "https remote -> same owner as scp-style remote"

# ssh://git@github.com/owner/repo is a valid remote form that a naive
# scp-style-only pattern does not match.
repo_dir="$(make_repo_with_remote "ssh://git@github.com/nightowlstudiollc/x.git")"
assert_equals "op://Automation/CCCLI-NOS/token" "$(ref_selected_from "${repo_dir}")" \
  "ssh:// remote form -> owner parsed correctly"

# An unknown org falls back to the personal token rather than guessing. It
# fails loudly with a permissions error, which beats silently trying a token
# that cannot work.
repo_dir="$(make_repo_with_remote "git@github.com:someotherorg/repo.git")"
assert_equals "op://Automation/GitHub - CCCLI/Token" "$(ref_selected_from "${repo_dir}")" \
  "unknown owner -> personal token ref (fallback)"

# A non-GitHub remote must yield no owner. A sed-based parser passes its input
# through unchanged when the pattern does not match, which would put an entire
# URL where an owner name belongs.
repo_dir="$(make_repo_with_remote "https://gitlab.com/someone/thing.git")"
assert_equals "op://Automation/GitHub - CCCLI/Token" "$(ref_selected_from "${repo_dir}")" \
  "non-GitHub remote -> personal token ref (owner not derivable)"

# A git repo with no origin remote at all.
repo_dir="$(make_repo_with_remote "")"
assert_equals "op://Automation/GitHub - CCCLI/Token" "$(ref_selected_from "${repo_dir}")" \
  "repo without origin remote -> personal token ref"

# Not a git repo — the pre-#120 behavior for sessions launched outside a repo.
repo_dir="$(mktemp -d "${TEST_TMP}/plain.XXXXXX")"
assert_equals "op://Automation/GitHub - CCCLI/Token" "$(ref_selected_from "${repo_dir}")" \
  "non-repo directory -> personal token ref"

# A subdirectory resolves to the enclosing repo's owner, since the wrapper is
# frequently launched from somewhere below the git root.
repo_dir="$(make_repo_with_remote "git@github.com:smartwatermelon/claude-wrapper.git")"
mkdir -p "${repo_dir}/nested/deeper"
assert_equals "op://Automation/CCCLI-SWM/token" "$(ref_selected_from "${repo_dir}/nested/deeper")" \
  "subdirectory of a repo -> enclosing repo's owner"

# --- Per-owner token loading (_load_owner_gh_tokens) ---
#
# These assert only against the fixed sentinel literal and stub-supplied
# values. No assertion prints a real credential, and the stub `op` never
# returns one — a test that must echo a live token to prove itself is the
# test that leaks it.

# KNOWN-BAD GATE. Before asserting that the three vars get set, prove the
# assertion can fail: with no OP_SERVICE_ACCOUNT_TOKEN, nothing is exported
# and op is never called. A suite that only ever sees the success path cannot
# distinguish "loaded correctly" from "assertion never ran".
stub_dir="$(make_stub_dir env bash cat id timeout)"
call_log="${stub_dir}/op-calls.log"
cat >"${stub_dir}/op" <<EOF
#!/usr/bin/env bash
echo "call" >>"${call_log}"
echo "should-never-be-reached"
EOF
chmod +x "${stub_dir}/op"
result="$(
  PATH="${stub_dir}" \
    bash -c "unset OP_SERVICE_ACCOUNT_TOKEN GH_TOKEN GH_TOKEN_SWM GH_TOKEN_NOS GH_TOKEN_TWM; source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/credentials.sh'; echo \"\${GH_TOKEN_SWM:-unset}/\${GH_TOKEN_NOS:-unset}/\${GH_TOKEN_TWM:-unset}\"" 2>/dev/null
)"
assert_equals "unset/unset/unset" "${result}" \
  "no OP_SERVICE_ACCOUNT_TOKEN -> per-owner tokens not exported"
assert_equals "" "$([[ -f "${call_log}" ]] && cat "${call_log}" || true)" \
  "no OP_SERVICE_ACCOUNT_TOKEN -> op never invoked for per-owner tokens"

# All three refs resolve -> all three vars exported, each from its own ref.
# The stub echoes the ref it was asked for, so a var populated from the wrong
# ref is visible rather than merely non-empty.
stub_dir="$(make_stub_dir env bash cat id security timeout)"
cat >"${stub_dir}/op" <<'EOF'
#!/usr/bin/env bash
# args: read <ref>
case "$2" in
  "op://Automation/CCCLI-SWM/token") echo "tok-swm" ;;
  "op://Automation/CCCLI-NOS/token") echo "tok-nos" ;;
  "op://Automation/GitHub - CCCLI/Token") echo "tok-twm" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${stub_dir}/op"
result="$(
  PATH="${stub_dir}" \
    OP_SERVICE_ACCOUNT_TOKEN="dummy" \
    bash -c "unset GH_TOKEN GH_TOKEN_SWM GH_TOKEN_NOS GH_TOKEN_TWM; source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/credentials.sh'; echo \"\${GH_TOKEN_SWM}/\${GH_TOKEN_NOS}/\${GH_TOKEN_TWM}\"" 2>/dev/null
)"
assert_equals "tok-swm/tok-nos/tok-twm" "${result}" \
  "all refs resolve -> each per-owner var loaded from its own ref"

# FAIL-CLOSED PATH. Every ref fails -> each var holds the invalid sentinel,
# never an empty string. An empty value would let gh fall through to the
# keyring OAuth token (repo/workflow/admin:org), silently widening scope on a
# transient vault failure. This is the assertion the export flagged as
# unverified; it is safe because the sentinel is a fixed literal, not a token.
stub_dir="$(make_stub_dir env bash cat id security timeout)"
cat >"${stub_dir}/op" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "${stub_dir}/op"
result="$(
  PATH="${stub_dir}" \
    OP_SERVICE_ACCOUNT_TOKEN="dummy" \
    bash -c "unset GH_TOKEN GH_TOKEN_SWM GH_TOKEN_NOS GH_TOKEN_TWM; source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/credentials.sh'; echo \"\${GH_TOKEN_SWM}/\${GH_TOKEN_NOS}/\${GH_TOKEN_TWM}\"" 2>/dev/null
)"
assert_equals "invalid-cccli-token-vault-fetch-failed/invalid-cccli-token-vault-fetch-failed/invalid-cccli-token-vault-fetch-failed" "${result}" \
  "all refs fail -> every per-owner var set to the invalid sentinel (fails closed)"

# A partial failure must not poison the refs that did resolve: one bad ref
# fails closed on its own var only. Mixed outcomes are the realistic vault
# failure, and the dangerous version is one failure zeroing the others.
stub_dir="$(make_stub_dir env bash cat id security timeout)"
cat >"${stub_dir}/op" <<'EOF'
#!/usr/bin/env bash
case "$2" in
  "op://Automation/CCCLI-NOS/token") exit 1 ;;
  "op://Automation/CCCLI-SWM/token") echo "tok-swm" ;;
  "op://Automation/GitHub - CCCLI/Token") echo "tok-twm" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${stub_dir}/op"
result="$(
  PATH="${stub_dir}" \
    OP_SERVICE_ACCOUNT_TOKEN="dummy" \
    bash -c "unset GH_TOKEN GH_TOKEN_SWM GH_TOKEN_NOS GH_TOKEN_TWM; source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/credentials.sh'; echo \"\${GH_TOKEN_SWM}/\${GH_TOKEN_NOS}/\${GH_TOKEN_TWM}\"" 2>/dev/null
)"
assert_equals "tok-swm/invalid-cccli-token-vault-fetch-failed/tok-twm" "${result}" \
  "one ref fails -> only that var gets the sentinel, others keep their tokens"

# The fail-closed path must warn, so a degraded session is visible. A silent
# sentinel looks identical to a working token until a gh call fails oddly.
stub_dir="$(make_stub_dir env bash cat id security timeout)"
cat >"${stub_dir}/op" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "${stub_dir}/op"
warn_output="$(
  PATH="${stub_dir}" \
    OP_SERVICE_ACCOUNT_TOKEN="dummy" \
    bash -c "unset GH_TOKEN GH_TOKEN_SWM GH_TOKEN_NOS GH_TOKEN_TWM; source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/credentials.sh'" 2>&1 1>/dev/null
)"
assert_contains "Failed to fetch GH_TOKEN_SWM from 1Password" "${warn_output}" \
  "per-owner fetch failure warns rather than failing silently"

# An already-set var is respected and costs no vault read — matching
# _load_gh_token. The stub exits non-zero, so a lookup would overwrite the
# pre-set value with the sentinel and fail this assertion.
stub_dir="$(make_stub_dir env bash cat id security timeout)"
call_log="${stub_dir}/op-calls.log"
cat >"${stub_dir}/op" <<EOF
#!/usr/bin/env bash
echo "\$2" >>"${call_log}"
exit 1
EOF
chmod +x "${stub_dir}/op"
result="$(
  PATH="${stub_dir}" \
    OP_SERVICE_ACCOUNT_TOKEN="dummy" \
    GH_TOKEN_SWM="preset-swm" \
    bash -c "unset GH_TOKEN GH_TOKEN_NOS GH_TOKEN_TWM; source '${LIB_DIR}/logging.sh'; source '${LIB_DIR}/credentials.sh'; echo \"\${GH_TOKEN_SWM}\"" 2>/dev/null
)"
assert_equals "preset-swm" "${result}" \
  "already-set per-owner var is preserved, not overwritten"
assert_equals "" "$(grep -F "op://Automation/CCCLI-SWM/token" "${call_log}" 2>/dev/null || true)" \
  "already-set per-owner var -> its ref is never read from the vault"

# --- Summary ---

echo ""
echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
if [[ "${TESTS_FAILED}" -gt 0 ]]; then
  exit 1
fi
