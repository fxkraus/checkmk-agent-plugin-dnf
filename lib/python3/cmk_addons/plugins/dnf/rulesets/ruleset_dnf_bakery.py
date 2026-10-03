#!/usr/bin/env python3
# Copyright 2026, Felix Kraus <16723031+fxkraus@users.noreply.github.com>
# SPDX-License-Identifier: GPL-2.0-only
"""Checkmk 2.5 ruleset for deploying the DNF agent plugin via the Agent Bakery."""

from collections.abc import Mapping

from cmk.rulesets.v1 import Help, Title
from cmk.rulesets.v1.form_specs import (
    CascadingSingleChoice,
    CascadingSingleChoiceElement,
    DefaultValue,
    DictElement,
    Dictionary,
    FixedValue,
    TimeMagnitude,
    TimeSpan,
    validators,
)
from cmk.rulesets.v1.rule_specs import AgentConfig, Topic

MIN_INTERVAL = 60.0


def _migrate_legacy_config(value: object) -> Mapping[str, object]:
    """Migrate legacy rule values to the cascading ``deploy`` choice.

    Legacy rules were ``{"interval": <seconds>}`` or ``{}`` (no interval, run
    synchronously). Earlier versions of this migration stored the invalid
    plain string ``"nointerval"``.
    """
    if not isinstance(value, Mapping):
        return {"deploy": ("nointerval", None)}
    if "deploy" in value:
        if value["deploy"] == "nointerval":
            return {"deploy": ("nointerval", None)}
        return value
    interval = value.get("interval")
    if interval is None or interval <= 0:
        return {"deploy": ("sync", None)}
    return {"deploy": ("interval", max(float(interval), MIN_INTERVAL))}


def _parameter_form_dnf_bakery() -> Dictionary:
    return Dictionary(
        migrate=_migrate_legacy_config,
        title=Title("Deploy the DNF update check plugin"),
        help_text=Help("Deploy the DNF agent plugin to RPM-based Linux hosts. The plugin monitors pending normal and security updates."),
        elements={
            "deploy": DictElement(
                required=True,
                parameter_form=CascadingSingleChoice(
                    title=Title("Deployment options"),
                    help_text=Help(
                        "Choose whether to deploy the plugin and how it runs. With an interval, the agent runs the plugin "
                        "asynchronously and caches its output. Without an interval, the plugin runs on every agent call."
                    ),
                    elements=[
                        CascadingSingleChoiceElement(
                            name="interval",
                            title=Title("Deploy with execution interval"),
                            parameter_form=TimeSpan(
                                title=Title("Execution interval"),
                                help_text=Help("How often the plugin runs on the monitored host."),
                                displayed_magnitudes=[
                                    TimeMagnitude.SECOND,
                                    TimeMagnitude.MINUTE,
                                    TimeMagnitude.HOUR,
                                    TimeMagnitude.DAY,
                                ],
                                prefill=DefaultValue(3600.0),
                                custom_validate=(validators.NumberInRange(min_value=MIN_INTERVAL),),
                            ),
                        ),
                        CascadingSingleChoiceElement(
                            name="sync",
                            title=Title("Deploy without interval (run on every agent call)"),
                            parameter_form=FixedValue(value=None),
                        ),
                        CascadingSingleChoiceElement(
                            name="nointerval",
                            title=Title("Do not deploy the plugin"),
                            parameter_form=FixedValue(value=None),
                        ),
                    ],
                ),
            ),
        },
    )


rule_spec_dnf_bakery = AgentConfig(
    title=Title("DNF update check plugin"),
    name="dnf",
    parameter_form=_parameter_form_dnf_bakery,
    topic=Topic.APPLICATIONS,
    help_text=Help("Deploy the DNF agent plugin for monitoring pending package updates on RPM-based Linux hosts."),
)
