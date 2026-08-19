"""Unit tests for the canonical privacy model (contact_syncer.privacy_model).

Covers the level-picker (type + source -> level), the read-time legacy
numeric -> string mapping (inverted sense), and the fail-closed defaults.
No network, no graph - pure functions on fixtures.
"""
from __future__ import annotations

import pytest

from contact_syncer import privacy_model as pm


# -- level_for: type + source -> level ----------------------------------------

class TestLevelFor:
    def test_public_social_sources_are_l2(self):
        for src in (
            "linkedin_connection",
            "linkedin_career",
            "linkedin_endorsement",
            "linkedin_recommendation",
            "twitter_synced_contact",
            "facebook_friend",
            "facebook_event",
            "instagram",
            "google_calendar",
        ):
            assert pm.level_for(source=src) == pm.LEVEL_L2, src

    def test_private_channels_are_l1_never_l2(self):
        for src in (
            "whatsapp_contact",
            "imessage",
            "email_signature",
            "user_asserted",
            "linkedin_messaging",
            "linkedin_message",
        ):
            level = pm.level_for(source=src)
            assert level == pm.LEVEL_L1, src
            assert level not in pm.PUBLISHABLE_LEVELS, src

    def test_private_channel_never_l2_is_the_invariant(self):
        # The leak-prevention invariant: no private-channel source may ever
        # resolve to a publishable level.
        for src in pm.PRIVATE_CHANNEL_SOURCE_MARKERS:
            assert pm.level_for(source=src) not in pm.PUBLISHABLE_LEVELS, src

    def test_health_and_finance_force_l0(self):
        assert pm.level_for(source="whatsapp_contact", tags=["health"]) == pm.LEVEL_L0
        assert pm.level_for(source="linkedin_connection", tags=["finance"]) == pm.LEVEL_L0
        assert pm.level_for(source="medical_note") == pm.LEVEL_L0
        assert pm.level_for(source="bank_statement") == pm.LEVEL_L0

    def test_health_outranks_public_source(self):
        # Even a "public" source carrying a health tag must drop to L0.
        assert pm.level_for(source="google_calendar", tags=["health"]) == pm.LEVEL_L0

    def test_unknown_source_fails_closed_to_private(self):
        assert pm.level_for(source="some_unknown_thing") == pm.LEVEL_L1
        assert pm.level_for(source=None) == pm.LEVEL_L1
        assert pm.level_for() == pm.LEVEL_L1

    def test_unknown_source_is_not_publishable(self):
        assert pm.level_for(source="mystery") not in pm.PUBLISHABLE_LEVELS

    def test_tags_as_string_or_list(self):
        assert pm.level_for(source="x", tags="health") == pm.LEVEL_L0
        assert pm.level_for(source="x", tags=["a", "finance", "b"]) == pm.LEVEL_L0

    def test_case_insensitive_source(self):
        assert pm.level_for(source="WhatsApp_Contact") == pm.LEVEL_L1
        assert pm.level_for(source="Facebook_Friend") == pm.LEVEL_L2


# -- numeric -> string legacy mapping (inverted sense) ------------------------

class TestNumericToString:
    def test_compartment_names_by_sensitivity(self):
        assert pm.numeric_compartment_to_string("L0Personal") == pm.LEVEL_L0
        assert pm.numeric_compartment_to_string("L1Family") == pm.LEVEL_L1
        assert pm.numeric_compartment_to_string("L1Private") == pm.LEVEL_L1
        assert pm.numeric_compartment_to_string("L2Trusted") == pm.LEVEL_L2
        assert pm.numeric_compartment_to_string("L3Community") == pm.LEVEL_L3
        # Inverted sense: public/commercial/broadcast all collapse to L2.
        assert pm.numeric_compartment_to_string("L4Public") == pm.LEVEL_L2
        assert pm.numeric_compartment_to_string("L5Commercial") == pm.LEVEL_L2
        assert pm.numeric_compartment_to_string("L6Broadcast") == pm.LEVEL_L2

    def test_full_uri_local_name_is_stripped(self):
        assert (
            pm.numeric_compartment_to_string(
                "https://pwg.dev/ontology#L2Trusted"
            )
            == pm.LEVEL_L2
        )

    def test_numeric_digit_inverted_sense(self):
        # The digit in numeric is NOT the digit in the string scheme.
        assert pm.numeric_compartment_to_string(2) == pm.LEVEL_L2
        assert pm.numeric_compartment_to_string(4) == pm.LEVEL_L2  # public -> L2
        assert pm.numeric_compartment_to_string(0) == pm.LEVEL_L0
        assert pm.numeric_compartment_to_string("4") == pm.LEVEL_L2

    def test_bool_is_rejected(self):
        assert pm.numeric_compartment_to_string(True) == pm.DEFAULT_UNKNOWN_LEVEL

    def test_unknown_fails_closed(self):
        assert pm.numeric_compartment_to_string(None) == pm.DEFAULT_UNKNOWN_LEVEL
        assert pm.numeric_compartment_to_string("") == pm.DEFAULT_UNKNOWN_LEVEL
        assert pm.numeric_compartment_to_string("nonsense") == pm.DEFAULT_UNKNOWN_LEVEL
        assert pm.numeric_compartment_to_string(99) == pm.DEFAULT_UNKNOWN_LEVEL


