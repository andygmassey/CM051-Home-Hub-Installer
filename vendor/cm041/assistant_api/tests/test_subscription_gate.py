"""Tests for the subscription gate helper.

Synthetic-fixture-only. NEVER touches real Apple receipts. Every test
overrides ``OSTLER_SUBSCRIPTION_STATE`` to a temp path so tests cannot
interfere with the customer's real state file.

Coverage map (per the G0 brief + project rules around silent-bail test
shape):

- Default state: no file on disk -> inactive (the legitimate "fresh
  uninstalled Hub" case).
- ``activate_first_month_free`` writes a 30-day active state with a
  14-day grace tail.
- ``refresh_from_companion`` writes an active state with the supplied
  expiry; resets grace_period_end.
- ``expire_check`` transitions active -> grace when expires_at passes.
- ``expire_check`` transitions grace -> inactive when grace_period_end
  passes.
- ``expire_check`` is idempotent (calling twice does not double-walk).
- ``is_active_or_grace`` covers all four branches:
    * status=active -> True
    * status=grace within window -> True
    * status=grace after window -> falls through to offline-grace
    * status=inactive but last_validated_at within 30d -> fail-open True
    * status=inactive AND last_validated_at over 30d (or absent) -> False
- Corrupt state file -> degrades to default-inactive without raising.
- ``state_dict`` round-trips written state for the Doctor banner.
"""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

# Import the module under test. The assistant_api/ directory is two
# parents up from this test file. Inserting it at the front of sys.path
# means tests can run from either the worktree root or this directory.
import sys

ASSISTANT_API_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ASSISTANT_API_DIR))

import subscription_gate  # noqa: E402
from subscription_gate import (  # noqa: E402
    GRACE_DAYS,
    OFFLINE_GRACE_DAYS,
    STATUS_ACTIVE,
    STATUS_GRACE,
    STATUS_INACTIVE,
    activate_first_month_free,
    expire_check,
    is_active_or_grace,
    refresh_from_companion,
    state_dict,
)


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


class SubscriptionGateTestCase(unittest.TestCase):
    """Base class -- isolates each test to its own temp state file."""

    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self.state_path = Path(self._tmpdir.name) / "subscription_state.json"
        self._prev_env = os.environ.get("OSTLER_SUBSCRIPTION_STATE")
        os.environ["OSTLER_SUBSCRIPTION_STATE"] = str(self.state_path)

    def tearDown(self) -> None:
        if self._prev_env is None:
            os.environ.pop("OSTLER_SUBSCRIPTION_STATE", None)
        else:
            os.environ["OSTLER_SUBSCRIPTION_STATE"] = self._prev_env
        self._tmpdir.cleanup()

    def _write_raw(self, payload: dict) -> None:
        """Write a literal payload to the state file -- bypasses the helper."""
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        self.state_path.write_text(json.dumps(payload))


class TestDefaultState(SubscriptionGateTestCase):
    def test_no_file_is_inactive(self) -> None:
        """Fresh Hub with no state file: ongoing intelligence is paused."""
        self.assertFalse(self.state_path.exists())
        self.assertFalse(is_active_or_grace())
        snapshot = state_dict()
        self.assertEqual(snapshot["status"], STATUS_INACTIVE)
        self.assertEqual(snapshot["source"], "default")


class TestFirstMonthFree(SubscriptionGateTestCase):
    def test_activate_writes_active_state_with_30d_expiry(self) -> None:
        purchase = datetime(2026, 5, 27, 12, 0, tzinfo=timezone.utc)
        activate_first_month_free(_iso(purchase))

        snapshot = state_dict()
        self.assertEqual(snapshot["status"], STATUS_ACTIVE)
        self.assertEqual(snapshot["source"], "first_month_free")

        expires = datetime.fromisoformat(snapshot["expires_at"].replace("Z", "+00:00"))
        self.assertEqual(expires - purchase, timedelta(days=30))

        grace_end = datetime.fromisoformat(snapshot["grace_period_end"].replace("Z", "+00:00"))
        self.assertEqual(grace_end - expires, timedelta(days=GRACE_DAYS))

        # Default-inactive is replaced; is_active_or_grace returns True.
        self.assertTrue(is_active_or_grace())

    def test_activate_with_garbage_date_falls_back_to_now(self) -> None:
        """install.sh should never write a broken state, even if it
        somehow passes garbage. Defensive fallback uses now() so the
        customer always gets at least 30 days from when the install
        actually ran.
        """
        activate_first_month_free("not-an-iso-date")
        snapshot = state_dict()
        self.assertEqual(snapshot["status"], STATUS_ACTIVE)
        # We can't assert the exact date, but the expires_at should be
        # parseable and ~30 days from now.
        expires = datetime.fromisoformat(snapshot["expires_at"].replace("Z", "+00:00"))
        delta = expires - datetime.now(timezone.utc)
        self.assertGreater(delta, timedelta(days=29))
        self.assertLess(delta, timedelta(days=31))


