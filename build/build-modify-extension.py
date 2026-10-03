#!/usr/bin/env python3
# Copyright 2026, Felix Kraus <16723031+fxkraus@users.noreply.github.com>
# SPDX-License-Identifier: GPL-2.0-only
"""Modify the MKP extension manifest with version and metadata."""

import ast
import sys
from pathlib import Path
from pprint import pformat

CMK_AGENT_PATH = Path("/omd/sites/cmk/local/share/check_mk/agents/plugins/dnf")
VERSION_PLACEHOLDER = 'CMK_VERSION="0.0.0"'

PACKAGE_METADATA = {
    "author": "Felix Kraus (based on the original plugin by Henri Wahl)",
    "description": (
        "Checks for available package updates on RPM-based distributions "
        "(RHEL 8-10, AlmaLinux, Rocky Linux, Oracle Linux, CentOS Stream) "
        "via dnf5, dnf, or yum."
    ),
    "download_url": "https://github.com/fxkraus/checkmk-agent-plugin-dnf/releases",
    "title": "DNF Update Check",
    "version.min_required": "2.5.0",
}


def update_manifest(manifest_path: Path, version: str) -> None:
    """Read the MKP manifest, inject metadata, and write it back."""
    # ast.literal_eval is safe — it only evaluates literal expressions.
    package_config = ast.literal_eval(manifest_path.read_text())

    package_config.update(PACKAGE_METADATA)
    package_config["version"] = version

    manifest_path.write_text(pformat(package_config, indent=4) + "\n")
    print(f"Manifest updated: version={version}")


def stamp_agent_version(version: str) -> None:
    """Replace the placeholder version in the deployed agent plugin.

    Exits if the plugin or the placeholder is missing, so the MKP never
    silently ships an agent plugin that reports version 0.0.0.
    """
    if not CMK_AGENT_PATH.is_file():
        print(f"ERROR: Agent plugin not found at {CMK_AGENT_PATH}")
        sys.exit(1)

    content = CMK_AGENT_PATH.read_text()
    if VERSION_PLACEHOLDER not in content:
        print(f"ERROR: {VERSION_PLACEHOLDER} not found in {CMK_AGENT_PATH}")
        sys.exit(1)

    CMK_AGENT_PATH.write_text(
        content.replace(VERSION_PLACEHOLDER, f'CMK_VERSION="{version}"')
    )
    print(f"Agent plugin stamped with version {version}")


def main() -> None:
    if len(sys.argv) < 3:
        print("Usage: build-modify-extension.py <version> <manifest-path>")
        sys.exit(1)

    version = sys.argv[1]
    manifest_path = Path(sys.argv[2])

    if not manifest_path.is_file():
        print(f"ERROR: Manifest file not found: {manifest_path}")
        sys.exit(1)

    update_manifest(manifest_path, version)
    stamp_agent_version(version)


if __name__ == "__main__":
    main()
