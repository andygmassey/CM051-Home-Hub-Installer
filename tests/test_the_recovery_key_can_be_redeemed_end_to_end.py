#!/usr/bin/env python3
"""The recovery key a customer is shown must actually get them back in.

WHAT WENT WRONG, AND WHY A LESSER TEST WOULD HAVE PASSED ON IT
=============================================================

``passphrase.setup_passphrase()`` mints an XXXX-XXXX-... recovery key and
the installer shows it to every customer, describing it as their only way
back in. ``passphrase.unlock_with_recovery_key()`` is the function that
spends it, and it had ZERO call sites for the whole of v1.0. It was
defined, exported from ``ostler_security/__init__.py``, named in an audit
document and mirrored by a comment in the AAD migrator. Every one of
those looks like use and none of them is.

That is precisely why this file asserts a ROUND TRIP and not a call site.
A test that imported the function and called it would have passed on the
broken tree, because the function always worked; what was missing was
anything shipped that a locked-out human could run. So the redeemer here
is driven AS A SUBPROCESS, through the module the console script
``ostler-unlock`` points at, with the key arriving on stdin the way a
customer's would.

And the thing being unlocked is a REAL SQLCipher database with a real
record in it, checked at the byte level, because "the function returned
32 bytes" is not "the customer got their data back".

THE ARMS
--------

  1  mint a config, take the recovery key
  2  write a real encrypted database under the passphrase-derived key,
     and prove on disk that it IS encrypted (not a SQLite header, and
     the canary string is nowhere in the raw bytes)
  3  forget the passphrase; run the SHIPPED redeemer with the recovery
     key on stdin; it must emit the same key the passphrase produced
  4  open the database with the redeemed key and read the canary back.
     THIS is the round trip and it is the point of the file
  5  NEGATIVE CONTROL: a wrong recovery key is rejected, exits non-zero
     and emits nothing on stdout
  6  NEGATIVE CONTROL: the database refuses a wrong key. Without this,
     arm 4 could be passing because the database was never encrypted
  7  --install-key-file lands the key at 0600 inside a 0700 directory
  8  REGRESSION: unlock_with_recovery_key has at least one call site in
     shipped code, with derive_key as the positive control proving the
     search finds callers when they exist

Exit codes: 0 all arms held, 1 an arm failed, 2 CANNOT-RUN (a
prerequisite is absent, which is not a pass).
"""
from __future__ import annotations

import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

RC_OK = 0
RC_FAIL = 1
RC_CANNOT_RUN = 2

FAILURES: list[str] = []
CHECKS = 0

# Long enough and odd enough that it cannot occur by chance in a header,
# a page of zero padding, or a schema string.
CANARY = "CANARY-recovery-round-trip-4f2a9c81"
PASSPHRASE = "correct horse battery staple 99"

SQLITE_MAGIC = b"SQLite format 3\x00"


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


def cannot_run(why: str) -> "None":
    print("", file=sys.stderr)
    print(f"CANNOT-RUN: {why}", file=sys.stderr)
    print("  NOTHING was checked. This is not a pass.", file=sys.stderr)
    raise SystemExit(RC_CANNOT_RUN)


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def stage_package(work: Path) -> Path:
    """Copy the vendored package somewhere importable.

    Copied rather than added to sys.path in place so the test cannot
    accidentally pick up a stray sibling of the vendor directory, and so
    the package's own tests/ tree is excluded exactly as the wheel
    excludes it.
    """
    pkg_root = work / "site"
    src = repo_root() / "vendor" / "ostler_security"
    dst = pkg_root / "ostler_security"
    shutil.copytree(src, dst, ignore=shutil.ignore_patterns("tests", "bin", "__pycache__"))
    return pkg_root


def run_redeemer(
    pkg_root: Path, secret: str, args: list, env_extra: dict | None = None,
) -> subprocess.CompletedProcess:
    """Drive the shipped redeemer the way a customer's shell would.

    `python -m ostler_security.passphrase_recovery_cli` is the exact
    module the `ostler-unlock` console script entry point names in
    pyproject.toml, so this exercises the shipped entry point rather
    than a library call that happens to sit behind it.
    """
    env = dict(os.environ)
    env["PYTHONPATH"] = str(pkg_root) + os.pathsep + env.get("PYTHONPATH", "")
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        [sys.executable, "-m", "ostler_security.passphrase_recovery_cli"] + args,
        input=secret,
        env=env,
        capture_output=True,
        text=True,
    )


def raw_bytes(path: Path) -> bytes:
    return path.read_bytes()


