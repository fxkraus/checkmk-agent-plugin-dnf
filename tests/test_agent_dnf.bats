#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# BATS tests for the DNF agent plugin.
#
# Prerequisites:
#   - Install BATS: https://github.com/bats-core/bats-core
#   - On RHEL: dnf install bats
#   - On Debian/Ubuntu: apt install bats
#
# Run with:
#   bats tests/test_agent_dnf.bats

setup() {
    # Create a temporary directory for test artifacts
    TEST_TEMP_DIR="$(mktemp -d)"

    # Set up mock MK_VARDIR
    export MK_VARDIR="${TEST_TEMP_DIR}/mk_vardir"
    mkdir -p "${MK_VARDIR}/cache"
    # The agent refuses a group-writable MK_VARDIR or cache dir (umask 002 is
    # common)
    chmod 755 "${MK_VARDIR}" "${MK_VARDIR}/cache"

    # Path to the agent plugin
    AGENT_PLUGIN="${BATS_TEST_DIRNAME}/../agents/plugins/dnf"
    RESULT_CACHE="${MK_VARDIR}/cache/dnf_updates.cache"
    PENDING="${MK_VARDIR}/cache/dnf_refresh_pending.cache"
    STUB_BIN=""
    # Written by the fingerprint test only, removed in teardown
    TEST_REPO_FILE="/etc/yum.repos.d/bats-fingerprint-test.repo"
}

# Run the agent, restricted to STUB_BIN when use_fake_pm set one up.
agent() {
    if [[ -n "${STUB_BIN}" ]]; then
        env PATH="${STUB_BIN}" bash "${AGENT_PLUGIN}" "$@"
    else
        bash "${AGENT_PLUGIN}" "$@"
    fi
}

# Do the refresh in the foreground (what the detached job does), then the
# normal agent run that serves the cache.
run_agent_refreshed() {
    agent --refresh
    run agent
    echo "$output"
}

# wait_for_file <path>: up to 10 s for a background refresh to write it
wait_for_file() {
    local i
    for (( i = 0; i < 50; i++ )); do
        [[ -s "$1" ]] && return 0
        sleep 0.2
    done
    return 1
}

# Block until no background refresh holds the lock
wait_for_refresh() {
    flock "${MK_VARDIR}/cache/dnf_refresh.lock" true
}

# Build a PATH with only the tools the agent needs plus tests/fixtures/fake-pm
# installed as $1 (dnf5, dnf or yum), so no real package manager is picked up.
use_fake_pm() {
    export FAKE_PM_DIR="${TEST_TEMP_DIR}/pm"
    STUB_BIN="${TEST_TEMP_DIR}/bin"
    mkdir -p "${FAKE_PM_DIR}" "${STUB_BIN}"

    local tool
    for tool in bash awk cat cut date flock grep head ls mkdir mv paste rm sed setsid sort stat tail timeout touch uname; do
        ln -s "$(command -v "$tool")" "${STUB_BIN}/${tool}"
    done
    ln -s "${BATS_TEST_DIRNAME}/fixtures/fake-pm" "${STUB_BIN}/$1"
}

# fake_pm_reply <key> <exit code> [output]
fake_pm_reply() {
    printf '%s' "${3:-}" > "${FAKE_PM_DIR}/$1.out"
    echo "$2" > "${FAKE_PM_DIR}/$1.rc"
}

# pending_upgrade <pm> <check command>: print a package with a pending
# upgrade. Fresh images are usually fully patched, so downgrade packages that
# have older builds in the tested repos to create one. Prints nothing on failure.
pending_upgrade() {
    local pkg
    pkg=$("$1" -q "$2" | awk '/^[^[:space:]]/ {print $1; exit}')
    if [[ -z "$pkg" ]] && "$1" -y -q downgrade acl attr tzdata &>/dev/null; then
        pkg=$("$1" -q "$2" | awk '/^[^[:space:]]/ {print $1; exit}')
    fi
    echo "$pkg"
}

# fake_kernel <running VERSION-RELEASE> <installed VERSION-RELEASE...>
# Fakes uname -r and rpm (tests/fixtures/fake-rpm); the running kernel's
# config file is owned by kernel-core unless config-owners is rewritten.
fake_kernel() {
    local running="$1"
    shift
    # Remove the symlink first; writing through it would replace the real uname
    rm -f "${STUB_BIN}/uname"
    printf '#!/bin/bash\necho %s.x86_64\n' "${running}" > "${STUB_BIN}/uname"
    chmod +x "${STUB_BIN}/uname"
    ln -s "${BATS_TEST_DIRNAME}/fixtures/fake-rpm" "${STUB_BIN}/rpm"
    echo "kernel-core ${running}" > "${FAKE_PM_DIR}/config-owners"
    printf '%s\n' "$@" > "${FAKE_PM_DIR}/kernels"
    fake_pm_reply check-update 0
    fake_pm_reply check-update-security 0
}

