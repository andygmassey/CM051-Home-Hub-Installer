"""Canonical fail-closed L3 privacy helper -- single source of truth.

This is the ONE helper every L3 read-side decision in the CM041 Hub
server routes through. It exists so the "hide L3 person facts" doctrine
cannot drift between the several readers that emit person facts
(``people_search``, ``person_context``, ``person_enrichment`` in
``assistant_api/ical-server.py`` and ``_get_person_facts`` in
``meeting_syncer/brief.py``).

Operator-approved doctrine (2026-06-28, Archie batch-1 F8):

    Read privacy from the record AND, where the record has an owning
    person/meeting node, that node's privacyLevel too -- MOST-RESTRICTIVE
    wins. Missing / empty / unparseable / any value not in {L0,L1,L2,L3}
    -> treat as L3 (hidden). Only an explicit, parseable L0/L1/L2 passes.
    Case/whitespace-insensitive. Non-list / un-auditable fact containers
    -> drop (fail-closed).

This is FAIL-CLOSED: the previous helper kept untagged facts (fail-OPEN),
which is the leak class Archie caught. An untagged fact is only visible
when an owning node supplies a parseable, non-L3 level for it to inherit;
with no parseable signal anywhere the fact is hidden.

VENDORING NOTE: both ``assistant_api/ical-server.py`` and
``meeting_syncer/brief.py`` import this module. If EITHER is vendored
downstream (e.g. CM051 ``vendor/cm041/``), THIS FILE MUST BE VENDORED
ALONGSIDE IT. One doctrine, one helper -- do not fork a second copy.
"""
from __future__ import annotations

# The four recognised privacy levels. Anything outside this set (including
# the empty string and non-string junk) is treated as "no parseable
# signal" and, absent any other signal, fails closed to hidden.
VALID_PRIVACY_LEVELS = frozenset({"L0", "L1", "L2", "L3"})

# Privacy-level keys a per-fact dict might carry. A Qdrant payload fact
# stores it snake-cased; an Oxigraph-mirrored fact could arrive under any
# of these spellings. All are checked.
FACT_PRIVACY_KEYS = ("privacy_level", "privacyLevel", "level")


def parse_privacy_level(value):
    """Normalise a raw privacy value to 'L0'/'L1'/'L2'/'L3', else None.

    Case- and whitespace-insensitive. ``None`` / empty / unparseable /
    any value outside {L0,L1,L2,L3} -> ``None`` ("no parseable signal").
    """
    if value is None:
        return None
    level = str(value).strip().upper()
    return level if level in VALID_PRIVACY_LEVELS else None


def _record_level(record):
    """Extract a parseable level from a fact record (dict), or None.

    Checks each recognised privacy key in order and returns the first
    that parses. A dict with no recognised/parseable key -> None.
    """
    if isinstance(record, dict):
        for key in FACT_PRIVACY_KEYS:
            if key in record:
                level = parse_privacy_level(record.get(key))
                if level is not None:
                    return level
    return None


def is_l3(record, owner_level=None):
    """Fail-closed L3 test. ``True`` => HIDE the record.

    ``record``: the fact/record itself -- a dict carrying a privacy key,
    a raw level string, or ``None``.
    ``owner_level``: the privacy level (raw or parsed) of the owning
    person/meeting node, when the caller can supply it.

    Contract:
      * Most-restrictive wins across {record level, owner level}.
      * A level counts only if it parses to L0/L1/L2/L3.
      * If NEITHER parses (missing / empty / unparseable / out-of-range)
        the record is treated as L3 and hidden.
      * Only an explicit, parseable L0/L1/L2 (with no L3 on either axis)
        is visible.
    """
    if isinstance(record, dict) or record is None:
        rec = _record_level(record)
    else:
        rec = parse_privacy_level(record)
    owner = parse_privacy_level(owner_level)
    levels = [lvl for lvl in (rec, owner) if lvl is not None]
    if not levels:
        return True                # no parseable signal -> fail closed
    return "L3" in levels          # most-restrictive: any L3 hides


def filter_l3_facts(facts, owner_level=None):
    """Return the visible subset of a facts *list*, fail-closed.

    ``facts`` MUST be a list to be auditable fact-by-fact; any other
    shape (dict, bare string, None) cannot be privacy-vetted per fact and
    is dropped whole -> ``[]``.

    Each element is tested with :func:`is_l3`. A bare-string element is a
    record with no parseable level: hidden unless ``owner_level`` clears
    it. This is the fail-closed inverse of the old "untagged kept" filter.
    """
    if not isinstance(facts, list):
        return []
    return [f for f in facts if not is_l3(f, owner_level)]
