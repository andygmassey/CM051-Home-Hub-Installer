#!/usr/bin/env python3
"""Photo events must reach the graph, and face names only with the opt-in.

THE BUG, measured on a walked box 2026-09-24: extract_all logged
"[ok] Photos: 0 people, 1298 events (faces=off)" and then the ingest logged
"No Photos data to ingest" in 10 of 10 runs. photos_events.json was written
every run and read by nothing: the only photos writer read photos_people.json,
which exists only with the faces opt-in. CM044's wiki queries pwg:PhotoEvent
for its "Photos here" section, so that section was empty on every install
with faces off, which is the default. The writer was built once (HR015 PR
#143) and closed unmerged as a stale draft.

This drives the REAL ingest_all dispatch with the SPARQL transport stubbed,
against synthetic rows only, and asserts:
  1. the "photos" result is ok and counts the events, not "no data";
  2. one pwg:PhotoEvent is written per dated row, with the exact predicates
     CM044 compiler/pwg_data.py load_photo_events reads;
  3. with faces OFF no pwg:photoAttendee edge is written even when a row
     carries a face name; with faces ON the edge is written;
  4. a re-run mints the same URIs (idempotent);
  5. extract_all strips face names from events when faces are off.
"""
from __future__ import annotations

import json
import re
import sys
import tempfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "vendor"))

from ostler_fda import pwg_ingest as m  # noqa: E402

FAILURES: list[str] = []


def check(cond: bool, msg: str) -> None:
    print(("ok: " if cond else "FAIL: ") + msg, file=sys.stdout if cond else sys.stderr)
    if not cond:
        FAILURES.append(msg)


# Synthetic rows in the exact shape extract_all writes (asdict + default=str).
ROWS = [
    {"date": "2031-02-03 10:11:12.500000+08:00", "location": None,
     "latitude": 1.25, "longitude": 103.5, "people": ["Jane Doe"], "album": None},
    {"date": "2031-02-04 09:00:00+08:00", "location": "Testville, Nowhere",
     "latitude": None, "longitude": None, "people": [], "album": None},
    {"date": "", "location": None, "latitude": 0.0, "longitude": 0.0, "people": [], "album": None},
    {"date": "2031-02-05 08:00:00+00:00", "location": None,
     "latitude": "not-a-number", "longitude": 2.0, "people": [], "album": None},
]


def run(fda_dir: Path) -> tuple[dict, list[str]]:
    sent: list[str] = []
    others = {name: (lambda d: {"status": "skipped", "reason": "stub"})
              for name, fn in m._INGEST_DISPATCH if name != "photos"}
    with mock.patch.object(m, "_sparql_update", side_effect=lambda q: sent.append(q)), \
         mock.patch.object(m, "_person_exists", return_value=True), \
         mock.patch.object(m, "_upsert_display_name", return_value=None):
        patches = [mock.patch.object(m, fn, others[name])
                   for name, fn in m._INGEST_DISPATCH if name != "photos"]
        for p in patches:
            p.start()
        try:
            results = m.ingest_all(fda_dir)
        finally:
            for p in patches:
                p.stop()
    return results, sent


with tempfile.TemporaryDirectory() as td:
    d = Path(td)
    (d / "photos_events.json").write_text(json.dumps(ROWS))

    # ── faces OFF (no photos_people.json) ─────────────────────────────────
    results, sent = run(d)
    photos = results.get("photos", {})
    check(photos.get("status") == "ok",
          f"faces off: photos status is ok, got {photos.get('status')!r} ({photos.get('reason')!r})")
    check(photos.get("events_ingested") == 3,
          f"faces off: 3 dated rows ingested, got {photos.get('events_ingested')!r}")
    body = "\n".join(sent)
    check(body.count("a pwg:PhotoEvent") == 3, f"3 PhotoEvent nodes written, got {body.count('a pwg:PhotoEvent')}")
    check("PREFIX pwg: <https://schema.ostler.ai/ontology#>" in body,
          "written in the schema.ostler.ai namespace CM044 reads")
    for pred in ("pwg:photoDate", "pwg:photoLatitude", "pwg:photoLongitude", "pwg:photoPlace"):
        check(pred in body, f"predicate {pred} written")
    check('"2031-02-03T10:11:12.500000+08:00"^^xsd:dateTime' in body,
          "str(datetime) date is written as a valid xsd:dateTime (T separator)")
    check(body.count("pwg:photoLatitude") == 1,
          "the malformed-coordinate row keeps its date and drops its coordinates")
    check("pwg:photoAttendee" not in body,
          "faces off: no face edge written although a row carries a face name")

    uris1 = sorted(set(re.findall(r"<([^>]*photo_event_[^>]*)>", body)))
    _, sent2 = run(d)
    uris2 = sorted(set(re.findall(r"<([^>]*photo_event_[^>]*)>", "\n".join(sent2))))
    check(len(uris1) == 3 and uris1 == uris2, "a re-run mints the same three URIs")

    # ── faces ON ─────────────────────────────────────────────────────────
    (d / "photos_people.json").write_text(json.dumps([]))
    _, sent3 = run(d)
    check("\n".join(sent3).count("pwg:photoAttendee") == 1,
          "faces on: the one face name becomes one pwg:photoAttendee edge")

# ── extract_all strips face names when faces are off ─────────────────────
from ostler_fda import extract_all as ea  # noqa: E402
from ostler_fda import photos_metadata as pm  # noqa: E402


def fake_events(since_days: int = 365, with_people_only: bool = True, db_path=None):
    return [pm.PhotoEvent(date=datetime(2031, 1, 1, tzinfo=timezone.utc), location=None,
                          latitude=1.0, longitude=2.0, people=["John Doe"], album=None)]


with tempfile.TemporaryDirectory() as td, \
        mock.patch.object(pm, "extract_photo_events", side_effect=fake_events), \
        mock.patch.object(pm, "extract_people", return_value=[]):
    out = Path(td)
    # ONLY the photos source: this must never read the machine it runs on.
    ea.run_all(out, enabled_sources=["photos_metadata"])
    ev_file = out / "photos_events.json"
    if ev_file.exists():
        rows = json.loads(ev_file.read_text())
        check(bool(rows) and all(not r.get("people") for r in rows),
              "extract_all with faces off writes events with no face names")
    else:
        check(False, "extract_all wrote no photos_events.json (could not examine the strip)")

if FAILURES:
    print(f"\n{len(FAILURES)} FAILURE(S)", file=sys.stderr)
    sys.exit(1)
print("\nphoto events reach the graph: PASS")
