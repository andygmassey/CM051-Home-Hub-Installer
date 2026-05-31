"""Synthetic-fixture tests for the HR015 spoken conversation feed.

Builds synthetic RemoteCapture (CM042) markdown transcripts with
SYNTHETIC data only (no real names / transcripts), then exercises the
reader, the renderer, the metadata builder, the watermark, and the
voice-note path against a STUB pwg-convo. A final test runs the REAL
CM048 ``pwg-convo`` end-to-end (when CM048 is importable) to prove the
four artefacts land and the L3 contract holds (09_bundle runs,
07_sinks_written absent).

Run from the HR015 repo root:
    python -m pytest spoken_source/tests/test_spoken_source.py
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

# Make the repo root importable so ``import spoken_source`` resolves
# when pytest runs from anywhere.
_REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_REPO_ROOT))

from spoken_source import reader, renderer  # noqa: E402
from spoken_source.pipeline import process_spoken  # noqa: E402


# ---------------------------------------------------------------------------
# Synthetic RemoteCapture transcript fixture builder
# ---------------------------------------------------------------------------


def _meeting_transcript(
    *,
    call_id: str,
    timestamp: str,
    duration_seconds: int,
    source: str = "zoom",
    context: str = "meeting",
    privacy_level: str = "L2",
    remote_name: str = "Alex Synthetic",
    remote_person_id: str | None = "alex-synthetic",
) -> str:
    """Build a multi-speaker CM042 transcript exactly as
    ``TranscriptBuilder`` writes it: YAML front matter + ## Transcript
    body with ``**Name** [MM:SS]: text`` lines."""
    fm = [
        "---",
        f"title: {timestamp[:16]}-{source}-call",
        f"call_id: {call_id}",
        f"timestamp: {timestamp}",
        f"duration_seconds: {duration_seconds}",
        f"source: {source}",
        f"context: {context}",
        f"privacy_level: {privacy_level}",
        "language: en",
        "participants:",
        "  - speaker_label: USER",
        "    display_name: You",
        "    confidence: 1.00",
        "  - speaker_label: SPEAKER_01",
    ]
    if remote_person_id:
        fm.append(f"    person_id: {remote_person_id}")
    fm += [
        f"    display_name: {remote_name}",
        "    confidence: 0.91",
        "diarization_method: stream_separation",
        "tags: [project, sync]",
        "---",
        "",
        "## Transcript",
        "",
        f"**{remote_name}** [00:03]: Are we still on for the project sync at two?",
        "**You** [00:09]: Yes. I will book the room and send the invite.",
        f"**{remote_name}** [00:21]: Great, I will send the deck beforehand.",
        "",
    ]
    return "\n".join(fm)


def _voice_note_transcript(
    *,
    call_id: str,
    timestamp: str,
    duration_seconds: int = 18,
) -> str:
    """Build a single-speaker voice-note CM042 transcript.

    A voice note has one participant (the operator) and no diarisation.
    Source ``voice_note`` so ``is_voice_note`` resolves true.
    """
    fm = [
        "---",
        f"title: {timestamp[:16]}-voice_note-call",
        f"call_id: {call_id}",
        f"timestamp: {timestamp}",
        f"duration_seconds: {duration_seconds}",
        "source: voice_note",
        "context: memo",
        "privacy_level: L2",
        "participants:",
        "  - speaker_label: USER",
        "    display_name: You",
        "    confidence: 1.00",
        "diarization_method: manual",
        "---",
        "",
        "## Transcript",
        "",
        "**You** [00:01]: Remember to send the synthetic report on Monday.",
        "",
    ]
    return "\n".join(fm)


def _write_transcript(transcripts_dir: Path, started: datetime, name: str, body: str) -> Path:
    """Drop one transcript into the CM042 YYYY/MM tree."""
    year = f"{started.year:04d}"
    month = f"{started.month:02d}"
    nested = transcripts_dir / year / month
    nested.mkdir(parents=True, exist_ok=True)
    path = nested / f"{name}.md"
    path.write_text(body, encoding="utf-8")
    return path


def _build_fixture_tree(transcripts_dir: Path) -> None:
    """One meeting + one voice note, each in the YYYY/MM tree."""
    base = datetime(2026, 5, 30, 10, 0, tzinfo=timezone.utc)
    _write_transcript(
        transcripts_dir,
        base,
        "2026-05-30-1000-zoom-call",
        _meeting_transcript(
            call_id="session-meeting-001",
            timestamp="2026-05-30T10:00:00Z",
            duration_seconds=1800,
        ),
    )
    _write_transcript(
        transcripts_dir,
        base,
        "2026-05-30-1300-voice_note-call",
        _voice_note_transcript(
            call_id="session-voice-001",
            timestamp="2026-05-30T13:00:00Z",
        ),
    )


# ---------------------------------------------------------------------------
# pwg-convo stub
# ---------------------------------------------------------------------------


class _StubDispatch:
    """Captures everything that would have gone to pwg-convo."""

    def make_cmd(self, tmp_path: Path) -> list[str]:
        capture = tmp_path / "capture.jsonl"
        script = tmp_path / "fake_pwg_convo.py"
        script.write_text(
            "import json, sys\n"
            "args = sys.argv[1:]\n"
            "ti = args.index('process')\n"
            "tpath = args[ti + 1]\n"
            "mpath = args[ti + 2]\n"
            "rec = {\n"
            "  'transcript': open(tpath).read(),\n"
            "  'metadata': json.load(open(mpath)),\n"
            "  'dry_run': '--dry-run' in args,\n"
            "}\n"
            f"open({str(capture)!r}, 'a').write(json.dumps(rec) + '\\n')\n"
        )
        self._capture = capture
        return [sys.executable, str(script)]

    def load(self) -> list[dict]:
        if not self._capture.exists():
            return []
        return [json.loads(line) for line in self._capture.read_text().splitlines()]


# ---------------------------------------------------------------------------
# Reader
# ---------------------------------------------------------------------------


def test_reader_parses_cm042_transcript(tmp_path):
    tdir = tmp_path / "Transcripts"
    _build_fixture_tree(tdir)
    sessions = reader.read_transcripts(transcripts_dir=tdir, since_days=0)
    assert len(sessions) == 2
    by_id = {s.call_id: s for s in sessions}
    meeting = by_id["session-meeting-001"]
    assert meeting.source == "zoom"
    assert meeting.context == "meeting"
    assert meeting.duration_seconds == 1800
    assert meeting.privacy_level == "L2"
    assert meeting.language == "en"
    assert meeting.diarization_method == "stream_separation"
    assert "project" in meeting.tags
    assert len(meeting.utterances) == 3
    # Participants resolved from front matter (USER + remote).
    labels = {p.speaker_label for p in meeting.participants}
    assert "USER" in labels and "SPEAKER_01" in labels
    remote = [p for p in meeting.participants if p.speaker_label == "SPEAKER_01"][0]
    assert remote.display_name == "Alex Synthetic"
    assert remote.person_id == "alex-synthetic"


def test_reader_missing_dir_is_empty(tmp_path):
    missing = tmp_path / "does-not-exist"
    assert reader.read_transcripts(transcripts_dir=missing, since_days=0) == []


def test_reader_fallback_front_matter_without_pyyaml(tmp_path, monkeypatch):
    """The line-parser fallback parses the exact CM042 shape when
    PyYAML is unavailable."""
    tdir = tmp_path / "Transcripts"
    _build_fixture_tree(tdir)

    real_import = __import__

    def _no_yaml(name, *a, **k):
        if name == "yaml":
            raise ImportError("yaml blocked for test")
        return real_import(name, *a, **k)

    monkeypatch.setattr("builtins.__import__", _no_yaml)
    sessions = reader.read_transcripts(transcripts_dir=tdir, since_days=0)
    meeting = [s for s in sessions if s.call_id == "session-meeting-001"][0]
    assert meeting.source == "zoom"
    assert meeting.duration_seconds == 1800
    assert len(meeting.participants) == 2
    assert meeting.tags == ["project", "sync"]


# ---------------------------------------------------------------------------
# Renderer + metadata
# ---------------------------------------------------------------------------


def test_render_and_metadata_shape(tmp_path):
    tdir = tmp_path / "Transcripts"
    _build_fixture_tree(tdir)
    meeting = [
        s for s in reader.read_transcripts(transcripts_dir=tdir, since_days=0)
        if s.call_id == "session-meeting-001"
    ][0]

    transcript = renderer.render_transcript(meeting)
    assert "**Alex Synthetic**" in transcript
    assert "**You**" in transcript
    assert transcript.startswith("# ")

    meta = renderer.build_metadata(meeting, user_display_name="You")
    assert meta["channel"] == "spoken"
    assert meta["source"] == "zoom"
    assert meta["source_app"] == "zoom"
    assert meta["capture_source"] == "cm042_mac"
    assert meta["source_session_id"] == "session-meeting-001"
    assert meta["started_at"] == "2026-05-30T10:00:00Z"
    # ended_at = started + duration.
    assert meta["ended_at"] == "2026-05-30T10:30:00Z"
    # participants: user + remote (person_id carried through).
    roles = [p["role"] for p in meta["participants"]]
    assert "user" in roles and "other" in roles
    other = [p for p in meta["participants"] if p["role"] == "other"][0]
    assert other["person_id"] == "alex-synthetic"
    # L2 front matter default does NOT pin privacy_level (left to CM048).
    assert "privacy_level" not in meta


def test_voice_note_rides_same_path(tmp_path):
    tdir = tmp_path / "Transcripts"
    _build_fixture_tree(tdir)
    voice = [
        s for s in reader.read_transcripts(transcripts_dir=tdir, since_days=0)
        if s.call_id == "session-voice-001"
    ][0]
    assert voice.is_voice_note is True
    meta = renderer.build_metadata(voice, user_display_name="You")
    # Same channel, no separate plumbing.
    assert meta["channel"] == "spoken"
    assert meta["is_voice_note"] is True
    assert meta["source"] == "voice_note"
    # Single participant: just the user (no remote speaker labelled).
    others = [p for p in meta["participants"] if p["role"] == "other"]
    assert others == []
    users = [p for p in meta["participants"] if p["role"] == "user"]
    assert len(users) == 1


def test_l3_front_matter_rides_through(tmp_path):
    tdir = tmp_path / "Transcripts"
    base = datetime(2026, 5, 30, 9, 0, tzinfo=timezone.utc)
    _write_transcript(
        tdir,
        base,
        "2026-05-30-0900-zoom-call",
        _meeting_transcript(
            call_id="session-private-001",
            timestamp="2026-05-30T09:00:00Z",
            duration_seconds=600,
            privacy_level="L3",
        ),
    )
    session = reader.read_transcripts(transcripts_dir=tdir, since_days=0)[0]
    assert session.privacy_level == "L3"
    meta = renderer.build_metadata(session, user_display_name="You")
    assert meta["privacy_level"] == "L3"


def test_operator_privacy_map_pins_l3(tmp_path):
    """A source pinned L3 in the operator contacts.yaml rides through."""
    tdir = tmp_path / "Transcripts"
    _build_fixture_tree(tdir)
    contacts = tmp_path / "contacts.yaml"
    contacts.write_text(
        "spoken:\n  sources:\n    zoom: L3\n", encoding="utf-8"
    )
    stub = _StubDispatch()
    cmd = stub.make_cmd(tmp_path)
    state = tmp_path / "state.json"
    process_spoken(
        transcripts_dir=tdir,
        contacts_path=contacts,
        pwg_convo_cmd=cmd,
        state_path=state,
        since_days=0,
    )
    records = stub.load()
    meeting = [r for r in records if r["metadata"]["source"] == "zoom"][0]
    assert meeting["metadata"]["privacy_level"] == "L3"


# ---------------------------------------------------------------------------
# Pipeline dispatch + watermark
# ---------------------------------------------------------------------------


def test_pipeline_dispatches_then_watermark_skips(tmp_path):
    tdir = tmp_path / "Transcripts"
    _build_fixture_tree(tdir)
    stub = _StubDispatch()
    cmd = stub.make_cmd(tmp_path)
    state = tmp_path / "state.json"

    first = process_spoken(
        transcripts_dir=tdir,
        pwg_convo_cmd=cmd,
        state_path=state,
        since_days=0,
    )
    assert first["sessions_scanned"] == 2
    assert first["sessions_dispatched"] == 2
    assert first["sessions_skipped"] == 0
    assert first["sessions_failed"] == 0

    records = stub.load()
    assert len(records) == 2
    channels = {r["metadata"]["channel"] for r in records}
    assert channels == {"spoken"}

    # Second tick: watermark skips both already-bundled sessions.
    second = process_spoken(
        transcripts_dir=tdir,
        pwg_convo_cmd=cmd,
        state_path=state,
        since_days=0,
    )
    assert second["sessions_scanned"] == 2
    assert second["sessions_dispatched"] == 0
    assert second["sessions_skipped"] == 2
    # No new dispatch recorded.
    assert len(stub.load()) == 2


def test_pipeline_failure_does_not_advance_watermark(tmp_path):
    tdir = tmp_path / "Transcripts"
    _build_fixture_tree(tdir)
    # A command that always fails (rc=1).
    failing = [sys.executable, "-c", "import sys; sys.exit(1)"]
    state = tmp_path / "state.json"
    summary = process_spoken(
        transcripts_dir=tdir,
        pwg_convo_cmd=failing,
        state_path=state,
        since_days=0,
    )
    assert summary["sessions_failed"] == 2
    assert summary["sessions_dispatched"] == 0
    # Watermark file written but empty so the next tick retries.
    saved = json.loads(state.read_text())
    assert saved["call_ids"] == []


# ---------------------------------------------------------------------------
# Real CM048 end-to-end (skipped if CM048's src is not importable)
# ---------------------------------------------------------------------------
#
# Drives CM048's own ``processor.process()`` in-process, in the exact
# offline mode CM048's own bundle test uses (dry_run=True,
# ingest_sinks=True): heuristic classification, no Ollama, no live
# Qdrant / Oxigraph, but step 09 lands the real four-artefact bundle on
# disk. The transcript + metadata fed in are produced by THIS feed's
# renderer, so the test proves the spoken feed's output flows through
# CM048 and lands the four artefacts, and that an L3 capture skips the
# gist sinks (steps 07 / 08) while step 09 still runs.

# Opt-in CM048 e2e arm: point OSTLER_CM048_ROOT at a local CM048 checkout to
# exercise the real writer. Defaults to a non-PII placeholder so no developer
# home path ships in the source (operator-pii-scan clean); the arm simply
# skips when the path does not resolve.
_CM048_ROOT = Path(
    os.environ.get(
        "OSTLER_CM048_ROOT",
        str(Path.home() / "Projects" / "cm048-conversation-processing"),
    )
)


def _import_cm048():
    """Import CM048's process() + Settings, or return None if absent."""
    if not (_CM048_ROOT / "src" / "cli.py").exists():
        return None
    sys.path.insert(0, str(_CM048_ROOT))
    try:
        from src.processor import process  # type: ignore
        from src.settings import Settings, ensure_directories  # type: ignore
    except Exception:
        return None
    return process, Settings, ensure_directories


