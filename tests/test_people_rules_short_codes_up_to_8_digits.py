"""P13 (v1.0.117 walk): a 7-digit SMS short code was listed as a person.

The shared People rule (vendor/cm041/assistant_api/people_rules.py, mirrored
by CM044 compiler/nameless.py and CM031 PersonNameFilter) now treats a short
code as up to 8 digits with no country code; 6 or fewer whatever the
punctuation. A "+" with 7+ digits, or 9+ digits, is a phone and the person is
shown (display-name ruling 2026-08-10). Synthetic values only.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

RULES = Path(__file__).resolve().parent.parent / "vendor" / "cm041" / "assistant_api" / "people_rules.py"
_spec = importlib.util.spec_from_file_location("_rules_p13", RULES)
R = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(R)


@pytest.mark.parametrize("code", ["6250123", "62501234", "625 0123", "6250-1234", "87099", "+12345"])
def test_short_codes_up_to_8_digits_are_not_people(code):
    assert R._is_short_code(code)
    assert R._is_nameless_name(code)
    assert R._is_sender_id_handle(code)
    assert not R._is_provisional_phone_name(code)
    assert R._is_nameless_name("Bank", handles=[code])


@pytest.mark.parametrize("phone", ["625012345", "+6250123", "+62501234", "+44 7700 900123", "07700 900123"])
def test_control_nine_digits_or_a_plus_is_still_a_person(phone):
    assert not R._is_short_code(phone)
    assert not R._is_nameless_name(phone)
    assert not R._is_sender_id_handle(phone)
    assert R._is_provisional_phone_name(phone)
    assert not R._is_nameless_name("Bank", handles=[phone])
