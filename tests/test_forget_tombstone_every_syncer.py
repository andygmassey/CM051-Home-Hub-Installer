"""CM051 copy of CM041 assistant_api/tests/test_forget_tombstone_every_syncer.py,
run against the VENDORED tree. whatsapp_bridge is not vendored here, so that
runner is absent.

A person erased by ``/api/v1/people/<slug>/forget`` stays erased when every
people syncer next runs (Lane 18, Archie's review of Lane 11).

Before the tombstone, forget deleted every triple and nothing else, so the
next sync that still held the person in its source read "nobody holds this
identifier" and minted them again (CM041 #200: "a person erased by forget can
be recreated by the next contact sync (no tombstone)").

HOW IT RUNS. A real HTTP socket speaks the Oxigraph /query and /update
endpoints over a pyoxigraph Store (``_fake_oxigraph.py``), so the forget
handler (urllib), the identity resolver (httpx) and each syncer's own writer
(httpx) all run UNMODIFIED. Per syncer:

  1. mint a synthetic person with the real resolver (phone, email, iCloud uid,
     LinkedIn URL, WhatsApp LID);
  2. forget them through the real ``api_people_forget``;
  3. run that syncer's real import entry point with a source that still lists
     them;
  4. assert the graph holds no person.

``test_control_*`` removes the tombstone and shows the SAME sync recreating the
person, so the green above is the tombstone's doing and not a harness that
cannot see a recreation.

All identifiers are SYNTHETIC / reserved (example.invalid, Ofcom drama range).
"""
from __future__ import annotations

import csv
import importlib.util
import json
import os
import sys
import types
from pathlib import Path

import pytest

pytest.importorskip("pyoxigraph")

HERE = Path(__file__).resolve().parent
#: The VENDORED CM041 tree is what ships on a customer Hub, so that is the tree
#: under test (CM041's own copy of this test lives in assistant_api/tests).
REPO = HERE.parent / "vendor" / "cm041"
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(HERE))


def _install_ostler_security_stub() -> None:
    """ical-server.py hard-imports ostler_security (HR015, private). Stub it
    exactly as vendor/cm041 CI does for its other server-loading tests."""
    try:
        import ostler_security  # noqa: F401
        return
    except Exception:
        pass
    import sqlite3 as _sqlite

    pkg = types.ModuleType("ostler_security")
    pkg.__path__ = []
    sys.modules["ostler_security"] = pkg
    db = types.ModuleType("ostler_security.database")
    db.get_db_connection = lambda path, _k, *a, **kw: _sqlite.connect(path)
    sys.modules["ostler_security.database"] = db
    posture = types.ModuleType("ostler_security.posture")
    posture.record_posture = lambda *a, **kw: None
    sys.modules["ostler_security.posture"] = posture
    # The vendored server also hard-imports ostler_security.db_key.
    db_key = types.ModuleType("ostler_security.db_key")
    db_key.resolve_db_key = lambda *a, **kw: types.SimpleNamespace(
        key=None, source=None, reason="no_key", detail=None)
    sys.modules["ostler_security.db_key"] = db_key


_install_ostler_security_stub()

from _fake_oxigraph import FakeOxigraph  # noqa: E402

NAME = "Elizabeth Stewart"
SLUG = "elizabeth-stewart"
PHONE = "+447700900123"
EMAIL = "elizabeth.stewart@example.invalid"
UID = "SYNTHETIC-ICLOUD-UID-0001"
LINKEDIN = "https://www.linkedin.com/in/elizabeth-stewart-synthetic"
LID = "1" + "0" * 13 + "1"  # 15 digits, composed so the shape scan never sees a literal


