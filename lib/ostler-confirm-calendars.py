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
# A Google holiday calendar synced through a Google account carries this in
# its id ("<lang>.<region>#holiday@group.v.calendar.google.com"), and a
# subscribed public-holiday feed names holidays in its URL. 118 Q32b: one
# region's holidays arrived as Apple's holiday calendar and as a feed, and the
# feed was grouped as "a calendar you subscribe to" while another region's
# sat under "public holidays". Both are holidays; group them as one.
_HOLIDAY_ID_MARK = "#holiday@"
_HOLIDAY_URL_MARK = "holiday"
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
        title = _norm(meta.get("title") or "")
        if title in _FALLBACK_TITLES:
            return _FALLBACK_TITLES[title]
        return "holiday" if "holiday" in title else ""
    try:
        flags = int(meta.get("flags") or 0)
    except (TypeError, ValueError):
        flags = 0
    external_id = meta.get("external_id") or ""
    subcal_url = (meta.get("subcal_url") or "").strip()
    if external_id == _HOLIDAY_EXTERNAL_ID or _HOLIDAY_ID_MARK in external_id:
        return "holiday"
    if subcal_url and _HOLIDAY_URL_MARK in subcal_url.lower():
        return "holiday"
    if store_type == _STORE_TYPE_BIRTHDAYS:
        return "suggestion" if flags & _SUGGESTION_FLAGS else "birthday"
    if store_type == _STORE_TYPE_REMINDERS:
        return "reminders"
    if store_type == _STORE_TYPE_SUBSCRIBED or subcal_url:
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
    if "" in kinds:
        return ""
    # Every calendar with this title is set aside, but not all the same way
    # (a region's holidays from Apple AND from a subscribed feed). Still set
    # aside, under the most specific kind, so they group together.
    for kind in _SET_ASIDE_PRIORITY:
        if kind in kinds:
            return kind
    return ""


# Most specific first: a holiday feed is a subscription too, but "holidays" is
# the group the customer recognises.
_SET_ASIDE_PRIORITY = ("holiday", "birthday", "suggestion", "reminders", "subscribed")


# Names that read as a shared household diary rather than a single person.
_FAMILY_GENERIC = {"family", "home", "household", "kids", "children"}
# Tokens that read as a work diary.
_WORK_TOKENS = {"work", "office", "team", "company", "meetings", "sales"}
# Words that make a title a calendar label rather than a person's name, so
# "work calendar" or "family diary" is never read as two people's names.
_CALENDAR_WORDS = {"calendar", "calendars", "diary", "events", "schedule",
                   "agenda", "plans", "shared", "personal", "holidays"}


def _norm(s: str) -> str:
    return (s or "").strip().lower()


def _owner_tokens(owner_name: str) -> set:
    return {t for t in _norm(owner_name).replace("-", " ").split() if len(t) >= 2}


def _possessor(cal_name: str) -> str:
    """"Robin's Calendar" -> "Robin"; "" when the title is not possessive."""
    first = (cal_name or "").strip().split(" ")[0] if cal_name else ""
    for mark in ("'s", "\u2019s"):
        if first.lower().endswith(mark) and len(first) > len(mark):
            return first[: -len(mark)]
    return ""


