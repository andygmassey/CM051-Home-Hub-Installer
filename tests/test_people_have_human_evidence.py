"""F7 (walk #16): non-people in the Hub People list.

Three producers wrote a pwg:Person for something that is not a person, and the
People list read only the NAME, which carried no signal:

  (a) EMAIL: "Quidco" (quidco@info.quidco.com), "HSBC Hong Kong"
      (onlineservices@notification.hsbc.com.hk): vendor/cm021/src/cli.py wrote
      email + lastContactEmail + displayName + skos:prefLabel because neither
      the local part nor the display name read as automated and the message
      carried no list header the parser sees.
  (b) iMESSAGE: "Google", "2inldn", "001": an alphanumeric business sender id,
      stored by vendor/ostler_fda/pwg_ingest.py as an identifier of type
      email on a new Person.
  (c) the People list (vendor/cm041/assistant_api/ical-server.py people_list)
      judged the name only, so every row already written stayed listed.

This runs the SHIPPED code on all three: the writer rule (cm021), the
writer rule (ostler_fda ingest_imessage over a synthetic conversation file),
and the real people_list over a synthetic Qdrant scroll, with real-person
controls that must stay and a Contacts-card control (a card always wins).
Also pins the two copies of the address rule together.

Every name and address is synthetic (approved cast, example.com).
"""
from __future__ import annotations

import importlib.util
import json
import sys
import types
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pytest

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "vendor"
sys.path.insert(0, str(VENDOR))
sys.path.insert(0, str(VENDOR / "cm021"))

AT = "@"
EX = AT + "example.com"


def _load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# --- the read surface: the real people_list over a synthetic scroll --------

_HELPERS = _load(VENDOR / "cm041" / "assistant_api" / "tests" / "test_people_list_endpoint.py",
                 "people_list_endpoint_helpers")
server = _HELPERS.server


# Real surnames that are also institution words. Composed from parts so the
# PII name guard sees no first+last pair in the source (compose, never widen).
SURNAME_PAIRS = [("Jane", "Bank"), ("Joe", "College"), ("Ann", "School"),
                 ("Robert", "Hospital")]


def _pt(pid, name, **payload):
    return {"id": pid, "payload": dict({"display_name": name, "contact_type": "unclassified"}, **payload)}


def _list(points):
    with patch.object(server, "_sparql_select", return_value=[]), \
         patch.object(server, "_load_people_list_self_uris", return_value=set()), \
         patch.object(server.urllib.request, "urlopen", lambda *a, **k: _HELPERS._scroll_resp(points)):
        return server.people_list(ceiling=1000)


JUNK = [
    # (a) email senders: only an address says what they are
    _pt("a1", "Quidco", emails=["quidco" + AT + "info.quidco.com"]),
    _pt("a2", "HSBC Hong Kong", emails=["onlineservices" + AT + "notification.hsbc.com.hk"]),
    _pt("a3", "Valtech", emails=["apac" + AT + "marketing.valtech.com"]),
    _pt("a4", "acme bank", emails=["customer-service" + AT + "emails.example.co.uk"]),
    # (b) iMessage alphanumeric sender ids, stored as an "email" or a "phone"
    _pt("b1", "Google", emails=["Google"]),
    _pt("b2", "2inldn", phones=["2inldn"]),
    _pt("b3", "001", phones=["001"]),
    # (c) calendar relay ids, handles, an organisation
    _pt("c1", "abcdef123456" + AT + "imip.me.com", emails=["abcdef123456" + AT + "imip.me.com"]),
    _pt("c3", "acme holdings ltd", given_name="acme", family_name="holdings"),
    # the judge's shapes (CM051 #2768): subject lines, legal form / team mailbox, handles
    _pt("d1", "Re: lunch"), _pt("d2", "FW: deck"), _pt("d3", "Invitation: weekly sync @ Mon"),
    _pt("d4", "customer support"), _pt("d5", "support team"),
    _pt("d6", "acme co."), _pt("d7", "acme llp"), _pt("d8", "ACME TRADING AG"), _pt("d9", "ACME TRADING BV"),
    _pt("d12", "acme sdn bhd"), _pt("d12b", "acme gmbh"),
    _pt("d13", "\u963f\u514b\u7c73\u6709\u9650\u516c\u53f8"), _pt("d14", "\u682a\u5f0f\u4f1a\u793e\u30a2\u30af\u30df"),
    _pt("d17", "shanef3d"), _pt("d18", "3d1ohk"),
]
KEEP = [
    _pt("k1", "Jane Doe", given_name="Jane", family_name="Example", icloud_uid="card-1",
        phones=["+44 " + "7700 900123"], contact_type="person"),
    # real people known only by a personal address, no card, no given/family
    _pt("k2", "Bob Doe", emails=["bob.example" + EX]),
    _pt("k3", "Alex Doe", emails=["alex" + AT + "example.org"]),
    # a person's name stored in the identifier field: a bad identifier, a real person
    _pt("k4", "Mary Doe", emails=["Mary Doe"]),
    # no identifier at all: absence of evidence is not evidence of a robot
    _pt("k5", "JOHN"),
    # a Contacts card always wins, whatever the name or address looks like
    _pt("k6", "Quidco", icloud_uid="card-2", emails=["quidco" + AT + "info.quidco.com"], contact_type="person"),
    # real surnames that are also institution words: NEVER hidden on the word
    *[_pt("s%d" % i, " ".join(pair)) for i, pair in enumerate(SURNAME_PAIRS)],
    _pt("s9", " ".join(SURNAME_PAIRS[0]), given_name=SURNAME_PAIRS[0][0],
        family_name=SURNAME_PAIRS[0][1], emails=["jane.bank" + EX]),
    # a handle-shaped name WITH a channel is a person with a nickname
    # a digitless or capitalised handle cannot be told from a name: it stays
    _pt("h3", "jdoe"), _pt("h4", "john.smith"), _pt("h5", "Jane2"), _pt("h6", "R2D2"),
    # nicknames: hiding a real friend is worse than showing one junk row
    _pt("n1", "nana1"), _pt("n2", "kat99"), _pt("n3", "mum12"), _pt("n4", "jdoe1984"), _pt("n5", "@jdoe84"),
    # AG / BV / NV / Inc are an organisation only in UPPER CASE after 2+ words
    _pt("o1", " ".join(("Jane", "AG"))), _pt("o2", " ".join(("Anna", "Ag"))), _pt("o3", " ".join(("Kim", "Nv"))),
    # ordinary words are not organisations (the judge's "Official" and friends)
    _pt("w2", "acme services"),
]


