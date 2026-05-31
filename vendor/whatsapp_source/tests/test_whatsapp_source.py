"""Synthetic-fixture tests for the HR015 WhatsApp conversation feed.

Builds a synthetic ChatStorage-shaped sqlite (SYNTHETIC data only: no
real names / numbers / messages), then exercises the body reader, the
renderer, the metadata builder, the watermark, the tier gate, and the
privacy ladder against a STUB pwg-convo. A final block runs the REAL
CM048 ``pwg-convo`` path (when CM048 is importable) to prove the four
artefacts land for a T1 + T2 chat and that an L3-labelled chat writes
the bundle but skips the gist sinks.

Run from the HR015 repo root:
    python -m pytest whatsapp_source/tests/test_whatsapp_source.py
"""
from __future__ import annotations

import json
import os
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

# Make the repo root importable so ``import whatsapp_source`` +
# ``import ostler_fda`` resolve when pytest runs from anywhere.
_REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_REPO_ROOT))

from ostler_fda import whatsapp_history as wh  # noqa: E402
from whatsapp_source import reader, renderer  # noqa: E402
from whatsapp_source.pipeline import process_whatsapp  # noqa: E402


# ---------------------------------------------------------------------------
# Synthetic ChatStorage fixture builder
# ---------------------------------------------------------------------------

_NOW = datetime(2026, 5, 30, 12, 0, tzinfo=timezone.utc)


def _mac_ts(dt: datetime) -> float:
    """UTC datetime -> WhatsApp Mac-epoch REAL."""
    return dt.timestamp() - wh.MAC_EPOCH_OFFSET


