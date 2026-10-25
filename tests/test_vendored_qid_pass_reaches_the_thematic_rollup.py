#!/usr/bin/env python3
"""T0i/T0j on the VENDORED tree: the shipped enrich command fills topic QIDs and
broader concepts, and the shipped derive runner turns them into a broad theme.

CM051 runs exactly this, every 1800 s, from the ostler-enrich-tick LaunchAgent
(install.sh _install_enrichment_agent) and from ostler-import:

    cd $CM019_DIR && python -m services.enrich.src.cli enrich --all \
        --budget-seconds N -u USER

and the com.ostler.derive-preferences agent runs derive_runner. This test runs
both FROM vendor/cm019_preferences: the CLI by module path (runpy, same name as
install.sh uses), then derive_runner.run() with the real readers, Aggregator,
pyshacl gate and writer over a pyoxigraph store (the engine the Hub runs, no
union default graph). Qdrant is a list of points behind points/points-scroll.
Every non-local host is RECORDED, so "never sent" is an observation. Wikidata is
a fake. Synthetic data only.

  arm 1  CONTROL: before the CLI runs, derive writes no theme.concept node and
         the thematic reader reports degraded:no_topic_qids.
  arm 2  after the CLI: QIDs for the 3 admitted topics, broader edges in the
         hierarchy graph, ONE "QID pass: ok" line, and derive_runner writes a
         theme.concept node "social science" whose derivedFrom is exactly
         those 3 preferences.
  arm 3  GATES on the same run: a sensitive label (P9), a minor's topic (P10,
         extra.about_minor), an L3 topic and a never_read-category (dietary)
         topic are never sent, never get a QID, are counted by reason and not
         named in the log, and are not evidence of the theme.
  arm 4  never_read alone: 0 external requests.
  arm 5  declined consent: 0 external requests, no QID.
  arm 6  P10 PRODUCER: the vendored minors registry stamps extra.about_minor on
         a ParsedPreference naming a flagged person, the payload carries it, and
         the vendored ingest pipeline calls the stamp before it writes.

Exit: 0 pass, 1 real failure, 2 cannot-run.
"""

from __future__ import annotations

import asyncio
import io
import json
import os
import runpy
import sys
import tempfile
from contextlib import redirect_stderr
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import parse_qs, urlparse

REPO = Path(__file__).resolve().parent.parent
TREE = REPO / "vendor" / "cm019_preferences"
SRC = TREE / "services" / "enrich" / "src"
COMMON = TREE / "services" / "common"

for p in (SRC / "cli.py", SRC / "derive_runner.py", SRC / "derive" / "thematic.py",
          SRC / "derive" / "sensitive.py", COMMON / "recency.py",
          TREE / "services" / "ingest" / "src" / "minors.py"):
    if not p.is_file():
        print(f"CANNOT-RUN: {p.relative_to(REPO)} is missing")
        sys.exit(2)
try:
    import httpx
    import pyoxigraph
    import pyshacl  # noqa: F401
    import click  # noqa: F401
    import yaml  # noqa: F401
except ImportError as exc:
    print(f"CANNOT-RUN: {exc}. pip install -r vendor/cm019_preferences/requirements.txt pyoxigraph")
    sys.exit(2)

TMP = Path(tempfile.mkdtemp(prefix="qid-pass-e2e-"))
os.environ["HOME"] = str(TMP)
os.environ["OSTLER_DIR"] = str(TMP / "ostler")
os.environ["OSTLER_MINORS_FILE"] = str(TMP / "no-minors.json")
os.environ["OSTLER_CONVERSATIONS_DIR"] = str(TMP / "Conversations")
os.environ["OSTLER_STATED_MODEL_CACHE"] = str(TMP / "verdicts.json")
for k in ("OXIGRAPH_HOST", "QDRANT_HOST"):
    os.environ[k] = "localhost"
for k in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy",
          "OSTLER_CONSENT_ENRICHMENT_DECISION"):
    os.environ.pop(k, None)

sys.path.insert(0, str(COMMON))
sys.path.insert(0, str(SRC))
sys.path.insert(0, str(TREE))

import derive_runner  # noqa: E402
from derive.model import DERIVED_GRAPH, ENRICH_NS, PREF_URN_PREFIX, PWG_NS, RDFS_NS  # noqa: E402
from derive.shacl import PyShaclValidator  # noqa: E402
from derive.thematic import HIERARCHY_GRAPH, WD_ENTITY  # noqa: E402

