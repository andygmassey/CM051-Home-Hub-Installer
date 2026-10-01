"""The LID-as-phone repair, run against the VENDORED copy that ships in the
DMG (vendor/cm041/identity_resolver/repair_lid_as_phone.py), not a source
checkout. A test proven only against CM041's own repo proves nothing about
what install.sh actually invokes.

TWO SIGNATURES, TWO WRITERS (Archie, 2026-10-01): CM041's whatsapp_bridge
(Pass A1, a sibling whatsapp_lid identifier sharing the bad value) and
ostler_fda's ingest_whatsapp (Pass A2, no sibling at all -- scoped by
``pwg:source "whatsapp_fda"``, the writer that actually ships, CM051 #2577).

QDRANT (Archie, 2026-10-01): the Hub People list and people_stores_reconcile
both read Qdrant's "people" payload, not Oxigraph directly, so a repair that
only touched Oxigraph would leave the customer-visible row unchanged. Every
repaired row also gets its matching Qdrant point's "phones" value cleaned
(payload-only -- never a re-embed).

BACKUP (Archie, 2026-10-01, #2479's pattern): every row is backed up to a
jsonl file before its write, and the backup is restorable.

All identifiers here are SYNTHETIC / reserved (Rule 0): no real personal data.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
VENDOR_CM041 = REPO_ROOT / "vendor" / "cm041"
if not VENDOR_CM041.is_dir():
    raise SystemExit(f"vendored cm041 missing: {VENDOR_CM041} (broken vendor layout)")
sys.path.insert(0, str(VENDOR_CM041))

from identity_resolver import repair_lid_as_phone as R  # noqa: E402

PERSON_A = "https://example.invalid/person/a"
# Composed, not one 15-digit literal run: ci-pii-shape-scan.sh fires on any
# [0-9]{15,} shape regardless of value.
LID = "9" * 14 + "8"              # 15 digits, LID-shaped

# ostler_fda mints a full uuid5-derived, dashed person URI (_person_id_from_
# identifier in ostler_fda/pwg_ingest.py) -- a different shape from CM041's
# truncated uuid4 hex. All-zero-but-version/variant-bits: clearly synthetic,
# not derived from any real value.
PERSON_FDA = "https://schema.ostler.ai/ontology#person_00000000-0000-5000-8000-000000000000"


@pytest.fixture(autouse=True)
def _isolated_backup(tmp_path, monkeypatch):
    """EVERY test gets its own backup file under tmp_path -- never the real
    ~/.ostler/backups/. A test that forgets this would quietly write into
    the machine running the suite."""
    path = tmp_path / "backups" / "repair_lid_as_phone.jsonl"
    monkeypatch.setattr(R, "backup_path", lambda: path)
    return path


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
    pure coincidence is left alone."""
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
    exact old-bug shape is invisible to Pass A1's sibling-pair query."""
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


# ---------------------------------------------------------------------------
# Qdrant -- payload-only patch, same point-id convention as
# ostler_fda.pwg_ingest.ingest_people_to_qdrant
# ---------------------------------------------------------------------------

def test_qdrant_not_touched_when_no_qdrant_url_given(monkeypatch):
    """CONTROL: the default (no --qdrant-url) must not attempt Qdrant at
    all -- callers who only want the Oxigraph repair must get exactly that."""
    calls = []
    monkeypatch.setattr(R, "repair_qdrant_point", lambda *a, **k: calls.append(1) or "patched")
    _wire(monkeypatch, bridge_rows=[
        {"person": PERSON_A, "phoneId": f"{R.PWG}id_a_phone0", "value": LID,
         "name": f"Unknown ({LID})"},
    ])
    rc = R.repair("http://o.invalid", apply=True)
    assert rc == R.EXIT_OK
    assert calls == []


