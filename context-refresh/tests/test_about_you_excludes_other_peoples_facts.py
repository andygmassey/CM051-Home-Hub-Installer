"""walk 121 brief fix: the About-you section of the digest (the PRODUCT path,
generate_pwg_context.py _about_you_section) keeps a place or family fact only
when it is about the owner. A second person's fact, whether tagged
urn:ostler:user/<other id> or urn:ostler:person/<slug>, must be absent.
Synthetic only."""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

_SCRIPT = Path(__file__).resolve().parent.parent / "bin" / "generate_pwg_context.py"
OWNER_PLACE = "Jane Doe is based in Lisbon"
OWNER_FAMILY = "Jane Doe has a daughter Robin"
OTHER_PLACE = "John Smith is based in Oslo"
OTHER_FAMILY = "John Smith asked about sailing twice a week"
OTHER_PERSON = "Alex Jones is based in Quito"


def _row(text, t, about):
    return {"text": text, "t": t, "d": None, "l": None, "at": "2026-10-01T00:00:00Z", "about": about}


@pytest.fixture()
def about_text(monkeypatch, tmp_path):
    for k in ("USER_ID", "USER_NAME", "USER_EMAIL", "WIKI_OPERATOR_NAME", "WIKI_OPERATOR_EMAILS"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path / "none"))
    spec = importlib.util.spec_from_file_location("generate_pwg_context", _SCRIPT)
    g = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(g)
    rows = [
        _row(OWNER_PLACE, "location", "urn:ostler:user/jane"),
        _row(OWNER_FAMILY, "relationship", "urn:ostler:user/jane"),
        _row(OTHER_PLACE, "location", "urn:ostler:user/john"),
        _row(OTHER_FAMILY, "relationship", "urn:ostler:user/john"),
        _row(OTHER_PERSON, "location", "urn:ostler:person/alex-jones"),
    ]
    monkeypatch.setattr(g, "_owner_identity", lambda: {"user_id": "jane", "name": "Jane Doe", "emails": []})
    monkeypatch.setattr(g, "_get_json", lambda *a, **k: {})
    monkeypatch.setattr(g, "_owner_uris", lambda ident: [])
    monkeypatch.setattr(g, "_sparql_select", lambda q: rows if "urn:ostler:Fact" in q and "urn:ostler:about" in q else [])
    return "\n".join(g._about_you_section())


def test_owner_facts_present(about_text):
    assert OWNER_PLACE in about_text and OWNER_FAMILY in about_text


@pytest.mark.parametrize("other", [OTHER_PLACE, OTHER_FAMILY, OTHER_PERSON])
def test_second_persons_fact_is_absent(about_text, other):
    assert other not in about_text
