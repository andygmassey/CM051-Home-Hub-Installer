"""L3 todos are dropped by the READERS, not only by the writer.

THE GAP
-------
CM048's writer refuses to store a todo from an L3 (most private)
conversation: processor.py step 07 (`resolved_privacy_level != "L3"`),
processor._step_ingest (`privacy_level == "L3"`) and ingest.py
(`todo_privacy != "L3"`). The daily brief is EMAILED, and its todo reader
(meeting_syncer/brief.py `_get_outstanding_todos`) and the commitments API
(ical-server.py `commitments_list`) did not look at privacyLevel at all, so
L3 safety rested on one writer.

WHAT THIS PINS, END TO END
--------------------------
The pipeline is the REAL vendored CM048 `process()` over a REAL pyoxigraph
store (fake LLM, synthetic data). The three writer guards are mutated OFF
in a private copy of the vendored tree (each replacement is asserted to
have applied, so a mutant that did not apply cannot pass as a result), so an
L3-tagged todo genuinely reaches the store. Then the two readers are run
over that store and must show the L1 control todo and NOT the L3 one.

Controls: the L3 todo is asserted PRESENT in the store before the readers
run (otherwise "absent from the reader" proves nothing); with the guards ON
the L3 todo never reaches the store; an untagged legacy todo is still
served by both readers.
"""
from __future__ import annotations

import importlib.util
import re
import shutil
import sys
from pathlib import Path

import httpx
import pyoxigraph
import pytest

from _update_fakes import Fakes as _BaseFakes


class Fakes(_BaseFakes):
    """The base fake, plus an `## Action items` table in the enrichment.

    OutstandingTodo nodes are parsed from that table
    (outstanding_todos.parse_action_items_table), not from the summary
    prompt's todo list, so this is what makes a todo reach the store.
    """

    action_item = ""

    def _answer(self, prompt: str) -> str:
        out = super()._answer(prompt)
        if "# Prompt 02" in prompt and self.action_item:
            table = (
                "## Action items\n\n"
                "| Owner | Action | Deadline | Priority |\n"
                "| --- | --- | --- | --- |\n"
                f"| Me | {self.action_item} | | medium |\n\n"
            )
            # Replace the base fake's bullet body under that heading.
            out, n = re.subn(r"## Action items\n\n- [^\n]*\n\n", table, out)
            assert n == 1, "base fake no longer emits an Action items section"
        return out

REPO = Path(__file__).resolve().parents[2]
VENDOR_PIPELINE = REPO / "vendor" / "cm048_pipeline"
CM041 = REPO / "vendor" / "cm041"

L1_TODO = "send Jane Doe the report"
L3_TODO = "send Bob Doe the secret report"
LEGACY_TODO = "Book a room for Jane Doe"

# (file, exact text, replacement): the three writer guards, switched off.
GUARDS = [
    ("src/processor.py",
     'and resolved_privacy_level != "L3"\n        and _should_run("07_sinks_written"',
     'and True\n        and _should_run("07_sinks_written"'),
    ("src/processor.py", 'if privacy_level == "L3":\n        logger.info(\n            "L3 short-circuit: skipping gist sinks for %s "',
     'if False:\n        logger.info(\n            "L3 short-circuit: skipping gist sinks for %s "'),
    ("src/ingest.py", 'if todo_privacy != "L3":', "if True:"),
]


def _metadata(conv_id: str, level: str) -> dict:
    return {
        "conversation_id": conv_id,
        "date": "2026-10-19",
        "started_at": "2026-10-19T10:00:00Z",
        "channel": "im",
        "source": "imessage",
        "privacy_level": level,
        "participants": [
            {"id": "user", "display": "Me", "role": "user"},
            {"id": "other:jane", "display": "Jane Doe", "role": "other"},
        ],
    }


def _transcript(todo: str) -> str:
    return f"[10:00] Jane: Please sort this.\n[10:01] Me: Yes, I will do it.\n"


def _mutated_copy(dest: Path) -> Path:
    tree = dest / "cm048_pipeline"
    shutil.copytree(
        VENDOR_PIPELINE, tree,
        ignore=shutil.ignore_patterns(".venv", "__pycache__", "tests", ".git"),
    )
    for rel, old, new in GUARDS:
        f = tree / rel
        text = f.read_text()
        assert text.count(old) == 1, f"mutant did not apply: {rel}: {old!r}"
        f.write_text(text.replace(old, new))
    return tree


class _PipelineAt:
    """Import `src` from a given tree, then put sys.modules back."""

    def __init__(self, tree: Path) -> None:
        self.tree = str(tree)

    def __enter__(self):
        self.saved = {k: v for k, v in sys.modules.items()
                      if k == "src" or k.startswith("src.")}
        for k in self.saved:
            del sys.modules[k]
        sys.path.insert(0, self.tree)
        from src import processor, settings  # noqa: PLC0415
        assert Path(processor.__file__).resolve().is_relative_to(Path(self.tree).resolve())
        return processor, settings

    def __exit__(self, *exc):
        sys.path.remove(self.tree)
        for k in [k for k in sys.modules if k == "src" or k.startswith("src.")]:
            del sys.modules[k]
        sys.modules.update(self.saved)


def _run_pipeline(tree: Path, tmp: Path, fakes: Fakes, conv_id: str, level: str,
                  todo: str, monkeypatch) -> None:
    fakes.action_item = todo
    with _PipelineAt(tree) as (processor, settings_mod):
        monkeypatch.setattr(processor, "BASE_DELAY_SECONDS", 0)
        s = settings_mod.Settings(
            user_id="test-user",
            user_display_name="Test User",
            processing_state_dir=tmp / "processing",
            output_conversations_dir=tmp / "Conversations",
            coach_db_path=tmp / "coach" / "observations.db",
            ollama_url="http://fake-ollama",
            qdrant_url="http://fake-qdrant",
            oxigraph_url="http://fake-oxigraph",
            reprocess_cooldown_seconds=0,
        )
        settings_mod.ensure_directories(s)
        state = processor.process(conv_id, _transcript(todo), _metadata(conv_id, level), s)
        assert state.failed_step is None, state.failure_reason


