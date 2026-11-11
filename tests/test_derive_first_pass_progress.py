#!/usr/bin/env python3
"""The derive runner says how far a pass has got, while the pass runs.

A first pass on a fresh box takes tens of minutes. Before this the status file
said nothing until the whole pass ended, so "What you like" looked dead for 46
minutes. The runner now times each reader and rewrites the status file as each
one finishes. Drives the REAL derive_runner.run() against the same synthetic
pyoxigraph fixture as test_derive_engine_writes_a_derived_preference.py.

  arm 1  a finished pass records one timing per reader (name, seconds, items,
         ok) and progress readers_done == readers_total.
  arm 2  INCREMENTAL: a reader that starts after an earlier one finished sees
         the status file already saying so (outcome in_progress, readers_done
         >= 1). Read from inside the store, not from the return value.
  arm 3  a failed reader is recorded ok=false and the pass is not written.
  arm 4  the Doctor reads an in_progress record as "still learning" with the
         count, not "unreadable" (the runner's own file, not a copy of it).
  arm 5  RED CONTROL: no preference value, label or title is in the file.

Exit: 0 pass, 1 real failure, 2 cannot-run. Synthetic only.
"""

from __future__ import annotations

import json
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TREE = REPO / "vendor" / "cm019_preferences"
SRC = TREE / "services" / "enrich" / "src"
COMMON = TREE / "services" / "common"
DOCTOR = REPO / "vendor" / "doctor" / "agent"
RUNNER = SRC / "derive_runner.py"

for p in (RUNNER, SRC / "derive" / "writer.py", COMMON / "strength.py",
          TREE / "ontology" / "shacl" / "derived-preference-shapes.ttl",
          DOCTOR / "derived_preferences_status.py"):
    if not p.is_file():
        print(f"CANNOT-RUN: {p.relative_to(REPO)} is missing")
        sys.exit(2)

try:
    import pyoxigraph  # noqa: F401
    import pyshacl  # noqa: F401
    import rdflib  # noqa: F401
    import yaml  # noqa: F401
except ImportError as exc:
    print(f"CANNOT-RUN: {exc}. pip install pyoxigraph rdflib pyshacl pyyaml")
    sys.exit(2)

sys.path.insert(0, str(COMMON))
sys.path.insert(0, str(SRC))
sys.path.insert(0, str(DOCTOR))

import derive_runner  # noqa: E402
from derive.model import DERIVED_GRAPH, ENRICH_NS, RDFS_NS  # noqa: E402
from derive.shacl import PyShaclValidator  # noqa: E402
from pyoxigraph import RdfFormat, Store  # noqa: E402

NOW = datetime(2026, 10, 17, tzinfo=timezone.utc)
GENRE = "synthetic-genre-alpha"
DIRECTOR = "synthetic-director-one"

PASS = 0
FAIL = 0


def check(cond: bool, msg: str) -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS {msg}")
    else:
        FAIL += 1
        print(f"  FAIL {msg}")


def _bindings(results) -> list:
    out = []
    for sol in results:
        row = {}
        for var in results.variables:
            term = sol[var]
            if term is not None:
                row[var.value] = {"value": term.value}
        out.append(row)
    return out


class OxigraphStore:
    def __init__(self, store: Store):
        self.s = store

    def update(self, sparql_update: str) -> None:
        self.s.update(sparql_update)

    def _select(self, query: str) -> list:
        return _bindings(self.s.query(query))


class Gateway:
    """StoreGateway over synthetic points. ``on_call`` runs before every read,
    so an arm can look at the status file mid-pass."""

    def __init__(self, store: OxigraphStore, points: list, on_call=None,
                 fail_scroll: bool = False):
        self.store, self.points = store, points
        self.on_call, self.fail_scroll = on_call, fail_scroll

    def sparql(self, query: str) -> list:
        if self.on_call:
            self.on_call()
        return self.store._select(query)

    def scroll(self, categories, fields) -> list:
        if self.on_call:
            self.on_call()
        if self.fail_scroll:
            raise ConnectionError("qdrant unreachable (synthetic)")
        return [p for p in self.points if p["payload"].get("category") in categories]


class Mirror:
    def replace_all(self, points):
        self.points = list(points)


