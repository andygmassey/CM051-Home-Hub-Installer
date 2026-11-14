"""Notification and organisation senders are not put into the people index.

Walk 131: a sender row named like "<Shop> Receipts" was a pwg:Person in Oxigraph
and the people projection embedded it, so it surfaced as a person. The projection
now leaves those rows out BEFORE the embed.

The rule is a product rule, not the probe's display rule. It drops a row only on
an unambiguous phrase, a plural keyword, a legal form, a marketplace or a domain,
or on a singular ambiguous word (gift, deal, card, bank, club, shop, team, ...)
TOGETHER WITH a second signal: a service mailbox local part on an email address.
A given name plus a surname is kept, whatever the surname is.

The end-to-end test drives the real ingest_people_to_qdrant (the shipped
vendored module) and stubs only its I/O boundaries. Synthetic data only; the
name pairs are fictional combinations.
"""

import pathlib
import sys

import pytest

VENDOR = pathlib.Path(__file__).resolve().parents[1] / "vendor"
if str(VENDOR) not in sys.path:
    sys.path.insert(0, str(VENDOR))

from ostler_fda import pwg_ingest as pi  # noqa: E402

# Senders that must be dropped.
SERVICE_SENDERS = [
    "acme receipts",
    "globex deals",
    "initech alerts",
    "riverside notifications",
    "acme ltd",
    "the globex team",
]
# A singular ambiguous word on its own is not a sender signal.
DROP_ONLY_WITH_SECOND_SIGNAL = [
    ("jane card", ["noreply@example.com"]),
    ("jane bank", ["info@example.com"]),
]
# NEGATIVE CONTROLS: a real person's name, in every shape the rule must keep.
# Given name plus each ambiguous surname; the given name Gift plus a surname;
# one CJK personal name; an email-only person with a personal address.
KEEP = [
    "gift hollis",
    "jane deal",
    "jane card",
    "jane bank",
    "jane club",
    "jane shop",
    "jane team",
    "jane ann card",
    "jane ann bank",
    "jane ann club",
    "jane ann shop",
    "jane ann team",
    "sam doe",
    "jane smith",
    "tom jones",
    "ben ross",
    "alex brown",
    "mary patel",
    "李明",
]
KEEP_WITH_PERSONAL_EMAIL = [
    ("jane card", ["jane.card@example.com"]),
    ("jane deal", ["jane.deal@example.com"]),
]


def _row(name, phones=(), emails=()):
    return {
        "uri": "https://schema.ostler.ai/ontology#person_" + name.replace(" ", "_"),
        "display_name": name,
        "given_name": "",
        "family_name": "",
        "contact_type": "person",
        "job_title": "",
        "organization": "",
        "phones": list(phones),
        "emails": list(emails),
        "created_at": "2026-11-01T00:00:00Z",
        "last_contact": "",
    }


@pytest.mark.parametrize("name", SERVICE_SENDERS)
def test_service_and_organisation_senders_are_classified(name):
    assert pi.service_sender_reason(name) is not None, name


@pytest.mark.parametrize("name,emails", DROP_ONLY_WITH_SECOND_SIGNAL)
def test_ambiguous_word_with_service_mailbox_is_classified(name, emails):
    assert pi.service_sender_reason(name, [], emails) is not None, name


@pytest.mark.parametrize("name", KEEP)
def test_negative_control_person_is_kept(name):
    assert pi.service_sender_reason(name) is None, name


@pytest.mark.parametrize("name,emails", KEEP_WITH_PERSONAL_EMAIL)
def test_negative_control_email_only_person_is_kept(name, emails):
    assert pi.service_sender_reason(name, [], emails) is None, name


def test_negative_control_a_phone_exempts_a_service_shaped_name():
    assert pi.service_sender_reason("acme receipts", ["+44 7700 900123"]) is None


@pytest.fixture
def projected(monkeypatch):
    rows = [_row(n) for n in KEEP if n.isascii()]
    rows += [_row(n) for n in SERVICE_SENDERS]
    rows += [_row(n, emails=e) for n, e in KEEP_WITH_PERSONAL_EMAIL]
    rows += [_row("jane card", emails=["noreply@example.com"])]
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
    # "acme receipts" appears twice (one with a phone); the phone one is checked below.
    leaked = sorted((set(projected) & set(SERVICE_SENDERS)) - {"acme receipts"})
    assert leaked == [], "service senders were projected as people: %r" % leaked


def test_projection_keeps_every_negative_control(projected):
    expected = [n for n in KEEP if n.isascii()] + [n for n, _ in KEEP_WITH_PERSONAL_EMAIL]
    missing = sorted(set(expected) - set(projected))
    assert missing == [], "real people were dropped: %r" % missing


def test_projection_drops_ambiguous_word_only_with_service_mailbox(projected):
    assert "jane card" in projected  # the personal-email row survives
    assert projected.count("jane card") == 2  # personal-email row kept, noreply row dropped