def _build_chatstorage(db_path: Path) -> None:
    """Create a synthetic ChatStorage.sqlite with:

      - chat 1: T1 DM (partner 111) with three text rows + one media row
        (media row's ZTEXT NULL, must be skipped).
      - chat 2: T2 intimate group (2 members, < 10) with two text rows.
      - chat 3: T3 large-passive group (12 members, no user engagement)
        with text rows that must NEVER be read.

    All SYNTHETIC: numeric JIDs, generic text.
    """
    conn = sqlite3.connect(str(db_path))
    conn.executescript(
        """
        CREATE TABLE ZWACHATSESSION (
            Z_PK INTEGER PRIMARY KEY,
            ZGROUPINFO INTEGER,
            ZCONTACTJID TEXT,
            ZLASTMESSAGEDATE REAL
        );
        CREATE TABLE ZWAMESSAGE (
            Z_PK INTEGER PRIMARY KEY,
            ZCHATSESSION INTEGER,
            ZISFROMME INTEGER,
            ZMESSAGEDATE REAL,
            ZFROMJID TEXT,
            ZTEXT TEXT,
            ZMESSAGETYPE INTEGER
        );
        CREATE TABLE ZWAGROUPMEMBER (
            Z_PK INTEGER PRIMARY KEY,
            ZCHATSESSION INTEGER,
            ZMEMBERJID TEXT,
            ZISACTIVE INTEGER
        );
        CREATE TABLE ZWAGROUPINFO (
            Z_PK INTEGER PRIMARY KEY,
            ZSUBJECT TEXT
        );
        """
    )

    base = _NOW - timedelta(days=2)
    last = _mac_ts(_NOW - timedelta(hours=1))

    # --- chat 1: T1 DM (ZGROUPINFO NULL) ---
    conn.execute(
        "INSERT INTO ZWACHATSESSION VALUES (1, NULL, '111@s.whatsapp.net', ?)",
        (last,),
    )
    conn.executemany(
        "INSERT INTO ZWAMESSAGE "
        "(Z_PK, ZCHATSESSION, ZISFROMME, ZMESSAGEDATE, ZFROMJID, ZTEXT, ZMESSAGETYPE) "
        "VALUES (?,?,?,?,?,?,?)",
        [
            (1, 1, 0, _mac_ts(base), "111@s.whatsapp.net",
             "Are we still on for Saturday?", 0),
            (2, 1, 1, _mac_ts(base + timedelta(minutes=5)), None,
             "Yes, see you at noon.", 0),
            (3, 1, 0, _mac_ts(base + timedelta(minutes=10)), "111@s.whatsapp.net",
             "Great, bringing the synthetic cake.", 0),
            # media row: NULL ZTEXT, non-text type -- must be skipped.
            (4, 1, 0, _mac_ts(base + timedelta(minutes=12)), "111@s.whatsapp.net",
             None, 1),
        ],
    )

    # --- chat 2: T2 intimate group (ZGROUPINFO set, 2 active members) ---
    conn.execute("INSERT INTO ZWAGROUPINFO VALUES (10, 'Synthetic Family')")
    conn.execute(
        "INSERT INTO ZWACHATSESSION VALUES (2, 10, '42@g.us', ?)", (last,)
    )
    conn.executemany(
        "INSERT INTO ZWAGROUPMEMBER (Z_PK, ZCHATSESSION, ZMEMBERJID, ZISACTIVE) "
        "VALUES (?,?,?,?)",
        [
            (1, 2, "222@s.whatsapp.net", 1),
            (2, 2, "333@s.whatsapp.net", 1),
        ],
    )
    conn.executemany(
        "INSERT INTO ZWAMESSAGE "
        "(Z_PK, ZCHATSESSION, ZISFROMME, ZMESSAGEDATE, ZFROMJID, ZTEXT, ZMESSAGETYPE) "
        "VALUES (?,?,?,?,?,?,?)",
        [
            (10, 2, 0, _mac_ts(base + timedelta(minutes=1)), "222@s.whatsapp.net",
             "Dinner at the usual place?", 0),
            (11, 2, 1, _mac_ts(base + timedelta(minutes=3)), None,
             "I am in. Booking now.", 0),
        ],
    )

    # --- chat 3: T3 large-passive group (12 members, no user engagement) ---
    conn.execute("INSERT INTO ZWAGROUPINFO VALUES (20, 'Synthetic Big Group')")
    conn.execute(
        "INSERT INTO ZWACHATSESSION VALUES (3, 20, '99@g.us', ?)", (last,)
    )
    conn.executemany(
        "INSERT INTO ZWAGROUPMEMBER (Z_PK, ZCHATSESSION, ZMEMBERJID, ZISACTIVE) "
        "VALUES (?,?,?,?)",
        [
            (100 + i, 3, f"5{i:02d}@s.whatsapp.net", 1) for i in range(12)
        ],
    )
    # Text rows the feed must NEVER read for a T3 chat. The string is a
    # sentinel: any leak into a transcript / dispatch makes the gate test
    # fail loudly.
    conn.executemany(
        "INSERT INTO ZWAMESSAGE "
        "(Z_PK, ZCHATSESSION, ZISFROMME, ZMESSAGEDATE, ZFROMJID, ZTEXT, ZMESSAGETYPE) "
        "VALUES (?,?,?,?,?,?,?)",
        [
            (200, 3, 0, _mac_ts(base + timedelta(minutes=2)), "500@s.whatsapp.net",
             "T3_SENTINEL_MUST_NOT_LEAK", 0),
            (201, 3, 0, _mac_ts(base + timedelta(minutes=4)), "501@s.whatsapp.net",
             "T3_SENTINEL_MUST_NOT_LEAK_2", 0),
        ],
    )

    conn.commit()
    conn.close()


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


@pytest.fixture()
def chatdb(tmp_path):
    db = tmp_path / "ChatStorage.sqlite"
    _build_chatstorage(db)
    return db


# ---------------------------------------------------------------------------
# Reader: ZTEXT bodies, media skip, tier gate
# ---------------------------------------------------------------------------