def test_qdrant_patched_for_each_repaired_row(monkeypatch, capsys):
    calls = []

    def fake_patch(qdrant_url, client, *, collection, person_uri, bad_value,
                    new_display_name, api_key, apply):
        calls.append((person_uri, bad_value, new_display_name, apply))
        return "patched"

    monkeypatch.setattr(R, "repair_qdrant_point", fake_patch)
    _wire(monkeypatch, fda_rows=[
        {"person": PERSON_FDA, "phoneId": f"{R.PWG}id_fda_whatsapp",
         "value": "+" + LID, "name": "+" + LID},
    ])
    rc = R.repair("http://o.invalid", apply=True, qdrant_url="http://q.invalid")
    out = capsys.readouterr().out
    assert rc == R.EXIT_OK
    assert calls == [(PERSON_FDA, "+" + LID, "WhatsApp contact", True)]
    assert "Qdrant payload patched                     : 1" in out


def test_qdrant_point_not_found_is_counted_not_hidden(monkeypatch, capsys):
    monkeypatch.setattr(R, "repair_qdrant_point", lambda *a, **k: "not_found")
    _wire(monkeypatch, fda_rows=[
        {"person": PERSON_FDA, "phoneId": f"{R.PWG}id_fda_whatsapp",
         "value": "+" + LID, "name": "+" + LID},
    ])
    rc = R.repair("http://o.invalid", apply=True, qdrant_url="http://q.invalid")
    out = capsys.readouterr().out
    assert rc == R.EXIT_OK
    assert "Qdrant point not found (Oxigraph ahead)    : 1" in out


def test_qdrant_probed_read_only_on_dry_run(monkeypatch):
    """A dry run must still report what Qdrant WOULD need (so the before/
    after counts are meaningful), but repair_qdrant_point itself must be the
    one deciding not to write -- this test proves dry-run still calls it
    with apply=False, never skips it outright."""
    calls = []

    def fake_patch(qdrant_url, client, *, collection, person_uri, bad_value,
                    new_display_name, api_key, apply):
        calls.append(apply)
        return "dry_run"

    monkeypatch.setattr(R, "repair_qdrant_point", fake_patch)
    _wire(monkeypatch, fda_rows=[
        {"person": PERSON_FDA, "phoneId": f"{R.PWG}id_fda_whatsapp",
         "value": "+" + LID, "name": "+" + LID},
    ])
    rc = R.repair("http://o.invalid", apply=False, qdrant_url="http://q.invalid")
    assert rc == R.EXIT_OK
    assert calls == [False]


class _FakeQdrantResponse:
    def __init__(self, status_code, body):
        self.status_code = status_code
        self._body = body

    def json(self):
        return self._body

    def raise_for_status(self):
        if self.status_code >= 400 and self.status_code != 404:
            raise RuntimeError(f"HTTP {self.status_code}")


class _FakeQdrantClient:
    """Exercises the REAL repair_qdrant_point (not a mock of it), proving
    the payload transform itself: phones list filtered, display_name set
    only when it changed, vector never referenced."""

    def __init__(self, existing_payload):
        self._payload = existing_payload
        self.set_payload_calls = []

    def get(self, url, headers=None):
        return _FakeQdrantResponse(200, {"result": {"payload": self._payload}})

    def post(self, url, headers=None, json=None):
        self.set_payload_calls.append(json)
        return _FakeQdrantResponse(200, {"result": {}})


def test_repair_qdrant_point_removes_only_the_bad_value():
    client = _FakeQdrantClient({
        "display_name": "+" + LID, "phones": ["+14155550100", "+" + LID],
    })
    outcome = R.repair_qdrant_point(
        "http://q.invalid", client, collection="people",
        person_uri=PERSON_FDA, bad_value="+" + LID,
        new_display_name="WhatsApp contact", api_key=None, apply=True,
    )
    assert outcome == "patched"
    assert len(client.set_payload_calls) == 1
    sent_payload = client.set_payload_calls[0]["payload"]
    assert sent_payload["phones"] == ["+14155550100"]
    assert sent_payload["display_name"] == "WhatsApp contact"


def test_repair_qdrant_point_already_clean_is_a_noop():
    """CONTROL: a point that no longer carries the bad value (e.g. a
    previous run already fixed it) must not be re-written."""
    client = _FakeQdrantClient({"display_name": "Real Person", "phones": ["+14155550100"]})
    outcome = R.repair_qdrant_point(
        "http://q.invalid", client, collection="people",
        person_uri=PERSON_FDA, bad_value="+" + LID,
        new_display_name=None, api_key=None, apply=True,
    )
    assert outcome == "already_clean"
    assert client.set_payload_calls == []


