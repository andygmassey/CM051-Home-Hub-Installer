"""CM051 Lane 9: the SHIPPED vendor/cm048_pipeline gives non-English owners
first-class summaries and todos. Mirrors CM048 tests/test_multilingual_output.py,
but runs against the vendored copy that a customer actually runs.

Lane 9: non-English owners get first-class summaries and todos.

Product decision (founder, 2026-09-22): the UI stays English; the
assistant writes summaries and todos in the conversation's own language
(default) or the owner's ``summary_language`` setting.

All fixtures under tests/fixtures/multilingual/ are synthetic and
fictional. The model is a deterministic stub that answers in the
language the PROMPT asks for, and in English otherwise, so each test
fails if the prompt stops carrying the language instruction.
"""
from __future__ import annotations

import sys
from pathlib import Path as _P

_ROOT = _P(__file__).resolve().parent.parent
sys.path.insert(0, str(_ROOT / "vendor" / "cm048_pipeline"))

import json
import re
from dataclasses import dataclass
from pathlib import Path

import pytest

from src import bundle_extractor, chunker, conversation_writer as cw
from src import language, outstanding_todos, prompts
from src.channel_adapter import make_bundle
from src.processor import _build_enrichment_input
from src.schemas import Classification, Sensitivity
from src.settings import Settings

FIX = Path(__file__).parent / "fixtures" / "multilingual"

SAMPLES = {
    "fr": "fr_cafe.md",
    "de": "de_projektbesprechung.md",
    "es": "es_reunion.md",
    "it": "it_riunione.md",
    "ja": "ja_kaigi.md",
    "zh": "zh_huiyi.md",
}

# What the stub "model" writes per language when told to.
CANNED = {
    "de": {
        "overall_summary": "Jane Doe und Tom Smith besprachen das Angebot für die Bäckerei am Markt.",
        "topics": [{"name": "Angebot der Bäckerei", "points": ["Tom schickt die Unterlagen bis morgen.", "Greta prüft das Budget."]}],
        "todos": [
            {"text": "überarbeitete Unterlagen an Jane schicken", "owner": "other", "deadline": None},
            {"text": "Budget prüfen und eine Zusammenfassung schreiben", "owner": "user", "deadline": None},
        ],
    },
    "ja": {
        "overall_summary": "田中花子と佐藤健は新しい店舗の予算について話し合った。",
        "topics": [{"name": "店舗の予算", "points": ["佐藤さんが明日までに見積書を送る。"]}],
        "todos": [{"text": "見積書を送る", "owner": "other", "deadline": None}],
    },
    "en": {
        "overall_summary": "ENGLISH FALLBACK SUMMARY.",
        "topics": [{"name": "Fallback", "points": ["English point."]}],
        "todos": [{"text": "English todo", "owner": "user", "deadline": None}],
    },
}


@dataclass
class _Result:
    raw_response: str
    parsed_json: object = None
    duration_seconds: float = 0.0
    model: str = "stub"
    prompt_chars: int = 0


class StubModel:
    """Writes in the language the prompt's OUTPUT LANGUAGE block names."""

    def __init__(self):
        self.prompts: list[str] = []

    def generate(self, model, prompt, **_kw):
        self.prompts.append(prompt)
        m = re.search(r"--- OUTPUT LANGUAGE ---\nWrite every summary sentence, topic name, topic point and todo in ([A-Za-z]+)", prompt)
        name = m.group(1) if m else "English"
        code = {"German": "de", "Japanese": "ja"}.get(name, "en")
        return _Result(raw_response=json.dumps(CANNED[code], ensure_ascii=False))


def _settings(tmp_path, **kw) -> Settings:
    return Settings(
        user_id="test-user", user_display_name="Test Owner",
        processing_state_dir=tmp_path / "p",
        output_conversations_dir=tmp_path / "c",
        coach_db_path=tmp_path / "coach" / "o.db", **kw,
    )


def _classification() -> Classification:
    return Classification(
        setting="work", shape="one-on-one", stakes="medium", confidence=0.9,
        reasoning="synthetic fixture",
        sensitivity=Sensitivity(level="normal", categories=[], reasoning=""),
        suggested_type_slug="work_one-on-one_medium",
    )


def _text(code: str) -> str:
    return (FIX / SAMPLES[code]).read_text(encoding="utf-8")


# ── detection ──────────────────────────────────────────────────────────


@pytest.mark.parametrize("code", sorted(SAMPLES))
def test_detects_each_fixture_language(code):
    assert language.detect_language(_text(code)) == code


def test_capture_language_beats_detection_and_setting_beats_capture(tmp_path):
    s = _settings(tmp_path)
    assert language.resolve_output_language(s, {"language": "fr"}, _text("de")).code == "fr"
    pinned = _settings(tmp_path, summary_language="de")
    got = language.resolve_output_language(pinned, {"language": "fr"}, _text("fr"))
    assert (got.code, got.source) == ("de", "setting")