def seed(store: Store, n_films: int) -> list:
    ttl = [f"@prefix enr: <{ENRICH_NS}> .", f"@prefix rdfs: <{RDFS_NS}> .",
           "<urn:test:genre> rdfs:label \"%s\" ." % GENRE,
           "<urn:test:director> rdfs:label \"%s\" ; enr:entityType \"director\" ." % DIRECTOR]
    points = []
    for i in range(n_films):
        pid = f"00000000-0000-0000-0000-00000000000{i}"
        subj = f"<urn:ostler:preference:{pid}>"
        ttl.append(f"{subj} enr:hasGenre <urn:test:genre> ; enr:enrichmentConfidence 0.9 .")
        if i < 2:
            ttl.append(f"{subj} enr:hasEntity <urn:test:director> .")
        points.append({"id": pid, "payload": {
            "category": "movie", "subject": f"Synthetic Film {i}", "source": "netflix",
            "strength": 0.8, "observed_at": "2026-09-01T00:00:00Z"}})
    store.load("\n".join(ttl).encode(), format=RdfFormat.TURTLE)
    return points


def main() -> int:
    tmp = Path(tempfile.mkdtemp(prefix="derive-progress-"))
    status_path = tmp / "state" / "derived-preferences.json"

    print("arm 1: a finished pass records one timing per reader")
    raw = Store()
    st = OxigraphStore(raw)
    points = seed(raw, 3)
    rc = derive_runner.run("synthetic_owner", Gateway(st, points), st,
                           PyShaclValidator(), Mirror(), status_path, now=NOW)
    check(rc == 0, f"runner exit 0 (got {rc})")
    s = json.loads(status_path.read_text())
    timings = s.get("reader_timings") or []
    total = s.get("readers_total")
    check(isinstance(total, int) and total > 0 and len(timings) == total,
          f"{len(timings)} reader_timings for {total} readers")
    check(all({"name", "seconds", "items", "ok"} <= set(t) for t in timings),
          "each timing carries name, seconds, items, ok")
    prog = s.get("progress") or {}
    check(prog.get("readers_done") == total and prog.get("readers_total") == total,
          f"progress readers_done={prog.get('readers_done')} of {total}")
    check(s.get("outcome") == "written", f"outcome={s.get('outcome')} (want written)")

    print("arm 2: a later reader sees the earlier one's progress already on disk")
    seen = []

    def look():
        if status_path.exists():
            rec = json.loads(status_path.read_text())
            seen.append((rec.get("outcome"), (rec.get("progress") or {}).get("readers_done")))

    raw2 = Store()
    st2 = OxigraphStore(raw2)
    points2 = seed(raw2, 3)
    derive_runner.run("synthetic_owner", Gateway(st2, points2, on_call=look), st2,
                      PyShaclValidator(), Mirror(), tmp / "arm2" / "d.json", now=NOW)
    mid = [d for (o, d) in seen if o == "in_progress" and isinstance(d, int) and d >= 1]
    check(bool(mid), f"a read began with readers_done >= 1 in progress (seen {seen[:6]})")

    print("arm 3: a failed reader is recorded ok=false and nothing is written")
    raw3 = Store()
    st3 = OxigraphStore(raw3)
    points3 = seed(raw3, 3)
    rc = derive_runner.run("synthetic_owner", Gateway(st3, points3, fail_scroll=True), st3,
                           PyShaclValidator(), Mirror(), tmp / "arm3" / "d.json", now=NOW)
    s3 = json.loads((tmp / "arm3" / "d.json").read_text())
    check(rc == 1 and s3.get("outcome") == "not_written", f"rc={rc} outcome={s3.get('outcome')}")
    check(any(not t.get("ok") for t in s3.get("reader_timings", [])),
          "the failed reader's timing says ok=false")

    print("arm 4: the Doctor reads an in-progress record as still learning")
    import derived_preferences_status as dps  # noqa: E402
    inprog = tmp / "arm4" / "derived-preferences.json"
    inprog.parent.mkdir(parents=True)
    inprog.write_text(json.dumps({"schema": 1, "outcome": "in_progress",
                                  "progress": {"readers_done": 3, "readers_total": 8,
                                               "items_so_far": 40}}))
    orig = dps.status_path
    dps.status_path = lambda: inprog
    try:
        row = dps.read_derived_preferences_status()
    finally:
        dps.status_path = orig
    check(row.get("status") == "in_progress",
          f"Doctor status={row.get('status')} (want in_progress, not unreadable)")
    check("3 of 8" in str(row.get("reason")), f"reason says how far: {row.get('reason')!r}")

    print("arm 5: RED CONTROL -- the progress file holds no preference value or title")
    blob = status_path.read_text()
    check(GENRE not in blob and DIRECTOR not in blob and "Synthetic Film" not in blob,
          "no label, title or subject in the status file")

    print(f"\n{PASS} passed, {FAIL} failed")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
