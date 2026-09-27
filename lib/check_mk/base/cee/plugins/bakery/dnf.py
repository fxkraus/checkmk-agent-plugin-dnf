#!/usr/bin/env python3
"""Bakery plugin for deploying the DNF update check agent plugin.

Uses Bakery API v1 — still supported in Checkmk 2.5 (v2 remains unstable;
v1 is not scheduled for removal before 2.7).
"""

from pathlib import Path
from typing import Any

from .bakery_api.v1 import OS, FileGenerator, Plugin, register


def get_dnf_files(conf: Any) -> FileGenerator:
    """Yield the agent plugin file for deployment via the Agent Bakery."""
    deploy = conf.get("deploy")
    if deploy is None:
        return

    # Handle the cascading single-choice structure:
    #   ("interval", <float seconds>)  -> deploy with interval
    #   "nointerval"                    -> do not deploy
    if isinstance(deploy, str) and deploy == "nointerval":
        return
    if isinstance(deploy, tuple):
        choice, value = deploy
        if choice == "nointerval":
            return
        if choice == "interval" and value is not None:
            yield Plugin(
                base_os=OS.LINUX,
                source=Path("dnf"),
                interval=int(value),
            )
            return

    # Fallback: deploy without caching interval
    yield Plugin(
        base_os=OS.LINUX,
        source=Path("dnf"),
    )


register.bakery_plugin(
    name="dnf",
    files_function=get_dnf_files,
)
