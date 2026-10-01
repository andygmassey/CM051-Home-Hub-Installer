"""CM051 #2543: a WhatsApp LID presented through the ordinary phone-JID
suffix must never become a "phone" identifier or a digit-shaped displayName.

Run against THIS vendored copy of pwg_ingest.py (the one that actually ships
in the DMG), not HR015's -- this tree carries its own grafts (e.g.
_creation_name_triples / _upsert_display_name, v1018-D658/D659) that HR015's
copy does not, so a test proven against HR015 alone does not prove anything
about what a customer runs. See HR015 PR #1017 for the upstream-converging
fix this mirrors.

Synthetic data only.
"""
from __future__ import annotations

import json
from unittest.mock import patch

from ostler_fda import pwg_ingest as p
from ostler_fda.whatsapp_history import JID_SUFFIX_PERSON

# NANP reserved fictional exchange (555-01xx) with a real area code, so
# phonenumbers accepts it as VALID -- these tests need a genuinely valid
# number to exercise _whatsapp_jid_is_genuine_phone's "yes" branch. Composed
# from fragments so the repo's PII guard (phone-shape regex over the literal
# source text) never fires. Local part only (no "+").
_NANP_RESERVED = "1" + "415" + "555" + "0100"

# A WhatsApp LID is 14-15 digits with no genuine country-code structure.
# Composed, not written as one literal run: the repo's PII guard flags any
# bare 15+ digit sequence, and a long numeric id has no reserved range to
# swap to -- "compose them at runtime" is the guard's own prescribed fix.
_LID_SHAPED = "1" + "0" * 13 + "1"

# For the discriminator proof below: a 15-digit string whose LEADING digits
# are "44" (a real, allocated country code -- the UK's) but whose total
# length is still LID-shaped (15 digits), not a length any real UK number
# reaches (UK numbers top out at country code + 10 digits = 12 total).
# Composed for the same PII-guard reason as above.
_LID_WITH_REAL_LEADING_COUNTRY_CODE = "44" + "1" * 13


class TestWhatsappJidIsGenuinePhone:
    def test_genuine_phone_is_accepted(self):
        assert p._whatsapp_jid_is_genuine_phone(_NANP_RESERVED) is True

    def test_lid_shaped_digits_are_rejected(self):
        assert p._whatsapp_jid_is_genuine_phone(_LID_SHAPED) is False

    def test_leading_real_country_code_does_not_rescue_a_lid_shaped_number(self):
        """THE DISCRIMINATOR, PROVEN NOT ASSUMED. A naive "does it start with
        a real country code" check would wrongly accept this value --
        phonenumbers.is_valid_number does not, because validity depends on
        the FULL number matching an allocated length/pattern for that
        country, not merely sharing its calling code prefix. A 15-digit
        string starting with "44" is 3-5 digits longer than any real UK
        number (country code + at most 10 national digits = 12 total), so
        it is invalid on length and pattern alone, exactly like an LID with
        no plausible leading digits at all."""
        assert _LID_WITH_REAL_LEADING_COUNTRY_CODE.startswith("44")
        assert len(_LID_WITH_REAL_LEADING_COUNTRY_CODE) == 15
        assert p._whatsapp_jid_is_genuine_phone(
            _LID_WITH_REAL_LEADING_COUNTRY_CODE
        ) is False

    def test_empty_and_non_digit_are_rejected(self):
        assert p._whatsapp_jid_is_genuine_phone("") is False
        assert p._whatsapp_jid_is_genuine_phone("not-digits") is False


class TestWhatsappDisplayName:
    def test_formats_a_genuine_phone(self):
        suffix = JID_SUFFIX_PERSON
        assert p._whatsapp_display_name(_NANP_RESERVED + suffix) == "+" + _NANP_RESERVED

    def test_non_numeric_local_part_unchanged(self):
        assert p._whatsapp_display_name("alice@example.com") == "alice"

    def test_lid_shaped_digits_are_not_rendered_as_a_number(self):
        suffix = JID_SUFFIX_PERSON
        assert p._whatsapp_display_name(_LID_SHAPED + suffix) == "WhatsApp contact"


