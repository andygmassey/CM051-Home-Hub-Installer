"""Google Takeout "Google Chat" importer (vendor/ostler_fda/google_chat_takeout.py).

WHAT THIS PINS, consumer side first:

  1. A Chat export becomes the FOUR ARTEFACTS a customer reads. The payload
     is driven through the VENDORED CM048 channel adapter and writer (the
     model-free seed path, the same adapter + writer the full pass uses) and
     the folder holds summary, todos, transcript and frontmatter metadata.
     CONTROL: the same payload with a source-named channel writes NOTHING,
     which is why the importer sends ``channel="im"``.
  2. People land once. Correspondents go through the EXISTING email sink
     (``pwg_ingest.ingest_mail_contacts``) against a real HTTP Oxigraph
     (pyoxigraph). A person already holding the address is matched, not
     duplicated; a second import creates no node; the Chat display name
     upgrades an address-named node and never replaces a real name.
  3. Idempotent re-import: a second run hands the pipeline 0 payloads; a
     changed day re-sends exactly that day; a failed send is retried.
  4. Tolerance: renamed fields, unparseable dates, a corrupt messages.json, a
     missing group_info.json each degrade one field or one file and are
     reported per file by relative path, never content.
  5. Owner: from user_info.json, else inferred only when unambiguous, else
     ``no_owner`` and no payloads (direction would be guessed).

Every fixture is built here from the community-documented layout, which is
UNVERIFIED against a real export (see the module docstring). Synthetic cast
only; every address is on example.com.
"""
from __future__ import annotations

import json
import os
from datetime import timezone
import stat
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(REPO / "vendor"))
sys.path.insert(0, str(HERE))

from ostler_fda import google_chat_takeout as gc  # noqa: E402

OWNER = {"name": "Alex Doe", "email": "alex.doe@example.com", "user_type": "Human"}
JANE = {"name": "Jane Smith", "email": "jane.smith@example.com", "user_type": "Human"}
JOHN = {"name": "John Jones", "email": "john.jones@example.com", "user_type": "Human"}
MARY = {"name": "Mary Patel", "email": "mary.patel@example.com", "user_type": "Human"}
# A bot WITH an address, so only the user_type guard keeps it out of People.
BOT = {"name": "acme-helper", "email": "helper-bot@example.com", "user_type": "Bot"}


def _msg(creator, when, text, topic="t-solo", files=None, **extra):
    m = {"creator": creator, "created_date": when, "text": text, "topic_id": topic,
         "message_id": f"m-{abs(hash((creator.get('email'), when, text))) % 10**8}"}
    if files:
        m["attached_files"] = files
    m.update(extra)
    return m


