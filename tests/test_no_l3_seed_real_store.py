#!/usr/bin/env python3
"""Real-store test for the no_l3 graph seed (scripts/box_walk_probes/lib/no_l3_graph_seed.py).

Run 12 of the 133 L3 proof stopped at the seed, and its teardown was wrong:
  (a) the decision UPDATE passed an already-angle-bracketed IRI (<<urn:...>>): HTTP 400;
  (b) the decision date was date-only but typed xsd:dateTime;
  (c) the teardown removed by stamp and subject, so unstamped conversation, fact, todo
      and mention rows stayed behind.

This test drives the seed's own staging code (run_units, stage_unit) against a REAL
pyoxigraph store (the SPARQL parser the Oxigraph server uses), and checks:
  - every row is accepted, and each decision date is a real xsd:dateTime;
  - the exact teardown returns the store to its pre-seed count, live rows kept;
  - a quad that was on the store BEFORE the seed survives the teardown (exclusion);
  - a live, non-seed topic and mention survive the topic UPDATE's DELETE WHERE;
  - mutants go red: stamp-only teardown, no pre-existence exclusion, double-wrapped
    IRI, date-only dateTime.
Synthetic data only; HOME is redirected to a temp dir.

Run: python3 tests/test_no_l3_seed_real_store.py -v
"""
import importlib.util
import os
import re
import shutil
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

_HOME = tempfile.mkdtemp(prefix="no_l3_seed_home_")
os.environ["HOME"] = _HOME  # before any CM048 import: the vendored modules read config from it

ROOT = Path(__file__).resolve().parents[1]
SEED_SRC = ROOT / "scripts" / "box_walk_probes" / "lib" / "no_l3_graph_seed.py"
DECISION_SRC = ROOT / "vendor" / "cm041" / "meeting_syncer" / "decision_extractor.py"
sys.path[:0] = [str(ROOT / "vendor" / "cm048_pipeline"), str(ROOT / "vendor")]

FIXED_PERSON = "about_persons=[person_uri[1:-1]], status="
MUTANT_PERSON = "about_persons=[person_uri], status="
FIXED_DATE = 'source_uri=meeting, date=FIXTURE_DATE + "T00:00:00Z",'
MUTANT_DATE = "source_uri=meeting, date=FIXTURE_DATE,"

PAYLOAD = {
    "owner": "synthowner", "stamp": "seedtest0001", "person_name": "Synthetic Person",
    "convs": [
        {"id": "ostler-walk-cL2", "level": "L2", "marker": "mkL2", "date": "2026-11-10"},
        {"id": "ostler-walk-cL3", "level": "L3", "marker": "mkL3", "date": "2026-11-10"},
    ],
    "conv_markers": {"L2": "cL2", "L3": "cL3"},
    "topic_markers": {"L2": "tL2", "L3": "tL3"},
    "decision_markers": {"L2": "dL2", "L3": "dL3"},
}
GRAPH = "urn:ostler:user/synthowner"
PWG = "https://schema.ostler.ai/ontology#"
DATE_PRED = PWG + "decisionDate"
LIVE_TOPIC = PWG + "topic_live-topic-plum"
LIVE_MENTION = PWG + "topicmention_live-row"

_DATETIME = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?$")


def _is_datetime_lexical(value):
    """xsd:dateTime needs a time part. datetime.fromisoformat accepts a bare date, so it
    cannot be the check: a date-only value passes it and is the defect itself."""
    return bool(_DATETIME.match(value))


def _stage(seed_text):
    """Stage the seed and decision_extractor side by side, as the box runner does."""
    d = Path(tempfile.mkdtemp(prefix="no_l3_seed_stage_"))
    (d / "no_l3_graph_seed.py").write_text(seed_text, encoding="utf-8")
    shutil.copy(DECISION_SRC, d / "decision_extractor.py")
    return d / "no_l3_graph_seed.py"


