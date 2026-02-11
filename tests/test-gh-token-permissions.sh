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
#   3. DENIED operations: admin, settings, delete (should get 403)
#   4. MERGE PROTECTION: branch protection blocks self-merge (should fail)
#
# Cleanup: Creates a temporary branch + PR, then deletes both on exit.
# =============================================================================

# --- Config ---
TEST_REPO="smartwatermelon/claude-config" # Public repo with branch protection
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
  else
    fail "GH_TOKEN does not look like a fine-grained PAT (prefix: ${GH_TOKEN:0:10}...)"
  fi
else
  fail "GH_TOKEN is not set — wrapper did not inject token"
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
# SECTION 3: Denied Operations (should get 403)
# =============================================================================
section "3. Denied Operations"

# 3.1 Branch protection (requires administration permission)
echo -e "${BOLD}Admin endpoints (should be 403):${NC}"
http_status="$(gh api "repos/${TEST_REPO}/branches/main/protection" 2>&1)" || true
if echo "${http_status}" | grep -q "Resource not accessible by personal access token"; then
  pass "BLOCKED: Cannot read branch protection (no admin permission)"
else
  fail "UNEXPECTED: Can read branch protection — token has too many permissions"
fi

# 3.2 Modify repo settings
http_status="$(gh api "repos/${TEST_REPO}" -X PATCH -f description="hacked" 2>&1)" || true
if echo "${http_status}" | grep -q "Resource not accessible by personal access token"; then
  pass "BLOCKED: Cannot modify repo settings"
elif echo "${http_status}" | grep -q "403"; then
  pass "BLOCKED: Cannot modify repo settings (403)"
else
  fail "UNEXPECTED: Could modify repo settings — token has too many permissions"
  # Revert if it actually worked
  gh api "repos/${TEST_REPO}" -X PATCH -f description="" 2>/dev/null || true
fi

# 3.3 Delete repo
echo ""
echo -e "${BOLD}Destructive operations (should be 403):${NC}"
http_status="$(gh api "repos/${TEST_REPO}" -X DELETE 2>&1)" || true
if echo "${http_status}" | grep -qi "403\|not accessible\|Must have admin"; then
  pass "BLOCKED: Cannot delete repo"
else
  fail "UNEXPECTED: Delete repo did not return 403 (got: ${http_status:0:100})"
fi

# 3.4 Manage collaborators
http_status="$(gh api "repos/${TEST_REPO}/collaborators/octocat" -X PUT 2>&1)" || true
if echo "${http_status}" | grep -qi "403\|not accessible\|Must have admin"; then
  pass "BLOCKED: Cannot manage collaborators"
else
  fail "UNEXPECTED: Manage collaborators did not return 403"
fi

# 3.5 Manage deploy keys
http_status="$(gh api "repos/${TEST_REPO}/keys" -X POST -f title="evil" -f key="ssh-ed25519 AAAA test" 2>&1)" || true
if echo "${http_status}" | grep -qi "403\|not accessible\|Must have admin"; then
  pass "BLOCKED: Cannot add deploy keys"
else
  fail "UNEXPECTED: Add deploy keys did not return 403"
fi

# 3.6 Manage webhooks
http_status="$(
  gh api "repos/${TEST_REPO}/hooks" -X POST --input - 2>&1 <<'HOOK'
{"config":{"url":"https://evil.example.com"},"events":["push"]}
HOOK
)" || true
if echo "${http_status}" | grep -qi "403\|not accessible\|Not Found"; then
  pass "BLOCKED: Cannot create webhooks"
else
  fail "UNEXPECTED: Create webhook did not return 403"
fi

# =============================================================================
# SECTION 4: Merge Protection
# =============================================================================
section "4. Merge Protection (branch protection enforcement)"

if [[ -n "${TEST_PR_NUMBER}" ]]; then
  echo -e "${BOLD}Attempting to merge PR #${TEST_PR_NUMBER} without review:${NC}"

  merge_result="$(gh pr merge "${TEST_PR_NUMBER}" --repo "${TEST_REPO}" --merge 2>&1)" || true

  if echo "${merge_result}" | grep -qi "review\|approved\|not allowed\|required.*review\|CODEOWNERS\|merging.*blocked"; then
    pass "BLOCKED: Merge rejected — review required (branch protection working)"
    echo -e "       ${CYAN}Server response: ${merge_result:0:120}${NC}"
  elif echo "${merge_result}" | grep -qi "403\|not accessible"; then
    pass "BLOCKED: Merge rejected by token permissions"
  elif echo "${merge_result}" | grep -qi "merged\|Merged"; then
    fail "CRITICAL: PR was merged without review! Branch protection is NOT working!"
  else
    fail "Unexpected merge response: ${merge_result:0:200}"
  fi
