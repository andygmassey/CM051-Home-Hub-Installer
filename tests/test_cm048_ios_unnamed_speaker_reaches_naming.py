"""An iPhone / Watch capture with no diarised speaker reaches the Hub's speaker naming.

Run against vendor/cm048_pipeline, the tree that ships.

CM031 sends one line per utterance, ``"<speakerLabel>: <text>"``
(APIClient.processEnvelope), with ``metadata.participants`` the sorted
labels. A line no diariser named used to go out as ``"S1"``; CM031 #303 made
it ``"Speaker 1"`` (``CapturedUtterance.unnamedSpeaker``), because the Hub only
names a speaker whose label is exactly ``Speaker N``
(``processor._unresolved_speaker_labels``).

This pins that contract from the consumer side. The transcript goes through
the real ``_write_raw`` and the real ``_step_speaker_feedback`` with dry_run
off. Only the LLM is stubbed: it names whatever label it is asked about, so
whether a label is named depends only on whether the pipeline asks.

"S1" is the control: it must NOT reach naming. Captures already stored on a
Hub as "S1" are not migrated; this test says why they stay unnamed.
All data synthetic.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm048_pipeline"))

from src import processor
from src.settings import Settings, ensure_directories

CID = "2026-10-18_ios_spoken_synthetic"


class NamingLLM:
    """Stands in for the Hub model: names every label it is asked about."""

    def __init__(self) -> None:
        self.asked: list[str] = []

    def generate_json(self, model, prompt, **kwargs):
        block = prompt.split("--- SPEAKER LABELS TO RESOLVE ---")[1].split("--- CANDIDATE")[0]
        labels = json.loads(block)
        self.asked += [label["raw_label"] for label in labels]

        class Result:
            parsed_json = {"labels": [{
                "raw_label": label["raw_label"], "inferred_person_id": "sam_smith",
                "inferred_display_name": "Sam Smith", "confidence": 0.95,
                "evidence": "synthetic"} for label in labels]}

        return Result()


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    s = Settings(
        user_id="test-user",
        user_display_name="Test User",
        processing_state_dir=tmp_path / "processing",
        output_conversations_dir=tmp_path / "conversations",
        coach_db_path=tmp_path / "coach" / "observations.db",
        # Discard port: the people-graph lookup fails fast and degrades to [].
        oxigraph_url="http://127.0.0.1:9",
    )
    ensure_directories(s)
    return s


def _classification():
    return processor.Classification.from_dict({
        "setting": "work", "shape": "one-on-one", "stakes": "low",
        "confidence": 0.9, "reasoning": "synthetic",
        "sensitivity": {"level": "normal", "categories": [], "reasoning": ""},
        "review_before_ingest": False, "processing_depth": "full",
        "hints_used": "none", "suggested_type_slug": "work_one-on-one_low",
    })


def _name(label: str, settings: Settings) -> tuple[list[str], dict]:
    """One capture through the real raw-write and speaker-naming steps."""
    transcript = (f"{label}: Right, quick update before you head off.\n"
                  f"{label}: Chase the paperwork before Friday, thanks.")
    meta = {"conversation_id": CID, "date": "2026-10-18", "participants": [label],
            "type": "in_person", "device_id": "synthetic-device",
            "compartment_level": 1, "capture_source": "cm031_iphone"}
    state = settings.processing_state_dir / CID
    state.mkdir(parents=True, exist_ok=True)
    processor._write_raw(state, CID, transcript, meta)
    llm = NamingLLM()
    processor._step_speaker_feedback(llm, state, CID, meta, _classification(), settings, dry_run=False)
    return llm.asked, json.loads((state / "06_speaker_feedback.json").read_text())


def test_speaker_1_reaches_naming_and_is_named(settings):
    asked, feedback = _name("Speaker 1", settings)
    assert asked == ["Speaker 1"]
    assert [(l["raw_label"], l["inferred_display_name"], l["apply_mode"]) for l in feedback["labels"]] == [
        ("Speaker 1", "Sam Smith", "auto")]
    assert feedback["unresolved_labels"] == []


def test_s1_never_reaches_naming(settings):
    """The control: the old CM031 fallback label is invisible to naming."""
    asked, feedback = _name("S1", settings)
    assert asked == []
    assert feedback["labels"] == []
    assert feedback["unresolved_labels"] == []


def test_the_label_finder_is_the_contract():
    found = processor._unresolved_speaker_labels(
        "Speaker 1: one\nSpeaker  2: two\nS1: three\nSam: four\n", {})
    assert [f["raw_label"] for f in found] == ["Speaker 1", "Speaker 2"]
