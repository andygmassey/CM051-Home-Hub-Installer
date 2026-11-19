"""Reader glue for the privacy level (CM041).

Every CM041 reader that fetches a level goes through this module and the
helper in pwg_privacy (effective_level, may_leave, outbound_ok,
filter_outbound_facts, legacy_l0_guard). No reader reads a privacy predicate
or decides an outbound verdict itself (tests/test_no_direct_level_reads.py).

DESTINATION: a route passes the destination its caller declared (the handler
reads it from the request). ``None`` resolves to ``unknown``, the strictest row (fail closed), never
to a hard-coded value at a call site.
"""
from __future__ import annotations

try:  # package context
    from . import pwg_privacy as _p
except ImportError:  # root on sys.path (ical-server, brief, tests)
    import pwg_privacy as _p


def optional_level(subject_var: str, out_var: str, subjects=None) -> str:
    """OPTIONAL group binding ``?out_var`` to ``?subject_var``'s effective level.

    Both names are given without the leading ``?``.
    """
    return "OPTIONAL { " + _p.sparql_effective_level(subject_var, out_var, subjects=subjects) + " }"


def optional_level_iri(iri: str, out_var: str) -> str:
    """As optional_level, for a constant subject IRI (a VALUES row joins it)."""
    # VALUES sits INSIDE the OPTIONAL: outside it, rdflib drops every outer
    # row when the IRI carries no tag (Oxigraph does not); inside, both
    # engines keep the row with the level unbound (tested on both).
    subj = "_subj_" + out_var
    return ("OPTIONAL { VALUES ?" + subj + " { <" + iri + "> } "
            + _p.sparql_effective_level(subj, out_var) + " }")


def level_input(value):
    """A SPARQL level binding -> the raw value effective_level takes.

    ``None`` (unbound) and ``""`` mean no spelling present.
    """
    return None if value in (None, "") else value


def level_of(value):
    """One raw or SPARQL value -> 'L0'..'L3', or None (absent or unreadable)."""
    lvl = _p.effective_level(level_input(value))
    return lvl if lvl in _p.VALID_PRIVACY_LEVELS else None


def resolve(destination):
    """The destination a caller declared, or ``unknown`` (strictest) when none."""
    return _p.resolve_destination(destination)


def outbound_ok(record, owner_level=None, destination=None) -> bool:
    """True when ``record`` may be served to ``destination`` (helper verdict)."""
    return _p.outbound_ok(record, owner_level, resolve(destination))


def outbound_filter(facts, owner_level=None, destination=None):
    """Visible subset of a fact LIST for ``destination``, fail-closed.

    For owner_local, a served dict that the helper labels (L3, untagged, or
    legacy L0) comes back as a COPY carrying ``"privacy_label": "private"``. No other
    destination ever sees those items, so nothing else is labelled.
    """
    dest = resolve(destination)
    visible = _p.filter_outbound_facts(facts, owner_level, dest)
    out = []
    for f in visible:
        if isinstance(f, dict) and _p.served_label(f, owner_level, dest):
            f = dict(f, privacy_label="private")
        out.append(f)
    return out


def is_labelled(item) -> bool:
    """True when an outbound_filter result carries the owner_local label."""
    return isinstance(item, dict) and item.get("privacy_label") == "private"


def level_serves(level, destination=None) -> bool:
    """Gate for one bare level (a SPARQL-derived value), same rule as outbound_ok.

    Delegates to the helper: an absent level is canonical L3 (owner_local
    only, labelled); an unmigrated L0 is withheld through legacy_l0_guard
    except for owner_local; otherwise the table decides for ``destination``.
    """
    return _p.outbound_ok(level_input(level), destination=resolve(destination))


def outbound_hidden(record, owner_level=None, destination=None) -> bool:
    """True when ``record`` must be withheld from ``destination``."""
    return not outbound_ok(record, owner_level, destination)


def served_label(record, owner_level=None, destination=None):
    """The label an owner_local item carries ("private"), else None."""
    return _p.served_label(record, owner_level, resolve(destination))


def label_of(level, destination=None) -> dict:
    """``{"privacy_label": "private"}`` for an owner_local item at a bare level that is
    L3, untagged, or legacy L0; ``{}`` otherwise. Splice into a served dict."""
    if _p.served_label(level_input(level), destination=resolve(destination)):
        return {"privacy_label": "private"}
    return {}


def label_for(record, owner_level=None, destination=None) -> dict:
    """As label_of, for a record and its owner: ``{"privacy_label": "private"}`` when
    owner_local serves an L3, untagged or unreadable item, or one whose OWN
    level is a LEGACY (unmigrated) L0, even beside a looser owner level)."""
    dest = resolve(destination)
    if _p.served_label(record, owner_level, dest) or (
            _p.legacy_l0_guard(record)
            and _p.may_leave(_p._TOP, dest) == "labelled"):
        return {"privacy_label": "private"}
    return {}
