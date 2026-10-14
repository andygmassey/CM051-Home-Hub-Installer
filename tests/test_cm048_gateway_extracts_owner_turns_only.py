"""A gateway chat's ASSISTANT turns are not facts about the owner (v1.0.107 F&F blocker).

Run against vendor/cm048_pipeline, the tree that ships.

Mini16 #27: the conversation pipeline ingests the owner's chats with their
own assistant (source=gateway, ids zg-*). Fact extraction read the whole
transcript, so the assistant's replies, guesses included, were extracted as
facts with subject=user, and chat then repeated them back confidently.

The fixture is produced by the REAL producer, not hand-typed: a synthetic
ZeroClaw gateway sessions.db is read by CM052's zeroclaw_sessions adapter
and rendered by CM052 wire.render_transcript / render_metadata, exactly the
transcript.md + metadata.json the outbox hands CM048.

The LLM is faked at its boundary (the OllamaClient the steps receive). The
fake is a deterministic extractor: it emits one fact / one todo for each
known synthetic sentence that appears in the TRANSCRIPT section of the
prompt it is handed. So "0 facts" here means the sentence never reached the
model, and the tests also assert on the exact prompt text.

All names and data are synthetic cast values.
"""
from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm048_pipeline"))
sys.path.insert(0, str(ROOT / "vendor" / "cm052_ai_conversations" / "src"))

from cm052 import wire  # noqa: E402
from cm052.adapters import zeroclaw_sessions  # noqa: E402
from src import processor  # noqa: E402
from src.schemas import Classification  # noqa: E402
from src.settings import Settings, ensure_directories  # noqa: E402

OWNER_EMAIL = "rowan.vale@example.invalid"

# What the owner says. Both must still be extracted.
OWNER_CLAIM = "I play cello in the Harbourside Orchestra"
OWNER_TODO = "renew the allotment permit by Friday"

# What only the assistant says. None of it may be extracted.
ASSISTANT_GUESS = "you keep a pet tortoise called Brimble"
ASSISTANT_TODO = "book the piano tuner"
# A bold "Label:" INSIDE an assistant reply. It is not a speaker, so it
# must not end the assistant turn and let this line back in.
ASSISTANT_BOLD_TRAP = "you were born in Port Sable"

ALL_CLAIMS = (OWNER_CLAIM, ASSISTANT_GUESS, ASSISTANT_BOLD_TRAP)
ALL_TODOS = (OWNER_TODO, ASSISTANT_TODO)

MESSAGES = [
    ("user", f"Remember that {OWNER_CLAIM}.", "2026-10-14T08:00:00Z"),
    (
        "assistant",
        f"Noted. I think {ASSISTANT_GUESS}, and you should {ASSISTANT_TODO}.\n"
        f"**Note:** {ASSISTANT_BOLD_TRAP}.",
        "2026-10-14T08:00:05Z",
    ),
    ("user", f"Remind me to {OWNER_TODO}.", "2026-10-14T08:01:00Z"),
    ("assistant", "Done, I will remind you.", "2026-10-14T08:01:04Z"),
]


def _gateway_conversation(tmp_path: Path):
    db = tmp_path / "sessions.db"
    conn = sqlite3.connect(db)
    conn.execute(
        "CREATE TABLE session_metadata (session_key TEXT, created_at TEXT, "
        "last_activity TEXT, message_count INTEGER, name TEXT)"
    )
    conn.execute(
        "CREATE TABLE sessions (id INTEGER PRIMARY KEY, session_key TEXT, "
        "role TEXT, content TEXT, created_at TEXT)"
    )
    conn.execute(
        "INSERT INTO session_metadata VALUES (?,?,?,?,?)",
        ("gw:synthetic-1", "2026-10-14T08:00:00Z", "2026-10-14T08:01:04Z",
         len(MESSAGES), "Synthetic chat"),
    )
    for role, content, ts in MESSAGES:
        conn.execute(
            "INSERT INTO sessions (session_key, role, content, created_at) "
            "VALUES (?,?,?,?)",
            ("gw:synthetic-1", role, content, ts),
        )
    conn.commit()
    conn.close()
    (conv,) = list(zeroclaw_sessions.read(db))
    return conv