def _run_through_cm048(transcript_md, metadata, tmp_path, *, label):
    imported = _import_cm048()
    if imported is None:
        pytest.skip("CM048 src not importable in this environment")
    process, Settings, ensure_directories = imported
    settings = Settings(
        user_id="test-user",
        user_display_name="Test User",
        processing_state_dir=tmp_path / f"{label}_state",
        output_conversations_dir=tmp_path / f"{label}_Conversations",
        coach_db_path=tmp_path / f"{label}_coach" / "observations.db",
    )
    ensure_directories(settings)
    conv_id = metadata["conversation_id"]
    state = process(
        conv_id,
        transcript_md,
        metadata,
        settings,
        dry_run=True,        # heuristic classification, no Ollama
        ingest_sinks=True,   # so step 09 lands the on-disk bundle
    )
    return state, settings, conv_id


def _import_cm048_writer():
    """Import CM048's make_bundle + write_conversation, or None.

    This path is NETWORK-FREE: ``write_conversation`` with
    ``gist_post_fn=None`` writes the four artefacts on disk and never
    touches Ollama / Qdrant / Oxigraph (the gist arm is the callback,
    which is the sink side). It is the deterministic proof that THIS
    feed's metadata -> CM048 spoken adapter -> writer lands all four
    artefacts, independent of whether the local sink services are up.
    """
    if not (_CM048_ROOT / "src" / "cli.py").exists():
        return None
    sys.path.insert(0, str(_CM048_ROOT))
    try:
        from src.channel_adapter import make_bundle  # type: ignore
        from src.conversation_writer import write_conversation  # type: ignore
        from src.bundle_extractor import BundleExtraction  # type: ignore
        from src.schemas import Classification, Sensitivity  # type: ignore
    except Exception:
        return None
    return make_bundle, write_conversation, BundleExtraction, Classification, Sensitivity


