#!/usr/bin/env python3
"""Delete the -180 "no location" sentinels that an earlier Photos extractor wrote
into the graph as photoLatitude / photoLongitude.

WHY THIS EXISTS. Photos stores -180 for "no location". The extractor passed it
through as a real coordinate, so every photo with no GPS became an event placed
in the Pacific. Measured on the shipped Mini16 graph (Archie, 2026-11-15):
13,432 of 45,890 PhotoEvents (29%) carry -180 coordinates, and 0 have a
photoPlace. The fix in HR015 (PR #1486) stops new events carrying it. It does
not touch events already in the store, and the wiki renders the store.

WHAT IT DELETES. For each event where EITHER coordinate is at most -179, both
coordinate triples are removed. The event and its photoDate are kept. Valid
coordinates on other events are not touched.

IDEMPOTENCY. The delete selects only sentinel coordinates, so a second run
finds none and issues no update. A marker file records a verified run. A run
that does not verify exits non-zero and writes no marker, so the next install
retries it.

SURFACES. A bare pattern is default-graph-only on this store. Every count and
the delete span the default graph AND named graphs (the same UNION used by
migrate_graph_namespace.py, measured there: named graphs held 100% of one
class of triples that a default-only check had missed).

Counts only leave this script. No coordinate, date or name is printed.

Usage:
    python3 repair_photo_sentinel_coordinates.py            # count only
    python3 repair_photo_sentinel_coordinates.py --apply    # delete and verify

Exit codes: 0 verified (or nothing to do), 2 store unreachable or refused,
3 verification failed (residue or photoDate changed).
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import sys
import urllib.error
import urllib.request

PWG = "https://schema.ostler.ai/ontology#"
SENTINEL_AT_OR_BELOW = -179
DEFAULT_STORE_URL = "http://127.0.0.1:7878"
_STORE_CURL_CONF = os.environ.get(
    "OSTLER_STORE_CURL_CONF",
    os.path.join(os.path.expanduser("~"), ".ostler", "secrets", "store-curl.conf"),
)
# No proxy for a loopback store. See migrate_graph_namespace.py: an inherited
# HTTP_PROXY answered for the store and read as an absent Oxigraph.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

PREFIX = f"PREFIX pwg: <{PWG}>\n"

# Both coordinate predicates, the sentinel test, over default and named graphs.
_SENT_BIND = (
    f"{{ ?e pwg:photoLatitude ?v . FILTER(?v <= {SENTINEL_AT_OR_BELOW}) }} "
    f"UNION {{ ?e pwg:photoLongitude ?v . FILTER(?v <= {SENTINEL_AT_OR_BELOW}) }}"
)

Q_SENTINEL_EVENTS = (
    PREFIX + "SELECT (COUNT(DISTINCT ?e) AS ?n) WHERE {\n"
    f"  {{ {_SENT_BIND} }}\n"
    f"  UNION {{ GRAPH ?g {{ {_SENT_BIND} }} }}\n"
    "}"
)
Q_DATE_TRIPLES = (
    PREFIX + "SELECT (COUNT(*) AS ?n) WHERE {\n"
    "  { ?e pwg:photoDate ?d }\n"
    "  UNION { GRAPH ?g { ?e pwg:photoDate ?d } }\n"
    "}"
)
Q_SENTINEL_COORD_TRIPLES = (
    PREFIX + "SELECT (COUNT(*) AS ?n) WHERE {\n"
    f"  {{ ?e ?p ?v . FILTER(?p IN (pwg:photoLatitude, pwg:photoLongitude) && ?v <= {SENTINEL_AT_OR_BELOW}) }}\n"
    f"  UNION {{ GRAPH ?g {{ ?e ?p ?v . FILTER(?p IN (pwg:photoLatitude, pwg:photoLongitude) && ?v <= {SENTINEL_AT_OR_BELOW}) }} }}\n"
    "}"
)
# Coordinate triples on CLEAN events, i.e. events with no sentinel coordinate.
# Those must be identical before and after. A valid longitude on a sentinel event
# is deleted with it by design (both coordinates of such an event go), so it is
# deliberately not part of this invariant.
_SENT_EXISTS = (
    f"{{ ?e pwg:photoLatitude ?s . FILTER(?s <= {SENTINEL_AT_OR_BELOW}) }} "
    f"UNION {{ ?e pwg:photoLongitude ?s . FILTER(?s <= {SENTINEL_AT_OR_BELOW}) }}"
)
Q_CLEAN_COORD_TRIPLES = (
    PREFIX + "SELECT (COUNT(*) AS ?n) WHERE {\n"
    "  { ?e ?p ?v . FILTER(?p IN (pwg:photoLatitude, pwg:photoLongitude))\n"
    f"    FILTER NOT EXISTS {{ {_SENT_EXISTS} }} }}\n"
    "  UNION { GRAPH ?g { ?e ?p ?v . FILTER(?p IN (pwg:photoLatitude, pwg:photoLongitude))\n"
    f"    FILTER NOT EXISTS {{ GRAPH ?g {{ {_SENT_EXISTS} }} }} }} }}\n"
    "}"
)

# Delete both coordinates of every event where either is a sentinel.
# OPTIONAL binds whichever of the pair exists; the template removes only bound ones.
_DELETE_BODY = (
    "  { ?e pwg:photoLatitude ?x } UNION { ?e pwg:photoLongitude ?x }\n"
    "  OPTIONAL { ?e pwg:photoLatitude ?lat }\n"
    "  OPTIONAL { ?e pwg:photoLongitude ?lng }\n"
    f"  FILTER ( (BOUND(?lat) && ?lat <= {SENTINEL_AT_OR_BELOW})"
    f" || (BOUND(?lng) && ?lng <= {SENTINEL_AT_OR_BELOW}) )\n"
)
U_DELETE = (
    PREFIX
    + "DELETE { ?e pwg:photoLatitude ?lat . ?e pwg:photoLongitude ?lng . }\n"
    + "WHERE {\n" + _DELETE_BODY + "}\n;\n"
    + "DELETE { GRAPH ?g { ?e pwg:photoLatitude ?lat . ?e pwg:photoLongitude ?lng . } }\n"
    + "WHERE { GRAPH ?g {\n" + _DELETE_BODY + "} }"
)


def _count(value) -> int:
    return int(value)


class HttpStore:
    """Oxigraph over loopback HTTP, with the store's bearer header if one is configured."""

    def __init__(self, base_url: str = DEFAULT_STORE_URL, conf_path: str = _STORE_CURL_CONF):
        self.base_url = base_url.rstrip("/")
        self.headers = self._load_headers(conf_path)

    @staticmethod
    def _load_headers(path: str) -> dict:
        if not os.path.exists(path):
            return {}
        hdrs = {}
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = re.match(r'^\s*header\s*=\s*"(.*)"\s*$', line)
                if m and ":" in m.group(1):
                    k, v = m.group(1).split(":", 1)
                    hdrs[k.strip()] = v.strip()
        return hdrs

    def _post(self, path: str, body: str, ctype: str, accept: str) -> str:
        h = {"Content-Type": ctype, "Accept": accept}
        h.update(self.headers)
        req = urllib.request.Request(self.base_url + path, data=body.encode("utf-8"), headers=h)
        with _OPENER.open(req, timeout=120) as r:
            return r.read().decode("utf-8", "replace")

    def select_int(self, query: str) -> int:
        out = self._post("/query", query, "application/sparql-query", "application/sparql-results+json")
        bindings = json.loads(out)["results"]["bindings"]
        return _count(bindings[0]["n"]["value"]) if bindings else 0

    def update(self, stmt: str) -> None:
        self._post("/update", stmt, "application/sparql-update", "*/*")


