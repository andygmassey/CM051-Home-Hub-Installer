"""Read-side consumer of the memory-hygiene verdict overlay.

The write side (``run.py`` / ``weight.py``) stamps ``HygieneVerdict``
rows into the isolated ``<urn:pwg:hygiene>`` named graph. Those verdicts
change NOTHING on their own -- a verdict only matters when a fact-listing
surface consults it. This module is that canonical READ side: any
surface that lists facts calls :func:`load_verdicts` once, then
:func:`is_dropped` / :func:`rank_weight` per fact to

  * DROP facts the pass retired (superseded / archived / deleted), and
  * re-RANK the survivors by the overlay's ``effectiveWeight`` instead of
    raw source confidence (the rank key the hygiene design specifies,
    ``weight.py``).

Absence of a verdict means "active + full weight" (fail-safe): a surface
whose overlay is empty -- hygiene never run, Oxigraph down, graph absent
-- behaves EXACTLY as it did before this overlay existed. Never raises.

Consumers inject their own SPARQL-SELECT callable (``select_fn``) so this
module stays free of any transport/config coupling and is unit-testable
offline. The query string and binding parser are the SAME canonical
primitives the writer round-trips through (``graph_io.build_verdicts_query``
/ ``graph_io.parse_verdict_bindings``) -- no second, drifting copy.
"""
from __future__ import annotations

from typing import Callable, Dict, List

from ostler_hygiene import graph_io
from ostler_hygiene.model import (
    HygieneVerdict,
    STATUS_ARCHIVED,
    STATUS_DELETED,
    STATUS_SUPERSEDED,
)

#: A verdict in any of these states removes the fact from every read
#: surface. Mirrors the writer's terminal statuses (spec 2.2 / 3.4).
DROP_STATUSES = frozenset({STATUS_SUPERSEDED, STATUS_ARCHIVED, STATUS_DELETED})

SelectFn = Callable[[str], List[dict]]


def load_verdicts(select_fn: SelectFn) -> Dict[str, HygieneVerdict]:
    """Load the overlay as ``{fact_uri: HygieneVerdict}``. Never raises.

    ``select_fn`` runs a SPARQL SELECT and returns value-flattened
    binding dicts (the shape both ``assistant_api/ical-server.py`` and
    ``ostler_hygiene/run.py`` produce). Any failure -- graph absent,
    Oxigraph unreachable, hygiene never run -- yields ``{}`` so the
    caller degrades to raw source facts.
    """
    try:
        rows = select_fn(graph_io.build_verdicts_query())
        return graph_io.parse_verdict_bindings(rows)
    except Exception:
        return {}


def is_dropped(fact_uri: str, verdicts: Dict[str, HygieneVerdict]) -> bool:
    """True iff the fact carries a superseded/archived/deleted verdict.

    A ``user_override`` verdict never drops a fact here: the automated
    pass excludes overridden facts from those terminal statuses, so an
    override can only ever leave a fact ``active`` (visible).
    """
    v = verdicts.get(fact_uri)
    return v is not None and v.status in DROP_STATUSES


def rank_weight(
    fact_uri: str,
    verdicts: Dict[str, HygieneVerdict],
    fallback: float,
) -> float:
    """The overlay's ``effectiveWeight`` for a fact, else ``fallback``.

    ``fallback`` is the surface's pre-hygiene rank key (raw confidence),
    so an un-scored fact keeps its old ordering exactly.
    """
    v = verdicts.get(fact_uri)
    if v is not None and v.effective_weight is not None:
        return v.effective_weight
    return fallback
