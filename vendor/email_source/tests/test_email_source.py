"""Synthetic-fixture tests for the HR015 email conversation feed.

Builds a synthetic Apple Mail ``.emlx`` tree with SYNTHETIC data only
(no real names / addresses / transcripts), then exercises the reader,
threader, and the pipeline dispatch to a STUB pwg-convo. The stub
captures the transcript + metadata it was handed so we can assert the
four-artefact contract's inputs are correct, reference-graph threading
works, the watermark prevents re-dispatch, and a per-contact /
per-domain L3 mapping rides through to metadata.privacy_level.

Run from the HR015 repo root:
    python -m pytest email_source/tests/test_email_source.py
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime
from pathlib import Path

import pytest

# Make the repo root importable so `import email_source` and
# `import ostler_fda` both resolve when pytest runs from anywhere.
_REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_REPO_ROOT))

from email_source import reader, threader  # noqa: E402
from email_source.pipeline import process_email  # noqa: E402


# ---------------------------------------------------------------------------
# Synthetic .emlx fixture builder
# ---------------------------------------------------------------------------

USER_ADDRESS = "operator@example.test"


def _emlx_bytes(
    *,
    message_id: str,
    from_addr: str,
    from_name: str,
    to_addr: str,
    subject: str,
    dt: datetime,
    body: str,
    in_reply_to: str | None = None,
    references: list[str] | None = None,
) -> bytes:
    """Build one .emlx file's raw bytes.

    Format: ``<decimal byte-length>\\n<rfc822 bytes><trailing plist>``.
    parse_emlx reads the length prefix, slices the rfc822 portion, and
    discards the plist.
    """
    headers = [
        f"From: {from_name} <{from_addr}>",
        f"To: <{to_addr}>",
        f"Subject: {subject}",
        f"Date: {format_datetime(dt)}",
        f"Message-Id: <{message_id}>",
        "Content-Type: text/plain; charset=utf-8",
    ]
    if in_reply_to:
        headers.append(f"In-Reply-To: <{in_reply_to}>")
    if references:
        headers.append("References: " + " ".join(f"<{r}>" for r in references))
    rfc822 = ("\r\n".join(headers) + "\r\n\r\n" + body + "\r\n").encode("utf-8")
    plist = (
        b'<?xml version="1.0" encoding="UTF-8"?>\n'
        b'<plist version="1.0"><dict><key>flags</key>'
        b"<integer>0</integer></dict></plist>\n"
    )
    return f"{len(rfc822)}\n".encode("utf-8") + rfc822 + plist


def _write_emlx(mail_dir: Path, name: str, payload: bytes) -> None:
    """Drop one .emlx file deep in a realistic Apple Mail tree."""
    nested = (
        mail_dir
        / "V10"
        / "account.mbox"
        / "INBOX.mbox"
        / "ABCD-UUID"
        / "Data"
        / "1"
        / "Messages"
    )
    nested.mkdir(parents=True, exist_ok=True)
    (nested / f"{name}.emlx").write_bytes(payload)


def _build_two_threads(mail_dir: Path) -> None:
    """Two distinct synthetic threads.

    Thread A: a 3-message project sync conversation (reference graph).
    Thread B: a single-message thread from a separate counterpart.
    """
    base = datetime(2026, 5, 30, 10, 0, tzinfo=timezone.utc)
    alex = "alex@partner.test"

    # Thread A: root + two replies linked by In-Reply-To / References.
    _write_emlx(
        mail_dir,
        "a1",
        _emlx_bytes(
            message_id="threadA-root@partner.test",
            from_addr=alex,
            from_name="Alex Synthetic",
            to_addr=USER_ADDRESS,
            subject="Project sync tomorrow",
            dt=base,
            body="Hi, are we still on for the project sync at 2pm tomorrow?",
        ),
    )
    _write_emlx(
        mail_dir,
        "a2",
        _emlx_bytes(
            message_id="threadA-r1@example.test",
            from_addr=USER_ADDRESS,
            from_name="Operator Synthetic",
            to_addr=alex,
            subject="Re: Project sync tomorrow",
            dt=base + timedelta(minutes=20),
            body="Yes. I will book Room 3 and send the invite shortly.",
            in_reply_to="threadA-root@partner.test",
            references=["threadA-root@partner.test"],
        ),
    )
    _write_emlx(
        mail_dir,
        "a3",
        _emlx_bytes(
            message_id="threadA-r2@partner.test",
            from_addr=alex,
            from_name="Alex Synthetic",
            to_addr=USER_ADDRESS,
            subject="Re: Project sync tomorrow",
            dt=base + timedelta(minutes=35),
            body="Great, I will send the deck beforehand.",
            in_reply_to="threadA-r1@example.test",
            references=["threadA-root@partner.test", "threadA-r1@example.test"],
        ),
    )

    # Thread B: a separate single-message thread.
    _write_emlx(
        mail_dir,
        "b1",
        _emlx_bytes(
            message_id="threadB-root@vendor.test",
            from_addr="sam@vendor.test",
            from_name="Sam Synthetic",
            to_addr=USER_ADDRESS,
            subject="Invoice question",
            dt=base + timedelta(hours=3),
            body="Quick question about last month's invoice line item.",
        ),
    )


# ---------------------------------------------------------------------------
# pwg-convo stub
# ---------------------------------------------------------------------------


class _StubDispatch:
    """Captures everything that would have gone to pwg-convo."""

    def make_cmd(self, tmp_path: Path) -> list[str]:
        capture = tmp_path / "capture.jsonl"
        script = tmp_path / "fake_pwg_convo.py"
        script.write_text(
            "import json, sys\n"
            "args = sys.argv[1:]\n"
            "ti = args.index('process')\n"
            "tpath = args[ti + 1]\n"
            "mpath = args[ti + 2]\n"
            "rec = {\n"
            "  'transcript': open(tpath).read(),\n"
            "  'metadata': json.load(open(mpath)),\n"
            "  'dry_run': '--dry-run' in args,\n"
            "}\n"
            f"open({str(capture)!r}, 'a').write(json.dumps(rec) + '\\n')\n"
        )
        self._capture = capture
        return [sys.executable, str(script)]

    def load(self) -> list[dict]:
        if not self._capture.exists():
            return []
        return [json.loads(line) for line in self._capture.read_text().splitlines()]


# ---------------------------------------------------------------------------
# Reader + threader
# ---------------------------------------------------------------------------


def test_reader_reads_all_messages(tmp_path):
    mail = tmp_path / "Mail"
    _build_two_threads(mail)
    msgs = reader.read_messages(mail_dir=mail, since_days=0)
    assert len(msgs) == 4
    subjects = {m.subject for m in msgs}
    assert "Project sync tomorrow" in subjects
    assert "Invoice question" in subjects
    # In-Reply-To / References parsed.
    r2 = [m for m in msgs if m.message_id == "threadA-r2@partner.test"][0]
    assert r2.in_reply_to == "threadA-r1@example.test"
    assert "threadA-root@partner.test" in r2.references


def test_threader_groups_reference_graph(tmp_path):
    mail = tmp_path / "Mail"
    _build_two_threads(mail)
    msgs = reader.read_messages(mail_dir=mail, since_days=0)
    threads = threader.thread_messages(msgs)
    assert len(threads) == 2
    by_count = sorted(len(t.messages) for t in threads)
    assert by_count == [1, 3]  # thread A has 3, thread B has 1
    # conversation_ids stable + distinct.
    ids = {t.conversation_id for t in threads}
    assert len(ids) == 2


def test_transcript_and_metadata_shape(tmp_path):
    mail = tmp_path / "Mail"
    _build_two_threads(mail)
    msgs = reader.read_messages(mail_dir=mail, since_days=0)
    threads = threader.thread_messages(msgs)
    thread_a = [t for t in threads if len(t.messages) == 3][0]

    name_for = lambda a: {"alex@partner.test": "Alex Synthetic"}.get(a, a)
    transcript = threader.render_transcript(
        thread_a, user_address=USER_ADDRESS, name_for_address=name_for
    )
    assert "**Alex Synthetic**" in transcript
    assert "**You**" in transcript
    assert "# Project sync tomorrow" in transcript

    meta = threader.build_metadata(
        thread_a,
        user_display_name="Operator Synthetic",
        user_address=USER_ADDRESS,
        name_for_address=name_for,
    )
    assert meta["channel"] == "email"
    assert meta["source"] == "email"
    assert meta["source_app"] == "mail"
    assert meta["capture_source"] == "hr015_email_source"
    # email_thread sidecar (consumed by CM048 _email_adapter).
    sidecar = meta["email_thread"]
    assert sidecar["message_count"] == 3
    assert sidecar["thread_id"] == "threadA-root@partner.test"
    assert len(sidecar["message_ids"]) == 3
    assert sidecar["first_message_at"] and sidecar["last_message_at"]
    # participants: user first with email, then the other with email.
    roles = [p["role"] for p in meta["participants"]]
    assert roles[0] == "user"
    assert meta["participants"][0]["email"] == USER_ADDRESS
    other = [p for p in meta["participants"] if p["role"] == "other"]
    assert any(p["email"] == "alex@partner.test" for p in other)


# ---------------------------------------------------------------------------
# Pipeline dispatch + watermark
# ---------------------------------------------------------------------------


def test_pipeline_dispatches_both_threads(tmp_path):
    mail = tmp_path / "Mail"
    _build_two_threads(mail)
    stub = _StubDispatch()
    cmd = stub.make_cmd(tmp_path)
    state = tmp_path / "state.json"

    summary = process_email(
        mail_dir=mail,
        user_display_name="Operator Synthetic",
        user_address=USER_ADDRESS,
        since_days=0,
        pwg_convo_cmd=cmd,
        state_path=state,
    )
    assert summary["threads_dispatched"] == 2
    assert summary["threads_failed"] == 0
    calls = stub.load()
    assert len(calls) == 2
    for c in calls:
        assert c["metadata"]["channel"] == "email"
        assert c["metadata"]["capture_source"] == "hr015_email_source"
        assert c["transcript"].count("**") >= 2


def test_watermark_prevents_redispatch(tmp_path):
    mail = tmp_path / "Mail"
    _build_two_threads(mail)
    stub = _StubDispatch()
    cmd = stub.make_cmd(tmp_path)
    state = tmp_path / "state.json"

    first = process_email(
        mail_dir=mail, user_display_name="Op", user_address=USER_ADDRESS,
        since_days=0, pwg_convo_cmd=cmd, state_path=state,
    )
    assert first["threads_dispatched"] == 2
    # Second tick: same mailbox, nothing new -> all skipped.
    second = process_email(
        mail_dir=mail, user_display_name="Op", user_address=USER_ADDRESS,
        since_days=0, pwg_convo_cmd=cmd, state_path=state,
    )
    assert second["threads_dispatched"] == 0
    assert second["threads_skipped"] == 2


def test_new_reply_redispatches_thread(tmp_path):
    mail = tmp_path / "Mail"
    _build_two_threads(mail)
    stub = _StubDispatch()
    cmd = stub.make_cmd(tmp_path)
    state = tmp_path / "state.json"

    process_email(
        mail_dir=mail, user_display_name="Op", user_address=USER_ADDRESS,
        since_days=0, pwg_convo_cmd=cmd, state_path=state,
    )
    # A new reply lands on thread A.
    base = datetime(2026, 5, 30, 10, 0, tzinfo=timezone.utc)
    _write_emlx(
        mail,
        "a4",
        _emlx_bytes(
            message_id="threadA-r3@example.test",
            from_addr=USER_ADDRESS,
            from_name="Operator Synthetic",
            to_addr="alex@partner.test",
            subject="Re: Project sync tomorrow",
            dt=base + timedelta(hours=1),
            body="Booked. See you at 2.",
            in_reply_to="threadA-r2@partner.test",
            references=["threadA-root@partner.test", "threadA-r2@partner.test"],
        ),
    )
    second = process_email(
        mail_dir=mail, user_display_name="Op", user_address=USER_ADDRESS,
        since_days=0, pwg_convo_cmd=cmd, state_path=state,
    )
    # Thread A re-dispatched (new reply), thread B still skipped.
    assert second["threads_dispatched"] == 1
    assert second["threads_skipped"] == 1


def test_since_days_clamp(tmp_path):
    """A message outside the since-days window is not read."""
    mail = tmp_path / "Mail"
    old = datetime.now(timezone.utc) - timedelta(days=400)
    _write_emlx(
        mail,
        "old",
        _emlx_bytes(
            message_id="ancient@vendor.test",
            from_addr="sam@vendor.test",
            from_name="Sam Synthetic",
            to_addr=USER_ADDRESS,
            subject="Old thread",
            dt=old,
            body="This is well outside the clamp window.",
        ),
    )
    recent = reader.read_messages(mail_dir=mail, since_days=30)
    assert recent == []
    everything = reader.read_messages(mail_dir=mail, since_days=0)
    assert len(everything) == 1


# ---------------------------------------------------------------------------
# L3 privacy map (operator override)
# ---------------------------------------------------------------------------


def test_l3_address_map_rides_through(tmp_path):
    mail = tmp_path / "Mail"
    _build_two_threads(mail)
    contacts = tmp_path / "contacts.yaml"
    contacts.write_text(
        "contacts:\n"
        '  "alex@partner.test":\n'
        '    name: "Alex Synthetic"\n'
        '    privacy_level: "L3"\n'
    )
    stub = _StubDispatch()
    cmd = stub.make_cmd(tmp_path)
    state = tmp_path / "state.json"
    process_email(
        mail_dir=mail, contacts_path=contacts,
        user_display_name="Op", user_address=USER_ADDRESS,
        since_days=0, pwg_convo_cmd=cmd, state_path=state,
    )
    calls = stub.load()
    # Thread A (with the L3-mapped address) must carry privacy_level L3.
    thread_a = [
        c for c in calls
        if c["metadata"]["email_thread"]["thread_id"] == "threadA-root@partner.test"
    ]
    assert thread_a, "thread A should have dispatched"
    assert thread_a[0]["metadata"]["privacy_level"] == "L3", (
        "L3 address mapping must ride through to metadata so CM048's "
        "writer short-circuits the gist arm"
    )
    # Thread B (unmapped) must NOT be forced L3 by us -- CM048's own
    # ladder decides.
    thread_b = [
        c for c in calls
        if c["metadata"]["email_thread"]["thread_id"] == "threadB-root@vendor.test"
    ]
    assert thread_b
    assert "privacy_level" not in thread_b[0]["metadata"]


def test_l3_domain_map_rides_through(tmp_path):
    """A bare-domain L3 entry marks every address on that domain L3."""
    mail = tmp_path / "Mail"
    _build_two_threads(mail)
    contacts = tmp_path / "contacts.yaml"
    contacts.write_text(
        "contacts:\n"
        '  "vendor.test":\n'
        '    privacy_level: "L3"\n'
    )
    stub = _StubDispatch()
    cmd = stub.make_cmd(tmp_path)
    state = tmp_path / "state.json"
    process_email(
        mail_dir=mail, contacts_path=contacts,
        user_display_name="Op", user_address=USER_ADDRESS,
        since_days=0, pwg_convo_cmd=cmd, state_path=state,
    )
    calls = stub.load()
    thread_b = [
        c for c in calls
        if c["metadata"]["email_thread"]["thread_id"] == "threadB-root@vendor.test"
    ]
    assert thread_b
    assert thread_b[0]["metadata"]["privacy_level"] == "L3"