def test_reader_pulls_bodies_for_t1_and_t2(chatdb):
    convs = reader.read_chats(db_path=chatdb, since_days=0, now_utc=_NOW)
    by_id = {c.chat_id: c for c in convs}
    # chat 1 (DM) + chat 2 (intimate group) only; chat 3 (T3) absent.
    assert set(by_id) == {"1", "2"}

    dm = by_id["1"]
    assert dm.tier == wh.TIER_T1_DM
    assert dm.is_group is False
    # Three text rows; the media row (ZTEXT NULL, type 1) was skipped.
    assert len(dm.utterances) == 3
    assert [u.text for u in dm.utterances] == [
        "Are we still on for Saturday?",
        "Yes, see you at noon.",
        "Great, bringing the synthetic cake.",
    ]
    # Operator row: ZFROMJID NULL in the DB -> is_from_me True.
    assert dm.utterances[1].is_from_me is True
    assert dm.utterances[1].author_jid is None
    # Partner rows carry the author JID + is_from_me False.
    assert dm.utterances[0].is_from_me is False
    assert dm.utterances[0].author_jid == "111@s.whatsapp.net"

    grp = by_id["2"]
    assert grp.tier == wh.TIER_T2_INTIMATE
    assert grp.is_group is True
    assert grp.group_subject == "Synthetic Family"
    assert len(grp.utterances) == 2


def test_reader_never_reads_t3_bodies(chatdb):
    """The T3 large-passive chat is skipped at read time: not a single
    body is pulled, so the sentinel text can never leak anywhere."""
    convs = reader.read_chats(db_path=chatdb, since_days=0, now_utc=_NOW)
    assert all(c.chat_id != "3" for c in convs)
    for c in convs:
        for u in c.utterances:
            assert "SENTINEL" not in u.text


def test_reader_missing_db_raises_filenotfound(tmp_path):
    with pytest.raises(FileNotFoundError):
        reader.read_chats(db_path=tmp_path / "nope.sqlite")


def test_reader_open_is_readonly(chatdb):
    """The reader uses ostler_fda's read-only open; a write is rejected,
    proving body extraction can never mutate the customer's store."""
    conn = wh._open_readonly(chatdb)
    with pytest.raises(sqlite3.OperationalError):
        conn.execute("INSERT INTO ZWAMESSAGE (Z_PK) VALUES (999)")
    conn.close()


def test_since_days_window_clamps_bodies(chatdb):
    """A tight window drops messages older than the clamp."""
    # All fixture messages are ~2 days old; a 1-day window drops them
    # (the session last-message is recent, but the bodies are older).
    convs = reader.read_chats(db_path=chatdb, since_days=1, now_utc=_NOW)
    # Bodies older than 1 day -> no in-window utterances -> chat dropped.
    assert convs == []
    # A 3-day window keeps them.
    convs = reader.read_chats(db_path=chatdb, since_days=3, now_utc=_NOW)
    assert {c.chat_id for c in convs} == {"1", "2"}


# ---------------------------------------------------------------------------
# Renderer + metadata
# ---------------------------------------------------------------------------


def _names(mapping):
    return lambda jid: mapping.get((jid or "").lower())


def test_render_and_metadata_shape_dm(chatdb):
    convs = reader.read_chats(db_path=chatdb, since_days=0, now_utc=_NOW)
    dm = [c for c in convs if c.chat_id == "1"][0]
    name_for = _names({"111@s.whatsapp.net": "Alex Synthetic"})

    transcript = renderer.render_transcript(
        dm, name_for_jid=name_for, user_display_name="You"
    )
    assert transcript.startswith("# Alex Synthetic")
    assert "**You**" in transcript
    assert "**Alex Synthetic**" in transcript
    assert "Are we still on for Saturday?" in transcript

    meta = renderer.build_metadata(dm, name_for_jid=name_for)
    assert meta["channel"] == "whatsapp"
    assert meta["source"] == "whatsapp"
    assert meta["source_app"] == "whatsapp"
    assert meta["chat_type"] == "private"
    assert meta["is_group_chat"] is False
    assert meta["chat_jid"] == "111@s.whatsapp.net"
    assert meta["source_session_id"] == "1"
    assert meta["contact_source_tier"] == wh.TIER_T1_DM
    roles = [p["role"] for p in meta["participants"]]
    assert "user" in roles and "other" in roles
    other = [p for p in meta["participants"] if p["role"] == "other"][0]
    assert other["display"] == "Alex Synthetic"
    # No privacy_level pinned by default (left to CM048's ladder).
    assert "privacy_level" not in meta


