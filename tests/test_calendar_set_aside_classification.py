#!/usr/bin/env python3
"""Set-aside calendar classification (lib/ostler-confirm-calendars.py).

Holiday, birthday, Siri suggestion, subscribed and reminders calendars are not
anyone's diary, so the end-of-install calendar screen sets them aside instead
of asking whose they are. These tests pin:

  * each kind is recognised from Calendar METADATA, whatever its title says
    (the holiday and birthday fixtures carry German titles);
  * the small English title list is only a fallback for when the metadata
    cannot be read;
  * a title shared by an ordinary calendar and a system one is never hidden;
  * the CONSUMER: a set-aside entry, read by the vendored CM041 reader, is
    withheld at L3 and never lands as the operator's personal diary.

Values in the metadata fixtures were measured on a real macOS 26
Calendar.sqlitedb on 2026-10-15. All names are invented.
"""
import importlib.util
import json
import os
import sqlite3
import sys
import tempfile
import types
from pathlib import Path

REPO = Path(os.environ.get("CAL_TEST_REPO_ROOT") or Path(__file__).resolve().parent.parent)
_spec = importlib.util.spec_from_file_location(
    "confirm_calendars", str(REPO / "lib" / "ostler-confirm-calendars.py")
)
cc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cc)


def _meta(store_type, flags=0, external_id=None, subcal_url=None, title="x"):
    return {"title": title, "store_type": store_type, "flags": flags,
            "external_id": external_id, "subcal_url": subcal_url}


def test_holiday_by_external_id_in_any_language():
    m = _meta(4, 6361097, "__HolidayCalendar__", "https://h.example.invalid/x.ics",
              title="Feiertage in Deutschland")
    assert cc.classify_set_aside(m) == "holiday"


def test_birthday_by_store_type_in_any_language():
    assert cc.classify_set_aside(_meta(5, 5, title="Geburtstage")) == "birthday"
    assert cc.classify_set_aside(_meta(5, 519, title="Anniversaires")) == "birthday"


def test_siri_suggestions_by_flag():
    nl = _meta(5, 524295, title="Found in Natural Language")
    mail = _meta(5, 262149, title="Found in Mail")
    assert cc.classify_set_aside(nl) == "suggestion"
    assert cc.classify_set_aside(mail) == "suggestion"


def test_subscribed_by_store_type_or_subscription_url():
    assert cc.classify_set_aside(_meta(4, 0, title="rowing club")) == "subscribed"
    # Subscribed through iCloud: the store is CalDAV, the URL says subscription.
    m = _meta(2, 6291465, "/1/calendars/rc", "https://f.example.invalid/r.ics")
    assert cc.classify_set_aside(m) == "subscribed"


def test_reminders_by_store_type():
    assert cc.classify_set_aside(_meta(6, 4, "scheduled", title="Scheduled Reminders")) == "reminders"


def test_ordinary_calendar_is_not_set_aside():
    assert cc.classify_set_aside(_meta(2, 0, "/1/calendars/w", title="Work")) == ""
    # A customer's own iCloud calendar NAMED "Birthdays" is still theirs:
    # with metadata present, the title is never consulted.
    assert cc.classify_set_aside(_meta(2, 0, "/1/calendars/b", title="Birthdays")) == ""


def test_title_fallback_only_without_metadata():
    for title, kind in [("Found in Natural Language", "suggestion"),
                        ("Birthdays", "birthday"),
                        ("Scheduled Reminders", "reminders"),
                        ("allotment rota", "")]:
        got = cc.set_aside_for(title, {})
        assert got == kind, (title, got)


def test_shared_title_is_never_hidden():
    meta = {"Birthdays": [_meta(5, 5, title="Birthdays"),
                          _meta(2, 0, "/1/calendars/b", title="Birthdays")]}
    assert cc.set_aside_for("Birthdays", meta) == ""


