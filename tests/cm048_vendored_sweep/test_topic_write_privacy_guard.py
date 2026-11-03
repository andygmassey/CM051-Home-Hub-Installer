"""CM051 port of CM048 tests/test_topic_write_privacy_guard.py (CM048 #109), run
against the VENDORED tree vendor/cm048_pipeline.

Step 09's topic bridge writes ONLY for a known non-L3 privacy level.

Two layers carry the rule, each on its own, so removing either one still
keeps L3 and level-less conversations out of the graph:

* call site: ``processor._step_bundle`` sub-step A2 (``is_writable_privacy_level``)
* writer:    ``topic_writer.write_topics`` (same predicate)

End-to-end tests drive the REAL ``_step_bundle`` and count the POSTs the
REAL writer sends. Layer tests pin each gate alone. Synthetic data only.
"""
from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import patch

import pytest

from src import processor, topic_writer
from src.schemas import Classification
from src.settings import Settings

NO_LEVEL = [None, "", "garbage", "l1", 3, ["L1"]]


class _Counter:
    """Stand-in for httpx.Client that counts the writer's POSTs."""

    posts: list = []

    def __init__(self, *_a, **_k): ...
    def __enter__(self): return self
    def __exit__(self, *_a): return None

    def post(self, url, content=None, headers=None, params=None):
        type(self).posts.append(url)

        class _Resp:
            status_code = 200
            def raise_for_status(self): return None

        return _Resp()


def _settings(tmp_path: Path) -> Settings:
    return Settings(
        user_id="synth-user",
        oxigraph_url="http://localhost:7878",
        processing_state_dir=tmp_path / "ps",
        output_conversations_dir=tmp_path / "convos",
        coach_db_path=tmp_path / "coach.db",
    )


def _run_step09(tmp_path: Path, level) -> int:
    """Run step 09 once; return the number of topic-write POSTs."""
    state = tmp_path / "state"
    state.mkdir(parents=True)
    (state / "00_raw_transcript.md").write_text("Alice: hello\nBob: hi\n")
    (state / "09_bundle.json").write_text(json.dumps({
        "overall_summary": "Synthetic.",
        "topics": [{"name": "Garden Design", "points": ["roses"]}],
        "todos": [],
    }))
    classification = Classification.from_dict({
        "setting": "correspondence", "shape": "one-on-one",
        "stakes": "medium", "confidence": 0.9, "reasoning": "synthetic",
        "sensitivity": {"level": "normal"},
    })
    metadata = {"conversation_id": "conv-synth-1", "channel": "spoken"}
    if level is not None:
        metadata["privacy_level"] = level
    _Counter.posts = []
    with patch("src.topic_writer.httpx.Client", _Counter):
        processor._step_bundle(
            None, state, metadata, classification, _settings(tmp_path), level,
            ingest_sinks=True, dry_run=False,
        )
    return len(_Counter.posts)


def _write_direct(tmp_path: Path, level) -> int:
    _Counter.posts = []
    with patch("src.topic_writer.httpx.Client", _Counter):
        topic_writer.write_topics(
            conversation_id="conv-synth-1",
            topics=[{"name": "Garden Design", "points": ["roses"]}],
            settings=_settings(tmp_path),
            privacy_level=level,
        )
    return len(_Counter.posts)


# ---- end to end: neither layer may be what makes these pass alone --------

@pytest.mark.parametrize("level", ["L0", "L1", "L2"])
def test_known_non_l3_control_writes_topics(tmp_path, level):
    assert _run_step09(tmp_path, level) > 0


def test_l3_writes_no_topics(tmp_path):
    assert _run_step09(tmp_path, "L3") == 0


@pytest.mark.parametrize("level", NO_LEVEL)
def test_no_or_unparseable_level_writes_no_topics(tmp_path, level):
    assert _run_step09(tmp_path, level) == 0


# ---- each layer alone -----------------------------------------------------

@pytest.mark.parametrize("level", ["L3", *NO_LEVEL])
def test_writer_alone_refuses(tmp_path, level):
    assert _write_direct(tmp_path, level) == 0


def test_writer_alone_control_writes(tmp_path):
    assert _write_direct(tmp_path, "L1") > 0


@pytest.mark.parametrize("level", ["L3", *NO_LEVEL])
def test_call_site_alone_does_not_call_writer(tmp_path, level):
    with patch("src.topic_writer.write_topics") as spy:
        _run_step09(tmp_path, level)
    assert spy.call_count == 0


def test_call_site_control_calls_writer(tmp_path):
    with patch("src.topic_writer.write_topics") as spy:
        _run_step09(tmp_path, "L1")
    assert spy.call_count == 1
