#!/usr/bin/env python3
"""Real-store test for the no_l3 graph seed (scripts/box_walk_probes/lib/no_l3_graph_seed.py).

Run 12 of the 133 L3 proof stopped at the seed. (1) The decision UPDATE passed an
already-angle-bracketed IRI as about_persons, and decision_extractor wrapped it again
(<<urn:...>>): Oxigraph answered 400. (2) The decision date was a date-only string typed
xsd:dateTime. (3) The teardown removed by stamp and subject, so the conversation, fact,
todo and topic-mention rows (which carry no stamp) stayed behind.

This test loads the seed into a REAL pyoxigraph store (the SPARQL parser the Oxigraph
server uses), runs every UPDATE the probe plans, and checks:
  - every row is accepted, and each decision date is a real xsd:dateTime;
  - the EXACT-set teardown returns the store to its pre-seed count, with live rows kept;
  - a stamp-only teardown (the mutant) leaves quads behind and the check goes red.
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

# The lines the mutants put back. Pre-fix they were `about_persons=[person_uri],` and
# `date=FIXTURE_DATE,`.
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
NS = "https://schema.ostler.ai/ontology#"
DATE_PRED = "https://schema.ostler.ai/ontology#decisionDate"


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


def _count(store):
    import pyoxigraph as ox  # noqa: F401
    return len(list(store.quads_for_pattern(None, None, None, None)))


def _live_store(ox):
    """A store with live rows already in it, as on the box. The teardown must keep them."""
    store = ox.Store()
    store.update('INSERT DATA { <urn:ostler:live/item-1> <urn:ostler:live/label> "live row" . }')
    store.update('INSERT DATA { GRAPH <urn:ostler:user/synthowner> { '
                 '<urn:ostler:live/item-2> <urn:ostler:live/label> "live graph row" . } }')
    return store


def _stamp_only_teardown(store, stamp):
    """The mutant: remove only quads whose text carries the stamp. Conversation, fact,
    todo and topic-mention rows have unstamped ids, so they survive this."""
    for q in list(store.quads_for_pattern(None, None, None, None)):
        if stamp in str(q):
            store.remove(q)


def run_seed(seed_path, store=None):
    """Seed a real store the way the probe does, and return what it measured."""
    import pyoxigraph as ox

    seed = _load(seed_path)
    _ingest, settings, ttl, subjects, writes, _slugs = seed.build(PAYLOAD)
    graph = "urn:ostler:user/" + settings.user_id
    store = store if store is not None else _live_store(ox)
    before = _count(store)
    out = {"before": before, "errors": [], "updates_ok": 0, "subjects": subjects}

    store.load(ttl.encode("utf-8"), format=ox.RdfFormat.TURTLE, to_graph=ox.NamedNode(graph))
    out["seed_quads"] = _count(store) - before

    plan = seed.plan_writes(settings, writes)
    applied = []
    for label, sparql in plan:
        try:
            store.update(sparql)
            applied.append((label, sparql))
            out["updates_ok"] += 1
        except Exception as exc:  # noqa: BLE001 -- recorded, the assertion judges it
            out["errors"].append((label, type(exc).__name__, str(exc)[:200]))
    out["plan"] = plan
    out["teardown"] = seed.exact_teardown(ttl, graph, applied)
    out["after_seed"] = _count(store)
    out["store"] = store
    out["ttl"] = ttl
    out["graph"] = graph
    return out


class NoL3SeedRealStore(unittest.TestCase):
    def setUp(self):
        import pyoxigraph as ox
        self.ox = ox
        self.assertIn(FIXED_PERSON, SEED_SRC.read_text(encoding="utf-8"),
                      "fixed person line not found: the source changed under the test")
        self.assertIn(FIXED_DATE, SEED_SRC.read_text(encoding="utf-8"),
                      "fixed date line not found: the source changed under the test")

    def test_seed_is_accepted_and_teardown_restores_the_pre_seed_count(self):
        r = run_seed(_stage(SEED_SRC.read_text(encoding="utf-8")))
        store, ox = r["store"], self.ox
        print("\n[real-store] pre-seed=%d seed_quads=%d after_seed=%d updates_ok=%d errors=%d"
              % (r["before"], r["seed_quads"], r["after_seed"], r["updates_ok"], len(r["errors"])))
        self.assertEqual(r["errors"], [], "a topic/decision UPDATE was rejected by the store")
        self.assertEqual(r["updates_ok"], 4, "2 topic + 2 decision UPDATEs expected")

        # every decision date is a real xsd:dateTime
        dates = list(store.quads_for_pattern(None, ox.NamedNode(DATE_PRED), None, None))
        self.assertEqual(len(dates), 2)
        for q in dates:
            self.assertEqual(q.object.datatype.value,
                             "http://www.w3.org/2001/XMLSchema#dateTime")
            self.assertTrue(_is_datetime_lexical(q.object.value), q.object.value)

        # exact-set teardown: back to the pre-seed count, live rows still there
        for sparql in r["teardown"]:
            store.update(sparql)
        after = _count(store)
        print("[real-store] exact teardown: total=%d (pre-seed %d)" % (after, r["before"]))
        self.assertEqual(after, r["before"], "exact teardown must return to the pre-seed count")
        live = list(store.quads_for_pattern(
            ox.NamedNode("urn:ostler:live/item-1"), None, None, None))
        self.assertEqual(len(live), 1, "a live row was removed by the teardown")

    def test_stamp_only_teardown_leaves_residue_so_the_check_is_red(self):
        """The mutant: the probe's old teardown. The exact-restore assertion must fail
        on it; this test passes because that failure is detected."""
        r = run_seed(_stage(SEED_SRC.read_text(encoding="utf-8")))
        store = r["store"]
        _stamp_only_teardown(store, PAYLOAD["stamp"])
        left = _count(store)
        print("\n[mutant] stamp-only teardown: total=%d (pre-seed %d), leftover=%d"
              % (left, r["before"], left - r["before"]))
        self.assertNotEqual(left, r["before"],
                            "the stamp-only mutant must leave quads behind")

    def test_mutant_double_wrap_is_rejected_by_the_store(self):
        src = SEED_SRC.read_text(encoding="utf-8")
        self.assertEqual(src.count(FIXED_PERSON), 1, "fixed person line must occur exactly once")
        mutant_src = src.replace(FIXED_PERSON, MUTANT_PERSON, 1)
        self.assertEqual(mutant_src.count(MUTANT_PERSON), 1, "mutant did not apply")
        r = run_seed(_stage(mutant_src))
        print("\n[mutant] double-wrap errors=%s" % [(e[0], e[1]) for e in r["errors"]])
        self.assertEqual(sorted(e[0] for e in r["errors"]), ["decision_L2", "decision_L3"],
                         "the double-wrapped decision UPDATEs must be rejected")

    def test_mutant_date_only_datetime_is_caught(self):  # the check on the healthy run is in the first test
        src = SEED_SRC.read_text(encoding="utf-8")
        self.assertEqual(src.count(FIXED_DATE), 1, "fixed date line must occur exactly once")
        mutant_src = src.replace(FIXED_DATE, MUTANT_DATE, 1)
        self.assertEqual(mutant_src.count(MUTANT_DATE), 1, "mutant did not apply")
        r = run_seed(_stage(mutant_src))
        bad = 0
        for q in r["store"].quads_for_pattern(None, self.ox.NamedNode(DATE_PRED), None, None):
            if not _is_datetime_lexical(q.object.value):
                bad += 1
        print("\n[mutant] date-only decisionDate values not parseable as dateTime: %d" % bad)
        self.assertEqual(bad, 2, "the date-only mutant must be caught on both decision rows")


if __name__ == "__main__":
    try:
        unittest.main(verbosity=2)
    finally:
        shutil.rmtree(_HOME, ignore_errors=True)
