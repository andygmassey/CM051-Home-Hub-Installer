"""Canonical privacy helper for the Ostler Hub: one file, no repo imports.

CANONICAL SCALE (owner-approved 2026-11-16; outbound ruling 2026-11-17,
design PRIVACY_SCALE_DESIGN_2026-11-16.md section 1):

    L0  public / unredacted            least private
    L1  personal, PII redacted
    L2  private / sensitive
    L3  owner-only, never off the box  most private

    Missing or unknown level = L3.

OUTBOUND, per request. THE TABLE IS NOT IN THIS FILE: it is the shared
``privacy_scale_canonical.tsv`` [outbound] section, read through its loader
``privacy_scale.py`` (CM041 #297, byte-identical in every repo, sha256-pinned).
Destinations (Archie 2026-11-17, the shared table's names win): owner_local,
owner_own_brief, thread_participants, cloud_model, others, export, and
``unknown`` = undeclared, which takes the strictest row. Every Hub-route
request carries ``destination``; an undeclared or unrecognised one is
``unknown``. ``may_leave(level, destination)`` is the only decider.

  owner_local      = the Hub UI on this Mac (loopback), and the owner-scoped
                     bearer once it lands. Shows L3, untagged and legacy L0
                     labelled "private" (``served_label``).
  owner_own_brief  = the owner's own brief and own-channel replies.
  thread_participants = a reply drafted into a thread, from that thread only.
  cloud_model = a cloud model.  others = other people.  export = any file.

  "full" and "labelled" serve; "redacted" serves only the redacted form, which
  no route produces yet, so it is withheld; "no" never serves.
  Every route response is tagged ``served_for: <destination>``.

LEGACY, named wherever it remains:

  * ``legacy_l0_guard``: an UNMIGRATED L0 from the old PWG/CM041 writers meant
    "owner-private". It is withheld, for every destination, until that store's
    per-writer relabel has run. A record is migrated when it carries the relabel
    contract (``CANONICAL_SCALE_KEY``); a raw value never does.
  * The 133 untagged rule (``legacy_absent_serves``) is RETIRED (Archie
    2026-11-17): a missing tag is L3, so ``outbound_ok`` serves an ABSENT
    record to owner_local (labelled "private") and every other destination
    follows the table (withheld).

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

# The scale, the outbound table and the stamp come from the shared table.
try:  # package context
    from . import privacy_scale as _scale
except ImportError:  # root on sys.path (ical-server, brief, tests)
    import privacy_scale as _scale

VALID_PRIVACY_LEVELS = frozenset(_scale.LEVELS)
# The two ends and the middle of the scale, by meaning rank, read from the
# table (privacy scale #297; used by the topic-mention verdict).
LEAST_PRIVATE = min(_scale.LEVELS, key=_scale.RANK.__getitem__)
MOST_PRIVATE = _scale.DEFAULT_LEVEL  # the fail-closed level
MIDDLE_LEVELS = tuple(l for l in _scale.LEVELS if l not in (LEAST_PRIVATE, MOST_PRIVATE))

# Privacy-level keys a per-fact dict might carry. A Qdrant payload fact stores
# it snake-cased; an Oxigraph-mirrored fact could arrive under any spelling.
FACT_PRIVACY_KEYS = ("privacy_level", "privacyLevel", "privacy", "level")

# Every spelling a record-level privacy value is written under.
PRIVACY_PREDICATES = (
    "https://schema.ostler.ai/ontology#privacyLevel",   # pwg:privacyLevel
    "urn:ostler:privacyLevel",
)

# The relabel contract ([scale_stamp] in the shared table). A record carrying
# the stamp value under either spelling is migrated; one without it is not.
# ONE spelling, the table's field (Archie 2026-11-17: ``privacyScale`` wins).
CANONICAL_SCALE_KEY = _scale.SCALE_STAMP_FIELD
SCALE_STAMP_KEYS = (CANONICAL_SCALE_KEY,)
CANONICAL_SCALE_VALUE = _scale.SCALE_STAMP_VALUE

# The destinations of the shared table. ``unknown`` (undeclared) is the
# strictest row and is what an undeclared or unrecognised destination becomes.
DESTINATIONS = _scale.DESTINATIONS
DEFAULT_DESTINATION = "unknown"
OWNER_LOCAL = "owner_local"

# Verdicts that serve ("full" as is, "labelled" with the private label).
SERVING_VERDICTS = ("full", "labelled")


def resolve_destination(value):
    """The destination a request declared, or ``unknown`` (the strictest row)
    when it declared none or one the table does not list."""
    if value in DESTINATIONS:
        return value
    return DEFAULT_DESTINATION


class _Absent:
    """Typed sentinel for 'no privacy tag at all'. Compare by identity."""
    __slots__ = ()

    def __repr__(self):
        return "ABSENT"


ABSENT = _Absent()

# Strictness, read from the table's ranks. UNREADABLE sits just below the most
# private level: a present value that does not parse is withheld, but it is
# not known to be L3. Doubling the table rank leaves that gap.
_TOP = _scale.DEFAULT_LEVEL
_BOTTOM = min(_scale.LEVELS, key=_scale.RANK.__getitem__)
_RANK = {lvl: 2 * r for lvl, r in _scale.RANK.items()}
_RANK["UNREADABLE"] = _RANK[_TOP] - 1


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
        present.append(_TOP)        # a missing tag beside a present one is L3
    return max(present, key=_RANK.__getitem__)


def may_leave(level, destination):
    """The outbound table: "full", "labelled", "redacted" or "no".

    Read from the shared table (``privacy_scale.outbound_rule``). ``level`` is
    one of the table's levels, or ``ABSENT``/"UNREADABLE": a missing or
    unknown level IS the most private level, so it gets that column
    ("labelled" for owner_local, "no" everywhere else).
    An undeclared or unknown ``destination`` is ``unknown`` (strictest row).
    """
    destination = resolve_destination(destination)
    if level is ABSENT or level not in VALID_PRIVACY_LEVELS:
        level = _TOP
    return _scale.outbound_rule(level, destination)


def _is_unmigrated_l0(item):
    if item is None:
        return False
    if isinstance(item, dict):
        stamp = next((item[k] for k in SCALE_STAMP_KEYS if item.get(k)), None)
        return _scale.is_legacy_l0(effective_level(item), stamp)
    return _scale.is_legacy_l0(_classify_value(item), None)


def legacy_l0_guard(item, *sources):
    """True when the item or any linked source is an UNMIGRATED L0.

    LEGACY. The old PWG L0 meant "owner-private", so it is withheld outbound
    until the store's per-writer relabel has run (LEGACY: old PWG L0 meant owner-private);
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

    OWNER-LOCAL ONLY (Archie, 2026-11-17): it serves L0, L1 and L2, so it must
    never gate a Hub route; every route goes through ``may_leave``
    (``outbound_ok``). Hidden when the effective level is the most private
    level, UNREADABLE, or ABSENT.
    """
    level = effective_level(record, owner_level)
    return level is ABSENT or _RANK[level] >= _RANK["UNREADABLE"]


# The shared table's [legacy] row for an unmigrated old-PWG/CM041 L0.
_LEGACY_L0_SCALE = "pwg_cm041_ladder"


def _treated_level(record, owner_level=None):
    """The level ``may_leave`` reads for a record: its effective level, or the
    table's [legacy] treat_as when the record is an unmigrated L0 (no row ->
    the most private level, fail closed)."""
    level = effective_level(record, owner_level)
    if level is not ABSENT and legacy_l0_guard(record):
        return _scale.legacy_treat_as(_LEGACY_L0_SCALE, _BOTTOM) or _TOP
    return level


def outbound_ok(record, owner_level=None, destination=DEFAULT_DESTINATION):
    """True when a record may be served to ``destination``: the shared table's
    verdict (``may_leave``) is "full" or "labelled". Undeclared = ``unknown``.

    A missing tag is the most private level, so it is served (labelled) to
    owner_local only. An unmigrated L0 is read as the table's [legacy]
    treat_as (L3): withheld everywhere except owner_local, where it is
    labelled.
    """
    destination = resolve_destination(destination)
    level = _treated_level(record, owner_level)
    return may_leave(level, destination) in SERVING_VERDICTS


def served_label(record, owner_level=None, destination=DEFAULT_DESTINATION):
    """"private" when the table's verdict for this record and destination is
    "labelled" (owner_local: L3, untagged, unreadable, legacy L0), else None."""
    level = _treated_level(record, owner_level)
    if may_leave(level, resolve_destination(destination)) == "labelled":
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


def sparql_effective_level(subject_var="s", out_var="effLevel", subjects=None):
    """SPARQL subquery: one row per subject, carrying its effective level.

    Insert as a group pattern. Binds ``?<subject_var>`` and ``?<out_var>`` to one
    of "L0".."L3" or "UNREADABLE". It NEVER emits an absent marker: a subject
    with no non-blank tag has NO row; map the missing binding with
    ``effective_level(None)``, which gives ``ABSENT``. Mirrors ``effective_level``
    exactly: a blank tag beside a present one gives L3. Reads the default graph
    AND every named graph (UNION). tests/test_privacy_effective_level.py runs
    both on one store.

    ``subjects`` (an iterable of IRIs) SCOPES the subquery: the VALUES block
    sits INSIDE the innermost WHERE, so the GROUP BY only ever sees those
    subjects. Without it the subquery aggregates the whole store on every
    evaluation, because SPARQL does not correlate a subquery with the outer
    group. Measured 2026-11-19 (Oxigraph 0.5.x, 11,500 synthetic persons): a
    full evaluation costs about 0.15 s and grows linearly with the store; the
    scoped form costs about 0.2 ms. Output is byte-identical when
    ``subjects`` is None.
    """
    s = subject_var
    values = ""
    if subjects is not None:
        iris = list(subjects)
        for _u in iris:
            if not isinstance(_u, str) or any(c in _u for c in '<>"{}| \n\r\t'):
                raise ValueError("sparql_effective_level: unsafe subject IRI")
        values = "VALUES ?%s { %s } " % (s, " ".join("<%s>" % _u for _u in iris))
    preds = ", ".join(f"<{p}>" for p in PRIVACY_PREDICATES)
    # Rank of a non-blank value, offset by one so that 0 means "no non-blank":
    # _RANK + 1, read from the shared table. A value that is not a level gets
    # the UNREADABLE rank. A blank value is rank 0 and sets _bl.
    by_rank = sorted(VALID_PRIVACY_LEVELS, key=_RANK.__getitem__)
    rank = str(_RANK["UNREADABLE"] + 1)
    for lvl in reversed(by_rank):
        rank = 'IF(?_pn = "%s", %d, %s)' % (lvl, _RANK[lvl] + 1, rank)
    rank = 'IF(?_pn = "", 0, %s)' % rank
    name = r'BIND(REPLACE(UCASE(STR(?_pv)), "\\s", "") AS ?_pn)'
    blank = 'BIND(IF(?_pn = "", 1, 0) AS ?_bl)'
    # Back from the max rank to a class; any blank beside a value is the top.
    level = '"%s"' % by_rank[0]
    for cls in sorted(list(VALID_PRIVACY_LEVELS) + ["UNREADABLE"], key=_RANK.__getitem__)[1:]:
        level = 'IF(?_mr = %d, "%s", %s)' % (_RANK[cls] + 1, cls, level)
    level = 'IF(?_anyb = 1, "%s", %s)' % (_TOP, level)
    return (
        "{ SELECT ?%(s)s (%(level)s AS ?%(out)s) WHERE { "
        "SELECT ?%(s)s (MAX(?_rk) AS ?_mr) (MAX(?_bl) AS ?_anyb) WHERE { "
        "%(values)s"
        "{ ?%(s)s ?_pp ?_pv . } UNION { GRAPH ?_pg { ?%(s)s ?_pp ?_pv . } } "
        "FILTER(?_pp IN (%(preds)s)) "
        "%(name)s %(blank)s BIND(%(rank)s AS ?_rk) "
        "} GROUP BY ?%(s)s HAVING (MAX(?_rk) > 0) } }"
    ) % {"s": s, "out": out_var, "level": level, "preds": preds,
         "name": name, "blank": blank, "rank": rank, "values": values}


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
    if own_c == _TOP:
        return "l3"
    if own_c == "UNREADABLE":
        return "unknown"
    classes = [_classify(s) for s in sources]
    if _TOP in classes:
        return "l3"
    if "UNREADABLE" in classes:
        return "unknown"
    readable = VALID_PRIVACY_LEVELS - {_TOP}
    if own_c in readable or any(c in readable for c in classes):
        return "ok"
    return "legacy_untagged"


def _classify(raw):
    """ABSENT (no value), a parsed level, or UNREADABLE (a value that is not
    a level). ABSENT and UNREADABLE stay distinct: ABSENT keeps the item as
    legacy, UNREADABLE withholds it."""
    if raw is None or str(raw).strip() == "":
        return "ABSENT"
    return parse_privacy_level(raw) or "UNREADABLE"
