#!/bin/bash
# ============================================================================
# Discover Services — Trigger service discovery on a monitored host
# Uses the CheckMK REST API to discover and accept all services.
# ============================================================================

set -euo pipefail

CMK_SITE="${CMK_SITE:-cmk}"
CMK_USER="${CMK_USER:-cmkadmin}"
CMK_PASSWORD="${CMK_PASSWORD:-cmk}"
TARGET_HOST="${1:-almalinux-host}"

readonly API_URL="http://localhost:5000/${CMK_SITE}/check_mk/api/1.0"

echo "Discovering services on '${TARGET_HOST}'..."

# Trigger service discovery (fix_all = accept new + remove vanished)
HTTP_CODE=$(curl -sf -o /tmp/discovery_resp.json -w "%{http_code}" \
    -X POST "${API_URL}/domain-types/service_discovery_run/actions/start/invoke" \
    -H "Authorization: Bearer ${CMK_USER} ${CMK_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d "{\"host_name\": \"${TARGET_HOST}\", \"mode\": \"fix_all\"}" \
    2>/dev/null) || HTTP_CODE="000"

if [[ "${HTTP_CODE}" == "200" ]] || [[ "${HTTP_CODE}" == "302" ]]; then
    echo "Service discovery started."
else
    echo "WARNING: Service discovery returned HTTP ${HTTP_CODE}"
    cat /tmp/discovery_resp.json 2>/dev/null || true
fi

echo "Waiting for discovery to complete..."
sleep 10

# Activate changes
echo "Activating changes..."
curl -sf -o /dev/null \
    -X POST "${API_URL}/domain-types/activation_run/actions/activate-changes/invoke" \
    -H "Authorization: Bearer ${CMK_USER} ${CMK_PASSWORD}" \
    -H "Content-Type: application/json" \
    -H "If-Match: *" \
    -d "{\"force_foreign_changes\": true, \"sites\": [\"${CMK_SITE}\"]}" \
    || echo "WARNING: Change activation may have failed"

echo "Service discovery complete for '${TARGET_HOST}'."
