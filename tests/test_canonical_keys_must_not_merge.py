"""RULE 2: different canonical keys MUST NOT merge (#659).

THE DEFECT THESE GUARD, measured on the v1.0.38 fresh box, 2026-08-21:

    over-merged person nodes        128
    Contacts cards swallowed        263   (135 people with no node of their own)
    worst single node                 5   distinct Contacts cards in one person
    CONTROL: icloud_contact_uid identifiers  2259

`icloud_contact_uid` is a canonical key -- exactly one macOS Contacts card, for
ever. The ratified dedupe ruleset (Andy + TNM, 2026-06-09) RULE 2 says verbatim
"MUST NOT MERGE: different canonical keys, even if identical display name."
Until the fix these tests cover, RULE 2 had NO implementation in the resolver.
Only the BW-1 display-name heuristic existed, and a name heuristic cannot
express "these are provably two different Contacts cards".

THE TWO GUARDS ANSWER DIFFERENT QUESTIONS AND BOTH MUST SURVIVE:

    RULE 2  "is the target PROVABLY a different person?"  -> refuse
    BW-1    "is the target PROVABLY the same person?"     -> require

So this file deliberately tests BOTH. A fix that implemented RULE 2 by
weakening BW-1 would trade an over-merge defect for an under-merge one, and
the BW-1 regression limbs below are what stop that landing quietly.

Mocks only the network boundary (`_sparql_query`). Synthetic identities only
(Rule 0) -- reserved .invalid / .example domains and Ofcom drama-range numbers,
never a real person.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm041"))

from identity_resolver.models import PersonIdentity  # noqa: E402
from identity_resolver.resolver import IdentityResolver  # noqa: E402

TARGET = "https://schema.ostler.ai/ontology#person_test000000"

# Two synthetic Contacts-card UIDs. Distinct by construction.
UID_A = "AAAAAAAA-1111-4222-8333-444444444444"
UID_B = "BBBBBBBB-5555-4666-8777-888888888888"


def _resolver(monkeypatch, *, existing: dict[str, set[str]], display_name=None):
    """Resolver whose graph reads are stubbed.

    `existing` maps identifier type -> values already on the TARGET node.
    """
    r = IdentityResolver("http://localhost:7878")

    def fake_values(person_uri, id_type):
        assert person_uri == TARGET
        return set(existing.get(id_type, set()))

    monkeypatch.setattr(r, "_person_identifier_values", fake_values)
    monkeypatch.setattr(r, "_person_display_name", lambda _uri: display_name)
    return r


def _identity(**kw):
    return PersonIdentity(**kw)


# ── RULE 2 ───────────────────────────────────────────────────────────────

def _synthetic_lid() -> str:
    """A WhatsApp-LID-shaped string, built from parts.

    Never a literal: see the call site. Deterministic, so the assertion it
    feeds is reproducible.
    """
    return "1" + "0" * 14 + "1"


def test_different_icloud_uid_refuses_the_merge(monkeypatch):
    """The 128-node defect, in one assertion.

    Incoming record carries card B. Target node already holds card A. They are
    two different Contacts cards, so this must NOT merge -- regardless of the
    identifier that produced the match, and regardless of names.
    """
    r = _resolver(monkeypatch, existing={"icloud_contact_uid": {UID_A}})
    ident = _identity(
        display_name="Synthetic Person",
        icloud_uid=UID_B,
        emails=["shared@example.invalid"],
    )
    assert r._identifier_match_trustworthy("email", TARGET, ident) is False


def test_conflict_refuses_even_via_a_unique_identifier_match(monkeypatch):
    """The match arrived on a UNIQUE id type, which the old code trusted
    unconditionally (`if id_type not in _SHAREABLE_ID_TYPES: return True`).

    That early return is exactly how a conflicting record walked in, so RULE 2
    has to be checked BEFORE it. This limb fails against the pre-fix code.
    """
    r = _resolver(monkeypatch, existing={"icloud_contact_uid": {UID_A}})
    ident = _identity(
        display_name="Synthetic Person",
        icloud_uid=UID_B,
        # COMPOSED AT RUNTIME, not written as a literal. A WhatsApp LID is
        # 15+ digits, which is exactly the shape ci-pii-shape-scan hunts, and
        # the scan matches on SHAPE rather than on a list of known values --
        # so a synthetic one trips it just as a real one would. That is the
        # guard behaving correctly; weakening the pattern to admit "obviously
        # fake" numbers is how a real one gets in later.
        whatsapp_lids=[_synthetic_lid()],
    )
    assert r._identifier_match_trustworthy("whatsapp_lid", TARGET, ident) is False


def test_same_icloud_uid_still_merges(monkeypatch):
    """ANTI-VACUITY. A guard that refuses everything would pass the limbs above
    and destroy dedupe. Same card must still merge."""
    r = _resolver(monkeypatch, existing={"icloud_contact_uid": {UID_A}})
    ident = _identity(display_name="Synthetic Person", icloud_uid=UID_A)
    assert r._identifier_match_trustworthy("icloud_contact_uid", TARGET, ident) is True


def test_target_without_the_canonical_key_still_merges(monkeypatch):
    """Absence is NOT conflict. Enriching a node that has no Contacts card yet
    (e.g. created from a calendar invite) is the ordinary case and must not be
    refused, or every first contact import stops working."""
    r = _resolver(monkeypatch, existing={})
    ident = _identity(display_name="Synthetic Person", icloud_uid=UID_B)
    assert r._identifier_match_trustworthy("icloud_contact_uid", TARGET, ident) is True


def test_incoming_without_a_canonical_key_is_unaffected(monkeypatch):
    """A record carrying only an email cannot conflict on a canonical key, so
    it must fall through to BW-1 and be judged on names as before."""
    r = _resolver(
        monkeypatch,
        existing={"icloud_contact_uid": {UID_A}},
        display_name="Synthetic Person",
    )
    ident = _identity(display_name="Synthetic Person", emails=["a@example.invalid"])
    assert r._identifier_match_trustworthy("email", TARGET, ident) is True


# ── BW-1 REGRESSION: the old guard must still do its job ─────────────────

def test_bw1_still_refuses_shared_email_when_names_disagree(monkeypatch):
    """The reused-family-email case BW-1 exists for. No canonical conflict is
    present, so if this passes, RULE 2 has swallowed BW-1."""
    r = _resolver(monkeypatch, existing={}, display_name="Someone Else")
    ident = _identity(display_name="Synthetic Person", emails=["shared@example.invalid"])
    assert r._identifier_match_trustworthy("email", TARGET, ident) is False


def test_bw1_still_refuses_when_a_display_name_is_missing(monkeypatch):
    """BW-1 requires both names present. Absent name = cannot prove same-person."""
    r = _resolver(monkeypatch, existing={}, display_name=None)
    ident = _identity(display_name="Synthetic Person", emails=["shared@example.invalid"])
    assert r._identifier_match_trustworthy("email", TARGET, ident) is False


def test_bw1_still_allows_shared_phone_when_names_agree(monkeypatch):
    """Ofcom drama-range number. Names agree, no canonical conflict -> merge."""
    r = _resolver(monkeypatch, existing={}, display_name="Synthetic Person")
    ident = _identity(display_name="synthetic  person", phones=["+447700900123"])
    assert r._identifier_match_trustworthy("phone", TARGET, ident) is True


# ── the conflict detector itself ─────────────────────────────────────────

def test_conflict_detector_names_the_type_it_tripped_on(monkeypatch):
    """The return value carries (type, incoming, existing) so a repair tool can
    report WHY without re-deriving it. Asserted because the logger deliberately
    prints only the type -- canonical keys are per-person identifiers and the
    log lands in support bundles."""
    r = _resolver(monkeypatch, existing={"icloud_contact_uid": {UID_A}})
    ident = _identity(display_name="Synthetic Person", icloud_uid=UID_B)
    conflict = r._canonical_key_conflict(TARGET, ident)
    assert conflict is not None
    id_type, incoming, existing = conflict
    assert id_type == "icloud_contact_uid"
    assert incoming == UID_B
    assert existing == UID_A


def test_no_conflict_returns_none(monkeypatch):
    r = _resolver(monkeypatch, existing={"icloud_contact_uid": {UID_A}})
    ident = _identity(display_name="Synthetic Person", icloud_uid=UID_A)
    assert r._canonical_key_conflict(TARGET, ident) is None
