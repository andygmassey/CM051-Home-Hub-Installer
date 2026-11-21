"""A degraded reply-debt brief with reason minor_debts_withheld RENDERS a human
line, on both the brief surface (ical-server) and the front-page card
(signals.py). The code alone is not a rendering (consumer-side proof, R01).

Fictional copy only. No names, no dates, no addresses.
"""
from __future__ import annotations

import importlib.util
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "vendor" / "cm041" / "assistant_api" / "ical-server.py"
COMPILER = ROOT / "vendor" / "cm059_editor"
WITHHELD_LINE = "Some reply reminders are hidden to protect a child's privacy."


def _server(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    # ical-server refuses to start without the vendored ostler_security package.
    sys.path.insert(0, str(ROOT / "vendor"))
    spec = importlib.util.spec_from_file_location("_r01_ical_server", SERVER)
    mod = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(SERVER.parent))
    spec.loader.exec_module(mod)
    return mod


class _FakeService:
    """Stands in for CM048's reply_debt_service with a given degraded reason."""

    def __init__(self, reason):
        self._reason = reason

    def compute_reply_debts(self, **kw):
        return []

    def reply_debt_payload(self, debts):
        return {"count": 0, "brief_line": "N reply debts withheld (private)",
                "debts": [], "degraded": True, "reason": self._reason}


def test_minor_withheld_reason_renders_the_human_line(monkeypatch, tmp_path):
    mod = _server(monkeypatch, tmp_path)
    monkeypatch.setattr(mod, "_load_reply_debt_service",
                        lambda: _FakeService("minor_debts_withheld"))
    payload, status = mod.api_reply_debt()
    assert status == 200
    assert payload["degraded"] is True
    assert payload["brief_line"] == WITHHELD_LINE
    assert "caught up" not in payload["brief_line"]


def test_control_another_degraded_reason_stays_blank(monkeypatch, tmp_path):
    mod = _server(monkeypatch, tmp_path)
    monkeypatch.setattr(mod, "_load_reply_debt_service",
                        lambda: _FakeService("reply_debt_failed"))
    payload, _ = mod.api_reply_debt()
    assert payload["degraded"] is True
    assert payload["brief_line"] == ""


def _signals():
    sys.path.insert(0, str(COMPILER))
    from compiler import signals
    return signals


def test_front_page_withheld_card_says_hidden_not_couldnt_check():
    signals = _signals()
    now = datetime(2026, 11, 20, 12, 0, tzinfo=timezone.utc)
    cards = signals.build_signal_cards(
        {"reply_debt": {"degraded": True, "reason": "minor_debts_withheld"}}, now)
    assert len(cards) == 1
    assert cards[0]["title"] == "Some reply reminders are hidden"
    assert WITHHELD_LINE in cards[0]["body"]
    assert "Couldn't check" not in cards[0]["title"]


def test_control_unreadable_source_still_says_couldnt_check():
    signals = _signals()
    now = datetime(2026, 11, 20, 12, 0, tzinfo=timezone.utc)
    cards = signals.build_signal_cards(
        {"reply_debt": {"degraded": True, "reason": "reply_debt_failed"}}, now)
    assert len(cards) == 1
    assert cards[0]["title"] == "Couldn't check who is waiting on you"
