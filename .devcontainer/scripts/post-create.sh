#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ============================================================================
# Post-Create Setup — CheckMK DNF Plugin DevContainer
# Symlinks plugin source files into the CheckMK site's local hierarchy
# so that live code changes are reflected immediately.
# ============================================================================

set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
CMK_LOCAL="${OMD_ROOT:-/omd/sites/cmk}/local"

echo "============================================================================"
echo "CheckMK DNF Plugin — Post-Create Setup"
echo "============================================================================"

# --- Server-side check plugin (Agent Based API v2) ---
mkdir -p "${CMK_LOCAL}/lib/python3/cmk_addons/plugins/dnf/agent_based"
ln -sf "${WORKSPACE}/lib/python3/cmk_addons/plugins/dnf/agent_based/dnf.py" \
       "${CMK_LOCAL}/lib/python3/cmk_addons/plugins/dnf/agent_based/dnf.py"

# --- Checkman page ---
mkdir -p "${CMK_LOCAL}/lib/python3/cmk_addons/plugins/dnf/checkman"
ln -sf "${WORKSPACE}/lib/python3/cmk_addons/plugins/dnf/checkman/dnf" \
       "${CMK_LOCAL}/lib/python3/cmk_addons/plugins/dnf/checkman/dnf"

# --- Rulesets ---
mkdir -p "${CMK_LOCAL}/lib/python3/cmk_addons/plugins/dnf/rulesets"
ln -sf "${WORKSPACE}/lib/python3/cmk_addons/plugins/dnf/rulesets/ruleset_dnf_bakery.py" \
       "${CMK_LOCAL}/lib/python3/cmk_addons/plugins/dnf/rulesets/ruleset_dnf_bakery.py"
ln -sf "${WORKSPACE}/lib/python3/cmk_addons/plugins/dnf/rulesets/ruleset_dnf_check_parameters.py" \
       "${CMK_LOCAL}/lib/python3/cmk_addons/plugins/dnf/rulesets/ruleset_dnf_check_parameters.py"

# --- Bakery plugin (Bakery API v1 — separate from cmk_addons hierarchy) ---
mkdir -p "${CMK_LOCAL}/lib/check_mk/base/cee/plugins/bakery"
ln -sf "${WORKSPACE}/lib/check_mk/base/cee/plugins/bakery/dnf.py" \
       "${CMK_LOCAL}/lib/check_mk/base/cee/plugins/bakery/dnf.py"

# --- Agent plugin ---
mkdir -p "${CMK_LOCAL}/share/check_mk/agents/plugins"
ln -sf "${WORKSPACE}/agents/plugins/dnf" \
       "${CMK_LOCAL}/share/check_mk/agents/plugins/dnf"

echo "Plugin files symlinked into CheckMK site."

# --- Set admin password and ensure account is unlocked ---
CMK_PASSWORD="${CMK_PASSWORD:-cmk}"
echo "Setting cmkadmin password and unlocking account..."
sudo htpasswd -b /omd/sites/cmk/etc/htpasswd cmkadmin "${CMK_PASSWORD}"
sudo sed -i "s/'locked': True/'locked': False/g" \
    /omd/sites/cmk/etc/check_mk/multisite.d/wato/users.mk
echo "0" | sudo tee /omd/sites/cmk/var/check_mk/web/cmkadmin/num_failed_logins.mk > /dev/null

# --- Start OMD site (ensures services are running after container creation) ---
echo "Starting OMD site 'cmk'..."
sudo omd start cmk || sudo omd restart cmk

echo "============================================================================"
echo "Setup complete!"
echo "  CheckMK Web UI: http://localhost:5000/cmk/"
echo "  Login: cmkadmin / ${CMK_PASSWORD}"
echo "  AlmaLinux host: almalinux-host (auto-registered)"
echo "============================================================================"
