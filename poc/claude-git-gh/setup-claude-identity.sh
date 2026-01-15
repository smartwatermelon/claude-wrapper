#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Claude Code CLI Identity Setup Script
# ============================================================================
#
# This script sets up a separate Git/GitHub identity for Claude Code CLI.
# Run it once to configure your system.
#
# What it does:
#   1. Generates a dedicated SSH key for Claude Code
#   2. Creates necessary directories
#   3. Installs the wrapper script
#   4. Updates SSH config
#   5. Provides instructions for manual steps
#
# ============================================================================

# CONFIGURATION
# =============
CLAUDE_GIT_NAME="Claude Code Bot"
CLAUDE_GIT_EMAIL="claude-code@smartwatermelon.github"
CLAUDE_SSH_KEY="${HOME}/.ssh/id_ed25519_claude_code"
CLAUDE_CONFIG_DIR="${HOME}/.config/claude-code"
WRAPPER_INSTALL_PATH="${HOME}/.local/bin/claude-with-identity"
SSH_CONFIG="${HOME}/.ssh/config"

# COLORS
# ======
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

# MAIN
# ====

echo ""
echo "=============================================="
echo " Claude Code CLI Identity Setup"
echo "=============================================="
echo ""
echo "This will configure a separate Git identity for Claude Code CLI:"
echo "  Name:  ${CLAUDE_GIT_NAME}"
echo "  Email: ${CLAUDE_GIT_EMAIL}"
echo ""

# Step 1: Generate SSH key
echo "Step 1: SSH Key Generation"
echo "--------------------------"
if [[ -f "${CLAUDE_SSH_KEY}" ]]; then
  warn "SSH key already exists at ${CLAUDE_SSH_KEY}"
  read -r -p "     Regenerate? (y/N): " regen
  if [[ "${regen}" =~ ^[Yy]$ ]]; then
    rm -f "${CLAUDE_SSH_KEY}" "${CLAUDE_SSH_KEY}.pub"
    ssh-keygen -t ed25519 -f "${CLAUDE_SSH_KEY}" -C "claude-code@$(hostname)" -N ""
    success "New SSH key generated"
  else
    info "Keeping existing key"
  fi
else
  info "Generating new SSH key..."
  ssh-keygen -t ed25519 -f "${CLAUDE_SSH_KEY}" -C "claude-code@$(hostname)" -N ""
  success "SSH key generated at ${CLAUDE_SSH_KEY}"
fi
echo ""

# Step 2: Create config directory
echo "Step 2: Configuration Directory"
echo "--------------------------------"
if [[ ! -d "${CLAUDE_CONFIG_DIR}" ]]; then
  mkdir -p "${CLAUDE_CONFIG_DIR}"
  chmod 700 "${CLAUDE_CONFIG_DIR}"
  success "Created ${CLAUDE_CONFIG_DIR}"
else
  info "Config directory already exists"
fi
echo ""

# Step 3: Install wrapper script
echo "Step 3: Wrapper Script Installation"
echo "------------------------------------"
mkdir -p "$(dirname "${WRAPPER_INSTALL_PATH}")"

# Download or copy the wrapper script
# For this setup, we'll create it inline
cat >"${WRAPPER_INSTALL_PATH}" <<'WRAPPER_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# Git identity for Claude Code operations
CLAUDE_GIT_NAME="Claude Code Bot"
CLAUDE_GIT_EMAIL="claude-code@smartwatermelon.github"
CLAUDE_SSH_KEY="${HOME}/.ssh/id_ed25519_claude_code"
CLAUDE_GH_TOKEN_FILE="${HOME}/.config/claude-code/gh-token"

# Set Git author/committer identity
export GIT_AUTHOR_NAME="${CLAUDE_GIT_NAME}"
export GIT_AUTHOR_EMAIL="${CLAUDE_GIT_EMAIL}"
export GIT_COMMITTER_NAME="${CLAUDE_GIT_NAME}"
export GIT_COMMITTER_EMAIL="${CLAUDE_GIT_EMAIL}"

# Use dedicated SSH key
if [[ -f "${CLAUDE_SSH_KEY}" ]]; then
    export GIT_SSH_COMMAND="ssh -i ${CLAUDE_SSH_KEY} -o IdentitiesOnly=yes"
