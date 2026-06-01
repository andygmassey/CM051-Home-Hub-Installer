"""Tests for the Apple Mail mbox emitter (CM046 LaunchAgent feed).

Synthesises a tiny Apple Mail directory tree under ``tmp_path`` with
a handful of ``.emlx`` files at known paths + dates, runs the
emitter, and asserts:

- the output mbox contains one well-formed record per fresh message,
- the checkpoint advances to the latest emitted ``received_at``,
- a re-run with no new files emits zero messages,
- adding a new message and re-running picks up exactly that one,
- the checkpoint format is forward-compatible (versioned JSON the
  emitter can read back).
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime
from pathlib import Path

import pytest

from ostler_fda.apple_mail_mbox import (
    CHECKPOINT_SCHEMA_VERSION,
    Checkpoint,
    emit_mbox,
    load_checkpoint,
    parse_emlx,
    save_checkpoint,
)


# ---------------------------------------------------------------------------
# Fixtures: build a synthetic Apple Mail tree under tmp_path
# ---------------------------------------------------------------------------


def _emlx_bytes(*, sender: str, to: str, subject: str, body: str,
                date: datetime, message_id: str) -> bytes:
    """Build a synthetic .emlx file body.

    Apple's format:
        \\d+\\n          length prefix in bytes
        <RFC 822>      exactly that many bytes
        <plist trailer> (we omit -- emitter clips to length anyway)
    """
    rfc822_lines = [
        f"From: {sender}",
        f"To: {to}",
        f"Subject: {subject}",
        f"Date: {format_datetime(date)}",
        f"Message-ID: <{message_id}>",
        "Content-Type: text/plain; charset=utf-8",
        "",
        body,
        "",
    ]
    rfc822 = ("\r\n".join(rfc822_lines)).encode("utf-8")
    prefix = f"{len(rfc822)}\n".encode("utf-8")
    # Trailing plist (real Apple files always have one; emitter ignores it).
    plist = (
        b"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        b"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\""
        b" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        b"<plist version=\"1.0\"><dict><key>flags</key><integer>0</integer>"
        b"</dict></plist>\n"
    )
    return prefix + rfc822 + plist


def _write_emlx(mail_dir: Path, *, account: str, folder: str, msg_id: str,
                **kwargs) -> Path:
    """Write one .emlx into a path that mirrors the Apple layout."""
    target_dir = (
        mail_dir
        / "V10"
        / f"{account}.mbox"
        / f"{folder}.mbox"
        / "0F0E0E00-AAAA-4444-AAAA-000000000000"
        / "Data" / "0" / "0" / "0" / "Messages"
    )
    target_dir.mkdir(parents=True, exist_ok=True)
    p = target_dir / f"{msg_id}.emlx"
    p.write_bytes(_emlx_bytes(message_id=msg_id, **kwargs))
    return p


@pytest.fixture
def synthetic_mail_dir(tmp_path):
    """Five-message Apple Mail tree, dates spaced one day apart."""
    mail_dir = tmp_path / "Mail"
    base = datetime(2026, 4, 25, 12, 0, 0, tzinfo=timezone.utc)
    for i in range(5):
        _write_emlx(
            mail_dir,
            account="iCloud", folder="INBOX",
            msg_id=f"msg{i:04d}",
            sender=f"alice{i}@example.test",
            to="andy@example.test",
            subject=f"Test message {i}",
            body=f"Body for message {i}.\nLine two.\n",
            date=base + timedelta(days=i),
        )
    return mail_dir


# ---------------------------------------------------------------------------
# parse_emlx
# ---------------------------------------------------------------------------


def test_parse_emlx_returns_rfc822_body(synthetic_mail_dir):
    """The returned bytes should be the RFC 822 portion only -- length
    prefix stripped, trailing plist clipped."""
    files = list(synthetic_mail_dir.rglob("*.emlx"))
    assert len(files) == 5
    parsed = parse_emlx(files[0])
    assert parsed.rfc822_bytes.startswith(b"From: alice")
    # The plist trailer must not be in the returned bytes.
    assert b"<plist" not in parsed.rfc822_bytes
    assert b"</dict>" not in parsed.rfc822_bytes


def test_parse_emlx_extracts_date_and_sender(synthetic_mail_dir):
    files = sorted(synthetic_mail_dir.rglob("*.emlx"))
    parsed = parse_emlx(files[0])
    assert parsed.received_at is not None
    assert parsed.received_at.year == 2026
    assert parsed.received_at.month == 4
    assert parsed.sender_address == "alice0@example.test"


def test_parse_emlx_rejects_missing_length_prefix(tmp_path):
    bad = tmp_path / "bad.emlx"
    bad.write_bytes(b"not-a-length-prefixed-emlx")
    with pytest.raises(ValueError, match="malformed"):
        parse_emlx(bad)


# ---------------------------------------------------------------------------
# emit_mbox: happy path + idempotency
# ---------------------------------------------------------------------------


def test_emit_mbox_writes_all_messages_first_run(tmp_path, synthetic_mail_dir):
    mbox = tmp_path / "out" / "2026-05-01-12.mbox.txt"
    checkpoint = tmp_path / "state" / "apple_mail_mbox_checkpoint.json"

    count = emit_mbox(
        mbox, mail_dir=synthetic_mail_dir, checkpoint_path=checkpoint,
    )
    assert count == 5
    assert mbox.exists()
    body = mbox.read_bytes()

    # Five mbox records, identifiable by the From-line separator.
    from_lines = [line for line in body.split(b"\n") if line.startswith(b"From ")]
    assert len(from_lines) == 5

    # Headers + bodies survived round-trip into the mbox.
    assert b"Subject: Test message 0" in body
    assert b"Body for message 0." in body
    assert b"Subject: Test message 4" in body


def test_emit_mbox_advances_checkpoint(tmp_path, synthetic_mail_dir):
    mbox = tmp_path / "out.mbox"
    checkpoint = tmp_path / "checkpoint.json"
    emit_mbox(mbox, mail_dir=synthetic_mail_dir, checkpoint_path=checkpoint)

    cp = load_checkpoint(checkpoint)
    assert cp.newest_processed is not None
    # Latest message in the synthetic tree is base + 4 days.
    assert cp.newest_processed.day == 29
    assert cp.last_emit_count == 5
    assert cp.schema_version == CHECKPOINT_SCHEMA_VERSION


def test_emit_mbox_second_run_is_idempotent(tmp_path, synthetic_mail_dir):
    """Second run with no new messages must emit zero, leave mbox unchanged
    (still appended with zero bytes), and update last_run_at without
    bumping newest_processed."""
    mbox = tmp_path / "out.mbox"
    checkpoint = tmp_path / "checkpoint.json"
    emit_mbox(mbox, mail_dir=synthetic_mail_dir, checkpoint_path=checkpoint)
    size_after_first = mbox.stat().st_size
    cp_first = load_checkpoint(checkpoint)

    count = emit_mbox(mbox, mail_dir=synthetic_mail_dir, checkpoint_path=checkpoint)
    assert count == 0
    assert mbox.stat().st_size == size_after_first

    cp_second = load_checkpoint(checkpoint)
    assert cp_second.newest_processed == cp_first.newest_processed
    assert cp_second.last_emit_count == 0
    # last_run_at should have advanced (or at minimum not gone backwards).
    if cp_first.last_run_at is not None and cp_second.last_run_at is not None:
        assert cp_second.last_run_at >= cp_first.last_run_at


def test_emit_mbox_picks_up_only_new_messages_on_third_run(
    tmp_path, synthetic_mail_dir,
):
    """First run emits the original 5; add a sixth, second run emits one."""
    mbox = tmp_path / "out.mbox"
    checkpoint = tmp_path / "checkpoint.json"
    first = emit_mbox(
        mbox, mail_dir=synthetic_mail_dir, checkpoint_path=checkpoint,
    )
    assert first == 5

    # Add a message dated AFTER the latest existing one.
    new_date = datetime(2026, 4, 30, 15, 0, 0, tzinfo=timezone.utc)
    _write_emlx(
        synthetic_mail_dir,
        account="iCloud", folder="INBOX",
        msg_id="msg9999",
        sender="bob@example.test",
        to="andy@example.test",
        subject="Hello from later",
        body="A new message.",
        date=new_date,
    )

    second = emit_mbox(
        mbox, mail_dir=synthetic_mail_dir, checkpoint_path=checkpoint,
    )
    assert second == 1

    cp = load_checkpoint(checkpoint)
    assert cp.newest_processed is not None
    assert cp.newest_processed.day == 30

    # The mbox now contains 6 records total.
    body = mbox.read_bytes()
    from_lines = [line for line in body.split(b"\n") if line.startswith(b"From ")]
    assert len(from_lines) == 6
    assert b"Subject: Hello from later" in body


# ---------------------------------------------------------------------------
# Checkpoint forward-compat
# ---------------------------------------------------------------------------


def test_checkpoint_is_versioned_json(tmp_path):
    """The on-disk format must be readable JSON with a schema_version
    field so future migrations can lift it without breaking older
    LaunchAgent installs."""
    checkpoint = tmp_path / "checkpoint.json"
    save_checkpoint(
        Checkpoint(
            newest_processed=datetime(2026, 5, 1, tzinfo=timezone.utc),
            last_run_at=datetime(2026, 5, 1, tzinfo=timezone.utc),
            last_emit_count=3,
        ),
        checkpoint,
    )
    body = json.loads(checkpoint.read_text())
    assert body["schema_version"] == CHECKPOINT_SCHEMA_VERSION
    assert body["newest_processed"].startswith("2026-05-01")
    assert body["last_emit_count"] == 3


def test_checkpoint_load_tolerates_unknown_future_keys(tmp_path):
    """Forward compat: a newer schema with extra keys should still
    load on an older install (missing keys default sensibly)."""
    checkpoint = tmp_path / "checkpoint.json"
    checkpoint.write_text(json.dumps({
        "schema_version": 99,  # future
        "last_emitted_received_at": "2026-05-01T12:00:00+00:00",
        "last_run_at": "2026-05-01T12:30:00+00:00",
        "last_emit_count": 7,
        "future_field_we_have_not_invented_yet": "xyz",
    }))
    cp = load_checkpoint(checkpoint)
    assert cp.newest_processed is not None
    assert cp.last_emit_count == 7
    # We preserve the schema_version so a re-save doesn't downgrade.
    assert cp.schema_version == 99


def test_checkpoint_load_handles_missing_file(tmp_path):
    cp = load_checkpoint(tmp_path / "does-not-exist.json")
    assert cp.newest_processed is None
    assert cp.last_emit_count == 0


def test_checkpoint_load_handles_corrupt_json_loudly(tmp_path, caplog):
    """Corrupt checkpoint -> log loudly and return zero (operator
    will see the error in the LaunchAgent log)."""
    import logging
    bad = tmp_path / "bad.json"
    bad.write_text("{ this is not valid json")
    with caplog.at_level(logging.ERROR):
        cp = load_checkpoint(bad)
    assert cp.newest_processed is None
    assert any("checkpoint" in r.message.lower() for r in caplog.records)


# ---------------------------------------------------------------------------
# Backfill window (first-run-on-fresh-install behaviour)
# ---------------------------------------------------------------------------


def test_backfill_window_clamps_first_run(tmp_path, synthetic_mail_dir):
    """When checkpoint is missing AND backfill_window_days is set, the
    very first run only emits messages within that window."""
    mbox = tmp_path / "out.mbox"
    checkpoint = tmp_path / "checkpoint.json"
    # Synthetic tree spans 2026-04-25 to 2026-04-29. With now=
    # 2026-05-01 and a 3-day window, only messages received after
    # 2026-04-28 should emit (i.e. days 28 + 29).
    count = emit_mbox(
        mbox,
        mail_dir=synthetic_mail_dir,
        checkpoint_path=checkpoint,
        backfill_window_days=3,
        now=datetime(2026, 5, 1, 0, 0, 0, tzinfo=timezone.utc),
    )
    assert count == 2

    body = mbox.read_bytes()
    assert b"Subject: Test message 3" in body
    assert b"Subject: Test message 4" in body
    assert b"Subject: Test message 0" not in body


def test_backfill_window_inactive_when_checkpoint_present(
    tmp_path, synthetic_mail_dir,
):
    """A checkpointed install MUST NOT re-clamp -- the window is a
    one-shot install-time guard, not a permanent rolling filter."""
    mbox = tmp_path / "out.mbox"
    checkpoint = tmp_path / "checkpoint.json"
    save_checkpoint(
        Checkpoint(
            newest_processed=datetime(
                2026, 4, 24, tzinfo=timezone.utc,
            ),
        ),
        checkpoint,
    )
    count = emit_mbox(
        mbox,
        mail_dir=synthetic_mail_dir,
        checkpoint_path=checkpoint,
        backfill_window_days=1,  # Would clamp to 1 day if active
        now=datetime(2026, 5, 1, 0, 0, 0, tzinfo=timezone.utc),
    )
    # All 5 should still emit because the checkpoint dominates.
    assert count == 5


# ---------------------------------------------------------------------------
# From-line escaping (mbox safety)
# ---------------------------------------------------------------------------


def test_body_lines_starting_with_from_are_escaped(tmp_path):
    """Lines beginning with ``From `` inside the body must be prefixed
    with ``>`` so the mbox reader doesn't treat them as record
    boundaries."""
    mail_dir = tmp_path / "Mail"
    _write_emlx(
        mail_dir, account="iCloud", folder="INBOX", msg_id="m1",
        sender="alice@example.test",
        to="andy@example.test",
        subject="forwarded",
        body=(
            "Beginning of body.\n"
            "From the previous email, you said...\n"
            "End.\n"
        ),
        date=datetime(2026, 4, 25, 12, 0, 0, tzinfo=timezone.utc),
    )
    mbox = tmp_path / "out.mbox"
    checkpoint = tmp_path / "checkpoint.json"
    emit_mbox(mbox, mail_dir=mail_dir, checkpoint_path=checkpoint)
    body = mbox.read_bytes()
    # The escaped body line should appear with leading ``>``.
    assert b">From the previous email" in body
    # Only one true From-line (the record opener).
    from_lines = [l for l in body.split(b"\n") if l.startswith(b"From ")]
    assert len(from_lines) == 1


# ---------------------------------------------------------------------------
# Output file management
# ---------------------------------------------------------------------------


def test_emit_to_nested_directory_creates_parents(tmp_path, synthetic_mail_dir):
    """The wrapper script writes to ``$OSTLER_DIR/imports/email/``
    which may not exist on a fresh install."""
    mbox = tmp_path / "deeply" / "nested" / "out.mbox.txt"
    checkpoint = tmp_path / "checkpoint.json"
    emit_mbox(mbox, mail_dir=synthetic_mail_dir, checkpoint_path=checkpoint)
    assert mbox.exists()


def test_empty_mail_dir_emits_zero(tmp_path):
    mail_dir = tmp_path / "EmptyMail"
    mail_dir.mkdir()
    mbox = tmp_path / "out.mbox"
    checkpoint = tmp_path / "checkpoint.json"
    count = emit_mbox(mbox, mail_dir=mail_dir, checkpoint_path=checkpoint)
    assert count == 0
    # The emitter should not have created an empty mbox file when there
    # was nothing to write -- the wrapper script uses ``-s`` to detect
    # "no work" without parsing.
    assert not mbox.exists() or mbox.stat().st_size == 0


def test_unparseable_emlx_is_skipped_not_fatal(tmp_path, synthetic_mail_dir):
    """One bad .emlx must not block the rest of the run."""
    bad = synthetic_mail_dir / "V10" / "broken.emlx"
    bad.write_bytes(b"this-has-no-length-prefix")
    mbox = tmp_path / "out.mbox"
    checkpoint = tmp_path / "checkpoint.json"
    count = emit_mbox(mbox, mail_dir=synthetic_mail_dir, checkpoint_path=checkpoint)
    assert count == 5  # The 5 well-formed messages still emit.


# ---------------------------------------------------------------------------
# Two-checkpoint progressive backfill (schema v2)
# ---------------------------------------------------------------------------


def test_first_tick_with_clamp_seeds_oldest_processed(tmp_path, synthetic_mail_dir):
    """Initial tick on a clean install with backfill_window_days clamps
    the forward window AND seeds oldest_processed at the same boundary,
    per Andy's #48 review (2026-05-01)."""
    mbox = tmp_path / "out.mbox"
    checkpoint = tmp_path / "checkpoint.json"
    count = emit_mbox(
        mbox,
        mail_dir=synthetic_mail_dir,
        checkpoint_path=checkpoint,
        backfill_window_days=3,
        now=datetime(2026, 5, 1, 0, 0, 0, tzinfo=timezone.utc),
    )
    # Forward sweep emits days 28 and 29; backward sweep is skipped on
    # the seeding tick so older days do not double-emit on tick 1.
    assert count == 2

    cp = load_checkpoint(checkpoint)
    assert cp.newest_processed is not None
    assert cp.oldest_processed is not None
    # Both edges land at the clamp boundary on tick 1.
    assert cp.oldest_processed == datetime(2026, 4, 28, tzinfo=timezone.utc)
    assert cp.backfill_complete is False


