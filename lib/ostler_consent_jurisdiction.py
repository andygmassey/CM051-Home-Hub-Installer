#!/usr/bin/env python3
"""Answer, for a jurisdiction, whether every party must agree before transcribing.

ONE IMPLEMENTATION, BECAUSE THREE WOULD DRIFT. The Hub, the capture app and the
Doctor all need this answer, and a rule re-implemented per surface is a rule
that disagrees with itself within a release. The table is data
(lib/transcription_consent_rules.csv) and this is the only reader of it.

THE CONTRACT, in one sentence: it never returns "one party is enough" for a
place it does not actually know about.

    resolve("DE")     -> ("yes", False)      every party must agree
    resolve("GB")     -> ("unclear", False)  not determined; treat as strictest
    resolve("US")     -> ("unclear", True)   ask for somewhere finer first
    resolve("US-CA")  -> ("yes", False)      answered at the level that decides
    resolve("ZZ")     -> ("unclear", False)  unknown code, still not permissive

The second value is the ESCALATION SIGNAL. True means a country-level answer is
not good enough here because the law varies below the country, so the caller
should resolve finer (GPS if already granted, otherwise show a guess and let
the customer confirm it) before deciding. It is True for 3 of 245 countries, so
in the ordinary case nobody is asked anything.
"""
from __future__ import annotations

import csv
import pathlib
from typing import Optional, Tuple

TABLE = pathlib.Path(__file__).resolve().parent / "transcription_consent_rules.csv"
VALID = {"yes", "no", "unclear"}


class TableUnreadable(RuntimeError):
    """The table could not be read. NOT the same as the table saying `no`."""


def load(path: Optional[pathlib.Path] = None) -> dict:
    """Read the table. Raises rather than returning an empty mapping.

    An empty mapping would make every lookup fall through to the unknown
    branch, which is safe by luck rather than by design, and would hide a
    deleted or corrupt table behind behaviour that looks deliberate.
    """
    path = path or TABLE
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise TableUnreadable(f"{path}: {exc}") from exc
    body = "\n".join(ln for ln in text.split("\n") if not ln.startswith("#"))
    rows = list(csv.DictReader(body.splitlines()))
    if len(rows) < 100:
        # The table covers every ISO country. A short read is a broken parse,
        # not a smaller world.
        raise TableUnreadable(
            f"{path}: only {len(rows)} row(s) parsed; the table covers every ISO "
            "country, so this is a broken read rather than a short table")
    return {r["iso"]: r for r in rows}


def resolve(iso: Optional[str], table: Optional[dict] = None) -> Tuple[str, bool]:
    """Return (all_party, needs_finer) for an ISO code.

    `iso` may be a country ("US") or a subdivision ("US-CA"). An unknown code,
    an empty one, or None all return ("unclear", False): not determined, and
    the caller must take the strictest path. There is deliberately no branch
    that returns "no" for anything not explicitly recorded as "no".
    """
    table = table if table is not None else load()
    if not iso or not isinstance(iso, str):
        return ("unclear", False)
    key = iso.strip()
    row = table.get(key)
    if row is None and "-" in key:
        # A subdivision we do not carry: fall back to its country, which for a
        # granular country is itself `unclear` with needs_finer set, so the
        # caller is told to ask rather than given a federal baseline that is
        # wrong for that subdivision.
        row = table.get(key.split("-", 1)[0])
    if row is None:
        return ("unclear", False)
    value = row.get("all_party", "unclear")
    if value not in VALID:
        return ("unclear", False)
    return (value, row.get("needs_finer", "no") == "yes")


def must_ask_everyone(iso: Optional[str], table: Optional[dict] = None) -> bool:
    """True unless this place is RECORDED as one-party and needs no escalation.

    The only way to get False is an explicit `no` with no escalation pending.
    Unknown, unclear, unreadable-value and needs-finer all return True.
    """
    value, finer = resolve(iso, table)
    return not (value == "no" and not finer)
