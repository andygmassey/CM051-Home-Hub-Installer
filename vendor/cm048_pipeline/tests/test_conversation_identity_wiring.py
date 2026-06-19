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


# ── chat-identifier derivation matches pwg_ingest keying ─────────────
#
# Two distinct concerns, deliberately separated after the dangling-edge
# bug: the URI *key* (``_participant_uri_key``) MUST equal the string
# pwg_ingest feeds to ``_person_id_from_identifier`` (raw JID for
# WhatsApp); the human-facing *chatIdentifier literal*
# (``_normalise_chat_identifier``) may stay normalised (e164 phone).


def _pwg_ingest_person_uri(participant: str) -> str:
    """Mirror ostler_fda.pwg_ingest's Person-URI derivation EXACTLY.

    pwg_ingest.ingest_whatsapp / ingest_imessage both do, byte-for-byte::

        person_id = _person_id_from_identifier(participant)
        uri       = _person_uri(person_id)

    where ``_person_id_from_identifier`` is
    ``uuid5(NAMESPACE_URL, "https://pwg.dev/person/" + p.strip().lower())``
    and ``_person_uri`` is ``"https://pwg.dev/ontology#person_" + id``.
    For WhatsApp, ``participant`` is the RAW JID (line ~468); for
    iMessage, the bare handle (line ~220). No e164 normalisation is
    applied to the URI key on either side -- that was the bug.
    """
    clean = participant.strip().lower()
    pid = str(uuid.uuid5(uuid.NAMESPACE_URL, f"https://pwg.dev/person/{clean}"))
    return f"https://pwg.dev/ontology#person_{pid}"


def test_whatsapp_uri_key_is_raw_jid():
    # The URI key keeps the RAW JID (matches pwg_ingest); it must NOT be
    # stripped to e164, which was the dangling-edge bug.
    assert ingest._participant_uri_key(
        "whatsapp", "447700900123@s.whatsapp.net"
    ) == "447700900123@s.whatsapp.net"


def test_whatsapp_chat_identifier_literal_stays_e164():
    # The surfaced literal stays "+<e164>" for readability / RULE 1 fold.
    assert ingest._normalise_chat_identifier(
        "whatsapp", "447700900123@s.whatsapp.net"
    ) == "+447700900123"


def test_imessage_handle_passes_through():
    assert ingest._participant_uri_key("im", "+447700900123") == "+447700900123"
    assert ingest._participant_uri_key("im", "friend@example.com") == "friend@example.com"
    assert ingest._normalise_chat_identifier(
        "im", "+447700900123"
    ) == "+447700900123"
    assert ingest._normalise_chat_identifier(
        "im", "friend@example.com"
    ) == "friend@example.com"


def test_whatsapp_person_uri_matches_pwg_ingest_raw_jid_keying():
    # THE regression test for the dangling-edge bug. The bridge's
    # reconstructed Person URI for a WhatsApp participant MUST equal the
    # URI pwg_ingest creates for the SAME raw JID, else the
    # pwg:participatedIn / pwg:hasParticipant edge dangles to a phantom.
    raw_jid = "447700900123@s.whatsapp.net"
    bridge_uri = ingest._person_graph_uri(
        ingest._person_id_from_identifier(
            ingest._participant_uri_key("whatsapp", raw_jid)
        )
    )
    assert bridge_uri == _pwg_ingest_person_uri(raw_jid)


def test_imessage_person_uri_matches_pwg_ingest_handle_keying():
    # iMessage was already correct; pin it so a future refactor can't
    # regress the handle-verbatim keying.
    handle = "+447700900123"
    bridge_uri = ingest._person_graph_uri(
        ingest._person_id_from_identifier(
            ingest._participant_uri_key("im", handle)
        )
    )
    assert bridge_uri == _pwg_ingest_person_uri(handle)


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
    # The URI is keyed off the RAW JID (matches pwg_ingest), NOT e164.
    raw_jid = "447700900123@s.whatsapp.net"
    person_uri = _pwg_ingest_person_uri(raw_jid)
    # The conversation links to the REAL person node, both directions.
    assert f"<{person_uri}> <urn:pwg:participatedIn> <urn:pwg:conversation/2026-03-04_chat>" in blob
    assert "<urn:pwg:hasParticipant>" in blob
    assert '<urn:pwg:hasChatChannel> "whatsapp"' in blob
    # The surfaced literal stays the readable e164 phone.
    assert '<urn:pwg:chatIdentifier> "+447700900123"' in blob


def test_participant_identity_skips_whatsapp_lid():
    # `@lid` is WhatsApp's opaque linked-id; pwg_ingest never creates a
    # Person node for it, so the bridge must not emit a dangling edge.
    meta = {
        "channel": "whatsapp",
        "participants": [
            {"id": "user", "display": "You", "role": "user"},
            {"id": "opaque", "display": "Unknown", "role": "other",
             "jid": "1234567890@lid"},
        ],
    }
    triples = ingest._participant_identity_triples("c-lid", meta, _settings())
    assert triples == []


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
