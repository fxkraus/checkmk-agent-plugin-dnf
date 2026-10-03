#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Unit tests for the DNF bakery plugin."""

import importlib.util
from pathlib import Path
from types import ModuleType

import pytest

try:
    from cmk.base.cee.plugins.bakery.bakery_api.v1 import OS, Plugin
except ImportError:
    pytest.skip("Checkmk libraries not available", allow_module_level=True)

BAKERY_PLUGIN = Path(__file__).parents[1] / "lib/check_mk/base/cee/plugins/bakery/dnf.py"


@pytest.fixture(scope="module")
def bakery() -> ModuleType:
    """Load the bakery plugin as part of the package its relative import expects."""
    spec = importlib.util.spec_from_file_location("cmk.base.cee.plugins.bakery.dnf", BAKERY_PLUGIN)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.mark.parametrize(
    ("conf", "expected"),
    [
        pytest.param({"deploy": ("interval", 3600.0)}, [Plugin(base_os=OS.LINUX, source=Path("dnf"), interval=3600)], id="interval"),
        pytest.param({"deploy": ("interval", 899.6)}, [Plugin(base_os=OS.LINUX, source=Path("dnf"), interval=900)], id="interval-rounded"),
        pytest.param({"deploy": ("sync", None)}, [Plugin(base_os=OS.LINUX, source=Path("dnf"))], id="sync"),
        pytest.param({"deploy": ("nointerval", None)}, [], id="do-not-deploy"),
        pytest.param({"deploy": "nointerval"}, [], id="broken-earlier-migration"),
        pytest.param({}, [Plugin(base_os=OS.LINUX, source=Path("dnf"))], id="legacy-without-interval"),
        pytest.param({"interval": 0}, [Plugin(base_os=OS.LINUX, source=Path("dnf"))], id="legacy-interval-zero"),
        pytest.param({"interval": 7200}, [Plugin(base_os=OS.LINUX, source=Path("dnf"), interval=7200)], id="legacy-interval"),
        pytest.param({"interval": 30}, [Plugin(base_os=OS.LINUX, source=Path("dnf"), interval=60)], id="legacy-interval-below-minimum"),
    ],
)
def test_get_dnf_files(bakery: ModuleType, conf: dict[str, object], expected: list[Plugin]) -> None:
    assert list(bakery.get_dnf_files(conf)) == expected


@pytest.mark.parametrize(
    "legacy",
    [{}, {"interval": None}, {"interval": 0}, {"interval": 30}, {"interval": 7200}, {"deploy": "nointerval"}],
)
def test_legacy_values_bake_like_their_migration(bakery: ModuleType, legacy: dict[str, object]) -> None:
    """Unmigrated rule values must deploy exactly what the ruleset migration turns them into."""
    from cmk_addons.plugins.dnf.rulesets.ruleset_dnf_bakery import _migrate_legacy_config

    assert list(bakery.get_dnf_files(legacy)) == list(bakery.get_dnf_files(_migrate_legacy_config(legacy)))
