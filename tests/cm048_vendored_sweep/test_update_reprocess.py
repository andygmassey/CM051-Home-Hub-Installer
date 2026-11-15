"""An updated re-POST of the same conversation_id re-runs the pipeline.

THE DEFECT (CM048 origin/main 14d75c1)
--------------------------------------
A connector re-POSTs the SAME conversation_id when a thread grows: a new
Slack reply, Jira comment, email reply, or chat message. ``_write_raw``
wrote the transcript only when absent and ``_should_run`` skipped every
completed step, so the update was answered "complete" while summary.md,
transcript.md, todos.md and the facts stayed at the first version.

WHAT THIS FILE PINS, END TO END THROUGH ``process()``
------------------------------------------------------
Every HTTP call the pipeline makes (Ollama, Qdrant, Oxigraph) goes to an
in-process fake: the LLM answers from the transcript in the prompt and
counts its calls; Qdrant is a dict of points; Oxigraph is a REAL
pyoxigraph store, so the retraction is real SPARQL against real data.

1. A changed re-POST rewrites the raw files and all four artefacts.
2. A byte-identical re-POST makes 0 LLM calls and 0 store writes.
3. After an update that rewords a fact, the earlier fact is gone from
   Qdrant and Oxigraph: replaced, not duplicated.
4. A todo already pushed to Reminders keeps its one row; a re-extraction
   that only changes its case/punctuation maps to the same row; a pending
   todo the update dropped is superseded, so it is never pushed.
5. An update that turns the conversation L3 retracts the earlier facts
   and writes no new gist.
"""
from __future__ import annotations

import json
import re
import sqlite3
from pathlib import Path

import httpx
import pyoxigraph
import pytest

from _update_fakes import Fakes
from src import processor
from src.processor import process
from src.settings import Settings, ensure_directories

CONV_ID = "2026-10-19_im_sample_sync"

V1 = (
    "[10:00] Riley: Can you send the draft agenda?\n"
    "[10:01] Me: Yes, I will send the agenda tonight.\n"
)
# The update edits a message (the fact's wording changes) AND adds one.
V2 = (
    "[10:00] Riley: Can you send the draft agenda?\n"
    "[10:01] Me: Yes, I will send the agenda tomorrow morning.\n"
    "[10:05] Riley: Also the venue moved to Room 4B.\n"
)


def _metadata(**overrides) -> dict:
    md = {
        "conversation_id": CONV_ID,
        "date": "2026-10-19",
        "started_at": "2026-10-19T10:00:00Z",
        "channel": "im",
        "source": "imessage",
        "privacy_level": "L1",
        "participants": [
            {"id": "user", "display": "Me", "role": "user"},
            {"id": "other:riley", "display": "Riley", "role": "other"},
        ],
    }
    md.update(overrides)
    return md


@pytest.fixture
def fakes(monkeypatch, tmp_path):
    f = Fakes()
    real_client = httpx.Client

    def client(*args, **kwargs):
        kwargs["transport"] = httpx.MockTransport(f.handle)
        return real_client(*args, **kwargs)

    monkeypatch.setattr(httpx, "Client", client)
    # reminders_map.db and every other ~/.ostler path stay in tmp.
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    # A failing step must fail fast, not back off for 30s per retry.
    monkeypatch.setattr(processor, "BASE_DELAY_SECONDS", 0)
    return f


@pytest.fixture
def settings(tmp_path) -> Settings:
    s = Settings(
        user_id="test-user",
        user_display_name="Test User",
        processing_state_dir=tmp_path / "processing",
        output_conversations_dir=tmp_path / "Conversations",
        coach_db_path=tmp_path / "coach" / "observations.db",
        ollama_url="http://fake-ollama",
        qdrant_url="http://fake-qdrant",
        oxigraph_url="http://fake-oxigraph",
        # The cost guard has its own tests below; these exercise the update
        # path itself, so successive versions must not be deferred.
        reprocess_cooldown_seconds=0,
    )
    ensure_directories(s)
    return s


def run(settings, transcript, **md):
    state = process(CONV_ID, transcript, _metadata(**md), settings)
    assert state.failed_step is None, state.failure_reason
    return state


def bundle_files(settings) -> dict[str, str]:
    out = {}
    for f in sorted(settings.output_conversations_dir.rglob("*/*/*.md")):
        out[f"{f.parent.name}/{f.name}"] = f.read_text()
    return out


