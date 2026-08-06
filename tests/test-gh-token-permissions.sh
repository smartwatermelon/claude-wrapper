#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# GitHub Token Permission Test Suite for Claude Code Wrapper
#
# Purpose: Verify that the claude-wrapper's restricted PAT enforces the
# intended permission boundaries. Run this FROM a claude-wrapper session
# to test the live environment.
#
# Usage:
#   Ask Claude Code (via wrapper): "Run ~/Developer/claude-wrapper/tests/test-gh-token-permissions.sh"
#
# What it tests:
#   1. Environment: wrapper-injected identity and token are active
#   2. ALLOWED operations: PRs, branches, CI status (should succeed)
#   3. REPO-SCOPE boundary: branch protection/settings/collaborators/deploy
#      keys/webhooks all SUCCEED (classic PAT `repo` scope grants these —
#      not deniable), only repo deletion is genuinely blocked (403, missing
#      `delete_repo` scope)
#   4. MERGE PROTECTION: branch protection blocks self-merge (should fail)
#
# Cleanup: Creates a temporary branch + PR, then deletes both on exit.
# =============================================================================

# --- Config ---
# Dedicated sandbox repo — DO NOT point this at a real project repo (e.g.
# claude-config). Section 3 below fires live mutating requests (branch
# protection writes, repo settings PATCH, collaborator/deploy-key/webhook
# creation) to establish the actual permission boundary. Most of these
# SUCCEED with a classic PAT + `repo` scope (GitHub doesn't gate them behind
# a separate admin scope), so running this against a repo you care about
# will actually mutate its live settings. See feedback memory
# "test-gh-token-permissions-live-mutations" for the incident that led here.
TEST_REPO="smartwatermelon/test-gh-token-permissions" # Sandbox repo — safe to mutate
TEST_BRANCH="test/token-permissions-$(date +%s)"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Counters ---
PASS=0
FAIL=0
SKIP=0
TEST_PR_NUMBER=""

# --- Cleanup ---
# shellcheck disable=SC2329  # invoked indirectly via `trap cleanup EXIT` below
cleanup() {
  echo ""
  echo -e "${CYAN}--- Cleanup ---${NC}"

  # Close PR if created
  if [[ -n "${TEST_PR_NUMBER}" ]]; then
    echo "Closing test PR #${TEST_PR_NUMBER}..."
    gh pr close "${TEST_PR_NUMBER}" --repo "${TEST_REPO}" --delete-branch 2>/dev/null || true
  fi

  # Delete remote branch if it exists
  if git ls-remote --exit-code --heads "git@github.com:${TEST_REPO}.git" "${TEST_BRANCH}" &>/dev/null; then
    echo "Deleting remote branch ${TEST_BRANCH}..."
    git push "git@github.com:${TEST_REPO}.git" --delete "${TEST_BRANCH}" 2>/dev/null || true
  fi

  # Remove local temp directory
  if [[ -n "${WORK_DIR:-}" ]] && [[ -d "${WORK_DIR}" ]]; then
    rm -rf "${WORK_DIR}"
  fi

  echo "Cleanup complete."
}
trap cleanup EXIT

# --- Helpers ---
pass() {
  ((PASS += 1))
  echo -e "  ${GREEN}PASS${NC} $1"
}

fail() {
  ((FAIL += 1))
  echo -e "  ${RED}FAIL${NC} $1"
  [[ -n "${2:-}" ]] && echo -e "       ${RED}$2${NC}"
}

skip() {
  ((SKIP += 1))
  echo -e "  ${YELLOW}SKIP${NC} $1"
}

section() {
  echo ""
  echo -e "${BOLD}${CYAN}═══ $1 ═══${NC}"
}

# =============================================================================
# GUARD: Must be run inside a claude-wrapper session
# =============================================================================
# GIT_AUTHOR_NAME is only set by git-identity.sh when the wrapper is active.
# Running this script directly from a shell will not have the wrapper context.
if [[ "${GIT_AUTHOR_NAME:-}" != "Claude Code Bot" ]]; then
  echo -e "${RED}ERROR: This test must be run from inside a claude-wrapper session.${NC}"
  echo ""
  echo "Usage: Ask Claude Code (via wrapper):"
  echo "  Run ~/Developer/claude-wrapper/tests/test-gh-token-permissions.sh"
  echo ""
  echo "GIT_AUTHOR_NAME is not 'Claude Code Bot' — wrapper environment is not active."
  exit 1
fi

# =============================================================================
# SECTION 1: Environment Checks
# =============================================================================
section "1. Wrapper Environment"

