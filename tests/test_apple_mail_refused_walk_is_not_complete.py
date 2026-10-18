"""A refused Apple Mail walk must not record "backfill complete".

Before: os.walk's onerror only logged, so an unreadable mail root walked as
empty, the tick wrote backfill_complete=true and exited 0, and after the
Full Disk Access grant older mail was never ingested. Synthetic data only.
"""
import json
import os
import stat
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor"))
from ostler_fda import apple_mail_mbox as m  # noqa: E402

pytestmark = pytest.mark.skipif(
    hasattr(os, "geteuid") and os.geteuid() == 0, reason="root ignores chmod 000"
)

NOW = datetime(2026, 10, 1, 12, 0, tzinfo=timezone.utc)


def _emlx(path: Path, when: datetime, n: int) -> None:
    body = (
        f"From: a@example.invalid\r\nTo: b@example.invalid\r\n"
        f"Subject: s{n}\r\nDate: {when.strftime('%a, %d %b %Y %H:%M:%S +0000')}\r\n"
        f"Message-ID: <{n}@example.invalid>\r\n\r\nhello {n}\r\n"
    ).encode()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(str(len(body)).encode() + b"\n" + body + b"<plist></plist>")


def _state(cp: Path) -> dict:
    return json.loads(cp.read_text()) if cp.exists() else {}


def test_unreadable_mail_root_raises_and_writes_no_completion(tmp_path):
    mail = tmp_path / "Mail"
    _emlx(mail / "V10" / "a.mbox" / "Messages" / "1.emlx", NOW - timedelta(days=400), 1)
    cp = tmp_path / "cp.json"
    mail.chmod(0)
    try:
        with pytest.raises(PermissionError):
            m.emit_mbox(tmp_path / "out.mbox", mail_dir=mail, checkpoint_path=cp, now=NOW)
    finally:
        mail.chmod(stat.S_IRWXU)
    assert _state(cp).get("backfill_complete") is not True
    assert not cp.exists()


def test_unreadable_subdir_holds_every_edge(tmp_path):
    mail = tmp_path / "Mail"
    _emlx(mail / "V10" / "ok.mbox" / "Messages" / "1.emlx", NOW - timedelta(days=1), 1)
    _emlx(mail / "V10" / "locked.mbox" / "Messages" / "2.emlx", NOW - timedelta(days=2), 2)
    cp = tmp_path / "cp.json"
    # seeded checkpoint: forward edge 10 days ago, backward edge same, not complete
    edge = NOW - timedelta(days=10)
    m.save_checkpoint(
        m.Checkpoint(newest_processed=edge, oldest_processed=edge,
                     backfill_complete=False, last_run_at=NOW, last_emit_count=0), cp)
    locked = mail / "V10" / "locked.mbox"
    locked.chmod(0)
    try:
        m.emit_mbox(tmp_path / "out.mbox", mail_dir=mail, checkpoint_path=cp, now=NOW)
    finally:
        locked.chmod(stat.S_IRWXU)
    st = _state(cp)
    assert st["backfill_complete"] is False
    assert st["newest_processed"].startswith(edge.strftime("%Y-%m-%dT%H:%M"))
    assert st["oldest_processed"].startswith(edge.strftime("%Y-%m-%dT%H:%M"))


def test_a_readable_empty_mailbox_still_completes(tmp_path):
    """Control: the guard must not turn a healthy empty tree into a failure."""
    mail = tmp_path / "Mail"
    mail.mkdir()
    cp = tmp_path / "cp.json"
    m.emit_mbox(tmp_path / "out.mbox", mail_dir=mail, checkpoint_path=cp, now=NOW)
    assert _state(cp)["backfill_complete"] is True