N, L = pyoxigraph.NamedNode, pyoxigraph.Literal
USER = "owner-test"
NOW = datetime(2026, 10, 24, tzinfo=timezone.utc)
SOCIAL_SCIENCE = "Q34749"
QIDS = {"psychology": "Q9418", "economics": "Q8134", "sociology": "Q21201",
        "diabetes": "Q12206", "anthropology": "Q23404", "linguistics": "Q8162",
        "cookery": "Q38695"}
ADMITTED = ("psychology", "economics", "sociology")
GATED = ("diabetes", "anthropology", "linguistics", "cookery")
LOCAL = {"localhost", "127.0.0.1", "::1"}

PASS = FAIL = 0


def check(cond, msg):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  ok   {msg}")
    else:
        FAIL += 1
        print(f"  FAIL {msg}")


class Box:
    def __init__(self):
        self.store = pyoxigraph.Store()
        self.points = []
        self.external = []

    def pref(self, pid, label, category="book", privacy="L2", **extra):
        payload = {"category": category, "subject": f"Synthetic item {pid}", "source": "synthetic",
                   "strength": 0.7, "observed_at": "2026-09-01T00:00:00Z", "user_id": USER,
                   "extra": extra}
        if privacy is not None:
            payload["privacy_level"] = privacy
        self.points.append({"id": pid, "payload": payload})
        topic, g = N(f"pwg:topic_{label}"), pyoxigraph.DefaultGraph()
        self.store.add(pyoxigraph.Quad(N(PREF_URN_PREFIX + pid), N(ENRICH_NS + "hasTopic"), topic, g))
        self.store.add(pyoxigraph.Quad(topic, N(RDFS_NS + "label"), L(label), g))

    def qid_of(self, label):
        rows = list(self.store.query(
            f"SELECT ?q WHERE {{ <pwg:topic_{label}> <{ENRICH_NS}wikidataId> ?q }}"))
        return rows[0]["q"].value if rows else None

    def broader_count(self):
        return len(list(self.store.query(
            f"SELECT ?a WHERE {{ GRAPH <{HIERARCHY_GRAPH}> {{ ?a <{ENRICH_NS}broaderConcept> ?b }} }}")))

    def sent_labels(self):
        return sorted(q["search"][0] for _, q in self.external if "search" in q)

    def sent_qids(self):
        out = []
        for _, q in self.external:
            out += q.get("ids", [])
            out += [w for w in QIDS.values() if f"wd:{w} " in q.get("query", [""])[0]]
        return out

    # --- the derive runner's store + gateway ---------------------------------
    def _select(self, query):
        res = self.store.query(query)
        return [{v.value: {"value": s[v].value} for v in res.variables if s[v] is not None}
                for s in res]

    def update(self, q):
        self.store.update(q)

    def count_default_graph_triples(self):
        return int(self._select("SELECT (COUNT(*) AS ?c) WHERE { ?s ?p ?o }")[0]["c"]["value"])

    def count_graph_triples(self, g):
        return int(self._select("SELECT (COUNT(*) AS ?c) WHERE { GRAPH <%s> { ?s ?p ?o } }" % g)[0]["c"]["value"])

    def sparql(self, q):
        return self._select(q)

    def scroll(self, categories, fields):
        return [p for p in self.points if not categories or p["payload"]["category"] in categories]

    # --- HTTP: local stores answered, everything else recorded --------------
    def handle(self, request):
        host, path = request.url.host, request.url.path
        q = parse_qs(urlparse(str(request.url)).query)
        if host not in LOCAL:
            self.external.append((host, q))
            return self.wikidata(host, q)
        if path.endswith("/query"):
            res = self.store.query(request.content.decode("utf-8"))
            return httpx.Response(200, content=res.serialize(format=pyoxigraph.QueryResultsFormat.JSON),
                                  headers={"Content-Type": "application/sparql-results+json"})
        if path.endswith("/store"):
            g = q.get("graph", [None])[0]
            self.store.load(request.content, format=pyoxigraph.RdfFormat.TURTLE,
                            to_graph=N(g) if g else pyoxigraph.DefaultGraph())
            return httpx.Response(204)
        if path.endswith("/update"):
            self.store.update(request.content.decode("utf-8"))
            return httpx.Response(204)
        if path.endswith("/points/scroll"):
            return httpx.Response(200, json={"result": {"points": [], "next_page_offset": None}})
        if path.endswith("/points"):
            ids = {str(i) for i in json.loads(request.content)["ids"]}
            return httpx.Response(200, json={"result": [
                {"id": p["id"], "payload": p["payload"]} for p in self.points if p["id"] in ids]})
        return httpx.Response(200, json={"result": []})

    @staticmethod
    def wikidata(host, q):
        if host == "query.wikidata.org":
            return httpx.Response(200, json={"results": {"bindings": [
                {"broader": {"value": WD_ENTITY + SOCIAL_SCIENCE},
                 "broaderLabel": {"value": "social science"}}]}})
        action = q.get("action", [""])[0]
        if action == "wbsearchentities":
            label = q.get("search", [""])[0]
            qid = QIDS.get(label.lower())
            return httpx.Response(200, json={"search": [{"id": qid, "label": label.lower()}] if qid else []})
        if action == "wbgetentities":
            qid = q.get("ids", [""])[0]
            label = next((k for k, v in QIDS.items() if v == qid), qid)
            return httpx.Response(200, json={"entities": {qid: {"labels": {"en": {"value": label}}, "claims": {}}}})
        return httpx.Response(404, json={})