def test_second_tick_after_clamp_runs_backward_sweep(tmp_path, synthetic_mail_dir):
    """Tick 2 advances oldest_processed by chunk_days and emits any
    .emlx in the new chunk window, while forward stays put when no new
    mail arrived."""
    mbox = tmp_path / "out.mbox"
    checkpoint = tmp_path / "checkpoint.json"
    # Tick 1: clamp to 3 days from 2026-05-01.
    emit_mbox(
        mbox,
        mail_dir=synthetic_mail_dir,
        checkpoint_path=checkpoint,
        backfill_window_days=3,
        now=datetime(2026, 5, 1, 0, 0, 0, tzinfo=timezone.utc),
    )
    cp_after_tick1 = load_checkpoint(checkpoint)
    assert cp_after_tick1.oldest_processed == datetime(
        2026, 4, 28, tzinfo=timezone.utc,
    )

    # Tick 2: backward sweep with 60-day chunk picks up days 25-27
    # (which fall in [2026-02-27, 2026-04-28)).
    count = emit_mbox(
        mbox,
        mail_dir=synthetic_mail_dir,
        checkpoint_path=checkpoint,
        backfill_chunk_days=60,
        now=datetime(2026, 5, 1, 1, 0, 0, tzinfo=timezone.utc),
    )
    assert count == 3

    cp = load_checkpoint(checkpoint)
    # Oldest edge advanced 60 days back from 2026-04-28.
    assert cp.oldest_processed == datetime(2026, 2, 27, tzinfo=timezone.utc)
    # Forward edge stays at the latest message we've emitted overall
    # (day 29 from tick 1).
    assert cp.newest_processed.day == 29
    # The synthetic tree's floor is day 25 12:00; advancing to Feb 27
    # crosses that floor so backfill is now complete.
    assert cp.backfill_complete is True


