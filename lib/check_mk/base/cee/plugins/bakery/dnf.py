#!/usr/bin/env python3
# Copyright 2026, Felix Kraus <16723031+fxkraus@users.noreply.github.com>
# SPDX-License-Identifier: GPL-2.0-only
"""Bakery plugin for deploying the DNF update check agent plugin.

Uses Bakery API v1 — still supported in Checkmk 2.5 (v2 remains unstable;
v1 is not scheduled for removal before 2.7).
"""

from pathlib import Path
from typing import Any

from .bakery_api.v1 import OS, FileGenerator, Plugin, register

# Same floor as MIN_INTERVAL in the bakery ruleset
MIN_INTERVAL = 60.0


def _deploy_choice(conf: Any) -> object:
    """Return the cascading ``deploy`` choice, also for legacy rule values.

    The ruleset migrates legacy values (``{"interval": <seconds>}``, or ``{}``
    to run without interval) only when the GUI or cmk-update-config rewrites
    the rule, so the bakery may still receive them. They are interpreted the
    same way as the migration does, instead of silently deploying nothing.
    """
    if "deploy" in conf:
        return conf["deploy"]
    interval = conf.get("interval")
    if not isinstance(interval, int | float) or interval <= 0:
        return ("sync", None)
    return ("interval", max(float(interval), MIN_INTERVAL))


def get_dnf_files(conf: Any) -> FileGenerator:
    """Yield the agent plugin file for deployment via the Agent Bakery.

    The ``deploy`` choice is ``("interval", <seconds>)``, ``("sync", None)`` or
    ``("nointerval", None)`` (do not deploy).
    """
    match _deploy_choice(conf):
        case ("interval", interval):
            yield Plugin(base_os=OS.LINUX, source=Path("dnf"), interval=round(interval))
        case ("sync", _):
            yield Plugin(base_os=OS.LINUX, source=Path("dnf"))


register.bakery_plugin(
    name="dnf",
    files_function=get_dnf_files,
)
