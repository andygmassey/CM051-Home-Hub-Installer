"""v1018-D021: a thread must be readable on the tick it arrives.

The defect is not that enrichment is slow. It is that NOTHING the
customer can read exists until enrichment finishes, because the
four-artefact bundle is produced by the sixth of six serialised model
calls. So these tests assert the two properties that fix costs:

  1. A bundle can be written with ZERO model calls, and it is honest
     about being provisional.
  2. The seed pass runs BEFORE the enrichment pass in a tick, and never
     overwrites a bundle a model already wrote.

Property 1 is proved by pointing the pipeline's Ollama URL at a port
nothing is listening on. If any code path in the seed reached for a
model, the test could not pass.

All fixture content is synthetic: @example.test addresses, placeholder
names, filler bodies.

Run from the CM051 repo root:
    python -m pytest vendor/email_source/tests/test_seed_first_wiki.py
"""
from __future__ import annotations

import json
import socket
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

_VENDOR = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_VENDOR))
sys.path.insert(0, str(_VENDOR / "cm048_pipeline"))

from email_source.pipeline import process_email  # noqa: E402
from src.settings import Settings  # noqa: E402

from test_email_source import (  # noqa: E402
    USER_ADDRESS,
    _StubDispatch,
    _emlx_bytes,
    _write_emlx,
)


SUBJECT = "Quarterly filing question"
CONTACT = "contact.one@example.test"


def _seed_module():
    """Imported lazily so this file still COLLECTS on a tree without the
    seed module. A gate that dies at import proves only that a name is
    missing; the tick-order assertions below have to be able to run and
    fail on behaviour."""
    from src import seed  # noqa: PLC0415

    return seed


def _closed_port() -> int:
    """A port with nothing behind it, so any model call fails loudly."""
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _settings(tmp_path: Path) -> Settings:
    return Settings(
        user_id="test-user",
        ollama_url=f"http://127.0.0.1:{_closed_port()}",
        qdrant_url=f"http://127.0.0.1:{_closed_port()}",
        oxigraph_url=f"http://127.0.0.1:{_closed_port()}",
        processing_state_dir=tmp_path / "processing",
        output_conversations_dir=tmp_path / "Conversations",
        coach_db_path=tmp_path / "coach.db",
        settings_path=tmp_path / "settings.yaml",
    )


TRANSCRIPT = (
    f"# {SUBJECT}\n"
    "\n"
    "**Contact One** (2026-01-05T09:00:00+00:00):\n"
    "Could you confirm which filing window applies this quarter?\n"
    "\n"
    "**You** (2026-01-05T11:30:00+00:00):\n"
    "Checking now, will confirm before Friday.\n"
)

METADATA = {
    "conversation_id": "2026-01-05_quarterly-filing-question_abcd1234",
    "date": "2026-01-05",
    "source": "email",
    "channel": "email",
    "shape": "correspondence",
    "started_at": "2026-01-05T09:00:00+00:00",
    "ended_at": "2026-01-05T11:30:00+00:00",
    "source_session_id": "thread-root@example.test",
    "source_app": "mail",
    "capture_source": "hr015_email_source",
    "participants": [
        {"id": "user", "display": "Operator", "role": "user",
         "email": USER_ADDRESS},
        {"id": "contact_one", "display": "Contact One", "role": "other",
         "email": CONTACT},
    ],
    "email_thread": {
        "thread_id": "thread-root@example.test",
        "subject": SUBJECT,
        "message_count": 2,
        "first_message_at": "2026-01-05T09:00:00+00:00",
        "last_message_at": "2026-01-05T11:30:00+00:00",
        "message_ids": ["a@example.test", "b@example.test"],
        "in_reply_to_chain": ["a@example.test"],
    },
}


# ---------------------------------------------------------------------------
# Property 1: a bundle with no model call
# ---------------------------------------------------------------------------


