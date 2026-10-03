#!/usr/bin/env python3
# Copyright 2026, Felix Kraus <16723031+fxkraus@users.noreply.github.com>
# SPDX-License-Identifier: GPL-2.0-only
"""Checkmk 2.5 ruleset for DNF update check parameters."""

from cmk.rulesets.v1 import Help, Label, Title
from cmk.rulesets.v1.form_specs import (
    BooleanChoice,
    DefaultValue,
    DictElement,
    Dictionary,
    Integer,
    LevelDirection,
    ServiceState,
    SimpleLevels,
    validators,
)
from cmk.rulesets.v1.rule_specs import CheckParameters, HostCondition, Topic


def _parameter_form_dnf() -> Dictionary:
    return Dictionary(
        title=Title("DNF Update Check"),
        help_text=Help("Configure thresholds and states for the DNF update monitoring check."),
        elements={
            "normal": DictElement(
                parameter_form=SimpleLevels(
                    title=Title("Levels for normal updates"),
                    help_text=Help("Set WARN/CRIT thresholds based on the number of pending normal updates."),
                    form_spec_template=Integer(),
                    level_direction=LevelDirection.UPPER,
                    prefill_fixed_levels=DefaultValue(value=(1, 10)),
                ),
                required=False,
            ),
            "security": DictElement(
                parameter_form=SimpleLevels(
                    title=Title("Levels for security updates"),
                    help_text=Help("Set WARN/CRIT thresholds based on the number of pending security updates."),
                    form_spec_template=Integer(),
                    level_direction=LevelDirection.UPPER,
                    prefill_fixed_levels=DefaultValue(value=(1, 1)),
                ),
                required=False,
            ),
            "reboot_req": DictElement(
                parameter_form=ServiceState(
                    title=Title("State when a reboot is required"),
                    prefill=DefaultValue(ServiceState.CRIT),
                ),
                required=False,
            ),
            "reboot_hint": DictElement(
                parameter_form=BooleanChoice(
                    title=Title("Reboot detection beyond the kernel"),
                    label=Label("Also require a reboot when core libraries or services were updated since boot"),
                    help_text=Help(
                        "Besides a newer kernel, use needs-restarting -r (dnf 4 plugins / dnf5) to detect updates of core "
                        "packages such as glibc, systemd or openssl since the last boot. Hosts without it fall back to the "
                        "kernel check."
                    ),
                    prefill=DefaultValue(True),
                ),
                required=False,
            ),
            "last_update_time_diff": DictElement(
                parameter_form=Integer(
                    title=Title("Maximum age of last update"),
                    help_text=Help(
                        "If no update has been applied within this many days and updates are available, the service state changes. "
                        "The same applies if no upgrade transaction is found in the package history at all."
                    ),
                    unit_symbol="days",
                    prefill=DefaultValue(60),
                    custom_validate=(validators.NumberInRange(min_value=1),),
                ),
                required=False,
            ),
            "last_update_state": DictElement(
                parameter_form=ServiceState(
                    title=Title("State when last update is too old"),
                    prefill=DefaultValue(ServiceState.WARN),
                ),
                required=False,
            ),
            "metadata_max_age": DictElement(
                parameter_form=Integer(
                    title=Title("Maximum age of repository metadata"),
                    help_text=Help(
                        "The agent plugin queries the local metadata cache only, which dnf-makecache.timer (dnf 4) or "
                        "dnf5-makecache.timer (dnf5) keeps current. If the newest metadata is older than this, the timer is "
                        "probably not running and pending updates may be missed."
                    ),
                    unit_symbol="days",
                    prefill=DefaultValue(7),
                    custom_validate=(validators.NumberInRange(min_value=1),),
                ),
                required=False,
            ),
            "metadata_age_state": DictElement(
                parameter_form=ServiceState(
                    title=Title("State when repository metadata is too old"),
                    prefill=DefaultValue(ServiceState.WARN),
                ),
                required=False,
            ),
            "refresh_pending_max_age": DictElement(
                parameter_form=Integer(
                    title=Title("Maximum time without a completed background refresh"),
                    help_text=Help(
                        "The agent plugin serves cached counts and recomputes them in the background when the package state "
                        "changes. If no refresh has completed for this long, for example because it keeps timing out or the "
                        "package manager keeps failing, the counts may be outdated."
                    ),
                    unit_symbol="hours",
                    prefill=DefaultValue(2),
                    custom_validate=(validators.NumberInRange(min_value=1),),
                ),
                required=False,
            ),
            "refresh_pending_state": DictElement(
                parameter_form=ServiceState(
                    title=Title("State when no background refresh has completed"),
                    prefill=DefaultValue(ServiceState.WARN),
                ),
                required=False,
            ),
        },
    )


rule_spec_dnf = CheckParameters(
    name="dnf",
    title=Title("DNF Update Check Parameters"),
    topic=Topic.OPERATING_SYSTEM,
    parameter_form=_parameter_form_dnf,
    condition=HostCondition(),
)
