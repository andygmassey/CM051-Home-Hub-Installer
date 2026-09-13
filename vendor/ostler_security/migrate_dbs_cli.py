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
    OSTLER_DB_KEY    64-character hex-encoded 256-bit key. Same key the
                     running services use. When it is unset, the key is
                     read from the protected key file instead (see
                     ostler_security.db_key), which is what the installer
                     writes and what `ostler-unlock --install-key-file`
                     restores. One of the two must resolve.
    OSTLER_DB_KEY_FILE
                     Optional. Overrides where that key file lives.
    PWG_HOME         Optional. Defaults to ~/.pwg. Drives the legacy
                     coach DB and memory-corrections paths.
    OSTLER_HOME      Optional. Defaults to ~/.ostler. Drives the
                     two-zone engine-room coach DB path.
    MEMORY_CORRECTIONS_DB
                     Optional. Overrides the memory-corrections DB path,
                     same variable ical-server.py reads.
    WHATSAPP_SESSION_DB
                     Optional. Path to the WhatsApp bridge session
                     DB. If set, included in the default candidate list.

Exit codes:
    0  All migrations succeeded or were skipped (already encrypted).
    1  At least one migration failed (see summary).
    2  No key could be resolved, or invalid input.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from ostler_security.database import HAS_SQLCIPHER, migrate_to_encrypted


def _default_candidates() -> list[Path]:
    """Return the default list of DB paths to consider migrating.

    🔴 THIS LIST WAS MISSING TWO OF THE THREE DATABASES THE PRODUCT
    ACTUALLY ENCRYPTS, WHICH MADE THE UPGRADE PATH A SILENT NO-OP.

    A migration CLI that names the wrong files does not report an error.
    It prints "0 target(s)" or a short clean summary and exits 0, which
    reads as "nothing needed doing". Every database it did not name
    stays plaintext, and the run that was supposed to fix that is the
    evidence offered that it was fixed.

    Measured against the shipped readers on this tree:

      ical-server.py:502   COACH_DB = ${PWG_HOME:-~/.pwg}/coach/observations.db
                           ^ the only one this list ever had
      ical-server.py:574   MEMORY_CORRECTIONS_DB, env-overridable,
                           default ${PWG_HOME:-~/.pwg}/memory/corrections.db
      cm048 ostler_paths.py:47
                           coach_db_path() = ~/.ostler/coach/observations.db

    The last one is the two-zone engine-room path CM048 moved to; the
    ~/.pwg entry is its pre-migration home. Both are listed because an
    install can carry either, and a file that is not there is reported
    "missing (skipped)" rather than failing the run.

    Env overrides mirror the services exactly (PWG_HOME, OSTLER_HOME,
    MEMORY_CORRECTIONS_DB) so a non-default install home moves the
    migration and the readers together instead of apart.

    Paths that don't exist on disk are reported as missing by the main
    loop rather than dropped here: "we looked and it was not there" and
    "we never looked" must not print the same.
    """
    pwg_home = Path(os.environ.get("PWG_HOME", os.path.expanduser("~/.pwg")))
    ostler_home = Path(
        os.environ.get("OSTLER_HOME", os.path.expanduser("~/.ostler"))
    )
    candidates = [
        # ical-server.py:502
        pwg_home / "coach" / "observations.db",
        # cm048 ostler_paths.coach_db_path(), the two-zone engine room
        ostler_home / "coach" / "observations.db",
    ]

    # ical-server.py:574. Same env var name and same default, so an
    # install that moved it is followed rather than missed.
    corrections = os.environ.get("MEMORY_CORRECTIONS_DB", "").strip()
    candidates.append(
        Path(corrections).expanduser()
        if corrections
        else pwg_home / "memory" / "corrections.db"
    )

    whatsapp_db = os.environ.get("WHATSAPP_SESSION_DB", "").strip()
    if whatsapp_db:
        candidates.append(Path(whatsapp_db).expanduser())

    # De-duplicate while preserving order: PWG_HOME and OSTLER_HOME can
    # legitimately be pointed at the same directory, and migrating one
    # file twice would report the second pass as "already encrypted",
    # which is true but reads like a second database was checked.
    seen: set[str] = set()
    unique: list[Path] = []
    for path in candidates:
        marker = str(path)
        if marker in seen:
            continue
        seen.add(marker)
        unique.append(path)
    return unique


def _resolve_key() -> str | None:
    """Return the encryption key, or None if none could be resolved.

    Delegates to the shared resolver so this CLI and the two services
    that open the databases agree on where the key comes from. It used
    to read OSTLER_DB_KEY directly, which meant the operator had to
    know the key and type it on the command line, on a box where
    nothing had ever set that variable.

    Import is local rather than top-of-module so an older vendored
    ostler_security without db_key still runs this CLI on the
    environment variable alone. The migration is the tool an operator
    reaches for when things are already wrong; it must not be the thing
    that cannot start.
    """
    try:
        from ostler_security.db_key import resolve_db_key
    except ImportError:
        return os.environ.get("OSTLER_DB_KEY") or None
    return resolve_db_key().key


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
    if not key and not args.dry_run:
        print(
            "ERROR: no database key could be resolved. Set OSTLER_DB_KEY to "
            "the 64-character hex key the running services use, or recover it "
            "and install it for them with `ostler-unlock --install-key-file`, "
            "then re-run.",
            file=sys.stderr,
        )
        return 2

    # A DRY RUN NEEDS NO KEY, AND REQUIRING ONE MADE IT USELESS WHERE IT WAS
    # MOST NEEDED.
    #
    # --dry-run only opens each candidate with plain sqlite3 to see whether it
    # is still plaintext. It never decrypts, never writes, and never touches
    # the key. But the key check above ran FIRST and unconditionally, so the
    # one box that most needs the answer -- an existing install with no key
    # delivered, every database readable -- was the one box that could not
    # ask the question. It got exit 2 and no list.
    #
    # The live path still demands a key, one branch up. Nothing is weakened:
    # what changes is that "which of my databases are readable right now" is
    # now answerable by someone who does not hold the key, which is the whole
    # population this matters to.
    if not key:
        print(
            "NOTE: no database key is available, so this is a report only. "
            "Nothing below can be migrated until a key is delivered "
            "(ostler-unlock --install-key-file).",
            file=sys.stderr,
        )

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
    # A MACHINE-READABLE PLAINTEXT COUNT, because a caller that has to parse
    # the table above to learn the one number that matters will parse it
    # wrong. install.sh reads this line on a re-run it cannot repair, to say
    # how many databases are readable on disk RIGHT NOW rather than the
    # vaguer "your databases are unencrypted".
    plaintext = sum(
        1 for _, status in results
        if status in ("would migrate", "migrated")
    )
    print(f"  {len(results)} target(s), {failed} failed")
    print(f"PLAINTEXT_REMAINING={plaintext if args.dry_run else 0}")

    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
