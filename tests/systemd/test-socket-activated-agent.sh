#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# End-to-end test of the background refresh under a socket-activated agent.
#
# Boots a systemd container, installs the real Checkmk agent RPM, deploys the
# plugin synchronously (plugins/, no interval) and queries the agent through
# its socket: the local socket the agent controller reads, or TCP port 6556
# when the RPM falls back to it (no controller for the host architecture).
# Checkmk's per-connection unit check-mk-agent@.service kills every process
# left in its cgroup when the agent exits, so a refresh that merely runs
# detached never writes its cache.
#
# Usage: test-socket-activated-agent.sh <agent rpm> [image]
# Needs Docker with privileged containers.
set -euo pipefail

RPM="$(realpath "$1")"
IMAGE="${2:-docker.io/almalinux/9-init}"
REPO_DIR="$(realpath "$(dirname "$0")/../..")"
CACHE=/var/lib/check_mk_agent/cache/dnf_updates.cache

container=$(docker run -d --privileged \
    -v "${RPM}:/agent.rpm:ro" -v "${REPO_DIR}:/code:ro" "${IMAGE}")
trap 'docker rm -f "${container}" >/dev/null' EXIT

in_container() {
    docker exec "${container}" bash -euc "$1"
}

# The agent (MK_READ_REMOTE=true) reads the socket until EOF before it
# answers, so close the sending side first, as the agent controller does.
query_agent() {
    in_container 'python3 -c "
import os, socket
if os.path.exists(\"/run/check-mk-agent.socket\"):
    s = socket.socket(socket.AF_UNIX)
    s.connect(\"/run/check-mk-agent.socket\")
else:
    s = socket.create_connection((\"127.0.0.1\", 6556))
s.settimeout(120)
s.shutdown(socket.SHUT_WR)
print(b\"\".join(iter(lambda: s.recv(65536), b\"\")).decode(errors=\"replace\"))
"' | awk '/^<<<dnf>>>/ {p = 1; print; next} /^<<</ {p = 0} p'
}

echo "==> Waiting for systemd"
for _ in $(seq 60); do
    state=$(docker exec "${container}" systemctl is-system-running 2>/dev/null) || true
    [[ "${state}" == running || "${state}" == degraded ]] && break
    sleep 1
done

echo "==> Installing the agent and the plugin (synchronous, no interval)"
in_container 'dnf -y -q install /agent.rpm python3 >/dev/null && dnf -q makecache'
in_container 'install -m 0755 /code/agents/plugins/dnf /usr/lib/check_mk_agent/plugins/dnf'
for _ in $(seq 30); do
    docker exec "${container}" systemctl is-active --quiet check-mk-agent.socket && break
    sleep 1
done

echo "==> First agent query (starts the background refresh)"
query_agent

echo "==> Waiting for the refresh to write ${CACHE}"
for _ in $(seq 120); do
    if docker exec "${container}" test -s "${CACHE}"; then
        echo "==> Second agent query"
        output=$(query_agent)
        echo "${output}"
        if grep -q '^ERROR:' <<< "${output}"; then
            echo "FAIL: second query still reports an error" >&2
            exit 1
        fi
        echo "PASS"
        exit 0
    fi
    sleep 1
done

echo "FAIL: the background refresh never wrote ${CACHE}" >&2
docker exec "${container}" journalctl --no-pager -n 30 >&2 || true
exit 1
