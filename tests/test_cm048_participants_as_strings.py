"""VENDOR COPY (CM051 graft of CM048 #83, v1.0.107 #12), run against vendor/cm048_pipeline, the tree that ships.

The iPhone / Watch envelope sends participants as STRINGS (v1.0.107 #12).

CM031's ``APIClient.processEnvelope`` builds
``metadata.participants`` as ``[String]``: the sorted, de-duplicated
speaker labels of the utterances (``"Speaker 1"``, ``"Speaker 2"``).
ical-server passes the metadata straight through, and every reader in
this pipeline assumed a list of dicts, so ``_build_classifier_input``
raised ``AttributeError: 'str' object has no attribute 'get'`` at
01_classify and every iPhone / Watch conversation failed.

The envelope below is copied field-for-field from
``ConversationMetadata`` in CM031 ``Sources/Services/APIClient.swift``
(CodingKeys: meeting_id, date, start_time, end_time, participants, type,
device_id, compartment_level), plus the ``conversation_id`` the hub adds.
All data synthetic.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm048_pipeline"))

from src import ingest, outstanding_todos, processor, seed
from src.bulk_classifier import classify
from src.processor import process
from src.settings import Settings, ensure_directories

CID = "2026-10-08_ios_spoken_synthetic"

# Exactly what CM031 encodes: transcript is "<speakerLabel>: <text>" per
# utterance, participants is Set(speakerLabel).sorted() as [String].
TRANSCRIPT = (
    "Speaker 1: Synthetic opening line about the garden shed.\n"
    "Speaker 2: Synthetic reply, I can paint it on Saturday.\n"
    "Speaker 1: Synthetic thanks, I will buy the paint.\n"
)


def _cm031_metadata() -> dict:
    return {
        "conversation_id": CID,
        "meeting_id": "00000000-0000-4000-8000-000000000001",
        "date": "2026-10-08",
        "start_time": "2026-10-08T09:00:00Z",
        "end_time": "2026-10-08T09:05:00Z",
        "participants": ["Speaker 1", "Speaker 2"],
        "type": "in_person",
        "device_id": "synthetic-device",
        "compartment_level": 1,
    }


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


def test_cm031_envelope_runs_the_whole_pipeline(settings):
    """The live-box crash: 01_classify must not fail on string participants."""
    state = process(CID, TRANSCRIPT, _cm031_metadata(), settings,
                    dry_run=True, ingest_sinks=False)
    assert state.failed_step is None, state.failure_reason
    assert "01_classify" in state.completed_steps
    assert "02_enrich" in state.completed_steps


def test_classifier_input_names_the_speakers(settings):
    body = processor._build_classifier_input(
        TRANSCRIPT, _cm031_metadata(), "", settings)
    assert "Participants: Speaker 1, Speaker 2" in body


def test_every_metadata_reader_accepts_string_participants(settings):
    meta = _cm031_metadata()
    c = processor.Classification.from_dict({
        "setting": "work", "shape": "one-on-one", "stakes": "medium",
        "confidence": 0.9, "reasoning": "synthetic",
        "sensitivity": {"level": "normal", "categories": [], "reasoning": ""},
        "review_before_ingest": False, "processing_depth": "full",
        "hints_used": "none", "suggested_type_slug": "work_one-on-one_medium",
    })
    assert "Speaker 1 = Speaker 1" in processor._build_speaker_mapping(meta)
    processor._fix_speaker_subjects([{"subject": "other:speaker_1"}], meta)
    processor._build_enrichment_input(TRANSCRIPT, meta, c, "", settings)
    processor._build_merge_prompt_for_retry(["a", "b"], meta, c, "", settings)
    processor._speaker_fingerprint_refs(meta)
    assert seed._participant_names(meta) == ["Speaker 1", "Speaker 2"]
    outstanding_todos.extract_outstanding_todos(
        "## Action items\n\n| Owner | Action |\n|---|---|\n"
        "| Speaker 1 | Buy paint |\n", meta)
    ingest._participant_identity_triples(CID, meta, settings)
    classify(meta)


def test_normalise_participants_shapes():
    from src.participants import normalise_participants

    assert normalise_participants(["Speaker 1", "  ", {"id": "x"}, 7, None]) == [
        {"display": "Speaker 1"}, {"id": "x"}]
    assert normalise_participants(None) == []
    assert normalise_participants("Speaker 1") == []
    dicts = [{"id": "user", "display": "Test User", "role": "user"}]
    assert normalise_participants(dicts) == dicts