def test_backfill_complete_freezes_backward_sweep(tmp_path, synthetic_mail_dir):
    """Once backfill_complete is true, subsequent ticks must NOT re-run
    the backward sweep -- we are forward-only forever."""
    mbox = tmp_path / "out.mbox"
    checkpoint = tmp_path / "checkpoint.json"
    save_checkpoint(
        Checkpoint(
            newest_processed=datetime(2026, 4, 30, tzinfo=timezone.utc),
            oldest_processed=datetime(2026, 4, 1, tzinfo=timezone.utc),
            backfill_complete=True,
        ),
        checkpoint,
    )
    count = emit_mbox(
        mbox,
        mail_dir=synthetic_mail_dir,
        checkpoint_path=checkpoint,
        now=datetime(2026, 5, 1, 12, 0, 0, tzinfo=timezone.utc),
    )
    # All synthetic messages are <= 2026-04-29; forward cutoff is
    # 2026-04-30 so nothing new. Backward is skipped because complete.
    assert count == 0
    cp = load_checkpoint(checkpoint)
    assert cp.backfill_complete is True
    # oldest_processed unchanged because backward sweep didn't run.
    assert cp.oldest_processed == datetime(2026, 4, 1, tzinfo=timezone.utc)


def test_unbounded_first_run_marks_backfill_complete(tmp_path, synthetic_mail_dir):
    """No checkpoint AND no backfill clamp emits the entire mailbox in
    one go and marks backfill_complete=True so the next tick does not
    re-emit history via a backward sweep."""
    mbox = tmp_path / "out.mbox"
    checkpoint = tmp_path / "checkpoint.json"
    count = emit_mbox(
        mbox, mail_dir=synthetic_mail_dir, checkpoint_path=checkpoint,
    )
    assert count == 5

    cp = load_checkpoint(checkpoint)
    assert cp.backfill_complete is True
    # oldest_processed pinned to the actual mailbox floor (day 25
    # 12:00 UTC).
    assert cp.oldest_processed == datetime(
        2026, 4, 25, 12, 0, 0, tzinfo=timezone.utc,
    )


