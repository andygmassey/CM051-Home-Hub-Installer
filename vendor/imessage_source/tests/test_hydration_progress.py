"""Tests for the shared hydration progress signal (BUG-037 / BUG-039).

Covers:
  * the hydration_progress contract module: merge-aware per-channel
    writes, overall recomputation, derived state, atomic write;
  * the iMessage pipeline's BUG-037 light-pass: the --max-sessions cap
    bounds the synchronous drain, and per-conversation progress is
    emitted with a real (queued) denominator so the wiki settling panel
    can show a climbing bar.

No real chat.db: the reader/threader/dispatch are monkeypatched so the
loop is driven deterministically.
"""
from __future__ import annotations

import json
import sys
import types
from datetime import datetime, timezone, timedelta
from pathlib import Path

import pytest

# Make the package importable as ``imessage_source`` regardless of CWD.
_PKG_ROOT = Path(__file__).resolve().parents[2]
if str(_PKG_ROOT) not in sys.path:
    sys.path.insert(0, str(_PKG_ROOT))

from imessage_source import hydration_progress as hp  # noqa: E402
from imessage_source import pipeline as pl  # noqa: E402
from imessage_source.reader import Conversation, Message  # noqa: E402
from imessage_source.threader import Session  # noqa: E402


# ---------------------------------------------------------------------------
# hydration_progress contract module
# ---------------------------------------------------------------------------

def test_update_channel_writes_and_derives_state(tmp_path):
    f = tmp_path / "hydration_progress.json"
    doc = hp.update_channel("imessage", queued=250, done=70, target=f)
    assert doc is not None
    assert f.exists()
    ch = doc["channels"]["imessage"]
    assert ch == {"queued": 250, "done": 70, "failed": 0, "state": "working"}
    # overall sums across channels (absent ones contribute 0)
    assert doc["overall"] == {"done": 70, "total": 250, "failed": 0}
    assert doc["version"] == hp.SCHEMA_VERSION


def test_done_equal_queued_is_ready(tmp_path):
    f = tmp_path / "p.json"
    doc = hp.update_channel("email", queued=12, done=12, target=f)
    assert doc["channels"]["email"]["state"] == "ready"


def test_done_never_exceeds_queued(tmp_path):
    f = tmp_path / "p.json"
    doc = hp.update_channel("imessage", queued=5, done=99, target=f)
    # a late count revision must not push the bar over 100%
    assert doc["channels"]["imessage"]["done"] == 5
    assert doc["channels"]["imessage"]["state"] == "ready"


def test_two_feeds_do_not_clobber_each_other(tmp_path):
    f = tmp_path / "p.json"
    hp.update_channel("imessage", queued=100, done=40, target=f)
    hp.update_channel("whatsapp", queued=20, done=5, target=f)
    doc = hp.read_progress(f)
    assert doc["channels"]["imessage"] == {"queued": 100, "done": 40, "failed": 0, "state": "working"}
    assert doc["channels"]["whatsapp"] == {"queued": 20, "done": 5, "failed": 0, "state": "working"}
    assert doc["overall"] == {"done": 45, "total": 120, "failed": 0}


def test_unknown_channel_is_rejected(tmp_path):
    f = tmp_path / "p.json"
    assert hp.update_channel("not_a_channel", queued=1, done=1, target=f) is None
    assert not f.exists()


def test_read_absent_returns_none(tmp_path):
    assert hp.read_progress(tmp_path / "nope.json") is None


def test_failed_settles_the_channel_state(tmp_path):
    """S1 writer side: done + failed >= queued settles the channel to
    ready even though done < queued, and overall.failed is summed."""
    f = tmp_path / "p.json"
    # 4 done, 1 permanently failed, 5 queued -> nothing left to do.
    doc = hp.update_channel("whatsapp", queued=5, done=4, failed=1, target=f)
    ch = doc["channels"]["whatsapp"]
    assert ch == {"queued": 5, "done": 4, "failed": 1, "state": "ready"}
    assert doc["overall"] == {"done": 4, "total": 5, "failed": 1}


def test_failed_still_working_when_real_backlog_remains(tmp_path):
    """A failure must not prematurely settle a channel with live work."""
    f = tmp_path / "p.json"
    doc = hp.update_channel("email", queued=10, done=3, failed=1, target=f)
    assert doc["channels"]["email"]["state"] == "working"  # 6 still pending


def test_done_plus_failed_capped_at_queued(tmp_path):
    """done + failed can never exceed queued (the settled count caps 100%)."""
    f = tmp_path / "p.json"
    doc = hp.update_channel("email", queued=5, done=5, failed=3, target=f)
    # done already fills queued, so failed is clamped to 0.
    assert doc["channels"]["email"]["done"] == 5
    assert doc["channels"]["email"]["failed"] == 0
    assert doc["channels"]["email"]["state"] == "ready"


def test_explicit_state_override(tmp_path):
    f = tmp_path / "p.json"
    doc = hp.update_channel("notes", queued=0, done=0, state="absent", target=f)
    assert doc["channels"]["notes"]["state"] == "absent"