# 1.1 Git identity
echo -e "${BOLD}Git identity:${NC}"
if [[ "${GIT_AUTHOR_NAME:-}" == "Claude Code Bot" ]]; then
  pass "GIT_AUTHOR_NAME = Claude Code Bot"
else
  fail "GIT_AUTHOR_NAME = '${GIT_AUTHOR_NAME:-<unset>}' (expected 'Claude Code Bot')"
fi

if [[ "${GIT_AUTHOR_EMAIL:-}" == *"@"* ]]; then
  pass "GIT_AUTHOR_EMAIL = ${GIT_AUTHOR_EMAIL}"
else
  fail "GIT_AUTHOR_EMAIL not set or missing @"
fi

if [[ "${GIT_COMMITTER_NAME:-}" == "Claude Code Bot" ]]; then
  pass "GIT_COMMITTER_NAME = Claude Code Bot"
else
  fail "GIT_COMMITTER_NAME = '${GIT_COMMITTER_NAME:-<unset>}'"
fi

# 1.2 GH_TOKEN
echo ""
echo -e "${BOLD}GitHub token:${NC}"
if [[ -n "${GH_TOKEN:-}" ]]; then
  pass "GH_TOKEN is set (${#GH_TOKEN} chars)"
  if [[ "${GH_TOKEN}" == github_pat_* ]]; then
    pass "GH_TOKEN is a fine-grained PAT (github_pat_ prefix)"
  elif [[ "${GH_TOKEN}" == ghp_* ]]; then
    pass "GH_TOKEN is a classic PAT (ghp_ prefix)"
  else
    fail "GH_TOKEN prefix not recognized (prefix: ${GH_TOKEN:0:10}...)"
  fi
else
  fail "GH_TOKEN is not set — check that ~/.config/bash/1password.sh is sourced at shell startup"
  echo -e "  ${RED}Cannot continue without GH_TOKEN. Aborting.${NC}"
  exit 1
fi

# 1.3 SSH key
echo ""
echo -e "${BOLD}SSH identity:${NC}"
if [[ "${GIT_SSH_COMMAND:-}" == *"id_ed25519_claude_code"* ]]; then
  pass "GIT_SSH_COMMAND uses dedicated Claude SSH key"
else
  skip "GIT_SSH_COMMAND not set to Claude key (may be using default SSH)"
fi

# 1.4 Token authentication
echo ""
echo -e "${BOLD}Token authentication:${NC}"
token_user="$(gh api user --jq '.login' 2>/dev/null)" || token_user=""
if [[ "${token_user}" == "smartwatermelon" ]]; then
  pass "Token authenticates as: ${token_user}"
else
  fail "Token authentication failed (got: '${token_user}')"
fi

# =============================================================================
# SECTION 2: Allowed Operations (should succeed)
# =============================================================================
section "2. Allowed Operations"

# 2.1 List repos
echo -e "${BOLD}Read repository metadata:${NC}"
if gh api "repos/${TEST_REPO}" --jq '.full_name' &>/dev/null; then
  pass "Can read repo metadata"
else
  fail "Cannot read repo metadata"
fi

# 2.2 List PRs
echo ""
echo -e "${BOLD}Read pull requests:${NC}"
if gh pr list --repo "${TEST_REPO}" --limit 1 &>/dev/null; then
  pass "Can list pull requests"
else
  fail "Cannot list pull requests"
fi

# 2.3 List actions/CI runs
echo ""
echo -e "${BOLD}Read CI/Actions:${NC}"
if gh api "repos/${TEST_REPO}/actions/runs" --jq '.total_count' &>/dev/null; then
  pass "Can read Actions workflow runs"
else
  fail "Cannot read Actions workflow runs"
fi

# 2.4 Read check suites
if gh api "repos/${TEST_REPO}/commits/main/check-suites" --jq '.total_count' &>/dev/null; then
  pass "Can read check suites"
else
  fail "Cannot read check suites"
fi

# 2.5 Create branch + PR (the core workflow)
echo ""
echo -e "${BOLD}Create branch and PR:${NC}"
WORK_DIR="$(mktemp -d)"
if git clone --depth 1 "git@github.com:${TEST_REPO}.git" "${WORK_DIR}/repo" 2>/dev/null; then
  pass "Can clone repo via SSH"
