#!/usr/bin/env bash
# Test suite for lib/reload.sh and bin/claude-reload
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
RELOAD_CMD="${REPO_ROOT}/bin/claude-reload"

# shellcheck source=lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=lib/reload.sh
source "${LIB_DIR}/reload.sh"

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "${TEST_TMP}"' EXIT
export CLAUDE_WRAPPER_STATE_DIR="${TEST_TMP}/state"
export CLAUDE_RELOAD_PROMPT="RELOADED"
# claude-reload looks for the session transcript under CLAUDE_CONFIG_DIR
export CLAUDE_CONFIG_DIR="${TEST_TMP}/config"

SESSION_ID="0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b"
mkdir -p "${CLAUDE_CONFIG_DIR}/projects/-some-project"
touch "${CLAUDE_CONFIG_DIR}/projects/-some-project/${SESSION_ID}.jsonl"

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

# Prints RELOAD_BASE_ARGS for the given args, one per line, wrapped in [] so
# empty and whitespace-only args stay visible
base_args_of() {
  reload_base_args "$@"
  local arg
  for arg in "${RELOAD_BASE_ARGS[@]}"; do
    printf '[%s]\n' "${arg}"
  done
}

status_of() {
  if "$@" >/dev/null 2>&1; then echo 0; else echo $?; fi
}

# Fake `caffeinate -is claude`: logs args to runs/<n>. Run 1 can run /reload;
# later runs exit MOCK_FINAL_RC.
make_mock_launcher() {
  local path="$1"
  cat >"${path}" <<'EOF'
#!/usr/bin/env bash
dir="${MOCK_DIR:?}"
n=$(($(find "${dir}/runs" -type f | wc -l) + 1))
printf '%s\n' "$@" >"${dir}/runs/${n}"
if [[ "${n}" -eq 1 && "${MOCK_RELOAD_ON_FIRST:-0}" == "1" ]]; then
  bash -c '"${CLAUDE_WRAPPER_RELOAD_CMD}"' >"${dir}/requester.out" 2>&1
  sleep 5 &
  wait
  exit 99 # only reached if the signal never arrived
fi
exit "${MOCK_FINAL_RC:-0}"
EOF
  chmod +x "${path}"
}

new_mock_dir() {
  local dir
  dir="$(mktemp -d "${TEST_TMP}/mock.XXXXXX")"
  mkdir -p "${dir}/runs"
  echo "${dir}"
}

# --- reload_base_args ---
echo ""
echo "=== reload_base_args ==="

# Each check assigns before asserting, so a failing command substitution is
# not masked inside an argument list
check_base_args() {
  local message="$1"
  shift
  local -a expected=()
  while [[ "$1" != "--" ]]; do
    expected+=("$1")
    shift
  done
  shift
  local want got
  want="$(printf '[%s]\n' "${expected[@]}")"
  got="$(base_args_of "$@")"
  assert_equals "${want}" "${got}" "${message}"
}

check_base_args "drops the trailing prompt and keeps flags" \
  --remote-control repo --dangerously-skip-permissions -- \
  --remote-control repo --dangerously-skip-permissions "review this URL"
check_base_args "keeps a trailing value of a value-taking flag" \
  --remote-control repo --model opus -- --remote-control repo --model opus
check_base_args "keeps the --remote-control name when no prompt follows" \
  --remote-control repo -- --remote-control repo
check_base_args "drops -c/--continue" \
  --verbose -- --continue --verbose -c
check_base_args "drops --resume and --session-id with their values" \
  --verbose -- --resume abc --verbose --session-id "${SESSION_ID}"
check_base_args "drops a bare --resume without eating the next flag" \
  --model opus -- --resume --model opus
check_base_args "drops --resume=<id> and --fork-session" \
  --verbose -- --resume=abc --fork-session --verbose
check_base_args "drops a prompt between flags" \
  --verbose --model opus -- --verbose "do X" --model opus
check_base_args "keeps every value of a variadic flag" \
  --add-dir /a /b -- --add-dir /a /b
check_base_args "a flag ends a variadic list, so a later prompt is dropped" \
  --add-dir /a /b --verbose -- --add-dir /a /b --verbose "do X"

