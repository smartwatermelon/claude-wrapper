# Claude Code Infrastructure - Project-Specific

This directory was automatically created by Git template when you initialized or cloned this repository.

## What is this?

The `.claude/` directory provides project-specific configuration and extensions for Claude Code CLI (CCCLI) collaboration. It integrates with global infrastructure at `~/.claude/` to provide:

- Project-specific configuration (Node version, required tools, deployment secrets)
- Custom git hook extensions for project-specific validation
- Project-local documentation and patterns

## Directory Structure

```
.claude/
├── README.md                  # This file
├── config.sh.template         # Template for project configuration
└── hooks/
    └── extensions/            # Project-specific git hook extensions
        └── example.sh.disabled  # Example extension (disabled by default)
```

## Quick Start

### Option 1: No Additional Configuration Needed

If your project doesn't need special validation, required secrets, or version constraints, **you're done**! Your project already benefits from global infrastructure:

- Global git hooks (pre-commit, pre-push)
- Code review automation
- Branch protection
- Standard workflows

### Option 2: Add Project Configuration

If you need project-specific settings:

1. Copy the template:

   ```bash
   cp .claude/config.sh.template .claude/config.sh
   ```

2. Edit `.claude/config.sh` to define:
   - Required Node version
   - Required tools (EAS, Maestro, jq, etc.)
   - Deployment secrets
   - Custom pre/post build hooks

3. Update your build/deploy scripts to source the config:

   ```bash
   # In build scripts
   source "${HOME}/.claude/lib/build-commons.sh"
   [[ -f ".claude/config.sh" ]] && source ".claude/config.sh"
   run_preflight_checks

   # In deploy scripts
   source "${HOME}/.claude/lib/deploy-commons.sh"
   source ".claude/config.sh"
   verify_cloudflare_secrets "${DEPLOYMENT_REQUIRED_SECRETS[@]}"
   ```

### Option 3: Add Custom Hook Extensions

If you need project-specific validation:

1. Create a new file in `.claude/hooks/extensions/`:

   ```bash
   touch .claude/hooks/extensions/my-validation.sh
   chmod +x .claude/hooks/extensions/my-validation.sh
   ```

2. Write your validation logic:

   ```bash
   #!/usr/bin/env bash
   # Extension contract:
   #   - Exit 0: Check passed (allow git operation)
   #   - Exit 1: Check failed (block git operation)
   #   - Can use functions from ~/.claude/hooks/lib/hook-common.sh

   # Your validation logic here
   if [[ condition_fails ]]; then
     echo "ERROR: Validation failed"
     exit 1
   fi

   exit 0
   ```

3. Extensions run automatically on relevant git operations (commit, push, etc.)

## Common Patterns

### Node.js Project with Version Requirement

```bash
# .claude/config.sh
export REQUIRED_NODE_VERSION="20"
```

### Project with Deployment Secrets

```bash
# .claude/config.sh
export DEPLOYMENT_REQUIRED_SECRETS=(
  "API_KEY"
  "DATABASE_URL"
  "JWT_SECRET"
)
```

### Custom Security Check

```bash
# .claude/hooks/extensions/security.sh
#!/usr/bin/env bash

# Block commits with hardcoded API keys
if git diff --cached | grep -iE 'API_KEY.*=.*"[A-Za-z0-9]{32}"'; then
  echo "ERROR: Hardcoded API key detected"
  exit 1
fi

exit 0
```

## Integration with Global Infrastructure

Global hooks at `~/.config/git/hooks/` automatically discover and run extensions in this directory. No configuration needed - just add your `.sh` files and make them executable.

**Global Infrastructure Documentation**: `~/.claude/docs/INFRASTRUCTURE.md`

## Files Included

### config.sh.template

Template for project configuration. Copy to `config.sh` and customize with your project's requirements.

### hooks/extensions/example.sh.disabled

Example extension showing the basic structure. Disabled by default (`.disabled` suffix prevents execution).

To enable:

1. Remove `.disabled` suffix: `mv example.sh.disabled my-check.sh`
2. Customize validation logic
3. Ensure executable: `chmod +x .claude/hooks/extensions/my-check.sh`

## Next Steps

1. **Review your needs**: Do you need project-specific configuration or validation?
2. **If yes**: Follow Quick Start Option 2 or 3 above
3. **If no**: You're done! Just start working

## Documentation

- **Global Infrastructure**: `~/.claude/docs/INFRASTRUCTURE.md`
- **Build Patterns**: `~/.claude/docs/BUILD_PATTERNS.md` (if exists)
- **Deployment Patterns**: `~/.claude/docs/DEPLOYMENT_PATTERNS.md` (if exists)
- **Hook System**: `~/.claude/docs/HOOKS.md` (if exists)

## Troubleshooting

### Extensions not running?

```bash
# Check extensions are executable
ls -la .claude/hooks/extensions/

# Make executable if needed
chmod +x .claude/hooks/extensions/*.sh
```

### Config not being used?

```bash
# Verify config exists and is sourced
ls -la .claude/config.sh

# Check your build/deploy scripts source it
grep -r "source.*config.sh" scripts/
```

### Need help?

See global infrastructure documentation at `~/.claude/docs/INFRASTRUCTURE.md` for complete reference.