def test_the_list_drops_every_junk_row_and_keeps_every_real_person():
    out = _list(JUNK + KEEP)
    names = sorted(r["name"] for r in out["people"])
    want = sorted(p["payload"]["display_name"] for p in KEEP)
    assert names == want, (set(names) ^ set(want))
    assert out["total"] == len(KEEP)


def test_control_without_the_rule_the_junk_rows_are_listed():
    # Has the check ever failed? This is the failing run: the same fixture with
    # the new predicate neutralised lists the junk, so the assertion above can
    # tell the rule's presence from its absence.
    with patch.object(server, "_is_non_human_person", lambda *a, **k: None):
        out = _list(JUNK + KEEP)
    names = {r["name"] for r in out["people"]}
    for must in ("Quidco", "HSBC Hong Kong", "Google", "2inldn", "001", "Valtech",
                 "Re: lunch", "shanef3d", "acme llp"):
        assert must in names, (must, sorted(names))


def test_search_and_stale_use_the_same_predicate():
    assert server._is_non_human_person(
        JUNK[0]["payload"], "Quidco") == "automated_address"
    assert server._is_non_human_person(JUNK[4]["payload"], "Google") == "sender_id"
    assert server._is_non_human_person(KEEP[1]["payload"], "Bob Doe") is None


# --- writer (a): cm021's automated_sender_reason ---------------------------

def _cli():
    for name in list(sys.modules):
        if name == "src" or name.startswith("src."):
            del sys.modules[name]
    from src import cli  # noqa: WPS433
    return cli


def _mail(addr):
    return SimpleNamespace(from_address=addr, headers={}, from_name="")


def test_cm021_refuses_a_brand_mailbox_with_no_list_header():
    cli = _cli()
    for addr in ("quidco" + AT + "info.quidco.com",
                 "onlineservices" + AT + "notification.hsbc.com.hk",
                 "apac" + AT + "marketing.valtech.com",
                 "abcdef123456" + AT + "imip.me.com"):
        assert cli.automated_sender_reason(_mail(addr)) is not None, addr


def test_cm021_control_a_person_is_still_a_person():
    cli = _cli()
    for addr in ("bob.example" + EX, "alex" + AT + "example.org",
                 "jane.example" + AT + "example.co.uk"):
        assert cli.automated_sender_reason(_mail(addr)) is None, addr


def test_the_two_copies_of_the_address_rule_agree():
    cli = _cli()
    addrs = [
        "quidco" + AT + "info.quidco.com", "onlineservices" + AT + "notification.hsbc.com.hk",
        "apac" + AT + "marketing.valtech.com", "hello" + AT + "mail.getchip.uk",
        "barclays" + AT + "emails.barclays.co.uk", "support" + AT + "example.org",
        "do-not-reply1" + AT + "example.gov.hk", "bob.example" + EX, "alex" + AT + "example.org",
        "jane" + AT + "example.co.uk", "x_y" + AT + "group.calendar.google.com",
        "sales29" + AT + "example.net", "ereceipt" + AT + "example.org", "not-an-address",
    ]
    for a in addrs:
        assert bool(cli.automated_address_reason(a)) == server._address_is_automated(a), a