def seeded():
    b = Box()
    b.pref("101", "psychology")
    b.pref("102", "economics", category="podcast")
    b.pref("103", "sociology")
    b.pref("104", "diabetes")                          # P9
    b.pref("105", "anthropology", about_minor=True)    # P10
    b.pref("106", "linguistics", privacy="L3")         # L3
    b.pref("107", "cookery", category="dietary")       # never_read
    return b


def consent(answer):
    cfg = TMP / "ostler" / "config"
    cfg.mkdir(parents=True, exist_ok=True)
    (cfg / ".env").write_text(f"OSTLER_CONSENT_ENRICHMENT_DECISION={answer}\n", encoding="utf-8")


def run_cli(box, argv=("enrich", "--all", "--budget-seconds", "60", "-u", USER)):
    """python -m services.enrich.src.cli ... from the vendored tree root."""
    real_client, real_sleep, cwd, old_argv = httpx.AsyncClient, asyncio.sleep, os.getcwd(), sys.argv

    class Routed(real_client):
        def __init__(self, *a, **kw):
            kw["transport"] = httpx.MockTransport(box.handle)
            super().__init__(*a, **kw)

    async def no_sleep(_s, *a, **kw):
        await real_sleep(0)

    httpx.AsyncClient, asyncio.sleep = Routed, no_sleep
    for m in [m for m in sys.modules if m.startswith("services.enrich")]:
        del sys.modules[m]
    os.chdir(TREE)
    sys.argv = ["cli", *argv]
    err, code = io.StringIO(), 0
    try:
        with redirect_stderr(err):
            runpy.run_module("services.enrich.src.cli", run_name="__main__", alter_sys=False)
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
    finally:
        httpx.AsyncClient, asyncio.sleep, sys.argv = real_client, real_sleep, old_argv
        os.chdir(cwd)
    text = err.getvalue()
    return code, text, [ln for ln in text.splitlines() if ln.startswith("QID pass:")]


class Mirror:
    def replace_all(self, points):
        self.points = list(points)


def derive(box):
    status = TMP / "state" / f"derived-{len(box.external)}-{os.urandom(3).hex()}.json"
    rc = derive_runner.run(USER, box, box, PyShaclValidator(), Mirror(), status, now=NOW)
    themes = box._select(
        "SELECT ?n ?l WHERE { GRAPH <%s> { ?n a <%sDerivedPreference> ; <%slabel> ?l ; "
        "<%sdimension> \"theme.concept\" } }" % (DERIVED_GRAPH, PWG_NS, RDFS_NS, PWG_NS))
    out = {}
    for t in themes:
        froms = box._select("SELECT ?f WHERE { GRAPH <%s> { <%s> <%sderivedFrom> ?f } }"
                            % (DERIVED_GRAPH, t["n"]["value"], PWG_NS))
        out[t["l"]["value"]] = {f["f"]["value"] for f in froms}
    return rc, out, json.loads(status.read_text())


