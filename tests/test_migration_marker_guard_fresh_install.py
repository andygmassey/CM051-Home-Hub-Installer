#!/usr/bin/env python3
"""Migration-marker guard: fresh install must NOT drop a false sentinel.

HR015 #233. Andy's freshly-wiped 16GB Mini (2026-07-31) showed
``~/.ostler/.migrated-from-pwg-dotdir`` present on a box where
``~/.pwg/`` had never existed. The sentinel body reads
``Migrated from ~/.pwg/ on <ts>`` -- a claim of migration on a box
where nothing was migrated.

Beyond the cosmetic lie, a false sentinel is a correctness bug: the
first check in ``migrate_pwg_dotdir_if_needed`` short-circuits on
``sentinel.exists()``. If the customer later restores a ``~/.pwg/``
from another machine, that legitimate migration is silently skipped
forever.

This test exercises the migration helper against a mock env where
neither ``~/.pwg/`` nor ``~/.ostler/`` exists (the fresh-install
shape) and asserts:

  1. The migration returns ``status="fresh_install"``.
  2. The sentinel file is NOT created.
  3. No stale lockfile is left behind.

Also covers the positive case: a mock env WITH a ``~/.pwg/`` tree
runs through the migration, ends up ``status="migrated"``, and DOES
write the sentinel.

Network-free, dependency-free (stdlib only).
"""
from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CM048_SRC = REPO_ROOT / "vendor" / "cm048_pipeline" / "src"
if not CM048_SRC.is_dir():
    raise SystemExit(
        f"vendored CM048 src missing: {CM048_SRC} (broken vendor layout)"
    )
sys.path.insert(0, str(CM048_SRC))

import ostler_paths  # noqa: E402  (path fiddled above)


class FreshInstallMustNotWriteSentinel(unittest.TestCase):
    """HR015 #233 regression: fresh install must leave no false marker."""

    def setUp(self) -> None:
        self._tmp = Path(tempfile.mkdtemp(prefix="ostler-migration-guard-"))
        self.legacy = self._tmp / ".pwg"
        self.new = self._tmp / ".ostler"
        self.conversations = self._tmp / "Documents" / "Ostler" / "Conversations"

    def tearDown(self) -> None:
        shutil.rmtree(self._tmp, ignore_errors=True)

    def test_fresh_install_leaves_no_sentinel(self) -> None:
        # Precondition: neither tree exists.
        self.assertFalse(self.legacy.exists())
        self.assertFalse(self.new.exists())

        outcome = ostler_paths.migrate_pwg_dotdir_if_needed(
            legacy_root=self.legacy,
            new_root=self.new,
            new_conversations_root=self.conversations,
        )

        self.assertEqual(outcome.status, "fresh_install")

        sentinel = self.new / ostler_paths.MIGRATION_SENTINEL_NAME
        self.assertFalse(
            sentinel.exists(),
            f"HR015 #233: fresh install wrote a false migration marker at "
            f"{sentinel}. The sentinel claims 'Migrated from ~/.pwg/' but "
            f"no ~/.pwg/ ever existed on this box.",
        )

        lockfile = self.new / ostler_paths.MIGRATION_LOCKFILE_NAME
        self.assertFalse(
            lockfile.exists(),
            f"stale migration lockfile left at {lockfile}",
        )

    def test_repeat_call_stays_fresh_install_and_stays_marker_free(self) -> None:
        # A second invocation on a still-fresh box must ALSO stay
        # marker-free. If a re-entrant caller wrote the sentinel on
        # the second try, we'd be back to the same false-marker bug.
        for _ in range(3):
            outcome = ostler_paths.migrate_pwg_dotdir_if_needed(
                legacy_root=self.legacy,
                new_root=self.new,
                new_conversations_root=self.conversations,
            )
            self.assertEqual(outcome.status, "fresh_install")

        sentinel = self.new / ostler_paths.MIGRATION_SENTINEL_NAME
        self.assertFalse(sentinel.exists())

    def test_real_migration_still_writes_sentinel(self) -> None:
        # Positive case: an actual ~/.pwg/ install DOES get a
        # sentinel after the migration completes. We only assert
        # the outer contract (status + sentinel body + backup);
        # detailed subdir routing is exercised elsewhere in the
        # CM048 test suite and depends on Path.home() lookups
        # this shim cannot easily monkey-patch.
        (self.legacy / "processing").mkdir(parents=True)
        (self.legacy / "processing" / "marker.txt").write_text("hi\n")

        outcome = ostler_paths.migrate_pwg_dotdir_if_needed(
            legacy_root=self.legacy,
            new_root=self.new,
            new_conversations_root=self.conversations,
        )

        self.assertEqual(outcome.status, "migrated")
        self.assertIsNotNone(
            outcome.backup_path,
            "migration completed without recording a backup path",
        )

        sentinel = self.new / ostler_paths.MIGRATION_SENTINEL_NAME
        self.assertTrue(sentinel.exists(), "sentinel missing after real migration")
        body = sentinel.read_text(encoding="utf-8")
        self.assertIn("Migrated from ~/.pwg/", body)

        # Sentinel plus moved payload => idempotent second call
        # short-circuits without touching anything.
        outcome2 = ostler_paths.migrate_pwg_dotdir_if_needed(
            legacy_root=self.legacy,
            new_root=self.new,
            new_conversations_root=self.conversations,
        )
        self.assertEqual(outcome2.status, "already_migrated")


if __name__ == "__main__":
    unittest.main(verbosity=2)
