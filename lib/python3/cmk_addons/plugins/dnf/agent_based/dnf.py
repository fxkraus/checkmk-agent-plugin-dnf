#!/usr/bin/env python3
"""Checkmk 2.5 agent-based check plugin for DNF package updates.

Monitors pending normal and security updates on RPM-based Linux distributions.
Supports Red Hat Enterprise Linux 8-10 and compatible derivatives.

Example agent output:

    <<<dnf>>>
    yes
    32
    4 kernel,glibc,openssl
    1626252300
    1626338700
    -1
    yes glibc,systemd

The last three lines (newest repository metadata refresh, start of the oldest
unfinished background refresh, needs-restarting reboot hint) are missing from
older agent plugins.
"""
#
# Copyright 2015, Henri Wahl <h.wahl@ifw-dresden.de>
# Copyright 2018, Moritz Schlarb <schlarbm@uni-mainz.de>
# Copyright 2021, Marco Lenhardt <marco.lenhardt@ontec.at>
# Copyright 2021, Henrik Giessel <henrik.giessel@yahoo.de>
# Copyright 2023, Timo Klecker <klecker@decoit.de>
# Copyright 2026, Felix Kraus <16723031+fxkraus@users.noreply.github.com>
#
# SPDX-License-Identifier: GPL-2.0-only

import contextlib
from collections.abc import Sequence
from time import time
from typing import NamedTuple, TypedDict

from cmk.agent_based.v2 import (
    AgentSection,
    CheckPlugin,
    CheckResult,
    DiscoveryResult,
    LevelsT,
    Metric,
    Result,
    Service,
    State,
    check_levels,
    render,
)


class DnfParams(TypedDict, total=False):
    """Check parameters (ruleset "dnf"); states are 0-3 (OK, WARN, CRIT, UNKNOWN)."""

    normal: LevelsT[int]
    security: LevelsT[int]
    reboot_req: int
    reboot_hint: bool
    last_update_time_diff: int
    last_update_state: int
    metadata_max_age: int
    metadata_age_state: int
    refresh_pending_max_age: int
    refresh_pending_state: int


class DnfSection(NamedTuple):
    """Parsed section data from the dnf agent plugin."""

    reboot_required: bool | None = None
    packages: int = -1
    security_packages: int = -1
    security_packages_list: str | None = None
    last_update_timestamp: int = -1
    metadata_timestamp: int = -1
    refresh_pending_since: int = -1
    reboot_hint: bool | None = None
    reboot_hint_packages: str | None = None
    error_message: str | None = None


# ---------------------------------------------------------------------------
# Parse function
# ---------------------------------------------------------------------------


def parse_dnf(string_table: Sequence[Sequence[str]]) -> DnfSection:
    """Parse the ``<<<dnf>>>`` agent section into a *DnfSection*."""
    if not string_table:
        return DnfSection(error_message="Empty agent output")

    if string_table[0][0] == "ERROR:":
        return DnfSection(error_message=" ".join(string_table[0][1:]))

    reboot_required: bool | None = None
    if string_table[0][0] in ("yes", "no"):
        reboot_required = string_table[0][0] == "yes"

    packages = -1
    security_packages = -1
    security_packages_list: str | None = None
    last_update_timestamp = -1
    metadata_timestamp = -1
    refresh_pending_since = -1
    reboot_hint: bool | None = None
    reboot_hint_packages: str | None = None

    with contextlib.suppress(IndexError, ValueError):
        packages = int(string_table[1][0])

    try:
        security_packages = int(string_table[2][0])
        if len(string_table[2]) > 1:
            security_packages_list = string_table[2][1]
    except (IndexError, ValueError):
        pass

    with contextlib.suppress(IndexError, ValueError):
        last_update_timestamp = int(string_table[3][0])

    with contextlib.suppress(IndexError, ValueError):
        metadata_timestamp = int(string_table[4][0])

    with contextlib.suppress(IndexError, ValueError):
        refresh_pending_since = int(string_table[5][0])

    if len(string_table) > 6 and string_table[6][0] in ("yes", "no"):
        reboot_hint = string_table[6][0] == "yes"
        if reboot_hint and len(string_table[6]) > 1:
            reboot_hint_packages = string_table[6][1]

    return DnfSection(
        reboot_required=reboot_required,
        packages=packages,
        security_packages=security_packages,
        security_packages_list=security_packages_list,
        last_update_timestamp=last_update_timestamp,
        metadata_timestamp=metadata_timestamp,
        refresh_pending_since=refresh_pending_since,
        reboot_hint=reboot_hint,
        reboot_hint_packages=reboot_hint_packages,
    )


# ---------------------------------------------------------------------------
# Agent section registration
# ---------------------------------------------------------------------------

agent_section_dnf = AgentSection(
    name="dnf",
    parse_function=parse_dnf,
)


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------


def discover_dnf(section: DnfSection) -> DiscoveryResult:
    """Discover one service if the dnf section is present."""
    yield Service()


# ---------------------------------------------------------------------------
# Check function
# ---------------------------------------------------------------------------


