#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
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
        "metadata_max_age": 7,
        "metadata_age_state": 1,
        "refresh_pending_max_age": 2,
        "refresh_pending_state": 1,
        "reboot_req": 2,
        "reboot_hint": True,
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

    def test_parse_metadata_timestamp(self):
        """Line 5 carries the newest repository metadata refresh."""
        result = parse_dnf([["no"], ["0"], ["0"], ["1700000000"], ["1700050000"]])
        assert result.metadata_timestamp == 1700050000

    def test_parse_without_metadata_line(self):
        """Output of older agent plugins (4 data lines) still parses."""
        result = parse_dnf([["no"], ["3"], ["1", "openssl"], ["1700000000"]])
        assert result.packages == 3
        assert result.last_update_timestamp == 1700000000
        assert result.metadata_timestamp == -1

    def test_parse_refresh_pending_since(self):
        """Line 6 carries the start of the oldest unfinished background refresh."""
        result = parse_dnf([["no"], ["0"], ["0"], ["1700000000"], ["1700050000"], ["1700060000"]])
        assert result.refresh_pending_since == 1700060000

    def test_parse_without_refresh_pending_line(self):
        """Output of older agent plugins (5 data lines) still parses."""
        result = parse_dnf([["no"], ["0"], ["0"], ["1700000000"], ["1700050000"]])
        assert result.refresh_pending_since == -1

    def test_parse_reboot_hint(self):
        """Line 7 carries the needs-restarting reboot hint."""
        rows = [["no"], ["0"], ["0"], ["1700000000"], ["1700050000"], ["-1"]]

        def hint(string_table):
            section = parse_dnf(string_table)
            return section.reboot_hint, section.reboot_hint_packages

        assert hint([*rows, ["yes", "glibc,systemd"]]) == (True, "glibc,systemd")
        assert hint([*rows, ["no"]]) == (False, None)
        assert hint([*rows, ["unknown"]]) == (None, None)
        assert hint(rows) == (None, None)

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

    def test_check_no_packages_info_points_at_makecache(self, default_params):
        """A failed cache-only query should hint at the missing metadata cache."""
        results = list(check_dnf(default_params, DnfSection(packages=-1)))

        assert any(isinstance(r, Result) and "makecache" in r.details for r in results)

    @pytest.mark.parametrize("packages", [0, 3])
    def test_check_security_unsupported_has_no_metric(self, default_params, packages):
        """An unknown number of security updates must not be graphed as 0."""
        section = DnfSection(reboot_required=False, packages=packages, security_packages=-2, last_update_timestamp=2000000000)
        results = list(check_dnf(default_params, section))

        assert "security_updates" not in [r.name for r in results if isinstance(r, Metric)]

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

    def test_failed_security_query_is_not_up_to_date(self, default_params):
        """A failed security query (-1) must not be summarised as up to date."""
        section = DnfSection(reboot_required=False, packages=0, security_packages=-1, last_update_timestamp=2000000000)
        results = [r for r in check_dnf(default_params, section) if isinstance(r, Result)]

        assert not any("up to date" in r.summary for r in results)
        assert any(r.state == State.UNKNOWN and r.summary == "Security update check failed" for r in results)
        assert any(r.state == State.OK and r.summary == "Normal updates: 0" for r in results)

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


class TestMissingLastUpdate:
    """A missing last-update timestamp (-1) only alerts while updates are pending."""

    def test_no_pending_updates_is_ok(self, default_params):
        section = DnfSection(reboot_required=False, packages=0, security_packages=0, last_update_timestamp=-1)
        results = [r for r in check_dnf(default_params, section) if isinstance(r, Result)]

        assert all(r.state == State.OK for r in results)
        assert any("No upgrade transaction found" in r.details for r in results)

    def test_pending_updates_alert(self, default_params):
        params = {**default_params, "normal": ("no_levels", None), "security": ("no_levels", None)}
        section = DnfSection(reboot_required=False, packages=3, security_packages=0, last_update_timestamp=-1)
        results = [r for r in check_dnf(params, section) if isinstance(r, Result)]

        assert [r.summary for r in results if r.state == State.WARN] == ["No upgrade transaction found"]

    def test_pending_updates_use_configured_state(self, default_params):
        params = {**default_params, "normal": ("no_levels", None), "last_update_state": 2}
        section = DnfSection(reboot_required=False, packages=3, security_packages=0, last_update_timestamp=-1)
        results = [r for r in check_dnf(params, section) if isinstance(r, Result)]

        assert any(r.state == State.CRIT and r.summary == "No upgrade transaction found" for r in results)


