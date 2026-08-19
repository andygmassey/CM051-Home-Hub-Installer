"""#576: WhatsApp/iMessage chat-only contacts get a raw phone/handle as
their displayName because the extractor reads JIDs/handles only. Those
placeholders must be FLAGGED provisional so the resolver may overwrite
them and surfaces can suppress the "+44 7700 900123 as a name" leak.
"""
from ostler_fda import pwg_ingest as p
from ostler_fda import pwg_ingest as p_mod


def test_bare_e164_is_provisional():
    assert p._is_provisional_display_name("+447700900123") is True
    assert p._is_provisional_display_name("447700900123") is True
    assert p._is_provisional_display_name("+44 7700 900123") is True


def test_bare_email_is_provisional():
    assert p._is_provisional_display_name("someone@example.com") is True


def test_real_name_is_not_provisional():
    assert p._is_provisional_display_name("Sam Wang") is False
    assert p._is_provisional_display_name("Alex Brown") is False
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


# ---------------------------------------------------------------------------
# v1018-D659, composed shape: "<kinship word> <surname>".
#
# Reported on a real box: a spouse rendering with a kinship word in place of
# her given name, on a machine where the owner's mother had died the previous
# year. `_is_relationship_label` matched the WHOLE label only, so the bare
# word was refused and the composed form scored tier 2 -- a real human name --
# and every guard downstream then behaved correctly on a value that should
# never have been written.
#
# THE REFUSAL IS AT THE WRITE PATH, NOT IN THE TIER, and that is load-bearing.
# repair_placeholder_names.py DELETES any stored name whose tier is below
# PLACEHOLDER. Folding this shape into the tier makes it delete "Auntie Emma",
# including where that is somebody's ONLY name. The repair suite pins that
# case and caught it when this was first written as one predicate.
#
# All names below are SYNTHETIC.
# ---------------------------------------------------------------------------

def test_composed_kinship_is_refused_at_the_write_path():
    for label in ("Mum Okonjo", "Dad Smith", "Mummy Jones", "Grandad Brown",
                  "Auntie Pat", "Uncle Bob", "Stepdad Clarke",
                  "Godmother Clare", "Hubby Wilson"):
        assert p_mod._is_kinship_composed_label(label) is True, label


def test_composed_kinship_keeps_a_delete_safe_tier():
    # The repair pass must still see these as names, or it deletes them.
    for label in ("Mum Okonjo", "Auntie Emma", "Mum Zhang", "Papa Okonkwo"):
        assert p_mod._display_name_tier(label) == p_mod._NAME_TIER_NAME, label
        assert p_mod._is_relationship_label(label) is False, label


def test_apostrophe_surname_does_not_reopen_the_hole():
    # The punctuation strip yields three tokens. A len == 2 test passes every
    # example above and lets this one through, which the first fix did.
    assert p_mod._is_kinship_composed_label("Grandma O'Rourke") is True


def test_kinship_words_that_double_as_real_names_survive():
    for label in ("Nan Goldin", "Ma Rainey", "Pop Smith", "Sis Jones",
                  "Aunt Sally", "Boy George", "Son Volt", "House Wilson"):
        assert p_mod._is_kinship_composed_label(label) is False, label
        assert p_mod._display_name_tier(label) == p_mod._NAME_TIER_NAME, label


def test_an_ordinary_name_is_never_touched():
    for label in ("Fenella Okonjo", "Zhang Wei", "Marta Ilves",
                  "Ciaran O'Rourke", "Sam Wang"):
        assert p_mod._is_kinship_composed_label(label) is False, label
        assert p_mod._display_name_tier(label) == p_mod._NAME_TIER_NAME, label


def test_a_bare_kinship_word_is_still_refused_and_still_deletable():
    for label in ("Mum", "mum", "  Mum  ", "my mum", "big sis", "Nan"):
        assert p_mod._is_relationship_label(label) is True, label
        assert p_mod._display_name_tier(label) == p_mod._NAME_TIER_REFUSED, label