# ---------------------------------------------------------------------------
# iMessage pipeline light-pass (BUG-037)
# ---------------------------------------------------------------------------

def _msg(rowid: int) -> Message:
    return Message(
        rowid=rowid,
        text=f"msg {rowid}",
        sender="+15550000001",
        timestamp=datetime(2026, 6, 1, tzinfo=timezone.utc) + timedelta(minutes=rowid),
        is_from_me=False,
        chat_id="chatA",
        has_attachment=False,
        service="iMessage",
    )


def _session(conv_chat: str, rowid: int) -> Session:
    return Session(
        conversation_id=f"{conv_chat}-{rowid}",
        chat_id=conv_chat,
        messages=[_msg(rowid)],
        is_group=False,
        participant_handles=["+15550000001"],
        display_name="Sam",
    )


def _wire_loop(monkeypatch, *, n_convos: int, sessions_per: int):
    """Monkeypatch the reader/threader/dispatch so the loop runs offline.

    Each conversation yields ``sessions_per`` sessions with monotonically
    increasing rowids (so none are below the initial -1 watermark).
    """
    convos = [
        Conversation(
            chat_id=f"chat{i}",
            display_name=f"P{i}",
            participants=["+15550000001"],
            message_count=sessions_per,
            first_message=datetime(2026, 6, 1, tzinfo=timezone.utc),
            last_message=datetime(2026, 6, 2, tzinfo=timezone.utc),
            is_group=False,
        )
        for i in range(n_convos)
    ]
    monkeypatch.setattr(pl, "extract_conversations", lambda **k: convos)
    monkeypatch.setattr(pl, "extract_messages", lambda chat_id, **k: [_msg(1)])

    def _thread(chat_id, messages, **k):
        return [_session(chat_id, 100 + j) for j in range(sessions_per)]

    monkeypatch.setattr(pl, "thread_messages", _thread)
    monkeypatch.setattr(pl, "render_transcript", lambda *a, **k: "transcript")
    monkeypatch.setattr(pl, "build_metadata", lambda *a, **k: {"conversation_id": "cid"})
    dispatched = []
    monkeypatch.setattr(pl, "_dispatch_to_cm048",
                        lambda *a, **k: dispatched.append(1) or 0)
    return dispatched


def test_max_sessions_caps_the_light_pass(monkeypatch, tmp_path):
    dispatched = _wire_loop(monkeypatch, n_convos=10, sessions_per=3)  # 30 backlog
    prog = tmp_path / "hydration_progress.json"
    monkeypatch.setenv(hp.PROGRESS_PATH_ENV, str(prog))

    summary = pl.process_imessage(
        db_path=Path("/dev/null"),
        state_path=tmp_path / "state.json",
        max_sessions=8,
        pwg_convo_cmd=["true"],
    )
    # The cap bounds dispatch to 8, NOT the full 30-session backlog.
    assert summary["sessions_dispatched"] == 8
    assert len(dispatched) == 8
    # The progress signal carries the REAL backlog as the denominator so the
    # settling panel shows the true remaining work, not just what was drained.
    doc = hp.read_progress(prog)
    assert doc["channels"]["imessage"]["queued"] == 30
    assert doc["channels"]["imessage"]["done"] == 8
    assert doc["channels"]["imessage"]["state"] == "working"
    assert summary["backlog_remaining"] == 22


def test_unbounded_pass_drains_all(monkeypatch, tmp_path):
    dispatched = _wire_loop(monkeypatch, n_convos=4, sessions_per=2)  # 8 backlog
    prog = tmp_path / "hp.json"
    monkeypatch.setenv(hp.PROGRESS_PATH_ENV, str(prog))
    summary = pl.process_imessage(
        db_path=Path("/dev/null"),
        state_path=tmp_path / "s.json",
        max_sessions=0,  # unbounded (the LaunchAgent default)
        pwg_convo_cmd=["true"],
    )
    assert summary["sessions_dispatched"] == 8
    doc = hp.read_progress(prog)
    assert doc["channels"]["imessage"]["done"] == 8
    assert doc["channels"]["imessage"]["queued"] == 8
    assert doc["channels"]["imessage"]["state"] == "ready"


def test_progress_accumulates_across_ticks(monkeypatch, tmp_path):
    """A capped pass then a follow-up tick keep the bar climbing, not reset."""
    prog = tmp_path / "hp.json"
    state = tmp_path / "s.json"
    monkeypatch.setenv(hp.PROGRESS_PATH_ENV, str(prog))

    _wire_loop(monkeypatch, n_convos=5, sessions_per=2)  # 10 backlog
    pl.process_imessage(db_path=Path("/dev/null"), state_path=state,
                        max_sessions=4, pwg_convo_cmd=["true"])
    doc1 = hp.read_progress(prog)
    assert doc1["channels"]["imessage"]["done"] == 4
    assert doc1["channels"]["imessage"]["queued"] == 10

    # Second (unbounded) tick: re-thread the SAME conversations. The
    # watermark skips the already-done sessions; done climbs toward queued.
    _wire_loop(monkeypatch, n_convos=5, sessions_per=2)
    pl.process_imessage(db_path=Path("/dev/null"), state_path=state,
                        max_sessions=0, pwg_convo_cmd=["true"])
    doc2 = hp.read_progress(prog)
    # The unbounded follow-up tick drains the remaining backlog EXACTLY: the
    # full 10-session backlog is now done (none lost at the cap boundary --
    # the >= here was a weak assertion before B1; pin it to the exact total).
    assert doc2["channels"]["imessage"]["done"] == 10
    assert doc2["channels"]["imessage"]["queued"] == 10
    assert doc2["channels"]["imessage"]["state"] == "ready"