def reminders_rows(tmp_path) -> list[tuple]:
    db = tmp_path / "home" / ".ostler" / "reminders_map.db"
    con = sqlite3.connect(str(db))
    try:
        return con.execute(
            "SELECT todo_id, status, skip_reason FROM reminders_map ORDER BY todo_id"
        ).fetchall()
    finally:
        con.close()


def mark_all_pushed(tmp_path) -> None:
    db = tmp_path / "home" / ".ostler" / "reminders_map.db"
    con = sqlite3.connect(str(db))
    con.execute("UPDATE reminders_map SET status='pushed', calendar_item_identifier='EK-1'")
    con.commit()
    con.close()


# ── 1. a changed re-POST updates every artefact ─────────────────────


def test_changed_repost_rewrites_raw_files_and_all_four_artefacts(fakes, settings):
    run(settings, V1)
    first = bundle_files(settings)
    calls_after_v1 = fakes.llm_calls
    assert calls_after_v1 > 0

    run(settings, V2)
    second = bundle_files(settings)

    state_dir = settings.processing_state_dir / CONV_ID
    assert (state_dir / "00_raw_transcript.md").read_text() == V2
    assert fakes.llm_calls > calls_after_v1, "the update made no LLM call"
    assert set(second) == set(first)  # same folder, same three files
    summary = next(v for k, v in second.items() if k.endswith("summary.md"))
    transcript = next(v for k, v in second.items() if k.endswith("transcript.md"))
    todos = next(v for k, v in second.items() if k.endswith("todos.md"))
    assert "3 messages; last: Also the venue moved to Room 4B." in summary
    assert "Room 4B" in transcript and "tomorrow morning" in transcript
    assert "send the agenda tomorrow morning" in todos
    assert "tonight" not in todos
    # The fourth artefact is the shared frontmatter: still this conversation.
    assert f'conversation_id: "{CONV_ID}"' in summary
    # The update marker is gone once the re-run completed.
    assert not (state_dir / processor.UPDATE_MARKER_FILE).exists()


def test_metadata_only_change_reprocesses(fakes, settings):
    run(settings, V1)
    before = fakes.llm_calls
    run(settings, V1, privacy_level="L2")
    assert fakes.llm_calls > before
    meta = json.loads(
        (settings.processing_state_dir / CONV_ID / "00_metadata.json").read_text()
    )
    assert meta["privacy_level"] == "L2"


# ── 2. an identical re-POST is a no-op ──────────────────────────────


def test_identical_repost_makes_zero_llm_calls_and_zero_store_writes(fakes, settings):
    run(settings, V1)
    llm, writes = fakes.llm_calls, fakes.store_writes
    before = bundle_files(settings)

    run(settings, V1)

    assert fakes.llm_calls - llm == 0
    assert fakes.store_writes - writes == 0
    assert bundle_files(settings) == before


def test_identical_repost_of_a_legacy_state_dir_is_a_noop(fakes, settings):
    """A state dir written before content_hash.json existed compares by
    hashing its stored raw files, so it is not re-run on upgrade."""
    run(settings, V1)
    (settings.processing_state_dir / CONV_ID / processor.CONTENT_HASH_FILE).unlink()
    llm = fakes.llm_calls
    run(settings, V1)
    assert fakes.llm_calls == llm


# ── 3. facts are replaced, not duplicated ───────────────────────────


def test_update_replaces_earlier_facts_in_qdrant_and_oxigraph(fakes, settings):
    run(settings, V1)
    assert fakes.qdrant_fact_texts() == [
        "Me said: Yes, I will send the agenda tonight.",
        "Riley said: Can you send the draft agenda?",
    ]

    run(settings, V2)

    expected = [
        "Me said: Yes, I will send the agenda tomorrow morning.",
        "Riley said: Also the venue moved to Room 4B.",
        "Riley said: Can you send the draft agenda?",
    ]
    assert fakes.qdrant_fact_texts() == expected
    assert fakes.oxigraph_fact_texts() == expected
    # One summary point, not two.
    summaries = [p for p in fakes.points.values()
                 if p["payload"].get("point_type") == "conversation_summary"]
    assert len(summaries) == 1


def test_update_does_not_touch_another_conversations_facts(fakes, settings):
    other = "2026-10-18_im_other_thread"
    process(other, V1, _metadata(conversation_id=other), settings)
    run(settings, V1)
    run(settings, V2)
    q = ("SELECT ?t WHERE { ?f <urn:ostler:fromConversation> "
         f"<urn:ostler:conversation/{other}> ; <urn:ostler:text> ?t }}")
    assert len(list(fakes.store.query(q, use_default_graph_as_union=True))) == 2
    assert sum(1 for p in fakes.points.values()
               if p["payload"].get("conversation_id") == other) == 3


