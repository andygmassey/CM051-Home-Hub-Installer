"""Tests for Google Takeout (Gmail mbox) extractor.

These tests construct real mbox files in tmpdir using the standard
library's mailbox module and feed them to the extractor. That way
the parsing path is exercised end-to-end without any vendored fixtures.
"""
from __future__ import annotations

import mailbox
import zipfile
from datetime import datetime, timedelta, timezone
from email.message import Message
from email.utils import format_datetime
from pathlib import Path

import pytest

from ostler_fda.google_takeout import (
    DEFAULT_BODY_PREVIEW_CHARS,
    TAKEOUT_ZIP_PATTERN,
    extract_mbox_from_zip,
    find_mbox_files,
    find_takeout_zips,
    stream_messages,
    summarise,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_message(
    sender: str = "alice@example.com",
    sender_name: str = "Alice",
    recipient: str = "bob@example.com",
    subject: str = "Hello",
    body: str = "This is the body of the email.",
    date: datetime | None = None,
    labels: list[str] | None = None,
    message_id: str | None = None,
) -> Message:
    msg = Message()
    msg["From"] = f'"{sender_name}" <{sender}>'
    msg["To"] = recipient
    msg["Subject"] = subject
    if date is not None:
        msg["Date"] = format_datetime(date)
    if labels:
        msg["X-Gmail-Labels"] = ",".join(labels)
    if message_id:
        msg["Message-ID"] = f"<{message_id}>"
    msg.set_payload(body)
    return msg


def _write_mbox(path: Path, messages: list[Message]) -> Path:
    box = mailbox.mbox(str(path), create=True)
    box.lock()
    try:
        for m in messages:
            box.add(m)
        box.flush()
    finally:
        box.unlock()
        box.close()
    return path


# ---------------------------------------------------------------------------
# Discovery functions
# ---------------------------------------------------------------------------


class TestTakeoutZipPattern:
    def test_matches_real_takeout_filename(self):
        assert TAKEOUT_ZIP_PATTERN.match("takeout-20260113T064626Z-1-001.zip")
        assert TAKEOUT_ZIP_PATTERN.match("takeout-20260113T064626Z-9-001.zip")
        assert TAKEOUT_ZIP_PATTERN.match("takeout-20260113T064626Z.zip")

    def test_rejects_non_takeout(self):
        assert not TAKEOUT_ZIP_PATTERN.match("not-a-takeout.zip")
        assert not TAKEOUT_ZIP_PATTERN.match("takeout.zip")
        assert not TAKEOUT_ZIP_PATTERN.match("takeout-2026.zip")
        assert not TAKEOUT_ZIP_PATTERN.match("takeout-20260113T064626.zip")  # no Z


class TestFindTakeoutZips:
    def test_finds_takeout_in_dir(self, tmp_path):
        (tmp_path / "takeout-20260113T064626Z-1-001.zip").write_bytes(b"x")
        (tmp_path / "random.zip").write_bytes(b"x")
        found = find_takeout_zips([tmp_path])
        assert len(found) == 1
        assert found[0].name == "takeout-20260113T064626Z-1-001.zip"

    def test_returns_empty_when_no_match(self, tmp_path):
        (tmp_path / "holiday.zip").write_bytes(b"x")
        assert find_takeout_zips([tmp_path]) == []

    def test_handles_missing_directories(self, tmp_path):
        nonexistent = tmp_path / "does_not_exist"
        assert find_takeout_zips([nonexistent]) == []


class TestFindMboxFiles:
    def test_finds_top_level_mbox(self, tmp_path):
        (tmp_path / "All mail.mbox").write_text("From x\n")
        found = find_mbox_files([tmp_path])
        assert len(found) == 1

    def test_finds_nested_mbox(self, tmp_path):
        nested = tmp_path / "Takeout" / "Mail"
        nested.mkdir(parents=True)
        (nested / "All mail Including Spam and Trash.mbox").write_text("")
        found = find_mbox_files([tmp_path])
        assert len(found) == 1
        assert found[0].name == "All mail Including Spam and Trash.mbox"

    def test_caps_recursion_depth(self, tmp_path):
        deep = tmp_path / "a" / "b" / "c" / "d" / "e"
        deep.mkdir(parents=True)
        (deep / "deep.mbox").write_text("")
        # depth 5 — should be excluded by the depth cap (max 4)
        found = find_mbox_files([tmp_path])
        assert len(found) == 0


# ---------------------------------------------------------------------------
# Zip extraction
# ---------------------------------------------------------------------------


class TestExtractMboxFromZip:
    def test_extracts_mbox_from_zip(self, tmp_path):
        # Build a fake Takeout zip with one mbox inside
        zip_path = tmp_path / "takeout-20260113T064626Z-1-001.zip"
        with zipfile.ZipFile(zip_path, "w") as zf:
            zf.writestr("Takeout/Mail/All mail.mbox", "From x@y 1\nSubject: hi\n\nbody\n")

        dest = tmp_path / "out"
        extracted = extract_mbox_from_zip(zip_path, dest)
        assert extracted is not None
        assert extracted.exists()
        assert extracted.name == "All mail.mbox"

    def test_returns_none_when_no_mbox_in_zip(self, tmp_path):
        zip_path = tmp_path / "takeout-no-mail.zip"
        with zipfile.ZipFile(zip_path, "w") as zf:
            zf.writestr("Takeout/Calendar/cal.ics", "BEGIN:VCALENDAR\nEND:VCALENDAR\n")
        dest = tmp_path / "out"
        assert extract_mbox_from_zip(zip_path, dest) is None

    def test_handles_corrupt_zip(self, tmp_path):
        bad = tmp_path / "corrupt.zip"
        bad.write_bytes(b"not a zip file")
        dest = tmp_path / "out"
        assert extract_mbox_from_zip(bad, dest) is None


# ---------------------------------------------------------------------------
# Message streaming
# ---------------------------------------------------------------------------


class TestStreamMessages:
    def test_streams_simple_messages(self, tmp_path):
        mbox_path = tmp_path / "test.mbox"
        _write_mbox(
            mbox_path,
            [
                _make_message(subject="One", body="Body one", message_id="msg-1"),
                _make_message(subject="Two", body="Body two", message_id="msg-2"),
            ],
        )
        msgs = list(stream_messages(mbox_path))
        assert len(msgs) == 2
        assert msgs[0].subject == "One"
        assert msgs[1].subject == "Two"
        assert msgs[0].body_preview == "Body one"

    def test_extracts_from_address_and_domain(self, tmp_path):
        mbox_path = tmp_path / "test.mbox"
        _write_mbox(
            mbox_path,
            [_make_message(sender="founder@example.com", sender_name="Some Person")],
        )
        msgs = list(stream_messages(mbox_path))
        assert msgs[0].from_address == "founder@example.com"
        assert msgs[0].from_domain == "example.com"
        assert msgs[0].from_name == "Some Person"

    def test_extracts_gmail_labels(self, tmp_path):
        mbox_path = tmp_path / "test.mbox"
        _write_mbox(
            mbox_path,
            [_make_message(labels=["Inbox", "Cricket Club", "Important"])],
        )
        msgs = list(stream_messages(mbox_path))
        assert "Cricket Club" in msgs[0].gmail_labels
        assert "Inbox" in msgs[0].gmail_labels

    def test_since_days_filter(self, tmp_path):
        mbox_path = tmp_path / "test.mbox"
        old = datetime.now(timezone.utc) - timedelta(days=400)
        recent = datetime.now(timezone.utc) - timedelta(days=10)
        _write_mbox(
            mbox_path,
            [
                _make_message(subject="Old", date=old, message_id="old"),
                _make_message(subject="Recent", date=recent, message_id="recent"),
            ],
        )
        # 365-day cutoff drops the old one
        msgs = list(stream_messages(mbox_path, since_days=365))
        subjects = {m.subject for m in msgs}
        assert "Recent" in subjects
        assert "Old" not in subjects

    def test_limit_caps_yield_count(self, tmp_path):
        mbox_path = tmp_path / "test.mbox"
        _write_mbox(
            mbox_path,
            [_make_message(subject=f"M{i}", message_id=f"m{i}") for i in range(10)],
        )
        msgs = list(stream_messages(mbox_path, limit=3))
        assert len(msgs) == 3

    def test_marks_sent_via_user_email_match(self, tmp_path):
        mbox_path = tmp_path / "test.mbox"
        _write_mbox(
            mbox_path,
            [
                _make_message(sender="me@example.com", subject="Sent", message_id="s"),
                _make_message(sender="alice@example.com", subject="Recv", message_id="r"),
            ],
        )
        msgs = list(stream_messages(mbox_path, user_email="ME@example.com"))
        sent = [m for m in msgs if m.is_sent]
        recv = [m for m in msgs if not m.is_sent]
        assert len(sent) == 1 and sent[0].subject == "Sent"
        assert len(recv) == 1 and recv[0].subject == "Recv"

    def test_marks_sent_via_gmail_label(self, tmp_path):
        mbox_path = tmp_path / "test.mbox"
        _write_mbox(
            mbox_path,
            [_make_message(labels=["Sent"], subject="A reply", message_id="s")],
        )
        msgs = list(stream_messages(mbox_path))
        assert msgs[0].is_sent is True

    def test_decodes_rfc2047_subject(self, tmp_path):
        mbox_path = tmp_path / "test.mbox"
        # =?utf-8?b?...?= = base64-encoded UTF-8 subject
        _write_mbox(
            mbox_path,
            [_make_message(subject="=?utf-8?b?Q3JpY2tldCBDbHVi?=", message_id="x")],
        )
        msgs = list(stream_messages(mbox_path))
        assert "Cricket Club" in msgs[0].subject

    def test_body_preview_capped_at_max_chars(self, tmp_path):
        mbox_path = tmp_path / "test.mbox"
        long_body = "x" * (DEFAULT_BODY_PREVIEW_CHARS * 3)
        _write_mbox(
            mbox_path,
            [_make_message(body=long_body, message_id="long")],
        )
        msgs = list(stream_messages(mbox_path))
        assert len(msgs[0].body_preview) <= DEFAULT_BODY_PREVIEW_CHARS

    def test_missing_file_raises(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            list(stream_messages(tmp_path / "missing.mbox"))


# ---------------------------------------------------------------------------
# Summarise
# ---------------------------------------------------------------------------


class TestSummarise:
    def test_counts_total_and_sent_received(self, tmp_path):
        mbox_path = tmp_path / "test.mbox"
        _write_mbox(
            mbox_path,
            [
                _make_message(sender="me@example.com", subject="s1", message_id="1"),
                _make_message(sender="alice@example.com", subject="r1", message_id="2"),
                _make_message(sender="bob@example.com", subject="r2", message_id="3"),
            ],
        )
        msgs = list(stream_messages(mbox_path, user_email="me@example.com"))
        s = summarise(msgs)
        assert s.total_messages == 3
        assert s.sent_count == 1
        assert s.received_count == 2

    def test_top_senders_ranks_by_count(self, tmp_path):
        mbox_path = tmp_path / "test.mbox"
        _write_mbox(
            mbox_path,
            [
                _make_message(sender="alice@test.local", message_id=f"a{i}")
                for i in range(5)
            ] + [
                _make_message(sender="bob@example.com", message_id=f"b{i}")
                for i in range(2)
            ],
        )
        s = summarise(list(stream_messages(mbox_path)))
        assert s.top_senders[0][0] == "alice@test.local"
        assert s.top_senders[0][1] == 5
        assert s.top_sender_domains[0][0] == "test.local"

    def test_by_year_groups_correctly(self, tmp_path):
        mbox_path = tmp_path / "test.mbox"
        _write_mbox(
            mbox_path,
            [
                _make_message(date=datetime(2025, 6, 1, tzinfo=timezone.utc), message_id="2025"),
                _make_message(date=datetime(2026, 3, 1, tzinfo=timezone.utc), message_id="2026a"),
                _make_message(date=datetime(2026, 4, 1, tzinfo=timezone.utc), message_id="2026b"),
            ],
        )
        s = summarise(list(stream_messages(mbox_path)))
        assert s.by_year[2025] == 1
        assert s.by_year[2026] == 2

    def test_gmail_labels_aggregate(self, tmp_path):
        mbox_path = tmp_path / "test.mbox"
        _write_mbox(
            mbox_path,
            [
                _make_message(labels=["Inbox", "Cricket Club"], message_id="1"),
                _make_message(labels=["Inbox", "Important"], message_id="2"),
                _make_message(labels=["Cricket Club"], message_id="3"),
            ],
        )
        s = summarise(list(stream_messages(mbox_path)))
        assert s.gmail_labels["Inbox"] == 2
        assert s.gmail_labels["Cricket Club"] == 2
        assert s.gmail_labels["Important"] == 1