def _write(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(data if isinstance(data, str) else json.dumps(data))


def build_export(root: Path, *, user_info=True, big_space=False) -> Path:
    chat = root / "Takeout" / "Google Chat"
    if user_info:
        _write(chat / "Users" / "User 1001" / "user_info.json",
               {"user": OWNER, "membership_info": []})
    dm = chat / "Groups" / "DM aaaa1111"
    _write(dm / "group_info.json", {"members": [OWNER, JANE]})
    _write(dm / "messages.json", {"messages": [
        _msg(JANE, "Wednesday, February 1, 2023 at 3:04:05 PM UTC", "Lunch on Friday?", "t1"),
        _msg(OWNER, "Wednesday, 1 February 2023 at 15:06:00 UTC", "Yes, the usual place", "t2"),
        _msg(JANE, "2023-02-02T09:00:00Z", "Here is the menu", "t3",
             files=[{"original_name": "menu.pdf", "export_name": "File-menu.pdf"}]),
    ]})
    _write(dm / "File-menu.pdf", "synthetic")
    space = chat / "Groups" / "Space bbbb2222"
    _write(space / "group_info.json", {"name": "Book club", "members": [OWNER, JANE, JOHN, BOT]})
    _write(space / "messages.json", {"messages": [
        _msg(JOHN, "February 3, 2023 at 10:00:00 AM UTC", "Next book is chosen", "thr-A"),
        _msg(OWNER, "February 3, 2023 at 10:05:00 AM UTC", "Great pick", "thr-A"),
        _msg(BOT, "February 3, 2023 at 10:06:00 AM UTC", "Reminder set", "thr-B"),
        _msg(JANE, "February 3, 2023 at 10:07:00 AM UTC", "I will bring snacks", "thr-A"),
        _msg(JOHN, "February 3, 2023 at 10:08:00 AM UTC", "Thanks all", "thr-C"),
        _msg(JOHN, "February 3, 2023 at 10:09:00 AM UTC", "See you then", "thr-C"),
    ]})
    if big_space:
        members = [OWNER] + [
            {"name": f"Person {i}", "email": f"person{i}@example.com", "user_type": "Human"}
            for i in range(12)
        ]
        big = chat / "Groups" / "Space cccc3333"
        _write(big / "group_info.json", {"name": "Globex news", "members": members})
        _write(big / "messages.json", {"messages": [
            _msg(members[1 + (i % 12)], f"2023-03-0{1 + i % 9}T08:00:00Z", f"notice {i}")
            for i in range(60)
        ]})
    return root


@pytest.fixture(autouse=True)
def _entitled(monkeypatch, request):
    """Every test runs ENTITLED unless it is a G7 test, which drives the gate
    itself. The real default (the shared helper) is exercised by name below."""
    if "g7" not in request.node.name:
        monkeypatch.setattr(gc, "default_gate", lambda: "pro")
    # Day boundaries follow the owner's zone; pin it so the fixtures' dates
    # are the same on every runner. The zone tests below set their own.
    monkeypatch.setenv("OSTLER_OWNER_TZ", "UTC")


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------


def test_parses_dm_and_space_with_owner_from_user_info(tmp_path):
    ex = gc.parse_export(build_export(tmp_path))
    assert ex.owner_email == "alex.doe@example.com" and ex.owner_source == "user_info"
    kinds = sorted((g.kind, g.tier) for g in ex.groups)
    assert kinds == [("dm", gc.TIER_T1_DM), ("space", gc.TIER_T2_GROUP)]
    assert sum(len(g.messages) for g in ex.groups) == 9
    assert ex.undated_messages == 0 and ex.errors == []


@pytest.mark.parametrize("raw,iso", [
    ("Wednesday, February 1, 2023 at 3:04:05 PM UTC", "2023-02-01T15:04:05+00:00"),
    ("Wednesday, 1 February 2023 at 15:04:05 UTC", "2023-02-01T15:04:05+00:00"),
    ("February 1, 2023 at 3:04:05 PM UTC", "2023-02-01T15:04:05+00:00"),
    ("1 February 2023 at 23:30:00 +08:00", "2023-02-01T15:30:00+00:00"),
    ("2023-02-01T15:04:05Z", "2023-02-01T15:04:05+00:00"),
    (1675263845, "2023-02-01T15:04:05+00:00"),
    (1675263845000, "2023-02-01T15:04:05+00:00"),
    (1675263845 * 10**6, "2023-02-01T15:04:05+00:00"),
])
def test_timestamp_formats(raw, iso):
    dt, _ = gc.parse_timestamp(raw)
    assert dt is not None and dt.isoformat() == iso


def test_unparseable_date_keeps_the_message_and_counts_it(tmp_path):
    root = build_export(tmp_path)
    p = root / "Takeout/Google Chat/Groups/DM aaaa1111/messages.json"
    data = json.loads(p.read_text())
    data["messages"].append(_msg(JANE, "1 Shvat 5783 15:10", "Parfait", "t9"))
    p.write_text(json.dumps(data))
    ex = gc.parse_export(root)
    assert ex.undated_messages == 1
    dm = next(g for g in ex.groups if g.kind == "dm")
    assert any(m.text == "Parfait" for m in dm.messages)
    # Filed under the previous dated message's day, not dropped.
    payload = next(p for p in gc.group_payloads(dm, ex) if "Parfait" in p["transcript"])
    assert payload["conversation_id"].startswith("gchat_20230202_")


def test_renamed_fields_are_read(tmp_path):
    root = tmp_path
    chat = root / "Google Chat"
    g = chat / "Groups" / "DM dddd4444"
    _write(g / "group_info.json", {"participants": [OWNER, MARY]})
    _write(g / "messages.json", {"messages": [
        {"sender": MARY, "create_time": "2023-04-01T10:00:00Z", "content": "Renamed shape", "thread_id": "x"},
    ]})
    ex = gc.parse_export(root, owner_email="Alex.Doe@example.com")
    m = ex.groups[0].messages[0]
    assert (m.author.email, m.text, m.topic_id) == ("mary.patel@example.com", "Renamed shape", "x")
    assert m.timestamp is not None and ex.owner_source == "argument"


def test_per_file_errors_never_abort_the_export(tmp_path):
    root = build_export(tmp_path)
    groups = root / "Takeout/Google Chat/Groups"
    _write(groups / "DM eeee5555" / "group_info.json", {"members": [OWNER, MARY]})
    _write(groups / "DM eeee5555" / "messages.json", "{ not json")
    _write(groups / "DM ffff6666" / "messages.json", {"messages": [
        _msg(MARY, "2023-05-01T10:00:00Z", "No group info here")]})
    _write(groups / "DM gggg7777" / "messages.json", {"msgs": []})
    ex = gc.parse_export(root)
    errs = {(e.path, e.reason, e.detail) for e in ex.errors}
    assert ("Groups/DM eeee5555/messages.json", "bad_json", "JSONDecodeError") in errs
    assert ("Groups/DM ffff6666/group_info.json", "missing", "") in errs
    assert ("Groups/DM gggg7777/messages.json", "unexpected_shape", "no_messages_key") in errs
    # The good groups still parsed, and the info-less group still yields its message.
    assert {g.folder for g in ex.groups} >= {"DM aaaa1111", "Space bbbb2222", "DM ffff6666"}
    # Error records carry no content.
    blob = json.dumps([e.to_dict() for e in ex.errors])
    assert "No group info here" not in blob and "example.com" not in blob


def test_no_groups_dir_is_not_found(tmp_path, capsys):
    assert gc.main(["--export-path", str(tmp_path), "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["status"] == "not_found"


def test_owner_inferred_only_when_unambiguous(tmp_path):
    ex = gc.parse_export(build_export(tmp_path / "a", user_info=False))
    # Members of every group: owner and Jane, so ambiguous -> no owner.
    assert ex.owner_email is None and gc.export_payloads(ex) == []
    root = build_export(tmp_path / "b", user_info=False)
    _write(root / "Takeout/Google Chat/Groups/DM hhhh8888/group_info.json", {"members": [OWNER, MARY]})
    _write(root / "Takeout/Google Chat/Groups/DM hhhh8888/messages.json",
           {"messages": [_msg(MARY, "2023-06-01T10:00:00Z", "hi")]})
    ex = gc.parse_export(root)
    assert (ex.owner_email, ex.owner_source) == ("alex.doe@example.com", "inferred")


def test_cli_no_owner_emits_nothing(tmp_path, capsys):
    root = build_export(tmp_path / "x", user_info=False)
    out = tmp_path / "out"
    assert gc.main(["--export-path", str(root), "--output-dir", str(out), "--json"]) == 0
    res = json.loads(capsys.readouterr().out)
    assert res["status"] == "no_owner"
    assert not (out / "google_chat_conversations.json").exists()


# ---------------------------------------------------------------------------
# Payload shape
# ---------------------------------------------------------------------------


def test_payloads_one_per_group_day_with_explicit_privacy(tmp_path):
    ex = gc.parse_export(build_export(tmp_path))
    payloads = gc.export_payloads(ex)
    ids = sorted(p["conversation_id"] for p in payloads)
    assert ids == ["gchat_20230201_aaaa1111", "gchat_20230202_aaaa1111", "gchat_20230203_bbbb2222"]
    for p in payloads:
        md = p["metadata"]
        assert (md["channel"], md["source"], md["privacy_level"]) == ("im", "google_chat", "L2")
        owner = [x for x in md["participants"] if x["role"] == "user"]
        assert owner == [{"id": "alex.doe@example.com", "display": "Alex Doe",
                          "role": "user", "email": "alex.doe@example.com"}]
    space = next(p for p in payloads if p["conversation_id"].endswith("bbbb2222"))
    others = {x["email"] for x in space["metadata"]["participants"] if x["role"] == "other"}
    assert others == {"jane.smith@example.com", "john.jones@example.com"}  # bot excluded
    assert space["metadata"]["group_subject"] == "Book club"
    t = space["transcript"]
    assert "**acme-helper (bot)**" in t
    assert t.count("[thread ") == 5   # thr-A x3, thr-C x2; thr-B is a single message
    dm2 = next(p for p in payloads if p["conversation_id"] == "gchat_20230202_aaaa1111")
    assert "[attachment: menu.pdf]" in dm2["transcript"]
    assert dm2["metadata"]["attachment_count"] == 1


def test_large_passive_space_is_skipped(tmp_path):
    ex = gc.parse_export(build_export(tmp_path, big_space=True))
    big = next(g for g in ex.groups if g.folder == "Space cccc3333")
    assert big.tier == gc.TIER_T3_SKIP
    assert not any(p["conversation_id"].endswith("cccc3333") for p in gc.export_payloads(ex))
    assert not any(e.startswith("person") for e in gc.correspondents(ex))


def test_correspondents_exclude_owner_and_bots(tmp_path):
    ex = gc.parse_export(build_export(tmp_path))
    assert gc.correspondents(ex) == {"jane.smith@example.com": 3, "john.jones@example.com": 3}


# ---------------------------------------------------------------------------
# Consumer side: the four artefacts, through the vendored CM048 writer
# ---------------------------------------------------------------------------


def _cm048(tmp_path, monkeypatch):
    # Every CM048 default path hangs off HOME: keep them all in tmp.
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    sys.path.insert(0, str(REPO / "vendor" / "cm048_pipeline"))
    from src import seed  # noqa: E402
    from src.settings import Settings  # noqa: E402

    s = Settings(user_id="test-owner")
    s.output_conversations_dir = tmp_path / "Conversations"
    s.processing_state_dir = tmp_path / "processing"
    return seed, s


def test_payload_writes_the_four_artefacts(tmp_path, monkeypatch):
    pytest.importorskip("yaml")
    seed, settings = _cm048(tmp_path, monkeypatch)
    ex = gc.parse_export(build_export(tmp_path / "export"))
    p = next(x for x in gc.export_payloads(ex) if x["conversation_id"].endswith("bbbb2222"))
    folder = seed.seed_conversation(p["conversation_id"], p["transcript"], p["metadata"], settings)
    assert folder is not None
    names = sorted(f.name for f in Path(folder).iterdir())
    # Three bodies, and the fourth artefact (metadata) is the frontmatter
    # every one of them carries.
    assert names == ["summary.md", "todos.md", "transcript.md"], names
    for n in names:
        head = (Path(folder) / n).read_text().split("\n---", 1)[0]
        assert head.startswith("---") and "privacy_level: L2" in head, n
        assert "google_chat" in head, n
    assert "I will bring snacks" in (Path(folder) / "transcript.md").read_text()
    # Re-seeding the same payload rewrites the same folder: no second copy.
    again = seed.seed_conversation(p["conversation_id"], p["transcript"], p["metadata"], settings)
    assert again == folder
    assert len(list((tmp_path / "Conversations").rglob("transcript.md"))) == 1


def test_control_a_source_named_channel_writes_no_bundle(tmp_path, monkeypatch):
    pytest.importorskip("yaml")
    seed, settings = _cm048(tmp_path, monkeypatch)
    ex = gc.parse_export(build_export(tmp_path / "export"))
    p = gc.export_payloads(ex)[0]
    md = dict(p["metadata"], channel="google_chat")
    assert seed.seed_conversation(p["conversation_id"], p["transcript"], md, settings) is None
    assert not list((tmp_path / "Conversations").rglob("transcript.md"))


# ---------------------------------------------------------------------------
# Idempotency
# ---------------------------------------------------------------------------


class _Sink:
    def __init__(self, fail_ids=()):
        self.sent = []
        self.fail_ids = set(fail_ids)

    def conversations(self, payloads, *, source):
        p = payloads[0]
        if p["conversation_id"] in self.fail_ids:
            return {"persist_status": "error", "persisted": 0, "persist_failed": 1}
        self.sent.append(p["conversation_id"])
        return {"persist_status": "ok", "persisted": 1, "persist_failed": 0}

    def people(self, contacts, *, source):
        return {"persist_status": "ok", "people_created": 0}


def _persist(ex, ledger, sink):
    return gc.persist(ex, ledger=ledger, conversations_fn=sink.conversations,
                      people_fn=sink.people, name_fn=lambda names: 0)


def test_second_run_sends_nothing_and_a_changed_day_resends_only_that_day(tmp_path):
    root = build_export(tmp_path / "export")
    state = tmp_path / "ledger.json"
    s1 = _Sink()
    r1 = _persist(gc.parse_export(root), gc.ImportLedger(state), s1)
    assert r1["conversations_sent"] == 3 and len(s1.sent) == 3
    s2 = _Sink()
    r2 = _persist(gc.parse_export(root), gc.ImportLedger(state), s2)
    assert (r2["conversations_sent"], r2["conversations_unchanged"], s2.sent) == (0, 3, [])
    p = root / "Takeout/Google Chat/Groups/DM aaaa1111/messages.json"
    data = json.loads(p.read_text())
    data["messages"].append(_msg(OWNER, "2023-02-02T18:00:00Z", "Looks good", "t4"))
    p.write_text(json.dumps(data))
    s3 = _Sink()
    _persist(gc.parse_export(root), gc.ImportLedger(state), s3)
    assert s3.sent == ["gchat_20230202_aaaa1111"]


def test_a_failed_send_is_retried_next_run(tmp_path):
    root = build_export(tmp_path / "export")
    state = tmp_path / "ledger.json"
    r1 = _persist(gc.parse_export(root), gc.ImportLedger(state),
                  _Sink(fail_ids={"gchat_20230203_bbbb2222"}))
    assert (r1["conversations_sent"], r1["conversations_failed"], r1["conversations_status"]) == (2, 1, "partial")
    s2 = _Sink()
    _persist(gc.parse_export(root), gc.ImportLedger(state), s2)
    assert s2.sent == ["gchat_20230203_bbbb2222"]


def test_through_the_real_pwg_convo_call_path(tmp_path, monkeypatch):
    """persist() drives universal_import._persist_conversations, which execs
    the pwg-convo command. A stub binary records each call; the second run
    execs it zero times."""
    log = tmp_path / "calls.log"
    stub = tmp_path / "pwg-convo"
    stub.write_text(f"#!/bin/sh\necho \"$1 $(basename \"$2\")\" >> '{log}'\nexit 0\n")
    stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("OSTLER_PWG_CONVO_CMD", str(stub))
    root = build_export(tmp_path / "export")
    state = tmp_path / "ledger.json"
    noop_people = lambda contacts, *, source: {"persist_status": "no_graph", "people_created": 0}
    r1 = gc.persist(gc.parse_export(root), ledger=gc.ImportLedger(state), people_fn=noop_people)
    assert r1["conversations_sent"] == 3
    assert log.read_text().splitlines() == ["process transcript.md"] * 3
    r2 = gc.persist(gc.parse_export(root), ledger=gc.ImportLedger(state), people_fn=noop_people)
    assert r2["conversations_sent"] == 0 and len(log.read_text().splitlines()) == 3


def test_l3_reaches_pwg_convo(tmp_path, monkeypatch):
    """Archie ruling 1: every level, L3 included, reaches processor.process.
    CM048's writer, not the importer, decides what L3 skips."""
    seen = tmp_path / "levels.log"
    stub = tmp_path / "pwg-convo"
    stub.write_text(
        "#!/bin/sh\n"
        f"/usr/bin/grep -o '\"privacy_level\": \"L[0-3]\"' \"$3\" >> '{seen}'\n"
        "exit 0\n"
    )
    stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("OSTLER_PWG_CONVO_CMD", str(stub))
    ex = gc.parse_export(build_export(tmp_path / "export"))
    real = gc.export_payloads

    def l3_payloads(export):
        out = real(export)
        for p in out:
            p["metadata"]["privacy_level"] = "L3"
        return out

    monkeypatch.setattr(gc, "export_payloads", l3_payloads)
    r = gc.persist(ex, ledger=gc.ImportLedger(tmp_path / "ledger.json"),
                   people_fn=lambda c, *, source: {"persist_status": "no_graph", "people_created": 0})
    assert r["conversations_sent"] == 3
    assert seen.read_text().splitlines() == ['"privacy_level": "L3"'] * 3


def test_no_pipeline_is_reported_not_recorded(tmp_path, monkeypatch):
    monkeypatch.setenv("OSTLER_PWG_CONVO_CMD", str(tmp_path / "absent-binary"))
    monkeypatch.setattr("shutil.which", lambda *_a, **_k: None)
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    root = build_export(tmp_path / "export")
    state = tmp_path / "ledger.json"
    r = gc.persist(gc.parse_export(root), ledger=gc.ImportLedger(state),
                   people_fn=lambda c, *, source: {"persist_status": "ok", "people_created": 0},
                   name_fn=lambda n: 0)
    assert r["conversations_status"] == "no_pipeline" and r["conversations_sent"] == 0
    assert gc.ImportLedger(state).entries == {}


# ---------------------------------------------------------------------------
# People: the existing email sink against a real HTTP Oxigraph
# ---------------------------------------------------------------------------


@pytest.fixture
def oxigraph(monkeypatch):
    pytest.importorskip("pyoxigraph")
    pytest.importorskip("httpx")
    from _fake_oxigraph import FakeOxigraph  # noqa: E402
    from ostler_fda import pwg_ingest  # noqa: E402

    fake = FakeOxigraph()
    monkeypatch.setattr(pwg_ingest, "OXIGRAPH_URL", fake.url)
    yield fake
    fake.close()


def _people_persist(root, state):
    noop = lambda payloads, *, source: {"persist_status": "ok", "persisted": 1, "persist_failed": 0}
    return gc.persist(gc.parse_export(root), ledger=gc.ImportLedger(state), conversations_fn=noop)


def test_people_land_once_matched_and_named(tmp_path, oxigraph):
    # Jane is already a contact card holding her address, under a URI the
    # email sink could never mint itself.
    oxigraph.update(
        "INSERT DATA { <urn:contact:jane> a pwg:Person ; pwg:displayName \"Jane Smith\" ;"
        " pwg:hasIdentifier <urn:contact:jane:id> . <urn:contact:jane:id> a pwg:PersonIdentifier ;"
        " pwg:identifierType \"email\" ; pwg:identifierValue \"Jane.Smith@example.com\" . }"
    )
    root = build_export(tmp_path / "export")
    state = tmp_path / "ledger.json"
    r1 = _people_persist(root, state)
    assert r1["people_status"] == "ok" and r1["people_created"] == 1   # John only
    assert oxigraph.person_count() == 2
    # The address-named node minted for John gained his Chat display name;
    # Jane's real name is untouched.
    assert oxigraph.person_names() == ["Jane Smith", "John Jones"]
    r2 = _people_persist(root, state)
    assert r2["people_created"] == 0 and oxigraph.person_count() == 2


# ---------------------------------------------------------------------------
# G7: Google Chat is Pro; the FIRST export import is free (Andy, 2026-10-19).
# The gate is the shared ostler_fda.first_import helper, at the entry point.
# ---------------------------------------------------------------------------


class _CountingPeople:
    def __init__(self):
        self.calls = 0

    def __call__(self, contacts, *, source):
        self.calls += 1
        return {"persist_status": "ok", "people_created": 0}


def _g7_run(root, state, gate, sink=None, marks=None):
    sink = sink or _Sink()
    people = _CountingPeople()
    marks = marks if marks is not None else []
    r = gc.persist(gc.parse_export(root), ledger=gc.ImportLedger(state),
                   conversations_fn=sink.conversations, people_fn=people,
                   name_fn=lambda n: 0, gate_fn=lambda: gate,
                   mark_fn=lambda: marks.append(1))
    return r, sink, people, marks


def test_g7_pro_required_sends_nothing_then_pro_sends_all(tmp_path):
    root = build_export(tmp_path / "export")
    state = tmp_path / "ledger.json"
    r, sink, people, marks = _g7_run(root, state, "pro_required")
    assert (r["conversations_status"], r["paused_reason"]) == ("paused", "pro_required")
    assert sink.sent == [] and people.calls == 0 and marks == []
    assert gc.ImportLedger(state).entries == {}
    r, sink, people, marks = _g7_run(root, state, "pro")
    assert r["conversations_sent"] == 3 and people.calls == 1
    assert marks == []          # Pro imports never spend the free taster


def test_g7_first_import_free_is_marked_only_after_every_payload_lands(tmp_path):
    root = build_export(tmp_path / "export")
    state = tmp_path / "ledger.json"
    r, _, _, marks = _g7_run(root, state, "first_import_free",
                             sink=_Sink(fail_ids={"gchat_20230203_bbbb2222"}))
    assert r["conversations_failed"] == 1 and marks == [] and r["first_import_marked"] is False
    r, sink, _, marks = _g7_run(root, state, "first_import_free")
    assert sink.sent == ["gchat_20230203_bbbb2222"] and marks == [1] and r["first_import_marked"]


def test_g7_could_not_check_is_cannot_run_not_a_refusal(tmp_path):
    r, sink, _, marks = _g7_run(build_export(tmp_path / "export"), tmp_path / "l.json", "could_not_check")
    assert r["conversations_status"] == "cannot_run" and sink.sent == [] and marks == []


def test_g7_could_not_ask_fails_open(tmp_path):
    r, sink, _, _ = _g7_run(build_export(tmp_path / "export"), tmp_path / "l.json", "unknown")
    assert r["conversations_sent"] == 3 and r["gate"] == "unknown"


def test_g7_default_refuses_when_the_shared_helper_is_absent(tmp_path, monkeypatch):
    monkeypatch.setattr(gc, "SHARED_GATE_MODULE", "ostler_fda._no_such_g7_helper_for_tests")
    assert gc.default_gate() == "gate_helper_absent"
    sink = _Sink()
    r = gc.persist(gc.parse_export(build_export(tmp_path / "export")),
                   ledger=gc.ImportLedger(tmp_path / "l.json"),
                   conversations_fn=sink.conversations, people_fn=_CountingPeople(),
                   name_fn=lambda n: 0)
    assert (r["conversations_status"], r["paused_reason"]) == ("paused", "gate_helper_absent")
    assert sink.sent == []


def test_g7_default_maps_the_helper_answer(monkeypatch):
    import types
    from dataclasses import dataclass

    @dataclass(frozen=True)
    class D:
        allowed: object
        reason: object

    asked = []
    fake = types.ModuleType("ostler_fda_g7_fake_helper")
    monkeypatch.setitem(sys.modules, "ostler_fda_g7_fake_helper", fake)
    monkeypatch.setattr(gc, "SHARED_GATE_MODULE", "ostler_fda_g7_fake_helper")

    def answer(d):
        def entry_gate(source, *, export_import):
            asked.append((source, export_import))
            return d
        fake.entry_gate = entry_gate

    for d, want in [
        (D(True, "pro"), "pro"),
        (D(True, "first_import_free"), "first_import_free"),
        (D(False, "pro_required"), "pro_required"),
        (D(False, "could_not_check"), "could_not_check"),
        (D(True, "pro_required"), "unknown"),        # self-contradictory
        (D("yes", "pro"), "unknown"),                # not a bool
        (D(True, "free_forever"), "unknown"),        # off-contract reason
    ]:
        answer(d)
        assert gc.default_gate() == want, d
    assert set(asked) == {("google_chat", True)}

    def boom(source, *, export_import):
        raise RuntimeError("state unreadable")

    fake.entry_gate = boom
    assert gc.default_gate() == "unknown"


def _cli(root, out, gate, monkeypatch, capsys, read_ok=True):
    monkeypatch.setattr(gc, "default_gate", lambda: gate)
    monkeypatch.setattr(gc, "gate_text", lambda reason: f"TEXT[{reason}]")
    if not read_ok:
        def must_not_read(*a, **k):
            raise AssertionError("the export was read without entitlement")
        monkeypatch.setattr(gc, "parse_export", must_not_read)
    rc = gc.main(["--export-path", str(root), "--output-dir", str(out), "--json"])
    cap = capsys.readouterr()
    return rc, json.loads(cap.out), cap.err


def test_g7_cli_pro_required_exits_5_reads_nothing(tmp_path, monkeypatch, capsys):
    out = tmp_path / "out"
    rc, res, err = _cli(build_export(tmp_path / "export"), out, "pro_required",
                        monkeypatch, capsys, read_ok=False)
    from ostler_fda import first_import as fi

    assert (rc, res["status"]) == (fi.EXIT_PAUSED_NOT_PRO, "paused_not_pro") and rc == 5
    assert "TEXT[pro_required]" in err and not out.exists()


def test_g7_cli_could_not_check_exits_6_reads_nothing(tmp_path, monkeypatch, capsys):
    out = tmp_path / "out"
    rc, res, err = _cli(build_export(tmp_path / "export"), out, "could_not_check",
                        monkeypatch, capsys, read_ok=False)
    from ostler_fda import first_import as fi

    assert (rc, res["status"]) == (fi.EXIT_COULD_NOT_CHECK, "cannot_run") and rc == 6
    assert "TEXT[could_not_check]" in err and not out.exists()


def test_g7_cli_first_import_free_shows_the_notice_and_stages(tmp_path, monkeypatch, capsys):
    out = tmp_path / "out"
    rc, res, err = _cli(build_export(tmp_path / "export"), out, "first_import_free",
                        monkeypatch, capsys)
    assert (rc, res["status"], res["conversations"]) == (0, "ok", 3)
    assert "TEXT[first_import_free]" in err
    assert len(json.loads((out / "google_chat_conversations.json").read_text())) == 3


def test_g7_real_shared_helper_free_once_then_pro(tmp_path, monkeypatch):
    """The REAL vendored helpers (subscription_gate #3024 + first_import),
    not fakes: no Pro, first import free and marked; the second needs Pro."""
    from datetime import datetime, timezone

    pytest.importorskip("ostler_fda.first_import")
    from ostler_fda import subscription_gate as sg

    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv("OSTLER_SUBSCRIPTION_STATE", str(tmp_path / "state" / "subscription_state.json"))
    monkeypatch.setenv("OSTLER_FIRST_IMPORT_LEDGER", str(tmp_path / "state" / "first_imports.json"))
    root = build_export(tmp_path / "export")
    assert gc.default_gate() == "first_import_free"
    sink = _Sink()
    r = gc.persist(gc.parse_export(root), ledger=gc.ImportLedger(tmp_path / "l.json"),
                   conversations_fn=sink.conversations, people_fn=_CountingPeople(),
                   name_fn=lambda n: 0)
    assert r["conversations_sent"] == 3 and r["first_import_marked"]
    assert gc.default_gate() == "pro_required"
    sg.activate_first_month_free(datetime.now(timezone.utc).isoformat())
    assert gc.default_gate() == "pro"


# ---------------------------------------------------------------------------
# Edge-case red team (EDGE_CASE_MATRIX_2026-10-19): locale dates, unplaceable
# zones, and the owner's local day.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("raw,iso", [
    ("Mittwoch, 1. Februar 2023 um 15:04:05 UTC", "2023-02-01T15:04:05+00:00"),
    ("mercredi 1 février 2023 à 15:04:05 UTC", "2023-02-01T15:04:05+00:00"),
    ("miércoles, 1 de febrero de 2023, 15:04:05 UTC", "2023-02-01T15:04:05+00:00"),
    ("1 febbraio 2023 alle 15:04:05 UTC", "2023-02-01T15:04:05+00:00"),
    ("1 februari 2023 om 15:04:05 UTC", "2023-02-01T15:04:05+00:00"),
    ("February 1, 2023 at 11:04:05 PM GMT+8", "2023-02-01T15:04:05+00:00"),
    ("1 February 2023 at 20:34:05 UTC+05:30", "2023-02-01T15:04:05+00:00"),
])
def test_locale_and_offset_dates(raw, iso):
    dt, note = gc.parse_timestamp(raw)
    assert dt is not None and dt.isoformat() == iso and note == gc.TS_OK


def test_an_unplaceable_zone_is_never_guessed():
    dt, note = gc.parse_timestamp("February 1, 2023 at 3:04:05 PM HKT")
    assert dt is None and note == gc.TS_UNPLACED_ZONE


def test_a_zoneless_time_is_read_in_the_owners_zone():
    from zoneinfo import ZoneInfo

    dt, note = gc.parse_timestamp("1 February 2023 at 23:04:05", ZoneInfo("Asia/Hong_Kong"))
    assert dt.isoformat() == "2023-02-01T15:04:05+00:00" and note == gc.TS_ASSUMED_LOCAL


def _one_dm(root, dates):
    g = root / "Google Chat" / "Groups" / "DM zzzz9999"
    _write(g / "group_info.json", {"members": [OWNER, MARY]})
    _write(g / "messages.json", {"messages": [
        _msg(MARY if i % 2 else OWNER, d, f"line {i}", f"t{i}") for i, d in enumerate(dates)]})
    return root


def test_a_mostly_unparsed_file_fails_loud_not_one_undated_pile(tmp_path):
    root = _one_dm(tmp_path, ["1 Shvat 5783 15:00"] * 4 + ["2023-02-01T10:00:00Z"])
    ex = gc.parse_export(root, owner_email=OWNER["email"])
    errs = [(e.path, e.reason, e.detail) for e in ex.errors]
    assert errs == [("Groups/DM zzzz9999/messages.json", "unparsed_dates", "4_of_5")]
    assert gc.export_payloads(ex) == []
    assert not any(p["conversation_id"].startswith("gchat_00000000") for p in gc.export_payloads(ex))


def test_a_file_of_unplaceable_zones_is_reported_as_such(tmp_path):
    root = _one_dm(tmp_path, ["February 1, 2023 at 3:04:05 PM HKT"] * 3)
    ex = gc.parse_export(root, owner_email=OWNER["email"])
    assert [(e.reason, e.detail) for e in ex.errors] == [("unplaced_zone", "3_of_3")]
    assert ex.tz_unplaced == 3 and gc.export_payloads(ex) == []


def test_a_minority_undated_never_makes_a_00000000_conversation(tmp_path):
    root = _one_dm(tmp_path, ["no date here", "2023-02-01T10:00:00Z", "2023-02-01T11:00:00Z"])
    ex = gc.parse_export(root, owner_email=OWNER["email"])
    ids = [p["conversation_id"] for p in gc.export_payloads(ex)]
    assert ids == ["gchat_20230201_zzzz9999"]
    assert ex.errors == [] and ex.undated_messages == 1


def test_days_and_times_are_the_owners_local_zone(tmp_path):
    """A UTC+8 owner's working day is ONE conversation, under its local date,
    with local clock times; in UTC the same messages would split at 08:00."""
    from zoneinfo import ZoneInfo

    root = _one_dm(tmp_path, ["2023-02-01T23:30:00Z",    # 07:30 on 2 Feb in Hong Kong
                              "2023-02-02T01:00:00Z"])   # 09:00 on 2 Feb in Hong Kong
    hk = gc.parse_export(root, owner_email=OWNER["email"], tz=ZoneInfo("Asia/Hong_Kong"))
    ps = gc.export_payloads(hk)
    assert [p["conversation_id"] for p in ps] == ["gchat_20230202_zzzz9999"]
    assert "(2023-02-02 07:30)" in ps[0]["transcript"] and "(2023-02-02 09:00)" in ps[0]["transcript"]
    assert ps[0]["metadata"]["date"] == "2023-02-02" and ps[0]["metadata"]["timezone"] == "Asia/Hong_Kong"
    utc = gc.parse_export(root, owner_email=OWNER["email"], tz=timezone.utc)
    assert len(gc.export_payloads(utc)) == 2      # control: UTC splits the same day


def test_owner_zone_comes_from_the_environment(monkeypatch):
    monkeypatch.setenv("OSTLER_OWNER_TZ", "Europe/London")
    assert str(gc.local_zone()) == "Europe/London"
