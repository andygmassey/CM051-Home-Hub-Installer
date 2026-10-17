#!/usr/bin/env python3
"""Book detail reaches the graph from the VENDORED CM019 enricher.

OpenLibrary enrichment fetched publish year and page count, and
`EnrichmentResult.to_turtle` never serialised book_metadata, so the wiki's
Books table could not show a year. Upstream CM019 #411 (7fd66daf) writes
pwg:publishYear and pwg:pageCount; cover_url stays out of the graph. This
checks the copy that SHIPS (vendor/cm019_preferences).

It drives the REAL write path: `EnrichmentService._store_enrichment` builds the
SPARQL INSERT DATA and posts it. Only the socket is replaced (an httpx
MockTransport that captures the body); the captured update is executed by
pyoxigraph, the engine the Hub runs, and the graph is compared with the shared
CM019/CM044 contract fixture tests/fixtures/book_enrichment_contract.json
(byte-identical copies live in CM019 and CM044; CM044's reader is tested
against the same triples). Every title and name in it is synthetic.

  arm 1  each fixture record: graph written == the fixture's turtle.
  arm 2  no cover URL reaches the graph (a remote URL; the wiki has no
         consent-gated local copy to show).
  arm 3  RED CONTROL: the same checks against a copy of the vendored module
         with the book block disabled must FAIL, or this test proves nothing.

Exit: 0 pass, 1 real failure, 2 cannot-run.
"""

import asyncio
import importlib.util
import json
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace

REPO = Path(__file__).resolve().parent.parent
ENRICH = REPO / "vendor" / "cm019_preferences" / "services" / "enrich"
MODEL = ENRICH / "src" / "models" / "enrichment.py"
FIXTURE = REPO / "tests" / "fixtures" / "book_enrichment_contract.json"

for p in (MODEL, FIXTURE):
    if not p.is_file():
        print(f"CANNOT RUN: missing {p}", file=sys.stderr)
        sys.exit(2)
try:
    import httpx
    import pyoxigraph as ox
except ImportError as exc:
    print(f"CANNOT RUN: {exc} (pip install pyoxigraph httpx)", file=sys.stderr)
    sys.exit(2)

sys.path.insert(0, str(ENRICH))
try:
    from src import enricher as enricher_mod
except Exception as exc:  # noqa: BLE001
    print(f"CANNOT RUN: vendored enricher does not import: {exc!r}", file=sys.stderr)
    sys.exit(2)

CONTRACT = json.loads(FIXTURE.read_text(encoding="utf-8"))
NS = CONTRACT["namespace"]
PREFIXES = (
    f"@prefix pwg: <{NS}> .\n"
    "@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .\n"
    "@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .\n"
)


def _result(models, rec):
    inp = rec["input"]
    return models.EnrichmentResult(
        preference_id=rec["preference_id"],
        original_subject=inp["matched_title"],
        source=models.EnrichmentSource.OPEN_LIBRARY,
        confidence=inp["confidence"],
        enriched_at=datetime.fromisoformat(CONTRACT["enriched_at"]),
        match_type=models.MatchType(inp["match_type"]),
        matched_title=inp["matched_title"],
        topics=[models.TopicResult(name=n, normalized=k) for n, k in inp.get("topics", [])],
        entities=[models.EntityResult(name=n, entity_type=t) for n, t in inp["entities"]],
        book_metadata=models.BookMetadata(**inp["book_metadata"]),
    )


def _store_via_real_write_path(result) -> str:
    """Run the vendored _store_enrichment; return the SPARQL update it posted."""
    captured = []

    def handler(request):
        captured.append(request.content.decode("utf-8"))
        return httpx.Response(204)

    real = httpx.AsyncClient

    class Captured(real):
        def __init__(self, *a, **k):
            k["transport"] = httpx.MockTransport(handler)
            super().__init__(*a, **k)

    enricher_mod.httpx.AsyncClient = Captured
    try:
        ok = asyncio.run(enricher_mod.EnrichmentService._store_enrichment(
            SimpleNamespace(_enriched_ids=set()), result))
    finally:
        enricher_mod.httpx.AsyncClient = real
    if not ok or len(captured) != 1:
        raise AssertionError(f"_store_enrichment ok={ok} posts={len(captured)}")
    return captured[0]


def _triples(store):
    return {(q.subject, q.predicate, q.object) for q in store.quads_for_pattern(None, None, None)}


def check(models) -> list:
    """Return a list of failure strings (empty == pass)."""
    fails = []
    for rec in CONTRACT["records"]:
        title = rec["input"]["matched_title"]
        written = ox.Store()
        try:
            written.update(_store_via_real_write_path(_result(models, rec)))
        except Exception as exc:  # noqa: BLE001
            fails.append(f"{title}: write path failed: {exc!r}")
            continue
        shared = ox.Store()
        shared.load(input=(PREFIXES + "\n".join(rec["turtle"])).encode("utf-8"),
                    format=ox.RdfFormat.TURTLE)
        a, b = _triples(written), _triples(shared)
        if a != b:
            fails.append(f"{title}: graph != contract; missing {len(b - a)}, extra {len(a - b)}")
        cover = rec["input"]["book_metadata"].get("cover_url") or ""
        if cover and any(cover in str(t) for t in a):
            fails.append(f"{title}: the remote cover URL reached the graph")
    return fails


def main() -> int:
    from src.models import enrichment as models

    examined = len(CONTRACT["records"])
    fails = check(models)
    if fails:
        for f in fails:
            print(f"FAIL: {f}")
        return 1
    print(f"arm 1+2 PASS: {examined} of {examined} contract records written exactly, no cover URL in the graph")

    # arm 3: red control on a mutant copy of the vendored module.
    src = MODEL.read_text(encoding="utf-8")
    needle = "        if book is not None:\n"
    if src.count(needle) != 1:
        print("CANNOT RUN: red control could not locate the book block in the vendored module", file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory() as td:
        mpath = Path(td) / "enrichment_mutant.py"
        mpath.write_text(src.replace(needle, "        if False:\n"), encoding="utf-8")
        spec = importlib.util.spec_from_file_location("enrichment_mutant", mpath)
        mutant = importlib.util.module_from_spec(spec)
        sys.modules["enrichment_mutant"] = mutant
        spec.loader.exec_module(mutant)
        mfails = check(mutant)
    if not mfails:
        print("FAIL: red control stayed green; the check cannot see a dropped book block")
        return 1
    print(f"arm 3 PASS: red control caught the disabled book block ({len(mfails)} failure(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
