"""Canonical privacy helper for the Ostler Hub: one file, no repo imports.

CANONICAL SCALE (owner-approved 2026-11-16; outbound ruling 2026-11-17,
design PRIVACY_SCALE_DESIGN_2026-11-16.md section 1):

    L0  public / unredacted            least private
    L1  personal, PII redacted
    L2  private / sensitive
    L3  owner-only, never off the box  most private

    Missing or unknown level = L3.

OUTBOUND, per request (Archie, 2026-11-17, replaces the "strictest destination"
rule). Every Hub-route request carries ``destination``. An undeclared or unknown
destination counts as ``cloud`` (fail closed). ``may_leave(level, destination)``
is the only decider.

    level  owner_local  owner_channel  cloud     others    export
    L0     full         full           full      full      full
    L1     full         full           redacted  redacted  redacted
    L2     full         full           no        no        no
    L3     labelled     no             no        no        no

  owner_local   = the Hub UI, and the owner-scoped bearer once it lands. It is
                  EXEMPT from legacy_l0_guard, and shows L3 and legacy L0 labelled
                  "private" (``served_label``).
  owner_channel = the owner's own brief and own-channel replies.
  cloud         = a cloud model.   others = other people.   export = any file.

  "full" and "labelled" serve; "redacted" serves only the redacted form, which
  no route produces yet, so it is withheld; "no" never serves.
  Every route response is tagged ``served_for: <destination>``.

LEGACY, named wherever it remains:

  * ``legacy_l0_guard``: an UNMIGRATED L0 from the old PWG/CM041 writers meant
    "owner-private". It is withheld, for every destination, until that store's
    per-writer relabel has run. A record is migrated when it carries the relabel
    contract (``CANONICAL_SCALE_KEY``); a raw value never does.
  * ``legacy_absent_serves``: an untagged person is served by the old 133
    rule. Canonical rule: a missing tag is L3. Only the person gate passes it.

ORDER for ``effective_level`` (strictest wins):
    L0 < L1 < L2 < UNREADABLE < L3.
    A missing tag beside a present one counts as L3. A record with no tag at
    all is ``ABSENT``, which the readers treat as L3.

OWNER-LOCAL: ``is_l3`` and ``filter_l3_facts`` serve L0, L1 and L2 and hide
L3, UNREADABLE and ABSENT. They are for surfaces on the owner's own Hub UI
only, never for a Hub route.

Readers MUST go through ``effective_level``: reading one key, or stopping at
the first spelling that parses, is the leak this module exists to prevent.

VENDORING NOTE: ``assistant_api/ical-server.py`` and ``meeting_syncer/brief.py``
import this module. If EITHER is vendored downstream (e.g. CM051
``vendor/cm041/``), THIS FILE MUST BE VENDORED ALONGSIDE IT. One doctrine,
one helper; do not fork a second copy.
"""
from __future__ import annotations

# The four canonical levels.
VALID_PRIVACY_LEVELS = frozenset({"L0", "L1", "L2", "L3"})

# Privacy-level keys a per-fact dict might carry. A Qdrant payload fact stores
# it snake-cased; an Oxigraph-mirrored fact could arrive under any spelling.
FACT_PRIVACY_KEYS = ("privacy_level", "privacyLevel", "privacy", "level")

# Every spelling a record-level privacy value is written under.
PRIVACY_PREDICATES = (
    "https://schema.ostler.ai/ontology#privacyLevel",   # pwg:privacyLevel
    "urn:ostler:privacyLevel",
)

# The relabel contract. A per-writer relabel writes this beside the canonical
# level on every record it migrates. A record without it is unmigrated.
CANONICAL_SCALE_KEY = "privacy_scale"
CANONICAL_SCALE_VALUE = "canonical-2026-11"

# The destinations of the outbound table.
DESTINATIONS = ("owner_local", "owner_channel", "cloud", "others", "export")
# An undeclared or unknown destination is cloud: fail closed.
DEFAULT_DESTINATION = "cloud"

# The outbound table. "full" = serves; "labelled" = serves, labelled private;
# "redacted" = only the redacted form may leave (no route produces it, so it is
# withheld); "no" = never leaves. Lift verbatim with the module.
_OUTBOUND_TABLE = {
    "L0": {"owner_local": "full", "owner_channel": "full", "cloud": "full", "others": "full", "export": "full"},
    "L1": {"owner_local": "full", "owner_channel": "full", "cloud": "redacted", "others": "redacted", "export": "redacted"},
    "L2": {"owner_local": "full", "owner_channel": "full", "cloud": "no", "others": "no", "export": "no"},
    "L3": {"owner_local": "labelled", "owner_channel": "no", "cloud": "no", "others": "no", "export": "no"},
}
SERVING_VERDICTS = ("full", "labelled")


def resolve_destination(value):
    """The destination a request declared, or ``cloud`` when it declared none
    or an unknown one (fail closed)."""
    if value in DESTINATIONS:
        return value
    return DEFAULT_DESTINATION


