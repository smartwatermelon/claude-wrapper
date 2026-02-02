# Security Hardening Documentation

## Overview

This document describes the security hardening measures implemented in the `claude-wrapper` wrapper to protect credentials and prevent common attack vectors.

## Security Principles

The wrapper follows defense-in-depth principles:

1. **Secure defaults**: Auto-fix insecure permissions rather than risk exposure or block operation
2. **Least privilege**: Enforce strict permission requirements (auto-fixed if needed)
3. **Path validation**: Prevent traversal and symlink attacks
4. **Binary integrity**: Validate the Claude binary before execution
5. **Audit trail**: Debug logging for security-relevant events

## Threat Model

### Threats Addressed

1. **Local privilege escalation**: Attacker with local access attempting to read credentials
2. **Path traversal**: Malicious repository attempting to load attacker-controlled secrets
3. **Binary substitution**: Attacker replacing the claude binary with malicious code
4. **Symlink attacks**: Using symlinks to bypass permission checks
5. **Race conditions**: TOCTOU attacks on file operations
6. **Information disclosure**: Secrets leaked through logs or error messages

### Out of Scope

- **Physical access**: Assumes attacker cannot physically access the machine
- **Kernel exploits**: Relies on OS-level security boundaries
- **Side-channel attacks**: Does not protect against timing/cache attacks
- **Compromised 1Password**: Assumes 1Password vault is secure

## Security Features

### 1. Permission Checks with Auto-Fix

**Implementation**: `check_file_permissions()` and `ensure_secure_permissions()` (lines 53-141)

**Behavior**:

- **Refuse** to load files not owned by the current user (cannot auto-fix ownership)
- **Warn and auto-fix** files that are group-readable or world-readable
- For secrets files (`.op`): auto-fix to `400` (read-only for owner)
- For pre-launch hooks: auto-fix to `700` (executable for owner only)

**Rationale**: Insecure permissions must be corrected before loading credentials. Auto-fixing ensures secure permissions are enforced without requiring manual intervention, while still warning the user about the issue.

**Example**:

```bash
# AUTO-FIXED: World-readable secrets file
$ ls -la .claude/secrets.op
-rw-r--r-- 1 user user 40 Jan 14 15:00 secrets.op

$ claude
WARNING: .claude/secrets.op has group permissions (644)
WARNING: .claude/secrets.op has world permissions (644)
WARNING: Auto-fixing permissions: chmod 400 .claude/secrets.op
# Continues loading with secure permissions
```

### 2. Path Canonicalization

**Implementation**: `canonicalize_path()` (lines 94-119)

**Behavior**:

- Resolves all symlinks to canonical absolute paths
- Removes `..` and `.` components
- **Refuses** to load from symlinks directly
- Returns error if path cannot be canonicalized

**Rationale**: Prevents path traversal attacks where a malicious repository might reference `../../../../etc/passwd` or similar.

**Example**:

```bash
# BLOCKED: Symlink to secrets outside git repo
$ ln -s ~/.ssh/id_rsa .claude/secrets.op

$ claude
WARNING: Refusing to load from symlink: .claude/secrets.op
```

### 3. Git Repository Boundary Enforcement

**Implementation**: Project secrets loading (lines 207-237)

**Behavior**:

- Project secrets **only loaded** if inside a git repository
- Uses `git rev-parse --show-toplevel` to find repo root
- Constructs secret path as `${GIT_ROOT}/.claude/secrets.op`
- **Double-checks** canonical path starts with `${GIT_ROOT}`
- **Refuses** to load if canonical path escapes repository

**Rationale**: Prevents malicious repositories from loading arbitrary secrets by controlling the current working directory.

**Example**:

```bash
# BLOCKED: User in /tmp/malicious-dir (not a git repo)
$ cd /tmp/malicious-dir
$ echo 'EVIL=op://vault/item' > .claude/secrets.op
$ claude

# Debug output shows:
DEBUG: Not in a git repository, skipping project/local secrets
```