@pytest.fixture
def gateway(tmp_path, monkeypatch):
    monkeypatch.setenv("CM052_USER_EMAIL", OWNER_EMAIL)
    monkeypatch.delenv("CM052_ASSISTANT_NAME", raising=False)
    conv = _gateway_conversation(tmp_path)
    transcript = wire.render_transcript(conv)
    metadata = wire.render_metadata(conv)
    # The producer's own shape, which the filter keys on.
    assert conv.conversation_id.startswith("zg-")
    assert metadata["source"] == "gateway"
    assert f"**{OWNER_EMAIL}:**" in transcript and "**Assistant:**" in transcript
    return transcript, metadata


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    s = Settings(
        user_id="test-user",
        user_display_name="Rowan Vale",
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


def _transcript_section(prompt: str) -> str:
    return prompt.split("--- TRANSCRIPT ---", 1)[1]


class FakeLLM:
    """Deterministic stand-in for OllamaClient at the step boundary."""

    def __init__(self) -> None:
        self.prompts: list[str] = []

    def generate_json(self, model, prompt, **_kw):
        self.prompts.append(prompt)
        seen = _transcript_section(prompt)
        facts = [
            {"text": c, "type": "fact", "subject": "user", "domain": "personal",
             "confidence": "stated", "privacy_level": "L1",
             "signal_strength": "strong", "temporal": False, "evidence": c}
            for c in ALL_CLAIMS if c in seen
        ]
        return SimpleNamespace(parsed_json={"facts": facts})

    def generate(self, *, model, prompt, **_kw):
        self.prompts.append(prompt)
        seen = _transcript_section(prompt)
        todos = [{"text": t, "owner": "user"} for t in ALL_TODOS if t in seen]
        return SimpleNamespace(raw_response=json.dumps({
            "overall_summary": "Synthetic summary.",
            "topics": [{"name": "Synthetic", "points": ["p"]}],
            "todos": todos,
        }))


def _state_dir(settings, transcript, metadata) -> Path:
    d = settings.processing_state_dir / metadata["conversation_id"]
    d.mkdir(parents=True, exist_ok=True)
    processor._write_raw(d, metadata["conversation_id"], transcript, metadata)
    return d


def _run_facts(settings, transcript, metadata):
    d = _state_dir(settings, transcript, metadata)
    llm = FakeLLM()
    processor._step_facts(llm, d, metadata, _classification(), settings, False)
    facts = json.loads((d / "05_facts.json").read_text())
    return [f["text"] for f in facts], llm.prompts[-1]


def test_assistant_only_claim_yields_no_fact(settings, gateway):
    texts, _ = _run_facts(settings, *gateway)
    assert texts.count(ASSISTANT_GUESS) == 0, texts


def test_owner_claim_still_yields_exactly_one_fact(settings, gateway):
    texts, _ = _run_facts(settings, *gateway)
    assert texts.count(OWNER_CLAIM) == 1, texts


def test_fact_prompt_holds_owner_turns_and_no_assistant_turn(settings, gateway):
    _, prompt = _run_facts(settings, *gateway)
    seen = _transcript_section(prompt)
    assert OWNER_CLAIM in seen
    assert OWNER_TODO in seen
    assert ASSISTANT_GUESS not in seen
    assert ASSISTANT_TODO not in seen
    assert "**Assistant:**" not in seen
    assert "I will remind you" not in seen


def test_a_bold_label_inside_an_assistant_reply_does_not_reopen_it(settings, gateway):
    texts, prompt = _run_facts(settings, *gateway)
    assert ASSISTANT_BOLD_TRAP not in _transcript_section(prompt)
    assert ASSISTANT_BOLD_TRAP not in texts


def _run_bundle(settings, transcript, metadata, monkeypatch):
    d = _state_dir(settings, transcript, metadata)
    llm = FakeLLM()
    handed: dict = {}

    def _capture(**kw):
        handed["transcript"] = kw["transcript"]
        raise NotImplementedError("test stops before the disk write")

    from src import topic_writer
    monkeypatch.setattr(topic_writer, "write_topics", lambda **_kw: None)
    monkeypatch.setattr(processor._channel_adapter, "make_bundle", _capture)
    processor._step_bundle(
        llm, d, metadata, _classification(), settings, "L1",
        ingest_sinks=True, dry_run=False,
    )
    bundle = json.loads((d / "09_bundle.json").read_text())
    return [t["text"] for t in bundle["todos"]], llm.prompts[-1], handed


def test_owner_todo_still_extracted_assistant_todo_is_not(settings, gateway, monkeypatch):
    todos, prompt, _ = _run_bundle(settings, *gateway, monkeypatch)
    assert todos == [OWNER_TODO], todos
    seen = _transcript_section(prompt)
    assert OWNER_TODO in seen and ASSISTANT_TODO not in seen


def test_rendered_transcript_artefact_keeps_every_turn(settings, gateway, monkeypatch):
    transcript, metadata = gateway
    _, _, handed = _run_bundle(settings, transcript, metadata, monkeypatch)
    # The bundle's transcript artefact is the full conversation, unfiltered.
    assert handed["transcript"] == transcript
    assert ASSISTANT_GUESS in handed["transcript"]
    # And the stored raw transcript is untouched.
    d = settings.processing_state_dir / metadata["conversation_id"]
    assert (d / "00_raw_transcript.md").read_text() == transcript


def test_a_non_gateway_transcript_is_not_filtered(settings, gateway):
    transcript, metadata = gateway
    other = dict(metadata, source="whatsapp",
                 conversation_id="2026-10-14_whatsapp_synthetic",
                 provenance={"source_kind": "whatsapp",
                             "source_subtype": "whatsapp"})
    assert processor._extraction_transcript(transcript, other) == transcript
    texts, _ = _run_facts(settings, transcript, other)
    assert ASSISTANT_GUESS in texts  # control: the fake does extract it


def test_owner_label_found_without_the_env_var(gateway, monkeypatch):
    transcript, metadata = gateway
    monkeypatch.delenv("CM052_USER_EMAIL", raising=False)
    kept = processor._extraction_transcript(transcript, metadata)
    assert OWNER_CLAIM in kept and OWNER_TODO in kept
    assert ASSISTANT_GUESS not in kept and ASSISTANT_BOLD_TRAP not in kept


def test_a_configured_assistant_name_is_dropped_too(monkeypatch):
    monkeypatch.setenv("CM052_ASSISTANT_NAME", "Marlowe")
    monkeypatch.setenv("CM052_USER_EMAIL", OWNER_EMAIL)
    t = (f"**{OWNER_EMAIL}:** Remember that {OWNER_CLAIM}.\n\n"
         f"**Marlowe:** I think {ASSISTANT_GUESS}.\n\n")
    kept = processor._extraction_transcript(t, {"source": "gateway"})
    assert OWNER_CLAIM in kept and ASSISTANT_GUESS not in kept
