# Test Suite

## Overview

Comprehensive test suite for the `claude-with-identity` wrapper script. Tests cover functionality, error handling, security, and integration.

## Quick Start

```bash
# Run all tests
./tests/test-wrapper.sh

# With verbose output
VERBOSE=true ./tests/test-wrapper.sh
```

## Test Categories

### 1. Structural Tests

- Wrapper script exists and is executable
- Correct shebang and strict mode (`set -euo pipefail`)
- ShellCheck compliance (no warnings or errors)

### 2. Configuration Tests

- Git identity environment variables
- SSH key configuration
- GitHub token loading
- 1Password paths configuration

### 3. Functionality Tests

- Claude binary search logic
- Multi-level secrets loading (global, project, local)
- Debug mode detection and logging
- 1Password CLI detection

### 4. Error Handling Tests

- Failed 1Password signin
- Missing secrets files
- Unreadable secrets files
- Missing claude binary

### 5. Security Tests

- No hardcoded credentials
- Proper file permission checks
- Graceful degradation without secrets
- Secret masking behavior

### 6. Integration Tests

- Mock claude execution
- Environment variable passing
- Subprocess inheritance

## Test Output

### Success

```
======================================
Claude Wrapper Test Suite
======================================

Test 1: Wrapper script validation
✓ Wrapper script exists
✓ Wrapper script is executable

Test 2: Git identity environment setup
✓ GIT_AUTHOR_NAME set correctly
✓ GIT_AUTHOR_EMAIL contains @ symbol

...

======================================
Test Results
======================================
Tests run:    42
Tests passed: 42
Tests failed: 0

All tests passed!
```

### Failure

```
Test 5: Multi-level secrets file configuration
✓ Global secrets path defined
✗ Project secrets path defined
  Expected: CLAUDE_OP_PROJECT_SECRETS
  Actual:   (not found)

======================================
Test Results
======================================
Tests run:    42
Tests passed: 40
Tests failed: 2
```

## Prerequisites

### Required

- Bash 5.0+
- GNU coreutils (grep, sed, cat, etc.)

### Optional (enhances tests)

- ShellCheck: For static analysis tests
- 1Password CLI (`op`): For integration tests with real 1Password

## Manual Testing Scenarios

After automated tests pass, manually verify:

### 1. First Run with 1Password

```bash
# Clear any existing session
op signout --all

# Run wrapper (should prompt for TouchID)
CLAUDE_DEBUG=true ./bin/claude-with-identity --version

# Expected:
# - TouchID prompt appears
# - "Authenticating with 1Password (once per session)..." message
# - DEBUG output shows secrets files loaded
```

### 2. Subsequent Runs (Session Persistence)

```bash
# Run again immediately
CLAUDE_DEBUG=true ./bin/claude-with-identity --version

# Expected:
# - NO TouchID prompt
# - DEBUG shows "Active 1Password session detected"
# - Completes faster than first run
```

### 3. Secrets Injection

```bash
# Create test secret
mkdir -p ~/.config/claude-code
echo 'TEST_SECRET=op://Personal/test/field' > ~/.config/claude-code/secrets.op

# Run with secret verification
./bin/claude-with-identity -c "printenv | grep TEST_SECRET"

# Expected:
# - Variable exists in environment
# - Value is masked in output (1Password behavior)
```

### 4. Multi-Level Secrets Precedence

```bash
# Setup test secrets at all levels
echo 'LEVEL=global' > ~/.config/claude-code/secrets.op
mkdir -p .claude
echo 'LEVEL=project' > .claude/secrets.op
echo 'LEVEL=local' > .claude/secrets.local.op

# Test precedence
CLAUDE_DEBUG=true ./bin/claude-with-identity -c "echo \$LEVEL"

# Expected:
# - DEBUG shows all three files loaded
# - Output shows "local" (last file wins)
```

### 5. Error Handling

```bash
# Test with invalid secret reference
echo 'BAD_SECRET=op://NonExistent/item/field' > ~/.config/claude-code/secrets.op

# Run wrapper
./bin/claude-with-identity --version

# Expected:
# - op run fails with descriptive error
# - Error indicates which reference is invalid
# - Process exits with non-zero code
```

### 6. Without 1Password

```bash
# Temporarily rename op to simulate absence
sudo mv /opt/homebrew/bin/op /opt/homebrew/bin/op.disabled

# Run wrapper
./bin/claude-with-identity --version

# Expected:
# - Works normally without secrets
# - No 1Password-related errors
# - Git identity still set

# Restore
sudo mv /opt/homebrew/bin/op.disabled /opt/homebrew/bin/op
```

### 7. Git Hook Integration

```bash
# Create a test hook that needs secrets
mkdir -p .git/hooks
cat > .git/hooks/pre-commit <<'EOF'
#!/usr/bin/env bash
# Test hook - verify secrets available
if [[ -n "${ANTHROPIC_API_KEY}" ]]; then
    echo "Hook has access to secrets ✓"
else
    echo "Hook does NOT have access to secrets ✗"
    exit 1
fi
EOF
chmod +x .git/hooks/pre-commit

# Make a commit through wrapper
./bin/claude-with-identity -c "git commit --allow-empty -m 'test'"

# Expected:
# - Hook executes
# - Hook has access to ANTHROPIC_API_KEY
# - Commit succeeds
```

## Continuous Integration

### GitHub Actions Example

```yaml
name: Test Wrapper

on: [push, pull_request]

jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3

      - name: Install ShellCheck
        run: brew install shellcheck

      - name: Run tests
        run: ./tests/test-wrapper.sh
```

### Pre-commit Hook

```bash
#!/usr/bin/env bash
# .git/hooks/pre-commit

# Run wrapper tests before allowing commit
if ! ./tests/test-wrapper.sh; then
    echo "Wrapper tests failed. Commit blocked."
    exit 1
fi
```

## Troubleshooting

### Tests fail with "command not found"

**Cause**: Missing test dependencies

**Solution**:

```bash
# macOS
brew install coreutils

# Check bash version
bash --version  # Should be 5.0+
```

### ShellCheck test fails

**Cause**: ShellCheck not installed or found issues

**Solution**:

```bash
# Install ShellCheck
brew install shellcheck

# Run manually to see issues
shellcheck bin/claude-with-identity
```

### Integration tests skip

**Cause**: Can't safely modify wrapper for testing

**Solution**: This is normal on some systems. Manual integration testing recommended.

## Adding New Tests

### Test Template

```bash
test_new_feature() {
    echo ""
    echo "Test N: Description of test"

    # Your test logic
    local result="$(some_command)"

    # Assertions
    assert_equals "expected" "${result}" "Feature works correctly"
    assert_contains "substring" "${result}" "Output contains expected text"
}
```

### Register Test

Add to `main()` function:

```bash
main() {
    # ... existing tests ...
    test_new_feature
}
```

## Related Documentation

- [SECRETS.md](../docs/SECRETS.md) - 1Password integration guide
- [ShellCheck](https://www.shellcheck.net/) - Shell script static analysis
- [Bash Testing](https://github.com/bats-core/bats-core) - Alternative testing frameworks
