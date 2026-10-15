"""VENDOR TEST, run against vendor/cm048_pipeline, the tree that ships.

A one-speaker capture is a memo, and the frontmatter tells the truth.

Mini16, 2026-10-15: a one-speaker voice memo from the iPhone app was
written to ~/Documents/Ostler/Conversations/<id>.md as a two-person call:
a second participant built from the speaker's own label plus a role copied
out of the prompt ("new acquaintance, ex-..."), a summary in which the
speaker "caught up with" themself, a location "inferred from transcript
structure", ``enrichment_completed_at`` padded to midnight, an
``enrichment_model`` copied from the prompt template (a 35B model on a box
that had only a 2B model), and ``conversation_id: N/A``.

The model reply below reproduces that SHAPE with synthetic text. The test
drives the real pipeline (processor.process, through 01_classify and
02_enrich) and then the real writer of that file
(ingest._write_conversation_md), and reads the file it wrote.
Synthetic data only; nothing here is copied from the capture.
"""
from __future__ import annotations

import sys
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm048_pipeline"))

from src import ingest, processor  # noqa: E402
from src.settings import Settings, ensure_directories  # noqa: E402

CID = "00000000-0000-4000-8000-00000000a11c"
RAN = "synthetic-small:2b"  # the model the pipeline actually asks for
TEMPLATE_MODEL = "qwen3.5:35b-a3b"  # the label printed in the prompt template

MEMO = (
    "S1: Quick synthetic note to check the garden tap recording.\n"
    "S1: Reminder: the parcel goes back on Friday.\n"
    "S1: Hello to the team, thanks for the tidy shed.\n"
)
DUO = (
    "S1: Synthetic question about the garden tap.\n"
    "S2: Synthetic answer, it is fixed now.\n"
    "S1: Synthetic thanks.\n"
)

# What a small model writes after reading 02_enrich_social_casual: the
# example frontmatter and roster copied, the one speaker turned into two.
MODEL_REPLY = f"""---
conversation_id: N/A
classification:
  setting: social
  shape: one-on-one
  stakes: low
  suggested_type_slug: social_one-on-one_low
sensitivity:
  level: normal
  categories: []
participants:
  - name: S1
    role: user
  - name: S1
    role: new acquaintance, ex-S1
location: Remote - Voice call (inferred from transcript structure)
prompt_version: 02-social_casual@1.0
enrichment_model: {TEMPLATE_MODEL}
enrichment_completed_at: 2026-10-15T00:00:00Z
retention_tier: tier-3-years
retention_score_inputs:
  signal_density: 0.68
related_conversation_ids: []
review_required: false
---
## Summary
### Participants
- S1

### Location
* Remote - Voice call

S1 caught up with S1 about the garden tap.

## Topics covered
* Garden tap recording.

## Notable moments
- Nothing specific.

## Commitments
_Nothing specific._

## People and places mentioned
* S1
* S1 (new acquaintance, ex-S1)
* The team

## Cleaned transcript
S1: Quick synthetic note to check the garden tap recording.
"""

CLASSIFIER_SAYS = {
    "setting": "social", "shape": "one-on-one", "stakes": "low",
    "confidence": 0.85, "reasoning": "synthetic: a greeting between two people",
    "sensitivity": {"level": "normal", "categories": [], "reasoning": ""},
    "review_before_ingest": False, "processing_depth": "full",
    "hints_used": "none", "suggested_type_slug": "social_one-on-one_low",
}


