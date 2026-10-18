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
        # Purchase date is RELATIVE to now, because an install happens now.
        # It used to be the literal datetime(2026, 5, 27) -- the day the
        # test was written -- and the final assertion below claimed that
        # customer still had Ostler Pro. By 2026-09-16 that install was
        # 112 days old and its grace had been over for two months, and
        # the assertion still passed, because nothing walked the state
        # forward and is_active_or_grace read the stale status field
        # directly. This test was a witness to the revenue defect, not a
        # guard against it. Keeping the date fixed would now assert that
        # a four-month-dead trial is live.
        purchase = datetime.now(timezone.utc) - timedelta(days=1)
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

        # The FIRST call normalises the state: it stamps the has_ever_paid
        # sticky bit that this legacy fixture predates (source=companion is
        # receipt evidence, so it backfills True). Idempotence is the claim
        # about calls after the state is normalised, so take the baseline
        # after one call rather than before any.
        expire_check()
        before = state_dict()
        self.assertTrue(before["has_ever_paid"])
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
        """grace expired AND we are in the dark -> fail-open True.

        The explicit Apple-restraint posture: a paying customer whose
        grace window just lapsed, whose newest receipt PREDATES the
        renewal we never heard about, is still treated as legitimate.

        The fixture's last_validated_at used to be LATER than its own
        expires_at, which is not the dark at all -- it says we heard from
        Apple after the expiry and were told it had expired. Because the
        iOS app re-pushes on every foreground, that fixture described a
        cancelled customer who keeps Ostler Pro by opening the app. Dates
        reordered so the test asserts the posture its docstring claims.
        See test_a_cancelled_customer_cannot_hold_pro_by_opening_the_app
        for the case it used to cover by accident.
        """
        now = datetime.now(timezone.utc)
        self._write_raw({
            "status": STATUS_GRACE,
            "expires_at": _iso(now - timedelta(days=1)),
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


class TestTheCustomerOnDayThirtyOne(SubscriptionGateTestCase):
    """The revenue spine, stated as people rather than as functions.

    Every test here starts from a state file written by the SAME code the
    installer runs (``activate_first_month_free``) or by the SAME code the
    receipt endpoint runs (``refresh_from_companion``), then moves the
    clock. Nothing hand-writes a status field, because a fixture that
    hand-writes the status is testing the fixture.

    The scheduler is deliberately NOT invoked in the first test. That is
    the point: the customer-visible answer must be right even if the
    ticker never ran, because for the whole of v1.0 it never did.
    """

    def _install_days_ago(self, days: int) -> None:
        activate_first_month_free(
            _iso(datetime.now(timezone.utc) - timedelta(days=days))
        )

    def test_a_buyer_who_never_subscribes_loses_pro_on_day_31(self) -> None:
        """Bought the Hub, took the free month, never subscribed.

        On day 31 ongoing intelligence stops. No grace: the 14-day
        cushion is for people who have paid, per Andy 2026-07-31.
        """
        self._install_days_ago(31)
        self.assertFalse(
            is_active_or_grace(),
            "A Hub buyer 31 days in who never paid for Pro still has it. "
            "This is the defect: every buyer got Pro free forever.",
        )
        self.assertEqual(state_dict()["status"], STATUS_INACTIVE)

    def test_that_buyer_still_has_pro_on_day_29(self) -> None:
        """The free month is a real month. Do not clip it."""
        self._install_days_ago(29)
        self.assertTrue(is_active_or_grace())

    def test_that_buyer_gets_no_grace_fortnight_on_day_40(self) -> None:
        """Day 40 is inside the 14-day grace window on paper.

        A never-paid trialist must not get it, or the free month is a
        free 44 days and the reinstall loop makes it free forever.
        """
        self._install_days_ago(40)
        self.assertFalse(is_active_or_grace())

    def test_that_buyer_cannot_farm_a_second_month_by_reinstalling(self) -> None:
        """Delete the state file, re-run the installer, get another month.

        That is allowed -- we cannot see the deletion -- but the sticky
        bit must still read false, so the second month also ends on time
        rather than compounding into a grace window.
        """
        self._install_days_ago(40)
        self.state_path.unlink()
        self._install_days_ago(0)
        self.assertTrue(is_active_or_grace())
        self.assertFalse(state_dict()["has_ever_paid"])

    def test_a_customer_who_paid_once_then_lapsed_keeps_grace(self) -> None:
        """Paid for Pro, then the subscription lapsed. Andy's rule: keep it.

        Two days past expiry, inside the 14-day window, they keep running.
        """
        now = datetime.now(timezone.utc)
        refresh_from_companion("cmVjZWlwdA==", _iso(now - timedelta(days=2)))
        self.assertTrue(state_dict()["has_ever_paid"])
        self.assertTrue(
            is_active_or_grace(),
            "A customer who has paid for Pro lost it two days after "
            "expiry. Grace exists for exactly this person.",
        )
        self.assertEqual(state_dict()["status"], STATUS_GRACE)

    def test_a_customer_who_paid_once_then_lapsed_stops_after_the_fortnight(self) -> None:
        """Grace is a fortnight, not forever.

        refresh_from_companion writes grace_period_end=None, so a lapsed
        payer has no grace date on file. Derived from expires_at, or this
        customer keeps Pro for life after cancelling.
        """
        now = datetime.now(timezone.utc)
        refresh_from_companion(
            "cmVjZWlwdA==", _iso(now - timedelta(days=GRACE_DAYS + 2))
        )
        self.assertFalse(is_active_or_grace())
        self.assertEqual(state_dict()["status"], STATUS_INACTIVE)

    def test_a_paying_customer_with_no_network_keeps_pro(self) -> None:
        """Currently paying, Hub offline, no receipt push for 20 days.

        Apple restraint: never punish a payer for infrastructure we
        cannot observe. The 30-day offline fail-open still covers them.
        """
        # The real shape of this: the last receipt we received was 25 days
        # ago and covered a month that ended 5 days ago. The renewal DID
        # happen at Apple, we just never heard about it. Our newest fact
        # predates the renewal point, so we are genuinely in the dark.
        now = datetime.now(timezone.utc)
        refresh_from_companion("cmVjZWlwdA==", _iso(now + timedelta(days=30)))
        state = state_dict()
        state["last_validated_at"] = _iso(now - timedelta(days=25))
        state["expires_at"] = _iso(now - timedelta(days=5))
        state["status"] = STATUS_INACTIVE
        self._write_raw(state)
        self.assertTrue(
            is_active_or_grace(),
            "A paying customer was locked out because their Hub could "
            "not reach the network. That is the error we must not make.",
        )

    def test_a_cancelled_customer_cannot_hold_pro_by_opening_the_app(self) -> None:
        """The other half of the fail-open, and a hole of its own.

        The iOS app re-pushes a receipt on every foreground, so
        last_validated_at keeps moving to now. If a fresh validation that
        REPORTS an expiry in the past still satisfies the 30-day offline
        branch, a customer who cancelled keeps Ostler Pro indefinitely
        just by opening the app. Silence is the reason to fail open; an
        answer is not.
        """
        now = datetime.now(timezone.utc)
        refresh_from_companion(
            "cmVjZWlwdA==", _iso(now - timedelta(days=GRACE_DAYS + 2))
        )
        self.assertEqual(state_dict()["last_validated_at"][:4], str(now.year))
        self.assertFalse(is_active_or_grace())

    def test_the_offline_failopen_does_not_cover_a_never_paid_trialist(self) -> None:
        """The fail-open used to grant everyone a second month.

        install.sh stamps last_validated_at at activation time, so for
        the first 30 days EVERY install satisfied the offline branch --
        a denominator of everybody. Gate it on has_ever_paid or the
        day-31 fix is undone by the branch below it.
        """
        self._install_days_ago(31)
        state = state_dict()
        state["last_validated_at"] = _iso(datetime.now(timezone.utc))
        self._write_raw(state)
        self.assertFalse(is_active_or_grace())

    def test_an_existing_payer_upgrading_to_this_build_keeps_grace(self) -> None:
        """A state file written BEFORE has_ever_paid existed.

        Backfill from the receipt, or the fix ships by taking grace away
        from the customers who paid for it.
        """
        now = datetime.now(timezone.utc)
        self._write_raw({
            "status": STATUS_ACTIVE,
            "last_validated_at": _iso(now - timedelta(days=2)),
            "expires_at": _iso(now - timedelta(days=2)),
            "grace_period_end": None,
            "source": "companion",
            "receipt": "cmVjZWlwdA==",
        })
        self.assertTrue(is_active_or_grace())
        self.assertTrue(state_dict()["has_ever_paid"])

    def test_reinstalling_does_not_cost_a_payer_their_sticky_bit(self) -> None:
        """A paying customer re-runs the installer. Do not demote them."""
        now = datetime.now(timezone.utc)
        refresh_from_companion("cmVjZWlwdA==", _iso(now + timedelta(days=5)))
        activate_first_month_free(_iso(now))
        self.assertTrue(state_dict()["has_ever_paid"])

    def test_the_free_month_never_sets_the_paid_bit(self) -> None:
        """The zero-denominator trap, asserted directly.

        If has_ever_paid were backfilled from status==active the way the
        Rust side does it, the installer would set it for every trialist
        on day zero, every row in the table would read true, and the rule
        would be inert while looking implemented.
        """
        self._install_days_ago(0)
        self.assertFalse(state_dict()["has_ever_paid"])
        self.assertEqual(state_dict()["status"], STATUS_ACTIVE)

    def test_deleting_expires_at_does_not_buy_a_permanent_trial(self) -> None:
        """Tamper check on the cheapest attack: remove the end date."""
        self._install_days_ago(5)
        state = state_dict()
        state.pop("expires_at", None)
        self._write_raw(state)
        self.assertFalse(is_active_or_grace())

    def test_a_payer_with_an_unreadable_expiry_is_not_locked_out(self) -> None:
        """Same missing field, opposite answer, because they paid."""
        now = datetime.now(timezone.utc)
        refresh_from_companion("cmVjZWlwdA==", _iso(now + timedelta(days=5)))
        state = state_dict()
        state["expires_at"] = "not-a-date"
        self._write_raw(state)
        self.assertTrue(is_active_or_grace())

    def test_the_reader_alone_walks_the_state_without_the_ticker(self) -> None:
        """expire_check is NOT called anywhere in this test.

        The scheduler is a thing that can fail to be loaded. The stored
        status must not be the authority, or we ship this defect again
        the first time a plist fails to bootstrap.
        """
        self._install_days_ago(31)
        self.assertEqual(json.loads(self.state_path.read_text())["status"],
                         STATUS_ACTIVE)
        self.assertFalse(is_active_or_grace())
        self.assertEqual(json.loads(self.state_path.read_text())["status"],
                         STATUS_INACTIVE)

    def test_a_read_only_state_dir_still_expires_the_trial(self) -> None:
        """The decision must not depend on the write-back succeeding."""
        self._install_days_ago(31)
        os.chmod(self.state_path, 0o444)
        os.chmod(self.state_path.parent, 0o555)
        try:
            self.assertFalse(is_active_or_grace())
        finally:
            os.chmod(self.state_path.parent, 0o755)
            os.chmod(self.state_path, 0o644)


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