def test_seed_writes_four_artefacts_without_any_model_call(tmp_path):
    settings = _settings(tmp_path)
    folder = _seed_module().seed_conversation(
        METADATA["conversation_id"], TRANSCRIPT, dict(METADATA), settings
    )
    assert folder is not None, "seed produced no folder"

    summary = (folder / "summary.md").read_text()
    transcript = (folder / "transcript.md").read_text()
    todos = (folder / "todos.md").read_text()

    # The four-artefact contract: three files plus frontmatter on each.
    for text in (summary, transcript, todos):
        assert text.startswith("---\n"), "artefact has no frontmatter"
        assert f"conversation_id: \"{METADATA['conversation_id']}\"" in text

    # Honest about being provisional, in the frontmatter every consumer
    # reads and not just in prose a renderer might drop.
    assert "enrichment_pending: true" in summary

    # Useful, not filler: it says what the thread IS.
    assert SUBJECT in summary
    assert "Contact One" in summary
    assert "2 messages" in summary
    # And it skims the messages.
    assert "which filing window applies" in summary

    # It does NOT invent commitments. "will confirm before Friday" is
    # exactly the sentence a naive extractor would turn into a todo.
    assert "(none extracted)" in todos

    # The transcript artefact carries the real thread.
    assert "Could you confirm" in transcript


def test_seed_marks_provisional_classification_not_a_judgement(tmp_path):
    settings = _settings(tmp_path)
    folder = _seed_module().seed_conversation(
        METADATA["conversation_id"], TRANSCRIPT, dict(METADATA), settings
    )
    summary = (folder / "summary.md").read_text()
    # A seed must never look like the classifier ran.
    assert "sensitivity_level: \"normal\"" in summary
    assert "enrichment_pending: true" in summary


# ---------------------------------------------------------------------------
# Property 2: a seed never overwrites model output
# ---------------------------------------------------------------------------


def test_seed_refuses_to_overwrite_an_enriched_bundle(tmp_path):
    settings = _settings(tmp_path)
    conv_id = METADATA["conversation_id"]

    # The full pipeline has already run this conversation.
    state_dir = settings.processing_state_dir / conv_id
    state_dir.mkdir(parents=True)
    (state_dir / "state.json").write_text(json.dumps({
        "conversation_id": conv_id,
        "current_step": "09_bundle",
        "completed_steps": ["00_raw", "01_classify", "02_enrich",
                            "09_bundle"],
        "failed_step": None,
    }))

    assert _seed_module().already_enriched(conv_id, settings) is True
    assert _seed_module().seed_conversation(
        conv_id, TRANSCRIPT, dict(METADATA), settings
    ) is None

    # And nothing was written, so a good summary could not have been
    # replaced by a placeholder.
    assert not list(settings.output_conversations_dir.rglob("summary.md"))


def test_already_enriched_is_false_before_the_bundle_step(tmp_path):
    """Control: the guard must not read every state file as enriched."""
    settings = _settings(tmp_path)
    conv_id = METADATA["conversation_id"]
    state_dir = settings.processing_state_dir / conv_id
    state_dir.mkdir(parents=True)
    (state_dir / "state.json").write_text(json.dumps({
        "conversation_id": conv_id,
        "current_step": "02_enrich",
        "completed_steps": ["00_raw", "01_classify", "02_enrich"],
        "failed_step": None,
    }))
    assert _seed_module().already_enriched(conv_id, settings) is False
    assert _seed_module().seed_conversation(
        conv_id, TRANSCRIPT, dict(METADATA), settings
    ) is not None


# ---------------------------------------------------------------------------
# Property 3: the tick seeds first, then enriches
# ---------------------------------------------------------------------------


def _build_thread(mail_dir: Path, *, tag: str, when: datetime) -> None:
    root = f"{tag}-root@example.test"
    _write_emlx(mail_dir, f"{tag}0.emlx", _emlx_bytes(
        message_id=root,
        from_addr=CONTACT, from_name="Contact One",
        to_addr=USER_ADDRESS, subject=f"Synthetic {tag}",
        dt=when, body="Synthetic body text with no real content.",
    ))
    _write_emlx(mail_dir, f"{tag}1.emlx", _emlx_bytes(
        message_id=f"{tag}-r1@example.test",
        from_addr=USER_ADDRESS, from_name="Operator",
        to_addr=CONTACT, subject=f"Re: Synthetic {tag}",
        dt=when + timedelta(hours=1),
        body="Synthetic reply text with no real content.",
        in_reply_to=root, references=[root],
    ))


