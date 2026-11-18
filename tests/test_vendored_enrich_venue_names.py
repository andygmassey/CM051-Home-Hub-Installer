#!/usr/bin/env python3
"""A venue is looked up by its NAME only, and never when it is an excluded venue.

Archie's venue ruling (2026-11-18): a business or venue name may be looked up as the
name only. Never an address, coordinates, postcode, dates, visit counts, or
"home" / "work" / "near me" labels. Never looked up, whatever the level: (a) Art. 9
type venues (clinic, hospital, GP, pharmacy, therapist, dentist, places of worship,
political, sexual-health, law firms, rehab); (b) a venue name containing a person name
from the owner's contacts.

Drives the REAL vendored ``privacy_gate.venue_name_refusal``. Synthetic values only.
One arm per exclusion, plus a positive control (a restaurant name, no hints).
Exit 0 pass, 1 an arm fails, 2 cannot-run.
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor" / "cm019_preferences" / "services"
for p in (VENDOR / "enrich" / "src", VENDOR / "common"):
    sys.path.insert(0, str(p))

try:
    from privacy_gate import venue_name_refusal
except Exception as exc:  # noqa: BLE001 - cannot-run, reported with its reason
    print(f"CANNOT-RUN: vendored privacy_gate did not import: {exc!r}")
    sys.exit(2)

CONTACTS = frozenset({"seedperson"})

ARMS = [
    # (name, category, subject, want_allowed)
    ("positive control: restaurant name, no hints", "restaurant", "seed venue bistro", True),
    ("exclusion (a) address with a number", "place", "1 seed street", False),
    ("exclusion (a) postcode", "place", "seed AB1 2CD", False),
    ("exclusion (a) comma-joined address", "place", "seed street, seed town", False),
    ("exclusion (a) location label 'home'", "place", "seed home office", False),
    ("exclusion (a) location label 'near me'", "place", "seed cafe near me", False),
    ("exclusion (b) Art. 9 clinic", "place", "seed clinic", False),
    ("exclusion (b) Art. 9 pharmacy", "place", "seed pharmacy", False),
    ("exclusion (b) Art. 9 church", "place", "seed church", False),
    ("exclusion (b) Art. 9 law firm", "place", "seed law firm", False),
    ("exclusion (c) venue contains a contact's name", "place", "seedperson kitchen", False),
    ("exclusion (c) contact name as 'Dr X'", "place", "dr seedperson", False),
    ("non-venue category is not subject to the venue rule", "book", "1 seed street", True),
]


def main() -> int:
    failures = 0
    for name, category, subject, want_allowed in ARMS:
        reason = venue_name_refusal(subject, category, CONTACTS)
        ok = (reason is None) == want_allowed
        failures += 0 if ok else 1
        print(f"{'PASS' if ok else 'FAIL'} {name}: refusal={reason!r}")
    print(f"TOTAL {len(ARMS)} arms, {failures} FAIL")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