def guess_owner_type(
    cal_name: str, owner_name: str, owner_emails: Optional[List[str]] = None
) -> Tuple[str, str]:
    """Pre-fill (owner, type) for a calendar display name.

    The customer corrects any guess in place with one menu per calendar, so a
    guess only has to be the likeliest, not certain. Two rules carry the
    weight (118 Q32b, both wrong on a real walk):

      - The owner's own possessive title ("<first name>'s Calendar") is the
        owner's, never "family". Another person's possessive title is that
        person's, shared.
      - A calendar named by an email address is the owner's only when the
        address is one of the owner's, or plainly carries the owner's name or
        a work word. Any other address is somebody else's diary shared with
        the owner (how Google shows another person's calendar), so it is
        never marked "yours".
    """
    name = _norm(cal_name)
    owner = _norm(owner_name)
    mine = _owner_tokens(owner_name)
    emails = {_norm(e) for e in (owner_emails or []) if e and "@" in e}

    if "@" in name:
        local = name.split("@", 1)[0]
        local_tokens = set(local.replace(".", " ").replace("_", " ").replace("-", " ").split())
        if name in emails or (mine & local_tokens):
            return ("You", "personal")
        if local_tokens & _WORK_TOKENS:
            return ("You", "work")
        return (cal_name.strip(), "shared")

    possessor = _possessor(cal_name)
    if possessor:
        if _norm(possessor) in mine:
            rest = set(name.split()[1:])
            return ("You", "work" if rest & _WORK_TOKENS else "personal")
        return (possessor, "shared")

    # Explicitly the operator's own name / first name.
    if owner and (name == owner or name in mine):
        return ("You", "personal")

    words = name.split()
    # Household / family diary ("Family", "family calendar", "Kids").
    if words and words[0] in _FAMILY_GENERIC and set(words[1:]) <= _CALENDAR_WORDS:
        return ("Family", "family")

    # Work diary.
    if any(tok in name for tok in _WORK_TOKENS):
        return ("You", "work")

    # Generic self calendar.
    if name in _SELF_GENERIC or (words and set(words) <= (_SELF_GENERIC | _CALENDAR_WORDS)):
        return ("You", "personal")

    # Looks like another person's name: two or more capitalised words, none
    # of them a calendar word, none of them the owner's -> that person's
    # diary, shared with the owner (not "family": a named person is not the
    # household).
    raw = (cal_name or "").split()
    if (
        len(raw) >= 2
        and all(w[:1].isupper() for w in raw if w)
        and not (set(words) & _CALENDAR_WORDS)
        and not (set(words) & mine)
    ):
        return (cal_name.strip(), "shared")

    # Fall back to the safe default.
    return ("You", "personal")


# ── The one-screen picker's categories (118 Q32b) ─────────────────────────
#
# The GUI shows one menu per calendar with these five values. ``initial_category``
# turns the guess into the menu's starting value; ``answers_from_categories``
# turns the customer's picks back into the answers ``build_calendars_json``
# writes. Nothing else in the flow knows these words.
CATEGORIES = ("yours", "family", "shared", "holidays", "ignore")


def initial_category(cal: Dict[str, Any]) -> str:
    aside = cal.get("set_aside") or ""
    if aside == "holiday":
        return "holidays"
    if aside:
        return "ignore"
    if cal.get("type") == "family":
        return "family"
    if cal.get("type") == "shared" or (cal.get("owner") or "You") != "You":
        return "shared"
    return "yours"


def answer_for_category(cal: Dict[str, str], category: str) -> Dict[str, str]:
    """One confirmed answer row for a calendar the customer put in ``category``."""
    match = cal.get("match", "")
    owner = cal.get("owner") or "You"
    ctype = cal.get("type") or "personal"
    aside = cal.get("set_aside") or ""
    if category == "yours":
        return {"match": match, "owner": "You",
                "type": ctype if owner == "You" and ctype in ("personal", "work") else "personal",
                "include": "1", "set_aside": ""}
    if category == "family":
        return {"match": match, "owner": "Family", "type": "family", "include": "1", "set_aside": ""}
    if category == "shared":
        who = owner if owner not in ("You", "Family") else "Shared"
        return {"match": match, "owner": who, "type": "shared", "include": "1", "set_aside": ""}
    if category == "holidays":
        return {"match": match, "owner": "You", "type": "other", "include": "0", "set_aside": "holiday"}
    # ignore
    return {"match": match, "owner": "You", "type": "other", "include": "0",
            "set_aside": aside or "other"}


