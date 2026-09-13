#!/usr/bin/env python3
"""The database key must reach the services, and the databases must come out encrypted.

WHAT WENT WRONG
===============

install.sh minted a DEK. Three consumers read it, all from the
``OSTLER_DB_KEY`` environment variable, and nothing anywhere set that
variable. Measured across the tree with a positive control on the same
search shape:

    OSTLER_DB_KEY                  17 mentions, 3 readers, 0 setters
    OSTLER_AI_CONVERSATIONS_DIR    found being SET in a rendered plist
    OSTLER_AI_CONV_GIST_PRIVACY    found being SET in a rendered plist

So the setter query worked and there was nothing to find. Both services
took their plaintext fallback on every install, one line after the
installer printed "Databases encrypted".

WHY THIS FILE DOES NOT READ A PLIST
===================================

The tempting test is "the LaunchAgent plist now sets the key, and here is
a grep that finds it". That is still the producer side. A plist entry
proves a variable is set; it proves nothing about a database.

So every arm below that matters ends at the BYTES ON DISK: the file does
not start with the SQLite magic, and a canary string written through the
real service is nowhere in the raw file. That assertion cannot pass while
the bug is present, and every arm that makes it is paired with a control
that produces a plaintext file and finds the canary, so a passing arm is
never a broken reader.

AND THE UPGRADE PATH, WHICH IS WHERE A CLEAN-INSTALL FIX HIDES
==============================================================

Delivering the key from now on does not encrypt one byte that already
exists. Every box installed before the fix holds plaintext databases. A
test that only covers a fresh install goes green while every existing
customer stays readable, which is the same defect wearing the fix's
clothes. Arm 6 seeds plaintext databases at the paths the shipped
services actually use, runs the real ostler-migrate-dbs, and checks the
bytes afterwards, with a control file OUTSIDE the candidate list that
must STILL be plaintext so a migration that silently touched nothing
cannot pass.

Exit codes: 0 all arms held, 1 an arm failed, 2 CANNOT-RUN.
"""
from __future__ import annotations

import importlib
import importlib.util
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

RC_OK = 0
RC_FAIL = 1
RC_CANNOT_RUN = 2

FAILURES: list[str] = []
CHECKS = 0

SQLITE_MAGIC = b"SQLite format 3\x00"
KEY_HEX = "3f" * 32


def ok(label: str) -> None:
    global CHECKS
    CHECKS += 1
    print(f"  [PASS] {label}")


def bad(label: str) -> None:
    global CHECKS
    CHECKS += 1
    FAILURES.append(label)
    print(f"  [FAIL] {label}", file=sys.stderr)


def check(condition: bool, label: str) -> bool:
    if condition:
        ok(label)
    else:
        bad(label)
    return bool(condition)


def cannot_run(why: str) -> None:
    print("", file=sys.stderr)
    print(f"CANNOT-RUN: {why}", file=sys.stderr)
    print("  NOTHING was checked. This is not a pass.", file=sys.stderr)
    raise SystemExit(RC_CANNOT_RUN)


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def is_plaintext_sqlite(path: Path) -> bool:
    return path.read_bytes().startswith(SQLITE_MAGIC)


def write_key_file(home: Path, key: str = KEY_HEX) -> Path:
    sec = home / "security"
    sec.mkdir(parents=True, exist_ok=True)
    sec.chmod(0o700)
    key_file = sec / "db_key"
    key_file.write_text(key + "\n")
    key_file.chmod(0o600)
    return key_file


def run_module(pkg_paths: list, module: str, args: list, env_extra: dict):
    env = dict(os.environ)
    env["PYTHONPATH"] = os.pathsep.join(
        [str(p) for p in pkg_paths] + [env.get("PYTHONPATH", "")]
    )
    env.update(env_extra)
    return subprocess.run(
        [sys.executable, "-m", module] + args,
        env=env, capture_output=True, text=True,
    )