def main():
    print("arm 1: control, before the shipped enrich command runs")
    consent("accepted")
    box = seeded()
    rc, themes, st = derive(box)
    check(rc == 0 and themes == {}, f"derive_runner exit {rc}, theme.concept nodes {sorted(themes)} (want none)")

    print("arm 2: python -m services.enrich.src.cli enrich --all, then derive_runner")
    code, err, lines = run_cli(box)
    print("    " + (lines[0] if lines else "(no QID pass line)"))
    check(code == 0, f"enrich exit 0 (got {code}){'' if code == 0 else ': ' + err[-800:]}")
    check(len(lines) == 1 and lines[0].startswith("QID pass: ok;"), "exactly one 'QID pass: ok' line")
    for lab in ADMITTED:
        check(box.qid_of(lab) == QIDS[lab], f"{lab} carries QID {QIDS[lab]} in the store")
    check(box.broader_count() >= 3, f"{box.broader_count()} broaderConcept edges in the hierarchy graph")
    rc, themes, st = derive(box)
    print(f"    derive status: outcome={st.get('outcome')} nodes={st.get('nodes_derived')}")
    check(rc == 0, f"derive_runner exit 0 (got {rc}, reason {st.get('reason')!r})")
    check(set(themes) == {"social science"}, f"theme.concept nodes: {sorted(themes)}")
    check(themes.get("social science") == {PREF_URN_PREFIX + i for i in ("101", "102", "103")},
          "the theme's derivedFrom is exactly the 3 admitted preferences")

    print("arm 3: gates on the same run")
    check(box.sent_labels() == sorted(ADMITTED), f"labels sent to Wikidata: {box.sent_labels()}")
    for lab in GATED:
        check(box.qid_of(lab) is None and QIDS[lab] not in box.sent_qids(),
              f"{lab}: no QID stored, no QID sent")
        check(lab not in err, f"{lab} is not named in the log")
    for reason in ("'sensitive': 1", "'minor': 1", "'level_L3': 1", "'never_read_category': 1"):
        check(bool(lines) and reason in lines[0], f"withheld counted as {reason}")

    print("arm 4: a never_read-category item alone sends nothing")
    solo = Box()
    solo.pref("107", "cookery", category="dietary")
    code, err, lines = run_cli(solo)
    check(code == 0 and solo.external == [], f"exit {code}, external requests {len(solo.external)} (want 0)")
    check(bool(lines) and "'never_read_category': 1" in lines[0], "withheld as never_read_category")

    print("arm 5: declined consent sends nothing")
    consent("declined")
    box2 = seeded()
    code, err, lines = run_cli(box2)
    # The vendored CLI stands down on a decline (require_enrichment_consent),
    # before any look-up and before the QID pass.
    check(box2.external == [] and not lines,
          f"exit {code}, external requests {len(box2.external)}, QID pass lines {len(lines)} (want 0, 0)")
    check(all(box2.qid_of(lab) is None for lab in QIDS), "no QID stored")

    print("arm 6: the P10 producer is vendored and called before the write")
    reg = TMP / "minors.json"
    reg.write_text(json.dumps({"version": 1, "minors": [
        {"slug": "jane-doe", "names": ["Jane Doe"], "identifiers": ["+447700900123"]}]}))
    from services.ingest.src.minors import MinorsRegistry
    from services.ingest.src.parsers.base import ParsedPreference
    kid = ParsedPreference(subject="Jane Doe's swimming lesson", category="event", source="synthetic")
    adult = ParsedPreference(subject="Synthetic jazz album", category="music", source="synthetic")
    n = MinorsRegistry.load(reg).stamp([kid, adult])
    check(n == 1 and kid.to_payload(USER)["extra"].get("about_minor") and
          not adult.to_payload(USER)["extra"].get("about_minor"),
          f"registry stamped {n} of 2, the payload carries extra.about_minor on the minor only")
    pipe = (TREE / "services" / "ingest" / "src" / "pipeline.py").read_text()
    i_stamp, i_vec = pipe.find("registry.stamp(preferences)"), pipe.find("texts = [p.embedding_text")
    check(0 < i_stamp < i_vec, "pipeline._process_batch stamps minors before embedding and writing")

    print(f"\n{PASS} passed, {FAIL} failed")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