def _check_updates(params: DnfParams, section: DnfSection) -> CheckResult:
    # -1 (security query failed) must not read as "up to date"; -2 (not
    # supported) carries no information about pending updates.
    if section.packages == 0 and section.security_packages in (0, -2):
        yield Result(state=State.OK, summary="All packages are up to date")
        yield Metric(name="normal_updates", value=0)
        if section.security_packages == 0:
            yield Metric(name="security_updates", value=0)
    else:
        yield from check_levels(
            section.packages,
            levels_upper=params.get("normal", ("fixed", (1, 10))),
            metric_name="normal_updates",
            label="Normal updates",
            render_func=lambda v: str(int(v)),
        )

        if section.security_packages >= 0:
            yield from check_levels(
                section.security_packages,
                levels_upper=params.get("security", ("fixed", (1, 1))),
                metric_name="security_updates",
                label="Security updates",
                render_func=lambda v: str(int(v)),
            )
            if section.security_packages_list and section.security_packages > 0:
                yield Result(
                    state=State.OK,
                    notice=f"Security packages: {section.security_packages_list}",
                )

    # No security_updates metric for -2: a 0 would read as "none pending".
    if section.security_packages == -2:
        yield Result(state=State.OK, notice="Security update check not available")
    elif section.security_packages == -1:
        yield Result(state=State.UNKNOWN, summary="Security update check failed")


def _check_last_update(params: DnfParams, section: DnfSection) -> CheckResult:
    """A missing or old last upgrade only matters while updates are pending."""
    if section.last_update_timestamp < 0:
        if section.packages == 0:
            yield Result(state=State.OK, notice="No upgrade transaction found")
        else:
            yield Result(state=State(int(params.get("last_update_state", 1))), summary="No upgrade transaction found")
        return

    last_update = render.datetime(section.last_update_timestamp)
    threshold_days = int(params.get("last_update_time_diff", 60))
    if time() - section.last_update_timestamp < threshold_days * 86400:
        yield Result(state=State.OK, summary=f"Last update: {last_update}")
    elif section.packages == 0:
        yield Result(state=State.OK, notice=f"Last update was {last_update}, but no updates available")
    else:
        yield Result(state=State(int(params.get("last_update_state", 1))), summary=f"Last update too long ago: {last_update}")


def _check_metadata_age(params: DnfParams, section: DnfSection) -> CheckResult:
    """Package queries are cache-only, so stale metadata hides pending updates."""
    if section.metadata_timestamp < 0:
        return

    age = max(time() - section.metadata_timestamp, 0)
    max_age_days = int(params.get("metadata_max_age", 7))
    if age < max_age_days * 86400:
        yield Result(state=State.OK, notice=f"Repository metadata age: {render.timespan(age)}")
    else:
        yield Result(
            state=State(int(params.get("metadata_age_state", 1))),
            summary=(f"Repository metadata age: {render.timespan(age)} (more than {max_age_days} days, is the dnf-makecache/dnf5-makecache timer running?)"),
        )


def _check_refresh_pending(params: DnfParams, section: DnfSection) -> CheckResult:
    """The counts are cached; a refresh that never completes would freeze them."""
    if section.refresh_pending_since < 0:
        return

    age = max(time() - section.refresh_pending_since, 0)
    if age >= int(params.get("refresh_pending_max_age", 2)) * 3600:
        yield Result(
            state=State(int(params.get("refresh_pending_state", 1))),
            summary=f"Update information may be outdated: no background refresh has completed for {render.timespan(age)}",
        )


def _check_reboot(params: DnfParams, section: DnfSection) -> CheckResult:
    """A newer kernel, or core libraries and services updated since boot (needs-restarting)."""
    state = State(int(params.get("reboot_req", 2)))
    if section.reboot_required:
        yield Result(state=state, summary="Reboot required", details="Reboot required: a newer kernel is installed")
    elif section.reboot_hint and params.get("reboot_hint", True):
        updated = section.reboot_hint_packages.replace(",", ", ") if section.reboot_hint_packages else "unknown packages"
        yield Result(state=state, summary="Reboot required", details=f"Reboot required: updated since boot: {updated}")


def check_dnf(params: DnfParams, section: DnfSection) -> CheckResult:
    """Evaluate available DNF updates against configurable thresholds."""
    if section.error_message:
        yield Result(state=State.UNKNOWN, summary=section.error_message)
        return

    if section.packages < 0:
        yield Result(
            state=State.UNKNOWN,
            summary="No package information available: the cache-only package query failed",
            details=(
                "No package information available: the cache-only package query failed. Usually the repository metadata "
                "cache is missing; check that the dnf-makecache/dnf5-makecache timer is running, or run 'dnf makecache' "
                "on the host. A package manager lock or a broken repository configuration can also cause this."
            ),
        )
    else:
        yield from _check_updates(params, section)
        yield from _check_last_update(params, section)

    # Independent of the package counts: still valid when the query failed
    yield from _check_metadata_age(params, section)
    yield from _check_refresh_pending(params, section)

    yield from _check_reboot(params, section)


# ---------------------------------------------------------------------------
# Check plugin registration
# ---------------------------------------------------------------------------

check_plugin_dnf = CheckPlugin(
    name="dnf",
    service_name="DNF Updates",
    discovery_function=discover_dnf,
    check_function=check_dnf,
    check_default_parameters={
        "normal": ("fixed", (1, 10)),
        "security": ("fixed", (1, 1)),
        "last_update_time_diff": 60,
        "last_update_state": 1,  # WARN
        "metadata_max_age": 7,
        "metadata_age_state": 1,  # WARN
        "refresh_pending_max_age": 2,
        "refresh_pending_state": 1,  # WARN
        "reboot_req": 2,  # CRIT
        "reboot_hint": True,
    },
    check_ruleset_name="dnf",
)