# ── 4. no duplicate Reminders pushes ────────────────────────────────


def test_pushed_todo_keeps_one_row_when_reextracted_with_new_case(fakes, settings, tmp_path):
    fakes.todo_texts = ["Send the agenda to Riley."]
    run(settings, V1)
    mark_all_pushed(tmp_path)
    first = reminders_rows(tmp_path)
    assert [r[1] for r in first] == ["pushed"]

    # The update's re-extraction words the same todo slightly differently.
    fakes.todo_texts = ["send the agenda to riley"]
    run(settings, V2)

    rows = reminders_rows(tmp_path)
    assert rows == first, rows  # same row, still pushed, no new pending row
    todos = next(v for k, v in bundle_files(settings).items() if k.endswith("todos.md"))
    assert first[0][0] in todos and "pushed-to-reminders" in todos


def test_pending_todo_dropped_by_the_update_is_superseded(fakes, settings, tmp_path):
    fakes.todo_texts = ["Book the room"]
    run(settings, V1)
    fakes.todo_texts = ["Send the agenda"]
    run(settings, V2)
    statuses = {r[1]: r[2] for r in reminders_rows(tmp_path)}
    assert statuses == {"skipped": "superseded_by_update", "pending": None}


def test_pushed_todo_dropped_by_the_update_is_left_alone(fakes, settings, tmp_path):
    fakes.todo_texts = ["Book the room"]
    run(settings, V1)
    mark_all_pushed(tmp_path)
    fakes.todo_texts = []
    run(settings, V2)
    assert [r[1] for r in reminders_rows(tmp_path)] == ["pushed"]


# ── 5. L3 stays files only ──────────────────────────────────────────


def test_update_to_l3_retracts_earlier_facts_and_writes_no_gist(fakes, settings):
    run(settings, V1)
    assert fakes.qdrant_fact_texts() and fakes.topic_mentions() == 1

    run(settings, V2, privacy_level="L3")

    assert fakes.qdrant_fact_texts() == []
    assert fakes.oxigraph_fact_texts() == []
    assert fakes.topic_mentions() == 0
    files = bundle_files(settings)
    assert any("Room 4B" in v for k, v in files.items() if k.endswith("transcript.md"))


def test_first_l3_post_makes_no_store_request(fakes, settings):
    run(settings, V1, privacy_level="L3")
    assert fakes.store_writes == 0
    assert fakes.points == {}


# ── bundle folder moves with a new participant ──────────────────────


def test_update_that_moves_the_folder_removes_the_stale_copy(fakes, settings):
    run(settings, V1)
    old = {k.split("/")[0] for k in bundle_files(settings)}
    md = _metadata()
    md["participants"].append({"id": "other:sam", "display": "Sam", "role": "other"})
    process(CONV_ID, V2, md, settings)
    new = {k.split("/")[0] for k in bundle_files(settings)}
    assert len(new) == 1 and new != old, (old, new)


@pytest.mark.xfail(strict=True, reason=(
    "CM051 VENDORED DIVERGENCE, confirmed by Archie 2026-10-20: the thread_key "
    "duplicate_thread gate in vendor/cm048_pipeline/src/reminders_push.py "
    "(recorded in vendor/divergences/cm048_pipeline.patch) marks the other "
    "conversation's todos skipped/duplicate_thread where upstream, which has no "
    "thread gate, leaves them pending. Pre-existing: fails identically on the "
    "v1.0.111 vendored tree (pin 5b5ea44c). Strict, so any change in that "
    "behaviour reds this file. The ordering guarantee itself is a hard pass in "
    "tests/test_cm048_reminder_supersede_before_duplicate_thread.py."))
def test_update_never_supersedes_another_conversations_pending_todo(fakes, settings, tmp_path):
    """A chat's session id spans many conversations (one per day window,
    say). Updating one of them must not cancel the other's pending todo."""
    other = "2026-10-18_im_same_chat"
    fakes.todo_texts = ["Order the cake"]
    process(other, V1, _metadata(conversation_id=other, source_session_id="chat-shared"), settings)
    fakes.todo_texts = ["Book the room"]
    run(settings, V1, source_session_id="chat-shared")
    fakes.todo_texts = ["Send the agenda"]
    run(settings, V2, source_session_id="chat-shared")
    statuses = sorted((r[1], r[2]) for r in reminders_rows(tmp_path))
    # this conversation: one superseded, one pending; the other: still pending
    assert statuses == [("pending", None), ("pending", None),
                        ("skipped", "superseded_by_update")], statuses


