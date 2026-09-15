#!/usr/bin/env python3
"""``ostler-unlock`` must not hand a customer their raw database key.

WHY THIS FILE EXISTS
=====================

Before this change, every successful run of
``ostler_security.passphrase_recovery_cli`` printed the raw 64-character
database key to stdout UNCONDITIONALLY, whether or not the caller also
asked to install the key file. A customer who has just recovered a locked
box and runs the documented command in Terminal would see that key
rendered in their own window, and Andy's own words on this class of
mistake (a recovery flow that dumps a raw secret at a frightened,
non-technical customer) are exactly why this file exists: something
that CAN be pasted into a note or a support ticket WILL be, eventually.

The fix makes key-file install the default and hides the raw key unless
an engineer explicitly asks for it with --print-key. This file proves
that split, as a subprocess, through the exact module the ``ostler-unlock``
console script points at -- not a library call, which would not notice a
CLI default drifting back to the old behaviour.

Exit codes: 0 all arms held, 1 an arm failed, 2 CANNOT-RUN.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

RC_OK = 0
RC_FAIL = 1
RC_CANNOT_RUN = 2

FAILURES: list[str] = []
CHECKS = 0

KEY_SHAPE = re.compile(r"[0-9a-f]{64}")
PASSPHRASE = "correct horse battery staple 99"


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


def stage_package(work: Path) -> Path:
    pkg_root = work / "site"
    src = repo_root() / "vendor" / "ostler_security"
    dst = pkg_root / "ostler_security"
    shutil.copytree(src, dst, ignore=shutil.ignore_patterns("tests", "bin", "__pycache__"))
    return pkg_root


def run_redeemer(pkg_root: Path, secret: str, args: list) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env["PYTHONPATH"] = str(pkg_root) + os.pathsep + env.get("PYTHONPATH", "")
    return subprocess.run(
        [sys.executable, "-m", "ostler_security.passphrase_recovery_cli"] + args,
        input=secret,
        env=env,
        capture_output=True,
        text=True,
    )


def main() -> int:
    work_dir = tempfile.mkdtemp(prefix="ostler-unlock-hide-key-")
    work = Path(work_dir)
    try:
        pkg_root = stage_package(work)
        sys.path.insert(0, str(pkg_root))

        try:
            from ostler_security import passphrase as pp
        except ImportError as exc:
            cannot_run(f"could not import ostler_security ({exc}).")

        config_dir = work / "security"
        result = pp.setup_passphrase(PASSPHRASE, config_dir=config_dir)
        recovery_key = result["recovery_key"]
        expected_key = pp.unlock(PASSPHRASE, config_dir=config_dir).hex()

        # Every invocation below names --key-file explicitly so none of
        # them can ever write to this test-runner's real ~/.ostler.

        # ── ARM A: default invocation hides the raw key ──────────────
        key_file_a = work / "home-a" / "security" / "db_key"
        proc_a = run_redeemer(
            pkg_root,
            recovery_key + "\n",
            ["--recovery-key", "--secret-file", "-",
             "--config-dir", str(config_dir), "--key-file", str(key_file_a)],
        )
        check(proc_a.returncode == 0, f"arm A: default run exits 0 (rc={proc_a.returncode})")
        check(
            KEY_SHAPE.search(proc_a.stdout) is None,
            "arm A: stdout carries NO 64-hex key-shaped string by default "
            f"(stdout={proc_a.stdout!r})",
        )
        check(
            KEY_SHAPE.search(proc_a.stderr) is None,
            "arm A: stderr carries no key-shaped string either",
        )
        check(
            "installed" in proc_a.stdout.lower(),
            "arm A: stdout instead carries a plain confirmation",
        )
        check(
            key_file_a.exists() and key_file_a.read_text().strip() == expected_key,
            "arm A: the key file was installed by DEFAULT, with no "
            "--install-key-file flag passed",
        )

        # ── ARM B: --print-key is the opt-in that reveals it ─────────
        key_file_b = work / "home-b" / "security" / "db_key"
        proc_b = run_redeemer(
            pkg_root,
            recovery_key + "\n",
            ["--recovery-key", "--secret-file", "-", "--print-key",
             "--config-dir", str(config_dir), "--key-file", str(key_file_b)],
        )
        check(proc_b.returncode == 0, f"arm B: --print-key run exits 0 (rc={proc_b.returncode})")
        check(
            proc_b.stdout.strip() == expected_key,
            "arm B: --print-key puts exactly the raw key on stdout, "
            f"and nothing else (stdout={proc_b.stdout!r})",
        )

        # ── ARM C: a wrong key still reveals nothing, either way ─────
        wrong = run_redeemer(
            pkg_root,
            "AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GG\n",
            ["--recovery-key", "--secret-file", "-", "--print-key",
             "--config-dir", str(config_dir),
             "--key-file", str(work / "home-c" / "security" / "db_key")],
        )
        check(wrong.returncode != 0, f"arm C (control): a wrong key is refused (rc={wrong.returncode})")
        check(
            wrong.stdout.strip() == "" and KEY_SHAPE.search(wrong.stderr) is None,
            "arm C (control): a refused attempt reveals no key anywhere, "
            "--print-key or not",
        )

        # ── ARM D: the write-failure escape hatch still shows the key ─
        # Block the key file's directory with a plain FILE at that path
        # component, so install_key_file()'s mkdir(parents=True) raises.
        blocker_parent = work / "home-d"
        blocker_parent.mkdir(parents=True)
        blocked_dir = blocker_parent / "not-a-directory"
        blocked_dir.write_text("occupying this path on purpose\n")
        key_file_d = blocked_dir / "security" / "db_key"
        proc_d = run_redeemer(
            pkg_root,
            recovery_key + "\n",
            ["--recovery-key", "--secret-file", "-",
             "--config-dir", str(config_dir), "--key-file", str(key_file_d)],
        )
        check(
            proc_d.returncode == 4,
            f"arm D: a key-file write failure exits 4 (rc={proc_d.returncode})",
        )
        check(
            proc_d.stdout.strip() == expected_key,
            "arm D: when the file handoff fails, the raw key IS printed "
            "regardless of --print-key, because that is the only way left "
            f"to hand it over (stdout={proc_d.stdout!r})",
        )

    finally:
        shutil.rmtree(work_dir, ignore_errors=True)

    print("")
    print(f"== {CHECKS - len(FAILURES)} pass / {len(FAILURES)} fail / {CHECKS} checks ==")
    if FAILURES:
        print("", file=sys.stderr)
        for failure in FAILURES:
            print(f"  FAILED: {failure}", file=sys.stderr)
        return RC_FAIL
    if CHECKS == 0:
        print("CANNOT-RUN: zero checks executed.", file=sys.stderr)
        return RC_CANNOT_RUN
    return RC_OK


if __name__ == "__main__":
    sys.exit(main())