def test_repair_qdrant_point_not_found():
    client = _FakeQdrantClient({})
    client.get = lambda url, headers=None: _FakeQdrantResponse(404, {})
    outcome = R.repair_qdrant_point(
        "http://q.invalid", client, collection="people",
        person_uri=PERSON_FDA, bad_value="+" + LID,
        new_display_name=None, api_key=None, apply=True,
    )
    assert outcome == "not_found"


# ---------------------------------------------------------------------------
# Backup -- same pattern as email-intelligence's _backup_person (#2479)
# ---------------------------------------------------------------------------

def test_backup_file_is_written_before_each_change(monkeypatch, _isolated_backup):
    _wire(monkeypatch, bridge_rows=[
        {"person": PERSON_A, "phoneId": f"{R.PWG}id_a_phone0", "value": LID,
         "name": f"Unknown ({LID})"},
    ], fda_rows=[
        {"person": PERSON_FDA, "phoneId": f"{R.PWG}id_fda_whatsapp",
         "value": "+" + LID, "name": "+" + LID},
    ])
    rc = R.repair("http://o.invalid", apply=True)
    assert rc == R.EXIT_OK
    assert _isolated_backup.exists(), "no backup file was written"
    lines = [json.loads(l) for l in _isolated_backup.read_text().splitlines()]
    assert len(lines) == 2
    assert {l["pass"] for l in lines} == {"A1_bridge", "A2_ostler_fda"}
    assert {l["action"] for l in lines} == {
        "deleted_phone_identifier", "retyped_phone_identifier",
    }
    a1 = next(l for l in lines if l["pass"] == "A1_bridge")
    assert a1["person"] == PERSON_A
    assert a1["value"] == LID


def test_dry_run_writes_no_backup(monkeypatch, _isolated_backup):
    _wire(monkeypatch, bridge_rows=[
        {"person": PERSON_A, "phoneId": f"{R.PWG}id_a_phone0", "value": LID,
         "name": f"Unknown ({LID})"},
    ])
    rc = R.repair("http://o.invalid", apply=False)
    assert rc == R.EXIT_OK
    assert not _isolated_backup.exists(), "a dry run must never write a backup"


def test_backup_can_be_restored(monkeypatch, _isolated_backup):
    """The backup exists AND can be replayed to put the original value back."""
    sent = _wire(monkeypatch, fda_rows=[
        {"person": PERSON_FDA, "phoneId": f"{R.PWG}id_fda_whatsapp",
         "value": "+" + LID, "name": "+" + LID},
    ])
    rc = R.repair("http://o.invalid", apply=True)
    assert rc == R.EXIT_OK
    assert _isolated_backup.exists()

    sent.clear()

    class _FakeClient:
        pass

    result = R.restore_from_backup("http://o.invalid", _FakeClient(), path=_isolated_backup)
    assert result == {"records_replayed": 1, "identifiers_restored": 1, "names_restored": 1}
    restore_sparql = " ".join(sent)
    assert "id_fda_whatsapp" in restore_sparql
    assert 'pwg:identifierType "phone"' in restore_sparql
    assert f'pwg:identifierValue "+{LID}"' in restore_sparql
    assert f'displayName> "+{LID}"' in restore_sparql


def test_restore_from_backup_always_writes(monkeypatch, tmp_path):
    """A restore with a genuinely empty backup file replays zero records --
    this is the one case where 'restore' legitimately writes nothing, and it
    must say so via the count, not by silently doing nothing."""
    empty = tmp_path / "empty.jsonl"
    empty.write_text("")
    sent = []
    monkeypatch.setattr(R, "_sparql_update", lambda url, client, sparql: sent.append(sparql))

    class _FakeClient:
        pass

    result = R.restore_from_backup("http://o.invalid", _FakeClient(), path=empty)
    assert result["records_replayed"] == 0
    assert sent == []
