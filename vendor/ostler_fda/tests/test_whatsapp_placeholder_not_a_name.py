"""CM051 #30 batch 3: WhatsApp's default / unknown-name token must not
CREATE a named person. 13 records on one box shared "WhatsApp contact".

The person (tier 0, phone handle, provisional) still appears; only the
name is withheld. Synthetic data only.
"""
from __future__ import annotations

import json
from unittest.mock import patch

import pytest

from ostler_fda import pwg_ingest as p
from ostler_fda.whatsapp_history import JID_SUFFIX_PERSON

_NANP = "1" + "415" + "555" + "0100"
_LID = "1" + "0" * 13 + "1"

PLACEHOLDERS = [
    "WhatsApp contact", "WhatsApp Contact", "~WhatsApp contact", "~", "~ ",
    "", "   ", "‎", "...", "-", "?!", "\U0001F600", "\U0001F600\U0001F44D",
    "~\U0001F600", "Unknown", "unknown", "~Unknown", "Unknown contact",
    "WhatsApp user", "WhatsApp",
    # locale variants (best-effort, not verified against WhatsApp tables)
    "Desconocido", "Contacto de WhatsApp", "Usuario de WhatsApp", "Inconnu",
    "Contact WhatsApp", "Utilisateur WhatsApp", "Unbekannt", "WhatsApp-Kontakt",
    "WhatsApp-Nutzer", "Sconosciuto", "Contatto WhatsApp", "Utente WhatsApp",
    "Desconhecido", "Contato do WhatsApp", "Onbekend", "WhatsApp-contact",
    "Неизвестный",
    "未知", "不明", "알 수 없음",
]
REAL = ["Sam Wang", "~Sam Wang", "Alex Brown", "Agent 3-2-1", "Nan Goldin",
        "Renee O'Neil", "王明"]


@pytest.mark.parametrize("v", PLACEHOLDERS)
def test_placeholder_shapes_are_not_names(v):
    assert p._is_whatsapp_placeholder_name(v) is True
    assert p._display_name_tier(v) == p._NAME_TIER_PLACEHOLDER
    triples = p._creation_name_triples("urn:x:1", v)
    assert not any("pwg:displayName " in t for t in triples)
    assert any("displayNameProvisional" in t for t in triples)


@pytest.mark.parametrize("v", REAL)
def test_real_names_still_names(v):
    assert p._is_whatsapp_placeholder_name(v) is False
    assert p._display_name_tier(v) == p._NAME_TIER_NAME
    assert any("pwg:displayName " in t for t in p._creation_name_triples("urn:x:1", v))


def test_none_is_placeholder():
    assert p._is_whatsapp_placeholder_name(None) is True


def test_upsert_never_writes_a_placeholder():
    with patch("ostler_fda.pwg_ingest._sparql_update") as upd:
        p._upsert_display_name("urn:x:1", "WhatsApp contact")
        upd.assert_not_called()
        p._upsert_display_name("urn:x:1", "Sam Wang")
        assert upd.call_count == 1


class TestIngest:
    @staticmethod
    def _run(tmp_path, jid):
        (tmp_path / "whatsapp_conversations.json").write_text(json.dumps([{
            "tier": "whatsapp_dm", "participants": [jid],
            "last_message": "2025-06-15T00:00:00+00:00", "confidence": 1.0}]))
        with patch("ostler_fda.pwg_ingest._update_last_contact"), \
             patch("ostler_fda.pwg_ingest._sparql_update") as upd, \
             patch("ostler_fda.pwg_ingest._resolve_merged", new=lambda u: u), \
             patch("ostler_fda.pwg_ingest._person_exists", return_value=False), \
             patch("ostler_fda.pwg_ingest._observe_identifier", return_value=False):
            result = p.ingest_whatsapp(tmp_path)
        return result, " ".join(str(c) for c in upd.call_args_list)

    def test_placeholder_creates_person_without_a_name(self, tmp_path):
        result, text = self._run(tmp_path, _LID + JID_SUFFIX_PERSON)
        assert result["people_created"] == 1          # tier-0 person appears
        assert "a pwg:Person" in text and "whatsapp_lid" in text
        assert "WhatsApp contact" not in text         # but no name
        assert "displayNameProvisional" in text

    def test_phone_person_keeps_phone_handle_name(self, tmp_path):
        result, text = self._run(tmp_path, _NANP + JID_SUFFIX_PERSON)
        assert result["people_created"] == 1
        assert f'pwg:displayName "+{_NANP}"' in text
        assert "displayNameProvisional" in text