def load_isolated(name: str, path: Path):
    """Import a module file fresh, under its own name.

    The service modules read the environment AT IMPORT TIME, which is the
    behaviour under test: launchd hands a job its environment once. Each
    arm therefore needs its own import against its own environment, so
    the module is evicted from sys.modules and loaded again rather than
    reused.
    """
    for key in list(sys.modules):
        if key == name or key.startswith(name + "."):
            del sys.modules[key]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def load_package_module(dotted: str):
    """Import a module that uses RELATIVE imports, fresh, each time.

    CM048's ingest.py does `from .turtle_escape import ...`, so it cannot
    be loaded from a file path in isolation; it has to come in as part of
    its package. Same requirement as the file loader above: the module
    reads the environment at import, so every arm needs its own import,
    which means evicting the whole package first.
    """
    top = dotted.split(".")[0]
    for key in list(sys.modules):
        if key == top or key.startswith(top + "."):
            del sys.modules[key]
    importlib.invalidate_caches()
    return importlib.import_module(dotted)


def posture_for(home: Path, service: str) -> dict:
    marker = home / "security-posture" / f"{service}.json"
    if not marker.exists():
        return {}
    try:
        return json.loads(marker.read_text())
    except (OSError, ValueError):
        return {}


def main() -> int:
    work_dir = tempfile.mkdtemp(prefix="ostler-db-key-delivery-")
    work = Path(work_dir)
    root = repo_root()

    # The package roots the shipped services are staged under on a real
    # install. ostler_security is pip-installed into the Hub venv;
    # pwg_privacy and identity_resolver are staged beside ical-server.
    sec_site = work / "site"
    shutil.copytree(
        root / "vendor" / "ostler_security",
        sec_site / "ostler_security",
        ignore=shutil.ignore_patterns("tests", "bin", "__pycache__"),
    )
    cm041_root = root / "vendor" / "cm041"
    cm048_root = root / "vendor" / "cm048_pipeline"
    ical_src = cm041_root / "assistant_api" / "ical-server.py"

    for required in (ical_src, cm048_root / "src" / "ingest.py"):
        if not required.exists():
            cannot_run(f"{required} is not in this tree; the consumer it "
                       "guards cannot be exercised")

    sys.path.insert(0, str(sec_site))
    sys.path.insert(0, str(cm041_root))
    sys.path.insert(0, str(cm048_root))

    try:
        try:
            from ostler_security import db_key
            from ostler_security.database import HAS_SQLCIPHER, get_db_connection
        except ImportError as exc:
            cannot_run(f"could not import ostler_security ({exc})")

        if not HAS_SQLCIPHER:
            cannot_run(
                "sqlcipher3 is not installed in this interpreter. Every "
                "on-disk arm below would compare a plaintext file against a "
                "plaintext file and pass for the wrong reason."
            )

        # ── ARM 1: the resolver, order and sources ───────────────────
        home1 = work / "h1"
        key_file = write_key_file(home1)
        os.environ.pop("OSTLER_DB_KEY", None)
        os.environ["OSTLER_DB_KEY_FILE"] = str(key_file)
        resolved = db_key.resolve_db_key()
        check(
            resolved.key == KEY_HEX and resolved.source == db_key.SOURCE_KEY_FILE,
            "arm 1: with no environment key, the resolver reads the "
            "protected key file and says so",
        )
        os.environ["OSTLER_DB_KEY"] = "ff" * 32
        resolved_env = db_key.resolve_db_key()
        check(
            resolved_env.key == "ff" * 32
            and resolved_env.source == db_key.SOURCE_ENV,
            "arm 1: an explicit OSTLER_DB_KEY still wins over the file, so "
            "ostler-migrate-dbs and every existing harness behave as before",
        )
        os.environ.pop("OSTLER_DB_KEY", None)

        # ── ARM 2: it fails CLOSED on a key another account can read ──
        loose_file = write_key_file(work / "h2")
        loose_file.chmod(0o644)
        loose = db_key.read_key_file(loose_file)
        check(
            loose.key is None
            and loose.reason == db_key.REASON_KEY_FILE_UNSAFE_MODE,
            "arm 2: a 0644 key file is REFUSED, with a reason distinct from "
            f"'no key' (got {loose.reason!r})",
        )
        loose_file.chmod(0o600)
        loose_file.parent.chmod(0o755)
        loose_dir = db_key.read_key_file(loose_file)
        check(
            loose_dir.key is None
            and loose_dir.reason == db_key.REASON_KEY_FILE_UNSAFE_DIR,
            "arm 2: a 0600 key file inside a 0755 directory is refused too, "
            f"because the file can be replaced wholesale (got {loose_dir.reason!r})",
        )
        loose_file.parent.chmod(0o700)
        absent = db_key.read_key_file(work / "h2" / "security" / "nope")
        check(
            absent.key is None and absent.reason == db_key.REASON_NO_KEY,
            "arm 2 (control): a genuinely absent key file reports 'no_key', "
            "so 'nothing configured' and 'configured but unsafe' never reach "
            "Doctor as the same string",
        )

        # ── ARM 3: the real ical-server, with and without the key ────
        home3 = work / "h3"
        key3 = write_key_file(home3)
        corrections = home3 / "corrections.db"
        env3 = {
            "OSTLER_HOME": str(home3),
            "OSTLER_DB_KEY_FILE": str(key3),
            "MEMORY_CORRECTIONS_DB": str(corrections),
            "PWG_HOME": str(home3 / "pwg"),
            "USER_ID": "regression",
        }
        os.environ.update(env3)
        ical = load_isolated("icalserver_keyed", ical_src)
        check(
            getattr(ical, "_ENCRYPTION_KEY", None) == KEY_HEX
            and getattr(ical, "_KEY_SOURCE", None) == db_key.SOURCE_KEY_FILE,
            "arm 3: the REAL ical-server module resolves the key from the "
            "protected file at import time",
        )
        posture = posture_for(home3, "ical-server")
        check(
            posture.get("encryption") == "enabled"
            and posture.get("key_source") == db_key.SOURCE_KEY_FILE,
            f"arm 3: it records an ENABLED security posture for Doctor "
            f"(marker: {posture.get('encryption')!r}/{posture.get('key_source')!r})",
        )

        # ── ARM 4: THE BYTES. The service's own database, encrypted ──
        CANARY = "CANARY-ical-server-8b71d4e2"
        conn = ical._memory_corrections_connect()
        conn.execute("CREATE TABLE IF NOT EXISTS probe (body TEXT)")
        conn.execute("INSERT INTO probe VALUES (?)", (CANARY,))
        conn.commit()
        conn.close()
        blob = corrections.read_bytes()
        check(
            not blob.startswith(SQLITE_MAGIC),
            "arm 4: the database the REAL ical-server opened and wrote does "
            "not carry the SQLite magic header on disk",
        )
        check(
            CANARY.encode() not in blob,
            f"arm 4: the canary is absent from all {len(blob)} bytes of that "
            "file. This is the assertion that cannot pass while the bug is "
            "present",
        )

        # ── ARM 4b: CONTROL. The same service with no key ────────────
        # Without this the arm above could be passing because the canary
        # was never written, or because the reader is broken.
        home4 = work / "h4"
        home4.mkdir(parents=True, exist_ok=True)
        corrections_plain = home4 / "corrections.db"
        os.environ.update({
            "OSTLER_HOME": str(home4),
            "MEMORY_CORRECTIONS_DB": str(corrections_plain),
            "PWG_HOME": str(home4 / "pwg"),
        })
        os.environ["OSTLER_DB_KEY_FILE"] = str(home4 / "security" / "db_key")
        ical_plain = load_isolated("icalserver_keyless", ical_src)
        check(
            getattr(ical_plain, "_ENCRYPTION_KEY", "<absent>") is None,
            "arm 4b (control): with no key file the same module resolves no "
            "key, which is the state every shipped install was in",
        )
        conn = ical_plain._memory_corrections_connect()
        conn.execute("CREATE TABLE IF NOT EXISTS probe (body TEXT)")
        conn.execute("INSERT INTO probe VALUES (?)", (CANARY,))
        conn.commit()
        conn.close()
        blob_plain = corrections_plain.read_bytes()
        check(
            blob_plain.startswith(SQLITE_MAGIC)
            and CANARY.encode() in blob_plain,
            "arm 4b (control): that unkeyed run produces a plaintext SQLite "
            "file with the canary readable in it, so arm 4 is a measurement "
            "and this test can tell the two apart",
        )
        posture_plain = posture_for(home4, "ical-server")
        check(
            posture_plain.get("encryption") == "disabled"
            and posture_plain.get("reason") == db_key.REASON_NO_KEY,
            "arm 4b (control): and the posture marker says disabled/no_key "
            "rather than staying silent",
        )

        # ── ARM 5: the real CM048 writer, to the bytes ───────────────
        # CM048 had a SECOND break the environment variable could not fix:
        # the coach write read its key from
        # getattr(settings, 'encryption_key_hex', None), a field Settings
        # has never had, so the encrypted branch was unreachable even with
        # OSTLER_DB_KEY set.
        CM048_CANARY = "CANARY-cm048-coach-1d93f60a"
        home5 = work / "h5"
        key5 = write_key_file(home5)
        os.environ.update({
            "OSTLER_HOME": str(home5),
            "OSTLER_DB_KEY_FILE": str(key5),
        })
        ingest = load_package_module("src.ingest")
        # getattr, not attribute access: a tree that reverts the consumer
        # wiring has no _ENCRYPTION_KEY at all, and an AttributeError
        # traceback is a crash rather than a verdict. A regression must
        # report as a named FAIL, not as a stack trace the reader has to
        # interpret. Measured: against the pre-fix cm048 this arm raised
        # instead of failing, which killed every arm after it.
        cm048_key = getattr(ingest, "_ENCRYPTION_KEY", "<no _ENCRYPTION_KEY symbol>")
        check(
            cm048_key == KEY_HEX,
            "arm 5: the REAL CM048 ingest module resolves the key at import "
            f"(module-level key: {'set' if cm048_key == KEY_HEX else cm048_key!r})",
        )

        class _Settings:
            """The minimum surface _write_coach touches.

            Deliberately WITHOUT an encryption_key_hex attribute, which is
            the shape every real install has: the getattr that used to
            decide the branch returns None here, exactly as it does in
            production, so this arm proves the fallback is what carries
            the key rather than a field the test invented.
            """

            def __init__(self, db_path: Path):
                self.coach_db_path = db_path
                self.user_id = "regression"

        state_dir = home5 / "state"
        state_dir.mkdir(parents=True, exist_ok=True)
        (state_dir / "04_coaching.json").write_text(json.dumps({
            "observed_at": "2026-01-01T00:00:00+00:00",
            "conversation_type": CM048_CANARY,
            "tone": "direct",
        }))
        coach_db = home5 / "coach" / "observations.db"
        written = ingest._write_coach(
            state_dir, "conv-regression", _Settings(coach_db), False,
        )
        check(
            written == 1 and coach_db.exists(),
            "arm 5: the real writer ran and produced the coach database",
        )
        coach_blob = coach_db.read_bytes()
        check(
            not coach_blob.startswith(SQLITE_MAGIC)
            and CM048_CANARY.encode() not in coach_blob,
            f"arm 5: that database is encrypted on disk and the canary is "
            f"absent from all {len(coach_blob)} bytes",
        )

        # ── ARM 5b: CONTROL for arm 5 ───────────────────────────────
        home5b = work / "h5b"
        home5b.mkdir(parents=True, exist_ok=True)
        os.environ.update({
            "OSTLER_HOME": str(home5b),
            "OSTLER_DB_KEY_FILE": str(home5b / "security" / "db_key"),
        })
        ingest_plain = load_package_module("src.ingest")
        coach_db_plain = home5b / "coach" / "observations.db"
        state_dir_b = home5b / "state"
        state_dir_b.mkdir(parents=True, exist_ok=True)
        shutil.copy(state_dir / "04_coaching.json", state_dir_b / "04_coaching.json")
        ingest_plain._write_coach(
            state_dir_b, "conv-regression", _Settings(coach_db_plain), False,
        )
        plain_blob = coach_db_plain.read_bytes()
        check(
            plain_blob.startswith(SQLITE_MAGIC)
            and CM048_CANARY.encode() in plain_blob,
            "arm 5b (control): with no key the same writer produces plaintext "
            "with the canary readable, so arm 5 is not vacuous",
        )

        # ── ARM 6: THE UPGRADE PATH ─────────────────────────────────
        # Boxes that already exist hold plaintext databases. Seed them at
        # the paths the shipped readers actually use, then run the real
        # migration CLI with ONLY the key file set, the way an installer
        # or a customer would.
        UPGRADE_CANARY = "CANARY-legacy-plaintext-6c04ab19"
        home6 = work / "h6"
        key6 = write_key_file(home6)
        pwg_home = work / "h6-pwg"

        legacy = {
            "ical coach (PWG_HOME/coach/observations.db)":
                pwg_home / "coach" / "observations.db",
            "cm048 coach (OSTLER_HOME/coach/observations.db)":
                home6 / "coach" / "observations.db",
            "memory corrections (PWG_HOME/memory/corrections.db)":
                pwg_home / "memory" / "corrections.db",
        }
        # The control file: a plaintext database the migration is NOT
        # asked about. If a broken migration touches nothing and the arms
        # above still passed, this one would look identical to them; it
        # must come out STILL plaintext for the arms to mean anything.
        untouched = work / "h6-elsewhere" / "not-a-candidate.db"

        for path in list(legacy.values()) + [untouched]:
            path.parent.mkdir(parents=True, exist_ok=True)
            conn = sqlite3.connect(str(path))
            conn.execute("CREATE TABLE legacy (body TEXT)")
            conn.execute("INSERT INTO legacy VALUES (?)", (UPGRADE_CANARY,))
            conn.commit()
            conn.close()

        seeded_plaintext = [
            name for name, path in legacy.items() if not is_plaintext_sqlite(path)
        ]
        if seeded_plaintext:
            cannot_run(
                "the seeded 'legacy' databases are not plaintext to begin "
                f"with ({seeded_plaintext}). The migration would have nothing "
                "to do and the arm would pass without migrating anything."
            )
        ok("arm 6 (precondition): all three legacy databases are plaintext "
           "before the migration, with the canary readable in each")

        migration = run_module(
            [sec_site], "ostler_security.migrate_dbs_cli", [],
            {
                "OSTLER_DB_KEY_FILE": str(key6),
                "OSTLER_HOME": str(home6),
                "PWG_HOME": str(pwg_home),
                # Deliberately NOT set. The whole point is that the
                # operator does not have to know the key.
                "OSTLER_DB_KEY": "",
                # Cleared so the DEFAULT memory-corrections path is what
                # gets exercised. Earlier arms set this variable in this
                # process's own environment, and run_module inherits it;
                # leaving it would migrate arm 4's database and report a
                # green for a file this arm never seeded. That is the
                # "passed for a reason you did not intend" shape, and it
                # is how this arm failed on its first run.
                "MEMORY_CORRECTIONS_DB": "",
            },
        )
        check(
            migration.returncode == 0,
            f"arm 6: the real ostler-migrate-dbs ran with only the key FILE "
            f"available and exited 0 (rc={migration.returncode})",
        )
        if migration.returncode != 0:
            print(migration.stdout, file=sys.stderr)
            print(migration.stderr, file=sys.stderr)

        for name, path in legacy.items():
            blob = path.read_bytes()
            check(
                not blob.startswith(SQLITE_MAGIC)
                and UPGRADE_CANARY.encode() not in blob,
                f"arm 6: {name} is encrypted on disk after the migration and "
                "the canary is gone from its bytes",
            )
            try:
                conn = get_db_connection(path, KEY_HEX)
                rows = conn.execute("SELECT body FROM legacy").fetchall()
                conn.close()
                recovered = [r[0] for r in rows]
            except Exception as exc:
                recovered = [f"<{exc.__class__.__name__}>"]
            check(
                recovered == [UPGRADE_CANARY],
                f"arm 6: and the row survives, readable with the delivered "
                f"key (got {recovered!r})",
            )

        untouched_blob = untouched.read_bytes()
        check(
            untouched_blob.startswith(SQLITE_MAGIC)
            and UPGRADE_CANARY.encode() in untouched_blob,
            "arm 6 (control): a plaintext database OUTSIDE the candidate list "
            "is still plaintext, so the arms above are reporting migration "
            "and not a byte-check that passes on everything",
        )

        rerun = run_module(
            [sec_site], "ostler_security.migrate_dbs_cli", [],
            {
                "OSTLER_DB_KEY_FILE": str(key6),
                "OSTLER_HOME": str(home6),
                "PWG_HOME": str(pwg_home),
                "OSTLER_DB_KEY": "",
            },
        )
        check(
            rerun.returncode == 0
            and "already encrypted" in rerun.stdout,
            "arm 6: a second run is idempotent and reports the databases as "
            "already encrypted rather than re-keying them",
        )

    finally:
        shutil.rmtree(work_dir, ignore_errors=True)

    print("")
    print(f"== {CHECKS - len(FAILURES)} pass / {len(FAILURES)} fail / "
          f"{CHECKS} checks ==")
    if FAILURES:
        print("", file=sys.stderr)
        for failure in FAILURES:
            print(f"  FAILED: {failure}", file=sys.stderr)
        return RC_FAIL
    if CHECKS == 0:
        cannot_run("zero checks executed. A zero denominator is not a pass.")
    return RC_OK


if __name__ == "__main__":
    sys.exit(main())
