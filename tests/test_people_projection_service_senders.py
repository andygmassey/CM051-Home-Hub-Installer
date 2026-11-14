"""Notification and organisation senders are not put into the people index.

Walk 131: a sender row named like "<Shop> Receipts" was a pwg:Person in Oxigraph
and the people projection embedded it, so it surfaced as a person. The fix
drops those rows in ingest_people_to_qdrant BEFORE the embed, with the same
rule the walk's people-phrasing probe measures.

The end-to-end test drives the real ingest_people_to_qdrant (the shipped
vendored module) and stubs only its I/O boundaries: the Oxigraph read, the
Qdrant read and write, and the Ollama embed. It asserts on what would be
upserted. Negative controls: real-looking synthetic person names and a service
shaped name that has a phone (a contact card the customer filled in) must stay.
Synthetic data only.
"""

import pathlib
import sys

import pytest

VENDOR = pathlib.Path(__file__).resolve().parents[1] / "vendor"
if str(VENDOR) not in sys.path:
    sys.path.insert(0, str(VENDOR))

from ostler_fda import pwg_ingest as pi  # noqa: E402

SERVICE_SENDERS = [
    "acme receipts",
    "globex deals",
    "initech alerts",
    "riverside notifications",
    "Acme Ltd",
    "The Globex Team",
]
SYNTHETIC_PEOPLE = ["Sam Doe", "Jane Smith", "Tom Jones", "Ben Ross", "Alex Brown", "Mary Patel"]


def _row(name, phones=()):
    return {
        "uri": "https://schema.ostler.ai/ontology#person_" + name.lower().replace(" ", "_"),
        "display_name": name,
        "given_name": "",
        "family_name": "",
        "contact_type": "person",
        "job_title": "",
        "organization": "",
        "phones": list(phones),
        "emails": [],
        "created_at": "2026-11-01T00:00:00Z",
        "last_contact": "",
    }


@pytest.mark.parametrize("name", SERVICE_SENDERS)
def test_service_and_organisation_senders_are_classified(name):
    assert pi.service_sender_reason(name) is not None, name


@pytest.mark.parametrize("name", SYNTHETIC_PEOPLE)
def test_negative_control_people_are_not_classified(name):
    assert pi.service_sender_reason(name) is None, name


def test_negative_control_a_phone_exempts_a_service_shaped_name():
    # A contact card the customer filled in is theirs, whatever its shape.
    assert pi.service_sender_reason("acme receipts", ["+44 7700 900123"]) is None


@pytest.fixture
def projected(monkeypatch):
    rows = [_row(n) for n in SYNTHETIC_PEOPLE]
    rows += [_row(n) for n in SERVICE_SENDERS]
    # The same shape WITH a phone: a card the customer filled in, so it stays.
    rows.append(_row("acme receipts", phones=["+44 7700 900123"]))
    upserts = []

    monkeypatch.setattr(pi, "_load_people_from_oxigraph", lambda: rows)
    monkeypatch.setattr(pi, "_qdrant_scroll_points", lambda collection, limit=1000: [])
    monkeypatch.setattr(pi, "_ollama_embed_batch", lambda texts: [[0.1, 0.2, 0.3, 0.4] for _ in texts])
    monkeypatch.setattr(pi, "_qdrant_ensure_collection", lambda collection, dim: True)

    def fake_upsert(collection, points):
        upserts.extend(points)
        return len(points)

    monkeypatch.setattr(pi, "_qdrant_upsert_points", fake_upsert)
    pi.ingest_people_to_qdrant()
    return [p["payload"]["display_name"] for p in upserts]


def test_projection_embeds_no_service_sender(projected):
    # "acme receipts" is checked by the phone test below: one row of that name
    # (the phone-carrying one) is a legitimate person, the no-phone one is not.
    leaked = sorted((set(projected) & set(SERVICE_SENDERS)) - {"acme receipts"})
    assert leaked == [], "service senders were projected as people: %r" % leaked


def test_projection_keeps_every_real_person(projected):
    missing = sorted(set(SYNTHETIC_PEOPLE) - set(projected))
    assert missing == [], "real people were dropped: %r" % missing


def test_projection_keeps_the_phone_exempt_card(projected):
    # Two rows share the name: the no-phone one is dropped, the phone one kept.
    assert projected.count("acme receipts") == 1