class _FakeOllama:
    """Stands in for the Ollama HTTP server only. Every pipeline function
    above it is the real one."""

    prompts: list[str] = []

    def __init__(self, *a, **k):
        pass

    def generate(self, model, prompt, **k):
        _FakeOllama.prompts.append(prompt)
        # Enrichment gets the defect-shaped reply; every other free-text
        # call (the step 09 bundle extraction) gets an empty, valid answer.
        reply = (
            MODEL_REPLY if "--- SECTION STRUCTURE REMINDER ---" in prompt
            else '{"overall_summary": "Synthetic.", "topics": [], "todos": []}'
        )
        return SimpleNamespace(
            raw_response=reply, parsed_json=None,
            duration_seconds=0.0, model=model, prompt_chars=len(prompt),
        )

    def generate_json(self, model, prompt, expect="object", **k):
        if "--- TRANSCRIPT (first 3000 chars) ---" in prompt:
            parsed = dict(CLASSIFIER_SAYS)
        else:
            parsed = [] if expect == "array" else {}
        return SimpleNamespace(
            raw_response="{}", parsed_json=parsed,
            duration_seconds=0.0, model=model, prompt_chars=len(prompt),
        )


@pytest.fixture
def settings(tmp_path: Path, monkeypatch) -> Settings:
    monkeypatch.setattr(processor, "OllamaClient", _FakeOllama)
    _FakeOllama.prompts = []
    s = Settings(
        user_id="test-user",
        user_display_name="Test User",
        processing_state_dir=tmp_path / "processing",
        output_conversations_dir=tmp_path / "conversations",
        coach_db_path=tmp_path / "coach" / "observations.db",
    )
    s.ollama_enrich_model = RAN
    s.ollama_classify_model = RAN
    ensure_directories(s)
    return s


def _iphone_metadata(cid: str, labels: list[str]) -> dict:
    # Field-for-field the CM031 envelope shape (participants as [String]).
    return {
        "conversation_id": cid,
        "meeting_id": cid,
        "date": "2026-10-15",
        "start_time": "2026-10-15T14:00:00Z",
        "end_time": "2026-10-15T14:01:00Z",
        "participants": labels,
        "type": "in_person",
        "device_id": "synthetic-device",
        "compartment_level": 0,
        "channel": "spoken",
    }


def _run(settings, cid, transcript, labels):
    state = processor.process(
        cid, transcript, _iphone_metadata(cid, labels), settings,
        ingest_sinks=False,
    )
    assert state.failed_step is None, state.failure_reason
    state_dir = settings.processing_state_dir / cid
    out = ingest._write_conversation_md(state_dir, cid, settings, False)
    assert out is not None and out.exists(), "the writer wrote nothing"
    text = out.read_text()
    fm = yaml.safe_load(text.split("---", 2)[1])
    return state, text, fm


def test_the_written_memo_has_one_participant_and_no_invented_setting(settings):
    state, text, fm = _run(settings, CID, MEMO, ["S1"])
    assert [p["name"] for p in fm["participants"]] == ["S1"], fm["participants"]
    assert "new acquaintance" not in text
    assert "location" not in fm, fm.get("location")
    assert "### Location" not in text
    assert fm["classification"]["shape"] == "memo"
    assert "03_relationship_signal" not in state.completed_steps
    assert "04_coaching" not in state.completed_steps
    people = text.split("## People and places mentioned", 1)[1].split("##", 1)[0]
    assert "S1" not in people and "The team" in people


def test_the_model_was_asked_for_a_memo_not_a_call(settings):
    _run(settings, CID, MEMO, ["S1"])
    enrich_prompts = [p for p in _FakeOllama.prompts if "--- SECTION STRUCTURE REMINDER ---" in p]
    assert enrich_prompts, "no enrichment prompt was sent"
    sent = enrich_prompts[0]
    assert sent.startswith("# Prompt 02 – Enrich: a single-speaker capture"), sent[:80]
    assert "Other name: other" not in sent
    assert "## Notable moments" not in sent.split("--- SECTION STRUCTURE REMINDER ---")[1]


def test_completed_at_is_the_real_time_not_a_padded_date(settings):
    before = datetime.now(timezone.utc).replace(microsecond=0)
    _, _, fm = _run(settings, CID, MEMO, ["S1"])
    after = datetime.now(timezone.utc)
    raw = fm["enrichment_completed_at"]
    stamp = raw if isinstance(raw, datetime) else datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
    assert before <= stamp <= after, (before, stamp, after)


