#!/usr/bin/env python3
"""The vendored enrich tree refuses public look-ups without a recorded yes.

Upstream: personal-world-graph #421 (consent gate), merged here with CM051's
own file-only backstop in cli.py (walk #28) kept.

  arm 1  the recurring agent's shape: OSTLER_CONSENT_ENRICHMENT_DECISION NOT
         exported, answer only in ${OSTLER_DIR}/config/.env. Exactly
         "accepted" (one pair of double quotes allowed) is yes; declined,
         missing, garbage, " accepted", "Accepted", "ACCEPTED" are no.
  arm 2  every EnrichmentService entry point, called directly with no CLI and
         no consent, makes 0 requests at the httpx transport and 0
         socket.connect calls. CONTROL: with consent the same call does reach
         the wire, so the counters are live.
  arm 3  the name clash: cli.py keeps its zero-argument
         require_public_lookup_consent() and the upstream one-argument gate is
         reachable under another name (an import that the local def shadowed
         would raise TypeError on every `enrich` run).
  arm 4  `enrich --all` as the agent runs it (env unset, file says accepted)
         is not refused; file says declined, nothing is sent.
  arm 5  the topic skip-check looks in the default graph, where POST /store
         writes land (real engine, pyoxigraph).

Exit: 0 pass, 1 real failure, 2 cannot-run.
"""

import asyncio
import inspect
import os
import socket
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ENRICH = REPO / "vendor" / "cm019_preferences" / "services" / "enrich"
KEY = "OSTLER_CONSENT_ENRICHMENT_DECISION"

for var in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
    os.environ.pop(var, None)
os.environ["NO_PROXY"] = "127.0.0.1,localhost"
os.environ.pop(KEY, None)

sys.path.insert(0, str(ENRICH))
try:
    import httpx
    import pyoxigraph
    from click.testing import CliRunner
    from src import cli as cli_module
    from src import enricher as enricher_module
except Exception as exc:  # noqa: BLE001
    print(f"CANNOT RUN: vendored enrich tree does not import: {exc!r}", file=sys.stderr)
    sys.exit(2)
try:
    from src.consent import public_lookup_allowed
except ImportError as exc:
    # The tree imports; the consent module is what is missing. A real failure.
    print(f"FAIL  the vendored tree has no src/consent.py: {exc!r}", file=sys.stderr)
    sys.exit(1)

FAILS = []


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {name}{(' -- ' + detail) if detail and not ok else ''}")
    if not ok:
        FAILS.append(name)


TMP = Path(tempfile.mkdtemp(prefix="cm019-consent-"))
os.environ["OSTLER_DIR"] = str(TMP)
(TMP / "config").mkdir()
ENVFILE = TMP / "config" / ".env"


def write_env(text):
    if text is None:
        ENVFILE.unlink(missing_ok=True)
    elif isinstance(text, bytes):
        ENVFILE.write_bytes(text)
    else:
        ENVFILE.write_text(text, encoding="utf-8")


# ---------------------------------------------------------------- arm 1
CASES = [
    (f"{KEY}=accepted\n", True),
    (f'{KEY}="accepted"\n', True),
    (f"A=1\n{KEY}=declined\n{KEY}=accepted\n", True),
    (f"{KEY}=accepted\n{KEY}=declined\n", False),
    (f"{KEY}=declined\n", False),
    (f"{KEY}=\n", False),
    (f"{KEY}=garbage\n", False),
    (f"{KEY}=Accepted\n", False),
    (f"{KEY}= accepted\n", False),
    (f"{KEY}=ACCEPTED\n", False),
    (b"\xff\xfe\x00" + KEY.encode() + b"=accepted\n", False),
    (None, False),
]
for content, want in CASES:
    write_env(content)
    got = public_lookup_allowed()
    check(f"arm1 file {content!r} -> {want}", got is want, f"got {got}")

# ---------------------------------------------------------------- arm 2
count = {"http": 0, "socket": 0}


def handler(request):
    count["http"] += 1
    return httpx.Response(200, json={
        "result": {"points": [], "count": 0, "collections": []},
        "results": {"bindings": []}, "search": [], "docs": [],
    })


_RealClient = httpx.AsyncClient


class Counting(_RealClient):
    def __init__(self, *a, **kw):
        kw["transport"] = httpx.MockTransport(handler)
        super().__init__(*a, **kw)


httpx.AsyncClient = Counting


def _deny(self, *a, **kw):
    count["socket"] += 1
    raise OSError("socket.connect blocked by test")


socket.socket.connect = _deny


async def _no_sleep(_):
    return None


enricher_module.asyncio.sleep = _no_sleep

