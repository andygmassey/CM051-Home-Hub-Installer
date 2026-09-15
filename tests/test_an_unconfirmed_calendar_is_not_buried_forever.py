#!/usr/bin/env python3
"""Regression guard: an imported calendar must not be invisible to its owner.

THE BUG THIS KILLS, measured 2026-09-16 on origin/main.

``contact_syncer/google_calendar.py`` documents ``~/.ostler/calendars.json``
as the authoritative owner/type map "that the onboarding step writes and this
ingest reads", and resolves an unconfirmed calendar to ``L3``.

NOTHING WROTE THAT FILE. Three references to the path in the whole repo, all
three inside the reader. (Positive control, same command shape:
``whatsapp_pair.json`` resolves to 5 files, writer included.) So
``load_calendar_provenance`` returned ``[]`` on every install that has ever
existed, every event took the unconfirmed branch, and L3 was not a provisional
hold -- it was permanent, with no surface that could ever release it.

The customer imports their calendar and it disappears. MEASURED against the
two calendar shapes a Google Takeout actually produces: 2 of 2 stamped L3.

The fix has two limbs and this pins both:

  * the ingest WRITES the map, so the file exists and the operator's answer
    has somewhere to land;
  * an UNCONFIRMED calendar resolves to L1 (private, assistant-usable,
    never publishable) rather than L3, while a calendar that is unconfirmed
    *in an estate where onboarding HAS run* still fails closed to L3 -- which
    is what BATCH1 #2 wanted and the old code could not express.

The assertion subject is the READER'S VERDICT, not the writer's field: each
level is put through the same predicate ical-server.py uses to withhold
calendar facts, so what is checked is whether the operator would see the
event, not whether some string was written.

Network-free: no Oxigraph, no HTTP. Only the resolver and the map on disk.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "vendor" / "cm041"))

os.environ.setdefault("USER_ID", "operator")
os.environ.setdefault("USER_DISPLAY_NAME", "Alex Rivera")
os.environ.setdefault("DEFAULT_COUNTRY_CODE", "44")

_TMP = Path(tempfile.mkdtemp())
MAP_PATH = _TMP / "calendars.json"
os.environ["OSTLER_CALENDAR_PROVENANCE"] = str(MAP_PATH)

from contact_syncer import google_calendar as gc  # noqa: E402

# The module read the env var at import time; keep the two in step in case
# this file is imported after something else has already loaded it.
gc.CALENDAR_PROVENANCE_PATH = str(MAP_PATH)

FAILURES: list[str] = []


def check(cond: bool, msg: str) -> None:
    if cond:
        print(f"ok: {msg}")
    else:
        print(f"FAIL: {msg}", file=sys.stderr)
        FAILURES.append(msg)


# ── The consumer predicate, not the writer's field ───────────────────
#
# vendor/cm041/assistant_api/ical-server.py builds its calendar-fact reads
# with `FILTER (!BOUND(?privacy) || UCASE(STR(?privacy)) != "L3")`. An L3
# fact is DROPPED. This is that filter, so every assertion below is about
# what the operator can see.
def operator_can_see(privacy_level: str) -> bool:
    return str(privacy_level).upper() != "L3"


# Two calendars in the shape Google Takeout actually writes them: the
# primary is named by the account ADDRESS (which is why a display-name
# token match can never recognise it as the operator's own), and a shared
# calendar is named by a human label. Synthetic throughout.
PRIMARY_LABEL = "alex.rivera@example.com"
SHARED_LABEL = "Family"

ICS_PRIMARY = f"""BEGIN:VCALENDAR
VERSION:2.0
X-WR-CALNAME:{PRIMARY_LABEL}
BEGIN:VEVENT
UID:evt-primary-1
SUMMARY:Dentist
DTSTART:20260401T090000Z
ORGANIZER;CN=Alex Rivera:mailto:{PRIMARY_LABEL}
END:VEVENT
END:VCALENDAR
"""

ICS_SHARED = f"""BEGIN:VCALENDAR
VERSION:2.0
X-WR-CALNAME:{SHARED_LABEL}
BEGIN:VEVENT
UID:evt-shared-1
SUMMARY:School run
DTSTART:20260402T080000Z
ORGANIZER;CN=Robin Carter:mailto:robin.carter@example.com
END:VEVENT
END:VCALENDAR
"""

EXPORT = _TMP / "export"
EXPORT.mkdir()
(EXPORT / f"{PRIMARY_LABEL}.ics").write_text(ICS_PRIMARY)
(EXPORT / f"{SHARED_LABEL}.ics").write_text(ICS_SHARED)
ICS_PATHS = sorted(str(p) for p in EXPORT.glob("*.ics"))


def resolve_all() -> list[tuple[str, str, str]]:
    """(label, owner, privacy) for every event in the export."""
    prov = gc.load_calendar_provenance()
    out = []
    for p in ICS_PATHS:
        label = gc.calendar_label_for_ics(p)
        for ev in gc.parse_ics(p, user_name="Alex Rivera"):
            owner, _type, privacy = gc.resolve_calendar_provenance(ev, prov)
            out.append((label, owner, privacy))
    return out


def write_map(entries: list) -> None:
    MAP_PATH.write_text(json.dumps({"calendars": entries}))


# ── 1. Fresh install, no map: the customer can see their calendar ────
if MAP_PATH.exists():
    MAP_PATH.unlink()

rows = resolve_all()
# DENOMINATOR FIRST. An assertion over an empty list passes vacuously, and
# "the resolver returned nothing" and "nothing was buried" print the same.
check(len(rows) == 2,
      f"denominator: both calendars produced an event (got {len(rows)})")
check(all(operator_can_see(p) for _l, _o, p in rows),
      "on a fresh install the operator can see EVERY imported event")
check(not any(p == "L3" for _l, _o, p in rows),
      "no event is stamped L3 when nothing has been confirmed")

# The trap this fix had to avoid: gating the new behaviour on
# _owner_denotes_operator would have fired ZERO times, because
# X-WR-CALNAME on a primary calendar is an email address and the
# operator-token set holds names. Pinned so nobody reintroduces that gate
# believing it recognises the operator's own diary.
check(not gc._owner_denotes_operator(PRIMARY_LABEL),
      "CONTROL: the operator's own primary calendar is NOT recognised by "
      "the owner-token predicate, so that predicate cannot gate this fix")

# ── 2. The ingest writes the map that onboarding reads ───────────────
added = gc.seed_calendar_provenance(
    [gc.calendar_label_for_ics(p) for p in ICS_PATHS]
)
check(added == 2, f"the ingest seeded one entry per calendar (got {added})")
check(MAP_PATH.exists(),
      "calendars.json now EXISTS -- it never did on any shipped install")

seeded = json.loads(MAP_PATH.read_text())["calendars"]
check({e["match"] for e in seeded} == {PRIMARY_LABEL, SHARED_LABEL},
      "the map names this customer's actual calendars")
check(all(e.get("confirmed") is False for e in seeded),
      "every seeded entry is UNCONFIRMED: the ingest records, never decides")
check(all(not e.get("type") and not e.get("privacy_level") for e in seeded),
      "the ingest guesses NO type and NO level -- a guess wearing the shape "
      "of an operator answer is worse than no entry")

rows = resolve_all()
check(all(operator_can_see(p) for _l, _o, p in rows),
      "seeding the map does not re-bury the events it recorded")

# ── 2b. Seeding is idempotent and never clobbers an answer ───────────
write_map([
    {"match": PRIMARY_LABEL, "owner": "You", "type": "personal",
     "confirmed": True},
    {"match": SHARED_LABEL, "owner": "", "type": "", "confirmed": False},
])
again = gc.seed_calendar_provenance(
    [gc.calendar_label_for_ics(p) for p in ICS_PATHS]
)
after = json.loads(MAP_PATH.read_text())["calendars"]
check(again == 0, f"re-seeding a known calendar adds nothing (got {again})")
check(len(after) == 2, f"re-seeding does not duplicate entries (got {len(after)})")
check(any(e["match"] == PRIMARY_LABEL and e.get("confirmed") for e in after),
      "an answer the operator already gave survives the next import")

# ── 3. THE FAIL-CLOSED HALF, which must NOT be lost ──────────────────
#
# BATCH1 #2 made the unclassified default L3 so an unconfirmed calendar
# stays private until the operator classifies it. That rule is right; its
# premise (that onboarding classifies them) was false. Once onboarding HAS
# run, a calendar it did not cover is genuinely new and is still withheld.
rows = resolve_all()
by_label = {label: privacy for label, _o, privacy in rows}
check(by_label.get(PRIMARY_LABEL) != "L3",
      "the confirmed personal calendar is visible to its owner")
check(by_label.get(SHARED_LABEL) == "L3",
      "a calendar onboarding has NOT covered still fails closed to L3 "
      "once the operator has confirmed anything")
check(not operator_can_see(by_label.get(SHARED_LABEL, "")),
      "and the reader filter actually withholds it")

# ── 3b. A confirmed-but-unclassified calendar still fails closed ─────
write_map([
    {"match": PRIMARY_LABEL, "owner": "You", "confirmed": True},
])
rows = resolve_all()
by_label = {label: privacy for label, _o, privacy in rows}
check(by_label.get(PRIMARY_LABEL) == "L3",
      "a CONFIRMED entry with no type still fails closed to L3 -- the "
      "operator answered and the answer did not classify it")

# ── 4. A hand-written map in the DOCUMENTED shape still works ────────
#
# The contract in the module docstring shows entries with no `confirmed`
# key. Those predate the flag and must not be demoted to seeds.
write_map([
    {"match": SHARED_LABEL, "owner": "Robin", "type": "family",
     "privacy_level": "L1"},
    {"match": PRIMARY_LABEL, "owner": "You", "type": "work"},
])
rows = resolve_all()
by_label = {label: privacy for label, _o, privacy in rows}
check(by_label.get(SHARED_LABEL) == "L1",
      "a hand-written entry's explicit privacy_level is still authoritative")
check(by_label.get(PRIMARY_LABEL) == "L2",
      "a hand-written entry's type still derives the level (work -> L2)")

# ── 5. An unwritable map degrades, it does not explode ───────────────
#
# A seed that cannot be written must leave the import running with exactly
# the behaviour it had before the seeder existed.
broken = gc.seed_calendar_provenance(
    ["Somebody's Calendar"],
    path="/proc/nonexistent-directory-for-this-test/calendars.json",
)
check(broken == 0,
      "an unwritable map reports 0 seeded rather than raising")

print()
if FAILURES:
    print(f"FAILED: {len(FAILURES)} check(s)", file=sys.stderr)
    raise SystemExit(1)
print("PASS: an unconfirmed calendar is visible to its owner, and a "
      "calendar onboarding has not covered is still withheld")