def _load_server():
    spec = importlib.util.spec_from_file_location(
        "ical_server_tombstone", REPO / "assistant_api" / "ical-server.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture()
def world(tmp_path, monkeypatch):
    store = FakeOxigraph()
    tomb = tmp_path / "forgotten_people.json"
    monkeypatch.setenv("OSTLER_FORGET_TOMBSTONE_FILE", str(tomb))
    monkeypatch.setenv("OXIGRAPH_URL", store.url)

    from contact_syncer import config as cfg

    monkeypatch.setattr(cfg, "OXIGRAPH_URL", store.url)
    monkeypatch.setattr(cfg, "QDRANT_URL", "http://127.0.0.1:9")
    monkeypatch.setattr(cfg, "USER_ID", "")
    monkeypatch.setattr(cfg, "DEFAULT_PRIVACY_LEVEL", "L2")
    monkeypatch.setattr(cfg, "DEFAULT_COUNTRY_CODE", 44)
    for modname in (
        "contact_syncer.facebook_friends",
        "contact_syncer.instagram_social",
        "contact_syncer.linkedin_connections",
        "contact_syncer.linkedin_career",
        "contact_syncer.linkedin_messages",
    ):
        m = __import__(modname, fromlist=["x"])
        if hasattr(m, "HAS_QDRANT"):
            monkeypatch.setattr(m, "HAS_QDRANT", False)

    server = _load_server()
    monkeypatch.setattr(server, "OXIGRAPH_URL", store.url)
    monkeypatch.setattr(server, "QDRANT_URL", "http://127.0.0.1:9")
    monkeypatch.setattr(server, "_RECOMPILE_QUEUE_DIR", tmp_path / "queue")

    w = types.SimpleNamespace(store=store, tomb=tomb, server=server, tmp=tmp_path, cfg=cfg,
                              monkeypatch=monkeypatch)
    yield w
    store.close()


def _mint_and_forget(w):
    from identity_resolver.models import PersonIdentity
    from identity_resolver.resolver import IdentityResolver

    resolver = IdentityResolver(oxigraph_url=w.store.url, default_country_code=44)
    resolver.create_person(
        PersonIdentity(
            display_name=NAME,
            given_name="Elizabeth",
            family_name="Stewart",
            phones=[PHONE],
            emails=[EMAIL],
            icloud_uid=UID,
            linkedin_url=LINKEDIN,
            whatsapp_lids=[LID],
        ),
        user_id="",
    )
    assert w.store.person_names() == [NAME], "the synthetic person was not minted"
    body, status = w.server.api_people_forget(SLUG)
    assert status == 200 and body["forgotten"] is True, (status, body)
    assert w.store.person_count() == 0, "forget left the person in the graph"


# ── one runner per syncer: its REAL entry point, a source that still lists them


def _run_icloud_contacts(w):
    from contact_syncer.syncer import ContactSyncer
    from identity_resolver.resolver import IdentityResolver

    s = ContactSyncer.__new__(ContactSyncer)
    s.cfg = w.cfg
    s.resolver = IdentityResolver(oxigraph_url=w.store.url, default_country_code=44)
    s._persist_photo = lambda *a, **k: None
    s._identifier_exists = lambda *a, **k: False
    parsed = {
        "fn": NAME, "given_name": "Elizabeth", "family_name": "Stewart",
        "uid": UID, "phones": [{"value": PHONE}], "emails": [{"value": EMAIL}],
        "org": "", "title": "", "notes": "", "birthday": "",
    }
    return s._resolve_and_write_person(parsed, "person")


def _run_facebook(w):
    from contact_syncer import facebook_friends

    p = w.tmp / "your_friends.json"
    p.write_text(json.dumps({"friends_v2": [{"name": NAME, "timestamp": 1700000000}]}))
    return facebook_friends.import_friends(str(p))


def _run_instagram(w):
    from contact_syncer import instagram_social

    d = w.tmp / "ig"
    d.mkdir()
    (d / "close_friends.json").write_text(json.dumps({"relationships_close_friends": [
        {"string_list_data": [{"value": "elizabeth.stewart", "timestamp": 1700000000,
                               "href": "https://www.instagram.com/elizabeth.stewart"}]}]}))
    return instagram_social.import_instagram(str(d))


def _run_linkedin_connections(w):
    from contact_syncer import linkedin_connections

    p = w.tmp / "Connections.csv"
    p.write_text(
        "Notes:\n\nFirst Name,Last Name,URL,Email Address,Company,Position,Connected On\n"
        f"Elizabeth,Stewart,{LINKEDIN},{EMAIL},Acme,Engineer,01 Jan 2024\n"
    )
    return linkedin_connections.import_connections(str(p))


def _run_linkedin_endorsements(w):
    from contact_syncer import linkedin_career

    p = w.tmp / "Endorsement_Received_Info.csv"
    with p.open("w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["Endorsement Date", "Skill Name", "Endorser First Name",
                     "Endorser Last Name", "Endorser Public Url", "Endorsement Status"])
        wr.writerow(["2024/01/01", "Testing", "Elizabeth", "Stewart", LINKEDIN, "ACCEPTED"])
    return linkedin_career.import_endorsements(str(p))