teardown() {
    rm -f "${TEST_REPO_FILE}"
    # A background refresh may still be starting up or writing into the cache
    # directory, so wait for its lock and retry the removal.
    local i
    for (( i = 0; i < 50; i++ )); do
        if [[ -e "${MK_VARDIR:-}/cache/dnf_refresh.lock" ]]; then
            wait_for_refresh
        fi
        rm -rf "${TEST_TEMP_DIR}" 2>/dev/null && return 0
        sleep 0.2
    done
    rm -rf "${TEST_TEMP_DIR}"
}

# =============================================================================
# Basic functionality tests
# =============================================================================

@test "Agent plugin is executable" {
    [ -x "${AGENT_PLUGIN}" ]
}

@test "Agent plugin starts with shebang" {
    head -1 "${AGENT_PLUGIN}" | grep -q '^#!/bin/bash'
}

@test "Agent plugin outputs dnf section header" {
    # This test may fail on non-RPM systems; skip if no package manager
    if ! command -v dnf &>/dev/null && ! command -v yum &>/dev/null; then
        skip "No dnf or yum available"
    fi

    run timeout 10 bash "${AGENT_PLUGIN}"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '<<<dnf>>>'
}

@test "Agent plugin fails gracefully without MK_VARDIR" {
    unset MK_VARDIR
    run bash "${AGENT_PLUGIN}"
    [ "$status" -eq 0 ]  # Should exit 0 (graceful failure)
    echo "$output" | grep -q 'ERROR:'
}

# =============================================================================
# Output format tests
# =============================================================================

@test "Agent output has correct number of lines" {
    if ! command -v dnf &>/dev/null && ! command -v yum &>/dev/null; then
        skip "No dnf or yum available"
    fi

    run_agent_refreshed
    [ "$status" -eq 0 ]

    # Section header + 7 data lines
    [ "${#lines[@]}" -eq 8 ]
}

@test "Reboot required line is yes or no" {
    if ! command -v dnf &>/dev/null && ! command -v yum &>/dev/null; then
        skip "No dnf or yum available"
    fi

    run_agent_refreshed
    [ "$status" -eq 0 ]
    [[ "${lines[1]}" == "yes" || "${lines[1]}" == "no" ]]
}

@test "Update count line is a number" {
    if ! command -v dnf &>/dev/null && ! command -v yum &>/dev/null; then
        skip "No dnf or yum available"
    fi

    run_agent_refreshed
    [ "$status" -eq 0 ]
    [[ "${lines[2]}" =~ ^[0-9]+$ ]]
}

@test "Security update line format is valid" {
    if ! command -v dnf &>/dev/null && ! command -v yum &>/dev/null; then
        skip "No dnf or yum available"
    fi

    run_agent_refreshed
    [ "$status" -eq 0 ]

    # Number [-2, -1, or 0+] optionally followed by package list
    [[ "${lines[3]}" =~ ^-?[0-9]+ ]]
}

# =============================================================================
# Cache behavior tests
# =============================================================================

@test "Refresh writes the result and fingerprint caches" {
    if ! command -v dnf &>/dev/null && ! command -v yum &>/dev/null; then
        skip "No dnf or yum available"
    fi

    run agent --refresh
    [ "$status" -eq 0 ]
    [ -s "${RESULT_CACHE}" ]
    [ -s "${MK_VARDIR}/cache/dnf_pkg_state.cache" ]
}

@test "Package queries don't change the fingerprint (no refresh churn)" {
    if ! command -v dnf &>/dev/null && ! command -v yum &>/dev/null; then
        skip "No dnf or yum available"
    fi

    run_agent_refreshed
    first_output="$output"
    before=$(stat -c %y "${RESULT_CACHE}")

    # A refresh started by this run would rewrite the result cache.
    run agent
    sleep 3
    [ "$output" = "$first_output" ]
    [ "$(stat -c %y "${RESULT_CACHE}")" = "$before" ]
}

# =============================================================================
# Package manager output parsing (fake package manager, runs anywhere on Linux)
# Output lines: [0] header, [1] reboot, [2] updates, [3] security,
# [4] last update, [5] metadata refresh, [6] refresh pending since,
# [7] reboot hint
# =============================================================================

