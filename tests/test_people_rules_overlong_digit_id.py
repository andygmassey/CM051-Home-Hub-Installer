"""A bare digit run longer than E.164's 15 digits is not a phone number.

Walk v1.0.122 (Mini16): one People row was named by an 18-digit iMessage
handle. people_list hid it as a PHONE (_displayable_phone, >15 digits is never
a phone) but still listed the same digits as the person's NAME, marked
provisional_name, which the Hub UI does not read. Synthetic values only.
"""
import importlib.util
from pathlib import Path

RULES = Path(__file__).resolve().parent.parent / "vendor" / "cm041" / "assistant_api" / "people_rules.py"
_spec = importlib.util.spec_from_file_location("_rules_overlong", RULES)
pr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pr)

OVERLONG = "1" * 18          # synthetic: 18 digits, no "+"
PHONE = "+" + "4" * 11       # synthetic: + then 11 digits


def test_overlong_digit_name_is_not_a_provisional_phone():
    assert not pr._is_provisional_phone_name(OVERLONG)


def test_overlong_digit_name_is_nameless():
    assert pr._is_nameless_name(OVERLONG)
    assert pr._is_nameless_name("+" + "2" * 16)


def test_overlong_digit_person_is_not_counted():
    assert not pr.is_countable_person(OVERLONG, phones=[OVERLONG])


def test_controls_real_phone_and_human_name_unchanged():
    assert pr._is_provisional_phone_name(PHONE)
    assert not pr._is_nameless_name(PHONE)
    assert not pr._is_nameless_name("+" + "4" * 15)   # 15 digits: E.164 ceiling, still shown
    assert pr.is_countable_person(PHONE, phones=[PHONE])


def test_overlong_digits_yield_to_a_human_name():
    assert pr._best_display_name(OVERLONG, "Ada", "Example") == "Ada Example"