def test_the_model_label_names_the_model_that_ran(settings):
    _, text, fm = _run(settings, CID, MEMO, ["S1"])
    assert fm["enrichment_model"] == RAN
    assert TEMPLATE_MODEL not in text
    assert fm["conversation_id"] == CID
    assert fm["prompt_version"] == "02_enrich_voice_memo@1.0"
    assert "retention_score_inputs" not in fm


def test_control_two_speakers_stay_a_conversation(settings):
    """The predicate must not fire on a real exchange: two labels in the
    transcript and the roster keep the model's shape and both entries."""
    cid = "00000000-0000-4000-8000-00000000d0e0"
    state, text, fm = _run(settings, cid, DUO, ["S1", "S2"])
    assert fm["classification"]["shape"] == "one-on-one"
    assert len(fm["participants"]) == 2
    sent = [p for p in _FakeOllama.prompts if "--- SECTION STRUCTURE REMINDER ---" in p][0]
    assert sent.startswith("# Prompt 02 – Enrich: social")
    # The truthful stamps apply to every capture, not only memos.
    assert fm["enrichment_model"] == RAN and fm["conversation_id"] == cid
    assert "location" not in fm


@pytest.mark.parametrize("transcript,labels,meta,expect", [
    (MEMO, ["S1"], {}, True),
    ("**Test User** (00:01):\nSynthetic note.\n\n**Test User** (00:09):\nMore.\n",
     [{"id": "user", "display": "Test User", "role": "user"}], {}, True),
    ("Synthetic dictation with no labels at all.\n", ["S1"], {}, True),
    # No roster: who was there is unknown, so the model's shape stands.
    (MEMO, [], {}, False),
    (DUO, ["S1"], {}, False),
    (MEMO, ["S1", "S2"], {}, False),
    ("**Test User** (00:01):\nHi.\n\n**Speaker 2** (00:04):\nHello.\n",
     [{"id": "user", "display": "Test User", "role": "user"}], {}, False),
    (MEMO, ["S1"], {"channel": "email"}, False),
    (MEMO, ["S1"], {"source": "gateway"}, False),
])
def test_single_speaker_predicate(transcript, labels, meta, expect):
    from src import capture_truth

    md = {"participants": labels, "channel": "spoken", **meta}
    assert capture_truth.is_single_speaker_capture(transcript, md) is expect


def test_the_bundle_carries_the_capture_times_not_midnight(settings, tmp_path):
    """Sibling on the same capture: the four-artefact bundle read
    started_at/ended_at only, so the envelope's start_time/end_time were
    ignored and a mid-afternoon memo was stamped 00:00-01:00, and the
    memo was labelled a "meeting". Real adapter + real writer."""
    from src import channel_adapter, conversation_writer
    from src.bundle_extractor import BundleExtraction

    _run(settings, CID, MEMO, ["S1"])
    meta = _iphone_metadata(CID, ["S1"])
    c = processor._load_classification(settings.processing_state_dir / CID)
    bundle = channel_adapter.make_bundle(
        metadata=meta, classification=c,
        extraction=BundleExtraction(overall_summary="Synthetic.", topics=[], todos=[]),
        transcript=MEMO, privacy_level="L2",
    )
    out = conversation_writer.write_conversation(
        bundle, root=tmp_path / "bundles", gist_post_fn=None,
    )
    fm = yaml.safe_load((out.folder / "summary.md").read_text().split("---", 2)[1])
    assert fm["started_at"] == "2026-10-15T14:00:00Z", fm["started_at"]
    assert fm["ended_at"] == "2026-10-15T14:01:00Z", fm["ended_at"]
    assert fm["source_subtype"] == "voice_memo"
