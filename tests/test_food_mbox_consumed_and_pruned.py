"""Food reads each mbox once, and an mbox is deleted only when both readers are done.

walk122 (v1.0.122, Mini16 scale fixture): ~/.ostler/imports/email held 12 GB,
a 12.2 GB first export plus one ~140 MB mbox per hourly backfill tick, and
nothing removed them. Food re-read every one of them every day. Readers of the
folder, from a grep of CM051 and ostler-assistant main: the sealed email-ingest
tick (logs "ingested <path> successfully"), install.sh's hydrate (deletes its
own install-time file), and ingest_food.

  arm 1  a second food run stages 0 bytes of an mbox it already consumed.
  arm 2  a failed ingest records nothing, keeps the file, and the next run retries.
  arm 3  a TIMEOUT under a slow parser (the real run_cm019_ingest, a fake venv
         python that sleeps past the scaled limit) records nothing, keeps the
         file, and the next run retries it.
  arm 4  the record is keyed by name AND (inode, size): a replaced or appended
         file is read again.
  arm 5  prune deletes only a past-hour, food-consumed file whose LAST log line
         is "ingested <path> successfully" at or after its mtime; it keeps an
         unconsumed file, a current-hour file, a file with no log, a log line
         older than the mtime, a later same-hour re-run, a preserved failure and
         an install-time name.
  arm 6  the timeout scales with the bytes staged and is capped.
Exit: 0 pass, 1 real failure, 2 cannot-run.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import time
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
TREE = REPO / "vendor" / "cm019_preferences"
try:
    import httpx  # noqa: F401
    import phonenumbers  # noqa: F401
    import nameparser  # noqa: F401
except ImportError as exc:
    print(f"CANNOT-RUN: {exc}. pip install httpx phonenumbers nameparser")
    sys.exit(2)

sys.path[:0] = [str(REPO / "vendor"), str(TREE / "services" / "common"), str(TREE / "services" / "enrich" / "src")]
from ostler_fda import pwg_ingest as fda  # noqa: E402

PASS = FAIL = 0


def check(cond, msg):
    global PASS, FAIL
    PASS, FAIL = (PASS + 1, FAIL) if cond else (PASS, FAIL + 1)
    print(("  PASS " if cond else "  FAIL ") + msg)


def box():
    """A fresh synthetic ~/.ostler: imports/fda with one extract, imports/email."""
    root = Path(tempfile.mkdtemp(prefix="food-mbox-"))
    (root / "imports" / "fda").mkdir(parents=True)
    (root / "imports" / "email").mkdir()
    (root / "logs").mkdir()
    (root / "imports" / "fda" / "calendar_events.json").write_text("[]")
    return root, root / "imports" / "fda", root / "imports" / "email"


def mbox(mail: Path, name: str, body: str = "From a@b Thu Sep  3 12:00:00 2026\nSubject: x\n\nbody\n") -> Path:
    p = mail / name
    p.write_text(body)
    return p


def runner(record):
    def run(stage, ostler_dir, user, timeout_s=None):
        record.append(sorted(p.name for p in Path(stage).iterdir()))
        return True
    return run


def log_line(root: Path, when: float, msg: str) -> None:
    with open(root / "logs" / "email-ingest.log", "a") as fh:
        fh.write("[%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(when)), msg))


PAST = "2026-10-22-19.mbox.txt"

# ── arm 1: consumed once, never staged again ─────────────────────────────────
root, fdadir, mail = box()
mbox(mail, PAST)
calls = []
with mock.patch.dict(os.environ, {"OSTLER_DIR": str(root)}), \
        mock.patch("ostler_fda.apple_music_refresh.run_cm019_ingest", runner(calls)):
    first = fda.ingest_food(fdadir)
    second = fda.ingest_food(fdadir)
check(PAST in calls[0], "arm 1: the first run stages the mbox")
check(PAST not in calls[1], f"arm 1: the second run does not stage it (staged {calls[1]})")
check(second.get("staged_bytes") == 2, f"arm 1: the second run stages 0 mbox bytes (staged_bytes={second.get('staged_bytes')}, the 2-byte extract only)")
state = json.loads((root / "state" / "food_mbox_consumed.json").read_text())
check(set(state[PAST]) >= {"inode", "size", "consumed_at"}, "arm 1: the record carries inode, size and consumed_at")

# ── arm 2: a failed ingest records nothing and is retried ────────────────────
root, fdadir, mail = box()
mbox(mail, PAST)
with mock.patch.dict(os.environ, {"OSTLER_DIR": str(root)}):
    with mock.patch("ostler_fda.apple_music_refresh.run_cm019_ingest", lambda *a, **k: False):
        res = fda.ingest_food(fdadir)
    after_fail = fda._load_food_state(root)
    calls = []
    with mock.patch("ostler_fda.apple_music_refresh.run_cm019_ingest", runner(calls)):
        fda.ingest_food(fdadir)
check(res["status"] == "error", "arm 2: a failed ingest is error")
check(PAST not in after_fail, "arm 2: nothing recorded by the failed run")
check((mail / PAST).exists(), "arm 2: the file is kept")
check(calls and PAST in calls[0], "arm 2: the next run retries it")

# ── arm 3: a TIMEOUT through the real run_cm019_ingest ───────────────────────
root, fdadir, mail = box()
mbox(mail, PAST)
venv = root / "services" / "cm019" / ".venv" / "bin"
venv.mkdir(parents=True)
py = venv / "python3"
py.write_text("#!/bin/sh\nsleep 5\n")
py.chmod(0o755)
t0 = time.monotonic()
with mock.patch.dict(os.environ, {"OSTLER_DIR": str(root)}), \
        mock.patch.object(fda, "FOOD_TIMEOUT_BASE_S", 0.5), mock.patch.object(fda, "FOOD_TIMEOUT_PER_GB_S", 0.0):
    res = fda.ingest_food(fdadir)
took = time.monotonic() - t0
check(res["status"] == "error" and took < 4, f"arm 3: the slow parser is cut off at the scaled limit and reported error ({took:.1f}s)")
check(PAST not in fda._load_food_state(root), "arm 3: a timeout records nothing")
check((mail / PAST).exists(), "arm 3: the file is kept")
py.write_text("#!/bin/sh\nexit 0\n")
with mock.patch.dict(os.environ, {"OSTLER_DIR": str(root)}):
    res = fda.ingest_food(fdadir)
check(res["status"] == "ok" and PAST in fda._load_food_state(root), "arm 3: the next run retries it and records it")

# ── arm 4: keyed by name AND (inode, size) ───────────────────────────────────
root, fdadir, mail = box()
p = mbox(mail, PAST)
calls = []
with mock.patch.dict(os.environ, {"OSTLER_DIR": str(root)}), \
        mock.patch("ostler_fda.apple_music_refresh.run_cm019_ingest", runner(calls)):
    fda.ingest_food(fdadir)
    with open(p, "a") as fh:
        fh.write("From a@b Thu Sep  3 13:00:00 2026\nSubject: y\n\nmore\n")
    fda.ingest_food(fdadir)
    size = p.stat().st_size
    fda.ingest_food(fdadir)
    p.unlink()
    mbox(mail, PAST, "x" * size)  # same name and size, a new inode
    fda.ingest_food(fdadir)
check(PAST in calls[1], "arm 4: an appended file (new size) is read again")
check(PAST not in calls[2], "arm 4: and then not again")
check(PAST in calls[3], "arm 4: a replaced file (same name and size, new inode) is read again")

# ── arm 5: prune keeps everything it cannot prove done ───────────────────────
root, fdadir, mail = box()
now = time.time()
hour = 3600
cur = time.strftime("%Y-%m-%d-%H", time.localtime(now)) + ".mbox.txt"
names = {}
for tag, offset in (("done", 5), ("unconsumed", 6), ("nolog", 7), ("oldlog", 8),
                    ("rerun", 9), ("preserved", 10)):
    n = time.strftime("%Y-%m-%d-%H", time.localtime(now - offset * hour)) + ".mbox.txt"
    names[tag] = mbox(mail, n)
names["current"] = mbox(mail, cur)
names["install"] = mbox(mail, "install-time-20261103T210000.mbox.txt")
for p in names.values():
    os.utime(p, (now - 2 * hour, now - 2 * hour))
state = {p.name: dict(fda._mbox_key(p), consumed_at="x") for t, p in names.items() if t != "unconsumed"}
after = now - hour      # after the mtime
before = now - 3 * hour  # before the mtime
for tag in ("done", "unconsumed", "rerun", "preserved", "current", "install"):
    log_line(root, after, "ingested %s successfully" % names[tag])
log_line(root, before, "ingested %s successfully" % names["oldlog"])
log_line(root, after + 60, "email-ingest tick start: mbox=%s backfill_days=1825" % names["rerun"])
log_line(root, after + 60, "ERROR: pwg-email-ingest failed (exit 1); mbox preserved at %s." % names["preserved"])
pruned = fda.prune_consumed_mboxes(mail, state, root / "logs" / "email-ingest.log", now=now)
check(pruned == [names["done"].name], f"arm 5: exactly the done file is pruned (pruned {pruned})")
check(not names["done"].exists() and names["done"].name not in state, "arm 5: it is gone from disk and from the record")
for tag in ("unconsumed", "nolog", "oldlog", "rerun", "preserved", "current", "install"):
    check(names[tag].exists(), f"arm 5: kept: {tag}")
(root / "logs" / "email-ingest.log").unlink()
check(fda.prune_consumed_mboxes(mail, state, root / "logs" / "email-ingest.log", now=now) == [],
      "arm 5: a missing (rotated) log prunes nothing")

# ── arm 6: the timeout scales and is capped ──────────────────────────────────
check(fda.food_timeout_s(0) == fda.FOOD_TIMEOUT_BASE_S, "arm 6: 0 bytes is the base 900 s")
check(fda.food_timeout_s(12_262_474_491) > 2300, "arm 6: the 12.2 GB first export gets > 2300 s (117 s measured calm)")
check(fda.food_timeout_s(10 ** 15) == fda.FOOD_TIMEOUT_CAP_S, "arm 6: capped")

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
