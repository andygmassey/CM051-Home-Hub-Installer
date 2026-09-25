#!/usr/bin/env python3
"""An absent HTTP library has not failed, and logging it as one buries the ones that did.

MEASURED on the v1.0.81 walk box, 2026-09-09:

    ~/.ostler/logs/store-auth-shim.log   351 lines
    arm=aiohttp FAILED: ModuleNotFoundError                288
    arm=httpx   FAILED: ModuleNotFoundError                 63
    real patch failures                                      0

One line per arm per process, on a box where nothing uses aiohttp at all. The
module's own comment says the log exists because "the rare case is the one
nobody can currently see". At 351 routine lines to zero real ones, the rare case
is precisely what it hides, and a reader skimming for a problem finds 351 lines
that say FAILED.

An interpreter without the library makes no requests through it, so there is
nothing there to authenticate and nothing to fix. It is recorded in STATUS,
where a diagnostic still reads it, and kept out of the log.

THREE ARMS, and the third is the one that keeps this honest: a REAL patch
failure must still be logged, or this change trades a noisy log for a silent one.
"""
from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHIM = os.path.join(REPO, "lib", "ostler_store_auth.py")


def _load_shim(secrets_dir: str):
    """Import a FRESH copy of the shim with its secrets dir redirected.

    A fresh module per test, because STATUS is module state and a test that
    inherited another's would pass on the wrong evidence.
    """
    os.environ["OSTLER_SECRETS_DIR"] = secrets_dir
    spec = importlib.util.spec_from_file_location(
        "ostler_store_auth_under_test_%d" % len(sys.modules), SHIM
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class ShimLogsOnlyRealFailures(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.secrets = os.path.join(self._tmp.name, "secrets")
        os.makedirs(self.secrets, exist_ok=True)
        self.logfile = os.path.join(self._tmp.name, "logs", "store-auth-shim.log")
        self.mod = _load_shim(self.secrets)

    def tearDown(self):
        self._tmp.cleanup()

    def _log_lines(self):
        if not os.path.exists(self.logfile):
            return []
        with open(self.logfile, encoding="utf-8") as fh:
            return [ln for ln in fh.read().splitlines() if ln.strip()]

    def test_an_absent_library_is_recorded_but_not_logged(self):
        """MUST-MISS on the log, MUST-HIT on STATUS."""
        before = len(self._log_lines())
        self.mod._record("aiohttp", ModuleNotFoundError("No module named 'aiohttp'"))
        self.assertEqual(
            self.mod.STATUS["aiohttp"],
            "not-installed",
            "an absent library must be recorded as not-installed, not as a failure",
        )
        self.assertEqual(
            len(self._log_lines()),
            before,
            "an absent library wrote a log line; that is the 351-line noise this "
            "change exists to remove",
        )

    def test_a_plain_importerror_counts_as_absent_too(self):
        """ModuleNotFoundError is a subclass, but an older arm can raise ImportError."""
        self.mod._record("httpx", ImportError("cannot import name 'Client'"))
        self.assertEqual(self.mod.STATUS["httpx"], "not-installed")
        self.assertEqual(self._log_lines(), [])

    def test_a_real_patch_failure_is_still_logged(self):
        """THE CONTROL. Without it this trades a noisy log for a silent one."""
        self.mod._record("urllib", RuntimeError("could not patch urlopen"))
        self.assertTrue(
            self.mod.STATUS["urllib"].startswith("FAILED:"),
            "a real failure must still read FAILED in STATUS, got %r"
            % self.mod.STATUS["urllib"],
        )
        lines = self._log_lines()
        self.assertEqual(len(lines), 1, "a real failure must be logged: %r" % lines)
        self.assertIn("arm=urllib", lines[0])
        self.assertIn("RuntimeError", lines[0])
        self.assertNotIn(self.secrets, lines[0], "the log must never carry a secret path's contents")

    def test_the_untouched_default_is_still_not_attempted(self):
        """An arm nobody reached reads differently from one that is absent."""
        fresh = _load_shim(self.secrets)
        for arm in ("httpx", "urllib", "aiohttp"):
            self.assertIn(
                fresh.STATUS[arm],
                ("not-attempted", "patched", "not-installed"),
                "unexpected STATUS vocabulary for %s: %r" % (arm, fresh.STATUS[arm]),
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
