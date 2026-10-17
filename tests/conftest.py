"""Keep the Person-removal audit out of the real home directory.

Writers that can remove a Person append to ~/.ostler/logs/person-deletions.jsonl
(person_audit.py). Any test that drives one of them must not write to the
developer's or CI runner's real log, so every test gets a private path.
"""
import pytest


@pytest.fixture(autouse=True)
def _private_person_deletion_log(tmp_path, monkeypatch):
    monkeypatch.setenv("OSTLER_PERSON_DELETION_LOG", str(tmp_path / "person-deletions.jsonl"))