fi

# Load GitHub CLI token
if [[ -f "${CLAUDE_GH_TOKEN_FILE}" ]]; then
    export GH_TOKEN
    GH_TOKEN="$(cat "${CLAUDE_GH_TOKEN_FILE}")"
fi

# Find real claude binary
WRAPPER_PATH="$(realpath "${BASH_SOURCE[0]}")"
CLAUDE_BIN=""
while IFS= read -r candidate; do
    candidate_real="$(realpath "${candidate}" 2>/dev/null || echo "${candidate}")"
    if [[ "${candidate_real}" != "${WRAPPER_PATH}" ]] && [[ -x "${candidate}" ]]; then
        CLAUDE_BIN="${candidate}"
        break
    fi
done < <(type -ap claude 2>/dev/null)

if [[ -z "${CLAUDE_BIN}" ]]; then
    for candidate in "${HOME}/.claude/local/claude" "${HOME}/.npm-global/bin/claude" "/opt/homebrew/bin/claude" "/usr/local/bin/claude"; do
        if [[ -x "${candidate}" ]]; then
            candidate_real="$(realpath "${candidate}" 2>/dev/null || echo "${candidate}")"
            if [[ "${candidate_real}" != "${WRAPPER_PATH}" ]]; then
                CLAUDE_BIN="${candidate}"
                break
            fi
        fi
    done
fi

if [[ -z "${CLAUDE_BIN}" ]]; then
    echo "Error: Could not find claude binary" >&2
    exit 1
fi

exec "${CLAUDE_BIN}" "$@"
WRAPPER_SCRIPT

chmod +x "${WRAPPER_INSTALL_PATH}"
success "Installed wrapper script at ${WRAPPER_INSTALL_PATH}"
echo ""

# Step 4: Update SSH config
echo "Step 4: SSH Configuration"
echo "-------------------------"
SSH_CONFIG_ENTRY="
# Claude Code CLI - uses dedicated key
Host github.com-claude
    HostName github.com
    User git
    IdentityFile ${CLAUDE_SSH_KEY}
    IdentitiesOnly yes
"

if [[ -f "${SSH_CONFIG}" ]] && grep -q "github.com-claude" "${SSH_CONFIG}"; then
  info "SSH config entry already exists"
else
  echo "${SSH_CONFIG_ENTRY}" >>"${SSH_CONFIG}"
  success "Added SSH config entry for github.com-claude"
fi
echo ""

# Step 5: Display manual steps
echo "=============================================="
echo " Manual Steps Required"
echo "=============================================="
echo ""
echo -e "${YELLOW}1. Add SSH key to GitHub:${NC}"
echo "   Copy this public key to GitHub → Settings → SSH Keys:"
echo ""
echo "   $(cat "${CLAUDE_SSH_KEY}.pub")"
echo ""
echo "   Name it: 'Claude Code CLI - $(hostname)'"
echo ""
echo -e "${YELLOW}2. Create fine-grained PAT:${NC}"
echo "   GitHub → Settings → Developer settings → Fine-grained tokens"
echo "   - Token name: claude-code-cli"
echo "   - Repository access: Select only needed repos"
echo "   - Permissions: Contents (R/W), Metadata (Read), Pull requests (R/W)"
echo ""
echo "   Then store it:"
echo "   echo 'YOUR_TOKEN' > ${CLAUDE_CONFIG_DIR}/gh-token"
echo "   chmod 600 ${CLAUDE_CONFIG_DIR}/gh-token"
echo ""
echo -e "${YELLOW}3. Add shell alias:${NC}"
echo "   Add to ~/.config/bash/aliases.sh:"
echo ""
echo "   alias claude-ai='${WRAPPER_INSTALL_PATH}'"
echo ""
echo "   Then run: source ~/.bash_profile"
echo ""
echo "=============================================="
echo " Verification"
echo "=============================================="
echo ""
echo "Test SSH key:"
echo "  ${WRAPPER_INSTALL_PATH} 'echo test' # or any claude command"
echo ""
echo "Test git identity:"
echo "  GIT_AUTHOR_NAME='${CLAUDE_GIT_NAME}' git var GIT_AUTHOR_IDENT"
echo ""
success "Setup complete! Follow the manual steps above to finish."