def test_default_is_conversation_language_and_documented(tmp_path):
    s = _settings(tmp_path)
    assert s.summary_language == "conversation"
    got = language.resolve_output_language(s, {}, _text("ja"))
    assert (got.code, got.source) == ("ja", "detected")
    example = (_ROOT / "vendor" / "cm048_pipeline" / "settings.yaml.example").read_text(encoding="utf-8")
    assert "summary_language" in example


def test_mixed_language_is_flagged_not_collapsed(tmp_path):
    mixed = _text("zh") + "\nAlex: Sounds good, I will send the report tomorrow to the team.\nAlex: We have the meeting and the budget for this.\n"
    got = language.resolve_output_language(_settings(tmp_path), {}, mixed)
    assert got.code == "zh" and "en" in got.mixed
    assert "mixes languages" in language.language_instruction(got)


# ── the prompt carries the instruction ─────────────────────────────────


def test_german_transcript_gets_german_instruction_in_enrichment_prompt(tmp_path):
    cls = _classification()
    body = _build_enrichment_input(
        _text("de"), {"participants": []}, cls, prompts.load_conventions(), _settings(tmp_path)
    )
    assert "--- OUTPUT LANGUAGE ---" in body
    assert "in German." in body
    assert "stay in English" in body  # headings and keys are NOT translated


# ── German conversation through extraction -> writer -> todos.md ──────


def test_german_conversation_flows_to_german_summary_and_todos(tmp_path):
    stub = StubModel()
    settings = _settings(tmp_path)
    transcript = _text("de")
    out_lang = language.resolve_output_language(settings, {}, transcript)
    extraction = bundle_extractor.extract(
        stub, transcript=transcript, enrichment_md="", channel="spoken",
        model="stub", locale="en-GB", output_language=out_lang,
    )
    assert "in German." in stub.prompts[0]
    assert "Bäckerei" in extraction.overall_summary
    assert len(extraction.todos) == 2

    classification = _classification()
    metadata = {
        "conversation_id": "2026-10-01_greta_brandt_de",
        "date": "2026-10-01", "source": "in-person", "language": "de",
        "participants": [
            {"id": "user", "display": "Jane Doe", "role": "user"},
            {"id": "tom_smith", "display": "Tom Smith", "role": "other"},
        ],
    }
    bundle = make_bundle(
        metadata=metadata, classification=classification,
        extraction=extraction, transcript=transcript,
    )
    out = cw.write_conversation(bundle, root=tmp_path / "Conversations")
    summary = out.summary_path.read_text(encoding="utf-8")
    todos = out.todos_path.read_text(encoding="utf-8")
    assert "Bäckerei am Markt" in summary and "Angebot der Bäckerei" in summary
    assert "überarbeitete Unterlagen" in todos and "Zusammenfassung" in todos
    assert todos.count("\n- ") == 2  # nothing silently dropped
    assert "Größe" in out.transcript_path.read_text(encoding="utf-8")


def test_japanese_summary_survives_the_writer_and_folder_is_named(tmp_path):
    stub = StubModel()
    text = _text("ja")
    lang = language.resolve_output_language(_settings(tmp_path), {}, text)
    extraction = bundle_extractor.extract(
        stub, transcript=text, enrichment_md="", channel="spoken",
        model="stub", output_language=lang,
    )
    assert "in Japanese." in stub.prompts[0]
    assert extraction.overall_summary.startswith("田中花子")
    assert cw._slug_segment("田中花子 佐藤健") == "田中花子-佐藤健"


def test_without_the_instruction_the_stub_would_answer_in_english():
    """Control arm: proves the stub only goes German because of the prompt."""
    class NoLang(StubModel):
        pass

    stub = NoLang()
    r = stub.generate("m", "plain prompt with no language block")
    assert "ENGLISH FALLBACK" in r.raw_response


# ── todos: structure stays English, but a translated one is not lost ──


GERMAN_TABLE_EN_HEADINGS = """## Summary
Kurz.

## Action items

| Owner | Action | Deadline | Priority | Notes |
|---|---|---|---|---|
| Tom Smith | Unterlagen an Greta schicken | morgen | hoch | - |
| Jane Doe | Budget prüfen | 2026-10-09 | mittel | erledigt |
"""

GERMAN_TABLE_DE_HEADINGS = """## Zusammenfassung
Kurz.

## Aufgaben

| Verantwortlich | Aufgabe | Frist | Priorität | Notizen |
|---|---|---|---|---|
| Tom Smith | Unterlagen an Greta schicken | morgen | hoch | - |
| Jane Doe | Budget prüfen | 2026-10-09 | mittel | erledigt |
"""