def test_v1_checkpoint_upgrades_cleanly(tmp_path, synthetic_mail_dir):
    """A schema-v1 checkpoint (only last_emitted_received_at) loads as
    v2 with newest_processed populated, oldest_processed=None, and
    backfill_complete=False so the next tick can seed the backward
    sweep without losing forward history."""
    checkpoint = tmp_path / "checkpoint.json"
    checkpoint.write_text(json.dumps({
        "schema_version": 1,
        "last_emitted_received_at": "2026-04-29T12:00:00+00:00",
        "last_run_at": "2026-04-29T13:00:00+00:00",
        "last_emit_count": 5,
    }))
    cp = load_checkpoint(checkpoint)
    assert cp.newest_processed == datetime(
        2026, 4, 29, 12, 0, tzinfo=timezone.utc,
    )
    assert cp.oldest_processed is None
    assert cp.backfill_complete is False

    # Next tick after upgrade: forward edge already covers the
    # synthetic tree (latest is 2026-04-29 12:00) so no forward
    # work; the seeding-tick branch sets oldest_edge=newest but
    # skips the backward sweep so we don't re-emit. The persisted
    # oldest_processed is now seeded for tick 2 to advance.
    mbox = tmp_path / "out.mbox"
    count = emit_mbox(
        mbox,
        mail_dir=synthetic_mail_dir,
        checkpoint_path=checkpoint,
        now=datetime(2026, 5, 1, 12, 0, 0, tzinfo=timezone.utc),
    )
    assert count == 0
    cp_after = load_checkpoint(checkpoint)
    assert cp_after.oldest_processed == cp.newest_processed


