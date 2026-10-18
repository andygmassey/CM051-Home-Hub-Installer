"""CM051 walk #2, item D (v1.0.107): is_possible_phone's first version (walk
#1) accepted a `+`-prefixed 14-digit value as "possible" under some country's
numbering plan even though it is not a real phone number -- measured on a
cold install, 7 of 2,345 People rows still carried exactly this shape.
Mirrors CM041 PR #187's own test suite against the copy that actually ships
(vendor/cm041).

All identifiers/numbers here are synthetic or OFCOM-reserved (Rule 0).
"""
from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR_CM041 = ROOT / "vendor" / "cm041"
if not VENDOR_CM041.is_dir():
    raise SystemExit(f"vendored cm041 missing: {VENDOR_CM041} (broken vendor layout)")
sys.path.insert(0, str(VENDOR_CM041))

from identity_resolver.normalise import is_possible_phone  # noqa: E402

# OFCOM mobile drama range: reserved for fiction use, POSSIBLE but not
# currently catalogued as a VALID assigned range by libphonenumber.
_UK_MOBILE_DRAMA_RANGE = "+44 7700 900200"

# OFCOM landline drama range: reserved, and phonenumbers-valid for GB too.
_UK_LANDLINE_E164 = "+442079460958"

# A WhatsApp LID / internal-id shape with no leading '+': fails to parse at
# all with no default country code, already covered before this change.
_LID_SHAPED_VALUE = "12345678901234"

# The gap this change closes: 14 raw digits, `+`-prefixed, obviously
# synthetic sequential digits. Chosen only because phonenumbers.
# is_possible_number() returns True for it under some country's numbering
# plan while is_valid_number() returns False -- the exact split walk #2
# measured on 7 real People rows (counts only; real values are customer
# data and never read into this codebase).
_PLUS_PREFIXED_14_DIGIT_POSSIBLE_BUT_INVALID = "+61234567890123"


def test_the_gap_fixture_reproduces_possible_true_valid_false():
    """Control: this fixture must actually exercise the split this test
    exists to close, or the assertions below prove nothing."""
    import phonenumbers
    parsed = phonenumbers.parse(_PLUS_PREFIXED_14_DIGIT_POSSIBLE_BUT_INVALID, None)
    assert phonenumbers.is_possible_number(parsed) is True
    assert phonenumbers.is_valid_number(parsed) is False


def test_refuses_the_plus_prefixed_14_digit_possible_but_invalid_value():
    assert is_possible_phone(_PLUS_PREFIXED_14_DIGIT_POSSIBLE_BUT_INVALID) is False


def test_refuses_the_same_value_with_a_country_code_configured():
    assert is_possible_phone(
        _PLUS_PREFIXED_14_DIGIT_POSSIBLE_BUT_INVALID, default_country_code=44,
    ) is False


def test_still_refuses_a_bare_lid_shaped_value_with_no_leading_plus():
    assert is_possible_phone(_LID_SHAPED_VALUE) is False
    assert is_possible_phone(_LID_SHAPED_VALUE, default_country_code=44) is False


def test_still_accepts_genuine_numbers_under_14_digits():
    """CONTROL: the 14-digit floor must not creep down and start refusing
    ordinary numbers. Both canonical fixtures below are 12 digits raw."""
    assert is_possible_phone(_UK_MOBILE_DRAMA_RANGE) is True
    assert is_possible_phone(_UK_LANDLINE_E164) is True
