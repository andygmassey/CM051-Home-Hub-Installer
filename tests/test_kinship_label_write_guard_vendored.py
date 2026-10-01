"""CM051 #2556: a bare kinship word ("Mum", "Wife", "Dad") must never become
a person's permanent displayName at ANY name-writer, in the copy that
actually ships (vendor/cm041), not merely in CM041 source.

Mirrors CM041 PR #185's own test suite 1:1 -- see that PR for the full
rationale per site. Routes every write site through the ALREADY-VENDORED-
HERE ``is_relationship_label`` (vendor/cm041/contact_syncer/
relationship_labels.py, added by this same change) rather than a new
predicate.

NEGATIVE CONTROL, as specified: matches the WHOLE label only. "Mum Zhang"
is plausibly a real name and must NOT be refused.

All identifiers/URIs here are synthetic (Rule 0): no real personal data.
"""
from __future__ import annotations

import pathlib
import sys
from unittest.mock import MagicMock

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR_CM041 = ROOT / "vendor" / "cm041"
if not VENDOR_CM041.is_dir():
    raise SystemExit(f"vendored cm041 missing: {VENDOR_CM041} (broken vendor layout)")
sys.path.insert(0, str(VENDOR_CM041))

from identity_resolver.models import PersonIdentity  # noqa: E402
from identity_resolver.resolver import IdentityResolver  # noqa: E402

KINSHIP = "Mum"
REAL_NAME_CONTAINING_KINSHIP_WORD = "Mum Zhang"

OX = "http://localhost:7878"


def _wire_update(monkeypatch, module):
    sent = []
    monkeypatch.setattr(module, "_sparql_update", lambda url, sparql: sent.append(sparql))
    return sent


# ---------------------------------------------------------------------------
# instagram_social.py / facebook_friends.py / linkedin_connections.py
# ---------------------------------------------------------------------------

def test_instagram_kinship_label_is_refused(monkeypatch):
    from contact_syncer import instagram_social as m
    sent = _wire_update(monkeypatch, m)
    m.create_person_oxigraph(
        OX, "https://example.invalid/p/1", "p1",
        PersonIdentity(display_name=KINSHIP), "insta_handle",
        "https://instagram.example/insta_handle", "user1", "L2",
    )
    assert len(sent) == 1
    assert 'pwg:displayName ""' in sent[0]


def test_instagram_real_name_containing_kinship_word_is_allowed(monkeypatch):
    from contact_syncer import instagram_social as m
    sent = _wire_update(monkeypatch, m)
    m.create_person_oxigraph(
        OX, "https://example.invalid/p/1", "p1",
        PersonIdentity(display_name=REAL_NAME_CONTAINING_KINSHIP_WORD), "insta_handle",
        "https://instagram.example/insta_handle", "user1", "L2",
    )
    assert f'pwg:displayName "{REAL_NAME_CONTAINING_KINSHIP_WORD}"' in sent[0]


def test_facebook_kinship_label_is_refused(monkeypatch):
    from contact_syncer import facebook_friends as m
    sent = _wire_update(monkeypatch, m)
    m.create_person_oxigraph(
        OX, "https://example.invalid/p/2", "p2",
        PersonIdentity(display_name=KINSHIP), {}, "user1", "L2",
    )
    assert len(sent) == 1
    assert 'pwg:displayName ""' in sent[0]


def test_facebook_real_name_containing_kinship_word_is_allowed(monkeypatch):
    from contact_syncer import facebook_friends as m
    sent = _wire_update(monkeypatch, m)
    m.create_person_oxigraph(
        OX, "https://example.invalid/p/2", "p2",
        PersonIdentity(display_name=REAL_NAME_CONTAINING_KINSHIP_WORD), {}, "user1", "L2",
    )
    assert f'pwg:displayName "{REAL_NAME_CONTAINING_KINSHIP_WORD}"' in sent[0]


def test_linkedin_connections_kinship_label_is_refused(monkeypatch):
    from contact_syncer import linkedin_connections as m
    sent = _wire_update(monkeypatch, m)
    m.create_person_oxigraph(
        OX, "https://example.invalid/p/3", "p3",
        PersonIdentity(display_name=KINSHIP), {}, "user1", "L2",
    )
    assert len(sent) == 1
    assert 'pwg:displayName ""' in sent[0]


def test_linkedin_connections_real_name_containing_kinship_word_is_allowed(monkeypatch):
    from contact_syncer import linkedin_connections as m
    sent = _wire_update(monkeypatch, m)
    m.create_person_oxigraph(
        OX, "https://example.invalid/p/3", "p3",
        PersonIdentity(display_name=REAL_NAME_CONTAINING_KINSHIP_WORD), {}, "user1", "L2",
    )
    assert f'pwg:displayName "{REAL_NAME_CONTAINING_KINSHIP_WORD}"' in sent[0]


# ---------------------------------------------------------------------------
# linkedin_career.py
# ---------------------------------------------------------------------------

def test_linkedin_career_endorser_kinship_label_is_refused(monkeypatch):
    from contact_syncer import linkedin_career as m
    sent = _wire_update(monkeypatch, m)
    m._create_person_from_endorser(
        OX, "https://example.invalid/p/4", "p4",
        KINSHIP, "", "", "https://linkedin.example/endorser", "user1",
    )
    assert len(sent) == 1
    assert 'pwg:displayName ""' in sent[0]