# ---------------------------------------------------------------------------
# Observability posture markers
# ---------------------------------------------------------------------------


def test_success_tick_writes_observability_posture(
    tmp_path, synthetic_mail_dir, monkeypatch,
):
    """A successful tick records last_tick_status=success plus mail
    count and both edges so Doctor can render a per-service health
    tile."""
    monkeypatch.setenv("OSTLER_HOME", str(tmp_path / "ostler_home"))
    mbox = tmp_path / "out.mbox"
    checkpoint = tmp_path / "checkpoint.json"
    emit_mbox(
        mbox,
        mail_dir=synthetic_mail_dir,
        checkpoint_path=checkpoint,
        backfill_window_days=3,
        now=datetime(2026, 5, 1, 0, 0, 0, tzinfo=timezone.utc),
    )
    marker = (
        Path(tmp_path / "ostler_home")
        / "observability-posture" / "email-ingest.json"
    )
    assert marker.exists()
    payload = json.loads(marker.read_text())
    assert payload["service"] == "email-ingest"
    assert payload["last_tick_status"] == "success"
    assert payload["last_error_message"] is None
    assert payload["mail_count_processed_this_tick"] == 2
    assert payload["newest_processed"].startswith("2026-04-29")
    assert payload["oldest_processed"].startswith("2026-04-28")