def _stub_classification(Classification, Sensitivity):
    return Classification(
        setting="work",
        shape="meeting",
        stakes="medium",
        confidence=0.9,
        reasoning="fixture",
        sensitivity=Sensitivity(level="normal", categories=[], reasoning=""),
    )


def _stub_extraction(BundleExtraction):
    return BundleExtraction(
        overall_summary="A synthetic project sync.",
        topics=[
            {"name": "Scheduling", "points": ["Confirmed the 2pm sync."]}
        ],
        todos=[
            {
                "text": "Book the room and send the invite.",
                "owner": "user",
                "deadline": None,
                "source_anchor": None,
            }
        ],
    )


def _build_bundle_via_adapter(metadata, transcript_md, tmp_path, *, label):
    imported = _import_cm048_writer()
    if imported is None:
        pytest.skip("CM048 src not importable in this environment")
    (
        make_bundle,
        write_conversation,
        BundleExtraction,
        Classification,
        Sensitivity,
    ) = imported
    classification = _stub_classification(Classification, Sensitivity)
    extraction = _stub_extraction(BundleExtraction)
    bundle = make_bundle(
        metadata=metadata,
        classification=classification,
        extraction=extraction,
        transcript=transcript_md,
        privacy_level=metadata.get("privacy_level"),
    )
    root = tmp_path / f"{label}_Conversations"
    output = write_conversation(
        bundle,
        root=root,
        gist_post_fn=None,   # network-free; gist arm not invoked
        reminders_db_path=tmp_path / f"{label}_reminders.db",
    )
    return bundle, output, root


