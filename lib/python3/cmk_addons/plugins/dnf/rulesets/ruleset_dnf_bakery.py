#!/usr/bin/env python3
# Copyright 2026, Felix Kraus <16723031+fxkraus@users.noreply.github.com>
# SPDX-License-Identifier: GPL-2.0-only
"""Checkmk 2.5 ruleset for deploying the DNF agent plugin via the Agent Bakery."""

from collections.abc import Mapping

from cmk.rulesets.v1 import Help, Title
from cmk.rulesets.v1.form_specs import (
    CascadingSingleChoice,
    CascadingSingleChoiceElement,
    DictElement,
    Dictionary,
    FixedValue,
    TimeMagnitude,
    TimeSpan,
)
from cmk.rulesets.v1.rule_specs import AgentConfig, Topic


def _migrate_legacy_config(value: object) -> Mapping[str, object]:
    """Migrate old-format config (``{"interval": <int>}``) to the current cascading-choice format."""
    if value is None:
        return {"deploy": "nointerval"}
    if not isinstance(value, Mapping):
        return {"deploy": "nointerval"}
    if "deploy" in value:
        return value  # already migrated
    interval = value.get("interval")
    if interval is not None and interval >= 0:
        return {"deploy": ("interval", float(interval))}
    return {"deploy": ("interval", 3600.0)}


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
                    help_text=Help("Choose whether to deploy the plugin and at what interval it should run."),
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
                            ),
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