@test "dnf5: update count ignores wrapped and obsoleting lines" {
    use_fake_pm dnf5
    fake_pm_reply check-upgrade 100 \
'bash.x86_64                        5.2.37-1.fc42  updates
a-very-long-package-name-that-wraps-the-column.noarch
                                   1.0-1.fc42     updates
Obsoleting packages
new-pkg.x86_64                     2-1.fc42       updates
    old-pkg.x86_64                 1-1.fc42       @System
'
    fake_pm_reply check-upgrade-security 100 \
'bash.x86_64                        5.2.37-1.fc42  updates
'
    run_agent_refreshed
    [ "$status" -eq 0 ]
    [ "${lines[2]}" = "2" ]
    [ "${lines[3]}" = "1 bash" ]
}

@test "dnf: no pending upgrades reports zero" {
    use_fake_pm dnf
    fake_pm_reply check-update 0
    fake_pm_reply check-update-security 0
    run_agent_refreshed
    [ "$status" -eq 0 ]
    [ "${lines[2]}" = "0" ]
    [[ "${lines[3]}" =~ ^0\ ?$ ]]
}

@test "Failed query is served as -1 and retried after the backoff" {
    use_fake_pm dnf5
    fake_pm_reply check-upgrade 1
    fake_pm_reply check-upgrade-security 1
    run_agent_refreshed
    [ "$status" -eq 0 ]
    [ "${lines[2]}" = "-1" ]
    [ "${lines[3]}" = "-1" ]
    [ ! -s "${MK_VARDIR}/cache/dnf_pkg_state.cache" ]
    [[ "${lines[6]}" =~ ^[0-9]+$ ]]

    # Within the backoff no agent run starts another refresh.
    fake_pm_reply check-upgrade 100 'bash.x86_64    5.2.37-1.fc42  updates
'
    fake_pm_reply check-upgrade-security 0
    run agent
    sleep 1
    wait_for_refresh
    # Only the call from the first refresh
    [ "$(grep -c . "${FAKE_PM_DIR}/check-upgrade.args")" -eq 1 ]
    grep -qx -- -1 "${RESULT_CACHE}"

    # Once it has passed, the next run retries.
    touch -d '-16 minutes' "${PENDING}"
    run agent
    for (( i = 0; i < 50; i++ )); do
        grep -qx 1 "${RESULT_CACHE}" && break
        sleep 0.2
    done
    wait_for_refresh
    run agent
    [ "${lines[2]}" = "1" ]
    [ "${lines[6]}" = "-1" ]
    [ ! -e "${PENDING}" ]
}

@test "Pending refresh reports when the first unfinished one started" {
    use_fake_pm dnf
    fake_pm_reply check-update 1
    fake_pm_reply check-update-security 1
    echo 1000 > "${PENDING}"
    touch -d '-16 minutes' "${PENDING}"
    run_agent_refreshed
    [ "$status" -eq 0 ]
    [ "${lines[6]}" = "1000" ]
}

@test "An unfinished refresh blocks new ones until the backoff has passed" {
    use_fake_pm dnf
    fake_pm_reply check-update 0
    fake_pm_reply check-update-security 0
    agent --refresh
    # A refresh that was killed (timeout) leaves the marker and a stale fingerprint.
    echo 1000 > "${PENDING}"
    : > "${MK_VARDIR}/cache/dnf_pkg_state.cache"
    rm -f "${FAKE_PM_DIR}/check-update.args"

    run agent
    sleep 1
    wait_for_refresh
    [ "${lines[6]}" = "1000" ]
    [ ! -e "${FAKE_PM_DIR}/check-update.args" ]
}

@test "A completed refresh clears the pending marker" {
    use_fake_pm dnf
    fake_pm_reply check-update 0
    fake_pm_reply check-update-security 0
    run_agent_refreshed
    [ "$status" -eq 0 ]
    [ "${lines[6]}" = "-1" ]
    [ ! -e "${PENDING}" ]
}

@test "dnf: plugins stay enabled so versionlock is honoured" {
    use_fake_pm dnf
    fake_pm_reply check-update 0
    fake_pm_reply check-update-security 0
    agent --refresh
    run cat "${FAKE_PM_DIR}/check-update.args" "${FAKE_PM_DIR}/check-update-security.args" \
        "${FAKE_PM_DIR}/history-list.args"
    echo "$output"
    [ "${#lines[@]}" -eq 3 ]
    [[ "$output" != *--noplugins* ]]
    [ "$(grep -c -- '--disableplugin=subscription-manager --disableplugin=product-id' <<< "$output")" -eq 3 ]
}