def _load(path):
    spec = importlib.util.spec_from_file_location("seed_" + uuid.uuid4().hex, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _quads(store):
    return list(store.quads_for_pattern(None, None, None, None))


def _visible(store):
    """Quads a reader sees: the default graph and every named graph except the seed's own
    staging and teardown graphs (those are removed by the teardown)."""
    return [q for q in _quads(store)
            if not (isinstance(q.graph_name, _NamedNode)
                    and q.graph_name.value.startswith("urn:ostler:no-l3-seed/"))]


try:
    from pyoxigraph import NamedNode as _NamedNode
except ImportError:  # the import happens at test time; this only names the class
    _NamedNode = None


def _count_query(store, sparql):
    return int(list(store.query(sparql))[0]["n"].value)


def _live_store(ox, preload=()):
    """A store with live rows already on it, as on the box. The teardown must keep them."""
    store = ox.Store()
    store.update('INSERT DATA { <urn:ostler:live/item-1> <urn:ostler:live/label> "live row" . }')
    store.update('INSERT DATA { GRAPH <%s> { <urn:ostler:live/item-2> <urn:ostler:live/label> '
                 '"live graph row" . } }' % GRAPH)
    for sparql in preload:
        store.update(sparql)
    return store


def run_seed(seed_path, store, exclude_existing=True):
    """Seed a real store through the seed's own run_units, the same code the probe runs
    (the probe's closures do HTTP; these do store calls). Returns what it measured."""
    seed = _load(seed_path)
    _ingest, settings, ttl, _subjects, writes, _slugs = seed.build(PAYLOAD)
    plan = seed.plan_writes(settings, writes)
    teardown = []
    before = len(_quads(store))

    def write_one(idx, label, sparql):
        store.update(sparql)

    try:
        excluded, to_delete = seed.run_units(
            lambda q: store.update(q), lambda q: _count_query(store, q),
            lambda: store.load(ttl.encode("utf-8"), format=_fmt(), to_graph=_named(GRAPH)),
            write_one, ttl, GRAPH, plan, teardown, exclude_existing=exclude_existing)
        errors = []
    except Exception as exc:  # noqa: BLE001 -- the assertion judges it
        excluded, to_delete, errors = None, None, [("seed", type(exc).__name__, str(exc)[:200])]
    return {"before": before, "teardown": teardown, "excluded": excluded,
            "to_delete": to_delete, "errors": errors, "plan": plan, "ttl": ttl,
            "store": store, "seed": seed}


def _fmt():
    import pyoxigraph as ox
    return ox.RdfFormat.TURTLE


def _named(iri):
    import pyoxigraph as ox
    return ox.NamedNode(iri)


def _teardown(store, teardown):
    for sparql in teardown:
        store.update(sparql)


class NoL3SeedRealStore(unittest.TestCase):
    def setUp(self):
        import pyoxigraph as ox
        self.ox = ox
        src = SEED_SRC.read_text(encoding="utf-8")
        self.assertIn(FIXED_PERSON, src, "fixed person line not found: the source changed")
        self.assertIn(FIXED_DATE, src, "fixed date line not found: the source changed")

    def test_seed_accepted_and_exact_teardown_restores_pre_seed_count(self):
        store = _live_store(self.ox)
        r = run_seed(_stage(SEED_SRC.read_text(encoding="utf-8")), store)
        print("\n[real-store] pre-seed=%d excluded_pre_existing=%s to_delete=%s errors=%d"
              % (r["before"], r["excluded"], r["to_delete"], len(r["errors"])))
        self.assertEqual(r["errors"], [], "the seed or a write was rejected: %s" % r["errors"])
        self.assertEqual(r["excluded"], 0, "nothing pre-existed, so nothing may be excluded")
        ox = self.ox
        dates = list(store.quads_for_pattern(None, ox.NamedNode(DATE_PRED), None, ox.DefaultGraph()))
        self.assertEqual(len(dates), 2)
        for q in dates:
            self.assertEqual(q.object.datatype.value, "http://www.w3.org/2001/XMLSchema#dateTime")
            self.assertTrue(_is_datetime_lexical(q.object.value), q.object.value)
        _teardown(store, r["teardown"])
        after = len(_visible(store))
        print("[real-store] exact teardown: total=%d (pre-seed %d)" % (after, r["before"]))
        self.assertEqual(after, r["before"], "exact teardown must return to the pre-seed count")
        self.assertEqual(len(list(store.quads_for_pattern(
            ox.NamedNode("urn:ostler:live/item-1"), None, None, None))), 1)

    def test_preexisting_identical_quad_survives_teardown(self):
        """Pre-load one quad identical to a seed quad. The exclusion must keep it."""
        seed_src = _stage(SEED_SRC.read_text(encoding="utf-8"))
        probe_ttl = _load(seed_src).build(PAYLOAD)[2]
        import pyoxigraph as ox
        scratch = ox.Store()
        scratch.load(probe_ttl.encode("utf-8"), format=ox.RdfFormat.TURTLE, to_graph=_named(GRAPH))
        seed_quad = next(q for q in _quads(scratch) if q.predicate.value.endswith("displayName"))
        pre = "INSERT DATA { GRAPH <%s> { <%s> <%s> %s . } }" % (
            GRAPH, seed_quad.subject.value, seed_quad.predicate.value, _nt_literal(seed_quad.object))
        store = _live_store(ox, preload=[pre])
        r = run_seed(seed_src, store)
        self.assertEqual(r["errors"], [])
        self.assertGreaterEqual(r["excluded"], 1, "the pre-loaded quad must be excluded")
        _teardown(store, r["teardown"])
        survivor = list(store.quads_for_pattern(seed_quad.subject, seed_quad.predicate,
                                                seed_quad.object, _named(GRAPH)))
        print("\n[pre-existence] excluded=%d; pre-loaded seed quad survives teardown: %s"
              % (r["excluded"], len(survivor) == 1))
        self.assertEqual(len(survivor), 1, "a quad on the box BEFORE the seed was deleted")

    def test_mutant_without_exclusion_deletes_the_preexisting_quad(self):
        seed_src = _stage(SEED_SRC.read_text(encoding="utf-8"))
        probe_ttl = _load(seed_src).build(PAYLOAD)[2]
        import pyoxigraph as ox
        scratch = ox.Store()
        scratch.load(probe_ttl.encode("utf-8"), format=ox.RdfFormat.TURTLE, to_graph=_named(GRAPH))
        seed_quad = next(q for q in _quads(scratch) if q.predicate.value.endswith("displayName"))
        pre = "INSERT DATA { GRAPH <%s> { <%s> <%s> %s . } }" % (
            GRAPH, seed_quad.subject.value, seed_quad.predicate.value,
            _nt_literal(seed_quad.object))
        store = _live_store(ox, preload=[pre])
        r = run_seed(seed_src, store, exclude_existing=False)
        _teardown(store, r["teardown"])
        survivor = list(store.quads_for_pattern(seed_quad.subject, seed_quad.predicate,
                                                seed_quad.object, _named(GRAPH)))
        print("\n[mutant no-exclusion] pre-loaded seed quad survives: %s" % (len(survivor) == 1))
        self.assertEqual(len(survivor), 0, "the mutant must delete the pre-existing quad")

    def test_delete_where_cannot_touch_a_live_topic_or_mention(self):
        """The topic UPDATE's DELETE WHERE is scoped to subjects the seed names: a topic
        IRI built from the run marker, and a mention IRI built from the seed's
        conversation id. Show the WHERE patterns, then prove a live row survives."""
        seed = _load(_stage(SEED_SRC.read_text(encoding="utf-8")))
        _ingest, settings, _ttl, _subj, writes, _slugs = seed.build(PAYLOAD)
        plan = dict(seed.plan_writes(settings, writes))
        l2 = plan["topic_L2"]
        dw = re.findall(r"DELETE WHERE \{ (<[^>]+>) ([^}]*)\}", l2)
        print("\n[delete-where] L2 topic UPDATE has %d DELETE WHERE clauses:" % len(dw))
        for subj, rest in dw:
            print("   DELETE WHERE { %s %s }" % (subj, rest.strip()))
        self.assertTrue(dw, "the topic UPDATE has no DELETE WHERE to scope")
        from src import topic_writer  # the shipped IRI builders, not a copy of them
        slug = topic_writer.slugify_topic("walk probe " + PAYLOAD["topic_markers"]["L2"] + " quarry")
        expected = {"<%s>" % topic_writer.topic_uri(slug),
                    "<%s>" % topic_writer.mention_uri("ostler-walk-" + PAYLOAD["conv_markers"]["L2"], slug)}
        named = {subj for subj, _ in dw}
        self.assertEqual(named, expected, "DELETE WHERE must name exactly the seed's topic and mention")
        ox = self.ox
        live = _live_store(ox, preload=[
            'INSERT DATA { <%s> <http://www.w3.org/2000/01/rdf-schema#label> "live topic" . }' % LIVE_TOPIC,
            'INSERT DATA { <%s> <%s> <%s> . }' % (LIVE_MENTION, PWG + "mentionsTopic", LIVE_TOPIC),
        ])
        before_live = len(list(live.quads_for_pattern(None, None, None, None)))
        live.update(l2)
        # the live rows are not in the update's DELETE WHERE scope, so they must survive
        self.assertEqual(len(list(live.quads_for_pattern(
            ox.NamedNode(LIVE_TOPIC), None, None, None))), 1, "live topic label was deleted")
        self.assertEqual(len(list(live.quads_for_pattern(
            ox.NamedNode(LIVE_MENTION), None, None, None))), 1, "live mention was deleted")
        print("[delete-where] live topic and live mention survive the L2 topic UPDATE "
              "(live quads before=%d)" % before_live)

    def test_stamp_only_teardown_leaves_residue(self):
        store = _live_store(self.ox)
        r = run_seed(_stage(SEED_SRC.read_text(encoding="utf-8")), store)
        for q in _visible(store):
            if PAYLOAD["stamp"] in str(q):
                store.remove(q)
        left = len(_visible(store)) - r["before"]
        print("\n[mutant stamp-only] leftover quads=%d" % left)
        self.assertNotEqual(left, 0, "the stamp-only mutant must leave quads behind")

    def test_mutant_double_wrap_is_rejected_by_the_store(self):
        src = SEED_SRC.read_text(encoding="utf-8")
        self.assertEqual(src.count(FIXED_PERSON), 1)
        mutant = src.replace(FIXED_PERSON, MUTANT_PERSON, 1)
        self.assertEqual(mutant.count(MUTANT_PERSON), 1, "mutant did not apply")
        r = run_seed(_stage(mutant), _live_store(self.ox))
        print("\n[mutant double-wrap] errors=%s" % [e[:2] for e in r["errors"]])
        self.assertTrue(r["errors"], "the double-wrapped decision UPDATE must be rejected")

    def test_mutant_date_only_datetime_is_caught(self):
        src = SEED_SRC.read_text(encoding="utf-8")
        self.assertEqual(src.count(FIXED_DATE), 1)
        mutant = src.replace(FIXED_DATE, MUTANT_DATE, 1)
        self.assertEqual(mutant.count(MUTANT_DATE), 1, "mutant did not apply")
        store = _live_store(self.ox)
        run_seed(_stage(mutant), store)
        bad = sum(1 for q in store.quads_for_pattern(None, self.ox.NamedNode(DATE_PRED), None, self.ox.DefaultGraph())
                  if not _is_datetime_lexical(q.object.value))
        print("\n[mutant date-only] decisionDate values not a dateTime: %d" % bad)
        self.assertEqual(bad, 2, "the date-only mutant must be caught on both decision rows")


class ProbeSeedOutput(unittest.TestCase):
    """The probe must NEVER read unparseable seed output as an empty (clean) teardown."""

    def test_unparseable_seed_stdout_is_recorded_and_raised(self):
        import subprocess
        sys.path.insert(0, str(SEED_SRC.parent))
        box = _load(SEED_SRC.parent / "no_l3_box.py")
        real = subprocess.run

        class Done:
            returncode = 0
            stdout = "not json"
            stderr = ""

        subprocess.run = lambda *a, **k: Done()
        box.EXACT_ERROR[:] = []
        box.EXACT_TEARDOWN[:] = []
        markers = {"L2": "a", "L3": "b", "L0": "c", "l2_topic": "t2", "l3_topic": "t3",
                   "l2_decision": "d2", "l3_decision": "d3"}
        try:
            with self.assertRaises(RuntimeError):
                box._seed_graph("owner", "stamp", markers, [])
        finally:
            subprocess.run = real
        print("\n[probe] unparseable seed stdout -> exact_error=%r" % box.EXACT_ERROR)
        self.assertTrue(box.EXACT_ERROR, "the unknown teardown must be recorded")
        self.assertEqual(box.EXACT_TEARDOWN, [], "no teardown may be invented")


def _nt_literal(lit):
    """A pyoxigraph literal as SPARQL/N-Triples text (for the pre-load only)."""
    v = lit.value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    if lit.datatype is not None and lit.datatype.value != "http://www.w3.org/2001/XMLSchema#string":
        return '"%s"^^<%s>' % (v, lit.datatype.value)
    return '"%s"' % v


if __name__ == "__main__":
    try:
        unittest.main(verbosity=2)
    finally:
        shutil.rmtree(_HOME, ignore_errors=True)
