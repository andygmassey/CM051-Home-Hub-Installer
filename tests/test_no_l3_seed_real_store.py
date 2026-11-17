#!/usr/bin/env python3
"""Real-store test for the no_l3 graph seed (scripts/box_walk_probes/lib/no_l3_graph_seed.py).

Run 12 of the 133 L3 proof stopped at the seed: Oxigraph answered HTTP 400 to the
decision UPDATE. The seed passed an already-angle-bracketed IRI as about_persons, and
decision_extractor wraps that list in <...> again, giving <<urn:...>>, which is a
SPARQL parse error. The offline harness mocked the store, so it could not see this.

This test loads the seed's Turtle into a REAL pyoxigraph store (the same SPARQL parser
the Oxigraph server uses), runs every topic and decision UPDATE the probe sends, counts
the rows, tears them down by stamp and counts again. A mutant that restores the double
wrap must go red. Synthetic data only; HOME is redirected to a temp dir.

Run: python3 tests/test_no_l3_seed_real_store.py -v
"""
import importlib.util
import os
import shutil
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

# Redirect HOME before any CM048 import: the vendored modules read config from it.
_HOME = tempfile.mkdtemp(prefix="no_l3_seed_home_")
os.environ["HOME"] = _HOME

ROOT = Path(__file__).resolve().parents[1]
SEED_SRC = ROOT / "scripts" / "box_walk_probes" / "lib" / "no_l3_graph_seed.py"
DECISION_SRC = ROOT / "vendor" / "cm041" / "meeting_syncer" / "decision_extractor.py"
sys.path[:0] = [str(ROOT / "vendor" / "cm048_pipeline"), str(ROOT / "vendor")]

# The line the mutant restores. Pre-fix it was `about_persons=[person_uri],`.
FIXED = "about_persons=[person_uri[1:-1]], status="
MUTANT = "about_persons=[person_uri], status="

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


SEED_TOKENS = ["ostler-walk-", PAYLOAD["stamp"]] + list(PAYLOAD["conv_markers"].values()) \
    + list(PAYLOAD["topic_markers"].values()) + list(PAYLOAD["decision_markers"].values())


def _stamp_quads(store, stamp):
    """Every quad in the store that carries the stamp anywhere (the teardown measure)."""
    return [q for q in store.quads_for_pattern(None, None, None, None) if stamp in str(q)]


def run_seed_on_real_store(seed_path, stamp):
    """Seed a real store the way the probe does. Returns a dict of counts and errors."""
    import pyoxigraph as ox

    seed = _load(seed_path)
    _ingest, settings, ttl, _subjects, writes, _slugs = seed.build(PAYLOAD)
    de = seed._decision_extractor()
    from src import topic_writer

    store = ox.Store()
    graph = ox.NamedNode("urn:ostler:user/" + settings.user_id)
    store.load(ttl.encode("utf-8"), format=ox.RdfFormat.TURTLE, to_graph=graph)
    out = {"seed_quads": len(list(store.quads_for_pattern(None, None, None, graph))),
           "errors": [], "updates_ok": 0}

    applied = []
    for w in writes:
        if w["kind"] == "topic":
            sparql = topic_writer.build_topic_update(
                w["conv"], w["topics"], settings, metadata=w["meta"])
            label = "topic_" + w["level"]
        else:
            sparql = de.build_decision_sparql(w["decision"])
            label = "decision_" + w["level"]
        try:
            store.update(sparql)
            applied.append(sparql)
            out["updates_ok"] += 1
        except Exception as exc:  # noqa: BLE001 -- recorded, the assertion judges it
            out["errors"].append((label, type(exc).__name__, str(exc)[:200]))

    out["stamp_quads_after_seed"] = len(_stamp_quads(store, stamp))
    out["decisions"] = sum(1 for _ in store.quads_for_pattern(
        None, ox.NamedNode("https://schema.ostler.ai/ontology#decisionAbout"), None, None))
    out["topics"] = sum(1 for _ in store.quads_for_pattern(
        None, ox.NamedNode("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"),
        ox.NamedNode("https://schema.ostler.ai/ontology#ConversationTopic"), None))

    # Teardown by stamp alone, as the probe's teardown does it.
    for q in _stamp_quads(store, stamp):
        store.remove(q)
    out["stamp_quads_after_teardown"] = len(_stamp_quads(store, stamp))
    out["total_after_stamp_teardown"] = len(list(store.quads_for_pattern(None, None, None, None)))
    # Stamp-only teardown leaves the conversation, fact and todo rows (their ids are not
    # stamped). The seed's exact quad set is the teardown key: every quad the Turtle
    # carried, plus anything still carrying a seed token.
    expected = ox.Store()
    expected.load(ttl.encode("utf-8"), format=ox.RdfFormat.TURTLE, to_graph=graph)
    for sparql in applied:
        expected.update(sparql)
    for q in list(expected.quads_for_pattern(None, None, None, None)):
        store.remove(q)
    for q in list(store.quads_for_pattern(None, None, None, None)):
        if any(tok in str(q) for tok in SEED_TOKENS):
            store.remove(q)
    out["total_after_teardown"] = len(list(store.quads_for_pattern(None, None, None, None)))
    return out


class NoL3SeedRealStore(unittest.TestCase):
    def test_seed_writes_every_row_to_a_real_store(self):
        self.assertTrue(SEED_SRC.is_file(), SEED_SRC)
        self.assertIn(FIXED, SEED_SRC.read_text(encoding="utf-8"),
                      "fixed line not found: the source changed under the test")
        r = run_seed_on_real_store(_stage(SEED_SRC.read_text(encoding="utf-8")), PAYLOAD["stamp"])
        print("\n[real-store] seed_quads=%d updates_ok=%d errors=%d decisions=%d topics=%d"
              % (r["seed_quads"], r["updates_ok"], len(r["errors"]), r["decisions"], r["topics"]))
        print("[real-store] stamp_quads after seed=%d; stamp-only teardown leaves total=%d; "
              "seed-token teardown leaves total=%d"
              % (r["stamp_quads_after_seed"], r["total_after_stamp_teardown"],
                 r["total_after_teardown"]))
        self.assertEqual(r["errors"], [], "a topic/decision UPDATE was rejected by the store")
        self.assertEqual(r["updates_ok"], 4, "2 topic + 2 decision UPDATEs expected")
        self.assertEqual(r["decisions"], 2)
        self.assertEqual(r["topics"], 2)
        self.assertGreater(r["stamp_quads_after_seed"], 0)
        self.assertEqual(r["stamp_quads_after_teardown"], 0)
        self.assertEqual(r["total_after_teardown"], 0, "teardown must return the store to empty")

    def test_mutant_double_wrap_is_rejected_by_the_store(self):
        src = SEED_SRC.read_text(encoding="utf-8")
        self.assertEqual(src.count(FIXED), 1, "fixed line must occur exactly once")
        mutant_src = src.replace(FIXED, MUTANT, 1)
        self.assertEqual(mutant_src.count(MUTANT), 1, "mutant did not apply")
        r = run_seed_on_real_store(_stage(mutant_src), PAYLOAD["stamp"] + "m")
        print("\n[mutant] errors=%s" % [(e[0], e[1]) for e in r["errors"]])
        self.assertEqual(sorted(e[0] for e in r["errors"]), ["decision_L2", "decision_L3"],
                         "the double-wrapped decision UPDATEs must be rejected")
        self.assertTrue(all(e[1] == "SyntaxError" for e in r["errors"]), r["errors"])


if __name__ == "__main__":
    try:
        unittest.main(verbosity=2)
    finally:
        shutil.rmtree(_HOME, ignore_errors=True)