def _wire_loop_tracking(monkeypatch, *, n_convos: int, sessions_per: int):
    """Like :func:`_wire_loop` but records the UNIQUE session identity of
    every dispatch, so a test can assert each backlog session is dispatched
    exactly once across capped + drain ticks (BUG-037 / B1 regression).

    Each session carries a stable ``conversation_id`` (``chatI-rowid``) and a
    rowid that is unique per (conversation, session) AND monotonically
    increasing within a conversation, mirroring how chat.db rowids behave.
    ``build_metadata`` forwards the session's conversation_id so the dispatch
    mock can record exactly which session was sent.
    """
    convos = [
        Conversation(
            chat_id=f"chat{i}",
            display_name=f"P{i}",
            participants=["+15550000001"],
            message_count=sessions_per,
            first_message=datetime(2026, 6, 1, tzinfo=timezone.utc),
            last_message=datetime(2026, 6, 2, tzinfo=timezone.utc),
            is_group=False,
        )
        for i in range(n_convos)
    ]
    monkeypatch.setattr(pl, "extract_conversations", lambda **k: convos)
    monkeypatch.setattr(pl, "extract_messages", lambda chat_id, **k: [_msg(1)])

    def _thread(chat_id, messages, **k):
        # Unique, increasing rowids per conversation. Offsetting by the
        # conversation index keeps rowids globally distinct, which surfaces
        # any cross-thread watermark confusion.
        base = 1000 + int(chat_id.replace("chat", "")) * 100
        return [_session(chat_id, base + j) for j in range(sessions_per)]

    monkeypatch.setattr(pl, "thread_messages", _thread)
    monkeypatch.setattr(pl, "render_transcript", lambda *a, **k: "transcript")
    monkeypatch.setattr(
        pl, "build_metadata",
        lambda session, **k: {"conversation_id": session.conversation_id},
    )
    dispatched_ids: list = []

    def _dispatch(transcript, metadata, **k):
        dispatched_ids.append(metadata["conversation_id"])
        return 0

    monkeypatch.setattr(pl, "_dispatch_to_cm048", _dispatch)
    expected_ids = {
        f"chat{i}-{1000 + i * 100 + j}"
        for i in range(n_convos)
        for j in range(sessions_per)
    }
    return dispatched_ids, expected_ids


def test_no_session_lost_at_cap_boundary(monkeypatch, tmp_path):
    """B1 regression: a session that trips the --max-sessions cap must NOT
    have its rowid folded into the persisted watermark before it is
    dispatched. Otherwise the next background tick skips it forever and
    exactly one conversation is silently lost per install.

    Drive a 25-session backlog with cap=8 to completion across repeated
    ticks and assert every backlog session is dispatched EXACTLY once --
    none lost, none duplicated.
    """
    prog = tmp_path / "hp.json"
    state = tmp_path / "s.json"
    monkeypatch.setenv(hp.PROGRESS_PATH_ENV, str(prog))

    n_convos, sessions_per, cap = 5, 5, 8  # 25 backlog
    all_dispatched: list = []
    expected_ids = None

    # First a capped light pass, then bounded background ticks (same cap)
    # until the backlog is fully drained. Bound the loop so a regression
    # (a stuck watermark) fails loudly instead of spinning forever.
    for _ in range(20):
        dispatched_ids, expected_ids = _wire_loop_tracking(
            monkeypatch, n_convos=n_convos, sessions_per=sessions_per
        )
        summary = pl.process_imessage(
            db_path=Path("/dev/null"),
            state_path=state,
            max_sessions=cap,
            pwg_convo_cmd=["true"],
        )
        all_dispatched.extend(dispatched_ids)
        if summary["backlog_remaining"] <= 0:
            break

    # Every backlog session dispatched exactly once: no loss, no duplication.
    assert sorted(all_dispatched) == sorted(expected_ids)
    assert len(all_dispatched) == len(expected_ids) == n_convos * sessions_per
    assert set(all_dispatched) == expected_ids


def test_emit_progress_can_be_disabled(monkeypatch, tmp_path):
    _wire_loop(monkeypatch, n_convos=2, sessions_per=1)
    prog = tmp_path / "hp.json"
    monkeypatch.setenv(hp.PROGRESS_PATH_ENV, str(prog))
    pl.process_imessage(db_path=Path("/dev/null"), state_path=tmp_path / "s.json",
                        emit_progress=False, pwg_convo_cmd=["true"])
    assert not prog.exists()


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
