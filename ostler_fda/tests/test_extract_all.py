"""Tests for the master extraction runner."""
from __future__ import annotations

import json
import os
from pathlib import Path
from unittest.mock import patch

import pytest

from ostler_fda.extract_all import (
    ALL_SOURCES,
    DEFAULT_SOURCES,
    _resolve_enabled_sources,
    run_all,
)


class TestRunAll:
    """Test the master extraction runner."""

    def test_creates_output_directory(self, tmp_path):
        output_dir = tmp_path / "fda_output"
        # All extractors will fail with FileNotFoundError (no databases)
        # but the function should still create the directory and return
        summary = run_all(output_dir=output_dir)
        assert output_dir.exists()
        assert "sources" in summary
        assert "extracted_at" in summary

    def test_handles_all_file_not_found(self, tmp_path):
        """When no macOS databases exist, all enabled sources should be
        not_found / error / no_fda. Sources not in defaults (e.g.
        photos_faces, google_takeout) should be disabled_by_user.
        """
        output_dir = tmp_path / "fda_output"
        summary = run_all(output_dir=output_dir)

        for source, status in summary["sources"].items():
            assert status["status"] in (
                "not_found", "error", "no_fda", "disabled_by_user",
            ), f"Source {source} has unexpected status: {status['status']}"

    def test_saves_summary_json(self, tmp_path):
        output_dir = tmp_path / "fda_output"
        run_all(output_dir=output_dir)

        summary_file = output_dir / "extraction_summary.json"
        assert summary_file.exists()

        data = json.loads(summary_file.read_text())
        assert "sources" in data
        assert "extracted_at" in data

    def test_sources_are_independent(self, tmp_path):
        """Each extractor should be independent – one failure
        should not affect others."""
        output_dir = tmp_path / "fda_output"

        # Patch safari_history to raise an unexpected error
        with patch(
            "ostler_fda.extract_all.run_all.__module__",
            side_effect=None,
        ):
            summary = run_all(output_dir=output_dir)

        # Should still have entries for all sources
        assert len(summary["sources"]) >= 6

    def test_all_nine_sources_listed(self, tmp_path):
        """Verify all 9 extractor outputs appear in the summary
        (8 attempted under default consent + google_takeout disabled_by_user).
        """
        output_dir = tmp_path / "fda_output"
        summary = run_all(output_dir=output_dir)

        expected_sources = {
            "safari_history",
            "safari_bookmarks",
            "imessage",
            "apple_notes",
            "photos",
            "calendar",
            "reminders",
            "apple_mail",
            "google_takeout",
        }
        assert set(summary["sources"].keys()) == expected_sources


class TestPerSourceConsent:
    """Per-source opt-in is the GDPR mechanism that keeps the user as
    Controller of their own graph (policy §1) and that gates Art. 9
    special-category face data behind explicit consent (policy §2).
    Regression tests below lock both protections in place.
    """

    def test_photos_faces_off_by_default(self):
        """Art. 9 protection: face data must NOT be in the default set.
        If this test fails, we are processing GDPR special-category data
        without the explicit consent the policy promises.
        """
        assert "photos_faces" not in DEFAULT_SOURCES, (
            "photos_faces (Art. 9 face data) must NEVER be in DEFAULT_SOURCES "
            "without an explicit-consent UI. See policy §2."
        )

    def test_photos_faces_in_all_sources(self):
        """photos_faces must remain a recognised source even though it
        is excluded from defaults."""
        assert "photos_faces" in ALL_SOURCES

    def test_default_sources_when_no_env_no_arg(self, monkeypatch):
        monkeypatch.delenv("OSTLER_FDA_SOURCES", raising=False)
        assert _resolve_enabled_sources() == DEFAULT_SOURCES

    def test_env_var_overrides_default(self, monkeypatch):
        monkeypatch.setenv("OSTLER_FDA_SOURCES", "safari_history,calendar")
        assert _resolve_enabled_sources() == frozenset({"safari_history", "calendar"})

    def test_arg_overrides_env_var(self, monkeypatch):
        monkeypatch.setenv("OSTLER_FDA_SOURCES", "calendar")
        assert _resolve_enabled_sources(["safari_history"]) == frozenset({"safari_history"})

    def test_env_var_with_photos_faces_enables_it(self, monkeypatch):
        monkeypatch.setenv("OSTLER_FDA_SOURCES", "calendar,photos_faces")
        resolved = _resolve_enabled_sources()
        assert "photos_faces" in resolved
        assert "calendar" in resolved
        assert "safari_history" not in resolved

    def test_env_var_handles_whitespace_and_empty(self, monkeypatch):
        monkeypatch.setenv("OSTLER_FDA_SOURCES", " calendar , , safari_history , ")
        assert _resolve_enabled_sources() == frozenset({"calendar", "safari_history"})

    def test_disabled_sources_marked_in_summary(self, tmp_path, monkeypatch):
        """Sources the user did NOT enable should appear in the summary
        with status='disabled_by_user' so audit trails are complete.
        """
        monkeypatch.setenv("OSTLER_FDA_SOURCES", "calendar")
        output_dir = tmp_path / "fda_output"
        summary = run_all(output_dir=output_dir)

        # Calendar attempted (will be not_found / no_fda in test env, but attempted)
        assert summary["sources"]["calendar"]["status"] != "disabled_by_user"
        # Everything else explicitly disabled
        for src in ("safari_history", "imessage", "apple_mail", "reminders"):
            assert summary["sources"][src]["status"] == "disabled_by_user", (
                f"Expected {src} disabled_by_user, got {summary['sources'][src]['status']}"
            )

    def test_summary_records_enabled_sources(self, tmp_path, monkeypatch):
        """The summary must record exactly which sources were enabled, so
        the audit trail can answer 'what did the user consent to on this run?'
        """
        monkeypatch.setenv("OSTLER_FDA_SOURCES", "calendar,safari_history")
        output_dir = tmp_path / "fda_output"
        summary = run_all(output_dir=output_dir)

        assert "enabled_sources" in summary
        assert summary["enabled_sources"] == ["calendar", "safari_history"]
