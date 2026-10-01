"""The LID-as-phone repair, run against the VENDORED copy that ships in the
DMG (vendor/cm041/identity_resolver/repair_lid_as_phone.py), not a source
checkout. A test proven only against CM041's own repo proves nothing about
what install.sh actually invokes.

TWO SIGNATURES, TWO WRITERS (Archie, 2026-10-01): CM041's whatsapp_bridge
(Pass A1, a sibling whatsapp_lid identifier sharing the bad value) and
ostler_fda's ingest_whatsapp (Pass A2, no sibling at all -- scoped by
``pwg:source "whatsapp_fda"``, the writer that actually ships, CM051 #2577).
Pass A1's predicate is proven NOT to see Pass A2's shape -- a sibling query
returning zero rows for a correctly-fixtured ostler_fda node would otherwise
look identical to "nothing wrong here".

All identifiers here are SYNTHETIC / reserved (Rule 0): no real personal data.
"""
from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
VENDOR_CM041 = REPO_ROOT / "vendor" / "cm041"
if not VENDOR_CM041.is_dir():
    raise SystemExit(f"vendored cm041 missing: {VENDOR_CM041} (broken vendor layout)")
sys.path.insert(0, str(VENDOR_CM041))

from identity_resolver import repair_lid_as_phone as R  # noqa: E402

PERSON_A = "https://example.invalid/person/a"
LID = "999999999999998"          # 15 digits, LID-shaped

# ostler_fda mints a full uuid5-derived, dashed person URI (_person_id_from_
# identifier in ostler_fda/pwg_ingest.py) -- a different shape from CM041's
# truncated uuid4 hex. All-zero-but-version/variant-bits: clearly synthetic,
# not derived from any real value.
PERSON_FDA = "https://schema.ostler.ai/ontology#person_00000000-0000-5000-8000-000000000000"


def _wire(monkeypatch, *, bridge_rows=(), fda_rows=()):
    sent = []

    def q(url, client, sparql):
        if "whatsapp_lid" in sparql:
            return list(bridge_rows)
        if "whatsapp_fda" in sparql:
            return list(fda_rows)
        raise AssertionError(
            "the harness was asked a query it does not recognise:\n%s" % sparql
        )

    def u(url, client, sparql):
        sent.append(sparql)

    monkeypatch.setattr(R, "_sparql_query", q)
    monkeypatch.setattr(R, "_sparql_update", u)
    return sent


# ---------------------------------------------------------------------------
# Pass A1 -- CM041 whatsapp_bridge signature (sibling whatsapp_lid pair)
# ---------------------------------------------------------------------------

def test_lid_as_phone_demoted_and_renamed(monkeypatch):
    sent = _wire(monkeypatch, bridge_rows=[
        {"person": PERSON_A, "phoneId": f"{R.PWG}id_a_phone0", "value": LID,
         "name": f"Unknown ({LID})"},
    ])
    rc = R.repair("http://o.invalid", apply=True)
    assert rc == R.EXIT_OK
    assert any("id_a_phone0" in s and "DELETE" in s for s in sent)
    assert any("WhatsApp contact" in s for s in sent)


def test_lid_as_phone_dry_run_changes_nothing(monkeypatch):
    sent = _wire(monkeypatch, bridge_rows=[
        {"person": PERSON_A, "phoneId": f"{R.PWG}id_a_phone0", "value": LID,
         "name": f"Unknown ({LID})"},
    ])
    rc = R.repair("http://o.invalid", apply=False)
    assert rc == R.EXIT_OK
    assert sent == [], "dry run (apply=False) must issue zero writes"


def test_lid_as_phone_ignores_a_genuinely_valid_phone(monkeypatch):
    """CONTROL: a real phone that happens to equal a whatsapp_lid value by
    pure coincidence (vanishingly unlikely, but the predicate must still
    check validity, not just equality) is left alone."""
    real_number = "+14155550100"
    sent = _wire(monkeypatch, bridge_rows=[
        {"person": PERSON_A, "phoneId": f"{R.PWG}id_a_phone0",
         "value": real_number, "name": "Real Person"},
    ])
    rc = R.repair("http://o.invalid", apply=True)
    assert rc == R.EXIT_OK
    assert sent == []


def test_negative_control_lid_predicate_refuses(monkeypatch):
    _wire(monkeypatch, bridge_rows=[
        {"person": PERSON_A, "phoneId": "x", "value": R.CONTROL_LID_PHONE_VALUE,
         "name": ""},
    ])
    rc = R.repair("http://o.invalid", apply=True)
    assert rc == R.EXIT_BROKEN_PREDICATE


def test_cannot_run_when_the_store_is_unreachable(monkeypatch):
    def boom(url, client, sparql):
        raise ConnectionError("no route to host")

    monkeypatch.setattr(R, "_sparql_query", boom)
    rc = R.repair("http://o.invalid", apply=True)
    assert rc == R.EXIT_CANNOT_RUN