def test_render_falls_back_to_number_when_no_name(chatdb):
    convs = reader.read_chats(db_path=chatdb, since_days=0, now_utc=_NOW)
    dm = [c for c in convs if c.chat_id == "1"][0]
    transcript = renderer.render_transcript(
        dm, name_for_jid=lambda jid: None, user_display_name="You"
    )
    # Bare number local part, never the raw @s.whatsapp.net suffix.
    assert "**111**" in transcript
    assert "@s.whatsapp.net" not in transcript


def test_metadata_group_carries_subject(chatdb):
    convs = reader.read_chats(db_path=chatdb, since_days=0, now_utc=_NOW)
    grp = [c for c in convs if c.chat_id == "2"][0]
    meta = renderer.build_metadata(grp, name_for_jid=lambda jid: None)
    assert meta["chat_type"] == "group"
    assert meta["is_group_chat"] is True
    assert meta["group_subject"] == "Synthetic Family"
    assert meta["chat_jid"] == "group:2"


def test_metadata_contact_label_rides_through(chatdb):
    convs = reader.read_chats(db_path=chatdb, since_days=0, now_utc=_NOW)
    dm = [c for c in convs if c.chat_id == "1"][0]
    meta = renderer.build_metadata(
        dm, name_for_jid=lambda jid: None, contact_label="Partner"
    )
    # The label rides through; CM048's ladder turns "Partner" into L3.
    assert meta["contact_label"] == "Partner"


# ---------------------------------------------------------------------------
# Pipeline dispatch + watermark + privacy map
# ---------------------------------------------------------------------------


def test_pipeline_dispatches_t1_t2_skips_t3_then_watermark(chatdb, tmp_path):
    stub = _StubDispatch()
    cmd = stub.make_cmd(tmp_path)
    state = tmp_path / "state.json"

    first = process_whatsapp(
        db_path=chatdb,
        pwg_convo_cmd=cmd,
        state_path=state,
        since_days=0,
        now_utc=_NOW,
    )
    assert first["chats_scanned"] == 2  # T1 + T2; T3 never scanned
    assert first["chats_dispatched"] == 2
    assert first["chats_skipped"] == 0
    assert first["chats_failed"] == 0

    records = stub.load()
    assert len(records) == 2
    channels = {r["metadata"]["channel"] for r in records}
    assert channels == {"whatsapp"}
    # The T3 sentinel never reached a dispatch.
    for r in records:
        assert "SENTINEL" not in r["transcript"]

    # Second tick: watermark skips both already-bundled chats.
    second = process_whatsapp(
        db_path=chatdb,
        pwg_convo_cmd=cmd,
        state_path=state,
        since_days=0,
        now_utc=_NOW,
    )
    assert second["chats_dispatched"] == 0
    assert second["chats_skipped"] == 2
    assert len(stub.load()) == 2


def test_pipeline_failure_does_not_advance_watermark(chatdb, tmp_path):
    failing = [sys.executable, "-c", "import sys; sys.exit(1)"]
    state = tmp_path / "state.json"
    summary = process_whatsapp(
        db_path=chatdb,
        pwg_convo_cmd=failing,
        state_path=state,
        since_days=0,
        now_utc=_NOW,
    )
    assert summary["chats_failed"] == 2
    assert summary["chats_dispatched"] == 0
    saved = json.loads(state.read_text())
    assert saved["chats"] == {}


def test_pipeline_no_app_is_graceful(tmp_path):
    """A missing ChatStorage.sqlite (WhatsApp Desktop never run) does not
    raise out of process_whatsapp -- the reader's FileNotFoundError is
    surfaced and the run() entry maps it to a clean no_app exit."""
    from whatsapp_source.pipeline import run

    rc = run(["--db-path", str(tmp_path / "missing.sqlite"), "--since-days", "0"])
    assert rc == 0


