"""PARITY: reminders_push decides "is this a person" with the People list's
OWN predicates (imported from ical-server.py), so a record the Hub People
list hides as an organisation / automated sender never gets a reminder.

The oracle is people_list itself, run over the same synthetic records
through a faked Qdrant scroll. Synthetic data only.
"""
from __future__ import annotations

import importlib.util
import io
import json
import os
import sys
import types
import typing
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm048_pipeline"))
os.environ.setdefault("OSTLER_SERVICE_TOKEN", "test-only-parity-token")

from src import reminders_push  # noqa: E402

SERVER = ROOT / "vendor" / "cm041" / "assistant_api" / "ical-server.py"


def _server():
    """The ORACLE: the real ical-server module, fully imported (people_list
    and all). reminders_push itself loads only the rules, from the file."""
    import importlib.util

    spec = importlib.util.spec_from_file_location("_oracle_ical_server", SERVER)
    mod = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(SERVER.parent))
    try:
        spec.loader.exec_module(mod)
    finally:
        sys.path.remove(str(SERVER.parent))
    return mod


# (label, payload). True = the People list shows it as a person.
RECORDS = [
    ("jane",   {"display_name": "Jane Doe", "given_name": "Jane", "family_name": "Doe",
                "icloud_uid": "card-1", "phones": ["+15550101"]}),
    ("john",   {"display_name": "John Doe", "given_name": "John", "family_name": "Roe",
                "phones": ["+15550102"]}),
    ("bank",   {"display_name": "example bank support team", "emails": ["noreply@bank.invalid"]}),
    ("org",    {"display_name": "example holdings ltd", "emails": ["hello@example.invalid"]}),
    ("sender", {"display_name": "EXAMPLEBANK", "phones": ["EXAMPLEBANK"]}),
    ("alerts", {"display_name": "Payment declined - update required",
                "emails": ["alerts@example.invalid"]}),
    ("bare",   {"display_name": "+15550103", "phones": ["+15550103"]}),
    ("role",   {"display_name": "support@example.invalid", "emails": ["support@example.invalid"]}),
]


class _Resp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _listed_names(srv, monkeypatch):
    points = [{"id": i, "payload": dict(p, person_uri=f"urn:p:{i}")}
              for i, (_, p) in enumerate(RECORDS)]
    body = json.dumps({"result": {"points": points, "next_page_offset": None}}).encode()
    monkeypatch.setattr(srv.urllib.request, "urlopen", lambda *a, **k: _Resp(body))
    monkeypatch.setattr(srv, "_sparql_select", lambda *a, **k: [])
    monkeypatch.setattr(srv, "_load_people_list_self_uris", lambda: set())
    return {r["name"] for r in srv.people_list()["people"]}


def test_push_gate_agrees_with_people_list_on_every_record(monkeypatch):
    monkeypatch.setattr(reminders_push, "_PEOPLE_TRIED", False)
    monkeypatch.setattr(reminders_push, "_PEOPLE_RULES", None)
    srv = _server()
    listed = _listed_names(srv, monkeypatch)
    verdicts = {}
    for label, payload in RECORDS:
        name = reminders_push._record_name(payload)
        verdicts[label] = reminders_push.is_listed_as_a_person(payload, name)
        shown = any(
            n == name or n == " ".join(
                x for x in (payload.get("given_name"), payload.get("family_name")) if x)
            for n in listed
        )
        assert verdicts[label] is shown, (label, name, verdicts[label], sorted(listed))
    # anti-vacuity: the table has both outcomes, so agreement is not trivial
    assert True in verdicts.values() and False in verdicts.values(), verdicts


def test_the_predicates_are_imported_not_copied():
    src = Path(reminders_push.__file__).read_text()
    for needle in ("_is_non_human_person", "_is_organisation_name", "_is_nameless_name"):
        assert f"srv.{needle}" in src, needle
    # and the module it calls is the SAME file ical-server.py imports from
    assert "from people_rules import" in SERVER.read_text()
    # no local re-definition of the People list rule
    assert "def _is_non_human_person" not in src
    assert "_ORG_STRONG_RE" not in src