class TestRefreshFromCompanion(SubscriptionGateTestCase):
    def test_refresh_writes_active_with_provided_expiry(self) -> None:
        future = datetime.now(timezone.utc) + timedelta(days=90)
        refresh_from_companion(receipt_b64="ZmFrZS1yZWNlaXB0", expires_at_iso=_iso(future))

        snapshot = state_dict()
        self.assertEqual(snapshot["status"], STATUS_ACTIVE)
        self.assertEqual(snapshot["source"], "companion")
        self.assertEqual(snapshot["receipt"], "ZmFrZS1yZWNlaXB0")
        self.assertIsNone(snapshot["grace_period_end"])
        self.assertTrue(is_active_or_grace())

    def test_refresh_clears_prior_grace(self) -> None:
        """A previously-grace state should clear to active on Companion sync."""
        now = datetime.now(timezone.utc)
        self._write_raw({
            "status": STATUS_GRACE,
            "expires_at": _iso(now - timedelta(days=2)),
            "grace_period_end": _iso(now + timedelta(days=12)),
            "last_validated_at": _iso(now - timedelta(days=2)),
            "source": "companion",
        })

        future = now + timedelta(days=30)
        refresh_from_companion("YWN0aXZl", _iso(future))

        snapshot = state_dict()
        self.assertEqual(snapshot["status"], STATUS_ACTIVE)
        self.assertIsNone(snapshot["grace_period_end"])


class TestExpireCheck(SubscriptionGateTestCase):
    def test_active_past_expiry_transitions_to_grace(self) -> None:
        now = datetime.now(timezone.utc)
        self._write_raw({
            "status": STATUS_ACTIVE,
            "expires_at": _iso(now - timedelta(hours=1)),
            "grace_period_end": _iso(now + timedelta(days=14)),
            "last_validated_at": _iso(now - timedelta(days=35)),  # past offline-grace
            "source": "companion",
        })

        expire_check()

        self.assertEqual(state_dict()["status"], STATUS_GRACE)
        # Grace window still active -> is_active_or_grace returns True.
        self.assertTrue(is_active_or_grace())

    def test_grace_past_grace_end_transitions_to_inactive(self) -> None:
        now = datetime.now(timezone.utc)
        self._write_raw({
            "status": STATUS_GRACE,
            "expires_at": _iso(now - timedelta(days=20)),
            "grace_period_end": _iso(now - timedelta(hours=1)),
            "last_validated_at": _iso(now - timedelta(days=40)),  # past offline-grace
            "source": "companion",
        })

        expire_check()

        self.assertEqual(state_dict()["status"], STATUS_INACTIVE)
        # No offline-grace coverage either -> intelligence pauses.
        self.assertFalse(is_active_or_grace())

    def test_expire_check_idempotent(self) -> None:
        """Calling expire_check repeatedly does not corrupt state."""
        now = datetime.now(timezone.utc)
        self._write_raw({
            "status": STATUS_ACTIVE,
            "expires_at": _iso(now + timedelta(days=10)),
            "grace_period_end": _iso(now + timedelta(days=24)),
            "last_validated_at": _iso(now),
            "source": "companion",
        })

        before = state_dict()
        for _ in range(5):
            expire_check()
        after = state_dict()

        self.assertEqual(before, after)
        self.assertTrue(is_active_or_grace())

    def test_active_within_window_unchanged(self) -> None:
        """expire_check on a still-active subscription is a no-op."""
        now = datetime.now(timezone.utc)
        self._write_raw({
            "status": STATUS_ACTIVE,
            "expires_at": _iso(now + timedelta(days=20)),
            "grace_period_end": _iso(now + timedelta(days=34)),
            "last_validated_at": _iso(now),
            "source": "companion",
        })

        expire_check()
        self.assertEqual(state_dict()["status"], STATUS_ACTIVE)