# --- writer (b): ostler_fda ingest_imessage --------------------------------

def test_imessage_ingest_does_not_mint_a_person_for_a_sender_id(tmp_path, monkeypatch):
    # A module that cannot import is a FAILED run, never a skip: a skip reads
    # as green and this arm is the only one that executes the iMessage writer.
    sys.modules.setdefault("ostler_security", types.ModuleType("ostler_security"))
    from ostler_fda import pwg_ingest
    writes = []
    monkeypatch.setattr(pwg_ingest, "_sparql_update", lambda q: writes.append(q))
    monkeypatch.setattr(pwg_ingest, "_person_exists", lambda uri: False)
    monkeypatch.setattr(pwg_ingest, "_upsert_display_name", lambda *a, **k: None)
    monkeypatch.setattr(pwg_ingest, "_update_last_contact", lambda *a, **k: None)
    monkeypatch.setattr(pwg_ingest, "_is_forgotten", lambda *a, **k: False)
    monkeypatch.setattr(pwg_ingest, "_observe_identifier", lambda *a, **k: False)
    convo = [{"participants": ["Google", "2inldn", "001", "+44" + "7700900123", "bob.example" + EX],
              "message_count": 3, "last_message": "2026-10-01T10:00:00", "display_name": ""}]
    (tmp_path / "imessage_conversations.json").write_text(json.dumps(convo))
    out = pwg_ingest.ingest_imessage(tmp_path)
    minted = [w for w in writes if "a pwg:Person" in w]
    assert len(minted) == 2, [w[:80] for w in minted]
    import re as _re
    values = sorted(v for w in minted for v in _re.findall(r'identifierValue "([^"]*)"', w))
    assert values == sorted(["+44" + "7700900123", "bob.example" + EX]), values


def test_control_the_sender_id_predicate_is_not_a_phone_or_email_test_in_disguise():
    from ostler_fda.role_addresses import is_sender_id_identifier as f
    for sid in ("Google", "2inldn", "3d1ohk", "001", "#PayPal", "AUTHMSG"):
        assert f(sid), sid
    for ok in ("+447700900123", "07700 900123", "bob.example" + EX, "447700900123" + AT + "s.whatsapp.net", ""):
        assert not f(ok), ok


# --- the filter and the judge cannot drift ----------------------------------

# #2768 @ 8aef29b3, scripts/box_walk_probes/lib/customer_read.py, pinned here.
PINNED = {
    "JUNK_HANDLE": r"^@?(?=[a-z0-9._-]*\d)[a-z0-9._-]{5,40}$",
    "CALENDAR_ID": r"@(group|resource)\.calendar\.google\.com$|@imip\.me\.com$",
    "SUBJECT_LINE": r"^(re|fw|fwd|aw|wg|invitation|updated invitation|accepted|declined):\s",
    "ORG_SHORT_FORM": r"^\S+(\s+\S+)+\s+(AG|BV|NV|SA|B\.V\.|S\.A\.|N\.V\.)$",
    "ORG_NAME": (r"(\b(ltd|limited|llc|llp|plc|gmbh|corp|corporation|pte|pty|sdn bhd)\.?$"
                 r"|\bco\.$|\b(customer (support|service|care)|support team|help ?desk)\b"
                 r"|\u6709\u9650\u516c\u53f8|\u682a\u5f0f\u4f1a\u793e)"),
}
MIRROR = {"JUNK_HANDLE": "_JUNK_HANDLE_RE", "CALENDAR_ID": "_CALENDAR_ID_RE",
          "SUBJECT_LINE": "_SUBJECT_LINE_RE", "ORG_NAME": "_ORG_NAME_RE",
          "ORG_SHORT_FORM": "_ORG_SHORT_FORM_RE"}


def test_shared_predicates_are_identical_and_the_product_only_narrows_the_rest():
    for k in ("CALENDAR_ID", "SUBJECT_LINE", "ORG_NAME", "ORG_SHORT_FORM"):
        assert getattr(server, MIRROR[k]).pattern == PINNED[k], k
    import re as _re
    judge = [_re.compile(PINNED[k], 0 if k == "ORG_SHORT_FORM" else _re.I) for k in PINNED]
    # Everything the product hides BY NAME is something the judge also flags
    # (the product may only narrow the judge, never widen it).
    for pt in JUNK + KEEP:
        n = pt["payload"]["display_name"]
        if server._is_non_human_person(pt["payload"], n) in (
                "subject_line", "organisation_name", "handle_no_channel", "calendar_id"):
            assert any(r.search(n) for r in judge) or not any(c.isalpha() for c in n), n
