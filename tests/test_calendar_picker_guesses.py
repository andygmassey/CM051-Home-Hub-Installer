#!/usr/bin/env python3
"""118 Q32b: the calendar check screen's guesses, and the picker that corrects them.

The 117 walk showed four wrong guesses on the one-screen calendar check:
another person's calendar marked "yours", the owner's own possessive calendar
marked "family", one region's holidays split across two groups, and a family
row that read "Family: Family, family". Each arm below is one of those
behaviours, on synthetic cast names only (owner "Jane Doe").

Run: python3 tests/test_calendar_picker_guesses.py   (exit 0 all pass)
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HELPER = REPO / "lib" / "ostler-confirm-calendars.py"
_spec = importlib.util.spec_from_file_location("confirm_calendars", str(HELPER))
cc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cc)

OWNER = "Jane Doe"


def _meta(store_type, flags=0, external_id=None, subcal_url=None, title="x"):
    return {"title": title, "store_type": store_type, "flags": flags,
            "external_id": external_id, "subcal_url": subcal_url}


# ── 1. The owner's own possessive calendar is hers, never "family" ──────────
def test_owners_possessive_calendar_is_yours():
    assert cc.guess_owner_type("Jane's Calendar", OWNER) == ("You", "personal")
    assert cc.guess_owner_type("Jane’s Calendar", OWNER) == ("You", "personal")
    assert cc.guess_owner_type("Jane's work calendar", OWNER) == ("You", "work")


# ── 2. Another person's calendar is never marked "yours" ────────────────────
def test_another_persons_address_calendar_is_shared_not_yours():
    assert cc.guess_owner_type("bob.jones@example.com", OWNER) == ("bob.jones@example.com", "shared")


def test_the_owners_own_address_is_yours():
    assert cc.guess_owner_type("jane.doe@example.com", OWNER) == ("You", "personal")
    assert cc.guess_owner_type("jd@example.net", OWNER, ["JD@example.net"]) == ("You", "personal")


def test_another_persons_possessive_calendar_is_theirs():
    assert cc.guess_owner_type("Bob's Calendar", OWNER) == ("Bob", "shared")


def test_a_named_person_is_shared_not_family():
    assert cc.guess_owner_type("Sam Patel", OWNER) == ("Sam Patel", "shared")


def test_a_calendar_label_is_not_a_persons_name():
    assert cc.guess_owner_type("family calendar", OWNER) == ("Family", "family")
    assert cc.guess_owner_type("personal calendar", OWNER) == ("You", "personal")


# ── 3. Holidays group together whatever their region or source ─────────────
def test_holiday_feed_and_google_holiday_calendar_are_holidays():
    feed = _meta(4, 0, None, "https://hols.example.invalid/bank-holidays.ics", title="Region A holidays")
    goog = _meta(2, 0, "en.xa#holiday@group.v.calendar.google.com", None, title="Holidays in Region B")
    apple = _meta(4, 6361097, "__HolidayCalendar__", "https://h.example.invalid/x.ics", title="Region B Holidays")
    assert [cc.classify_set_aside(m) for m in (feed, goog, apple)] == ["holiday"] * 3
    # A subscribed feed that is not holidays stays "subscribed".
    assert cc.classify_set_aside(_meta(4, 0, None, "https://f.example.invalid/rowing.ics")) == "subscribed"


def test_one_title_from_two_holiday_sources_is_still_set_aside():
    meta = {"Region A holidays": [
        _meta(4, 6361097, "__HolidayCalendar__", None, title="Region A holidays"),
        _meta(4, 0, None, "https://f.example.invalid/feed.ics", title="Region A holidays"),
    ]}
    assert cc.set_aside_for("Region A holidays", meta) == "holiday"


def test_holidays_sort_together_after_ordinary_calendars():
    events = ([{"calendar_name": "Region A holidays", "title": "h"}] * 3
              + [{"calendar_name": "Personal", "title": "p"}]
              + [{"calendar_name": "Found in Mail", "title": "s"}] * 9
              + [{"calendar_name": "Region B Holidays", "title": "h"}])
    meta = {
        "Region A holidays": [_meta(4, 0, None, "https://a.example.invalid/holidays.ics")],
        "Region B Holidays": [_meta(4, 6361097, "__HolidayCalendar__")],
        "Found in Mail": [_meta(5, 262149)],
        "Personal": [_meta(2, 0, "/1/p")],
    }
    order = [(c["match"], c["category"]) for c in cc.aggregate_calendars(events, OWNER, meta)]
    assert order == [("Personal", "yours"), ("Region A holidays", "holidays"),
                     ("Region B Holidays", "holidays"), ("Found in Mail", "ignore")], order


# ── 4. The picker's answer becomes calendars.json, and a bad answer never half-applies ──
ROWS = [
    {"match": "Personal", "owner": "You", "type": "personal", "set_aside": "", "category": "yours"},
    {"match": "Jane's Calendar", "owner": "You", "type": "personal", "set_aside": "", "category": "yours"},
    {"match": "bob.jones@example.com", "owner": "bob.jones@example.com", "type": "shared", "set_aside": "", "category": "shared"},
    {"match": "Region A holidays", "owner": "You", "type": "personal", "set_aside": "holiday", "category": "holidays"},
    {"match": "rowing", "owner": "You", "type": "personal", "set_aside": "subscribed", "category": "ignore"},
]


def test_picks_map_to_the_reader_shape():
    answers, note = cc.answers_from_categories(ROWS, "yours,family,shared,ignore,holidays")
    assert note == ""
    cals = {c["match"]: c for c in cc.build_calendars_json(answers)["calendars"]}
    assert cals["Personal"] == {"match": "Personal", "owner": "You", "type": "personal"}
    assert cals["Jane's Calendar"] == {"match": "Jane's Calendar", "owner": "Family", "type": "family"}
    assert cals["bob.jones@example.com"]["owner"] == "bob.jones@example.com"
    assert cals["bob.jones@example.com"]["type"] == "shared"
    # "Ignore" keeps the calendar's own kind; "Holidays" files it with the holidays.
    assert cals["Region A holidays"]["include"] is False and cals["Region A holidays"]["set_aside"] == "holiday"
    assert cals["rowing"]["include"] is False and cals["rowing"]["set_aside"] == "holiday"
    answers, _ = cc.answers_from_categories(ROWS, "yours,yours,yours,holidays,ignore")
    cals = {c["match"]: c for c in cc.build_calendars_json(answers)["calendars"]}
    assert cals["rowing"]["set_aside"] == "subscribed"


def test_a_malformed_answer_keeps_the_prefill_and_says_so():
    for bad in ("yours,family", "yours,family,shared,holidays,maybe", ""):
        answers, note = cc.answers_from_categories(ROWS, bad)
        assert "not applied" in note, bad
        assert [a["include"] for a in answers] == ["1", "1", "1", "0", "0"], bad


def test_cli_rows_and_categories_round_trip():
    d = tempfile.mkdtemp()
    events = os.path.join(d, "events.json")
    json.dump([{"calendar_name": "Jane's Calendar", "title": "Dentist"},
               {"calendar_name": "bob.jones@example.com", "title": "Flight"}], open(events, "w"))
    rows = subprocess.run([sys.executable, str(HELPER), "enumerate", "--events", events,
                           "--owner-name", OWNER, "--calendar-db", os.path.join(d, "none.sqlitedb")],
                          capture_output=True, text=True, check=True).stdout
    lines = [l.split("\t") for l in rows.splitlines()]
    assert all(len(l) == 7 for l in lines), lines
    assert {l[0]: l[6] for l in lines} == {"Jane's Calendar": "yours", "bob.jones@example.com": "shared"}
    rows_path = os.path.join(d, "rows.tsv")
    open(rows_path, "w").write(rows)
    out = os.path.join(d, "calendars.json")
    picks = ",".join("family" if l[0].startswith("Jane") else "ignore" for l in lines)
    subprocess.run([sys.executable, str(HELPER), "write", "--rows", rows_path,
                    "--categories", picks, "--out", out], check=True, capture_output=True)
    cals = {c["match"]: c for c in json.load(open(out))["calendars"]}
    assert cals["Jane's Calendar"]["type"] == "family"
    assert cals["bob.jones@example.com"]["include"] is False


if __name__ == "__main__":
    fails = 0
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    for name, fn in tests:
        try:
            fn()
            print(f"ok   {name}")
        except AssertionError as exc:
            fails += 1
            print(f"FAIL {name}: {exc}")
    print(f"{len(tests) - fails} passed, {fails} failed")
    sys.exit(1 if fails or not tests else 0)
