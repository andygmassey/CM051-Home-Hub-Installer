"""#576: WhatsApp/iMessage chat-only contacts get a raw phone/handle as
their displayName because the extractor reads JIDs/handles only. Those
placeholders must be FLAGGED provisional so the resolver may overwrite
them and surfaces can suppress the "+44 7700 900123 as a name" leak.
"""
from ostler_fda import pwg_ingest as p


def test_bare_e164_is_provisional():
    assert p._is_provisional_display_name("+447700900123") is True
    assert p._is_provisional_display_name("447700900123") is True
    assert p._is_provisional_display_name("+44 7700 900123") is True


def test_bare_email_is_provisional():
    assert p._is_provisional_display_name("someone@example.com") is True


def test_real_name_is_not_provisional():
    assert p._is_provisional_display_name("Danny Kwan") is False
    assert p._is_provisional_display_name("Arnaud Bonzom") is False
    # A human nickname with a few digits is still a name, not a phone.
    assert p._is_provisional_display_name("Agent 3-2-1") is False


def test_empty_is_provisional():
    assert p._is_provisional_display_name("") is True
    assert p._is_provisional_display_name("   ") is True


def test_whatsapp_display_name_placeholder_is_flagged_provisional():
    # End-to-end: the WhatsApp placeholder produced for an un-named JID
    # is exactly the value the provisional guard rejects as a name.
    display = p._whatsapp_display_name("447700900123@s.whatsapp.net")
    assert display == "+447700900123"
    assert p._is_provisional_display_name(display) is True