nl_value="line one
line two"
reload_base_args --append-system-prompt "${nl_value}" "a prompt"
assert_equals "2|--append-system-prompt|${nl_value}" \
  "${#RELOAD_BASE_ARGS[@]}|${RELOAD_BASE_ARGS[0]}|${RELOAD_BASE_ARGS[1]}" \
  "keeps a flag value that contains a newline"

reload_base_args "only a prompt"
assert_equals "0" "${#RELOAD_BASE_ARGS[@]}" "a lone prompt leaves no args"

# --- reload_supported ---
echo ""
echo "=== reload_supported ==="

got="$(status_of reload_supported --remote-control repo --model opus "hi")"
assert_equals "0" "${got}" "ordinary interactive args support reload"
got="$(status_of reload_supported -w)"
assert_equals "1" "${got}" "-w disables reload"
got="$(status_of reload_supported --worktree=feature)"
assert_equals "1" "${got}" "--worktree=<name> disables reload"
got="$(status_of reload_supported --tmux)"
assert_equals "1" "${got}" "--tmux disables reload"

# --- reload_consume_marker ---
echo ""
echo "=== reload_consume_marker ==="

marker="${TEST_TMP}/marker"
got="$(status_of reload_consume_marker "${marker}")"
assert_equals "1" "${got}" "no marker means no relaunch"

printf '%s\n' "${SESSION_ID}" >"${marker}"
got="$(reload_consume_marker "${marker}")"
assert_equals "${SESSION_ID}" "${got}" "returns the session ID"
got="present"
[[ -e "${marker}" ]] || got="absent"
assert_equals "absent" "${got}" "removes the marker"

printf 'new\n' >"${marker}"
got="$(reload_consume_marker "${marker}")"
assert_equals "new" "${got}" "passes through the fresh-session request"

printf '%s\n' '--settings=/tmp/evil.json' >"${marker}"
got="$(reload_consume_marker "${marker}" 2>/dev/null)"
assert_equals "" "${got}" "rejects a marker value that is not a session ID"

ln -s /dev/null "${marker}"
got="$(status_of reload_consume_marker "${marker}")"
assert_equals "1" "${got}" "ignores a symlinked marker"
rm -f "${marker}"

# --- run_with_reload ---
echo ""
echo "=== run_with_reload ==="

count_runs() {
  local -a files=("${MOCK_DIR}/runs/"*)
  [[ -e "${files[0]}" ]] || files=()
  echo "${#files[@]}"
}

mock="${TEST_TMP}/launcher"
make_mock_launcher "${mock}"

MOCK_DIR="$(new_mock_dir)"
export MOCK_DIR MOCK_FINAL_RC=7 MOCK_RELOAD_ON_FIRST=1 CLAUDE_CODE_SESSION_ID="${SESSION_ID}"
rc=0
run_with_reload "${mock}" -- --remote-control repo --verbose "first prompt" 2>/dev/null || rc=$?
assert_equals "7" "${rc}" "returns the exit code of the final run"
got="$(count_runs)"
assert_equals "2" "${got}" "relaunches exactly once"
want="$(printf '%s\n' --remote-control repo --verbose --resume "${SESSION_ID}" RELOADED)"
got="$(<"${MOCK_DIR}/runs/2")"
assert_equals "${want}" "${got}" "relaunch resumes the session and does not resend the first prompt"

# /reload as the first message: no transcript yet, so relaunch fresh
MOCK_DIR="$(new_mock_dir)"
export MOCK_DIR MOCK_FINAL_RC=0 MOCK_RELOAD_ON_FIRST=1
CLAUDE_CODE_SESSION_ID="11111111-2222-3333-4444-555555555555" \
  run_with_reload "${mock}" -- --remote-control repo "first prompt" 2>/dev/null
want="$(printf '%s\n' --remote-control repo)"
got="$(<"${MOCK_DIR}/runs/2")"
assert_equals "${want}" "${got}" "a session with no transcript relaunches fresh"

MOCK_DIR="$(new_mock_dir)"
export MOCK_DIR MOCK_FINAL_RC=5 MOCK_RELOAD_ON_FIRST=0
rc=0
run_with_reload "${mock}" -- --verbose 2>/dev/null || rc=$?
got="$(count_runs)"
assert_equals "5|1" "${rc}|${got}" "an exit without a reload request does not relaunch"

