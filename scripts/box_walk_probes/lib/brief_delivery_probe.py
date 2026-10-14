#!/usr/bin/env python3
"""Did the scheduled brief and wrap actually reach Messages?

Walk #27 (Mini16, 2026-10-14). The 01:00Z morning-brief run is recorded in
cron_runs as status "ok", and chat.db has no message anywhere near it. Until
now no instrument could tell those two apart, because `ok` is written for a
run that DELIVERED, for one the settle grace SUPPRESSED, and (with
best_effort) for one whose delivery FAILED. That run was in fact
`delivery=SUPPRESSED_SETTLING` in ostler-assistant.err: by design, not a
drop. The next one might not be.

This reader joins three records the box already keeps, per run:

  cron_runs (jobs.db)          a run happened, and when
  ostler-assistant.err         delivery=<DELIVERED|SUPPRESSED_*|SKIPPED_*|FAILED>
                               job_id=<id>, the daemon's own disposition
  chat.db                      an is_from_me=1 message carrying the assistant
                               send marker (leading robot emoji, or the
                               invisible marker) inside the delivery window

Per-run outcome:

  seen        a marked message is in chat.db in the window       -> counts PASS
  suppressed  no message, and the daemon says it withheld it      -> neutral
  dropped     no message, and the daemon says DELIVERED or FAILED -> FAIL
  unknown     no message and no disposition line (log rotated)    -> CANNOT-RUN

Verdict: any dropped -> FAIL. Else at least one seen and no unknown -> PASS.
Else CANNOT-RUN, naming why: a walk where every run was suppressed has NOT
shown that delivery works, so it must not read as a pass.

Counts only leave the box: no message text, recipient or handle.

  box                 read the box's real files, print a JSON capture
  judge <capture>     print the verdict lines, exit 0 / 1 / 78
  --self-test         every synthetic case lands on its own verdict
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78

ROBOT = "\U0001F916"
MARKER = "⁣⁤⁣"
MAC_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
ANSI = re.compile(r"\x1b\[[0-9;]*m")
LOG_LINE = re.compile(r"^(\d{4}-\d\d-\d\dT[\d:.]+Z)\b.*?\bdelivery=([A-Z_]+)")
JOB_ID = re.compile(r"\bjob_id\W{0,8}=\W{0,8}([A-Za-z0-9_.:-]+)")

HOME = Path.home()
JOBS_DB = [
    HOME / ".ostler/assistant-config/workspace/cron/jobs.db",
    HOME / ".zeroclaw/workspace/cron/jobs.db",
]
CHAT_DB = HOME / "Library/Messages/chat.db"
LOGS = [HOME / ".ostler/logs/ostler-assistant.err", HOME / ".ostler/logs/ostler-assistant.log"]

# Delivery can take up to max_wait_secs; the message lands after that.
SLACK_S = 600
WINDOW_DAYS = 7


def _ts(s: str) -> datetime:
    s = s.strip().replace("Z", "+00:00")
    # cron_runs stamps carry microseconds and an offset; fromisoformat copes.
    d = datetime.fromisoformat(s)
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


def _ro(path: Path) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True)


def collect(jobs_paths, chat_db, logs, now=None) -> dict:
    """Counts-only capture. Never raises: an unreadable input is reported."""
    now = now or datetime.now(timezone.utc)
    cap = {"jobs_db": None, "chat_db_readable": False, "log_readable": False,
           "runs": [], "window_days": WINDOW_DAYS}
    jobs = next((p for p in jobs_paths if Path(p).is_file()), None)
    if jobs is None:
        return cap
    cap["jobs_db"] = "found"
    try:
        con = _ro(Path(jobs))
        rows = con.execute(
            "SELECT j.id, json_extract(j.delivery,'$.mode'), "
            "json_extract(j.delivery,'$.channel'), "
            "COALESCE(json_extract(j.delivery,'$.max_wait_secs'), 0), "
            "r.started_at, r.finished_at, r.status "
            "FROM cron_runs r JOIN cron_jobs j ON j.id = r.job_id"
        ).fetchall()
        con.close()
    except sqlite3.Error as exc:
        cap["jobs_db"] = "unreadable: " + type(exc).__name__
        return cap

    cutoff = now - timedelta(days=WINDOW_DAYS)
    runs = []
    for jid, mode, chan, max_wait, started, finished, status in rows:
        if str(mode or "").lower() != "announce" or str(chan or "").lower() != "imessage":
            continue
        try:
            s, f = _ts(started), _ts(finished)
        except ValueError:
            continue
        if s < cutoff or status != "ok":
            continue
        runs.append({"job": jid, "start": s, "end": f + timedelta(seconds=int(max_wait or 0) + SLACK_S)})

    # The daemon's own disposition per (job, time).
    labels = []
    for lp in logs:
        p = Path(lp)
        if not p.is_file():
            continue
        try:
            with p.open("r", encoding="utf-8", errors="replace") as fh:
                for raw in fh:
                    if "delivery=" not in raw:
                        continue
                    line = ANSI.sub("", raw)
                    m, j = LOG_LINE.search(line), JOB_ID.search(line)
                    if m and j:
                        labels.append((_ts(m.group(1)), j.group(1), m.group(2)))
            cap["log_readable"] = True
        except OSError:
            pass

    # chat.db: marked is_from_me rows, as times only.
    sent = []
    try:
        con = _ro(Path(chat_db))
        for date_raw, text in con.execute(
            "SELECT date, text FROM message WHERE is_from_me = 1 AND text IS NOT NULL "
            "AND date > ?", (_mac(cutoff - timedelta(days=1)),)
        ):
            if text.lstrip().startswith(ROBOT) or MARKER in text:
                sent.append(_from_mac(date_raw))
        con.close()
        cap["chat_db_readable"] = True
    except sqlite3.Error:
        pass

    for r in runs:
        seen = sum(1 for t in sent if r["start"] - timedelta(seconds=5) <= t <= r["end"])
        disp = [l for (t, jid, l) in labels
                if jid == r["job"] and r["start"] - timedelta(seconds=5) <= t <= r["end"]]
        cap["runs"].append({"seen": seen, "disposition": disp[-1] if disp else None})
    return cap


def _mac(d: datetime) -> int:
    return int((d - MAC_EPOCH).total_seconds() * 1e9)


def _from_mac(raw) -> datetime:
    raw = int(raw or 0)
    secs = raw / 1e9 if raw > 1e15 else raw
    return MAC_EPOCH + timedelta(seconds=secs)


def judge(cap: dict):
    lines = []
    if not cap.get("jobs_db"):
        return ["  CANNOT no cron jobs.db on the box; no scheduled brief to check"], EX_CANNOT
    if str(cap["jobs_db"]).startswith("unreadable"):
        return [f"  CANNOT jobs.db {cap['jobs_db']}"], EX_CANNOT
    if not cap.get("chat_db_readable"):
        return ["  CANNOT chat.db could not be read (Full Disk Access for this session?); "
                "delivery cannot be observed"], EX_CANNOT
    runs = cap.get("runs") or []
    if not runs:
        return [f"  CANNOT 0 ok iMessage brief/wrap runs in the last {cap.get('window_days')} days"], EX_CANNOT
    seen = suppressed = dropped = unknown = 0
    for r in runs:
        d = r.get("disposition") or ""
        if r.get("seen", 0) > 0:
            seen += 1
        elif d.startswith(("SUPPRESSED", "SKIPPED", "NOT_ANNOUNCED")):
            suppressed += 1
        elif d in ("DELIVERED", "FAILED"):
            dropped += 1
            lines.append(f"  FAIL a run the daemon logged delivery={d} has no assistant message in chat.db")
        else:
            unknown += 1
    lines.append(f"  note runs={len(runs)} seen={seen} suppressed={suppressed} "
                 f"dropped={dropped} unknown={unknown} log_readable={cap.get('log_readable')}")
    if dropped:
        return lines, EX_FAIL
    if unknown:
        lines.append(f"  CANNOT {unknown} run(s) have no message and no delivery= line to say why")
        return lines, EX_CANNOT
    if not seen:
        lines.append("  CANNOT every run in the window was withheld by design; none was delivered, "
                     "so delivery has not been shown to work")
        return lines, EX_CANNOT
    lines.append(f"  ok {seen} of {len(runs)} run(s) observed in chat.db, the rest withheld by design")
    return lines, EX_PASS


# ---------------------------------------------------------------------------
# Self-test: synthetic jobs.db, chat.db and log; every case on its own verdict.
# ---------------------------------------------------------------------------

def _fixture(d: Path, *, disposition, message_at, chat_ok=True, now):
    run = now - timedelta(hours=3)
    jobs = d / "jobs.db"
    con = sqlite3.connect(jobs)
    con.executescript(
        "CREATE TABLE cron_jobs (id TEXT, delivery TEXT);"
        "CREATE TABLE cron_runs (job_id TEXT, started_at TEXT, finished_at TEXT, status TEXT);"
    )
    con.execute("INSERT INTO cron_jobs VALUES ('morning-brief', ?)",
                (json.dumps({"mode": "announce", "channel": "imessage", "max_wait_secs": 30}),))
    con.execute("INSERT INTO cron_runs VALUES ('morning-brief', ?, ?, 'ok')",
                (run.isoformat(), (run + timedelta(seconds=2)).isoformat()))
    con.commit(); con.close()
    chat = d / "chat.db"
    if chat_ok:
        con = sqlite3.connect(chat)
        con.execute("CREATE TABLE message (date INTEGER, text TEXT, is_from_me INTEGER)")
        # An owner self-note in the window that carries NO marker: must not count.
        con.execute("INSERT INTO message VALUES (?, ?, 1)",
                    (_mac(run + timedelta(seconds=20)), "Good morning. Note to self."))
        if message_at is not None:
            con.execute("INSERT INTO message VALUES (?, ?, 1)",
                        (_mac(run + timedelta(seconds=message_at)), ROBOT + " Good morning."))
        con.commit(); con.close()
    else:
        chat.write_bytes(b"not a database")
    log = d / "ostler-assistant.err"
    if disposition:
        stamp = (run + timedelta(seconds=3)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        log.write_text(f"\x1b[2m{stamp}\x1b[0m INFO scheduler: delivery={disposition} "
                       f"\x1b[3mjob_id\x1b[0m=morning-brief reached_customer=false\n")
    else:
        log.write_text("")
    return [jobs], chat, [log]


CASES = [
    # name, disposition, marked message offset (s) or None, chat readable, expected
    ("delivered and seen", "DELIVERED", 40, True, EX_PASS),
    ("logged DELIVERED, nothing in chat.db", "DELIVERED", None, True, EX_FAIL),
    ("logged FAILED, nothing in chat.db", "FAILED", None, True, EX_FAIL),
    ("message far outside the window", "DELIVERED", 6 * 3600, True, EX_FAIL),
    ("suppressed by the settle grace", "SUPPRESSED_SETTLING", None, True, EX_CANNOT),
    ("no disposition line, no message", None, None, True, EX_CANNOT),
    ("chat.db unreadable", "DELIVERED", 40, False, EX_CANNOT),
]


def self_test() -> int:
    now = datetime.now(timezone.utc)
    bad = 0
    for name, disp, at, chat_ok, want in CASES:
        with tempfile.TemporaryDirectory() as t:
            jobs, chat, logs = _fixture(Path(t), disposition=disp, message_at=at,
                                        chat_ok=chat_ok, now=now)
            _, rc = judge(collect(jobs, chat, logs, now=now))
        mark = "ok" if rc == want else "FAIL"
        bad += rc != want
        print(f"  {mark}   {name}: rc={rc} want={want}")
    with tempfile.TemporaryDirectory() as t:
        _, rc = judge(collect([Path(t) / "absent.db"], Path(t) / "c.db", [], now=now))
        bad += rc != EX_CANNOT
        print(f"  {'ok' if rc == EX_CANNOT else 'FAIL'}   no jobs.db: rc={rc} want={EX_CANNOT}")
    return 1 if bad else 0


def main(argv) -> int:
    if argv[1:2] == ["--self-test"]:
        return self_test()
    if argv[1:2] == ["box"]:
        cap = collect(JOBS_DB, CHAT_DB, LOGS)
        print(json.dumps(cap))
        return 0
    if argv[1:2] == ["judge"] and len(argv) == 3:
        lines, rc = judge(json.load(open(argv[2])))
        print("\n".join(lines))
        return rc
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