_META = {
    "conversation_id": "c1", "date": "2026-10-07",
    "participants": [
        {"id": "user", "display": "Jane Doe", "role": "user"},
        {"id": "tom_smith", "display": "Tom Smith", "role": "other"},
    ],
}


@pytest.mark.parametrize("md", [GERMAN_TABLE_EN_HEADINGS, GERMAN_TABLE_DE_HEADINGS])
def test_german_action_table_is_extracted_not_silently_dropped(md):
    todos = outstanding_todos.extract_outstanding_todos(md, _META)
    assert [t.action_text for t in todos] == [
        "Unterlagen an Greta schicken", "Budget prüfen",
    ]
    first, second = todos
    assert first.deadline == "2026-10-08"  # "morgen" -> tomorrow
    assert first.priority == "high"
    assert second.status == "closed"       # "erledigt"
    assert second.deadline == "2026-10-09"


def test_sidecar_round_trip_keeps_non_ascii(tmp_path):
    todos = outstanding_todos.extract_outstanding_todos(GERMAN_TABLE_DE_HEADINGS, _META)
    outstanding_todos.write_sidecar(tmp_path, todos)
    raw = (tmp_path / "outstanding_todos.json").read_text(encoding="utf-8")
    assert "prüfen" in raw  # ensure_ascii=False: not ü escaped
    assert [t.action_text for t in outstanding_todos.load_sidecar(tmp_path)] == [t.action_text for t in todos]


def test_cjk_action_table_is_extracted():
    md = """## Action items

| Owner | Action | Deadline | Priority | Notes |
|---|---|---|---|---|
| 佐藤健 | 見積書を送る | 明日 | 高 | - |
"""
    meta = dict(_META, participants=[
        {"id": "user", "display": "田中花子", "role": "user"},
        {"id": "sato", "display": "佐藤健", "role": "other"},
    ])
    (todo,) = outstanding_todos.extract_outstanding_todos(md, meta)
    assert todo.action_text == "見積書を送る"
    assert todo.owner_display == "佐藤健"
    assert todo.deadline == "2026-10-08" and todo.priority == "high"


# ── chunker is not Latin-only ──────────────────────────────────────────


def test_cjk_transcript_is_chunked_to_fit_the_context():
    turn = "田中：" + "今日は新しい店舗の予算についてお話しします。" * 20 + "\n"
    text = turn * 400  # ~ 100k chars of Japanese
    chunks = chunker.chunk_transcript(text)
    assert len(chunks) > 1, "CJK must not be treated as 4 chars per token"
    assert all(len(c.content) < 40_000 for c in chunks)


def test_non_latin_speaker_labels_are_turn_boundaries():
    t = "田中: こんにちは\nИван: привет\nÉlodie: salut\n"
    assert len(chunker._find_turn_boundaries(t)) == 3
    assert chunker._find_turn_boundaries("see https://example.test/x\n") == []


def test_cjk_sentence_end_splits_without_a_space():
    assert len(chunker._SENTENCE_END.findall("今日は雨です。明日は晴れ！")) >= 2


# ── CJK round trip through the writer (the wiki's source files) ───────


def test_cjk_conversation_round_trips_through_the_four_artefacts(tmp_path):
    ja = _text("ja")
    summary_text = "田中花子と佐藤健は新しい店舗の予算について話し合った。"
    extraction = bundle_extractor.BundleExtraction(
        overall_summary=summary_text,
        topics=[{"name": "店舗の予算", "points": ["佐藤さんが明日までに見積書を送る。"]}],
        todos=[{"text": "見積書を送る", "owner": "other", "deadline": None}],
    )
    metadata = {
        "conversation_id": "2026-10-01_ja_round_trip",
        "date": "2026-10-01", "source": "in-person", "language": "ja",
        "participants": [
            {"id": "user", "display": "田中花子", "role": "user"},
            {"id": "sato", "display": "佐藤健", "role": "other"},
        ],
    }
    bundle = make_bundle(
        metadata=metadata, classification=_classification(),
        extraction=extraction, transcript=ja,
    )
    out = cw.write_conversation(bundle, root=tmp_path / "Conversations")

    assert out.folder.is_dir()
    assert out.transcript_path.read_bytes().decode("utf-8").count("予算") >= 1
    transcript = out.transcript_path.read_text(encoding="utf-8")
    assert ja.strip() in transcript  # the transcript body is byte for byte
    assert summary_text in out.summary_path.read_text(encoding="utf-8")
    todos = out.todos_path.read_text(encoding="utf-8")
    assert "見積書を送る" in todos and "\\u" not in todos
    for p in (out.summary_path, out.transcript_path, out.todos_path):
        assert "�" not in p.read_text(encoding="utf-8"), p.name  # no replacement characters