else
  fail "Cannot clone repo via SSH"
  # Try HTTPS fallback
  if git clone --depth 1 "https://github.com/${TEST_REPO}.git" "${WORK_DIR}/repo" 2>/dev/null; then
    pass "Can clone repo via HTTPS (fallback)"
  else
    fail "Cannot clone repo at all — skipping branch/PR tests"
    WORK_DIR=""
  fi
fi

if [[ -n "${WORK_DIR:-}" ]] && [[ -d "${WORK_DIR}/repo" ]]; then
  # Run git operations in a subshell to isolate cd and prevent set -e from
  # killing the whole script if pre-commit hooks or push fails.
  # Uses --no-verify because this is a throwaway test commit, not production code.
  push_ok=false
  if (
    cd "${WORK_DIR}/repo"
    git checkout -b "${TEST_BRANCH}" 2>/dev/null
    # shellcheck disable=SC2312  # date failure here is non-fatal; return value not needed
    echo "# Token permission test — $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>README.md
    git add README.md
    git commit --no-verify -m "test: token permission verification (will be deleted)" 2>/dev/null
    git push origin "${TEST_BRANCH}" 2>/dev/null
  ); then
    push_ok=true
    pass "Can push branch to remote"
  else
    fail "Cannot push branch to remote (clone/commit/push failed)"
  fi

  # Create PR (only if push succeeded)
  if [[ "${push_ok}" == "true" ]]; then
    pr_url="$(gh pr create \
      --repo "${TEST_REPO}" \
      --base main \
      --head "${TEST_BRANCH}" \
      --title "test: token permission check (auto-delete)" \
      --body "Automated test — verifying claude-wrapper PAT permissions. This PR will be closed and deleted automatically." \
      2>/dev/null)" || pr_url=""

    if [[ -n "${pr_url}" ]]; then
      TEST_PR_NUMBER="$(echo "${pr_url}" | grep -oE '[0-9]+$')"
      pass "Can create PR (#${TEST_PR_NUMBER})"
    else
      fail "Cannot create PR"
    fi
  fi
fi

# =============================================================================
# SECTION 3: Denied Operations
# =============================================================================
# A classic PAT's `repo` scope is coarse: it grants read AND write on repo
# settings, branch protection, collaborators, deploy keys, and webhooks —
# GitHub does not gate any of these behind a separate admin-only scope for
# classic PATs. Live-verified against the sandbox repo (2026-08-06): all of
# branch protection write, repo settings PATCH, collaborator invite, deploy
# key add, and webhook creation SUCCEED with this token. The only operation
# GitHub actually gates behind a scope this token lacks is repository
# deletion (`delete_repo`), so that's the only real boundary left to assert
# here.
#
# The five checks above are documented SKIPs, not live requests — they no
# longer run anything. Only the repo-delete check below fires a real (safe,
# scope-guaranteed) request. If you're re-adding a live check for any of the
# skipped operations, remember: TEST_REPO MUST stay a disposable sandbox
# (see the TEST_REPO comment above), and several of those operations are not
# reliably revertible (e.g. a webhook or deploy key ID must be captured and
# explicitly deleted after creation) — a bad revert can leave real repo
# state altered, which is exactly what happened during this fix's
# investigation before TEST_REPO was repointed.
section "3. Denied Operations"

echo -e "${BOLD}Repo-scope write operations (expected to SUCCEED — not deniable for a classic PAT):${NC}"
skip "Branch protection write: 'repo' scope permits this for classic PATs (verified live against sandbox)"
skip "Repo settings PATCH: 'repo' scope permits this for classic PATs (verified live against sandbox)"
skip "Add collaborator: 'repo' scope permits this for classic PATs (verified live against sandbox)"
skip "Add deploy key: 'repo' scope permits this for classic PATs (verified live against sandbox)"
skip "Create webhook: 'repo' scope permits this for classic PATs (verified live against sandbox)"

# Delete repo — the one operation GitHub actually gates behind a scope this
# token doesn't have (`delete_repo`, separate from `repo`). Safe to assert
# live: a 403 here is guaranteed by the scope model, not just observed
# behavior, so there's no risk of this one silently succeeding.
echo ""
echo -e "${BOLD}Destructive operations (should be 403):${NC}"
http_status="$(gh api "repos/${TEST_REPO}" -X DELETE 2>&1)" || true
if echo "${http_status}" | grep -qi "403\|not accessible\|Must have admin\|delete_repo"; then
  pass "BLOCKED: Cannot delete repo (missing delete_repo scope)"
else
  fail "UNEXPECTED: Delete repo did not return 403 (got: ${http_status:0:100})"
fi

