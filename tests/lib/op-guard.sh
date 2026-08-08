#!/usr/bin/env bash
# Guards against the failure mode in issue #79: a test that builds a stub
# `op` binary somehow escapes its isolated PATH sandbox and overwrites the
# real system `op` (1Password CLI) at its real location.
#
# Committed test logic already writes stubs only under mktemp'd stub dirs
# and never resolves a write target via `command -v`, so this isn't closing
# a known hole in current code — it's a tripwire for future regressions
# (e.g. manual iteration on stub-writing code that slips a `PATH=` prefix or
# swaps a read for a write). Source this file, then call
# `op_guard_snapshot` once before any stub PATH tests run and
# `op_guard_verify` once after — normally via an EXIT trap so it still runs
# on early test failure.
#
# Usage:
#   # shellcheck source=lib/op-guard.sh
#   source "${TEST_DIR}/lib/op-guard.sh"
#   op_guard_snapshot
#   trap 'op_guard_verify; <other-cleanup>' EXIT
#   ... tests ...

_OP_GUARD_REAL_PATH=""
_OP_GUARD_REAL_SIZE=""

# Records the real `op` binary's resolved path and size before any stub-PATH
# tests run. No-ops (with a stderr note) if `op` isn't installed at all —
# e.g. on CI runners — since there's nothing to protect in that case.
op_guard_snapshot() {
  _OP_GUARD_REAL_PATH="$(command -v op 2>/dev/null || true)"
  if [[ -z "${_OP_GUARD_REAL_PATH}" ]]; then
    echo "op-guard: no system 'op' binary on PATH, skipping integrity check" >&2
    return 0
  fi
  _OP_GUARD_REAL_SIZE="$(wc -c <"${_OP_GUARD_REAL_PATH}" 2>/dev/null | tr -d ' ')"
}

# Re-resolves `op` after the suite runs and fails loudly if the path that
# was real before is now missing, resolves somewhere else, or shrank to
# something stub-shaped (a hand-written shell stub is well under 1KB; the
# real 1Password CLI binary is tens of MB).
op_guard_verify() {
  [[ -z "${_OP_GUARD_REAL_PATH}" ]] && return 0

  if [[ ! -e "${_OP_GUARD_REAL_PATH}" ]]; then
    echo "op-guard: FATAL - real op binary at ${_OP_GUARD_REAL_PATH} is gone after test run" >&2
    exit 1
  fi

  local post_size
  post_size="$(wc -c <"${_OP_GUARD_REAL_PATH}" 2>/dev/null | tr -d ' ')"

  if [[ "${post_size}" != "${_OP_GUARD_REAL_SIZE}" ]]; then
    echo "op-guard: FATAL - ${_OP_GUARD_REAL_PATH} changed size during test run (${_OP_GUARD_REAL_SIZE} -> ${post_size} bytes) - it may have been overwritten by a test stub (see issue #79)" >&2
    exit 1
  fi

  # Belt-and-suspenders floor: even if size happened to match, a binary
  # this small can't be a real 1Password CLI build.
  if [[ "${post_size}" -lt 1000000 ]]; then
    echo "op-guard: FATAL - ${_OP_GUARD_REAL_PATH} is only ${post_size} bytes, too small to be the real 1Password CLI (see issue #79)" >&2
    exit 1
  fi
}