@pytest.fixture
def fakes(monkeypatch, tmp_path):
    f = Fakes()
    real_client = httpx.Client

    def client(*args, **kwargs):
        kwargs["transport"] = httpx.MockTransport(f.handle)
        return real_client(*args, **kwargs)

    monkeypatch.setattr(httpx, "Client", client)
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    return f


def _todo_texts_in_store(store: pyoxigraph.Store) -> dict[str, str]:
    q = ("SELECT ?t ?l WHERE { ?x a <urn:ostler:OutstandingTodo> ; "
         "<urn:ostler:todoText> ?t . OPTIONAL { ?x <urn:ostler:privacyLevel> ?l } }")
    return {r["t"].value: (r["l"].value if r["l"] is not None else "")
            for r in store.query(q, use_default_graph_as_union=True)}


def _store_with_l3_leaked(fakes, tmp_path, monkeypatch):
    tree = _mutated_copy(tmp_path / "mut")
    _run_pipeline(tree, tmp_path / "a", fakes, "2026-10-19_im_l1", "L1", L1_TODO, monkeypatch)
    _run_pipeline(tree, tmp_path / "b", fakes, "2026-10-19_im_l3", "L3", L3_TODO, monkeypatch)
    # An untagged legacy todo, written straight into the store.
    fakes.store.update(
        'INSERT DATA { <urn:ostler:todo/legacy> a <urn:ostler:OutstandingTodo> ; '
        '<urn:ostler:todoText> "%s" ; <urn:ostler:owner> "user" ; '
        '<urn:ostler:status> "open" ; '
        '<urn:ostler:aboutPerson> <urn:ostler:person/jane> . }' % LEGACY_TODO
    )
    return _todo_texts_in_store(fakes.store)


def _person_uri(store) -> str:
    q = "SELECT DISTINCT ?p WHERE { ?x <urn:ostler:aboutPerson> ?p }"
    return next(iter(store.query(q, use_default_graph_as_union=True)))["p"].value


def _brief_texts(fakes, store) -> list[str]:
    sys.path.insert(0, str(CM041))
    try:
        from meeting_syncer import brief  # noqa: PLC0415
    finally:
        sys.path.remove(str(CM041))

    def fake_query(_url, sparql):
        res = store.query(sparql, use_default_graph_as_union=True)
        import json
        return json.loads(res.serialize(format=pyoxigraph.QueryResultsFormat.JSON))

    orig = brief._sparql_query
    brief._sparql_query = fake_query
    try:
        out = []
        for person in {r["p"].value for r in store.query(
                "SELECT DISTINCT ?p WHERE { ?x <urn:ostler:aboutPerson> ?p }",
                use_default_graph_as_union=True)}:
            out += [t["text"] for t in brief._get_outstanding_todos("http://x", person)]
        return out
    finally:
        brief._sparql_query = orig


def _api_texts(store) -> list[str]:
    sys.path.insert(0, str(CM041 / "assistant_api"))
    sys.path.insert(0, str(CM041))
    try:
        spec = importlib.util.spec_from_file_location(
            "ical_server_l3_defence", CM041 / "assistant_api" / "ical-server.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    finally:
        sys.path.remove(str(CM041))
        sys.path.remove(str(CM041 / "assistant_api"))

    def fake_select(sparql):
        res = store.query(sparql, use_default_graph_as_union=True)
        return [{str(v)[1:] if str(v).startswith("?") else str(v): b[v].value
                 for v in res.variables if b[v] is not None} for b in res]

    mod._sparql_select = fake_select
    body, code = mod.commitments_list(owner=None, status="open", limit=100)
    assert code == 200, body
    return [c["action"] for c in body["commitments"]]


def test_with_writer_guards_off_the_l3_todo_reaches_the_store(fakes, tmp_path, monkeypatch):
    """Control: without this, 'the readers drop it' proves nothing."""
    in_store = _store_with_l3_leaked(fakes, tmp_path, monkeypatch)
    assert in_store.get(L3_TODO) == "L3", in_store
    assert in_store.get(L1_TODO) == "L1", in_store


def test_brief_todo_reader_drops_l3_and_keeps_l1_and_legacy(fakes, tmp_path, monkeypatch):
    in_store = _store_with_l3_leaked(fakes, tmp_path, monkeypatch)
    assert L3_TODO in in_store  # the leak happened
    texts = _brief_texts(fakes, fakes.store)
    assert L3_TODO not in texts, texts
    assert L1_TODO in texts, texts
    assert LEGACY_TODO in texts, texts


def test_commitments_api_drops_l3_and_keeps_l1_and_legacy(fakes, tmp_path, monkeypatch):
    in_store = _store_with_l3_leaked(fakes, tmp_path, monkeypatch)
    assert L3_TODO in in_store
    texts = _api_texts(fakes.store)
    assert L3_TODO not in texts, texts
    assert L1_TODO in texts, texts
    assert LEGACY_TODO in texts, texts


def test_with_guards_on_the_l3_todo_never_reaches_the_store(fakes, tmp_path, monkeypatch):
    """The unmutated writer, as a control that the mutation is what leaks."""
    _run_pipeline(VENDOR_PIPELINE, tmp_path / "a", fakes, "2026-10-19_im_l3", "L3",
                  L3_TODO, monkeypatch)
    assert L3_TODO not in _todo_texts_in_store(fakes.store)
