#!/usr/bin/env python3
"""Row 1970, the CLI half.

passphrase_recovery_cli wrote the unlocked DATABASE ENCRYPTION KEY to stdout
UNCONDITIONALLY, with a comment calling stdout the clean channel. Clean is not
the property that matters for a key. A printed key lands in shell history, in
terminal scrollback, in any screen share running at the time, and in whatever
log captures the session. None of that is chosen by the customer and none of
it can be un-chosen afterwards.

THE SUBJECT OF EVERY ASSERTION IS WHAT ENDS UP ON A PERSON'S TERMINAL, read
from the stdout of the real shipped entry point as a subprocess, not from a
library call and not from the presence of a flag.

The one case where printing is still correct is kept and asserted: when the
key file could not be written the key exists nowhere else, and losing it costs
the customer their databases. Removing that branch would trade a disclosure
for a data-loss, which is not an improvement.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "vendor"
PASSPHRASE = "correct-horse-battery-staple-1970"
HEX64 = re.compile(r"^[0-9a-f]{64}$")

PASS = FAIL = CANTRUN = 0


def ok(m: str) -> None:
    global PASS
    PASS += 1
    print(f"  ok    {m}")


def bad(m: str) -> None:
    global FAIL
    FAIL += 1
    print(f"  FAIL  {m}")


def cannot_run(why: str) -> int:
    global CANTRUN
    CANTRUN += 1
    print(f"  CANNOT-RUN  {why}")
    print("    NOTHING was checked. This is not a pass.")
    print(f"PASS={PASS} FAIL={FAIL} CANNOT-RUN={CANTRUN}")
    return 1


def redeem(pkg_root: Path, secret: str, args: list) -> subprocess.CompletedProcess:
    """Drive the shipped entry point the way a customer's shell would."""
    env = dict(os.environ)
    env["PYTHONPATH"] = str(pkg_root) + os.pathsep + env.get("PYTHONPATH", "")
    return subprocess.run(
        [sys.executable, "-m", "ostler_security.passphrase_recovery_cli"] + args,
        input=secret, env=env, capture_output=True, text=True,
    )


def main() -> int:
    try:
        import ostler_security.passphrase as pp  # noqa: F401
    except Exception as exc:
        return cannot_run(f"ostler_security.passphrase is not importable: {exc}")

    with tempfile.TemporaryDirectory() as td:
        work = Path(td)
        pkg_root = work / "pkg"
        pkg_root.mkdir()
        shutil.copytree(
            VENDOR / "ostler_security", pkg_root / "ostler_security",
            ignore=shutil.ignore_patterns("tests", "bin", "__pycache__"),
        )
        config_dir = work / "security"
        result = pp.setup_passphrase(PASSPHRASE, config_dir=config_dir)
        recovery_key = getattr(result, "recovery_key", None) or result["recovery_key"]
        expected = pp.unlock(PASSPHRASE, config_dir=config_dir).hex()
        if not HEX64.match(expected):
            return cannot_run("the fixture did not produce a 64-hex key to compare against")
        print(f"EXAMINED: the shipped entry point as a subprocess, 4 invocations, "
              f"against a real config in {config_dir.name}")

        base = ["--recovery-key", "--secret-file", "-", "--config-dir", str(config_dir)]

        # (1) THE DEFECT. No destination flag at all.
        p = redeem(pkg_root, recovery_key + "\n", base)
        if expected in p.stdout:
            bad("(1) a bare invocation STILL prints the database key to stdout")
        else:
            ok("(1) a bare invocation does NOT print the key to stdout")
        if p.returncode != 0:
            ok(f"(2) and it does not claim success: rc={p.returncode}, so a caller cannot mistake it for done")
        else:
            bad("(2) it exited 0 while putting the key nowhere, which reads as success")
        if "--install-key-file" in p.stderr and "--print-key" in p.stderr:
            ok("(3) it tells the person both destinations on stderr")
        else:
            bad("(3) it does not name the two destinations, so the refusal is not actionable")

        # (4) THE OPT-IN. Explicitly asked for, explicitly given.
        p = redeem(pkg_root, recovery_key + "\n", base + ["--print-key"])
        if p.returncode == 0 and HEX64.match(p.stdout.strip() or ""):
            ok("(4) --print-key prints a 64-hex key and nothing else, rc=0")
        else:
            bad(f"(4) --print-key did not produce the key (rc={p.returncode})")
        if p.stdout.strip() == expected:
            ok("(5) and it is byte-identical to the key the passphrase produces, so it opens the same data")
        else:
            bad("(5) --print-key produced a key that is not the real one")

        # (6) THE NORMAL PATH. Key file requested and written: nothing on stdout.
        key_file = work / "sec" / "db.key"
        p = redeem(pkg_root, recovery_key + "\n",
                   base + ["--install-key-file", "--key-file", str(key_file)])
        wrote = key_file.exists() and key_file.read_text().strip() == expected
        if wrote and expected not in p.stdout:
            ok("(6) --install-key-file writes the key file and keeps the key OFF stdout")
        else:
            bad(f"(6) install path wrong (file written={wrote}, key on stdout={expected in p.stdout})")

        # (7) THE SAFETY NET, and it is why this is a branch and not a deletion.
        # Make the write fail by pointing it at a path under a read-only dir.
        # A parent that is a REGULAR FILE, not a read-only directory. Mode
        # bits are ignored for root and this suite must not quietly degrade
        # to CANNOT-RUN in CI; a file cannot contain a directory for anyone.
        blocker = work / "not-a-dir"
        blocker.write_text("this is a file, so nothing can be created inside it\n")
        doomed = blocker / "db.key"
        p = redeem(pkg_root, recovery_key + "\n",
                   base + ["--install-key-file", "--key-file", str(doomed)])
        if doomed.exists():
            bad("(7) the write was expected to fail and did not, so the arm proves nothing")
        elif expected in p.stdout:
            ok("(7) a FAILED handoff still prints the key, so it is not lost")
            if "NOT the normal path" in p.stderr:
                ok("(8) and stderr says this is not the normal path, so it is not read as the old default")
            else:
                bad("(8) it printed the key on failure without saying why")
        else:
            bad("(7) a failed handoff printed nothing: the key is LOST, which is worse than the defect")

    print(f"PASS={PASS} FAIL={FAIL} CANNOT-RUN={CANTRUN}")
    return 0 if (FAIL == 0 and CANTRUN == 0 and PASS >= 8) else 1


if __name__ == "__main__":
    sys.exit(main())