class _Absent:
    """Typed sentinel for 'no privacy tag at all'. Compare by identity."""
    __slots__ = ()

    def __repr__(self):
        return "ABSENT"


ABSENT = _Absent()

# Strictness, least to most restrictive. UNREADABLE sits between L2 and L3: a
# present value that does not parse is withheld, but it is not known to be L3.
_RANK = {"L0": 0, "L1": 1, "L2": 2, "UNREADABLE": 3, "L3": 4}


def parse_privacy_level(value):
    """Normalise a raw privacy value to 'L0'..'L3', else None.

    Case- and whitespace-insensitive. None, empty, or any value outside
    {L0..L3} gives None.
    """
    if value is None:
        return None
    level = str(value).strip().upper()
    return level if level in VALID_PRIVACY_LEVELS else None


def _classify_value(value):
    """One raw spelling's value -> 'L0'..'L3', 'UNREADABLE', or ABSENT (blank)."""
    if value is None or str(value).strip() == "":
        return ABSENT
    return parse_privacy_level(value) or "UNREADABLE"


def effective_level(record, owner_level=None):
    """The strictest class across EVERY spelling a record carries.

    Returns "L0", "L1", "L2", "L3", "UNREADABLE", or the ``ABSENT`` sentinel
    (test with ``is ABSENT``).

    ``record`` may be a dict (every key in FACT_PRIVACY_KEYS is read), a list
    of (predicate, value) pairs (a triple view over PRIVACY_PREDICATES and the
    keys above), a bare raw value, or None.
    ``owner_level``: optional raw level of the owning node, counted as one more
    spelling.

    Rules:
      * ABSENT only when no spelling carries a non-blank value at all.
      * A missing (blank) spelling beside a present one counts as L3.
      * Otherwise the most restrictive present class wins:
        L0 < L1 < L2 < UNREADABLE < L3.
    So L0+L2 -> L2; L2+junk -> UNREADABLE; L1+L3 -> L3; blank+L1 -> L3.
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
    classes = [_classify_value(v) for v in values]
    present = [c for c in classes if c is not ABSENT]
    if not present:
        return ABSENT
    if len(present) < len(classes):
        present.append("L3")        # a missing tag beside a present one is L3
    return max(present, key=_RANK.__getitem__)


def may_leave(level, destination):
    """The outbound table: "full", "labelled", "redacted" or "no".

    ``level`` is one of "L0".."L3", or ``ABSENT``/"UNREADABLE" (both "no").
    An unknown ``destination`` is resolved to ``cloud`` (fail closed).
    """
    destination = resolve_destination(destination)
    if level is ABSENT or level not in _OUTBOUND_TABLE:
        return "no"
    return _OUTBOUND_TABLE[level][destination]


def _is_unmigrated_l0(item):
    if item is None:
        return False
    if isinstance(item, dict):
        if effective_level(item) != "L0":
            return False
        return item.get(CANONICAL_SCALE_KEY) != CANONICAL_SCALE_VALUE
    return _classify_value(item) == "L0"


def legacy_l0_guard(item, *sources):
    """True when the item or any linked source is an UNMIGRATED L0.

    LEGACY. The old PWG L0 meant "owner-private", so it is withheld outbound
    until the store's per-writer relabel has run: old PWG L0 meant owner-private;
    withheld until relabelled. A record is migrated when it carries
    ``CANONICAL_SCALE_KEY == CANONICAL_SCALE_VALUE``; the relabel writes that
    beside the new level. A raw value carries no contract, so it is always
    unmigrated. After the relabel, canonical L0 is served.
    """
    return any(_is_unmigrated_l0(x) for x in (item, *sources))


def _record_level(record):
    """The effective parseable level L0..L3, or None (ABSENT or UNREADABLE)."""
    level = effective_level(record)
    return level if level in VALID_PRIVACY_LEVELS else None


def is_l3(record, owner_level=None):
    """Owner-local fail-closed test. ``True`` => HIDE the record.

    OWNER-LOCAL ONLY: it serves L0, L1 and L2, so it must never gate a Hub
    route. Hidden when the effective level is L3, UNREADABLE, or ABSENT.
    """
    level = effective_level(record, owner_level)
    return level is ABSENT or level in ("L3", "UNREADABLE")


def outbound_ok(record, owner_level=None, destination=DEFAULT_DESTINATION,
                legacy_absent_serves=False):
    """True when a record may be served to ``destination`` (table verdict is
    "full" or "labelled"). An undeclared destination is cloud.

    An unmigrated L0 is withheld through ``legacy_l0_guard`` for every
    destination. ``legacy_absent_serves`` is LEGACY (the 133 untagged rule):
    only the person gate and the derived-preferences route pass it. A fact with
    no tag is refused by default.
    """
    destination = resolve_destination(destination)
    level = effective_level(record, owner_level)
    if level is ABSENT:
        return bool(legacy_absent_serves)
    # owner_local is EXEMPT from the legacy guard: legacy L0 meant owner-private,
    # which is exactly what the owner's own Hub UI is for (Archie, 2026-11-17).
    if destination != "owner_local" and legacy_l0_guard(record):
        return False
    return may_leave(level, destination) in SERVING_VERDICTS


def served_label(record, owner_level=None, destination=DEFAULT_DESTINATION):
    """The label a served owner_local item carries: "private" for an L3 item, or
    an unmigrated legacy L0 (owner-private). None for anything else, and for
    every other destination (those never see these items)."""
    if resolve_destination(destination) != "owner_local":
        return None
    level = effective_level(record, owner_level)
    if level == "L3" or (level == "L0" and legacy_l0_guard(record)):
        return "private"
    return None


def filter_outbound_facts(facts, owner_level=None, destination=DEFAULT_DESTINATION):
    """Visible subset of a facts *list* under :func:`outbound_ok`, fail-closed.

    ``facts`` MUST be a list; any other shape is dropped whole -> ``[]``.
    """
    if not isinstance(facts, list):
        return []
    return [f for f in facts if outbound_ok(f, owner_level, destination)]


def filter_l3_facts(facts, owner_level=None):
    """Owner-local L3 filter for a facts *list*. NOT for Hub routes.

    Hides L3, UNREADABLE and ABSENT; serves L0, L1 and L2. Hub routes must use
    :func:`filter_outbound_facts`. ``facts`` MUST be a list; else -> ``[]``.
    """
    if not isinstance(facts, list):
        return []
    return [f for f in facts if not is_l3(f, owner_level)]


def sparql_effective_level(subject_var="s", out_var="effLevel"):
    """SPARQL subquery: one row per subject, carrying its effective level.

    Insert as a group pattern. Binds ``?<subject_var>`` and ``?<out_var>`` to one
    of "L0".."L3" or "UNREADABLE". It NEVER emits an absent marker: a subject
    with no non-blank tag has NO row; map the missing binding with
    ``effective_level(None)``, which gives ``ABSENT``. Mirrors ``effective_level``
    exactly: a blank tag beside a present one gives L3. Reads the default graph
    AND every named graph (UNION). tests/test_privacy_effective_level.py runs
    both on one store.
    """
    s = subject_var
    preds = ", ".join(f"<{p}>" for p in PRIVACY_PREDICATES)
    # Rank of a non-blank value, offset by one so that 0 means "no non-blank".
    # L0=1 L1=2 L2=3 UNREADABLE=4 L3=5. A blank value is rank 0 and sets _bl.
    rank = (
        'IF(?_pn = "", 0, IF(?_pn = "L0", 1, IF(?_pn = "L1", 2, '
        'IF(?_pn = "L2", 3, IF(?_pn = "L3", 5, 4)))))'
    )
    name = r'BIND(REPLACE(UCASE(STR(?_pv)), "\\s", "") AS ?_pn)'
    blank = 'BIND(IF(?_pn = "", 1, 0) AS ?_bl)'
    level = (
        'IF(?_anyb = 1, "L3", IF(?_mr = 5, "L3", IF(?_mr = 4, "UNREADABLE", '
        'IF(?_mr = 3, "L2", IF(?_mr = 2, "L1", "L0")))))'
    )
    return (
        "{ SELECT ?%(s)s (%(level)s AS ?%(out)s) WHERE { "
        "SELECT ?%(s)s (MAX(?_rk) AS ?_mr) (MAX(?_bl) AS ?_anyb) WHERE { "
        "{ ?%(s)s ?_pp ?_pv . } UNION { GRAPH ?_pg { ?%(s)s ?_pp ?_pv . } } "
        "FILTER(?_pp IN (%(preds)s)) "
        "%(name)s %(blank)s BIND(%(rank)s AS ?_rk) "
        "} GROUP BY ?%(s)s HAVING (MAX(?_rk) > 0) } }"
    ) % {"s": s, "out": out_var, "level": level, "preds": preds,
         "name": name, "blank": blank, "rank": rank}


def provenance_verdict(own, sources=()):
    """Visibility of one item, from its OWN level and its linked sources.

    ``own``: the item's own privacyLevel (raw), or None if it has none.
    ``sources``: the raw level of each linked source, None where the link has
    no level.

    The own level is read first, then the linked sources; most-restrictive
    wins. For outbound withholding of an unmigrated L0, see ``legacy_l0_guard``.

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


def _classify(raw):
    """ABSENT (no value), a parsed level, or UNREADABLE (a value that is not
    a level). ABSENT and UNREADABLE stay distinct: ABSENT keeps the item as
    legacy, UNREADABLE withholds it."""
    if raw is None or str(raw).strip() == "":
        return "ABSENT"
    return parse_privacy_level(raw) or "UNREADABLE"
