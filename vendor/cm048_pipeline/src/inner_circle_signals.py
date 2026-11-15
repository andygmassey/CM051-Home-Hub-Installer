"""Signal adapter: the store's windowed signals -> the provider's people payload.

Reads the per-person windows that person_signals_graph (CM048 #129) wrote into
GRAPH <urn:ostler:user/<user_id>>, keyed by the People id the Hub passes in.
Business senders are classified by handle_resolution.is_business_sender (CM048
#134) on the person's handle. Nothing is written here.

Input rows (from the Hub's People store), one per person:
    {"id": str, "handle": str?, "privacy_level": str?, "minor": bool?,
     "deceased": bool?, "do_not_suggest": bool?, "contacts_label": str?,
     "work_domain": bool?, "close_friend": bool?, "photo_count": int?,
     "meetings_12m": int?, "warmth": float?}

Output: {"people": [PersonSignals dicts], "p90_msgs": null}, for
inner_circle.compute_from_payload.

CLI:
    python3 -I inner_circle_signals.py --build <rows.json> --sparql-url <url> --user <user_id>
prints the payload on stdout. The SPARQL endpoint is queried with a SELECT
that returns JSON (application/sparql-results+json).
"""
from __future__ import annotations

import json
import sys
import urllib.parse
import urllib.request
from typing import Callable, Iterable, Optional

from src.handle_resolution import is_business_sender
from src.person_signals_graph import NS, PREDICATES, graph_for, subject_for

# predicate local name -> PersonSignals field, reversed from the writer's table.
_FIELD_FOR_LOCAL = {local: key for key, local in PREDICATES.items()}
_FLOAT_KEYS = {"reciprocity_365", "median_reply_min_365", "last_contact_days"}

# Facts the Hub already holds, passed through to PersonSignals unchanged.
_PASS_THROUGH = (
    "contacts_label", "work_domain", "close_friend", "photo_count", "meetings_12m",
    "warmth", "privacy_level", "minor", "deceased", "do_not_suggest",
)


def signal_query(user_id: str, subject: str) -> str:
    g = graph_for(user_id)
    return f"SELECT ?p ?o WHERE {{ GRAPH <{g}> {{ <{subject}> ?p ?o }} }}"


def _values_from_bindings(bindings: Iterable[dict]) -> dict:
    out = {}
    for b in bindings:
        pred = b.get("p", {}).get("value", "")
        if not pred.startswith(NS):
            continue
        field = _FIELD_FOR_LOCAL.get(pred[len(NS):])
        if field is None:
            continue
        raw = b.get("o", {}).get("value")
        if raw is None:
            continue
        try:
            out[field] = float(raw) if field in _FLOAT_KEYS else int(float(raw))
        except (TypeError, ValueError):
            continue  # a value that does not parse is unknown, never zero
    return out


def build_payload(rows: Iterable[dict], *, user_id: str,
                  query: Callable[[str], list]) -> dict:
    """``query(sparql) -> [sparql-json binding dicts]``. Pure apart from the query."""
    people = []
    for row in rows:
        pid = row.get("id")
        if not isinstance(pid, str) or not pid:
            continue
        entry = {"person_id": pid}
        for key in _PASS_THROUGH:
            if row.get(key) is not None:
                entry[key] = row[key]
        if is_business_sender(row.get("handle")):
            entry["business_sender"] = True
        else:
            entry.update(_values_from_bindings(
                query(signal_query(user_id, _subject(user_id, pid)))))
        people.append(entry)
    return {"people": people, "p90_msgs": None}


def _subject(user_id: str, person_id: str) -> str:
    # subject_for returns "<iri>" with brackets; the query wants the bare IRI.
    return subject_for(user_id, person_id)[1:-1]


def sparql_http_query(url: str) -> Callable[[str], list]:
    def run(sparql: str) -> list:
        data = urllib.parse.urlencode({"query": sparql}).encode("utf-8")
        req = urllib.request.Request(url, data=data, headers={
            "Accept": "application/sparql-results+json",
            "Content-Type": "application/x-www-form-urlencoded",
        })
        # The Hub's store is loopback. Never send it through a system proxy.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(req, timeout=20) as resp:
            body = json.loads(resp.read().decode("utf-8"))
        return body.get("results", {}).get("bindings", [])
    return run


def main(argv: Optional[list] = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 6 or args[0] != "--build" or args[2] != "--sparql-url" or args[4] != "--user":
        print("usage: inner_circle_signals.py --build <rows.json> --sparql-url <url> --user <id>",
              file=sys.stderr)
        return 64
    with open(args[1], encoding="utf-8") as fh:
        rows = json.load(fh)
    payload = build_payload(rows, user_id=args[5], query=sparql_http_query(args[3]))
    print(json.dumps(payload, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
