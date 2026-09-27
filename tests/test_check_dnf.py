#!/usr/bin/env python3
"""Unit tests for the DNF agent-based check plugin."""

from collections.abc import Mapping
from unittest.mock import patch

import pytest

# Import the check plugin module
# When running inside Checkmk, these would be available; for standalone testing we mock them
try:
    from cmk.agent_based.v2 import Metric, Result, State
    from cmk_addons.plugins.dnf.agent_based.dnf import (
        DnfSection,
        check_dnf,
        discover_dnf,
        parse_dnf,
    )
except ImportError:
    # For standalone testing without Checkmk installed
    pytest.skip("Checkmk libraries not available", allow_module_level=True)


# =============================================================================
# Test Data Fixtures
# =============================================================================


@pytest.fixture
def default_params() -> Mapping[str, object]:
    """Default check parameters."""
    return {
        "normal": ("fixed", (1, 10)),
        "security": ("fixed", (1, 1)),
        "last_update_time_diff": 60,
        "last_update_state": 1,
        "reboot_req": 2,
    }


# =============================================================================
# Parse Function Tests
# =============================================================================


class TestParseDnf:
    """Tests for the parse_dnf function."""

    def test_parse_empty_output(self):
        """Empty agent output should return an error section."""
        result = parse_dnf([])
        assert result.error_message == "Empty agent output"

    def test_parse_error_message(self):
        """Agent error messages should be captured."""
        result = parse_dnf([["ERROR:", "MK_VARDIR", "not", "set"]])
        assert result.error_message == "MK_VARDIR not set"

    def test_parse_normal_output(self):
        """Standard agent output should be parsed correctly."""
        string_table = [
            ["no"],
            ["5"],
            ["2", "kernel,glibc"],
            ["1700000000"],
        ]
        result = parse_dnf(string_table)

        assert result.reboot_required is False
        assert result.packages == 5
        assert result.security_packages == 2
        assert result.security_packages_list == "kernel,glibc"
        assert result.last_update_timestamp == 1700000000
        assert result.error_message is None

    def test_parse_reboot_required(self):
        """Reboot required flag should be detected."""
        string_table = [
            ["yes"],
            ["12"],
            ["1"],
            ["1700000000"],
        ]
        result = parse_dnf(string_table)
        assert result.reboot_required is True

    def test_parse_security_unsupported(self):
        """Security updates unsupported (-2) should be handled."""
        string_table = [
            ["no"],
            ["3"],
            ["-2"],
            ["1700000000"],
        ]
        result = parse_dnf(string_table)
        assert result.security_packages == -2

    def test_parse_security_failed(self):
        """Security check failure (-1) should be handled."""
        string_table = [
            ["no"],
            ["3"],
            ["-1"],
            ["1700000000"],
        ]
        result = parse_dnf(string_table)
        assert result.security_packages == -1

    def test_parse_no_timestamp(self):
        """Missing timestamp (-1) should be handled."""
        string_table = [
            ["no"],
            ["0"],
            ["0"],
            ["-1"],
        ]
        result = parse_dnf(string_table)
        assert result.last_update_timestamp == -1

    def test_parse_malformed_numbers(self):
        """Malformed numeric values should default gracefully."""
        string_table = [
            ["no"],
            ["not_a_number"],
            ["also_bad"],
            ["invalid"],
        ]
        result = parse_dnf(string_table)
        assert result.packages == -1
        assert result.security_packages == -1
        assert result.last_update_timestamp == -1


# =============================================================================
# Discovery Tests
# =============================================================================


class TestDiscoverDnf:
    """Tests for the discover_dnf function."""

    def test_discover_creates_service(self):
        """Discovery should yield exactly one service."""
        section = DnfSection()
        services = list(discover_dnf(section))
        assert len(services) == 1


# =============================================================================
# Check Function Tests
# =============================================================================