def test_end_to_end_four_artefacts_land(tmp_path):
    """A normal (L2) spoken meeting from THIS feed lands the four
    artefacts (summary.md + transcript.md + todos.md, each with
    frontmatter = the 4th artefact, metadata) under
    Conversations/<date>/<slug>-<short-id>/.

    Network-free: drives CM048's spoken adapter + writer directly so
    the proof holds even when the local sink services are down (which
    is the case on this dev box -- the full ``process()`` non-L3 path
    blocks on a socket connecting to Qdrant / Ollama; see the
    spoken-source build report's audit note)."""
    tdir = tmp_path / "Transcripts"
    base = datetime(2026, 5, 30, 10, 0, tzinfo=timezone.utc)
    _write_transcript(
        tdir, base, "normal",
        _meeting_transcript(
            call_id="e2e-normal-001",
            timestamp="2026-05-30T10:00:00Z",
            duration_seconds=900,
        ),
    )
    session = reader.read_transcripts(transcripts_dir=tdir, since_days=0)[0]
    transcript_md = renderer.render_transcript(session)
    metadata = renderer.build_metadata(session, user_display_name="You")
    # No privacy_level set by the feed for an L2 meeting.
    assert "privacy_level" not in metadata

    bundle, output, root = _build_bundle_via_adapter(
        metadata, transcript_md, tmp_path, label="normal"
    )
    assert bundle.channel == "spoken"
    assert bundle.source_kind == "spoken"

    bundles = sorted(root.rglob("summary.md"))
    assert len(bundles) == 1, [str(b) for b in bundles]
    folder = bundles[0].parent
    artefacts = sorted(p.name for p in folder.iterdir())
    assert artefacts == ["summary.md", "todos.md", "transcript.md"]
    for name in artefacts:
        text = (folder / name).read_text(encoding="utf-8")
        # Frontmatter (the 4th artefact: metadata) on every file.
        assert text.startswith("---\n"), name
        assert 'channel: "spoken"' in text, name
    # The extracted todo rendered into todos.md.
    assert "Book the room" in (folder / "todos.md").read_text()


