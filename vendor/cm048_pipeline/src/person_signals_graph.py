"""Consumer-side graph write for windowed per-person message signals.

Behind OSTLER_INNER_CIRCLE. Default off: with the flag unset, or set to anything
other than exactly "1", nothing is written and the update function is never
called.

Where it writes: the per-user named graph urn:ostler:user/<user_id>, the same
graph CM048's writer uses. Readers that query the default graph see nothing,
so readers must scope with GRAPH (see the warmth finding, 2026-11-15).

What it writes: one subject per person, keyed by a hash of (user, person id).
The raw handle never enters the graph. Unknown values (None) are omitted, never
written as zero. Each row replaces its subject's previous values (DELETE WHERE
then INSERT DATA), so a repeat write is idempotent and a changed value replaces
the old one.

Resolution: rows are keyed by handle. Linking a handle to a graph Person is a
separate step and is not done here. Each subject records resolution "unresolved"
until that step exists.
"""
from __future__ import annotations

import hashlib
import os
from datetime import datetime, timezone
from typing import Callable, Iterable, Optional

FLAG_ENV = "OSTLER_INNER_CIRCLE"
NS = "urn:ostler:"

PREDICATES = {
    "sent_30": "msgSent30",
    "recv_30": "msgRecv30",
    "sent_90": "msgSent90",
    "recv_90": "msgRecv90",
    "sent_365": "msgSent365",
    "recv_365": "msgRecv365",
    "reciprocity_365": "reciprocity365",
    "active_months_12": "activeMonths12",
    "median_reply_min_365": "medianReplyMin365",
    "reply_pairs_365": "replyPairs365",
    "last_contact_days": "lastContactDays",
}
_FLOAT_KEYS = {"reciprocity_365", "median_reply_min_365", "last_contact_days"}


def enabled(env: Optional[dict] = None) -> bool:
    e = os.environ if env is None else env
    return e.get(FLAG_ENV, "0") == "1"


def graph_for(user_id: str) -> str:
    return f"{NS}user/{user_id}"


def subject_for(user_id: str, person_id: str) -> str:
    digest = hashlib.sha256(f"{user_id}|{person_id}".encode("utf-8")).hexdigest()[:24]
    return f"<{NS}person-signal/{digest}>"


def _literal(key: str, value) -> str:
    if key in _FLOAT_KEYS:
        return f'"{float(value)!r}"^^<http://www.w3.org/2001/XMLSchema#double>'
    return f'"{int(value)}"^^<http://www.w3.org/2001/XMLSchema#integer>'


def _iso_literal(value: str) -> str:
    safe = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")
    return f'"{safe}"^^<http://www.w3.org/2001/XMLSchema#dateTime>'


def build_update(rows: Iterable[dict], *, user_id: str, snapshot_at: str) -> str:
    g = graph_for(user_id)
    parts = []
    for r in rows:
        s = subject_for(user_id, r["person_id"])
        resolution = r.get("resolution") or "unresolved"
        triples = [f"{s} <{NS}resolution> \"{resolution}\""]
        if resolution == "resolved" and r.get("person_iri"):
            triples.append(f"{s} <{NS}aboutPerson> <{r['person_iri']}>")
        triples.append(f"{s} <{NS}snapshotAt> {_iso_literal(snapshot_at)}")
        for key, pred in PREDICATES.items():
            if r.get(key) is None:
                continue
            triples.append(f"{s} <{NS}{pred}> {_literal(key, r[key])}")
        parts.append(
            f"DELETE WHERE {{ GRAPH <{g}> {{ {s} ?p ?o }} }} ;\n"
            f"INSERT DATA {{ GRAPH <{g}> {{\n  " + " .\n  ".join(triples) + " .\n} }"
        )
    return " ;\n".join(parts)


def attach_resolutions(rows: list, index: dict, *, iri_for: Callable[[str], str]) -> list:
    """Resolve each row's handle through the resolver. Ambiguous and unresolved rows
    get their status and no person link. Resolved rows get the person's IRI."""
    from src import handle_resolution as hr
    out = []
    for r in rows:
        res = hr.resolve(r["person_id"], index)
        new = dict(r)
        new["resolution"] = res.status
        new["person_iri"] = iri_for(res.person_id) if res.status == "resolved" else None
        out.append(new)
    return out


def write_windows(rows: list, *, user_id: str, apply_update: Callable[[str], None],
                  env: Optional[dict] = None, now_iso: Optional[str] = None) -> int:
    """Write the rows into the user's graph. Returns the number of rows written.

    Flag off: returns 0 and never calls apply_update.
    """
    if not enabled(env):
        return 0
    rows = list(rows)
    if not rows:
        return 0
    snapshot_at = now_iso or datetime.now(timezone.utc).isoformat()
    apply_update(build_update(rows, user_id=user_id, snapshot_at=snapshot_at))
    return len(rows)