def measure(store) -> dict:
    return {
        "sentinel_events": store.select_int(Q_SENTINEL_EVENTS),
        "sentinel_coord_triples": store.select_int(Q_SENTINEL_COORD_TRIPLES),
        "clean_coord_triples": store.select_int(Q_CLEAN_COORD_TRIPLES),
        "date_triples": store.select_int(Q_DATE_TRIPLES),
    }


def repair(store, apply: bool) -> tuple[int, dict]:
    """Return (exit_code, report). report holds counts only."""
    before = measure(store)
    report = {"before": before}
    if before["sentinel_events"] == 0 and before["sentinel_coord_triples"] == 0:
        report["action"] = "nothing_to_do"
        return 0, report
    if not apply:
        report["action"] = "dry_run"
        return 0, report
    store.update(U_DELETE)
    after = measure(store)
    report["after"] = after
    if after["sentinel_events"] != 0 or after["sentinel_coord_triples"] != 0:
        report["action"] = "verify_failed_residue"
        return 3, report
    if after["date_triples"] != before["date_triples"]:
        report["action"] = "verify_failed_dates_changed"
        return 3, report
    if after["clean_coord_triples"] != before["clean_coord_triples"]:
        report["action"] = "verify_failed_clean_coords_changed"
        return 3, report
    report["action"] = "deleted_and_verified"
    return 0, report


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--store-url", default=DEFAULT_STORE_URL)
    ap.add_argument("--marker", default=None, help="written only on a verified run")
    args = ap.parse_args(argv)
    try:
        store = HttpStore(args.store_url)
        code, report = repair(store, apply=args.apply)
    except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
        print(json.dumps({"action": "store_unreachable", "error_type": type(e).__name__}))
        return 2
    print(json.dumps(report, sort_keys=True))
    if code == 0 and args.apply and args.marker and report.get("action") in ("deleted_and_verified", "nothing_to_do"):
        os.makedirs(os.path.dirname(args.marker), exist_ok=True)
        with open(args.marker, "w", encoding="utf-8") as fh:
            fh.write("ran_at\t%s\n" % datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
            fh.write(json.dumps(report, sort_keys=True) + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