else
  skip "No test PR was created — cannot test merge protection"
fi

# =============================================================================
# SECTION 5: Cross-Org Token Routing
# =============================================================================
section "5. Cross-Org Token Routing"

echo -e "${BOLD}Multi-org token routing:${NC}"

# 5.1 Check if router env vars are set
if [[ -n "${CLAUDE_GH_TOKEN_DIR:-}" ]]; then
  pass "CLAUDE_GH_TOKEN_DIR is set: ${CLAUDE_GH_TOKEN_DIR}"
else
  skip "CLAUDE_GH_TOKEN_DIR not set (multi-org routing not active)"
fi

if [[ -n "${CLAUDE_GH_TOKEN_ROUTER:-}" ]]; then
  pass "CLAUDE_GH_TOKEN_ROUTER is set: ${CLAUDE_GH_TOKEN_ROUTER}"
else
  skip "CLAUDE_GH_TOKEN_ROUTER not set (multi-org routing not active)"
fi

# 5.2 Test personal repo access
echo ""
echo -e "${BOLD}Personal repo access:${NC}"
if gh api repos/smartwatermelon/claude-wrapper --jq '.full_name' &>/dev/null; then
  pass "Can access personal repo (smartwatermelon/claude-wrapper)"
else
  fail "Cannot access personal repo (smartwatermelon/claude-wrapper)"
fi

# 5.3 Test org repo access (requires gh-token.nightowlstudiollc to exist)
echo ""
echo -e "${BOLD}Organization repo access:${NC}"
ORG_TOKEN_FILE="${CLAUDE_GH_TOKEN_DIR:-${HOME}/.config/claude-code}/gh-token.nightowlstudiollc"
if [[ -f "${ORG_TOKEN_FILE}" ]]; then
  org_result="$(gh api repos/nightowlstudiollc/kebab-tax --jq '.full_name' 2>&1)" || org_result=""
  if [[ "${org_result}" == "nightowlstudiollc/kebab-tax" ]]; then
    pass "Can access org repo (nightowlstudiollc/kebab-tax)"
  else
    fail "Cannot access org repo (nightowlstudiollc/kebab-tax)" "Got: ${org_result:0:100}"
  fi
else
  skip "Org token file not found: ${ORG_TOKEN_FILE} (create PAT for nightowlstudiollc first)"
fi

# 5.4 Test that both work in the same flow
echo ""
echo -e "${BOLD}Same-session multi-org:${NC}"
if [[ -f "${ORG_TOKEN_FILE}" ]]; then
  personal_ok=false
  org_ok=false

  if gh api repos/smartwatermelon/claude-wrapper --jq '.full_name' &>/dev/null; then
    personal_ok=true
  fi
  if gh api repos/nightowlstudiollc/kebab-tax --jq '.full_name' &>/dev/null; then
    org_ok=true
  fi

  if [[ "${personal_ok}" == "true" && "${org_ok}" == "true" ]]; then
    pass "Both personal and org repos accessible in same session"
  elif [[ "${personal_ok}" == "true" ]]; then
    fail "Personal works but org fails in same session"
  elif [[ "${org_ok}" == "true" ]]; then
    fail "Org works but personal fails in same session"
  else
    fail "Neither personal nor org repos accessible"
  fi
else
  skip "Cannot test multi-org flow without org token file"
fi

# =============================================================================
# SECTION 6: Token Scope Verification
# =============================================================================
section "6. Token Scope Summary"

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
  echo ""
  echo "The wrapper PAT cannot:"
  echo "  - Access admin/settings endpoints"
  echo "  - Delete repos or manage collaborators"
  echo "  - Merge PRs without an approving review"
  exit 0
else
  echo -e "${RED}${BOLD}${FAIL} test(s) failed — review output above.${NC}"
  exit 1
fi