class TestMetadataAge:
    """Stale repository metadata (makecache timer not running) must not stay silent."""

    @pytest.fixture(autouse=True)
    def _now(self):
        with patch("cmk_addons.plugins.dnf.agent_based.dnf.time", return_value=1700000000 + 30 * 86400):
            yield

    def _results(self, params, metadata_timestamp):
        section = DnfSection(
            reboot_required=False,
            packages=0,
            security_packages=0,
            last_update_timestamp=1700000000,
            metadata_timestamp=metadata_timestamp,
        )
        return [r for r in check_dnf(params, section) if isinstance(r, Result)]

    def test_recent_metadata_is_ok(self, default_params):
        results = self._results(default_params, 1700000000 + 29 * 86400)

        assert all(r.state == State.OK for r in results)
        assert any(r.details.startswith("Repository metadata age: 1 day") for r in results)

    def test_old_metadata_warns_and_names_the_cause(self, default_params):
        results = self._results(default_params, 1700000000 + 20 * 86400)

        warn = [r for r in results if r.state == State.WARN]
        assert len(warn) == 1
        assert warn[0].summary.startswith("Repository metadata age: 10 days")
        assert "makecache" in warn[0].summary

    def test_thresholds_and_state_are_configurable(self, default_params):
        params = {**default_params, "metadata_max_age": 14, "metadata_age_state": 2}

        assert all(r.state == State.OK for r in self._results(params, 1700000000 + 20 * 86400))
        assert any(r.state == State.CRIT for r in self._results(params, 1700000000 + 10 * 86400))

    def test_unknown_metadata_age_is_not_reported(self, default_params):
        results = self._results(default_params, -1)

        assert all(r.state == State.OK for r in results)
        assert not any("metadata" in r.details for r in results)


class TestRefreshPending:
    """Cached counts that no refresh completes for must not look current."""

    NOW = 1700000000 + 30 * 86400

    @pytest.fixture(autouse=True)
    def _now(self):
        with patch("cmk_addons.plugins.dnf.agent_based.dnf.time", return_value=self.NOW):
            yield

    def _results(self, params, refresh_pending_since):
        section = DnfSection(
            reboot_required=False,
            packages=0,
            security_packages=0,
            last_update_timestamp=self.NOW - 86400,
            refresh_pending_since=refresh_pending_since,
        )
        return [r for r in check_dnf(params, section) if isinstance(r, Result)]

    @pytest.mark.parametrize("since", [-1, NOW - 600], ids=["none", "running"])
    def test_no_or_recent_pending_refresh_is_ok(self, default_params, since):
        results = self._results(default_params, since)

        assert all(r.state == State.OK for r in results)
        assert not any("outdated" in r.details for r in results)

    def test_long_pending_refresh_warns(self, default_params):
        results = self._results(default_params, self.NOW - 3 * 3600)

        warn = [r for r in results if r.state == State.WARN]
        assert len(warn) == 1
        assert warn[0].summary.startswith("Update information may be outdated")
        assert "3 hours" in warn[0].summary

    def test_threshold_and_state_are_configurable(self, default_params):
        params = {**default_params, "refresh_pending_max_age": 4, "refresh_pending_state": 2}

        assert all(r.state == State.OK for r in self._results(params, self.NOW - 3 * 3600))
        assert any(r.state == State.CRIT for r in self._results(params, self.NOW - 5 * 3600))


class TestRebootHint:
    """needs-restarting covers core libraries and services besides the kernel."""

    def _results(self, params, *, kernel=False, hint=None, packages=None):
        section = DnfSection(
            reboot_required=kernel,
            packages=0,
            security_packages=0,
            last_update_timestamp=2000000000,
            reboot_hint=hint,
            reboot_hint_packages=packages,
        )
        return [r for r in check_dnf(params, section) if isinstance(r, Result)]

    def test_updated_core_packages_require_a_reboot(self, default_params):
        results = self._results(default_params, hint=True, packages="glibc,systemd")

        crit = [r for r in results if r.state == State.CRIT]
        assert len(crit) == 1
        assert crit[0].summary == "Reboot required"
        assert crit[0].details == "Reboot required: updated since boot: glibc, systemd"

    def test_newer_kernel_takes_precedence(self, default_params):
        results = self._results(default_params, kernel=True, hint=True, packages="kernel-core")

        assert [r.details for r in results if r.state == State.CRIT] == ["Reboot required: a newer kernel is installed"]

    @pytest.mark.parametrize("hint", [False, None])
    def test_no_or_unknown_hint_is_ok(self, default_params, hint):
        assert all(r.state == State.OK for r in self._results(default_params, hint=hint))

    def test_hint_can_be_disabled(self, default_params):
        params = {**default_params, "reboot_hint": False}

        assert all(r.state == State.OK for r in self._results(params, hint=True, packages="glibc"))
        assert any(r.state == State.CRIT for r in self._results(params, kernel=True))

    def test_uses_the_configured_state(self, default_params):
        params = {**default_params, "reboot_req": 1}

        assert any(r.state == State.WARN and r.summary == "Reboot required" for r in self._results(params, hint=True, packages="glibc"))
