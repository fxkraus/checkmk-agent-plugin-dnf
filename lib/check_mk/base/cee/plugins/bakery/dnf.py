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


def get_dnf_files(conf: Any) -> FileGenerator:
    """Yield the agent plugin file for deployment via the Agent Bakery.

    ``conf["deploy"]`` is the ruleset's cascading choice: ``("interval",
    <seconds>)``, ``("sync", None)`` or ``("nointerval", None)`` (do not deploy).
    """
    match conf.get("deploy"):
        case ("interval", interval):
            yield Plugin(base_os=OS.LINUX, source=Path("dnf"), interval=round(interval))
        case ("sync", _):
            yield Plugin(base_os=OS.LINUX, source=Path("dnf"))


register.bakery_plugin(
    name="dnf",
    files_function=get_dnf_files,
)