class TestWhatsappPhoneE164:
    def test_genuine_phone_formats_to_e164(self):
        suffix = JID_SUFFIX_PERSON
        assert p._whatsapp_phone_e164(_NANP_RESERVED + suffix) == "+" + _NANP_RESERVED

    def test_lid_shaped_digits_return_none(self):
        """The writer-level contract: callers must not write this under
        identifierType "phone" when None comes back."""
        suffix = JID_SUFFIX_PERSON
        assert p._whatsapp_phone_e164(_LID_SHAPED + suffix) is None

    def test_non_numeric_passes_through(self):
        assert p._whatsapp_phone_e164("alice@example.com") == "alice@example.com"


class TestIngestWhatsapp:
    """Integration-level: the actual writer, against THIS vendored module."""

    _REAL_PHONE_JID = _NANP_RESERVED + JID_SUFFIX_PERSON
    _LID_SHAPED_JID = _LID_SHAPED + JID_SUFFIX_PERSON

    @staticmethod
    def _chats(jid: str) -> list:
        return [{
            "tier": "whatsapp_dm",
            "participants": [jid],
            "last_message": "2025-06-15T00:00:00+00:00",
            "confidence": 1.0,
        }]

    @patch("ostler_fda.pwg_ingest._update_last_contact")
    @patch("ostler_fda.pwg_ingest._sparql_update")
    @patch("ostler_fda.pwg_ingest._person_exists", return_value=False)
    @patch("ostler_fda.pwg_ingest._observe_identifier", return_value=False)
    def test_lid_shaped_participant_is_never_tagged_phone(
        self, mock_observe, mock_exists, mock_update, mock_last_contact, tmp_path
    ):
        (tmp_path / "whatsapp_conversations.json").write_text(
            json.dumps(self._chats(self._LID_SHAPED_JID))
        )
        result = p.ingest_whatsapp(tmp_path)
        assert result["status"] == "ok"
        assert result["people_created"] == 1

        sparql_text = " ".join(str(c) for c in mock_update.call_args_list)
        assert 'identifierType "phone"' not in sparql_text
        assert 'identifierType "whatsapp_lid"' in sparql_text
        assert "+" + _LID_SHAPED not in sparql_text

    @patch("ostler_fda.pwg_ingest._update_last_contact")
    @patch("ostler_fda.pwg_ingest._sparql_update")
    @patch("ostler_fda.pwg_ingest._person_exists", return_value=False)
    @patch("ostler_fda.pwg_ingest._observe_identifier", return_value=False)
    def test_genuine_phone_participant_is_tagged_phone(
        self, mock_observe, mock_exists, mock_update, mock_last_contact, tmp_path
    ):
        """CONTROL: the ordinary, resolved case is unaffected."""
        (tmp_path / "whatsapp_conversations.json").write_text(
            json.dumps(self._chats(self._REAL_PHONE_JID))
        )
        result = p.ingest_whatsapp(tmp_path)
        assert result["status"] == "ok"
        assert result["people_created"] == 1

        sparql_text = " ".join(str(c) for c in mock_update.call_args_list)
        assert 'identifierType "phone"' in sparql_text
        assert "+" + _NANP_RESERVED in sparql_text

    @patch("ostler_fda.pwg_ingest._update_last_contact")
    @patch("ostler_fda.pwg_ingest._sparql_update")
    @patch("ostler_fda.pwg_ingest._person_exists", return_value=True)
    @patch("ostler_fda.pwg_ingest._identifier_exists", return_value=False)
    @patch("ostler_fda.pwg_ingest._observe_identifier", return_value=False)
    def test_enrich_branch_also_normalises_and_never_tags_lid_as_phone(
        self, mock_observe, mock_id_exists, mock_exists, mock_update,
        mock_last_contact, tmp_path,
    ):
        """The "person already exists" branch wrote the raw JID local-part
        (no "+", never normalised) instead of _whatsapp_phone_e164's output,
        so the same real number from the create path and the enrich path
        could disagree in format."""
        (tmp_path / "whatsapp_conversations.json").write_text(
            json.dumps(self._chats(self._REAL_PHONE_JID))
        )
        p.ingest_whatsapp(tmp_path)
        sparql_text = " ".join(str(c) for c in mock_update.call_args_list)
        assert "+" + _NANP_RESERVED in sparql_text
        assert _NANP_RESERVED + JID_SUFFIX_PERSON not in sparql_text
