"""CM051 #2578: a WhatsApp LID (linked-device id) presented through the
ordinary phone-JID suffix (@s.whatsapp.net) must never be formatted as a
"+<digits>" phone in cm048_pipeline's surfaced ``pwg:chatIdentifier``
literal. Same bug class as CM051 #2543 (ostler_fda's pwg_ingest.py) and
CM051 #2545 (CM041's identity_resolver), in a third tree.

Run against THIS vendored copy (vendor/cm048_pipeline/src/ingest.py), the
one that actually ships, not the CM048 source repo -- a test proven only
against source proves nothing about what a customer runs. See CM048 PR #80
for the source-side fix this mirrors.

All identifiers here are SYNTHETIC / reserved (Rule 0): no real personal
data, composed from fragments so no PII-shaped literal sits in this file's
source text.
"""
from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
# Same pattern as tests/test_every_conversation_produces_all_four_artefacts.py:
# ingest.py uses relative imports (`from . import outstanding_todos`), so it
# must be imported as part of the `src` package, not loaded standalone.
sys.path.insert(0, str(ROOT / "vendor" / "cm048_pipeline"))
from src.ingest import (  # noqa: E402
    _normalise_chat_identifier,
    _whatsapp_jid_is_genuine_phone,
)

# NANP reserved fictional exchange (555-01xx) with a real area code, so
# phonenumbers accepts it as VALID.
_NANP_RESERVED = "1" + "415" + "555" + "0100"

# A WhatsApp LID is 14-15 digits with no genuine country-code structure.
_LID_SHAPED = "9" * 15

# A LID whose LEADING digits happen to form a real, allocated country code
# (the UK's, "44") -- proves the discriminator checks the FULL number, not
# merely a calling-code prefix.
_LID_WITH_REAL_LEADING_COUNTRY_CODE = "44" + "1" * 13


class TestWhatsappJidIsGenuinePhone:
    def test_genuine_phone_is_accepted(self):
        assert _whatsapp_jid_is_genuine_phone(_NANP_RESERVED) is True

    def test_lid_shaped_digits_are_rejected(self):
        assert _whatsapp_jid_is_genuine_phone(_LID_SHAPED) is False

    def test_leading_real_country_code_does_not_rescue_a_lid_shaped_number(self):
        assert _whatsapp_jid_is_genuine_phone(_LID_WITH_REAL_LEADING_COUNTRY_CODE) is False

    def test_empty_and_non_digit_are_rejected(self):
        assert _whatsapp_jid_is_genuine_phone("") is False
        assert _whatsapp_jid_is_genuine_phone("not-a-phone") is False


class TestNormaliseChatIdentifier:
    def test_whatsapp_genuine_phone_jid_formats_as_phone(self):
        jid = _NANP_RESERVED + "@s.whatsapp.net"
        assert _normalise_chat_identifier("whatsapp", jid) == "+" + _NANP_RESERVED

    def test_whatsapp_lid_shaped_jid_is_not_rendered_as_a_number(self):
        """THE BUG, demonstrated directly: an LID presented through the
        ordinary phone-JID suffix must come back UNCHANGED (the raw JID),
        never reformatted as "+<LID digits>"."""
        jid = _LID_SHAPED + "@s.whatsapp.net"
        result = _normalise_chat_identifier("whatsapp", jid)
        assert result == jid
        assert result != "+" + _LID_SHAPED

    def test_whatsapp_lid_with_real_leading_country_code_is_not_rendered_as_a_number(self):
        jid = _LID_WITH_REAL_LEADING_COUNTRY_CODE + "@s.whatsapp.net"
        assert _normalise_chat_identifier("whatsapp", jid) == jid

    def test_non_whatsapp_channel_passes_through_verbatim(self):
        assert _normalise_chat_identifier("imessage", "+15550100") == "+15550100"
        assert _normalise_chat_identifier("imessage", _LID_SHAPED) == _LID_SHAPED

    def test_empty_raw_returns_empty(self):
        assert _normalise_chat_identifier("whatsapp", "") == ""
        assert _normalise_chat_identifier("whatsapp", None) == ""