def test_end_to_end_l3_skips_sinks_keeps_bundle(tmp_path):
    """An L3-marked spoken capture (recorder marked the meeting
    private) lands the four-artefact bundle (step 09_bundle ran) but
    skips the gist sinks: 07_sinks_written + 08_linked absent."""
    tdir = tmp_path / "Transcripts"
    base = datetime(2026, 5, 30, 14, 0, tzinfo=timezone.utc)
    _write_transcript(
        tdir, base, "private",
        _meeting_transcript(
            call_id="e2e-private-001",
            timestamp="2026-05-30T14:00:00Z",
            duration_seconds=600,
            privacy_level="L3",
            remote_name="Sam Synthetic",
            remote_person_id="sam-synthetic",
        ),
    )
    session = reader.read_transcripts(transcripts_dir=tdir, since_days=0)[0]
    assert session.privacy_level == "L3"
    transcript_md = renderer.render_transcript(session)
    metadata = renderer.build_metadata(session, user_display_name="You")
    assert metadata["privacy_level"] == "L3"  # rode through the feed

    state, settings, conv_id = _run_through_cm048(
        transcript_md, metadata, tmp_path, label="private"
    )

    # Episodic bundle still landed.
    assert "09_bundle" in state.completed_steps, state.completed_steps
    output_root = settings.output_conversations_dir
    bundles = sorted(output_root.rglob("summary.md"))
    assert len(bundles) == 1, [str(b) for b in bundles]
    summary_text = bundles[0].read_text(encoding="utf-8")
    assert "privacy_level: L3" in summary_text

    # Gist sinks short-circuited.
    assert "07_sinks_written" not in state.completed_steps, state.completed_steps
    assert "08_linked" not in state.completed_steps, state.completed_steps


