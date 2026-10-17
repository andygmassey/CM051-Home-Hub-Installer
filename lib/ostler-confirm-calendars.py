#!/usr/bin/env python3
"""End-of-install calendar-owner confirmation helper.

Backs the calendar half of the end-of-installation confirmation step in
``install.sh``. Two modes, driven from bash:

  --enumerate --events <calendar_events.json> [--owner-name "You"]
      Aggregate the distinct calendars present in the freshly-hydrated
      ``calendar_events.json`` (written by the FDA calendar extractor) and
      emit one TAB-separated row per calendar:

          match <TAB> owner <TAB> type <TAB> count <TAB> samples <TAB> set_aside

      ``owner`` / ``type`` are *pre-fills* (sensible guesses) so an operator
      who just hits enter still gets a reasonable answer -- never a wall of
      mandatory config. ``count`` / ``samples`` are shown to help the operator
      recognise which diary it is. ``set_aside`` is empty for an ordinary
      calendar, or one of ``SET_ASIDE_KINDS`` for a calendar nobody owns
      (holidays, birthdays, Siri suggestions, subscriptions, reminders).
      install.sh shows every row on ONE screen and the customer confirms
      once; set-aside rows are listed in their own group, excluded by default.

      Classification reads the macOS Calendar database's METADATA (store
      type, calendar flags, external id), never a translated display name,
      unless that metadata cannot be read. See ``classify_set_aside``.

  --write --answers <answers.tsv> --out <calendars.json>
      Read the operator-confirmed answers (``match <TAB> owner <TAB> type
      [<TAB> include <TAB> set_aside]``, one per line) and write ``~/.ostler/calendars.json`` in the EXACT shape
      the CM041 reader consumes (``contact_syncer.google_calendar
      .load_calendar_provenance`` on ``fix/calendar-owner-attribution``):

          {"calendars": [{"match": ..., "owner": ..., "type": ...}, ...]}

      A calendar the customer left set aside is written as
      ``{"match", "owner": "You", "type": "other", "include": false,
      "set_aside": <kind>}``. The current reader ignores the two extra keys
      and maps the confirmed ``other`` type to L3, its most restrictive
      level, so a set-aside calendar is withheld rather than read as the
      operator's own diary.

      ``privacy_level`` is deliberately omitted -- the reader derives it from
      ``type`` (work/shared -> L2, personal/family -> L1). The operator confirms
      *whose* diary and *what kind*; the sensitivity follows from the kind.

Pure stdlib (json/argparse) so it runs under any install venv. The scoring /
grouping / prefill logic is factored into pure functions for unit testing.

All example names here are synthetic. No real personal data. See
PRODUCTISATION_CHECKLIST.md Rule 0.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from typing import Any, Dict, List, Optional, Tuple

# Calendar "type" vocabulary the CM041 reader understands. ``other`` is a safe
# catch-all that maps to the reader's default (personal-grade) privacy.
VALID_TYPES = ("personal", "work", "family", "shared", "other")

# Generic calendar names, from Apple and Google alike, that are always the
# operator's own and carry no other-person signal -> pre-fill You / personal.
# System calendars (holidays, birthdays, Siri suggestions) are NOT here: they
# are not anyone's diary and are set aside by ``classify_set_aside`` below.
_SELF_GENERIC = {"calendar", "home", "personal", "icloud", "iphone", "contacts"}

# ── Set-aside classification: THE ONE TABLE ────────────────────────────────
#
# Calendars that belong to nobody: the customer is not asked whose they are,
# and they are excluded by default (still listed, still changeable).
SET_ASIDE_KINDS = ("holiday", "birthday", "suggestion", "subscribed", "reminders")

# Calendar.sqlitedb ``Store.type``. 0-5 follow EventKit's EKSourceType
# numbering (4 = subscribed, 5 = birthdays). Measured on a macOS 26 box on
# 2026-10-15: the birthdays source (shown as "Other" in Calendar.app) holds
# the contacts and Facebook birthday calendars and both Siri suggestion
# calendars; store type 6 holds the scheduled-reminders calendar.
_STORE_TYPE_SUBSCRIBED = 4
_STORE_TYPE_BIRTHDAYS = 5
_STORE_TYPE_REMINDERS = 6
# ``Calendar.external_id`` of an Apple holiday calendar, in every language.
_HOLIDAY_EXTERNAL_ID = "__HolidayCalendar__"
# ``Calendar.flags`` bits on the Siri suggestion calendars inside the
# birthdays source (same measurement): 0x40000 on the one found in mail,
# 0x80000 on the one found in natural language. Birthday calendars carry
# neither.
_SUGGESTION_FLAGS = 0x40000 | 0x80000

# LAST RESORT ONLY, used when the Calendar database cannot be read (macOS 14
# and earlier keep a different store; or no access). Keyed on the internal
# titles Apple gives these calendars, which are English. Kept deliberately
# small: a localised holiday calendar is NOT listed here because its title
# changes with the language, which is why the metadata path comes first.
_FALLBACK_TITLES = {
    "found in natural language": "suggestion",
    "found in mail": "suggestion",
    "found in apps": "suggestion",
    "siri suggestions": "suggestion",
    "birthdays": "birthday",
    "scheduled reminders": "reminders",
}

# Where macOS keeps the Calendar database (macOS 15 and later). Same path the
# FDA calendar extractor probes first (vendor/ostler_fda/calendar.py).
DEFAULT_CALENDAR_DB = os.path.join(
    os.path.expanduser("~"), "Library", "Group Containers",
    "group.com.apple.calendar", "Calendar.sqlitedb",
)


def classify_set_aside(meta: Dict[str, Any]) -> str:
    """Return a ``SET_ASIDE_KINDS`` value for one calendar, or "" if ordinary.

    ``meta`` carries the Calendar database row: ``store_type`` (int),
    ``flags`` (int), ``external_id`` and ``subcal_url`` (str), and ``title``.
    Metadata decides. The title is consulted only for a calendar with no
    database metadata at all (``store_type`` is None).
    """
    store_type = meta.get("store_type")
    if store_type is None:
        return _FALLBACK_TITLES.get(_norm(meta.get("title") or ""), "")
    try:
        flags = int(meta.get("flags") or 0)
    except (TypeError, ValueError):
        flags = 0
    if (meta.get("external_id") or "") == _HOLIDAY_EXTERNAL_ID:
        return "holiday"
    if store_type == _STORE_TYPE_BIRTHDAYS:
        return "suggestion" if flags & _SUGGESTION_FLAGS else "birthday"
    if store_type == _STORE_TYPE_REMINDERS:
        return "reminders"
    if store_type == _STORE_TYPE_SUBSCRIBED or (meta.get("subcal_url") or "").strip():
        return "subscribed"
    return ""


def load_calendar_meta(db_path: Optional[str]) -> Dict[str, List[Dict[str, Any]]]:
    """Read calendar metadata from Calendar.sqlitedb, keyed by calendar title.

    Read-only. Returns {} when the database is absent or unreadable, and says
    so on stderr (install.sh routes stderr to the confirm log) so a fallback
    to titles is never silent.
    """
    if not db_path:
        return {}
    if not os.path.exists(db_path):
        sys.stderr.write(
            f"calendar metadata: no database at {db_path}; using title fallback\n"
        )
        return {}
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        try:
            rows = conn.execute(
                "SELECT c.title, s.type, c.flags, c.external_id, c.subcal_url "
                "FROM Calendar c LEFT JOIN Store s ON s.ROWID = c.store_id"
            ).fetchall()
        finally:
            conn.close()
    except sqlite3.Error as exc:
        sys.stderr.write(
            f"calendar metadata: could not read {db_path}: {exc}; "
            "using title fallback\n"
        )
        return {}
    out: Dict[str, List[Dict[str, Any]]] = {}
    for title, store_type, flags, external_id, subcal_url in rows:
        key = (title or "").strip()
        if not key:
            continue
        out.setdefault(key, []).append(
            {
                "title": key,
                # A calendar with no store row still HAS metadata: -1 keeps
                # it on the metadata path (ordinary unless a flag says not).
                "store_type": store_type if store_type is not None else -1,
                "flags": flags,
                "external_id": external_id,
                "subcal_url": subcal_url,
            }
        )
    return out


def set_aside_for(cal_name: str, meta: Dict[str, List[Dict[str, Any]]]) -> str:
    """Classify a calendar by NAME (the name is all an event carries).

    Two calendars can share a title. Set one aside only when EVERY calendar
    with that title classifies the same way; a mixed title is shown as an
    ordinary calendar, so a customer's own "Birthdays" diary on iCloud is
    never hidden because Apple's built-in one shares its name.
    """
    rows = meta.get(cal_name.strip())
    if not rows:
        return classify_set_aside({"title": cal_name, "store_type": None})
    kinds = {classify_set_aside(r) for r in rows}
    return kinds.pop() if len(kinds) == 1 else ""


# Names that read as a shared household diary rather than a single person.
_FAMILY_GENERIC = {"family", "home", "household", "kids", "children"}
# Tokens that read as a work diary.
_WORK_TOKENS = {"work", "office", "team", "company", "meetings", "sales"}


def _norm(s: str) -> str:
    return (s or "").strip().lower()


def guess_owner_type(cal_name: str, owner_name: str) -> Tuple[str, str]:
    """Pre-fill (owner, type) for a calendar display name.

    Conservative: when in doubt, attribute to the operator as personal (the
    prior product behaviour), because the operator can correct in one keypress
    and an over-eager "family"/other guess is more surprising than "You".
    """
    name = _norm(cal_name)
    owner = _norm(owner_name)
    owner_first = owner.split()[0] if owner else ""

    # An email address as a calendar name -> the operator's own diary.
    if "@" in name:
        return ("You", "personal")

    # Explicitly the operator's own name / first name.
    if owner and (name == owner or (owner_first and name == owner_first)):
        return ("You", "personal")

    # Household / family diary.
    if name in _FAMILY_GENERIC:
        return ("Family", "family")

    # Work diary.
    if any(tok in name for tok in _WORK_TOKENS):
        return ("You", "work")

    # Generic self calendar.
    if name in _SELF_GENERIC:
        return ("You", "personal")

    # Looks like another person's name (two+ capitalised words, not the
    # operator) -> a shared person's diary; pre-fill that person as owner.
    words = (cal_name or "").split()
    if (
        len(words) >= 2
        and all(w[:1].isupper() for w in words if w)
        and name != owner
    ):
        return (cal_name.strip(), "family")

    # Fall back to the safe default.
    return ("You", "personal")


def aggregate_calendars(
    events: List[Dict[str, Any]],
    owner_name: str,
    meta: Optional[Dict[str, List[Dict[str, Any]]]] = None,
) -> List[Dict[str, Any]]:
    """Collapse events into distinct calendars with counts + sample titles.

    Ordinary calendars come first (busiest first), then set-aside ones.
    """
    buckets: Dict[str, Dict[str, Any]] = {}
    for ev in events:
        if not isinstance(ev, dict):
            continue
        cal = (ev.get("calendar_name") or "").strip()
        if not cal:
            continue  # no calendar identity -> nothing to attribute/confirm
        b = buckets.setdefault(cal, {"match": cal, "count": 0, "samples": []})
        b["count"] += 1
        title = (ev.get("title") or ev.get("summary") or "").strip()
        if title and len(b["samples"]) < 3 and title not in b["samples"]:
            b["samples"].append(title)

    out: List[Dict[str, Any]] = []
    for cal, b in buckets.items():
        owner, ctype = guess_owner_type(cal, owner_name)
        out.append(
            {
                "match": cal,
                "owner": owner,
                "type": ctype,
                "count": b["count"],
                "samples": b["samples"],
                "set_aside": set_aside_for(cal, meta or {}),
            }
        )
    out.sort(key=lambda c: (1 if c["set_aside"] else 0, -c["count"]))
    return out


def build_calendars_json(answers: List[Dict[str, str]]) -> Dict[str, Any]:
    """Build the calendars.json payload from confirmed answers.

    Each answer is ``{match, owner, type}`` plus optional ``include`` and
    ``set_aside``. Entries missing a ``match`` are dropped (the reader ignores
    them anyway). ``type`` is normalised into the known vocabulary; anything
    unknown becomes ``other``. An answer with ``include`` "0" is written as a
    set-aside entry (see the module docstring).
    """
    cals: List[Dict[str, Any]] = []
    for a in answers:
        match = (a.get("match") or "").strip()
        if not match:
            continue
        if (a.get("include") or "").strip() == "0":
            kind = _norm(a.get("set_aside") or "")
            cals.append(
                {
                    "match": match,
                    "owner": "You",
                    "type": "other",
                    "include": False,
                    "set_aside": kind if kind in SET_ASIDE_KINDS else "other",
                }
            )
            continue
        owner = (a.get("owner") or "You").strip() or "You"
        ctype = _norm(a.get("type") or "")
        if ctype not in VALID_TYPES:
            ctype = "other"
        cals.append({"match": match, "owner": owner, "type": ctype})
    return {"calendars": cals}


def _load_events(path: str) -> List[Dict[str, Any]]:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if isinstance(data, list):
        return data
    if isinstance(data, dict) and isinstance(data.get("events"), list):
        return data["events"]
    return []


def _read_answers_tsv(path: str) -> List[Dict[str, str]]:
    answers: List[Dict[str, str]] = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            parts = line.split("\t")
            answers.append(
                {
                    "match": parts[0] if len(parts) > 0 else "",
                    "owner": parts[1] if len(parts) > 1 else "",
                    "type": parts[2] if len(parts) > 2 else "",
                    "include": parts[3] if len(parts) > 3 else "",
                    "set_aside": parts[4] if len(parts) > 4 else "",
                }
            )
    return answers


def _cmd_enumerate(args: argparse.Namespace) -> int:
    try:
        events = _load_events(args.events)
    except (OSError, ValueError):
        # No/unreadable events -> nothing to confirm. Emit nothing (exit 0);
        # the caller treats an empty enumeration as "skip the calendar step".
        return 0
    meta = load_calendar_meta(args.calendar_db)
    for c in aggregate_calendars(events, args.owner_name or "You", meta):
        samples = "; ".join(c["samples"])
        # TSV: match, owner, type, count, samples, set_aside. Strip tabs from
        # values so the row stays well-formed.
        row = [
            c["match"].replace("\t", " "),
            c["owner"].replace("\t", " "),
            c["type"],
            str(c["count"]),
            samples.replace("\t", " "),
            c["set_aside"],
        ]
        sys.stdout.write("\t".join(row) + "\n")
    return 0


def _cmd_write(args: argparse.Namespace) -> int:
    answers = _read_answers_tsv(args.answers)
    payload = build_calendars_json(answers)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")
    sys.stdout.write(
        json.dumps({"status": "ok", "calendars": len(payload["calendars"])}) + "\n"
    )
    return 0


def main(argv: List[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Calendar-owner confirmation helper")
    sub = p.add_subparsers(dest="mode", required=True)

    e = sub.add_parser("enumerate")
    e.add_argument("--events", required=True)
    e.add_argument("--owner-name", default="You")
    e.add_argument(
        "--calendar-db",
        default=DEFAULT_CALENDAR_DB,
        help="macOS Calendar.sqlitedb, read for metadata (store type, flags)",
    )
    e.set_defaults(func=_cmd_enumerate)

    w = sub.add_parser("write")
    w.add_argument("--answers", required=True)
    w.add_argument("--out", required=True)
    w.set_defaults(func=_cmd_write)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