def test_metadata_read_from_a_calendar_database():
    d = tempfile.mkdtemp()
    db = os.path.join(d, "Calendar.sqlitedb")
    c = sqlite3.connect(db)
    c.execute("CREATE TABLE Store (ROWID INTEGER PRIMARY KEY, name TEXT, type INTEGER)")
    c.execute("CREATE TABLE Calendar (ROWID INTEGER PRIMARY KEY, store_id INTEGER,"
              " title TEXT, flags INTEGER, external_id TEXT, subcal_url TEXT)")
    c.executemany("INSERT INTO Store VALUES (?,?,?)", [(1, "iCloud", 2), (2, "Other", 5)])
    c.executemany("INSERT INTO Calendar VALUES (?,?,?,?,?,?)", [
        (1, 1, "Personal", 0, "/1/p", None),
        (2, 2, "Geburtstage", 5, None, None),
    ])
    c.commit()
    c.close()
    meta = cc.load_calendar_meta(db)
    assert cc.set_aside_for("Geburtstage", meta) == "birthday"
    assert cc.set_aside_for("Personal", meta) == ""
    # An unreadable database is a fallback, not a crash.
    assert cc.load_calendar_meta(os.path.join(d, "absent.sqlitedb")) == {}


def test_set_aside_answer_writes_exclusion():
    payload = cc.build_calendars_json([
        {"match": "Personal", "owner": "You", "type": "personal", "include": "1", "set_aside": ""},
        {"match": "Geburtstage", "owner": "You", "type": "personal", "include": "0", "set_aside": "birthday"},
    ])
    by = {e["match"]: e for e in payload["calendars"]}
    assert by["Personal"] == {"match": "Personal", "owner": "You", "type": "personal"}
    assert by["Geburtstage"]["include"] is False
    assert by["Geburtstage"]["set_aside"] == "birthday"
    assert by["Geburtstage"]["type"] == "other"


def _load_cm041_reader():
    """Import the VENDORED reader with its network/graph deps stubbed out."""
    vend = REPO / "vendor" / "cm041"
    stubs = {
        "httpx": types.ModuleType("httpx"),
        "contact_syncer": types.ModuleType("contact_syncer"),
        "contact_syncer.config": types.ModuleType("contact_syncer.config"),
        "identity_resolver": types.ModuleType("identity_resolver"),
        "identity_resolver.models": types.ModuleType("identity_resolver.models"),
        "identity_resolver.resolver": types.ModuleType("identity_resolver.resolver"),
    }
    stubs["contact_syncer"].__path__ = [str(vend / "contact_syncer")]
    stubs["contact_syncer"].config = stubs["contact_syncer.config"]
    stubs["contact_syncer.config"].USER_DISPLAY_NAME = "Jane Doe"
    stubs["identity_resolver.models"].PersonIdentity = object
    stubs["identity_resolver.resolver"].IdentityResolver = object
    saved = {k: sys.modules.get(k) for k in stubs}
    sys.modules.update(stubs)
    try:
        spec = importlib.util.spec_from_file_location(
            "cm041_google_calendar", str(vend / "contact_syncer" / "google_calendar.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    finally:
        for k, v in saved.items():
            if v is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = v


def test_consumer_withholds_a_set_aside_calendar():
    gc = _load_cm041_reader()
    payload = cc.build_calendars_json([
        {"match": "Personal", "owner": "You", "type": "personal", "include": "1"},
        {"match": "Geburtstage", "owner": "You", "type": "personal",
         "include": "0", "set_aside": "birthday"},
    ])
    d = tempfile.mkdtemp()
    p = os.path.join(d, "calendars.json")
    with open(p, "w", encoding="utf-8") as f:
        json.dump(payload, f)
    prov = gc.load_calendar_provenance(p)
    assert len(prov) == 2
    _, ctype, level = gc.resolve_calendar_provenance(
        {"source_calendar": "Geburtstage"}, prov)
    assert level == "L3", level
    assert ctype != "personal"
    # Control: the same reader on an ordinary calendar gives L1, so an L3 here
    # is the set-aside entry's doing, not a reader that returns L3 for all.
    _, ctype_p, level_p = gc.resolve_calendar_provenance(
        {"source_calendar": "Personal"}, prov)
    assert (ctype_p, level_p) == ("personal", "L1"), (ctype_p, level_p)


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    passed = failed = 0
    for fn in fns:
        try:
            fn()
        except Exception as exc:  # report every test, not just the first red
            failed += 1
            print(f"FAIL {fn.__name__}: {type(exc).__name__}: {exc}")
        else:
            passed += 1
            print(f"ok   {fn.__name__}")
    print(f"\npassed {passed}, failed {failed}")
    sys.exit(1 if failed else 0)
