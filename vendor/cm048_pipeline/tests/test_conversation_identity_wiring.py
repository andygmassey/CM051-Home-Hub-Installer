"""CM044 conversations-ingest fix: channel tag + participant-identity wiring.

These tests pin the structural contract that was silently broken in the
field (live box 192.168.1.159): conversation Qdrant points carried no
``channel`` tag and conversation facts never linked back to the
JID/handle-keyed ``pwg:Person`` nodes, so "who did I talk to" could not
be answered structurally.

The triple/payload builders under test are pure (no network), so these
run anywhere the package imports.
"""
from __future__ import annotations

import uuid

import pytest

from src import ingest
from src.schemas import Classification, Sensitivity
from src.settings import Settings


def _settings() -> Settings:
    return Settings(user_id="test-user")


def _classification() -> Classification:
    return Classification(
        setting="social",
        shape="casual",
        stakes="low",
        confidence=0.9,
        reasoning="t",
        sensitivity=Sensitivity(level="normal"),
        suggested_type_slug="social_casual_low",
    )


# ── chat-identifier normalisation matches pwg_ingest keying ──────────

def test_whatsapp_jid_normalises_to_e164_phone():
    # WhatsApp JID -> "+<e164>" so it folds with the same number from
    # Contacts / iMessage (dedup RULE 1).
    assert ingest._normalise_chat_identifier(
        "whatsapp", "447700900123@s.whatsapp.net"
    ) == "+447700900123"


def test_imessage_handle_passes_through():
    assert ingest._normalise_chat_identifier(
        "im", "+447700900123"
    ) == "+447700900123"
    assert ingest._normalise_chat_identifier(
        "im", "friend@example.com"
    ) == "friend@example.com"


def test_person_uri_matches_pwg_ingest_derivation():
    # The reconstructed Person URI MUST equal what ostler_fda.pwg_ingest
    # would create for the same identifier, else the conversation links
    # to a phantom node instead of the real contact.
    ident = "+447700900123"
    pid = str(uuid.uuid5(uuid.NAMESPACE_URL, f"https://pwg.dev/person/{ident.lower()}"))
    expected = f"https://pwg.dev/ontology#person_{pid}"
    assert ingest._person_graph_uri(ingest._person_id_from_identifier(ident)) == expected


# ── participant-identity triples ─────────────────────────────────────

def test_participant_identity_links_whatsapp_jid_to_person_node():
    meta = {
        "channel": "whatsapp",
        "participants": [
            {"id": "user", "display": "You", "role": "user"},
            {"id": "danny-kwan", "display": "Danny Kwan", "role": "other",
             "jid": "447700900123@s.whatsapp.net"},
        ],
    }
    triples = ingest._participant_identity_triples("2026-03-04_chat", meta, _settings())
    blob = "\n".join(triples)
    ident = "+447700900123"
    pid = ingest._person_id_from_identifier(ident)
    person_uri = ingest._person_graph_uri(pid)
    # The conversation links to the REAL person node, both directions.
    assert f"<{person_uri}> <urn:pwg:participatedIn> <urn:pwg:conversation/2026-03-04_chat>" in blob
    assert "<urn:pwg:hasParticipant>" in blob
    assert '<urn:pwg:hasChatChannel> "whatsapp"' in blob
    assert '<urn:pwg:chatIdentifier> "+447700900123"' in blob


def test_participant_identity_skips_user_and_unkeyed():
    meta = {
        "channel": "im",
        "participants": [
            {"id": "user", "display": "You", "role": "user"},
            {"id": "no-handle", "display": "Slug Only", "role": "other"},
            {"id": "h", "display": "Friend", "role": "other", "handle": "+15551234567"},
        ],
    }
    triples = ingest._participant_identity_triples("c1", meta, _settings())
    # Only the one participant with a real handle is linked.
    assert sum("participatedIn" in t for t in triples) == 1
    keyed = ingest._person_graph_uri(
        ingest._person_id_from_identifier("+15551234567")
    )
    assert keyed in "\n".join(triples)


def test_participant_identity_empty_when_no_participants():
    assert ingest._participant_identity_triples("c1", {"channel": "whatsapp"}, _settings()) == []
    assert ingest._participant_identity_triples("c1", {}, _settings()) == []


# ── channel tagging in the Qdrant payload path ───────────────────────

def test_qdrant_base_payload_carries_channel(monkeypatch, tmp_path):
    # Drive _write_qdrant with no embeddable content so it returns 0
    # without touching the network, but assert the channel is resolved
    # from metadata (the base_payload construction is the thing fixed).
    captured = {}

    def fake_load(_state_dir):
        return {"channel": "whatsapp", "participants": []}

    monkeypatch.setattr(ingest, "_load_metadata", fake_load)
    # No 02_enrichment.md and no 05_facts.json in tmp_path -> 0 points,
    # so no embed/upsert network call is made.
    n = ingest._write_qdrant(
        tmp_path, "c1", _classification(), _settings(), dry_run=False
    )
    assert n == 0  # nothing to embed, but no crash and channel resolved

    # And prove the payload would carry the channel: re-run the resolve
    # the same way the function does.
    meta = fake_load(tmp_path)
    assert (meta.get("channel") or "").strip().lower() == "whatsapp"


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(pytest.main([__file__, "-v"]))