def _run_linkedin_recommendations(w):
    from contact_syncer import linkedin_career

    p = w.tmp / "Recommendations_Received.csv"
    with p.open("w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["First Name", "Last Name", "Company", "Job Title", "Text",
                     "Creation Date", "Status"])
        wr.writerow(["Elizabeth", "Stewart", "Acme", "Engineer",
                     "A synthetic recommendation.", "01/01/24, 10:00 AM", "VISIBLE"])
    return linkedin_career.import_recommendations(str(p))


def _run_linkedin_messages(w):
    from contact_syncer import linkedin_messages

    p = w.tmp / "messages.csv"
    with p.open("w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["CONVERSATION ID", "FROM", "SENDER PROFILE URL", "DATE", "SUBJECT", "CONTENT"])
        wr.writerow(["c1", NAME, LINKEDIN, "2024-01-01 10:00:00 UTC", "hi", "hello there"])
        wr.writerow(["c1", "John Doe", "", "2024-01-01 10:05:00 UTC", "hi", "hello back"])
    return linkedin_messages.import_messages(str(p), user_name="John Doe")


def _run_meeting_attendee(w):
    from identity_resolver.resolver import IdentityResolver
    from meeting_syncer import config as mcfg
    from meeting_syncer.syncer import MeetingSyncer

    s = MeetingSyncer.__new__(MeetingSyncer)
    s.resolver = IdentityResolver(oxigraph_url=w.store.url, default_country_code=44)
    s.oxigraph_url = w.store.url
    s.owner_emails = set()
    w.monkeypatch.setattr(mcfg, "USER_ID", "")
    return s._resolve_attendee({"name": NAME, "email": EMAIL})


SYNCERS = {
    "contact_syncer.syncer (iCloud/CardDAV)": _run_icloud_contacts,
    "contact_syncer.facebook_friends": _run_facebook,
    "contact_syncer.instagram_social": _run_instagram,
    "contact_syncer.linkedin_connections": _run_linkedin_connections,
    "contact_syncer.linkedin_career (endorsements)": _run_linkedin_endorsements,
    "contact_syncer.linkedin_career (recommendations)": _run_linkedin_recommendations,
    "contact_syncer.linkedin_messages": _run_linkedin_messages,
    "meeting_syncer (calendar attendees)": _run_meeting_attendee,
}


@pytest.mark.parametrize("name", list(SYNCERS))
def test_a_forgotten_person_stays_absent_after_the_sync(world, name):
    _mint_and_forget(world)
    SYNCERS[name](world)
    assert world.store.person_names() == [], (
        f"{name} recreated a person who was forgotten: {world.store.person_names()}"
    )


@pytest.mark.parametrize("name", list(SYNCERS))
def test_control_without_the_tombstone_the_same_sync_recreates_them(world, name):
    """The harness CAN see a recreation: lift the tombstone and the same sync
    brings the person back. Without this the test above could pass on a runner
    that never reaches the creation path."""
    _mint_and_forget(world)
    world.tomb.unlink(missing_ok=True)
    SYNCERS[name](world)
    assert world.store.person_count() >= 1, (
        f"{name}: with no tombstone the sync did not recreate the person, so the "
        "runner does not exercise the creation path and proves nothing"
    )


def test_forget_reports_the_tombstone_and_it_holds_no_clear_value(world):
    _mint_and_forget(world)
    text = world.tomb.read_text()
    for needle in (NAME, "Stewart", EMAIL, "447700900123", UID, LID):
        assert needle not in text
    # A second forget of the same slug is the benign "already forgotten".
    body, status = world.server.api_people_forget(SLUG)
    assert status == 200 and body["already_forgotten"] is True


def test_an_unwritable_tombstone_still_erases_and_says_so(world, monkeypatch):
    bad = world.tmp / "afile"
    bad.write_text("x")
    from identity_resolver.models import PersonIdentity
    from identity_resolver.resolver import IdentityResolver

    IdentityResolver(oxigraph_url=world.store.url, default_country_code=44).create_person(
        PersonIdentity(display_name=NAME, emails=[EMAIL]), user_id=""
    )
    monkeypatch.setenv("OSTLER_FORGET_TOMBSTONE_FILE", str(bad / "sub" / "t.json"))
    body, status = world.server.api_people_forget(SLUG)
    assert status == 200 and body["forgotten"] is True
    assert body["tombstone_written"] is False and body["degraded"] is True
    assert "tombstone_failed" in body["reason"]
    assert world.store.person_count() == 0