@test "dnf: last update is the newest upgrade transaction" {
    use_fake_pm dnf
    fake_pm_reply check-update 0
    fake_pm_reply check-update-security 0
    fake_pm_reply history-list 0 \
'ID     | Command line             | Date and time    | Action(s)      | Altered
-------------------------------------------------------------------------------
     4 | install which            | 2026-09-27 10:48 | Install        |    1
     3 | upgrade                  | 2026-09-20 08:00 | I, U           |   25
     2 | update bash              | 2026-09-10 08:00 | Upgrade        |    1
     1 |                          | 2026-04-26 07:47 | Install        |  126 EE
'
    run_agent_refreshed
    [ "$status" -eq 0 ]
    [ "${lines[4]}" = "$(date -d '2026-09-20 08:00' +%s)" ]
}

@test "dnf: upgrade words in the command line are not taken for an upgrade" {
    use_fake_pm dnf
    fake_pm_reply check-update 0
    fake_pm_reply check-update-security 0
    fake_pm_reply history-list 0 \
'ID     | Command line             | Date and time    | Action(s)      | Altered
-------------------------------------------------------------------------------
     4 | install a|b -x U         | 2026-09-28 09:00 | Install        |    1
     3 | install Update-tool      | 2026-09-27 10:48 | Install        |    1
     2 | upgrade                  | 2026-09-20 08:00 | Upgrade        |   25
     1 |                          | 2026-04-26 07:47 | Install        |  126 EE
'
    run_agent_refreshed
    [ "$status" -eq 0 ]
    [ "${lines[4]}" = "$(date -d '2026-09-20 08:00' +%s)" ]
}

@test "dnf: history without upgrades yields -1" {
    use_fake_pm dnf
    fake_pm_reply check-update 0
    fake_pm_reply check-update-security 0
    fake_pm_reply history-list 0 \
'ID     | Command line             | Date and time    | Action(s)      | Altered
-------------------------------------------------------------------------------
     2 | install which            | 2026-09-27 10:48 | Install        |    1
     1 |                          | 2026-04-26 07:47 | Install        |  126 EE
'
    run_agent_refreshed
    [ "$status" -eq 0 ]
    [ "${lines[4]}" = "-1" ]
}

# =============================================================================
# Background refresh
# =============================================================================

@test "First run returns immediately and refreshes in the background" {
    use_fake_pm dnf
    fake_pm_reply check-update 100 'bash.x86_64    5.1.8-9.el9    baseos
'
    fake_pm_reply check-update-security 0

    run agent
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "<<<dnf>>>" ]
    [[ "${lines[1]}" == ERROR:* ]]

    wait_for_file "${RESULT_CACHE}"
    run agent
    [ "${#lines[@]}" -eq 8 ]
    [ "${lines[2]}" = "1" ]
}

@test "Agent run doesn't wait for a slow package manager" {
    use_fake_pm dnf
    fake_pm_reply check-update 0
    fake_pm_reply check-update-security 0
    agent --refresh
    # Invalidate the fingerprint and make the next query hang.
    : > "${MK_VARDIR}/cache/dnf_pkg_state.cache"
    printf '#!/bin/bash\nsleep 8\n' > "${STUB_BIN}/dnf.slow"
    chmod +x "${STUB_BIN}/dnf.slow"
    mv -f "${STUB_BIN}/dnf.slow" "${STUB_BIN}/dnf"

    SECONDS=0
    run agent
    [ "$status" -eq 0 ]
    (( SECONDS < 5 ))
    [ "${lines[2]}" = "0" ]
}

@test "Without setsid the refresh runs inline" {
    use_fake_pm dnf
    rm -f "${STUB_BIN}/setsid"
    fake_pm_reply check-update 0
    fake_pm_reply check-update-security 0

    run agent
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 8 ]
    [ "${lines[2]}" = "0" ]
}

