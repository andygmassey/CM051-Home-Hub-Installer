#!/usr/bin/env python3
"""Tests for lib/ostler-confirm-calendars.py (end-of-install calendar confirm).

Verifies: enumeration + owner/type pre-fill heuristics, and that the written
calendars.json is in the EXACT shape the CM041 reader
(contact_syncer.google_calendar.load_calendar_provenance) accepts.

All fixtures are SYNTHETIC. No real personal data. See
PRODUCTISATION_CHECKLIST.md Rule 0.
"""
import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location(
    "confirm_calendars", str(REPO / "lib" / "ostler-confirm-calendars.py")
)
cc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cc)


def test_guess_owner_type_prefills():
    assert cc.guess_owner_type("work@example.com", "Jane Doe") == ("You", "personal")
    assert cc.guess_owner_type("Family", "Jane Doe") == ("Family", "family")
    assert cc.guess_owner_type("Work", "Jane Doe") == ("You", "work")
    assert cc.guess_owner_type("Calendar", "Jane Doe") == ("You", "personal")
    assert cc.guess_owner_type("Jane Doe", "Jane Doe") == ("You", "personal")
    assert cc.guess_owner_type("Jane", "Jane Doe") == ("You", "personal")
    # A different person's name -> that person, family.
    assert cc.guess_owner_type("Robin Carter", "Jane Doe") == ("Robin Carter", "family")


def test_aggregate_counts_and_samples():
    events = [
        {"calendar_name": "Work", "title": "Standup"},
        {"calendar_name": "Work", "title": "1:1"},
        {"calendar_name": "Robin Carter", "title": "Flight to Tokyo"},
        {"calendar_name": "", "title": "orphan"},  # no calendar -> dropped
        {"not_a_dict": True},
    ]
    cals = cc.aggregate_calendars(events, "Jane Doe")
    by_match = {c["match"]: c for c in cals}
    assert set(by_match) == {"Work", "Robin Carter"}
    assert by_match["Work"]["count"] == 2
    assert by_match["Work"]["type"] == "work"
    assert by_match["Robin Carter"]["owner"] == "Robin Carter"
    assert "Standup" in by_match["Work"]["samples"]


def test_build_calendars_json_normalises_type():
    answers = [
        {"match": "Work", "owner": "You", "type": "work"},
        {"match": "Family", "owner": "Family", "type": "family"},
        {"match": "Mystery", "owner": "", "type": "weird"},  # -> other, You
        {"match": "", "owner": "x", "type": "personal"},  # dropped (no match)
    ]
    payload = cc.build_calendars_json(answers)
    cals = payload["calendars"]
    assert len(cals) == 3
    mystery = [c for c in cals if c["match"] == "Mystery"][0]
    assert mystery["type"] == "other"
    assert mystery["owner"] == "You"


def test_written_json_accepted_by_cm041_reader():
    """The write path must produce something the real reader accepts.

    We inline the reader's acceptance contract (from
    contact_syncer/google_calendar.py::load_calendar_provenance on
    fix/calendar-owner-attribution): top-level dict, ``calendars`` is a list,
    each usable entry is a dict with a truthy ``match``.
    """
    payload = cc.build_calendars_json(
        [{"match": "Work", "owner": "You", "type": "work"}]
    )
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "calendars.json")
        with open(out, "w", encoding="utf-8") as f:
            json.dump(payload, f)
        with open(out, "r", encoding="utf-8") as f:
            data = json.load(f)

    assert isinstance(data, dict)
    entries = data.get("calendars")
    assert isinstance(entries, list)
    usable = [e for e in entries if isinstance(e, dict) and e.get("match")]
    assert len(usable) == 1
    e = usable[0]
    assert e["match"] == "Work" and e["owner"] == "You" and e["type"] == "work"
    # privacy_level intentionally absent -> reader derives L2 from type "work".
    assert "privacy_level" not in e


def test_write_and_enumerate_roundtrip_via_cli(tmp_path=None):
    """enumerate -> answers -> write, exercised through the CLI entrypoints."""
    d = Path(tempfile.mkdtemp())
    events_path = d / "calendar_events.json"
    events_path.write_text(json.dumps([
        {"calendar_name": "Work", "title": "Standup"},
        {"calendar_name": "Home", "title": "Dentist"},
    ]))
    # enumerate -> capture TSV
    import io
    from contextlib import redirect_stdout
    buf = io.StringIO()
    with redirect_stdout(buf):
        cc.main(["enumerate", "--events", str(events_path), "--owner-name", "Jane Doe"])
    rows = [r for r in buf.getvalue().splitlines() if r]
    assert len(rows) == 2
    # Build an answers.tsv straight from the prefills (simulate hit-enter).
    answers = d / "answers.tsv"
    answers.write_text(
        "\n".join("\t".join(r.split("\t")[:3]) for r in rows) + "\n"
    )
    out = d / "calendars.json"
    cc.main(["write", "--answers", str(answers), "--out", str(out)])
    data = json.loads(out.read_text())
    matches = {c["match"] for c in data["calendars"]}
    assert matches == {"Work", "Home"}


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in fns:
        fn()
        print(f"ok  {fn.__name__}")
    print(f"\nPASS: {len(fns)} calendar-confirm tests")
