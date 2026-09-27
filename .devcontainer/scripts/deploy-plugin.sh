#!/bin/bash
# ============================================================================
# Deploy Plugin — Refresh symlinks and reload CheckMK
# Run this after changing server-side plugin code to pick up the changes.
# ============================================================================

set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"

# Re-run the symlink setup
bash "${WORKSPACE}/.devcontainer/scripts/post-create.sh"

# Reload the CheckMK configuration to pick up server-side changes
echo "Reloading CheckMK configuration..."
cmk -R 2>/dev/null || omd restart apache 2>/dev/null || true

echo "CheckMK configuration reloaded."
