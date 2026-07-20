#!/usr/bin/env python3
"""End-of-install calendar-owner confirmation helper.

Backs the calendar half of the end-of-installation confirmation step in
``install.sh``. Two modes, driven from bash:

  --enumerate --events <calendar_events.json> [--owner-name "You"]
      Aggregate the distinct calendars present in the freshly-hydrated
      ``calendar_events.json`` (written by the FDA calendar extractor) and
      emit one TAB-separated row per calendar:

          match <TAB> owner <TAB> type <TAB> count <TAB> samples

      ``owner`` / ``type`` are *pre-fills* (sensible guesses) so an operator
      who just hits enter still gets a reasonable answer -- never a wall of
      mandatory config. ``count`` / ``samples`` are shown to help the operator
      recognise which diary it is.

  --write --answers <answers.tsv> --out <calendars.json>
      Read the operator-confirmed answers (``match <TAB> owner <TAB> type``,
      one per line) and write ``~/.ostler/calendars.json`` in the EXACT shape
      the CM041 reader consumes (``contact_syncer.google_calendar
      .load_calendar_provenance`` on ``fix/calendar-owner-attribution``):

          {"calendars": [{"match": ..., "owner": ..., "type": ...}, ...]}

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
import sys
from typing import Any, Dict, List, Tuple

# Calendar "type" vocabulary the CM041 reader understands. ``other`` is a safe
# catch-all that maps to the reader's default (personal-grade) privacy.
VALID_TYPES = ("personal", "work", "family", "shared", "other")

# Generic Apple/Google calendar names that are always the operator's own and
# carry no other-person signal -> pre-fill You / personal.
_SELF_GENERIC = {
    "calendar", "home", "personal", "icloud", "iphone",
    "birthdays", "holidays", "us holidays", "siri suggestions",
    "found in apps", "found in mail", "found in messages", "contacts",
}
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
    events: List[Dict[str, Any]], owner_name: str
) -> List[Dict[str, Any]]:
    """Collapse events into distinct calendars with counts + sample titles."""
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
    for cal, b in sorted(buckets.items(), key=lambda kv: -kv[1]["count"]):
        owner, ctype = guess_owner_type(cal, owner_name)
        out.append(
            {
                "match": cal,
                "owner": owner,
                "type": ctype,
                "count": b["count"],
                "samples": b["samples"],
            }
        )
    return out


def build_calendars_json(answers: List[Dict[str, str]]) -> Dict[str, Any]:
    """Build the calendars.json payload from confirmed answers.

    Each answer is ``{match, owner, type}``. Entries missing a ``match`` are
    dropped (the reader ignores them anyway). ``type`` is normalised into the
    known vocabulary; anything unknown becomes ``other``.
    """
    cals: List[Dict[str, str]] = []
    for a in answers:
        match = (a.get("match") or "").strip()
        if not match:
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
    for c in aggregate_calendars(events, args.owner_name or "You"):
        samples = "; ".join(c["samples"])
        # TSV: match, owner, type, count, samples. Strip tabs from values so
        # the row stays well-formed.
        row = [
            c["match"].replace("\t", " "),
            c["owner"].replace("\t", " "),
            c["type"],
            str(c["count"]),
            samples.replace("\t", " "),
        ]
        sys.stdout.write("\t".join(row) + "\n")
    return 0


def _cmd_write(args: argparse.Namespace) -> int:
    answers = _read_answers_tsv(args.answers)
    payload = build_calendars_json(answers)
    import os

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
    e.set_defaults(func=_cmd_enumerate)

    w = sub.add_parser("write")
    w.add_argument("--answers", required=True)
    w.add_argument("--out", required=True)
    w.set_defaults(func=_cmd_write)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