@test "systemd: the refresh runs in its own transient unit" {
    use_fake_pm dnf
    ln -s "${BATS_TEST_DIRNAME}/fixtures/fake-systemd-run" "${STUB_BIN}/systemd-run"
    rm -f "${STUB_BIN}/setsid"
    fake_pm_reply check-update 100 'bash.x86_64    5.1.8-9.el9    baseos
'
    fake_pm_reply check-update-security 0

    # Relative path: the unit starts in / and needs the absolute one
    cd "$(dirname "${AGENT_PLUGIN}")"
    run env PATH="${STUB_BIN}" bash ./dnf
    [ "$status" -eq 0 ]
    # The fake runs the unit in the foreground, so the result is already there
    [ "${lines[2]}" = "1" ]

    run cat "${FAKE_PM_DIR}/systemd-run.args"
    echo "$output"
    [[ "$output" == *$'\n--unit=cmk-agent-dnf-refresh\n'* ]]
    [[ "$output" == *$'\n--property=RuntimeMaxSec=300\n'* ]]
    [[ "$output" == *$'\n--setenv=MK_VARDIR='"${MK_VARDIR}"$'\n'* ]]
    [[ "${lines[-2]}" == /* ]]
    [ "${lines[-2]}" -ef "${AGENT_PLUGIN}" ]
    [ "${lines[-1]}" = "--refresh" ]
}

@test "systemd: falls back to setsid when systemd-run fails" {
    use_fake_pm dnf
    ln -s "${BATS_TEST_DIRNAME}/fixtures/fake-systemd-run" "${STUB_BIN}/systemd-run"
    echo 1 > "${FAKE_PM_DIR}/systemd-run.rc"
    fake_pm_reply check-update 0
    fake_pm_reply check-update-security 0

    run agent
    [ "$status" -eq 0 ]
    [ -s "${FAKE_PM_DIR}/systemd-run.args" ]
    wait_for_file "${RESULT_CACHE}"
    run agent
    [ "${lines[2]}" = "0" ]
}

@test "needs-restarting: core packages updated since boot are reported" {
    use_fake_pm dnf
    fake_pm_reply check-update 0
    fake_pm_reply check-update-security 0
    fake_pm_reply needs-restarting 1 'Core libraries or services have been updated since boot-up:
  * glibc
  * systemd

Reboot is required to fully utilize these updates.
More information: https://access.redhat.com/solutions/27943
'
    run_agent_refreshed
    [ "$status" -eq 0 ]
    [ "${lines[7]}" = "yes glibc,systemd" ]
    # Reads the rpm database only: cache-only, every repository disabled
    run cat "${FAKE_PM_DIR}/needs-restarting.args"
    [[ "$output" == *"-C"* && "$output" == *"--disablerepo=*"* && "$output" == *"-r"* ]]
}

@test "needs-restarting: nothing updated since boot is reported as no" {
    use_fake_pm dnf5
    fake_pm_reply check-upgrade 0
    fake_pm_reply check-upgrade-security 0
    fake_pm_reply needs-restarting 0 'No core libraries or services have been updated since boot-up.
Reboot should not be necessary.
'
    run_agent_refreshed
    [ "$status" -eq 0 ]
    [ "${lines[7]}" = "no" ]
}

@test "needs-restarting: a missing plugin is unknown, not a reboot" {
    use_fake_pm dnf
    fake_pm_reply check-update 0
    fake_pm_reply check-update-security 0
    fake_pm_reply needs-restarting 1 'No such command: needs-restarting.
'
    run_agent_refreshed
    [ "$status" -eq 0 ]
    [ "${lines[7]}" = "unknown" ]
}

@test "needs-restarting: a result cache from an older version serves unknown" {
    use_fake_pm dnf
    fake_pm_reply check-update 0
    fake_pm_reply check-update-security 0
    agent --refresh
    printf '0\n0 \n-1\n' > "${RESULT_CACHE}"
    run agent
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 8 ]
    [ "${lines[2]}" = "0" ]
    [ "${lines[7]}" = "unknown" ]
}

@test "The fingerprint includes the boot ID, so a reboot refreshes the hint" {
    [ -r /proc/sys/kernel/random/boot_id ] || skip "No boot ID available"
    use_fake_pm dnf
    fake_pm_reply check-update 0
    fake_pm_reply check-update-security 0
    agent --refresh
    grep -qx "boot_id $(cat /proc/sys/kernel/random/boot_id)" "${MK_VARDIR}/cache/dnf_pkg_state.cache"
}

@test "The package manager always runs in the C locale" {
    use_fake_pm dnf
    fake_pm_reply check-update 0
    fake_pm_reply check-update-security 0
    fake_pm_reply needs-restarting 0 'Reboot should not be necessary.
'
    LANG=de_DE.UTF-8 LC_ALL=de_DE.UTF-8 agent --refresh
    run cat "${FAKE_PM_DIR}"/*.lc_all
    [ "${#lines[@]}" -ge 4 ]
    for line in "${lines[@]}"; do
        [ "$line" = "C" ]
    done
}

@test "The fingerprint covers the package manager configuration" {
    if [[ ! -w /etc/yum.repos.d ]] || ! command -v find &>/dev/null; then
        skip "/etc/yum.repos.d not writable"
    fi
    use_fake_pm dnf
    ln -s "$(command -v find)" "${STUB_BIN}/find"
    fake_pm_reply check-update 0
    fake_pm_reply check-update-security 0
    : > "${TEST_REPO_FILE}"
    agent --refresh
    grep -q "^${TEST_REPO_FILE} " "${MK_VARDIR}/cache/dnf_pkg_state.cache"
}

@test "Legacy 4-line cache files are removed" {
    use_fake_pm dnf
    fake_pm_reply check-update 0
    fake_pm_reply check-update-security 0
    printf 'no\n3\n0 \n-1\n' > "${MK_VARDIR}/cache/yum_result.cache"
    echo 100 > "${MK_VARDIR}/cache/yum_uptime.cache"

    run_agent_refreshed
    [ ! -e "${MK_VARDIR}/cache/yum_result.cache" ]
    [ ! -e "${MK_VARDIR}/cache/yum_uptime.cache" ]
    [ "${lines[2]}" = "0" ]
}

@test "Reboot hint is yes with packages, no or unknown (real package manager)" {
    if ! command -v dnf &>/dev/null && ! command -v yum &>/dev/null; then
        skip "No dnf or yum available"
    fi

    run_agent_refreshed
    [ "$status" -eq 0 ]
    [[ "${lines[7]}" =~ ^(yes\ [^[:space:]]*|no|unknown)$ ]]
}

@test "Metadata refresh line is a timestamp or -1" {
    use_fake_pm dnf
    fake_pm_reply check-update 0
    fake_pm_reply check-update-security 0
    run_agent_refreshed
    [ "$status" -eq 0 ]
    [[ "${lines[5]}" =~ ^(-1|[0-9]+)$ ]]
}

@test "dnf: unsupported --security option reports -2" {
    use_fake_pm dnf
    fake_pm_reply check-update 100 'bash.x86_64    5.1.8-9.el9    baseos
'
    fake_pm_reply check-update-security 2
    run_agent_refreshed
    [ "$status" -eq 0 ]
    [ "${lines[2]}" = "1" ]
    [ "${lines[3]}" = "-2" ]
}

@test "dnf5: last update is the newest Upgrade transaction" {
    use_fake_pm dnf5
    fake_pm_reply check-upgrade 0
    fake_pm_reply check-upgrade-security 0
    fake_pm_reply history-list 0 \
'ID Command line                           Date and time       Action(s) Altered
 3 dnf5 -y install which                  2026-09-27 10:48:33                 1
 2 dnf5 -y upgrade vim-minimal            2026-09-27 10:48:31                 4
 1 dnf5 --config /builddir/result/image/b 2026-04-26 07:47:41               126
'
    fake_pm_reply history-info 0 \
'Transaction ID : 3
Begin time     : 2026-09-27 10:48:33
Packages altered:
  Action  Package                     Reason Repository
  Install which-0:2.23-2.fc42.aarch64 User   updates
Transaction ID : 2
Begin time     : 2026-09-27 10:48:31
Packages altered:
  Action   Package                              Reason     Repository
  Upgrade  vim-minimal-2:9.2.390-1.fc42.aarch64 User       updates
  Replaced vim-minimal-2:9.2.280-1.fc42.aarch64 User       @System
Transaction ID : 1
Begin time     : 2026-04-26 07:47:41
Packages altered:
  Action  Package                  Reason Repository
  Install basesystem-0:11-22.fc42.noarch User  updates
'
    run_agent_refreshed
    [ "$status" -eq 0 ]
    [ "${lines[4]}" = "$(date -d '2026-09-27 10:48:31' +%s)" ]
}

@test "dnf5: the last upgrade is found behind many newer transactions" {
    use_fake_pm dnf5
    fake_pm_reply check-upgrade 0
    fake_pm_reply check-upgrade-security 0
    # 60 transactions, newest first; only the oldest is an upgrade
    local id list='ID Command line                           Date and time       Action(s) Altered'$'\n'
    mkdir "${FAKE_PM_DIR}/history-info.d"
    for (( id = 60; id >= 1; id-- )); do
        list+=" ${id} dnf5 -y install pkg${id}              2026-09-27 10:48:33                 1"$'\n'
        printf 'Transaction ID : %s\nBegin time     : 2026-09-%02d 08:00:00\n  %s pkg%s-0:1-1.fc42.noarch User updates\n' \
            "${id}" "$(( id < 28 ? id : 28 ))" "$( (( id == 1 )) && echo Upgrade || echo Install )" "${id}" \
            > "${FAKE_PM_DIR}/history-info.d/${id}"
    done
    fake_pm_reply history-list 0 "${list}"

    run_agent_refreshed
    [ "$status" -eq 0 ]
    [ "${lines[4]}" = "$(date -d '2026-09-01 08:00:00' +%s)" ]
    # Two batches of history info: 60-11, then 10-1
    [ "$(wc -l < "${FAKE_PM_DIR}/history-info.args")" -eq 2 ]
}

@test "dnf5: history without upgrades yields -1" {
    use_fake_pm dnf5
    fake_pm_reply check-upgrade 0
    fake_pm_reply check-upgrade-security 0
    fake_pm_reply history-list 0 \
'ID Command line                           Date and time       Action(s) Altered
 1 dnf5 -y install which                  2026-09-27 10:48:33                 1
'
    fake_pm_reply history-info 0 \
'Transaction ID : 1
Begin time     : 2026-09-27 10:48:33
  Install which-0:2.23-2.fc42.aarch64 User   updates
'
    run_agent_refreshed
    [ "$status" -eq 0 ]
    [ "${lines[4]}" = "-1" ]
}

# =============================================================================
# Reboot detection (fake rpm and uname)
# =============================================================================

@test "Reboot: running the newest kernel needs no reboot" {
    use_fake_pm dnf
    fake_kernel 5.14.0-503.9.1.el9 5.14.0-427.13.1.el9 5.14.0-503.9.1.el9
    run_agent_refreshed
    [ "${lines[1]}" = "no" ]
}

@test "Reboot: a newer installed kernel needs a reboot" {
    use_fake_pm dnf
    fake_kernel 5.14.0-503.9.1.el9 5.14.0-503.9.1.el9 5.14.0-503.10.1.el9
    run_agent_refreshed
    [ "${lines[1]}" = "yes" ]
}

@test "Reboot: an older kernel installed later needs no reboot" {
    use_fake_pm dnf
    fake_kernel 5.14.0-503.9.1.el9 5.14.0-503.9.1.el9 5.14.0-427.13.1.el9
    run_agent_refreshed
    [ "${lines[1]}" = "no" ]
}

@test "Reboot: only the first package owning the kernel config is used" {
    use_fake_pm dnf
    fake_kernel 5.14.0-503.9.1.el9 5.14.0-503.9.1.el9
    printf 'kernel-core 5.14.0-503.9.1.el9\nkernel-rt-core 5.14.0-503.9.1.el9\n' \
        > "${FAKE_PM_DIR}/config-owners"
    run_agent_refreshed
    [ "${lines[1]}" = "no" ]
}

@test "Reboot: the running kernel's package is found via its vmlinuz" {
    use_fake_pm dnf
    fake_kernel 5.14.0-503.9.1.el9 5.14.0-503.9.1.el9 5.14.0-503.10.1.el9
    echo "/lib/modules/5.14.0-503.9.1.el9.x86_64/vmlinuz" > "${FAKE_PM_DIR}/owned-paths"
    run_agent_refreshed
    [ "${lines[1]}" = "yes" ]
    [ "$(head -n1 "${FAKE_PM_DIR}/rpm-qf.args")" = "/lib/modules/5.14.0-503.9.1.el9.x86_64/vmlinuz" ]
}

@test "Reboot: falls back to the kernel config when vmlinuz is not owned" {
    use_fake_pm dnf
    fake_kernel 5.14.0-503.9.1.el9 5.14.0-503.9.1.el9 5.14.0-503.10.1.el9
    echo "/boot/config-5.14.0-503.9.1.el9.x86_64" > "${FAKE_PM_DIR}/owned-paths"
    run_agent_refreshed
    [ "${lines[1]}" = "yes" ]
}

@test "Reboot: a kernel config owned by no package needs no reboot" {
    use_fake_pm dnf
    fake_kernel 6.1.0-custom 5.14.0-503.9.1.el9
    rm "${FAKE_PM_DIR}/config-owners"
    run_agent_refreshed
    [ "${lines[1]}" = "no" ]
}

# =============================================================================
# Cache file safety
# =============================================================================

@test "A dangling symlink as cache file is refused, not followed" {
    use_fake_pm dnf
    ln -s "${TEST_TEMP_DIR}/planted" "${RESULT_CACHE}"
    run agent
    [ "$status" -eq 0 ]
    [[ "${lines[1]}" == ERROR:*symlink* ]]
    [ ! -e "${TEST_TEMP_DIR}/planted" ]
}

@test "A group- or world-writable cache directory is refused" {
    use_fake_pm dnf
    chmod 777 "${MK_VARDIR}/cache"
    run agent
    [ "$status" -eq 0 ]
    [[ "${lines[1]}" == ERROR:*writable* ]]
    [ ! -e "${RESULT_CACHE}" ]
}

@test "A group- or world-writable MK_VARDIR is refused" {
    use_fake_pm dnf
    chmod 775 "${MK_VARDIR}"
    run agent
    [ "$status" -eq 0 ]
    [[ "${lines[1]}" == ERROR:*MK_VARDIR*writable* ]]
    [ ! -e "${RESULT_CACHE}" ]
}

@test "A missing cache directory is created usable despite umask 002" {
    use_fake_pm dnf
    fake_pm_reply check-update 0
    fake_pm_reply check-update-security 0
    rm -rf "${MK_VARDIR}"
    umask 002
    run agent
    [ "$status" -eq 0 ]
    [[ "${lines[1]}" != ERROR:*writable* ]]
    [ "$(stat -c %a "${MK_VARDIR}")" = "755" ]
    [ "$(stat -c %a "${MK_VARDIR}/cache")" = "755" ]
}

# =============================================================================
# Real package manager (destructive: upgrades a package; opt-in for CI)
# =============================================================================

@test "Last update timestamp is recorded after a real upgrade" {
    if [[ "${DNF_AGENT_TEST_ALLOW_UPGRADE:-}" != "1" ]]; then
        skip "Set DNF_AGENT_TEST_ALLOW_UPGRADE=1 to allow upgrading a package"
    fi

    local pm check pkg
    if command -v dnf5 &>/dev/null; then
        pm=dnf5; check=check-upgrade
    else
        pm=dnf; check=check-update
    fi
    pkg=$(pending_upgrade "$pm" "$check")
    [ -n "$pkg" ] || skip "No pending upgrades to apply"
    "$pm" -y -q upgrade "$pkg"

    run_agent_refreshed
    [ "$status" -eq 0 ]
    [[ "${lines[4]}" =~ ^[0-9]+$ ]]
    (( $(date +%s) - lines[4] < 3600 ))
}

@test "dnf: a version-locked package is not counted (real dnf 4)" {
    if [[ "${DNF_AGENT_TEST_ALLOW_UPGRADE:-}" != "1" ]]; then
        skip "Set DNF_AGENT_TEST_ALLOW_UPGRADE=1 to allow installing the versionlock plugin"
    fi
    if command -v dnf5 &>/dev/null; then
        skip "dnf5 honours versionlock natively"
    fi

    dnf -y -q install python3-dnf-plugin-versionlock
    local pkg before
    pkg=$(pending_upgrade dnf check-update)
    [ -n "$pkg" ] || skip "No pending upgrades to lock"

    run_agent_refreshed
    before="${lines[2]}"
    dnf -q versionlock add "${pkg%.*}"
    run_agent_refreshed
    dnf -q versionlock clear
    [ "${lines[2]}" -eq $(( before - 1 )) ]
}

@test "Metadata refresh time follows makecache (real package manager)" {
    if [[ "${DNF_AGENT_TEST_ALLOW_UPGRADE:-}" != "1" ]]; then
        skip "Set DNF_AGENT_TEST_ALLOW_UPGRADE=1 to allow changing the metadata cache"
    fi
    local pm=dnf
    command -v dnf5 &>/dev/null && pm=dnf5

    find /var/cache/dnf /var/cache/libdnf5 -name '*primary.xml*' -exec touch -d @1000000000 {} + 2>/dev/null || true
    run_agent_refreshed
    [ "${lines[5]}" = "1000000000" ]

    # Re-checking unchanged metadata must count as a refresh
    "$pm" -q makecache --refresh
    run agent
    (( $(date +%s) - lines[5] < 600 ))
}

# =============================================================================
# Function isolation tests (source the script and test functions)
# =============================================================================

@test "detect_package_manager function finds dnf or yum" {
    source "${AGENT_PLUGIN}" || true

    if declare -f detect_package_manager &>/dev/null; then
        if command -v dnf5 &>/dev/null || command -v dnf &>/dev/null || command -v yum &>/dev/null; then
            detect_package_manager
            [[ "$PKG_MGR" =~ ^(dnf5|dnf|yum)$ ]]
        else
            skip "No package manager available"
        fi
    else
        skip "Function not accessible"
    fi
}

# =============================================================================
# ShellCheck compliance (if shellcheck is available)
# =============================================================================

@test "Agent plugin passes shellcheck" {
    if ! command -v shellcheck &>/dev/null; then
        skip "shellcheck not installed"
    fi

    run shellcheck -x "${AGENT_PLUGIN}"
    echo "$output"
    [ "$status" -eq 0 ]
}
