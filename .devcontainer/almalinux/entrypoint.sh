#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ============================================================================
# AlmaLinux Agent Entrypoint
# Downloads and installs the CheckMK agent, deploys the dnf plugin,
# registers with the CheckMK server, and starts the agent daemon.
# ============================================================================

set -euo pipefail

CMK_SERVER="${CMK_SERVER:-checkmk-server}"
CMK_SITE="${CMK_SITE:-cmk}"
CMK_USER="${CMK_USER:-cmkadmin}"
CMK_PASSWORD="${CMK_PASSWORD:-cmk}"
AGENT_HOSTNAME="${AGENT_HOSTNAME:-almalinux-host}"
WORKSPACE="${WORKSPACE:-/workspace}"

readonly API_URL="http://${CMK_SERVER}:5000/${CMK_SITE}/check_mk/api/1.0"

echo "============================================================================"
echo "AlmaLinux — CheckMK Agent Setup"
echo "============================================================================"

# --- Wait for CheckMK server to become ready ---
echo "Waiting for CheckMK server at ${CMK_SERVER}..."
MAX_ATTEMPTS=60
ATTEMPT=0
until curl -sf -o /dev/null \
    "${API_URL}/version" \
    -H "Authorization: Bearer ${CMK_USER} ${CMK_PASSWORD}"; do
    ATTEMPT=$((ATTEMPT + 1))
    if (( ATTEMPT >= MAX_ATTEMPTS )); then
        echo "ERROR: CheckMK server not ready after $((MAX_ATTEMPTS * 5))s"
        exec tail -f /dev/null
    fi
    sleep 5
done
echo "CheckMK server is ready."

# --- Download and install the CheckMK agent ---
if ! rpm -q check-mk-agent >/dev/null 2>&1; then
    echo "Downloading CheckMK agent RPM..."
    AGENTS_PAGE="http://${CMK_SERVER}:5000/${CMK_SITE}/check_mk/agents/"
    RPM_NAME=$(curl -sf "${AGENTS_PAGE}" \
        | grep -oP 'check-mk-agent-[0-9][^"]*\.noarch\.rpm' \
        | head -n1) || true

    if [[ -z "${RPM_NAME:-}" ]]; then
        echo "ERROR: Could not find agent RPM on CheckMK server"
        exec tail -f /dev/null
    fi

    curl -sf -o /tmp/check-mk-agent.rpm "${AGENTS_PAGE}${RPM_NAME}"
    echo "Installing CheckMK agent (${RPM_NAME})..."
    rpm -ivh --nodeps /tmp/check-mk-agent.rpm || true
    rm -f /tmp/check-mk-agent.rpm
else
    echo "CheckMK agent already installed."
fi

# --- Deploy the dnf agent plugin via symlink ---
PLUGIN_SRC="${WORKSPACE}/agents/plugins/dnf"
PLUGIN_DST="/usr/lib/check_mk_agent/plugins/dnf"

if [[ -f "${PLUGIN_SRC}" ]]; then
    echo "Deploying dnf agent plugin (symlink)..."
    ln -sf "${PLUGIN_SRC}" "${PLUGIN_DST}"
    chmod +x "${PLUGIN_DST}" 2>/dev/null || true
else
    echo "WARNING: Agent plugin not found at ${PLUGIN_SRC}"
fi

# --- Create the host in CheckMK via REST API ---
echo "Creating host '${AGENT_HOSTNAME}' in CheckMK..."
OWN_IP=$(hostname -i 2>/dev/null | awk '{print $1}')

HTTP_CODE=$(curl -sf -o /tmp/api_resp.json -w "%{http_code}" \
    -X POST "${API_URL}/domain-types/host_config/collections/all" \
    -H "Authorization: Bearer ${CMK_USER} ${CMK_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d "{
        \"host_name\": \"${AGENT_HOSTNAME}\",
        \"folder\": \"/\",
        \"attributes\": {\"ipaddress\": \"${OWN_IP}\"}
    }" 2>/dev/null) || HTTP_CODE="000"

case "${HTTP_CODE}" in
    200|201) echo "Host created successfully." ;;
    400)     echo "Host may already exist (HTTP 400), continuing." ;;
    *)       echo "WARNING: Host creation returned HTTP ${HTTP_CODE}"
             cat /tmp/api_resp.json 2>/dev/null || true ;;
esac

# --- Activate pending changes ---
echo "Activating changes..."
sleep 3
curl -sf -o /dev/null \
    -X POST "${API_URL}/domain-types/activation_run/actions/activate-changes/invoke" \
    -H "Authorization: Bearer ${CMK_USER} ${CMK_PASSWORD}" \
    -H "Content-Type: application/json" \
    -H "If-Match: *" \
    -d "{\"force_foreign_changes\": true, \"sites\": [\"${CMK_SITE}\"]}" \
    || echo "WARNING: Change activation may have failed"

sleep 5

# --- Register the agent controller with the CheckMK server ---
echo "Registering agent controller with CheckMK server..."
if command -v cmk-agent-ctl >/dev/null 2>&1; then
    cmk-agent-ctl register \
        --hostname "${AGENT_HOSTNAME}" \
        --server "${CMK_SERVER}:8000" \
        --site "${CMK_SITE}" \
        --user "${CMK_USER}" \
        --password "${CMK_PASSWORD}" \
        --trust-cert \
        2>&1 || echo "WARNING: Agent controller registration may have failed"

    echo "Starting agent controller daemon..."
    cmk-agent-ctl daemon &
else
    echo "WARNING: cmk-agent-ctl not found — using legacy agent mode"
    # Fallback: start xinetd for legacy agent pull
    if command -v xinetd >/dev/null 2>&1; then
        xinetd -stayalive &
    fi
fi

echo "============================================================================"
echo "AlmaLinux agent setup complete."
echo "  Host: ${AGENT_HOSTNAME}  IP: ${OWN_IP}"
echo "============================================================================"

# Keep container running
exec tail -f /dev/null