def test_end_to_end_l3_writer_skips_gist_arm(tmp_path):
    """Network-free L3 proof at the writer seam: an L3 spoken capture
    still lands the four-artefact bundle, but the gist callback is
    never invoked (gist_status='skipped-l3'). Complements the
    process()-level step-contract test above without depending on the
    pipeline being able to reach a stubbed sink."""
    tdir = tmp_path / "Transcripts"
    base = datetime(2026, 5, 30, 9, 0, tzinfo=timezone.utc)
    _write_transcript(
        tdir, base, "private",
        _meeting_transcript(
            call_id="e2e-l3-writer-001",
            timestamp="2026-05-30T09:00:00Z",
            duration_seconds=600,
            privacy_level="L3",
        ),
    )
    session = reader.read_transcripts(transcripts_dir=tdir, since_days=0)[0]
    transcript_md = renderer.render_transcript(session)
    metadata = renderer.build_metadata(session, user_display_name="You")
    assert metadata["privacy_level"] == "L3"

    # A gist callback that records if it was ever called.
    called = {"n": 0}

    imported = _import_cm048_writer()
    if imported is None:
        pytest.skip("CM048 src not importable in this environment")
    (
        make_bundle,
        write_conversation,
        BundleExtraction,
        Classification,
        Sensitivity,
    ) = imported
    bundle = make_bundle(
        metadata=metadata,
        classification=_stub_classification(Classification, Sensitivity),
        extraction=_stub_extraction(BundleExtraction),
        transcript=transcript_md,
        privacy_level="L3",
    )
    assert bundle.privacy_level == "L3"

    def _gist(_bundle, _output):
        called["n"] += 1
        return {"status": "ok"}

    root = tmp_path / "l3w_Conversations"
    output = write_conversation(
        bundle,
        root=root,
        gist_post_fn=_gist,   # provided, but must NOT fire for L3
        reminders_db_path=tmp_path / "l3w_reminders.db",
    )

    # Four artefacts still on disk.
    bundles = sorted(root.rglob("summary.md"))
    assert len(bundles) == 1
    folder = bundles[0].parent
    assert sorted(p.name for p in folder.iterdir()) == [
        "summary.md", "todos.md", "transcript.md"
    ]
    assert "privacy_level: L3" in (folder / "summary.md").read_text()
    # The gist arm (Qdrant / Oxigraph) was never invoked.
    assert called["n"] == 0, "gist callback fired for an L3 capture"
    assert output.gist_status in ("skipped-l3", "skipped", "not-attempted"), (
        output.gist_status
    )