# ── cost guard: a burst of updates is deferred, never dropped ───────


def test_update_inside_the_cooldown_is_deferred_and_changes_nothing(fakes, settings):
    settings.reprocess_cooldown_seconds = 900
    run(settings, V1)
    llm, writes = fakes.llm_calls, fakes.store_writes
    before = bundle_files(settings)
    raw = settings.processing_state_dir / CONV_ID / "00_raw_transcript.md"

    with pytest.raises(processor.UpdateDeferred) as exc:
        process(CONV_ID, V2, _metadata(), settings)

    assert 0 < exc.value.retry_after_seconds <= 900
    assert fakes.llm_calls == llm and fakes.store_writes == writes
    assert bundle_files(settings) == before
    assert raw.read_text() == V1  # nothing written: the re-send carries it


def test_update_after_the_cooldown_runs(fakes, settings):
    settings.reprocess_cooldown_seconds = 900
    run(settings, V1)
    hash_path = settings.processing_state_dir / CONV_ID / processor.CONTENT_HASH_FILE
    data = json.loads(hash_path.read_text())
    data["accepted_at"] = "2026-10-19T00:00:00+00:00"  # long ago
    hash_path.write_text(json.dumps(data))
    llm = fakes.llm_calls
    run(settings, V2)
    assert fakes.llm_calls > llm


def test_identical_repost_never_restarts_the_cooldown(fakes, settings):
    settings.reprocess_cooldown_seconds = 900
    run(settings, V1)
    hash_path = settings.processing_state_dir / CONV_ID / processor.CONTENT_HASH_FILE
    stamp = json.loads(hash_path.read_text())["accepted_at"]
    run(settings, V1)
    assert json.loads(hash_path.read_text())["accepted_at"] == stamp


# ── the change hash covers a declared stable metadata subset ────────


def test_volatile_metadata_fields_do_not_trigger_reprocessing(fakes, settings):
    """A post timestamp, a run id and a counter move on every send. They
    must not turn an unchanged re-POST into a full re-run."""
    run(settings, V1, posted_at="2026-10-19T10:00:00Z", run_id="run-1", attempt=1)
    llm, writes = fakes.llm_calls, fakes.store_writes
    before = bundle_files(settings)

    run(settings, V1, posted_at="2026-10-19T10:05:00Z", run_id="run-2", attempt=2)

    assert fakes.llm_calls == llm and fakes.store_writes == writes
    assert bundle_files(settings) == before


def test_a_hashed_metadata_field_still_triggers_reprocessing(fakes, settings):
    """Control for the test above: the subset is not empty, a content key
    (an operator relabelling the chat) still re-runs."""
    run(settings, V1)
    llm = fakes.llm_calls
    run(settings, V1, contact_label="Work")
    assert fakes.llm_calls > llm


# Every key the shipped producers send (CM051 origin/main, 2026-10-19;
# file:line in processor.METADATA_HASH_KEYS). A key in neither set fails,
# so adding a producer key forces a hash-or-ignore decision here.
PRODUCER_KEYS = {
    "imessage threader.py:185-200": [
        "conversation_id", "date", "source", "channel", "started_at",
        "ended_at", "source_session_id", "capture_source", "participants",
        "chat_identifier", "service", "is_group_chat", "privacy_level"],
    "whatsapp renderer.py:215-245": [
        "conversation_id", "date", "source", "channel", "source_app",
        "source_session_id", "capture_source", "chat_jid", "chat_type",
        "is_group_chat", "contact_source_tier", "participants",
        "group_subject", "started_at", "ended_at", "contact_label",
        "group_label", "privacy_level"],
    "mail threader.py:298-320": [
        "conversation_id", "date", "source", "channel", "shape",
        "started_at", "ended_at", "source_session_id", "source_app",
        "capture_source", "participants", "email_thread", "privacy_level"],
    "mbox universal_import.py:1509-1521": [
        "conversation_id", "date", "source", "channel", "participants",
        "started_at", "ended_at", "privacy_level", "subject",
        "is_group_chat", "message_count"],
    "spoken renderer.py:215-243": [
        "conversation_id", "date", "source", "channel", "context",
        "source_app", "source_session_id", "capture_source",
        "diarization_method", "duration_seconds", "is_voice_note",
        "participants", "started_at", "ended_at", "language", "tags",
        "privacy_level"],
    "cm052 wire.py:444-457": [
        "conversation_id", "date", "source", "channel", "participant_kind",
        "privacy_level", "participants", "provenance", "extra"],
}