### 4. Claude Binary Validation

**Implementation**: `validate_claude_binary()` (lines 288-319)

**Behavior**:

- Canonicalizes binary path (resolves symlinks)
- Verifies binary is executable
- **Checks owner** (must be current user or root)
- **Checks permissions** (must not be world-writable)
- **Refuses execution** if validation fails

**Rationale**: Prevents execution of attacker-placed binaries, even if they appear in PATH before the real claude.

**Example**:

```bash
# BLOCKED: World-writable claude binary
$ chmod 777 ~/.local/bin/claude

$ claude-wrapper
ERROR: Claude binary is world-writable (777): /Users/user/.local/bin/claude
ERROR: Claude binary failed security validation, refusing to execute
```

### 5. Symlink Protection

**Multiple layers**:

1. `canonicalize_path()` refuses direct symlinks (line 111-114)
2. Binary validation uses `realpath` (line 294)
3. Permission checks operate on canonical paths

**Rationale**: Symlink attacks are a classic TOCTOU vector. All operations must work on canonical paths.

### 6. Ownership Validation

**Files checked**:

- GitHub token file (via `check_file_permissions`)
- Global secrets file (via `validate_secrets_file`)
- Project secrets files (via `validate_secrets_file`)
- Claude binary (via `validate_claude_binary`)

**Requirement**: Must be owned by current user (credentials) or root (system binaries)

**Rationale**: Prevents loading credentials from files an attacker could modify.

## Security Trade-offs

### Usability vs Security

**Permission enforcement with auto-fix**:

- **Pro**: Prevents credential exposure while ensuring usability
- **Pro**: Automatically corrects insecure permissions (no manual intervention needed)
- **Con**: Modifies file permissions without explicit user action (mitigated by warning messages)

**Git repository requirement for project secrets**:

- **Pro**: Prevents loading secrets from arbitrary directories
- **Con**: Cannot use wrapper outside git repos with project secrets

**Binary ownership checks**:

- **Pro**: Prevents execution of attacker-placed binaries
- **Con**: May block legitimate multi-user installations (mitigated by allowing root-owned binaries)

### Performance

**Canonicalization overhead**:

- Every secrets file is canonicalized via `realpath` (typically <1ms)
- Binary is canonicalized once per invocation
- Total overhead: <10ms, negligible for interactive use

**Multiple `git` calls**:

- `git rev-parse --git-dir`: Check if in repo
- `git rev-parse --show-toplevel`: Get repo root
- Combined overhead: ~5-15ms
- Only runs if loading project secrets

## Bypasses and Limitations

### Known Limitations

1. **TOCTOU window still exists**: Between validation and actual read by `op run`, files could theoretically be modified. This is a fundamental limitation of the shell environment - we cannot pass file descriptors directly to `op run`. Mitigation: `set -e` catches read errors, and file system operations are typically atomic at the inode level.

2. **Symlink checking limited to leaf path**: The `canonicalize_path` function checks if the final path argument is a symlink, but does not walk up and check every path component. An attacker with write access to parent directories could create symlinked directories. Mitigation: The `realpath` call resolves all symlinks in the final canonical path, and the ownership check prevents loading files from attacker-controlled locations.

3. **No checksum validation**: Claude binary is validated for ownership/permissions but not cryptographic integrity. Mitigation: Relies on OS package managers for integrity. Future enhancement: Add optional checksum verification against known good values.

4. **Process environment inheritance**: All subprocesses (hooks, agents, spawned commands) inherit secrets. This is by design to enable git hooks and agents to function, but means any code execution within the Claude session has access to secrets. Mitigation: Use least-privilege 1Password vaults and limit secret exposure to only what Claude needs.

5. **1Password session hijacking**: If an attacker can access the 1Password session (via `OP_SESSION_*` environment variables or biometric unlock), they can access secrets. Mitigation: Relies on 1Password's session security and OS-level protections.

