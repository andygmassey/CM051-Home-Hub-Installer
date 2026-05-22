"""Migrate Ostler's plaintext SQLite databases to SQLCipher-encrypted form.

Run this once on an existing install where databases were created
under the pre-fix code paths (silent plaintext fallback). For each
candidate database, this CLI:

  1. Checks the file exists and is plaintext (encrypted DBs are skipped).
  2. Calls ostler_security.database.migrate_to_encrypted, which:
     - Dumps every row to SQL via sqlite3.iterdump.
     - Creates a fresh SQLCipher DB at <path>.encrypted.
     - Replays the dump under the user's OSTLER_DB_KEY.
     - Verifies the encrypted copy opens with the right key.
     - Atomically replaces the original.
     - Securely overwrites and deletes the temporary plaintext backup.
  3. Reports a per-DB summary table at the end.

The migration function is the source of truth for the actual logic;
this CLI is the user-facing wrapper around it.

Usage:
    OSTLER_DB_KEY=<64-hex> python -m ostler_security.migrate_dbs_cli
    OSTLER_DB_KEY=<64-hex> python -m ostler_security.migrate_dbs_cli --dry-run
    OSTLER_DB_KEY=<64-hex> python -m ostler_security.migrate_dbs_cli \
        --db ~/.pwg/coach/observations.db \
        --db ~/.pwg/whatsapp-session.db

Environment:
    OSTLER_DB_KEY    REQUIRED. 64-character hex-encoded 256-bit key.
                     Same key used by the running services (see
                     ostler_security.database for derivation).
    PWG_HOME         Optional. Defaults to ~/.pwg. Drives the default
                     coach DB path.
    WHATSAPP_SESSION_DB
                     Optional. Path to the WhatsApp bridge session
                     DB. If set, included in the default candidate list.

Exit codes:
    0  All migrations succeeded or were skipped (already encrypted).
    1  At least one migration failed (see summary).
    2  No OSTLER_DB_KEY set, or invalid input.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from ostler_security.database import HAS_SQLCIPHER, migrate_to_encrypted


def _default_candidates() -> list[Path]:
    """Return the default list of DB paths to consider migrating.

    Path resolution mirrors the runtime services:
      - PWG_HOME defaults to ~/.pwg, matching ical-server.py and
        CM048's settings.
      - The WhatsApp session DB has no fixed default; it is picked up
        from WHATSAPP_SESSION_DB only.

    Paths that don't exist on disk are silently dropped here; the
    main loop logs them as "missing" if the user passes them
    explicitly via --db.
    """
    pwg_home = Path(os.environ.get("PWG_HOME", os.path.expanduser("~/.pwg")))
    candidates = [
        pwg_home / "coach" / "observations.db",
    ]
    whatsapp_db = os.environ.get("WHATSAPP_SESSION_DB", "").strip()
    if whatsapp_db:
        candidates.append(Path(whatsapp_db).expanduser())
    return candidates


def _resolve_key() -> str | None:
    """Return the encryption key from env, or None if unset."""
    return os.environ.get("OSTLER_DB_KEY") or None


def _is_plaintext(db_path: Path) -> bool:
    """Best-effort check: opens the file with plain sqlite3.

    A plaintext DB succeeds; an encrypted DB raises sqlite3.DatabaseError
    when sqlite_master is queried. The migrate_to_encrypted function
    does the same check internally; we duplicate it here so --dry-run
    can report what would happen without invoking migration.
    """
    import sqlite3

    if not db_path.exists():
        return False
    try:
        conn = sqlite3.connect(str(db_path))
        conn.execute("SELECT count(*) FROM sqlite_master")
        conn.close()
        return True
    except sqlite3.DatabaseError:
        return False


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Migrate Ostler plaintext SQLite databases to SQLCipher.",
    )
    parser.add_argument(
        "--db",
        action="append",
        type=Path,
        help="Path to a database file to migrate. Repeatable. "
             "If omitted, the default candidate list is used "
             "(coach DB + WHATSAPP_SESSION_DB if set).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report what would be migrated without writing anything.",
    )
    args = parser.parse_args(argv)

    if not HAS_SQLCIPHER:
        print(
            "ERROR: sqlcipher3 is not installed in this Python environment. "
            "Install it first: pip install sqlcipher3",
            file=sys.stderr,
        )
        return 2

    key = _resolve_key()
    if not key:
        print(
            "ERROR: OSTLER_DB_KEY env var not set. "
            "Set it to the same 64-character hex key the running services use, "
            "then re-run.",
            file=sys.stderr,
        )
        return 2

    targets: list[Path]
    if args.db:
        targets = [Path(p).expanduser() for p in args.db]
    else:
        targets = _default_candidates()

    if not targets:
        print("No candidate databases to migrate.", file=sys.stderr)
        return 0

    # Header
    print(f"Ostler plaintext-to-encrypted migration "
          f"({'dry run' if args.dry_run else 'live'})")
    print("=" * 60)

    results: list[tuple[Path, str]] = []
    for db_path in targets:
        print(f"  {db_path}")

        if not db_path.exists():
            results.append((db_path, "missing (skipped)"))
            print("    -> missing on disk; skipped")
            continue

        if not _is_plaintext(db_path):
            results.append((db_path, "already encrypted (skipped)"))
            print("    -> already encrypted; skipped")
            continue

        if args.dry_run:
            results.append((db_path, "would migrate"))
            print("    -> WOULD migrate (dry run)")
            continue

        try:
            ok = migrate_to_encrypted(db_path, key, backup=True)
        except Exception as exc:
            results.append((db_path, f"FAILED: {exc}"))
            print(f"    -> FAILED: {exc}")
            continue

        if ok:
            results.append((db_path, "migrated"))
            print("    -> migrated successfully")
        else:
            results.append((db_path, "skipped (already encrypted or no SQLCipher)"))
            print("    -> skipped (already encrypted or no SQLCipher)")

    # Summary
    print("")
    print("Summary:")
    print("-" * 60)
    failed = 0
    for db_path, status in results:
        marker = "FAIL" if status.startswith("FAILED") else "ok  "
        if marker == "FAIL":
            failed += 1
        print(f"  [{marker}] {status:<40s} {db_path}")
    print("-" * 60)
    print(f"  {len(results)} target(s), {failed} failed")

    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
