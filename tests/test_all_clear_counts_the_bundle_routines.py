"""D3: "Everything looks healthy" must not print while a bundle routine is failing.

_append_all_clear looked only at findings/errors, never at the recurring ingest
routines (email-ingest and the bundles), so a routine that had stopped, or
exited non-zero on every run, left the banner up. Synthetic data only.
"""
import sys
from pathlib import Path

import pytest

AGENT = Path(__file__).resolve().parent.parent / "vendor" / "doctor" / "agent"
sys.path.insert(0, str(AGENT))

import routine_status  # noqa: E402
import web_ui  # noqa: E402


def _row(label, health, reason="x"):
    return {"routine": label, "keeps_up_to_date": label, "installed": True,
            "health": health, "reason": reason}


def _with_rows(monkeypatch, rows):
    monkeypatch.setattr(routine_status, "read_routine_status", lambda *a, **k: rows)


def test_failing_routine_blocks_the_all_clear(monkeypatch):
    _with_rows(monkeypatch, [
        _row("com.creativemachines.ostler.email-ingest", "ok"),
        _row("com.creativemachines.ostler.whatsapp-bundle", "failing", "last run exited with code 1"),
    ])
    out = web_ui._append_all_clear([])
    titles = [f["title"] for f in out]
    assert web_ui.ALL_HEALTHY_TITLE not in titles, titles
    assert any("whatsapp-bundle" in f["detail"] or "WhatsApp" in f["detail"] for f in out)
    assert all(f["severity"] != "info" for f in out)


def test_stale_routine_blocks_the_all_clear(monkeypatch):
    _with_rows(monkeypatch, [_row("com.creativemachines.ostler.imessage-bundle", "stale", "no run for 900 min")])
    assert web_ui.ALL_HEALTHY_TITLE not in [f["title"] for f in web_ui._append_all_clear([])]


def test_healthy_routines_still_get_the_all_clear(monkeypatch):
    """Control: waiting / not installed / ok are not faults."""
    _with_rows(monkeypatch, [
        _row("com.creativemachines.ostler.email-ingest", "ok"),
        _row("com.creativemachines.ostler.email-bundle", "waiting"),
        _row("com.creativemachines.ostler.spoken-bundle", "not_installed"),
    ])
    assert web_ui.ALL_HEALTHY_TITLE in [f["title"] for f in web_ui._append_all_clear([])]


def test_unreadable_routine_status_is_not_an_all_clear(monkeypatch):
    def boom(*a, **k):
        raise OSError("launchctl unavailable")
    monkeypatch.setattr(routine_status, "read_routine_status", boom)
    assert web_ui.ALL_HEALTHY_TITLE not in [f["title"] for f in web_ui._append_all_clear([])]