def answers_from_categories(
    rows: List[Dict[str, str]], categories_csv: str
) -> Tuple[List[Dict[str, str]], str]:
    """Map the picker's answer onto the rows. Returns (answers, note).

    The answer is one category per row, comma-separated, in row order. A
    malformed answer (wrong count, an unknown word) keeps every row's initial
    category and says why in ``note``; it never half-applies.
    """
    picks = [p.strip().lower() for p in (categories_csv or "").split(",")] if categories_csv.strip() else []
    note = ""
    if len(picks) != len(rows) or any(p not in CATEGORIES for p in picks):
        note = (f"picker answer not applied (got {len(picks)} value(s) for "
                f"{len(rows)} calendar(s)); kept the pre-filled categories")
        picks = [r.get("category") or "yours" for r in rows]
    return [answer_for_category(r, c) for r, c in zip(rows, picks)], note


def aggregate_calendars(
    events: List[Dict[str, Any]],
    owner_name: str,
    meta: Optional[Dict[str, List[Dict[str, Any]]]] = None,
    owner_emails: Optional[List[str]] = None,
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
        owner, ctype = guess_owner_type(cal, owner_name, owner_emails)
        row = {
            "match": cal,
            "owner": owner,
            "type": ctype,
            "count": b["count"],
            "samples": b["samples"],
            "set_aside": set_aside_for(cal, meta or {}),
        }
        row["category"] = initial_category(row)
        out.append(row)
    # Ordinary calendars first (busiest first), then every holiday calendar
    # together whatever its region or source, then the rest set aside.
    out.sort(key=lambda c: (0 if not c["set_aside"] else 1 if c["set_aside"] == "holiday" else 2,
                            -c["count"], c["match"].lower()))
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


# bash ``read`` with IFS=TAB collapses an empty field (TAB is IFS whitespace),
# which shifted every later column left by one. Empty middle fields are
# written as this placeholder and read back as empty on both sides.
EMPTY_FIELD = "-"


def _cmd_enumerate(args: argparse.Namespace) -> int:
    try:
        events = _load_events(args.events)
    except (OSError, ValueError):
        # No/unreadable events -> nothing to confirm. Emit nothing (exit 0);
        # the caller treats an empty enumeration as "skip the calendar step".
        return 0
    meta = load_calendar_meta(args.calendar_db)
    for c in aggregate_calendars(events, args.owner_name or "You", meta, args.owner_email):
        samples = "; ".join(c["samples"])
        # TSV: match, owner, type, count, samples, set_aside, category. Strip tabs from
        # values so the row stays well-formed.
        row = [
            c["match"].replace("\t", " "),
            c["owner"].replace("\t", " "),
            c["type"],
            str(c["count"]),
            samples.replace("\t", " ") or EMPTY_FIELD,
            c["set_aside"] or EMPTY_FIELD,
            c["category"],
        ]
        sys.stdout.write("\t".join(row) + "\n")
    return 0


def _read_rows_tsv(path: str) -> List[Dict[str, str]]:
    rows: List[Dict[str, str]] = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if not parts or not parts[0].strip():
                continue
            parts += [""] * (7 - len(parts))
            parts = ["" if p == EMPTY_FIELD else p for p in parts]
            rows.append({"match": parts[0], "owner": parts[1], "type": parts[2],
                         "set_aside": parts[5], "category": parts[6]})
    return rows


def _cmd_write(args: argparse.Namespace) -> int:
    if args.rows:
        answers, note = answers_from_categories(_read_rows_tsv(args.rows), args.categories or "")
        if note:
            sys.stderr.write(f"calendar picker: {note}\n")
    elif args.answers:
        answers = _read_answers_tsv(args.answers)
    else:
        sys.stderr.write("write: needs --answers, or --rows with --categories\n")
        return 2
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
    e.add_argument("--owner-email", action="append", default=[],
                   help="one of the owner's addresses (repeatable)")
    e.add_argument(
        "--calendar-db",
        default=DEFAULT_CALENDAR_DB,
        help="macOS Calendar.sqlitedb, read for metadata (store type, flags)",
    )
    e.set_defaults(func=_cmd_enumerate)

    w = sub.add_parser("write")
    w.add_argument("--answers")
    w.add_argument("--rows", help="enumerate output, for the GUI picker's answer")
    w.add_argument("--categories", help="the picker's answer, one category per row")
    w.add_argument("--out", required=True)
    w.set_defaults(func=_cmd_write)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