6. **Debug mode information disclosure**: Debug logging reveals file paths (but not secret values). Mitigation: Debug mode should only be used in trusted environments. Do not enable in shared/multi-user systems.

7. **Binary discovery via PATH**: The wrapper searches PATH for the claude binary, trusting the first match that passes validation. An attacker with write access to early PATH entries could potentially place a malicious binary. Mitigation: Binary validation checks ownership and permissions, and fallback paths are searched only if PATH search fails.

### Potential Future Improvements

1. **Cryptographic binary validation**: Verify claude binary signature/checksum
2. **Secrets file format validation**: Verify 1Password reference syntax before passing to `op run`
3. **Audit logging**: Log all credential loads to a tamper-evident audit log
4. **MAC address/time-based session limits**: Additional constraints on when secrets can be loaded
5. **Hardware token integration**: Support for YubiKey or similar for additional authentication

## Compliance Considerations

### SOC 2 / ISO 27001

Relevant controls:

- **A.9.4.1**: Information access restriction (permission checks)
- **A.9.4.4**: Use of privileged utility programs (binary validation)
- **A.12.4.1**: Event logging (debug logging for security events)

### PCI-DSS

If handling payment card data:

- **Req 3.4**: Render PAN unreadable (1Password vault encryption)
- **Req 8.3**: Secure authentication (ownership and permission validation)

### GDPR

- **Article 32**: Security of processing (technical measures implemented)
- **Recital 83**: Data breach prevention (permission checks prevent unauthorized access)

## Security Contact

**Report security issues**: DO NOT open public GitHub issues for security vulnerabilities.

**Contact**: [Specify your security contact method]

**PGP Key**: [Optional: Include PGP key fingerprint]

**Expected response time**: Within 48 hours for critical issues

## Changelog

### v2.0.0 (2026-01-14) - Security Hardening Release

**Critical fixes**:

- ✅ Permission checks now blocking (not advisory)
- ✅ Simplified permission logic: reject ANY group or world permissions
- ✅ Path canonicalization prevents traversal attacks
- ✅ Git repository boundary enforcement with proper path containment check
- ✅ Canonicalized git root to handle symlinked repositories
- ✅ Claude binary integrity validation
- ✅ Symlink attack protection
- ✅ Ownership validation for all credential files
- ✅ Removed stderr capture in validation functions

**Removed insecure patterns**:

- ❌ `eval` of external command output (1Password v1 pattern)
- ❌ Advisory-only permission warnings (replaced with warn-and-fix that enforces secure permissions)
- ❌ CWD-relative secret paths without validation
- ❌ Broken permission check logic (original v2.0.0 had logic error)
- ❌ Bypassable boundary checks (fixed string prefix match vulnerability)

**Security reviews**:

- Code reviewer: Clean (2 iterations)
- Adversarial reviewer (iteration 1): Critical issues identified
- Adversarial reviewer (iteration 2): Logic errors fixed, known limitations documented
- ShellCheck: No warnings or errors

**Known limitations acknowledged**:

- TOCTOU conditions inherent to shell environment
- Symlink checking limited to leaf paths (mitigated by realpath + ownership checks)
- No cryptographic binary validation (relies on OS package managers)

### v1.0.0 (Initial) - Basic Implementation

- Git identity management
- SSH key isolation
- GitHub token loading
- 1Password integration (v1 pattern)
- Multi-level secrets support

## References

- [OWASP Secure Coding Practices](https://owasp.org/www-project-secure-coding-practices-quick-reference-guide/)
- [CWE-22: Path Traversal](https://cwe.mitre.org/data/definitions/22.html)
- [CWE-59: Improper Link Resolution Before File Access](https://cwe.mitre.org/data/definitions/59.html)
- [1Password CLI Security](https://developer.1password.com/docs/cli/about-biometric-unlock/)
- [Bash Security Best Practices](https://www.shellcheck.net/)