# A session that asks to reload on every start must not loop forever
cat >"${TEST_TMP}/always-reload" <<'EOF'
#!/usr/bin/env bash
echo run >>"${MOCK_DIR}/all-runs"
bash -c '"${CLAUDE_WRAPPER_RELOAD_CMD}"' >/dev/null 2>&1
sleep 5 &
wait
EOF
chmod +x "${TEST_TMP}/always-reload"
MOCK_DIR="$(new_mock_dir)"
export MOCK_DIR
rc=0
run_with_reload "${TEST_TMP}/always-reload" -- --verbose 2>"${MOCK_DIR}/stderr" >/dev/null || rc=$?
mapfile -t all_runs <"${MOCK_DIR}/all-runs"
assert_equals "3" "${#all_runs[@]}" "stops relaunching after 3 quick reloads in a row"
stopped=0
grep -q 'reloads in a row' "${MOCK_DIR}/stderr" || stopped=1
assert_equals "129|0" "${rc}|${stopped}" "returns the last exit code and says why it stopped"

# With reload unsupported, claude must see no reload env, so /reload says why
cat >"${TEST_TMP}/env-dump" <<'EOF'
#!/usr/bin/env bash
count=0
for var in CLAUDE_WRAPPER_PID CLAUDE_WRAPPER_RELOAD_FILE CLAUDE_WRAPPER_RELOAD_CMD; do
  [[ -n "${!var:-}" ]] && ((count += 1))
done
echo "${count}" >"${MOCK_DIR}/env-count"
echo "$*" >"${MOCK_DIR}/args"
EOF
chmod +x "${TEST_TMP}/env-dump"
MOCK_DIR="$(new_mock_dir)"
export MOCK_DIR
run_with_reload "${TEST_TMP}/env-dump" -- -w "a prompt"
got="$(<"${MOCK_DIR}/env-count")|$(<"${MOCK_DIR}/args")"
assert_equals "0|-w a prompt" "${got}" \
  "with reload unsupported, launches unchanged and exports no reload env"

MOCK_DIR="$(new_mock_dir)"
export MOCK_DIR
run_with_reload "${TEST_TMP}/env-dump" -- --verbose
got="$(<"${MOCK_DIR}/env-count")"
assert_equals "3" "${got}" "with reload supported, exports the reload env"

# --- bin/claude-reload ---
echo ""
echo "=== claude-reload ==="

rc=0
out="$(env -u CLAUDE_WRAPPER_PID -u CLAUDE_WRAPPER_RELOAD_FILE "${RELOAD_CMD}" 2>&1)" || rc=$?
explained=0
[[ "${out}" == *"not started by claude-wrapper"* ]] || explained=1
assert_equals "1|0" "${rc}|${explained}" "fails outside claude-wrapper and explains why"

# Nested session: an inner "claude" (bash via symlink, so comm says claude)
# runs the requester, which must refuse.
nested_dir="${TEST_TMP}/nested/bin"
mkdir -p "${nested_dir}"
bash_bin="$(command -v bash)"
ln -s "${bash_bin}" "${nested_dir}/claude"
cat >"${TEST_TMP}/outer" <<EOF
#!/usr/bin/env bash
"${nested_dir}/claude" -c '"\${CLAUDE_WRAPPER_RELOAD_CMD}" >"\${MOCK_DIR}/requester.out" 2>&1; true'
exit 3
EOF
chmod +x "${TEST_TMP}/outer"
MOCK_DIR="$(new_mock_dir)"
export MOCK_DIR
rc=0
run_with_reload "${TEST_TMP}/outer" -- --verbose 2>/dev/null || rc=$?
assert_equals "3" "${rc}" "a nested session does not kill or reload the outer one"
refused=0
grep -q 'nested claude session' "${MOCK_DIR}/requester.out" || refused=1
assert_equals "0" "${refused}" "a nested session explains the refusal"

# --- Summary ---
echo ""
echo "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
if [[ ${TESTS_FAILED} -gt 0 ]]; then
  echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
  exit 1
fi
echo "Tests failed: 0"
