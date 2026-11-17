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

OUTBOUND RULE (Archie, CM041 #295, 2026-11-17). Two classes of caller:

  * OUTBOUND = any route or caller NOT proven owner-local. Today that is
    EVERY Hub API route. Outbound readers withhold L0, L3 and UNREADABLE,
    and serve L1, L2 and ABSENT (untagged). This is the 133 strict design.
  * OWNER-LOCAL is ONLY two surfaces: (a) requests carrying the owner-scoped
    bearer, once the 134 owner scope and audience marker land; (b) surfaces
    on the owner's own Hub UI. Only these may read L0 and L3.

``effective_level`` returns the strictest class across every spelling. A
missing tag is the ``ABSENT`` sentinel (identity, never the string); a
present-but-unparseable tag is ``"UNREADABLE"``.

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
FACT_PRIVACY_KEYS = ("privacy_level", "privacyLevel", "privacy", "level")

# Every spelling a record-level privacy value is written under. Readers MUST
# go through effective_level(); reading one key (or one predicate) and
# stopping at the first hit is the leak this module exists to prevent.
PRIVACY_PREDICATES = (
    "https://schema.ostler.ai/ontology#privacyLevel",   # pwg:privacyLevel
    "urn:ostler:privacyLevel",
)

class _Absent:
    """Typed sentinel for 'no privacy tag at all'. Compare by identity."""
    __slots__ = ()

    def __repr__(self):
        return "ABSENT"


ABSENT = _Absent()

# Strictness, least to most restrictive. ABSENT (no spelling present) is the
# untagged case. An UNREADABLE value may be a corrupted STRICTER label, so it
# outranks L1 and L2 and is never ignored: junk beside a valid level fails
# closed. L0 and L3 are withheld too, and rank above L2. Order fixed by Archie
# (CM041 #295 review): ABSENT < L1 < L2 < L0 < UNREADABLE < L3.
_STRICT_RANK = {ABSENT: 0, "L1": 1, "L2": 2, "L0": 3, "UNREADABLE": 4, "L3": 5}


def parse_privacy_level(value):
    """Normalise a raw privacy value to 'L0'/'L1'/'L2'/'L3', else None.

    Case- and whitespace-insensitive. ``None`` / empty / unparseable /
    any value outside {L0,L1,L2,L3} -> ``None`` ("no parseable signal").
    """
    if value is None:
        return None
    level = str(value).strip().upper()
    return level if level in VALID_PRIVACY_LEVELS else None


def _classify_value(value):
    """One raw spelling's value -> 'L0'..'L3', 'UNREADABLE' or 'ABSENT'."""
    if value is None or str(value).strip() == "":
        return ABSENT
    return parse_privacy_level(value) or "UNREADABLE"


def effective_level(record, owner_level=None):
    """The STRICTEST privacy class across EVERY spelling a record carries.

    Returns one of "L0", "L1", "L2", "L3", "UNREADABLE" or the ``ABSENT``
    sentinel (test with ``is ABSENT``).

    ``record`` may be:
      * a dict: every key in FACT_PRIVACY_KEYS is read, not the first hit;
      * a list of (predicate, value) pairs (a triple view): every pair whose
        predicate is a snake/camel key or one of PRIVACY_PREDICATES is read;
      * a bare raw value (string / None);
      * None: ABSENT.
    ``owner_level``: optional raw level of the owning node, counted as one
    more spelling (most-restrictive wins across record and owner).

    Order (least to most restrictive): ABSENT < L1 < L2 < L0 < UNREADABLE < L3.
    Consequences: L0+L2 -> L0 (withheld, not numeric max); L3+L1 -> L3;
    L0+L3 -> L3; junk+L1 -> UNREADABLE (withheld: junk never loses to a
    valid level, it may be a corrupted stricter label); junk alone ->
    UNREADABLE; nothing -> ABSENT (untagged).
    """
    if isinstance(record, dict):
        values = [record[k] for k in FACT_PRIVACY_KEYS if k in record]
    elif isinstance(record, (list, tuple)):
        values = [v for (pred, v) in record
                  if pred in FACT_PRIVACY_KEYS or pred in PRIVACY_PREDICATES]
    elif record is None:
        values = []
    else:
        values = [record]
    if owner_level is not None:
        values.append(owner_level)
    if not values:
        return ABSENT
    return max((_classify_value(v) for v in values), key=_STRICT_RANK.__getitem__)


def _record_level(record):
    """Strictest parseable L0..L3 across all spellings, or None."""
    level = effective_level(record)
    return level if level in VALID_PRIVACY_LEVELS else None


def is_l3(record, owner_level=None):
    """Fail-closed L3 test. ``True`` => HIDE the record.

    Hidden when the strictest class across every spelling (and the owner,
    if given) is L3, UNREADABLE, or ABSENT (no tag at all). L0, L1 and L2 are
    served here; outbound readers apply their own, narrower, rule on top.
    """
    level = effective_level(record, owner_level)
    return level is ABSENT or level in ("L3", "UNREADABLE")


def sparql_effective_level(subject_var="s", out_var="effLevel"):
    """SPARQL subquery: one row per subject, carrying its strictest class.

    Insert as a group pattern, e.g. ``OPTIONAL { {sparql} }`` or
    ``{ {sparql} }``. Binds ``?<subject_var>`` and ``?<out_var>`` to one of
    "L0".."L3" or "UNREADABLE". It NEVER emits an absent marker: a subject
    whose tags are all blank, or that has no privacy triple, has NO row.
    Map the missing binding with ``effective_level(None)``, which returns the
    ``ABSENT`` sentinel. Reads the default graph AND every named graph
    (UNION), so it works inside ``GRAPH ?g``. The rank mapping mirrors
    _STRICT_RANK exactly; tests/test_privacy_effective_level.py runs both on
    one store.
    """
    s = subject_var
    preds = ", ".join(f"<{p}>" for p in PRIVACY_PREDICATES)
    rank = (
        'IF(?_pn = "", 0, IF(?_pn = "L1", 1, IF(?_pn = "L2", 2, '
        'IF(?_pn = "L0", 3, IF(?_pn = "L3", 5, 4)))))'
    )
    name = (r'BIND(REPLACE(UCASE(STR(?_pv)), "\\s", "") AS ?_pn)')
    level = (
        'IF(?_mr = 5, "L3", IF(?_mr = 4, "UNREADABLE", IF(?_mr = 3, "L0", '
        'IF(?_mr = 2, "L2", IF(?_mr = 1, "L1", "UNREADABLE")))))'
    )
    return (
        "{ SELECT ?%(s)s (%(level)s AS ?%(out)s) WHERE { "
        "SELECT ?%(s)s (MAX(?_rk) AS ?_mr) WHERE { "
        "{ ?%(s)s ?_pp ?_pv . } UNION { GRAPH ?_pg { ?%(s)s ?_pp ?_pv . } } "
        "FILTER(?_pp IN (%(preds)s)) "
        "%(name)s BIND(%(rank)s AS ?_rk) "
        "} GROUP BY ?%(s)s HAVING (MAX(?_rk) > 0) } }"
    ) % {"s": s, "out": out_var, "level": level, "preds": preds,
         "name": name, "rank": rank}


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



def _classify(raw):
    """ABSENT (no value), a parsed level, or UNREADABLE (a value that is not
    a level). ABSENT and UNREADABLE stay distinct: ABSENT keeps the item as
    legacy, UNREADABLE withholds it."""
    if raw is None or str(raw).strip() == "":
        return "ABSENT"
    return parse_privacy_level(raw) or "UNREADABLE"


def provenance_verdict(own, sources=()):
    """Visibility of one item, from its OWN level and its linked sources.

    ``own``: the item's own privacyLevel (raw), or None if it has none.
    ``sources``: the raw level of each linked source (source conversation,
    source meeting, attendee), None where the link has no level.

    Order (Archie, 133): the item's own level first, then the linked
    sources; most-restrictive wins.

      * "l3"             -- own or any source is L3: withhold, counted.
      * "unknown"        -- own or any source is present but unreadable,
                            or a link does not resolve: withhold, counted.
      * "ok"             -- no L3, nothing unreadable, and at least one
                            readable L0/L1/L2: serve.
      * "legacy_untagged"-- no readable level anywhere: serve, and count it
                            so it is visible. Not a withhold.
    """
    own_c = _classify(own)
    if own_c == "L3":
        return "l3"
    if own_c == "UNREADABLE":
        return "unknown"
    classes = [_classify(s) for s in sources]
    if "L3" in classes:
        return "l3"
    if "UNREADABLE" in classes:
        return "unknown"
    if own_c in ("L0", "L1", "L2") or any(c in ("L0", "L1", "L2") for c in classes):
        return "ok"
    return "legacy_untagged"