def main() -> int:
    work_dir = tempfile.mkdtemp(prefix="ostler-recovery-roundtrip-")
    work = Path(work_dir)
    try:
        pkg_root = stage_package(work)
        sys.path.insert(0, str(pkg_root))

        try:
            from ostler_security import passphrase as pp
            from ostler_security.database import HAS_SQLCIPHER, get_db_connection
        except ImportError as exc:
            cannot_run(
                f"could not import ostler_security ({exc}). The redeemer "
                "cannot be exercised and nothing was measured."
            )

        if not HAS_SQLCIPHER:
            cannot_run(
                "sqlcipher3 is not installed in this interpreter, so no real "
                "encrypted database can be created. Arms 2, 4 and 6 would "
                "silently degrade to plaintext SQLite and pass for the wrong "
                "reason, which is the exact failure class this file exists "
                "to refuse."
            )

        # ── ARM 1: mint ───────────────────────────────────────────────
        config_dir = work / "security"
        result = pp.setup_passphrase(PASSPHRASE, config_dir=config_dir)
        recovery_key = result["recovery_key"]
        config = json.loads((config_dir / "keychain.json").read_text())

        check(
            bool(recovery_key) and "-" in recovery_key,
            f"arm 1: setup_passphrase minted a recovery key "
            f"({len(recovery_key)} characters, grouped)",
        )
        check(
            "recovery_encrypted_key" in config,
            "arm 1: the config carries a recovery envelope to open",
        )

        # ── ARM 2: a real encrypted database, proved on disk ──────────
        db_path = work / "coach.db"
        passphrase_key = pp.unlock(PASSPHRASE, config_dir=config_dir).hex()
        conn = get_db_connection(db_path, passphrase_key)
        conn.execute("CREATE TABLE notes (body TEXT)")
        conn.execute("INSERT INTO notes VALUES (?)", (CANARY,))
        conn.commit()
        conn.close()

        blob = raw_bytes(db_path)
        check(
            not blob.startswith(SQLITE_MAGIC),
            "arm 2: the database on disk does NOT start with the SQLite "
            "magic header, so it is genuinely encrypted",
        )
        check(
            CANARY.encode() not in blob,
            "arm 2: the canary record is absent from the raw bytes of the "
            f"database file ({len(blob)} bytes read)",
        )

        # ── ARM 3: redeem, as a subprocess, key on stdin ──────────────
        proc = run_redeemer(
            pkg_root,
            recovery_key + "\n",
            # --print-key is REQUIRED now and was not before (#1970). These
            # two arms observe the key by reading stdout, which is exactly
            # what the flag is for. The default no longer prints, because a
            # printed database key lands in shell history, scrollback and any
            # screen share. Arm 7 below is untouched: it asserts on the key
            # FILE, not on stdout.
            ["--recovery-key", "--secret-file", "-", "--print-key",
             "--config-dir", str(config_dir)],
        )
        redeemed = proc.stdout.strip()
        check(
            proc.returncode == 0,
            f"arm 3: the shipped redeemer exited 0 (rc={proc.returncode})",
        )
        check(
            re.fullmatch(r"[0-9a-f]{64}", redeemed or "") is not None,
            "arm 3: it emitted a 64-hex key on stdout and nothing else",
        )
        check(
            redeemed == passphrase_key,
            "arm 3: the redeemed key is byte-identical to the one the "
            "passphrase produces, so it opens the same data",
        )

        # ── ARM 4: THE ROUND TRIP. Open the box with the redeemed key ─
        if redeemed:
            try:
                conn = get_db_connection(db_path, redeemed)
                rows = conn.execute("SELECT body FROM notes").fetchall()
                conn.close()
                check(
                    [r[0] for r in rows] == [CANARY],
                    "arm 4: the encrypted database OPENS with the redeemed "
                    "key and the record reads back intact. This is the whole "
                    "point: a locked-out customer gets their data",
                )
            except Exception as exc:
                bad(
                    f"arm 4: the redeemed key did not open the database "
                    f"({exc.__class__.__name__}: {exc})"
                )
        else:
            bad("arm 4: no key was redeemed, so the round trip was not attempted")

        # ── ARM 5: NEGATIVE CONTROL, a wrong key ─────────────────────
        wrong = run_redeemer(
            pkg_root,
            "AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GG\n",
            # --print-key is REQUIRED now and was not before (#1970). These
            # two arms observe the key by reading stdout, which is exactly
            # what the flag is for. The default no longer prints, because a
            # printed database key lands in shell history, scrollback and any
            # screen share. Arm 7 below is untouched: it asserts on the key
            # FILE, not on stdout.
            ["--recovery-key", "--secret-file", "-", "--print-key",
             "--config-dir", str(config_dir)],
        )
        check(
            wrong.returncode != 0,
            f"arm 5 (control): a wrong recovery key is refused "
            f"(rc={wrong.returncode})",
        )
        check(
            wrong.stdout.strip() == "",
            "arm 5 (control): a refused attempt emits NOTHING on stdout, so "
            "a caller capturing stdout cannot receive a key that was never "
            "unlocked",
        )
        check(
            "Incorrect recovery key" in wrong.stderr,
            "arm 5 (control): the refusal names what was wrong, on stderr",
        )

        # ── ARM 6: NEGATIVE CONTROL for arm 4 ────────────────────────
        # Without this, arm 4 could be passing on a database that was
        # never encrypted at all: a plaintext SQLite file opens with any
        # key, or none.
        bogus_key = "ab" * 32
        opened_with_wrong_key = True
        try:
            conn = get_db_connection(db_path, bogus_key)
            conn.execute("SELECT body FROM notes").fetchall()
            conn.close()
        except Exception:
            opened_with_wrong_key = False
        check(
            not opened_with_wrong_key,
            "arm 6 (control): the same database REFUSES a wrong key, which "
            "is what makes arm 4 a measurement rather than a tautology",
        )

        # ── ARM 7: the key file handoff ──────────────────────────────
        home = work / "home"
        key_file = home / "security" / "db_key"
        installed = run_redeemer(
            pkg_root,
            recovery_key + "\n",
            ["--recovery-key", "--secret-file", "-",
             "--config-dir", str(config_dir),
             "--install-key-file", "--key-file", str(key_file)],
        )
        check(
            installed.returncode == 0 and key_file.exists(),
            "arm 7: --install-key-file wrote the key file",
        )
        if key_file.exists():
            file_mode = stat.S_IMODE(key_file.lstat().st_mode)
            dir_mode = stat.S_IMODE(key_file.parent.lstat().st_mode)
            check(
                file_mode == 0o600,
                f"arm 7: the key file is 0600 (measured {file_mode:04o})",
            )
            check(
                dir_mode == 0o700,
                f"arm 7: its directory is 0700 (measured {dir_mode:04o})",
            )
            check(
                key_file.read_text().strip() == passphrase_key,
                "arm 7: the key file holds the real database key",
            )

        # ── ARM 8: the call-site regression, with its controls ───────
        #
        # INVOCATIONS, NOT MENTIONS, and this is not a style preference.
        # A regex for `unlock_with_recovery_key\s*\(` scores 3 on this
        # very tree, and two of the three are prose: this file's own
        # docstring and the redeemer's. That is exactly the defect
        # verify_test_wiring.sh admits to in its own source ("a test
        # scored WIRED if any workflow merely NAMED it"), and inheriting
        # it here would mean a future tree could delete the last real
        # caller and stay green on the strength of a comment about it.
        #
        # So the count comes from the AST. An ast.Call node is a call;
        # a docstring is a string.
        import ast

        def count_invocations(tree: ast.AST, name: str) -> int:
            found = 0
            for node in ast.walk(tree):
                if not isinstance(node, ast.Call):
                    continue
                func = node.func
                if isinstance(func, ast.Name) and func.id == name:
                    found += 1
                elif isinstance(func, ast.Attribute) and func.attr == name:
                    found += 1
            return found

        # passphrase.py is excluded because it DEFINES these; a
        # definition is not a consumer, and counting it would have made
        # the broken tree look wired.
        pkg = repo_root() / "vendor" / "ostler_security"
        subject = control = absent = 0
        parsed = 0
        for f in sorted(pkg.rglob("*.py")):
            if "test" in f.name or f.name == "passphrase.py":
                continue
            try:
                tree = ast.parse(f.read_text(encoding="utf-8", errors="ignore"))
            except (OSError, SyntaxError):
                continue
            parsed += 1
            subject += count_invocations(tree, "unlock_with_recovery_key")
            control += count_invocations(tree, "derive_key")
            absent += count_invocations(tree, "unlock_with_a_key_that_does_not_exist")

        if parsed == 0:
            cannot_run(
                "arm 8 parsed zero python files under vendor/ostler_security. "
                "A call-site count over an empty denominator establishes "
                "nothing, and would read as 'no callers'."
            )

        check(
            control > 0,
            f"arm 8 (positive control): the counter finds {control} "
            "derive_key invocation(s) across "
            f"{parsed} shipped module(s), so it detects callers that exist",
        )
        check(
            absent == 0,
            "arm 8 (negative control): a function name that exists nowhere "
            f"counts {absent}, so the counter is not simply returning a "
            "non-zero number for everything",
        )
        check(
            subject > 0,
            f"arm 8: unlock_with_recovery_key is INVOKED {subject} time(s) in "
            "shipped, non-test, non-defining code. It was invoked 0 times for "
            "the whole of v1.0 while being defined, exported and documented",
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
        print(
            "CANNOT-RUN: zero checks executed. A zero denominator is not a "
            "pass.",
            file=sys.stderr,
        )
        return RC_CANNOT_RUN
    return RC_OK


if __name__ == "__main__":
    sys.exit(main())
