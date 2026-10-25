"""Keep the Person-removal audit out of the real home directory.

Writers that can remove a Person append to ~/.ostler/logs/person-deletions.jsonl
(person_audit.py). Any test that drives one of them must not write to the
developer's or CI runner's real log, so every test gets a private path.
"""
import pytest


@pytest.fixture(autouse=True)
def _private_person_deletion_log(tmp_path, monkeypatch):
    monkeypatch.setenv("OSTLER_PERSON_DELETION_LOG", str(tmp_path / "person-deletions.jsonl"))


@pytest.fixture(autouse=True)
def _reminder_fixture_dates_are_not_stale(request, monkeypatch):
    """The older cm048_reminder tests carry fixed 2026-10 source dates; the
    30-day staleness cutoff would turn them red as the calendar moves. They
    test other rules, so the cutoff is off for them. The gate's own test
    (test_cm048_reminder_title_quality_gate.py) sets the env var itself."""
    name = request.module.__name__
    if name.startswith("test_cm048_reminder") and "quality_gate" not in name:
        monkeypatch.setenv("OSTLER_TODO_MAX_AGE_DAYS", "0")