# -- normalise_level ----------------------------------------------------------

class TestNormaliseLevel:
    def test_valid_levels_pass_through(self):
        for lvl in pm.CANONICAL_LEVELS:
            assert pm.normalise_level(lvl) == lvl

    def test_case_insensitive(self):
        assert pm.normalise_level("l0") == pm.LEVEL_L0
        assert pm.normalise_level(" l3 ") == pm.LEVEL_L3

    def test_unknown_fails_closed(self):
        assert pm.normalise_level("L9") == pm.DEFAULT_UNKNOWN_LEVEL
        assert pm.normalise_level(None) == pm.DEFAULT_UNKNOWN_LEVEL
        assert pm.normalise_level("") == pm.DEFAULT_UNKNOWN_LEVEL

    def test_default_unknown_is_body_private(self):
        assert pm.DEFAULT_UNKNOWN_LEVEL == pm.LEVEL_L3


# -- Twin-drift guard (C2) ----------------------------------------------------
#
# The canonical L0-L3 set and the legacy numeric->string map are SHARED across
# the privacy_model twins (CM041 contact_syncer, CM019 services/mcp,
# CM044 compiler). There is no cross-repo CI, so each repo pins the canonical
# values here. If the shared table drifts in this repo, this test fails and
# the editor is reminded to mirror the change in the other twins.
#
# Only the SHARED part is pinned. The per-consumer ABSENT-default is allowed to
# differ by design (CM041/CM019 absent -> L3 withhold; CM044 wiki absent -> L1
# owner-only) and is NOT asserted here.

#: The four canonical string levels, most-private first. SHARED across twins.
CANONICAL_LEVEL_SET = ("L0", "L1", "L2", "L3")

#: Legacy named compartment -> canonical string, BY SENSITIVITY. SHARED.
CANONICAL_LEGACY_NAME_MAP = {
    "L0Personal": "L0",
    "L1Family": "L1",
    "L1Private": "L1",
    "L2Trusted": "L2",
    "L3Community": "L3",
    "L4Public": "L2",
    "L5Commercial": "L2",
    "L6Broadcast": "L2",
}

#: Legacy bare digit -> canonical string, BY SENSITIVITY. SHARED.
CANONICAL_LEGACY_DIGIT_MAP = {
    0: "L0",
    1: "L1",
    2: "L2",
    3: "L3",
    4: "L2",
    5: "L2",
    6: "L2",
}


class TestTwinDriftGuard:
    def test_canonical_level_set_pinned(self):
        assert pm.CANONICAL_LEVELS == CANONICAL_LEVEL_SET

    def test_legacy_name_map_pinned(self):
        assert pm.LEGACY_NUMERIC_NAME_TO_STRING == CANONICAL_LEGACY_NAME_MAP

    def test_legacy_digit_map_pinned(self):
        assert pm.LEGACY_NUMERIC_DIGIT_TO_STRING == CANONICAL_LEGACY_DIGIT_MAP

    def test_legacy_mapping_resolves_via_public_api(self):
        # Belt-and-braces: the values also resolve through the public mapper,
        # so a refactor of the internal tables that keeps the API correct is
        # still caught if it changes a value.
        for name, expected in CANONICAL_LEGACY_NAME_MAP.items():
            assert pm.numeric_compartment_to_string(name) == expected, name
        for digit, expected in CANONICAL_LEGACY_DIGIT_MAP.items():
            assert pm.numeric_compartment_to_string(digit) == expected, digit
