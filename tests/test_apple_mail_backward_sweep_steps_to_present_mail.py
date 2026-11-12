"""The backward sweep must step to the next OLDER message that exists.

Before: a fixed 30-day chunk per tick, so one mis-dated header (a 1970 epoch
Date is real) kept the sweep alive for ~56 years of empty chunks, one hourly
tick each. After: the edge jumps to the next older message present and the
sweep completes when none older remains. Synthetic data only.
"""
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor"))
from ostler_fda import apple_mail_mbox as m  # noqa: E402

NOW = datetime(2026, 10, 1, 12, 0, tzinfo=timezone.utc)


def _emlx(mail: Path, name: str, when: datetime, n: int) -> None:
    body = (
        f"From: a@example.invalid\r\nTo: b@example.invalid\r\nSubject: s{n}\r\n"
        f"Date: {when.strftime('%a, %d %b %Y %H:%M:%S +0000')}\r\n"
        f"Message-ID: <{n}@example.invalid>\r\n\r\nhello {n}\r\n"
    ).encode()
    p = mail / "V10" / "a.mbox" / "Messages" / f"{name}.emlx"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(str(len(body)).encode() + b"\n" + body + b"<plist></plist>")


def _run_to_completion(tmp_path, dates, max_ticks=12):
    mail = tmp_path / "Mail"
    for i, d in enumerate(dates):
        _emlx(mail, str(i), d, i)
    cp = tmp_path / "cp.json"
    emitted, ticks = [], 0
    while ticks < max_ticks:
        ticks += 1
        out = tmp_path / f"out{ticks}.mbox"
        n = m.emit_mbox(out, mail_dir=mail, checkpoint_path=cp, backfill_window_days=1825,
                        backfill_chunk_days=30, now=NOW + timedelta(hours=ticks))
        emitted.append(n)
        if json.loads(cp.read_text())["backfill_complete"]:
            break
    return emitted, ticks, json.loads(cp.read_text())


def test_epoch_dated_message_does_not_cost_56_years_of_ticks(tmp_path):
    dates = [
        NOW - timedelta(days=3),                 # inside the 5-year seed window
        NOW - timedelta(days=2000),              # older than the window
        NOW - timedelta(days=4000),              # a decade back
        datetime(1970, 1, 1, tzinfo=timezone.utc),  # mis-dated header
    ]
    emitted, ticks, st = _run_to_completion(tmp_path, dates)
    assert st["backfill_complete"] is True, f"not complete after {ticks} ticks: {emitted}"
    assert sum(emitted) == len(dates), f"every message emitted exactly once: {emitted}"
    assert ticks <= 5, f"{ticks} ticks for 3 older messages: the sweep stepped through empty chunks"


def test_sweep_does_not_complete_while_older_mail_remains(tmp_path):
    """Control: completion must still wait for the oldest message."""
    dates = [NOW - timedelta(days=3), NOW - timedelta(days=2000), NOW - timedelta(days=9000)]
    mail = tmp_path / "Mail"
    for i, d in enumerate(dates):
        _emlx(mail, str(i), d, i)
    cp = tmp_path / "cp.json"
    m.emit_mbox(tmp_path / "o1.mbox", mail_dir=mail, checkpoint_path=cp,
                backfill_window_days=1825, now=NOW)            # seed
    m.emit_mbox(tmp_path / "o2.mbox", mail_dir=mail, checkpoint_path=cp,
                backfill_window_days=1825, now=NOW + timedelta(hours=1))  # 2000d message
    assert json.loads(cp.read_text())["backfill_complete"] is False