def test_linkedin_career_endorser_real_name_containing_kinship_word_is_allowed(monkeypatch):
    from contact_syncer import linkedin_career as m
    sent = _wire_update(monkeypatch, m)
    m._create_person_from_endorser(
        OX, "https://example.invalid/p/4", "p4",
        REAL_NAME_CONTAINING_KINSHIP_WORD, "", "", "https://linkedin.example/endorser", "user1",
    )
    assert f'pwg:displayName "{REAL_NAME_CONTAINING_KINSHIP_WORD}"' in sent[0]


# ---------------------------------------------------------------------------
# owner_node.py -- builds and RETURNS a SPARQL string.
# ---------------------------------------------------------------------------

def test_owner_node_kinship_label_is_refused_and_skips_the_name_clause_entirely():
    from contact_syncer import owner_node as m
    sparql = m.build_owner_sparql(
        user_id="andy", display_name=KINSHIP, now_iso="2026-01-01T00:00:00+00:00",
    )
    assert "pwg:displayName" not in sparql


def test_owner_node_real_name_containing_kinship_word_is_allowed():
    from contact_syncer import owner_node as m
    sparql = m.build_owner_sparql(
        user_id="andy", display_name=REAL_NAME_CONTAINING_KINSHIP_WORD,
        now_iso="2026-01-01T00:00:00+00:00",
    )
    assert f'pwg:displayName "{REAL_NAME_CONTAINING_KINSHIP_WORD}"' in sparql


# ---------------------------------------------------------------------------
# syncer.py -- create and update
# ---------------------------------------------------------------------------

def _make_syncer():
    from contact_syncer.syncer import ContactSyncer
    syncer = ContactSyncer.__new__(ContactSyncer)
    cfg = MagicMock()
    cfg.DEFAULT_PRIVACY_LEVEL = "L2"
    cfg.USER_ID = None
    cfg.DEFAULT_COUNTRY_CODE = 44
    syncer.cfg = cfg
    syncer._captured_sparql = []
    syncer._sparql_update = lambda sparql: syncer._captured_sparql.append(sparql)
    syncer._identifier_exists = lambda *a, **k: False
    return syncer


def _parsed(fn):
    return {"fn": fn, "given_name": "", "family_name": "", "emails": [], "phones": []}


def test_syncer_create_kinship_label_is_refused():
    syncer = _make_syncer()
    syncer._create_person_oxigraph(
        "https://example.invalid/p/create1", "p_create1", _parsed(KINSHIP), "person",
    )
    assert 'pwg:displayName ""' in "\n".join(syncer._captured_sparql)


def test_syncer_create_real_name_containing_kinship_word_is_allowed():
    syncer = _make_syncer()
    syncer._create_person_oxigraph(
        "https://example.invalid/p/create2", "p_create2",
        _parsed(REAL_NAME_CONTAINING_KINSHIP_WORD), "person",
    )
    assert f'pwg:displayName "{REAL_NAME_CONTAINING_KINSHIP_WORD}"' in "\n".join(syncer._captured_sparql)


def test_syncer_update_incoming_kinship_label_does_not_blank_the_existing_name():
    syncer = _make_syncer()
    syncer._update_person_oxigraph(
        "https://example.invalid/p/update1", _parsed(KINSHIP), "person",
    )
    assert "pwg:displayName" not in "\n".join(syncer._captured_sparql)


def test_syncer_update_real_name_containing_kinship_word_is_allowed():
    syncer = _make_syncer()
    syncer._update_person_oxigraph(
        "https://example.invalid/p/update2",
        _parsed(REAL_NAME_CONTAINING_KINSHIP_WORD), "person",
    )
    sent = "\n".join(syncer._captured_sparql)
    assert f'pwg:displayName "{REAL_NAME_CONTAINING_KINSHIP_WORD}"' in sent


# ---------------------------------------------------------------------------
# identity_resolver/resolver.py -- create_person
# ---------------------------------------------------------------------------

def test_resolver_create_person_kinship_label_is_refused(monkeypatch):
    monkeypatch.delenv("USER_ID", raising=False)
    resolver = IdentityResolver(OX)
    captured = []
    monkeypatch.setattr(resolver, "_sparql_update", lambda s: captured.append(s))
    resolver.create_person(PersonIdentity(display_name=KINSHIP), user_id="jane")
    assert len(captured) == 1
    assert 'displayName> ""' in captured[0]


def test_resolver_create_person_real_name_containing_kinship_word_is_allowed(monkeypatch):
    monkeypatch.delenv("USER_ID", raising=False)
    resolver = IdentityResolver(OX)
    captured = []
    monkeypatch.setattr(resolver, "_sparql_update", lambda s: captured.append(s))
    resolver.create_person(
        PersonIdentity(display_name=REAL_NAME_CONTAINING_KINSHIP_WORD), user_id="jane",
    )
    assert len(captured) == 1
    assert f'displayName> "{REAL_NAME_CONTAINING_KINSHIP_WORD}"' in captured[0]
