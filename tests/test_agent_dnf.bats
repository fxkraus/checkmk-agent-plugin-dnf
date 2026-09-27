#!/usr/bin/env bats
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

    # Path to the agent plugin
    AGENT_PLUGIN="${BATS_TEST_DIRNAME}/../agents/plugins/dnf"
    RESULT_CACHE="${MK_VARDIR}/cache/dnf_updates.cache"
    STUB_BIN=""
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
    for tool in bash awk cat cut date flock grep head ls mkdir mv paste rm sed setsid sort timeout uname; do
        ln -s "$(command -v "$tool")" "${STUB_BIN}/${tool}"
    done
    ln -s "${BATS_TEST_DIRNAME}/fixtures/fake-pm" "${STUB_BIN}/$1"
}

# fake_pm_reply <key> <exit code> [output]
fake_pm_reply() {
    printf '%s' "${3:-}" > "${FAKE_PM_DIR}/$1.out"
    echo "$2" > "${FAKE_PM_DIR}/$1.rc"
}

teardown() {
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

    # Section header + 4 data lines
    [ "${#lines[@]}" -eq 5 ]
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
# Output lines: [0] header, [1] reboot, [2] updates, [3] security, [4] timestamp
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

@test "Failed query is served as -1 and retried on the next run" {
    use_fake_pm dnf5
    fake_pm_reply check-upgrade 1
    fake_pm_reply check-upgrade-security 1
    run_agent_refreshed
    [ "$status" -eq 0 ]
    [ "${lines[2]}" = "-1" ]
    [ "${lines[3]}" = "-1" ]
    # The fingerprint isn't stored, so the next agent run starts a new refresh
    [ ! -s "${MK_VARDIR}/cache/dnf_pkg_state.cache" ]

    # That already happened during the run above; let it finish first.
    wait_for_refresh
    fake_pm_reply check-upgrade 100 'bash.x86_64    5.2.37-1.fc42  updates
'
    fake_pm_reply check-upgrade-security 0
    run agent
    for (( i = 0; i < 50; i++ )); do
        grep -qx 1 "${RESULT_CACHE}" && break
        sleep 0.2
    done
    run agent
    [ "${lines[2]}" = "1" ]
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
    [ "${#lines[@]}" -eq 5 ]
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
    [ "${#lines[@]}" -eq 5 ]
    [ "${lines[2]}" = "0" ]
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
    pkg=$("$pm" -q "$check" | awk '/^[^[:space:]]/ {print $1; exit}') || true
    [ -n "$pkg" ] || skip "No pending upgrades to apply"
    "$pm" -y -q upgrade "$pkg"

    run_agent_refreshed
    [ "$status" -eq 0 ]
    [[ "${lines[4]}" =~ ^[0-9]+$ ]]
    (( $(date +%s) - lines[4] < 3600 ))
}

# =============================================================================
# Function isolation tests (source the script and test functions)
# =============================================================================

@test "detect_distribution function works" {
    # Source the script to get access to functions
    source "${AGENT_PLUGIN}" || true

    # The function should set MAJOR_VERSION and DISTRO_ID
    if declare -f detect_distribution &>/dev/null; then
        detect_distribution
        [ -n "$MAJOR_VERSION" ]
        [ -n "$DISTRO_ID" ]
    else
        skip "Function not accessible (script may have changed structure)"
    fi
}

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