PREF = {"id": "p1", "category": "book", "subject": "Example Book", "strength": 0.9}
ENTRY = {
    "enrich_preference": lambda s: s.enrich_preference(PREF),
    "enrich_batch": lambda s: s.enrich_batch([PREF], enricher_module.EnrichmentStats()),
    "enrich_all": lambda s: s.enrich_all(limit=5),
    "enrich_categories": lambda s: s.enrich_categories(["book"], limit_per_category=5),
    "enrich_parallel": lambda s: s.enrich_parallel([{"category": "book", "limit": 5}]),
}
public = {
    n for n in dir(enricher_module.EnrichmentService)
    if n.startswith("enrich_") and callable(getattr(enricher_module.EnrichmentService, n))
}
check("arm2 every public enrich_* entry point is covered", public == set(ENTRY),
      f"uncovered: {sorted(public - set(ENTRY))}")


def call(name):
    async def go():
        svc = enricher_module.EnrichmentService()
        try:
            return await ENTRY[name](svc)
        finally:
            await svc.close()
    asyncio.run(go())


for decision in (None, f"{KEY}=declined\n", f"{KEY}=Accepted\n"):
    write_env(decision)
    for name in sorted(ENTRY):
        count.update(http=0, socket=0)
        call(name)
        check(f"arm2 {name} without consent ({decision!r}) makes 0 requests",
              count == {"http": 0, "socket": 0}, str(count))

write_env(f"{KEY}=accepted\n")
count.update(http=0, socket=0)
call("enrich_all")
check("arm2 CONTROL: with consent the same call reaches the wire",
      count["http"] + count["socket"] > 0, str(count))

# ---------------------------------------------------------------- arm 3
check("arm3 cli keeps its zero-argument require_public_lookup_consent",
      len(inspect.signature(cli_module.require_public_lookup_consent).parameters) == 0)
check("arm3 upstream gate reachable under another name",
      len(inspect.signature(cli_module.require_enrichment_consent).parameters) == 1)

# ---------------------------------------------------------------- arm 4
write_env(f'{KEY}="accepted"\n')
count.update(http=0, socket=0)
res = CliRunner().invoke(cli_module.cli, ["enrich", "--all", "--limit", "1"])
check("arm4 agent shape (env unset, file accepted): not refused",
      "No request was made" not in res.output and "Public look-ups" not in res.output
      and not isinstance(res.exception, TypeError),
      f"exit={res.exit_code} exc={res.exception!r} out={res.output[:200]!r}")

write_env(f"{KEY}=declined\n")
count.update(http=0, socket=0)
res = CliRunner().invoke(cli_module.cli, ["enrich", "--all", "--limit", "1"])
check("arm4 file declined: nothing sent", count == {"http": 0, "socket": 0}, str(count))

os.environ[KEY] = "accepted"
write_env(f"{KEY}=declined\n")
count.update(http=0, socket=0)
CliRunner().invoke(cli_module.cli, ["enrich", "--all", "--limit", "1"])
check("arm4 env says accepted but file says declined: nothing sent",
      count == {"http": 0, "socket": 0}, str(count))
os.environ.pop(KEY, None)

# ---------------------------------------------------------------- arm 5
PWG = "https://schema.ostler.ai/enrichment/ontology#"
RDFS = "http://www.w3.org/2000/01/rdf-schema#"
for qname, prop in (("_LOCAL_PENDING_TOPICS_QUERY", "normalizedLabel"),
                    ("_WIKIDATA_PENDING_TOPICS_QUERY", "wikidataId")):
    query = getattr(enricher_module, qname, None)
    if query is None:
        check(f"arm5 {qname} exists", False)
        continue
    store = pyoxigraph.Store()
    g = pyoxigraph.NamedNode("http://example.com/graph/prefs")
    for i in (1, 2):
        t = pyoxigraph.NamedNode(f"http://example.com/topic/{i}")
        p = pyoxigraph.NamedNode(f"http://example.com/pref/{i}")
        store.add(pyoxigraph.Quad(p, pyoxigraph.NamedNode(PWG + "hasTopic"), t, g))
        store.add(pyoxigraph.Quad(t, pyoxigraph.NamedNode(RDFS + "label"),
                                  pyoxigraph.Literal(f"Topic {i}"), g))
    before = len(list(store.query(query)))
    store.add(pyoxigraph.Quad(pyoxigraph.NamedNode("http://example.com/topic/1"),
                              pyoxigraph.NamedNode(PWG + prop), pyoxigraph.Literal("x")))
    after = len(list(store.query(query)))
    check(f"arm5 {prop}: default-graph write is skipped next run (control {before}==2)",
          before == 2 and after == 1, f"before={before} after={after}")

if FAILS:
    print(f"\n{len(FAILS)} FAILED", file=sys.stderr)
    sys.exit(1)
print("\nall arms passed")
