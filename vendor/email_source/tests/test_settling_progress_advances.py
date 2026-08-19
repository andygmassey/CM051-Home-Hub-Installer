"""The 'Your emails' setup row must advance while email ingest runs.

THE DEFECT THIS PINS. Measured on the shipped v1.0.36 box, 2026-08-19:
``~/.ostler/state/settling_progress.d/emails.json`` read ``done=707
total=17609`` and had not been written for 27h44m, while the email pipeline
was demonstrably alive (a tick at 19:35 emitted and ingested 8 messages; the
module held 1:05 of CPU). ``install.sh`` writes that shard once at hydrate
time and nothing wrote it again, so the customer's panel showed "Your emails:
just getting started" permanently.

WHY THE FIRST ARM GOES THROUGH ``process_email`` AND NOT THE HELPER. A test
that calls ``_report_email_settling`` directly passes as soon as the function
exists, which says nothing about whether any tick reaches it -- and an
uninvoked writer is precisely what shipped. The arm below stubs the mail
reader and drives the real entry point, so it fails if the call site is
removed even when the helper is perfect.

ARM 3 IS THE ONE THAT STOPS A WRONG FIX. A tick cannot measure the email
backfill, so the tempting shortcut is ``total=done``, which renders as 100%
complete. Arm 3 asserts that a missing total produces NO shard at all.
"""

from __future__ import annotations

import json
import os
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

_HERE = Path(__file__).resolve()
_VENDOR = _HERE.parents[2]
for _p in (str(_VENDOR), str(_VENDOR / "email_source")):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from email_source import pipeline  # noqa: E402


class _StateDir:
    """Point BOTH state-dir resolvers at a temp tree for the duration."""

    def __init__(self, path: Path) -> None:
        self._path = path
        self._saved: dict[str, str | None] = {}

    def __enter__(self) -> Path:
        for key in ("OSTLER_STATE_DIR", "STATE_DIR"):
            self._saved[key] = os.environ.get(key)
        os.environ["OSTLER_STATE_DIR"] = str(self._path)
        os.environ.pop("STATE_DIR", None)
        return self._path

    def __exit__(self, *exc: object) -> None:
        for key, val in self._saved.items():
            if val is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = val


def _shard(root: Path) -> Path:
    return root / "settling_progress.d" / "emails.json"


def _seed_shard(root: Path, *, done: int, total: int) -> Path:
    path = _shard(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(
            {
                "key": "emails",
                "done": done,
                "total": total,
                "needs_source": False,
                "started_at": "2026-08-18T11:55:12+00:00",
                "updated_at": "2026-08-18T11:55:12+00:00",
            }
        )
    )
    return path


def _seed_watermark(root: Path, threads: dict[str, list[str]]) -> None:
    path = root / "email_source_state.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"threads": threads}))


class EmailSettlingProgressAdvances(unittest.TestCase):
    # Three threads, twelve message-ids in total: the number the shard must
    # reach. Deliberately not a round number so an accidental default cannot
    # coincide with it.
    THREADS = {
        "t-1": ["m1", "m2", "m3", "m4", "m5"],
        "t-2": ["m6", "m7", "m8"],
        "t-3": ["m9", "m10", "m11", "m12"],
    }
    EXPECTED_DONE = 12
    SEEDED_TOTAL = 17609

    def test_a_tick_advances_the_shard_via_the_real_entry_point(self) -> None:
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            with _StateDir(root):
                _seed_watermark(root, self.THREADS)
                # Seed BELOW the watermark count on purpose. `done` is kept
                # MONOTONIC by report_settling_progress (_read_existing_done,
                # settling_progress.py:250) so a later, narrower run cannot
                # walk a customer's progress backwards. An earlier draft of
                # this test seeded 707 -- the real box's value -- and expected
                # 12, i.e. asserted a DECREASE. The clamp correctly refused it
                # and the test failed against a working fix.
                #
                # That refusal is load-bearing for the SHIPPED bug, not just
                # for this test: on the v1.0.36 box the installer seeds
                # done=707 while the watermark holds 181, so wiring the tick
                # alone would have been clamped to 707 and the panel would
                # have stayed frozen -- delivered and ineffective. The two
                # numbers are not even the same unit (people vs messages),
                # which is why the install.sh half is a prerequisite.
                seeded = _seed_shard(root, done=5, total=self.SEEDED_TOTAL)
                before = json.loads(seeded.read_text())
                self.assertEqual(before["done"], 5, "control: seed is what we think")

                original = pipeline.read_messages
                pipeline.read_messages = lambda **_kw: []
                try:
                    pipeline.process_email(
                        mail_dir=root / "no-such-mail",
                        pwg_convo_cmd=["true"],
                        dry_run=False,
                    )
                finally:
                    pipeline.read_messages = original

                after = json.loads(seeded.read_text())

            self.assertEqual(
                after["done"],
                self.EXPECTED_DONE,
                "a completed tick must republish 'done' from the watermark; "
                "this is the v1.0.36 defect, where the shard sat at its "
                "install-time value for 27h while ingest ran",
            )
            self.assertEqual(
                after["total"],
                self.SEEDED_TOTAL,
                "the installer-measured backfill size must survive the tick; "
                "recomputing it walks the progress bar backwards",
            )

    def test_the_helper_preserves_total_and_publishes_done(self) -> None:
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            with _StateDir(root):
                seeded = _seed_shard(root, done=0, total=500)
                pipeline._report_email_settling(self.THREADS)
                after = json.loads(seeded.read_text())

        self.assertEqual(after["done"], self.EXPECTED_DONE)
        self.assertEqual(after["total"], 500)

    def test_no_existing_shard_means_no_shard_is_invented(self) -> None:
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            with _StateDir(root):
                target = _shard(root)
                self.assertFalse(target.exists(), "control: nothing seeded")
                pipeline._report_email_settling(self.THREADS)
                created = target.exists()

        self.assertFalse(
            created,
            "with no installer-measured total, the tick must write NOTHING. "
            "Defaulting total to done would render 100% complete, which is a "
            "worse lie than a frozen counter.",
        )

    def test_an_unusable_total_is_refused_rather_than_guessed(self) -> None:
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            with _StateDir(root):
                path = _shard(root)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps({"key": "emails", "done": 4}))
                pipeline._report_email_settling(self.THREADS)
                after = json.loads(path.read_text())

        self.assertEqual(
            after.get("done"),
            4,
            "a shard with no 'total' must be left exactly as found, not "
            "rewritten with a guessed denominator",
        )


if __name__ == "__main__":
    unittest.main()
