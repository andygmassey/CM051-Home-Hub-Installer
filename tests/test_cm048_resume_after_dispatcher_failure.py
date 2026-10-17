"""VENDOR COPY (CM051 graft of CM048 v1.0.107 #11), run against vendor/cm048_pipeline, the tree that ships.

A conversation the Hub dispatcher marked failed must be resumable
(v1.0.107 #11).

CM041's ical-server records a dispatch failure as ``failed_step="processor"``,
a dispatcher label rather than a pipeline step. ``retry`` / ``retry-all`` pass
that straight to ``process(resume_from_step=...)``, where ``_should_run`` did
``PIPELINE_STEP_ORDER.index("processor")`` and raised ValueError. The manual
retry therefore crashed on the very conversations it exists to recover, so the
2 failed of 129 on the walk box could not be resumed even by hand.
All data synthetic.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm048_pipeline"))

from src.processor import process
from src.schemas import PipelineState
from src.settings import Settings, ensure_directories

RAW = "Alice: synthetic line one.\nBob: synthetic line two.\n"


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    s = Settings(
        user_id="test-user",
        user_display_name="Test User",
        processing_state_dir=tmp_path / "processing",
        output_conversations_dir=tmp_path / "conversations",
        coach_db_path=tmp_path / "coach" / "observations.db",
    )
    ensure_directories(s)
    return s


def _dispatcher_failed_state(settings: Settings, cid: str, extra=None) -> Path:
    d = settings.processing_state_dir / cid
    d.mkdir(parents=True)
    data = {
        "conversation_id": cid,
        "created_at": "2026-10-08T00:00:00Z",
        "last_updated_at": "2026-10-08T00:00:00Z",
        "current_step": "00_raw",
        "completed_steps": ["00_raw"],
        "failed_step": "processor",
        "failure_reason": "synthetic tail",
        "retry_count": 1,
        "prompt_versions": {},
        "sink_idempotency_keys": {},
    }
    data.update(extra or {})
    (d / "state.json").write_text(json.dumps(data))
    return d


def test_resume_from_the_dispatchers_failed_step_does_not_raise(settings):
    cid = "2026-10-08_alice_bob_conversation"
    _dispatcher_failed_state(settings, cid)
    meta = {"conversation_id": cid, "date": "2026-10-08", "channel": "spoken",
            "participants": [{"id": "user", "display": "Alice", "role": "user"}]}
    state = process(cid, RAW, meta, settings,
                    resume_from_step="processor", dry_run=True,
                    ingest_sinks=False)
    assert state.failed_step is None
    assert "01_classify" in state.completed_steps


def test_raw_transcript_survives_the_resume(settings):
    cid = "2026-10-08_alice_bob_conversation"
    d = _dispatcher_failed_state(settings, cid)
    meta = {"conversation_id": cid, "date": "2026-10-08", "channel": "spoken",
            "participants": [{"id": "user", "display": "Alice", "role": "user"}]}
    process(cid, RAW, meta, settings, resume_from_step="processor", dry_run=True,
                    ingest_sinks=False)
    assert (d / "00_raw_transcript.md").read_text().endswith(RAW) or RAW in (
        d / "00_raw_transcript.md").read_text()


def test_state_with_an_unknown_key_still_loads():
    s = PipelineState.from_dict({
        "conversation_id": "c", "created_at": "t", "last_updated_at": "t",
        "current_step": "00_raw", "completed_steps": ["00_raw"],
        "some_future_field": {"a": 1},
    })
    assert s.conversation_id == "c"


def test_a_real_step_is_still_honoured(settings):
    cid = "2026-10-08_alice_bob_conversation"
    _dispatcher_failed_state(settings, cid, {
        "failed_step": "02_enrich", "completed_steps": ["00_raw", "01_classify"]})
    meta = {"conversation_id": cid, "date": "2026-10-08", "channel": "spoken",
            "participants": [{"id": "user", "display": "Alice", "role": "user"}]}
    state = process(cid, RAW, meta, settings,
                    resume_from_step="02_enrich", dry_run=True,
                    ingest_sinks=False)
    assert state.failed_step is None