def test_tick_seeds_every_thread_before_enriching_any(tmp_path):
    mail = tmp_path / "Mail"
    now = datetime.now(timezone.utc)
    _build_thread(mail, tag="alpha", when=now - timedelta(days=3))
    _build_thread(mail, tag="beta", when=now - timedelta(days=1))

    stub = _StubDispatch()
    cmd = stub.make_cmd(tmp_path)
    summary = process_email(
        mail_dir=mail,
        user_display_name="Operator",
        user_address=USER_ADDRESS,
        since_days=30,
        pwg_convo_cmd=cmd,
        state_path=tmp_path / "state.json",
    )

    assert summary["threads_scanned"] == 2
    assert summary["threads_seeded"] == 2
    assert summary["threads_dispatched"] == 2

    order = [r["cmd"] for r in stub.load_all()]
    # Every seed lands before the first enrichment. If enrichment came
    # first the split would buy the customer nothing.
    assert order == ["seed", "seed", "process", "process"], order


def test_tick_enriches_newest_thread_first(tmp_path):
    mail = tmp_path / "Mail"
    now = datetime.now(timezone.utc)
    _build_thread(mail, tag="older", when=now - timedelta(days=20))
    _build_thread(mail, tag="newer", when=now - timedelta(days=1))

    stub = _StubDispatch()
    cmd = stub.make_cmd(tmp_path)
    process_email(
        mail_dir=mail,
        user_display_name="Operator",
        user_address=USER_ADDRESS,
        since_days=60,
        pwg_convo_cmd=cmd,
        state_path=tmp_path / "state.json",
    )

    enriched = [
        r["metadata"]["email_thread"]["subject"]
        for r in stub.load_all() if r["cmd"] == "process"
    ]
    assert enriched[0].endswith("newer"), enriched


def test_seed_pass_can_be_switched_off(tmp_path, monkeypatch):
    """The escape hatch must genuinely restore the old tick."""
    monkeypatch.setenv("OSTLER_SEED_FIRST", "0")
    mail = tmp_path / "Mail"
    _build_thread(mail, tag="gamma", when=datetime.now(timezone.utc))

    stub = _StubDispatch()
    cmd = stub.make_cmd(tmp_path)
    summary = process_email(
        mail_dir=mail,
        user_display_name="Operator",
        user_address=USER_ADDRESS,
        since_days=30,
        pwg_convo_cmd=cmd,
        state_path=tmp_path / "state.json",
    )
    assert summary["threads_seeded"] == 0
    assert [r["cmd"] for r in stub.load_all()] == ["process"]


def test_a_broken_seeder_never_stops_enrichment(tmp_path):
    """A seed is an optimisation. It must not be able to block the
    durable path -- the failure mode that would turn a throughput fix
    into an outage."""
    mail = tmp_path / "Mail"
    _build_thread(mail, tag="delta", when=datetime.now(timezone.utc))

    capture = tmp_path / "capture.jsonl"
    script = tmp_path / "half_broken_pwg_convo.py"
    script.write_text(
        "import json, sys\n"
        "args = sys.argv[1:]\n"
        "if 'seed' in args:\n"
        "    sys.stderr.write('synthetic seeder explosion\\n')\n"
        "    sys.exit(3)\n"
        "ti = args.index('process')\n"
        "rec = {'cmd': 'process',\n"
        "       'metadata': json.load(open(args[ti + 2]))}\n"
        f"open({str(capture)!r}, 'a').write(json.dumps(rec) + '\\n')\n"
    )

    summary = process_email(
        mail_dir=mail,
        user_display_name="Operator",
        user_address=USER_ADDRESS,
        since_days=30,
        pwg_convo_cmd=[sys.executable, str(script)],
        state_path=tmp_path / "state.json",
    )
    assert summary["threads_seeded"] == 0
    assert summary["threads_dispatched"] == 1
    assert summary["threads_failed"] == 0
    assert capture.exists(), "enrichment did not run after the seed failed"


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
