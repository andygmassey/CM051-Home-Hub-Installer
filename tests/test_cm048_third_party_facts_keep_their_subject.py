"""A fact about ANOTHER person's family is not a fact about the owner (DMG #27).

The walk: the assistant summarised real messages about someone else's family
event as concerning the owner's own parent. The local model labels a
first-person line ("my dad's ...") with subject "user" whoever wrote it, and
nothing checked who wrote it.

This drives the REAL step 05 (processor._step_facts) with the LLM faked at its
boundary: the fake returns exactly the mis-attributed facts the model produces
(subject "user", the owner's name in the text), with the evidence line copied
from the transcript. The transcripts are in the producers' shapes: iMessage
"**Name** (ts): body", WhatsApp "**Name** (ts):" with the body below.

Cast names and a neutral event (a retirement party) only.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm048_pipeline"))

from src import processor  # noqa: E402
from src.attribution import reattribute, speaker_turns  # noqa: E402
from src.schemas import Classification  # noqa: E402
from src.settings import Settings, ensure_directories  # noqa: E402

PARTICIPANTS = [
    {"id": "user", "display": "Jane Doe", "role": "user"},
    {"id": "bob_smith", "display": "Bob Smith", "role": "other"},
]

BOB_LINE = "My dad's retirement party is on Saturday at the riverside hall."
JANE_LINE = "Lovely, I will bring a cake on Saturday."
JANE_NAMES_BOBS_MUM = "Bob's mum starts her new job at the library on Monday."
BOB_ABOUT_JANES_DAD = "Your dad rang me about the boat club on Sunday."

IMESSAGE = (
    f"**Bob Smith** (2026-10-10T09:00:00Z): {BOB_LINE}\n"
    f"**You** (2026-10-10T09:01:00Z): {JANE_LINE}\n"
    f"**You** (2026-10-10T09:02:00Z): {JANE_NAMES_BOBS_MUM}\n"
    f"**Bob Smith** (2026-10-10T09:03:00Z): {BOB_ABOUT_JANES_DAD}\n"
)

WHATSAPP = (
    "# Bob Smith\n\n"
    "**Bob Smith** (2026-10-10T09:00:00Z):\n"
    "Morning!\n"
    f"{BOB_LINE}\n\n"
    "**Jane Doe** (2026-10-10T09:01:00Z):\n"
    f"{JANE_LINE}\n"
)


def _fact(text, evidence, subject="user"):
    return {"text": text, "type": "fact", "subject": subject, "domain": "personal",
            "confidence": "stated", "privacy_level": "L1", "signal_strength": "strong",
            "temporal": True, "evidence": evidence}


MODEL_FACTS = [
    # The defect: Bob's own father, attributed to the owner.
    _fact("Jane's father has a retirement party on Saturday", f"Bob Smith said: {BOB_LINE}"),
    # Control: the owner speaking about herself stays the owner's.
    _fact("Jane will bring a cake on Saturday", JANE_LINE),
    # The owner names the person concerned: Bob's mother, not the owner's.
    _fact("Jane's mother starts a new job at the library", JANE_NAMES_BOBS_MUM),
    # Bob addressing the owner about HER father: correctly the owner's.
    _fact("Jane's father rang Bob about the boat club", BOB_ABOUT_JANES_DAD),
    # Evidence the transcript does not contain: left alone.
    _fact("Jane likes sailing", "I have always liked sailing"),
]


class FakeLLM:
    def __init__(self, facts):
        self.facts = facts

    def generate_json(self, model, prompt, **_kw):
        return SimpleNamespace(parsed_json={"facts": json.loads(json.dumps(self.facts))})


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    s = Settings(
        user_id="test-user",
        user_display_name="Jane Doe",
        processing_state_dir=tmp_path / "processing",
        output_conversations_dir=tmp_path / "conversations",
        coach_db_path=tmp_path / "coach" / "observations.db",
    )
    ensure_directories(s)
    return s


def _classification() -> Classification:
    return Classification.from_dict({
        "setting": "personal", "shape": "one-on-one", "stakes": "low",
        "confidence": 0.9, "reasoning": "synthetic",
        "sensitivity": {"level": "normal", "categories": [], "reasoning": ""},
        "review_before_ingest": False, "processing_depth": "full",
        "hints_used": "none", "suggested_type_slug": "social_casual",
    })


def _run_step(tmp_path, settings, transcript, facts, source="imessage"):
    state = tmp_path / "state"
    state.mkdir(exist_ok=True)
    (state / "00_raw_transcript.md").write_text(transcript)
    metadata = {"conversation_id": "im-synthetic-1", "source": source, "channel": "im",
                "participants": PARTICIPANTS}
    processor._step_facts(FakeLLM(facts), state, metadata, _classification(), settings, False)
    return json.loads((state / "05_facts.json").read_text())


def test_another_persons_family_event_is_theirs_not_the_owners(tmp_path, settings):
    out = _run_step(tmp_path, settings, IMESSAGE, MODEL_FACTS)
    by_ev = {f["evidence"]: f for f in out}
    bob = by_ev[f"Bob Smith said: {BOB_LINE}"]
    assert bob["subject"] == "other:bob_smith"
    assert "Jane" not in bob["text"] and "Bob Smith" in bob["text"]


def test_the_owner_naming_another_persons_relative_moves_it_to_them(tmp_path, settings):
    out = _run_step(tmp_path, settings, IMESSAGE, MODEL_FACTS)
    mum = next(f for f in out if f["evidence"] == JANE_NAMES_BOBS_MUM)
    assert mum["subject"] == "other:bob_smith"
    assert "Jane" not in mum["text"]


def test_controls_stay_with_the_owner(tmp_path, settings):
    out = _run_step(tmp_path, settings, IMESSAGE, MODEL_FACTS)
    by_ev = {f["evidence"]: f for f in out}
    assert by_ev[JANE_LINE]["subject"] == "user"                 # the owner about herself
    assert by_ev[BOB_ABOUT_JANES_DAD]["subject"] == "user"       # "your dad": the owner's father
    assert by_ev["I have always liked sailing"]["subject"] == "user"   # evidence not found
    assert by_ev[JANE_LINE]["text"] == "Jane will bring a cake on Saturday"


def test_whatsapp_multiline_turns(tmp_path, settings):
    facts = [_fact("Jane's father has a retirement party on Saturday", BOB_LINE)]
    out = _run_step(tmp_path, settings, WHATSAPP, facts, source="whatsapp")
    assert out[0]["subject"] == "other:bob_smith"


def test_evidence_under_two_speakers_is_left_alone():
    transcript = (
        f"**Bob Smith** (t): {BOB_LINE}\n"
        f"**You** (t): {BOB_LINE}\n"
    )
    facts = [_fact("Jane's father has a retirement party", BOB_LINE)]
    reattribute(facts, transcript, {"participants": PARTICIPANTS})
    assert facts[0]["subject"] == "user"


def test_an_unknown_speaker_label_is_left_alone():
    transcript = f"**Tom Brown** (t): {BOB_LINE}\n"
    facts = [_fact("Jane's father has a retirement party", BOB_LINE)]
    reattribute(facts, transcript, {"participants": PARTICIPANTS})
    assert facts[0]["subject"] == "user"


def test_turn_parser_reads_all_three_producer_shapes():
    turns = speaker_turns(
        "**Bob Smith** (2026-10-10T09:00:00Z): one\n"
        "**Bob Smith** (2026-10-10T09:00:00Z):\nTwo\nthree\n"
        "**Jane Doe:** four\n"
    )
    assert [t[0] for t in turns] == ["Bob Smith", "Bob Smith", "Jane Doe"]
    assert turns[1][1] == "two three"
