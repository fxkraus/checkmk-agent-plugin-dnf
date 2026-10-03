#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Unit tests for the DNF rulesets (bakery migration and input validation)."""

from collections.abc import Callable, Sequence

import pytest

try:
    from cmk.rulesets.v1.form_specs import CascadingSingleChoice
    from cmk.rulesets.v1.form_specs.validators import ValidationError
    from cmk_addons.plugins.dnf.rulesets.ruleset_dnf_bakery import (
        _migrate_legacy_config,
        _parameter_form_dnf_bakery,
    )
    from cmk_addons.plugins.dnf.rulesets.ruleset_dnf_check_parameters import _parameter_form_dnf
except ImportError:
    pytest.skip("Checkmk libraries not available", allow_module_level=True)


def _validate(validators: Sequence[Callable[[object], object]] | None, value: object) -> None:
    for validator in validators or ():
        validator(value)


MIGRATION_CASES = [
    pytest.param(None, ("nointerval", None), id="none"),
    pytest.param("garbage", ("nointerval", None), id="not-a-mapping"),
    pytest.param({}, ("sync", None), id="legacy-without-interval"),
    pytest.param({"interval": None}, ("sync", None), id="legacy-interval-none"),
    pytest.param({"interval": 0}, ("sync", None), id="legacy-interval-zero"),
    pytest.param({"interval": 30}, ("interval", 60.0), id="legacy-interval-below-minimum"),
    pytest.param({"interval": 7200}, ("interval", 7200.0), id="legacy-interval"),
    pytest.param({"deploy": "nointerval"}, ("nointerval", None), id="broken-earlier-migration"),
    pytest.param({"deploy": ("interval", 900.0)}, ("interval", 900.0), id="migrated-interval"),
    pytest.param({"deploy": ("sync", None)}, ("sync", None), id="migrated-sync"),
    pytest.param({"deploy": ("nointerval", None)}, ("nointerval", None), id="migrated-nointerval"),
]


class TestBakeryMigration:
    @pytest.mark.parametrize(("value", "expected"), MIGRATION_CASES)
    def test_migrate(self, value: object, expected: tuple[str, object]) -> None:
        assert _migrate_legacy_config(value) == {"deploy": expected}

    @pytest.mark.parametrize(("value", "expected"), MIGRATION_CASES)
    def test_migrate_is_idempotent(self, value: object, expected: tuple[str, object]) -> None:
        migrated = _migrate_legacy_config(value)
        assert _migrate_legacy_config(migrated) == migrated

    @pytest.mark.parametrize(("value", "expected"), MIGRATION_CASES)
    def test_migrated_value_is_valid_for_the_form(self, value: object, expected: tuple[str, object]) -> None:
        deploy = _parameter_form_dnf_bakery().elements["deploy"].parameter_form
        assert isinstance(deploy, CascadingSingleChoice)
        elements = {element.name: element.parameter_form for element in deploy.elements}

        name, choice_value = _migrate_legacy_config(value)["deploy"]
        assert name in elements
        _validate(elements[name].custom_validate, choice_value)


class TestValidation:
    def test_interval_below_one_minute_is_rejected(self) -> None:
        deploy = _parameter_form_dnf_bakery().elements["deploy"].parameter_form
        assert isinstance(deploy, CascadingSingleChoice)
        interval = next(element.parameter_form for element in deploy.elements if element.name == "interval")
        with pytest.raises(ValidationError):
            _validate(interval.custom_validate, 59.0)
        _validate(interval.custom_validate, 60.0)

    @pytest.mark.parametrize("days", [0, -1])
    def test_last_update_days_below_one_are_rejected(self, days: int) -> None:
        form = _parameter_form_dnf().elements["last_update_time_diff"].parameter_form
        with pytest.raises(ValidationError):
            _validate(form.custom_validate, days)
        _validate(form.custom_validate, 1)

    @pytest.mark.parametrize("hours", [0, -1])
    def test_refresh_pending_hours_below_one_are_rejected(self, hours: int) -> None:
        form = _parameter_form_dnf().elements["refresh_pending_max_age"].parameter_form
        with pytest.raises(ValidationError):
            _validate(form.custom_validate, hours)
        _validate(form.custom_validate, 1)
