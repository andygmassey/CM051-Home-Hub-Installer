"""Future-dated last-contact cap regression (CM041 #88, vendored twin).

`last_contact` answers "when did I last interact with this person". A
future-dated event (an upcoming calendar meeting that leaked into a
``pwg:lastContact*`` predicate) must NEVER win the flat ``last_contact``
value. Before the fix the twin computed ``max(per_source)`` / ``max(
by_source.values())`` directly, so a future date became "last contact"
(symptom: the assistant said "I last had contact with her on July 2nd
2026" — a date in the future).

This test targets the ``_max_past_last_contact`` helper that both
person-card paths now route through. Past dates are unaffected; a
future date is dropped; an all-future set yields ``None`` (no
last-contact rather than a wrong one).

All fixtures are synthetic dates. No real names or emails are touched.
"""

from __future__ import annotations

import importlib.util
import sys
import types
import unittest
from datetime import datetime, timedelta
from pathlib import Path


THIS_DIR = Path(__file__).resolve().parent
ICAL_SERVER_PY = THIS_DIR.parent / "ical-server.py"


def _install_stub_ostler_security():
    if "ostler_security" in sys.modules:
        return
    pkg = types.ModuleType("ostler_security")
    pkg.__path__ = []
    sys.modules["ostler_security"] = pkg
    db_mod = types.ModuleType("ostler_security.database")

    def _stub_get_db_connection(*args, **kwargs):
        raise RuntimeError("stub: tests must not touch the DB")

    db_mod.get_db_connection = _stub_get_db_connection
    sys.modules["ostler_security.database"] = db_mod
    posture_mod = types.ModuleType("ostler_security.posture")
    posture_mod.record_posture = lambda *args, **kwargs: None
    sys.modules["ostler_security.posture"] = posture_mod


def _load_ical_server():
    if "ical_server" in sys.modules:
        return sys.modules["ical_server"]
    _install_stub_ostler_security()
    spec = importlib.util.spec_from_file_location(
        "ical_server", str(ICAL_SERVER_PY)
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["ical_server"] = module
    spec.loader.exec_module(module)
    return module


ical_server = _load_ical_server()


def _iso(days_from_today: int) -> str:
    return (
        datetime.utcnow() + timedelta(days=days_from_today)
    ).strftime("%Y-%m-%d")


class MaxPastLastContactTests(unittest.TestCase):
    """The helper both person-card paths route through."""

    def test_future_date_never_wins(self):
        # A past iMessage date and a future calendar date. The future
        # one must NOT be returned as last-contact.
        past = _iso(-30)
        future = _iso(+5)
        self.assertEqual(
            ical_server._max_past_last_contact([past, future]),
            past,
            "a future-dated event must not be treated as last-contact",
        )

    def test_today_is_allowed(self):
        today = _iso(0)
        self.assertEqual(
            ical_server._max_past_last_contact([_iso(-2), today]),
            today,
        )

    def test_all_future_yields_none(self):
        # Only future signals -> no last-contact rather than a wrong one.
        self.assertIsNone(
            ical_server._max_past_last_contact([_iso(+1), _iso(+10)])
        )

    def test_past_only_unaffected(self):
        # Pure past set: behaves exactly like max() did before.
        dates = ["2025-01-01", "2026-03-15", "2024-12-31"]
        self.assertEqual(
            ical_server._max_past_last_contact(dates),
            "2026-03-15",
        )

    def test_empty_and_falsy_inputs(self):
        self.assertIsNone(ical_server._max_past_last_contact([]))
        self.assertIsNone(ical_server._max_past_last_contact([None, ""]))

    def test_longer_iso_timestamps_capped_on_date_prefix(self):
        # Full ISO timestamps are compared on their YYYY-MM-DD prefix.
        past_ts = _iso(-1) + "T09:30:00Z"
        future_ts = _iso(+3) + "T09:30:00Z"
        self.assertEqual(
            ical_server._max_past_last_contact([past_ts, future_ts]),
            past_ts,
        )


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