# ---------------------------------------------------------------------------
# Pass A2 -- ostler_fda ingest_whatsapp signature (no sibling, uuid5 URI)
# ---------------------------------------------------------------------------

def test_pass_a1_does_not_see_the_ostler_fda_signature(monkeypatch):
    """PROVEN, NOT ASSUMED: a synthetic uuid5-shaped node with ostler_fda's
    exact old-bug shape (one invalid "phone" identifier, NO whatsapp_lid
    sibling) is invisible to Pass A1's sibling-pair query. This is why
    Pass A2 has to exist as an independent predicate."""
    sent = _wire(monkeypatch, bridge_rows=[], fda_rows=[
        {"person": PERSON_FDA, "phoneId": f"{R.PWG}id_fda_whatsapp",
         "value": "+" + LID, "name": "+" + LID},
    ])
    rc = R.repair("http://o.invalid", apply=True)
    assert rc == R.EXIT_OK
    assert any(
        "id_fda_whatsapp" in s and '"whatsapp_lid"' in s and "INSERT" in s
        for s in sent
    )


def test_ostler_fda_signature_retypes_rather_than_deletes(monkeypatch):
    sent = _wire(monkeypatch, fda_rows=[
        {"person": PERSON_FDA, "phoneId": f"{R.PWG}id_fda_whatsapp",
         "value": "+" + LID, "name": "+" + LID},
    ])
    rc = R.repair("http://o.invalid", apply=True)
    assert rc == R.EXIT_OK
    retype_calls = [s for s in sent if "id_fda_whatsapp" in s]
    assert retype_calls, "the fda identifier was never touched"
    assert not any("DELETE {" in s and "hasIdentifier" in s for s in retype_calls)
    assert any('"whatsapp_lid"' in s for s in retype_calls)


def test_ostler_fda_displayname_renamed_when_it_equals_the_phone_value(monkeypatch):
    sent = _wire(monkeypatch, fda_rows=[
        {"person": PERSON_FDA, "phoneId": f"{R.PWG}id_fda_whatsapp",
         "value": "+" + LID, "name": "+" + LID},
    ])
    rc = R.repair("http://o.invalid", apply=True)
    assert rc == R.EXIT_OK
    assert any("WhatsApp contact" in s for s in sent)


def test_ostler_fda_displayname_untouched_when_it_is_a_real_name(monkeypatch):
    """CONTROL: if a real name already overwrote the placeholder, the
    displayName must not be touched even though the phone identifier is
    still bad."""
    sent = _wire(monkeypatch, fda_rows=[
        {"person": PERSON_FDA, "phoneId": f"{R.PWG}id_fda_whatsapp",
         "value": "+" + LID, "name": "Real Person"},
    ])
    rc = R.repair("http://o.invalid", apply=True)
    assert rc == R.EXIT_OK
    assert not any("WhatsApp contact" in s for s in sent)
    assert not any("displayName" in s and "DELETE" in s for s in sent)


def test_ostler_fda_dry_run_changes_nothing(monkeypatch):
    sent = _wire(monkeypatch, fda_rows=[
        {"person": PERSON_FDA, "phoneId": f"{R.PWG}id_fda_whatsapp",
         "value": "+" + LID, "name": "+" + LID},
    ])
    rc = R.repair("http://o.invalid", apply=False)
    assert rc == R.EXIT_OK
    assert sent == []


def test_ostler_fda_signature_ignores_a_genuinely_valid_phone(monkeypatch):
    """CONTROL: an ostler_fda-sourced person with a genuinely valid phone
    (the ordinary, already-fixed-forward case) is left alone."""
    sent = _wire(monkeypatch, fda_rows=[
        {"person": PERSON_FDA, "phoneId": f"{R.PWG}id_fda_whatsapp",
         "value": "+14155550100", "name": "+14155550100"},
    ])
    rc = R.repair("http://o.invalid", apply=True)
    assert rc == R.EXIT_OK
    assert sent == []


def test_negative_control_ostler_fda_predicate_refuses(monkeypatch):
    _wire(monkeypatch, fda_rows=[
        {"person": PERSON_FDA, "phoneId": "x", "value": R.CONTROL_LID_PHONE_VALUE,
         "name": ""},
    ])
    rc = R.repair("http://o.invalid", apply=True)
    assert rc == R.EXIT_BROKEN_PREDICATE


def test_both_signatures_counted_independently(monkeypatch, capsys):
    _wire(monkeypatch, bridge_rows=[
        {"person": PERSON_A, "phoneId": f"{R.PWG}id_a_phone0", "value": LID,
         "name": f"Unknown ({LID})"},
    ], fda_rows=[
        {"person": PERSON_FDA, "phoneId": f"{R.PWG}id_fda_whatsapp",
         "value": "+" + LID, "name": "+" + LID},
    ])
    rc = R.repair("http://o.invalid", apply=True)
    out = capsys.readouterr().out
    assert rc == R.EXIT_OK
    assert "Pass A1, CM041 bridge signature          : 1" in out
    assert "Pass A2, ostler_fda signature             : 1" in out