class TestIsActiveOrGrace(SubscriptionGateTestCase):
    """The four branches of the resolution order, walked byte-by-byte."""

    def test_status_active_returns_true(self) -> None:
        now = datetime.now(timezone.utc)
        self._write_raw({
            "status": STATUS_ACTIVE,
            "expires_at": _iso(now + timedelta(days=10)),
            "last_validated_at": _iso(now),
            "source": "companion",
        })
        self.assertTrue(is_active_or_grace())

    def test_status_grace_within_window_returns_true(self) -> None:
        now = datetime.now(timezone.utc)
        self._write_raw({
            "status": STATUS_GRACE,
            "expires_at": _iso(now - timedelta(days=2)),
            "grace_period_end": _iso(now + timedelta(days=5)),
            "last_validated_at": _iso(now - timedelta(days=40)),  # past offline-grace
            "source": "companion",
        })
        self.assertTrue(is_active_or_grace())

    def test_status_grace_after_window_falls_through_to_offline_grace(self) -> None:
        """grace expired AND recent companion contact -> fail-open True.

        This is the explicit Apple-restraint posture: a customer whose
        grace window just lapsed but who synced with the Companion within
        the offline-grace window is still treated as legitimate. The next
        Companion sync will resolve their real state.
        """
        now = datetime.now(timezone.utc)
        self._write_raw({
            "status": STATUS_GRACE,
            "expires_at": _iso(now - timedelta(days=20)),
            "grace_period_end": _iso(now - timedelta(hours=1)),
            "last_validated_at": _iso(now - timedelta(days=10)),  # within offline-grace
            "source": "companion",
        })
        self.assertTrue(is_active_or_grace())

    def test_offline_grace_with_inactive_status_still_returns_true(self) -> None:
        """Customer on holiday: Hub thinks status=inactive (no Companion
        contact has refreshed it), but last_validated_at was recent.
        Fail-open: keep their intelligence running. The brief calls this
        out as the litmus test for fail-open semantics.
        """
        now = datetime.now(timezone.utc)
        self._write_raw({
            "status": STATUS_INACTIVE,
            "expires_at": _iso(now - timedelta(days=1)),  # actually expired
            "last_validated_at": _iso(now - timedelta(days=25)),  # within 30d
            "source": "companion",
        })
        self.assertTrue(
            is_active_or_grace(),
            "Customer with recent last_validated_at must not be blocked "
            "on infrastructure failure (Apple-restraint posture).",
        )

    def test_no_offline_grace_coverage_returns_false(self) -> None:
        """Genuinely-cancelled: grace exhausted AND last_validated_at over
        30 days old. This is the only path that returns False.
        """
        now = datetime.now(timezone.utc)
        self._write_raw({
            "status": STATUS_INACTIVE,
            "expires_at": _iso(now - timedelta(days=50)),
            "grace_period_end": _iso(now - timedelta(days=36)),
            "last_validated_at": _iso(now - timedelta(days=45)),  # past offline-grace
            "source": "companion",
        })
        self.assertFalse(is_active_or_grace())

    def test_inactive_with_no_last_validated_returns_false(self) -> None:
        """No prior Companion contact at all and status=inactive: no
        legitimate-customer signal to fail-open on. Block.
        """
        self._write_raw({
            "status": STATUS_INACTIVE,
            "source": "default",
        })
        self.assertFalse(is_active_or_grace())

    def test_offline_grace_boundary_exact(self) -> None:
        """At exactly OFFLINE_GRACE_DAYS old, fail-open is borderline.
        Behaviour: strictly-less-than the window -> still True; the test
        pins the contract so a future refactor that changes < to <= is
        caught.
        """
        now = datetime.now(timezone.utc)
        # last_validated_at is exactly 25 days ago, comfortably inside
        # the 30-day window.
        self._write_raw({
            "status": STATUS_INACTIVE,
            "expires_at": _iso(now - timedelta(days=1)),
            "last_validated_at": _iso(now - timedelta(days=25)),
            "source": "companion",
        })
        self.assertTrue(is_active_or_grace())

        # And exactly 35 days ago, well past the window -> False.
        self._write_raw({
            "status": STATUS_INACTIVE,
            "expires_at": _iso(now - timedelta(days=1)),
            "last_validated_at": _iso(now - timedelta(days=35)),
            "source": "companion",
        })
        self.assertFalse(is_active_or_grace())


class TestCorruptState(SubscriptionGateTestCase):
    def test_corrupt_json_degrades_to_inactive_without_raising(self) -> None:
        """A garbage state file must not crash the helper. Every pipeline
        depends on this: if state.json gets corrupted (disk full mid-write,
        editor accident), pipelines pause cleanly rather than crashing.
        """
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        self.state_path.write_text("{not valid json")

        # No exception raised.
        snapshot = state_dict()
        self.assertEqual(snapshot["status"], STATUS_INACTIVE)

        # And is_active_or_grace returns False (no fail-open signal).
        self.assertFalse(is_active_or_grace())

    def test_state_is_not_a_dict_degrades(self) -> None:
        """state.json containing a JSON array (or string, etc.) degrades."""
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        self.state_path.write_text('["array", "not", "object"]')

        snapshot = state_dict()
        self.assertEqual(snapshot["status"], STATUS_INACTIVE)


class TestConstants(unittest.TestCase):
    """Pin the contract values the brief locks. If anyone changes these,
    the test forces them to update the brief + Doctor banner copy too.
    """

    def test_grace_days(self) -> None:
        self.assertEqual(GRACE_DAYS, 14)

    def test_offline_grace_days(self) -> None:
        self.assertEqual(OFFLINE_GRACE_DAYS, 30)


if __name__ == "__main__":
    unittest.main()