class TestCheckDnf:
    """Tests for the check_dnf function."""

    def test_check_error_state(self, default_params):
        """Error messages should result in UNKNOWN state."""
        section = DnfSection(error_message="Test error")
        results = list(check_dnf(default_params, section))

        assert len(results) == 1
        assert results[0].state.value == 3  # UNKNOWN
        assert "Test error" in results[0].summary

    def test_check_no_packages_info(self, default_params):
        """Missing package info should result in UNKNOWN state."""
        section = DnfSection(packages=-1)
        results = list(check_dnf(default_params, section))

        assert any(r.state.value == 3 for r in results if hasattr(r, "state"))

    def test_check_all_up_to_date(self, default_params):
        """No pending updates should result in OK state."""
        section = DnfSection(
            reboot_required=False,
            packages=0,
            security_packages=0,
            last_update_timestamp=2000000000,  # Recent
        )
        results = list(check_dnf(default_params, section))

        # Should have OK summary for up-to-date
        summaries = [r.summary for r in results if hasattr(r, "summary")]
        assert any("up to date" in s for s in summaries)

    def test_check_normal_updates_warn(self, default_params):
        """Normal updates at warn threshold should result in WARN."""
        section = DnfSection(
            reboot_required=False,
            packages=5,  # Above warn (1), below crit (10)
            security_packages=0,
            last_update_timestamp=2000000000,
        )
        results = list(check_dnf(default_params, section))

        # Should have at least one WARN
        states = [r.state.value for r in results if hasattr(r, "state")]
        assert 1 in states  # WARN

    def test_check_normal_updates_crit(self, default_params):
        """Normal updates at crit threshold should result in CRIT."""
        section = DnfSection(
            reboot_required=False,
            packages=15,  # Above crit (10)
            security_packages=0,
            last_update_timestamp=2000000000,
        )
        results = list(check_dnf(default_params, section))

        states = [r.state.value for r in results if hasattr(r, "state")]
        assert 2 in states  # CRIT

    def test_check_security_updates_crit(self, default_params):
        """Security updates should trigger CRIT with default params."""
        section = DnfSection(
            reboot_required=False,
            packages=1,
            security_packages=1,  # At crit threshold (1, 1)
            last_update_timestamp=2000000000,
        )
        results = list(check_dnf(default_params, section))

        states = [r.state.value for r in results if hasattr(r, "state")]
        assert 2 in states  # CRIT

    def test_check_reboot_required(self, default_params):
        """Reboot required should trigger configured state."""
        section = DnfSection(
            reboot_required=True,
            packages=0,
            security_packages=0,
            last_update_timestamp=2000000000,
        )
        results = list(check_dnf(default_params, section))

        # Should have "Reboot required" result
        summaries = [r.summary for r in results if hasattr(r, "summary")]
        assert any("Reboot required" in s for s in summaries)

        # Should be CRIT (reboot_req=2)
        states = [r.state.value for r in results if hasattr(r, "state")]
        assert 2 in states

    def test_check_security_list_in_notice(self, default_params):
        """Security package list should appear in notice."""
        section = DnfSection(
            reboot_required=False,
            packages=2,
            security_packages=2,
            security_packages_list="kernel,openssl",
            last_update_timestamp=2000000000,
        )
        results = list(check_dnf(default_params, section))

        # The security package list is emitted as a notice; the agent-based API
        # stores notice text in the result's details field (not a .notice attr).
        details = [r.details for r in results if hasattr(r, "details") and r.details]
        assert any("kernel,openssl" in d for d in details)

    @pytest.mark.parametrize("security_packages", [0, -1, -2])
    def test_check_security_metric_emitted_at_most_once(self, default_params, security_packages):
        """The security_updates metric must not be duplicated in any state."""
        section = DnfSection(
            reboot_required=False,
            packages=0,
            security_packages=security_packages,
            last_update_timestamp=2000000000,
        )
        results = list(check_dnf(default_params, section))

        names = [r.name for r in results if isinstance(r, Metric)]
        assert names.count("security_updates") <= 1
        assert names.count("normal_updates") == 1

    def test_check_security_check_failed_is_unknown(self, default_params):
        """A failed security query must not look healthy."""
        section = DnfSection(
            reboot_required=False,
            packages=0,
            security_packages=-1,
            last_update_timestamp=2000000000,
        )
        results = list(check_dnf(default_params, section))

        assert any(isinstance(r, Result) and r.state == State.UNKNOWN and "Security update check failed" in r.summary for r in results)


# =============================================================================
# Integration-style Tests (with mocked time)
# =============================================================================


class TestCheckDnfWithMockedTime:
    """Tests that require mocking time.time()."""

    @patch("cmk_addons.plugins.dnf.agent_based.dnf.time")
    def test_check_last_update_recent(self, mock_time, default_params):
        """Recent last update should be OK."""
        mock_time.return_value = 1700100000  # ~1 day after last update

        section = DnfSection(
            reboot_required=False,
            packages=0,
            security_packages=0,
            last_update_timestamp=1700000000,
        )
        results = list(check_dnf(default_params, section))

        # Should not have warning about last update
        assert not any("too long ago" in getattr(r, "summary", "") for r in results if hasattr(r, "summary"))

    @patch("cmk_addons.plugins.dnf.agent_based.dnf.time")
    def test_check_last_update_old(self, mock_time, default_params):
        """Old last update with pending updates should warn."""
        mock_time.return_value = 1710000000  # ~115 days after last update

        section = DnfSection(
            reboot_required=False,
            packages=5,  # Updates available
            security_packages=0,
            last_update_timestamp=1700000000,
        )
        results = list(check_dnf(default_params, section))

        summaries = [r.summary for r in results if hasattr(r, "summary")]
        assert any("too long ago" in s for s in summaries)
