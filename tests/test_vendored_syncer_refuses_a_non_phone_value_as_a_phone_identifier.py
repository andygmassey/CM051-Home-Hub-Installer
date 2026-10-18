"""CM051 walk-defect D (v1.0.107): a cold-install walk found 8 of 3,307 phone
identifiers on the box were exactly 14 digits -- a WhatsApp-LID/internal-id
shape, never a phone number -- all on contact_syncer-minted person_<hex12>
URIs. This tests the copy that actually SHIPS (vendor/cm041), not CM041
source -- mirrors CM041 PR #186's own test suite.

ROOT CAUSE: normalise_phone() is a best-effort FORMATTER, not a validator --
when phonenumbers cannot parse/validate a value it returns the ORIGINAL
STRING UNCHANGED, so a vCard "phone" field holding a LID/internal-id sailed
straight through into identifierType "phone" with no separate validity
check at this file's three phone-writing sites.

FIX: gate every write on is_possible_phone (vendor/cm041/identity_resolver/
normalise.py, added by this same change) -- NOT the stricter is_valid_phone,
which rejects numbers in ranges libphonenumber has not catalogued as
assigned, including this repo's own OFCOM drama-reserved test fixture
(+44 7700 900200). See WRITER_READER_MISMATCHES.UNRECORDED.md's
cm041/identity_resolver entry for the measured is_valid_phone False / is_
possible_phone True distinction.

All identifiers/URIs/numbers here are synthetic or OFCOM-reserved (Rule 0).
"""
from __future__ import annotations

import pathlib
import sys
from typing import Any, Dict, List
from unittest.mock import MagicMock

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR_CM041 = ROOT / "vendor" / "cm041"
if not VENDOR_CM041.is_dir():
    raise SystemExit(f"vendored cm041 missing: {VENDOR_CM041} (broken vendor layout)")
sys.path.insert(0, str(VENDOR_CM041))

from contact_syncer.syncer import ContactSyncer  # noqa: E402

# A WhatsApp LID / internal-id shape: 14 digits, no leading '+'. Fictional,
# reserved-shape value -- not a real LID.
LID_SHAPED_VALUE = "12345678901234"
GENUINE_PHONE = "+442079460958"  # OFCOM landline drama range, GB-valid.


def _make_syncer() -> ContactSyncer:
    syncer = ContactSyncer.__new__(ContactSyncer)
    cfg = MagicMock()
    cfg.DEFAULT_PRIVACY_LEVEL = "L2"
    cfg.USER_ID = None
    cfg.QDRANT_COLLECTION = "people"
    syncer.cfg = cfg
    syncer.resolver = MagicMock()
    syncer.resolver.default_country_code = 44
    syncer._captured_sparql: List[str] = []  # type: ignore[attr-defined]
    syncer._sparql_update = lambda sparql: syncer._captured_sparql.append(sparql)  # type: ignore[assignment]
    syncer._identifier_exists = lambda *a, **k: False  # type: ignore[assignment]
    return syncer


def _all_sparql(syncer: ContactSyncer) -> str:
    return "\n".join(syncer._captured_sparql)  # type: ignore[attr-defined]


def _parsed(phones: List[Dict[str, Any]], **extra: Any) -> Dict[str, Any]:
    base: Dict[str, Any] = {
        "fn": "Test Person", "given_name": "", "family_name": "",
        "emails": [], "phones": phones,
    }
    base.update(extra)
    return base


# ── _create_person_oxigraph ──────────────────────────────────────────────────

def test_create_refuses_a_lid_shaped_value_as_a_phone_identifier() -> None:
    syncer = _make_syncer()
    syncer._create_person_oxigraph(
        "https://example.invalid/p/create1", "p_create1",
        _parsed([{"value": LID_SHAPED_VALUE}]), "person",
    )
    sent = _all_sparql(syncer)
    assert LID_SHAPED_VALUE not in sent
    assert 'pwg:identifierType "phone"' not in sent


def test_create_accepts_a_genuine_phone_number() -> None:
    """Negative control: the guard must not refuse real phone numbers."""
    syncer = _make_syncer()
    syncer._create_person_oxigraph(
        "https://example.invalid/p/create2", "p_create2",
        _parsed([{"value": GENUINE_PHONE}]), "person",
    )
    sent = _all_sparql(syncer)
    assert 'pwg:identifierType "phone"' in sent
    assert f'pwg:identifierValue "{GENUINE_PHONE}"' in sent


# ── _update_person_oxigraph ──────────────────────────────────────────────────

def test_update_refuses_a_lid_shaped_value_as_a_phone_identifier() -> None:
    syncer = _make_syncer()
    syncer._update_person_oxigraph(
        "https://example.invalid/p/update1",
        _parsed([{"value": LID_SHAPED_VALUE}]), "person",
    )
    assert LID_SHAPED_VALUE not in _all_sparql(syncer)


def test_update_accepts_a_genuine_phone_number() -> None:
    """Negative control: the guard must not refuse real phone numbers."""
    syncer = _make_syncer()
    syncer._update_person_oxigraph(
        "https://example.invalid/p/update2",
        _parsed([{"value": GENUINE_PHONE}]), "person",
    )
    sent = _all_sparql(syncer)
    assert f'pwg:identifierValue "{GENUINE_PHONE}"' in sent
    assert 'pwg:identifierType "phone"' in sent


# ── Qdrant payload mirror ────────────────────────────────────────────────────

def _make_syncer_for_qdrant() -> ContactSyncer:
    syncer = _make_syncer()
    syncer._collection_ensured = True  # type: ignore[attr-defined]
    syncer.qdrant = MagicMock()  # type: ignore[attr-defined]
    syncer.qdrant.retrieve.return_value = []
    return syncer


def test_qdrant_payload_excludes_a_lid_shaped_value() -> None:
    syncer = _make_syncer_for_qdrant()
    syncer._upsert_qdrant(
        "p_qdrant1", "https://example.invalid/p/qdrant1",
        _parsed([{"value": LID_SHAPED_VALUE}]), vector=[0.0],
    )
    (_args, kwargs) = syncer.qdrant.upsert.call_args
    payload = kwargs["points"][0].payload
    assert payload["phones"] == []


def test_qdrant_payload_keeps_a_genuine_phone_number() -> None:
    """Negative control: the guard must not refuse real phone numbers."""
    syncer = _make_syncer_for_qdrant()
    syncer._upsert_qdrant(
        "p_qdrant2", "https://example.invalid/p/qdrant2",
        _parsed([{"value": GENUINE_PHONE}]), vector=[0.0],
    )
    (_args, kwargs) = syncer.qdrant.upsert.call_args
    payload = kwargs["points"][0].payload
    assert payload["phones"] == [GENUINE_PHONE]