@pytest.mark.parametrize("producer", sorted(PRODUCER_KEYS))
def test_every_producer_key_is_classified(producer):
    unclassified = [
        k for k in PRODUCER_KEYS[producer]
        if k not in processor.METADATA_HASH_KEYS
        and k not in processor.METADATA_IGNORED_KEYS
    ]
    assert unclassified == [], (producer, unclassified)


def test_no_key_is_both_hashed_and_ignored():
    assert processor.METADATA_HASH_KEYS & processor.METADATA_IGNORED_KEYS == set()


# ── the Hub API path: ical-server writes the state dir FIRST ────────
#
# CM041 ical-server (_conversation_process_background, the path iOS capture
# and every CM052 connector take) writes 00_raw_transcript.md,
# 00_metadata.json and a FRESH state.json (completed_steps=["00_raw"])
# into this conversation's state dir, then runs `pwg-convo process` on
# those files. So by the time process() looks, state.json no longer says
# step 07 ran, and the raw file already holds the new text.


def hub_writes(settings, transcript, md):
    state_dir = settings.processing_state_dir / CONV_ID
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "00_raw_transcript.md").write_text(transcript)
    (state_dir / "00_metadata.json").write_text(json.dumps(md, indent=2))
    (state_dir / "state.json").write_text(json.dumps({
        "conversation_id": CONV_ID,
        "created_at": "2026-10-19T10:00:00Z",
        "last_updated_at": "2026-10-19T10:00:00Z",
        "current_step": "00_raw",
        "completed_steps": ["00_raw"],
        "failed_step": None, "failure_reason": None, "retry_count": 0,
        "prompt_versions": {}, "sink_idempotency_keys": {},
    }))


EXPECTED_V2_FACTS = [
    "Me said: Yes, I will send the agenda tomorrow morning.",
    "Riley said: Also the venue moved to Room 4B.",
    "Riley said: Can you send the draft agenda?",
]


def test_hub_writer_update_still_replaces_earlier_facts(fakes, settings):
    hub_writes(settings, V1, _metadata())
    run(settings, V1)
    hub_writes(settings, V2, _metadata())
    run(settings, V2)
    assert fakes.qdrant_fact_texts() == EXPECTED_V2_FACTS
    assert fakes.oxigraph_fact_texts() == EXPECTED_V2_FACTS


def test_hub_writer_update_of_a_legacy_state_dir_is_detected(fakes, settings):
    """A state dir from before content_hash.json existed: the Hub has
    already overwritten the raw file, so hashing it would say "unchanged".
    A raw file newer than the cached step outputs means it was rewritten
    after they were made."""
    import os
    hub_writes(settings, V1, _metadata())
    run(settings, V1)
    state_dir = settings.processing_state_dir / CONV_ID
    (state_dir / processor.CONTENT_HASH_FILE).unlink()
    for f in state_dir.iterdir():
        if f.is_file():
            os.utime(f, (1_700_000_000, 1_700_000_000))
    llm = fakes.llm_calls
    hub_writes(settings, V2, _metadata())
    run(settings, V2)
    assert fakes.llm_calls > llm
    assert fakes.qdrant_fact_texts() == EXPECTED_V2_FACTS
    assert "Room 4B" in next(
        v for k, v in bundle_files(settings).items() if k.endswith("summary.md"))


def test_hub_writer_identical_repost_is_still_a_noop(fakes, settings):
    hub_writes(settings, V1, _metadata())
    run(settings, V1)
    llm, writes = fakes.llm_calls, fakes.store_writes
    hub_writes(settings, V1, _metadata())
    run(settings, V1)
    assert fakes.store_writes == writes
    # The Hub reset state.json, so steps "re-run" but every one is served
    # from its cached output: no model call.
    assert fakes.llm_calls == llm


def test_hub_writer_update_of_an_l3_conversation_makes_no_store_request(fakes, settings):
    hub_writes(settings, V1, _metadata(privacy_level="L3"))
    run(settings, V1, privacy_level="L3")
    (settings.processing_state_dir / CONV_ID / processor.CONTENT_HASH_FILE).unlink()
    hub_writes(settings, V2, _metadata(privacy_level="L3"))
    run(settings, V2, privacy_level="L3")
    assert fakes.store_writes == 0 and fakes.points == {}
    assert any("Room 4B" in v for k, v in bundle_files(settings).items()
               if k.endswith("transcript.md"))