def test_fda_denied_writes_failure_posture(tmp_path, monkeypatch):
    """A PermissionError walking the mail dir maps to the dedicated
    fda_denied status so Doctor can show a clearer hint than a
    generic IOError."""
    monkeypatch.setenv("OSTLER_HOME", str(tmp_path / "ostler_home"))
    mbox = tmp_path / "out.mbox"
    checkpoint = tmp_path / "checkpoint.json"

    # Make the mail dir exist but raise PermissionError on rglob.
    fake_mail = tmp_path / "Mail"
    fake_mail.mkdir()
    import ostler_fda.apple_mail_mbox as m

    def boom(*_args, **_kwargs):
        raise PermissionError("Operation not permitted")

    monkeypatch.setattr(m, "discover_emlx_files", boom)

    with pytest.raises(PermissionError):
        emit_mbox(
            mbox, mail_dir=fake_mail, checkpoint_path=checkpoint,
            backfill_window_days=365,
        )

    marker = (
        Path(tmp_path / "ostler_home")
        / "observability-posture" / "email-ingest.json"
    )
    assert marker.exists()
    payload = json.loads(marker.read_text())
    assert payload["last_tick_status"] == "fda_denied"
    assert "Operation not permitted" in payload["last_error_message"]
    assert payload["mail_count_processed_this_tick"] == 0