def test_operator_privacy_map_pins_l3(chatdb, tmp_path):
    """A DM partner pinned L3 in the operator contacts.yaml rides through
    metadata['privacy_level']."""
    pytest.importorskip("yaml")
    contacts = tmp_path / "contacts.yaml"
    contacts.write_text(
        "whatsapp:\n"
        "  contacts:\n"
        '    "111@s.whatsapp.net":\n'
        "      name: Alex Synthetic\n"
        "      privacy_level: L3\n",
        encoding="utf-8",
    )
    stub = _StubDispatch()
    cmd = stub.make_cmd(tmp_path)
    state = tmp_path / "state.json"
    process_whatsapp(
        db_path=chatdb,
        contacts_path=contacts,
        pwg_convo_cmd=cmd,
        state_path=state,
        since_days=0,
        now_utc=_NOW,
    )
    records = stub.load()
    dm = [r for r in records if r["metadata"]["chat_type"] == "private"][0]
    assert dm["metadata"]["privacy_level"] == "L3"
    # The resolved name also rode through from the contacts map.
    assert "Alex Synthetic" in dm["transcript"]


def test_operator_contact_label_family_rides_through(chatdb, tmp_path):
    """A family/partner contact_label rides through so CM048's ladder
    escalates the thread to L3."""
    pytest.importorskip("yaml")
    contacts = tmp_path / "contacts.yaml"
    contacts.write_text(
        "whatsapp:\n"
        "  contacts:\n"
        '    "111@s.whatsapp.net":\n'
        "      contact_label: Family\n",
        encoding="utf-8",
    )
    stub = _StubDispatch()
    cmd = stub.make_cmd(tmp_path)
    state = tmp_path / "state.json"
    process_whatsapp(
        db_path=chatdb,
        contacts_path=contacts,
        pwg_convo_cmd=cmd,
        state_path=state,
        since_days=0,
        now_utc=_NOW,
    )
    dm = [r for r in stub.load() if r["metadata"]["chat_type"] == "private"][0]
    assert dm["metadata"]["contact_label"] == "Family"


# ---------------------------------------------------------------------------
# Real CM048 end-to-end (skipped if CM048's src is not importable)
# ---------------------------------------------------------------------------
#
# Network-free: drives CM048's WhatsApp adapter + writer directly so the
# proof holds even when the local sink services are down. Proves THIS
# feed's metadata -> CM048 whatsapp adapter -> writer lands all four
# artefacts, and that an L3 chat skips the gist arm while still landing
# the bundle on disk.

# Opt-in real-CM048 end-to-end. Point OSTLER_CM048_ROOT at a CM048 checkout
# to exercise the live writer; absent (the default), the e2e arm skips. Kept
# free of any operator-specific absolute path so this vendored test ships
# clean (Rule 4: env-var-driven placeholders, never a real home dir).
_CM048_ROOT = Path(
    os.environ.get("OSTLER_CM048_ROOT", "/nonexistent/cm048-conversation-processing")
).expanduser()


def _import_cm048_writer():
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
    return (
        make_bundle, write_conversation, BundleExtraction,
        Classification, Sensitivity,
    )


def _stub_classification(Classification, Sensitivity):
    return Classification(
        setting="personal",
        shape="chat",
        stakes="low",
        confidence=0.9,
        reasoning="fixture",
        sensitivity=Sensitivity(level="normal", categories=[], reasoning=""),
    )


def _stub_extraction(BundleExtraction):
    return BundleExtraction(
        overall_summary="A synthetic WhatsApp catch-up.",
        topics=[{"name": "Plans", "points": ["Confirmed Saturday at noon."]}],
        todos=[
            {
                "text": "Bring the synthetic cake.",
                "owner": "user",
                "deadline": None,
                "source_anchor": None,
            }
        ],
    )


def _build_bundle_via_adapter(metadata, transcript_md, tmp_path, *, label, gist=None):
    imported = _import_cm048_writer()
    if imported is None:
        pytest.skip("CM048 src not importable in this environment")
    (
        make_bundle, write_conversation, BundleExtraction,
        Classification, Sensitivity,
    ) = imported
    bundle = make_bundle(
        metadata=metadata,
        classification=_stub_classification(Classification, Sensitivity),
        extraction=_stub_extraction(BundleExtraction),
        transcript=transcript_md,
        privacy_level=metadata.get("privacy_level"),
    )
    root = tmp_path / f"{label}_Conversations"
    output = write_conversation(
        bundle,
        root=root,
        gist_post_fn=gist,
        reminders_db_path=tmp_path / f"{label}_reminders.db",
    )
    return bundle, output, root