# =============================================================================
# SECTION 4: Merge Protection
# =============================================================================
section "4. Merge Protection (branch protection enforcement)"

if [[ -n "${TEST_PR_NUMBER}" ]]; then
  echo -e "${BOLD}Attempting to merge PR #${TEST_PR_NUMBER} without review:${NC}"

  # Bypass the local gh merge-lock/pre-merge-review wrapper — this check is
  # verifying GitHub's own branch protection API behavior, not this
  # machine's local merge tooling. The wrapper exists both as a shell
  # function AND as a same-named binary earlier in PATH
  # (~/.local/bin/gh -> ~/.config/bash/gh-wrapper.sh, see its own header
  # comment), so `command gh` alone isn't enough to reach the real GitHub
  # CLI — it only defeats the function, not the PATH-shadowing binary.
  # Resolve the real Homebrew gh explicitly instead. Using the wrapped `gh`
  # here tests the wrong layer and masks the real signal (confirmed during
  # sandbox verification: the local wrapper rejected the call with its own
  # --squash/--delete-branch policy error before it ever reached GitHub).
  real_gh="$(type -a gh 2>/dev/null | grep -oE '/[^ ]+/gh$' | grep -v '/\.local/bin/gh$' | head -1)"

  if [[ -z "${real_gh}" ]]; then
    # No non-wrapper gh binary found — falling back to bare `gh` would
    # silently re-invoke the wrapper and produce its policy-rejection
    # message instead of GitHub's, which looks identical to a passing test
    # but verifies nothing. Fail loudly instead so this doesn't mask a
    # broken branch-protection check.
    fail "Cannot find a real (non-wrapper) gh binary in PATH — install Homebrew gh or check 'type -a gh'"
  else
    merge_result="$("${real_gh}" pr merge "${TEST_PR_NUMBER}" --repo "${TEST_REPO}" --merge 2>&1)" || true

    if echo "${merge_result}" | grep -qi "review\|approved\|not allowed\|required.*review\|CODEOWNERS\|merging.*blocked\|not mergeable\|policy prohibits"; then
      pass "BLOCKED: Merge rejected — review required (branch protection working)"
      echo -e "       ${CYAN}Server response: ${merge_result:0:120}${NC}"
    elif echo "${merge_result}" | grep -qi "403\|not accessible"; then
      pass "BLOCKED: Merge rejected by token permissions"
    elif echo "${merge_result}" | grep -qi "merged\|Merged"; then
      fail "CRITICAL: PR was merged without review! Branch protection is NOT working!"
    else
      fail "Unexpected merge response: ${merge_result:0:200}"
    fi
  fi
else
  skip "No test PR was created — cannot test merge protection"
fi

# =============================================================================
# SECTION 5: Token Scope Verification
# =============================================================================
section "5. Token Scope Summary"

echo -e "${BOLD}Fine-grained PAT capabilities:${NC}"

# Check what the token reports
rate_info="$(gh api rate_limit --jq '.resources.core.limit' 2>/dev/null)" || rate_info="unknown"
echo -e "  API rate limit: ${rate_info} requests/hour"

# Check token expiration (via the auth status)
auth_info="$(gh auth status 2>&1)" || true
if echo "${auth_info}" | grep -q "Token expires"; then
  expiry="$(echo "${auth_info}" | grep "Token expires" | sed 's/.*Token expires/Expires/')"
  echo -e "  ${expiry}"
fi

# =============================================================================
# Results
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
echo -e "${BOLD}Results${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
echo ""
echo -e "  ${GREEN}PASS: ${PASS}${NC}"
echo -e "  ${RED}FAIL: ${FAIL}${NC}"
echo -e "  ${YELLOW}SKIP: ${SKIP}${NC}"
echo ""

if [[ ${FAIL} -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}All permission boundaries verified!${NC}"
  echo ""
  echo "The wrapper PAT can:"
  echo "  - Read repos, PRs, CI status"
  echo "  - Push branches, create PRs"
  echo "  - Write branch protection, repo settings, collaborators, deploy"
  echo "    keys, and webhooks (classic PAT 'repo' scope grants all of this —"
  echo "    not deniable at the scope level; see section 3 above)"
  echo ""
  echo "The wrapper PAT cannot:"
  echo "  - Delete repos (missing delete_repo scope)"
  echo "  - Merge PRs without an approving review (branch protection, when"
  echo "    enforce_admins is enabled — see section 4 above)"
  exit 0
else
  echo -e "${RED}${BOLD}${FAIL} test(s) failed — review output above.${NC}"
  exit 1
fi
