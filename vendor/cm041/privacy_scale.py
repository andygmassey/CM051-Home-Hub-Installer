"""Loader for the canonical privacy scale (privacy_scale_canonical.tsv, next to this file).

BYTE-IDENTICAL in every repo that carries it, pinned by sha256 together with the
table. Edit the shared copy and re-pin every repo in one held set; never edit one
copy alone. Stdlib only, Python 3.9+, no side effects at import beyond reading
the table.

Scale: L0 least private (public, no protection) ... L3 most private (owner-only).
A missing, empty, unknown or unparseable level is L3 (fail closed).

Code must not restate any of this (no level-to-meaning dicts, no allow-sets of
level literals): the conformance gate (test_privacy_scale_conformance.py) fails
on any such site outside this loader.
"""
from pathlib import Path

TABLE_PATH = Path(__file__).resolve().with_name("privacy_scale_canonical.tsv")


def _sections(path):
    """{section: [row, ...]} with comments and blank lines dropped. The first
    (unnamed) section is ``"levels"``. Unknown sections are kept, never parsed
    here, so another table appended to the file cannot break this loader."""
    out = {"levels": []}
    name = "levels"
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        if line.startswith("[") and line.rstrip().endswith("]"):
            name = line.strip()[1:-1]
            out.setdefault(name, [])
            continue
        out[name].append(line.split("\t"))
    return out


def _load(path=TABLE_PATH):
    sec = _sections(path)
    lv_head, lv_rows = sec["levels"][0], sec["levels"][1:]
    if lv_head != ["level", "rank", "meaning"]:
        raise ValueError("privacy scale table: unexpected levels header %r" % (lv_head,))
    levels = tuple(r[0] for r in lv_rows)
    rank = {r[0]: int(r[1]) for r in lv_rows}
    meaning = {r[0]: r[2] for r in lv_rows}
    ob_head, ob_rows = sec["outbound"][0], sec["outbound"][1:]
    if ob_head[0] != "destination" or tuple(ob_head[1:]) != levels:
        raise ValueError("privacy scale table: outbound header must list every level in order")
    outbound = {r[0]: dict(zip(levels, r[1:])) for r in ob_rows}
    legacy = {}
    for r in sec.get("legacy", [])[1:]:
        legacy[(r[0], r[1])] = r[3]
    st_head, st_rows = sec["scale_stamp"][0], sec["scale_stamp"][1:]
    if st_head != ["field", "value"] or len(st_rows) != 1:
        raise ValueError("privacy scale table: scale_stamp must hold exactly one field/value row")
    return levels, rank, meaning, outbound, legacy, tuple(st_rows[0])


LEVELS, RANK, MEANING, OUTBOUND, LEGACY, (SCALE_STAMP_FIELD, SCALE_STAMP_VALUE) = _load()
DEFAULT_LEVEL = max(LEVELS, key=RANK.__getitem__)
DESTINATIONS = tuple(d for d in OUTBOUND if d != "unknown")


def normalize(value):
    """Any raw level -> one of LEVELS. Missing, empty, unknown or unparseable -> L3."""
    if value is None:
        return DEFAULT_LEVEL
    text = str(value).strip().upper()
    return text if text in RANK else DEFAULT_LEVEL


def rank(value):
    """Meaning rank, 0 least private .. 3 most private (normalized first)."""
    return RANK[normalize(value)]


def strictest(*values):
    """The most private of several raw levels; none at all is L3."""
    if not values:
        return DEFAULT_LEVEL
    return max((normalize(v) for v in values), key=RANK.__getitem__)


def outbound_rule(value, destination):
    """'full', 'redacted', 'labelled' or 'no' for a raw level going to a destination.

    An unknown destination is read as the strictest ('unknown') row; an unknown
    level as L3."""
    row = OUTBOUND.get(destination, OUTBOUND["unknown"])
    return row[normalize(value)]


def is_canonical_stamp(stamp):
    """True when a record's scale stamp says it was written on this scale."""
    return stamp is not None and str(stamp).strip() == SCALE_STAMP_VALUE


def is_legacy_l0(value, stamp):
    """An L0 written without the canonical scale stamp: LEGACY-AMBIGUOUS until
    its store is relabelled. Outbound paths treat it per the [legacy] row (L3)."""
    return normalize(value) == "L0" and not is_canonical_stamp(stamp)


def legacy_treat_as(scale, old_label):
    """Canonical level a legacy label is treated as on outbound paths, or None
    when the table holds no ruled row for it (the caller then fails closed)."""
    return LEGACY.get((scale, old_label))