def test_end_to_end_four_artefacts_land_dm(chatdb, tmp_path):
    convs = reader.read_chats(db_path=chatdb, since_days=0, now_utc=_NOW)
    dm = [c for c in convs if c.chat_id == "1"][0]
    name_for = _names({"111@s.whatsapp.net": "Alex Synthetic"})
    transcript_md = renderer.render_transcript(dm, name_for_jid=name_for)
    metadata = renderer.build_metadata(dm, name_for_jid=name_for)
    assert "privacy_level" not in metadata  # L2 default left to CM048

    bundle, output, root = _build_bundle_via_adapter(
        metadata, transcript_md, tmp_path, label="dm"
    )
    assert bundle.channel == "whatsapp"
    assert bundle.source_kind == "channel"

    bundles = sorted(root.rglob("summary.md"))
    assert len(bundles) == 1, [str(b) for b in bundles]
    folder = bundles[0].parent
    artefacts = sorted(p.name for p in folder.iterdir())
    assert artefacts == ["summary.md", "todos.md", "transcript.md"]
    for name in artefacts:
        text = (folder / name).read_text(encoding="utf-8")
        # Frontmatter (the 4th artefact: metadata) on every file.
        assert text.startswith("---\n"), name
        assert 'channel: "whatsapp"' in text, name
    assert "Bring the synthetic cake" in (folder / "todos.md").read_text()


def test_end_to_end_four_artefacts_land_group(chatdb, tmp_path):
    convs = reader.read_chats(db_path=chatdb, since_days=0, now_utc=_NOW)
    grp = [c for c in convs if c.chat_id == "2"][0]
    transcript_md = renderer.render_transcript(grp, name_for_jid=lambda jid: None)
    metadata = renderer.build_metadata(grp, name_for_jid=lambda jid: None)

    bundle, output, root = _build_bundle_via_adapter(
        metadata, transcript_md, tmp_path, label="grp"
    )
    assert bundle.channel == "whatsapp"
    bundles = sorted(root.rglob("summary.md"))
    assert len(bundles) == 1
    folder = bundles[0].parent
    assert sorted(p.name for p in folder.iterdir()) == [
        "summary.md", "todos.md", "transcript.md"
    ]


def test_end_to_end_l3_labelled_chat_skips_sinks_keeps_bundle(chatdb, tmp_path):
    """An L3-labelled (family/partner) chat lands the four-artefact
    bundle but never invokes the gist arm (Qdrant / Oxigraph)."""
    convs = reader.read_chats(db_path=chatdb, since_days=0, now_utc=_NOW)
    dm = [c for c in convs if c.chat_id == "1"][0]
    name_for = _names({"111@s.whatsapp.net": "Alex Synthetic"})
    transcript_md = renderer.render_transcript(dm, name_for_jid=name_for)
    # Operator marked this DM partner "Partner" -> CM048 ladder -> L3.
    metadata = renderer.build_metadata(
        dm, name_for_jid=name_for, contact_label="Partner"
    )

    called = {"n": 0}

    def _gist(_bundle, _output):
        called["n"] += 1
        return {"status": "ok"}

    bundle, output, root = _build_bundle_via_adapter(
        metadata, transcript_md, tmp_path, label="l3", gist=_gist
    )
    # CM048's WhatsApp ladder resolved the "Partner" label to L3.
    assert bundle.privacy_level == "L3"

    # Four artefacts still on disk.
    bundles = sorted(root.rglob("summary.md"))
    assert len(bundles) == 1
    folder = bundles[0].parent
    assert sorted(p.name for p in folder.iterdir()) == [
        "summary.md", "todos.md", "transcript.md"
    ]
    assert "privacy_level: L3" in (folder / "summary.md").read_text()
    # The gist arm (Qdrant / Oxigraph) was never invoked for an L3 chat.
    assert called["n"] == 0, "gist callback fired for an L3 chat"
    assert output.gist_status in ("skipped-l3", "skipped", "not-attempted"), (
        output.gist_status
    )
