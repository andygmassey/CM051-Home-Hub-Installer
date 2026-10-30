"""people_count_agreement reads ONLY after the embed queue has drained (v1.0.121 trial).

Measured on the trial: oxigraph 8937 vs Doctor 8837, a gap of 100, was EMBED LAG
during live ingest: one Person reached oxigraph at 15:35:15Z and Qdrant at
15:45:18Z, ten minutes later. The probe's stability check asks whether the counts
stopped MOVING for a minute or so, so it graded the lag as a disagreement.

The named quiescence signal (see the probe, "DO NOT READ WHILE THE EMBED QUEUE IS
NON-EMPTY"): the customer-visible graph people with no vector point is EMPTY, or
the vector writer's own marker (people_index.tsv, last_status=ok, last_success_at
strictly later than the first sighting) says a run that began after the sighting
finished and they are still missing (a drop: graded, not waited on). No signal
inside the bound is CANNOT-RUN. The tolerance and the cap are NOT touched: every
case here runs with cap 0.

Real components: the shipped probe script run locally (no box), the shipped
people_rules.py, the shipped _wiki_people_count loaded from ical-server.py (as in
test_people_count_one_definition.py, whose stand-in Oxigraph / Qdrant / Doctor
this reuses). The "writer" is a thread that adds the missing vector point and
stamps people_index.tsv, exactly the two things the real fda-rerun tick does.
Synthetic data only.

PROBE_SUBJECT=<path> runs another copy of the probe (the trial tree's, for RED).
"""
from __future__ import annotations

import os
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest

pytest.importorskip("pyoxigraph")
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import test_people_count_one_definition as base  # noqa: E402

World, API, seed_graph = base.World, base.API, base.seed_graph
PROBE = Path(os.environ.get("PROBE_SUBJECT") or base.PROBE)
MARKER = ".ostler/state/source_activity/people_index.tsv"


@pytest.fixture()
def world():
    w = World()
    base.server.QDRANT_URL = w.qdrant
    yield w
    w.close()


def stamp(ts=None):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts if ts is not None else time.time()))


def write_marker(home, status="ok", ts=None):
    p = home / MARKER
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("source=people_index\nlast_run_at=%s\nlast_status=%s\nlast_success_at=%s\nwriter=ostler-fda\n"
                 % (stamp(), status, stamp(ts)))


def run_probe(w, tmp_path, probe=None, drain_wait=40):
    home = tmp_path / "acct"
    (home / ".ostler" / "secrets").mkdir(parents=True, exist_ok=True)
    (home / ".ostler" / "secrets" / "store-curl.conf").write_text('header = "Authorization: Bearer t"\n')
    env = dict(os.environ, HOME=str(home), OSTLER_BOX_HOST="",
               OSTLER_OXIGRAPH_URL=w.oxi + "/query", OSTLER_QDRANT_URL=w.qdrant,
               OSTLER_DOCTOR_PEOPLE_URL=w.doctor + "/api/v1/hydration/status",
               OSTLER_PEOPLE_RULES_DIR=str(API), NO_PROXY="127.0.0.1,localhost",
               OSTLER_PEOPLE_STABILITY_STEP_S="1", OSTLER_PEOPLE_STABILITY_WAIT_S="20",
               OSTLER_PEOPLE_CONVERGE_WAIT_S="0", OSTLER_PROBE_STATE_DIR=str(tmp_path / "pstate"),
               OSTLER_PEOPLE_EMBED_DRAIN_STEP_S="1", OSTLER_PEOPLE_EMBED_DRAIN_WAIT_S=str(drain_wait),
               # cap 0: ANY gap fails. The shipped cap (5) and percentage are not touched.
               OSTLER_PEOPLE_TOLERANCE_PCT="100", OSTLER_PEOPLE_TOLERANCE_CAP="0")
    for k in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY"):
        env.pop(k, None)
    t0 = time.time()
    r = subprocess.run(["bash", str(probe or PROBE)], env=env, capture_output=True, text=True, timeout=300)
    text = r.stdout + r.stderr
    v = next((ln.split("VERDICT:")[1].strip() for ln in text.splitlines() if "VERDICT:" in ln), "NONE")
    return v, text, time.time() - t0


def lagging_world(w, tmp_path):
    """Graph holds a, b, c; the vector store holds only a, b: c is in the embed queue."""
    seed_graph(w)
    w.point("a", "Jane Doe")
    w.point("b", "John Smith")
    return tmp_path / "acct"


def after(delay, fn):
    t = threading.Timer(delay, fn)
    t.daemon = True
    t.start()
    return t


def test_green_mid_lag_waits_for_the_vector_then_agrees(world, tmp_path):
    home = lagging_world(world, tmp_path)
    after(8, lambda: world.point("c", "Mary Jones"))      # the vector lands ~8 s in
    v, text, took = run_probe(world, tmp_path)
    assert v.startswith("PASS"), text
    assert "oxigraph=3 doctor=3" in text, text
    assert "embed queue: EMPTY" in text, text
    assert "holding the reads until people_index has run" in text, text
    assert took > 7, "it did not wait for the drain (%.1fs)" % took


def test_embed_lag_is_not_graded_as_a_disagreement(world, tmp_path):
    """The trial's probe (PROBE_SUBJECT) FAILS this same lag. Run against the new probe
    this asserts the new probe does NOT, which is the point; the RED is shown by running
    this test with PROBE_SUBJECT set to the trial copy."""
    lagging_world(world, tmp_path)
    after(8, lambda: world.point("c", "Mary Jones"))
    v, text, _ = run_probe(world, tmp_path)
    assert not v.startswith("FAIL"), "graded embed lag as a disagreement:\n" + text


def test_cannot_run_when_the_drain_signal_never_arrives(world, tmp_path):
    home = lagging_world(world, tmp_path)
    write_marker(home, "ok", ts=time.time() - 7200)         # a marker from two hours ago is no signal
    v, text, _ = run_probe(world, tmp_path, drain_wait=6)
    assert v.startswith("CANNOT-RUN"), text
    assert "NO DRAIN SIGNAL ARRIVED" in text, text
    assert "1 customer-visible graph people still had no vector" in text, text
    assert "last_status=ok" in text, text


def test_cannot_run_when_there_is_no_marker_at_all(world, tmp_path):
    lagging_world(world, tmp_path)
    v, text, _ = run_probe(world, tmp_path, drain_wait=5)
    assert v.startswith("CANNOT-RUN"), text
    assert "last_status=-" in text, text


def test_a_failed_index_run_is_not_a_drain(world, tmp_path):
    home = lagging_world(world, tmp_path)
    # Stamped ~12 s in, i.e. AFTER the probe's first sighting (the stability phase
    # takes ~5 s): a run that errored after the people were seen drained nothing.
    after(12, lambda: write_marker(home, "error"))
    v, text, _ = run_probe(world, tmp_path, drain_wait=22)
    assert v.startswith("CANNOT-RUN"), text


def test_a_real_drop_is_still_a_fail_not_a_wait(world, tmp_path):
    """people_index COMPLETES a run after the sighting and the person still has no
    vector: that is a drop. It is graded (FAIL), never waited out and never CANNOT-RUN."""
    home = lagging_world(world, tmp_path)
    # Stamped ~12 s in, AFTER the first sighting (the stability phase takes ~5 s).
    # A marker stamped before the sighting is a run that cannot have seen these
    # people, and rightly does not count (see the CANNOT-RUN tests).
    after(12, lambda: write_marker(home, "ok"))
    v, text, took = run_probe(world, tmp_path, drain_wait=60)
    assert v.startswith("FAIL"), text
    assert "STILL have no vector" in text, text
    assert "oxigraph=3 doctor=2 differ by 1" in text, text
    assert took < 50, "it waited out the bound instead of grading the drop"


def test_control_nothing_waiting_does_not_wait(world, tmp_path):
    seed_graph(world)
    base.seed_qdrant_named(world)
    v, text, took = run_probe(world, tmp_path)
    assert v.startswith("PASS"), text
    assert "embed queue: EMPTY" in text and "after 0s" in text, text
    assert "holding the reads" not in text, text


def test_nameless_people_never_hold_the_probe_and_both_sides_exclude_them(world, tmp_path):
    """Two nameless WhatsApp provisionals sit in the graph with no vector, by design, and
    a nameless point sits in Qdrant. Both sides exclude them via is_countable_person
    (#3245): graph 3 = Doctor 3, and the probe does not wait for vectors that never come."""
    seed_graph(world)                         # a, b, c named + p1, p2 nameless + m1 merged
    base.seed_qdrant_named(world)
    base.seed_qdrant_hidden(world)            # a nameless point, a JID, a short code
    assert base.server._wiki_people_count() == 3
    v, text, took = run_probe(world, tmp_path, drain_wait=6)
    assert v.startswith("PASS"), text
    assert "oxigraph=3 doctor=3" in text, text
    assert "stubs=2" in text, text
    assert "embed queue: EMPTY" in text and "after 0s" in text, text


def test_mutant_counting_nameless_in_the_queue_is_caught(world, tmp_path):
    """Sensitivity: a probe whose awaiting-embed set counted the nameless nodes would wait
    for vectors that never come (CANNOT-RUN). The control above passes only because it does not."""
    seed_graph(world)
    base.seed_qdrant_named(world)
    src = PROBE.read_text()
    needle = "        if not hidden:\n            vo += 1; countable_uris.add(u)\n"
    assert needle in src
    # The probe sources ../lib/probe.sh relative to itself, so the mutant sits
    # beside it and is removed in the finally (the same pattern as
    # scripts/tests/test_people_count_agreement_probe.sh).
    mutant = PROBE.parent / (".mutant_embed_drain_%d.sh" % os.getpid())
    mutant.write_text(src.replace(needle, "        countable_uris.add(u)\n        if not hidden:\n            vo += 1\n"))
    try:
        v, text, _ = run_probe(world, tmp_path, probe=mutant, drain_wait=5)
    finally:
        mutant.unlink()
    assert v.startswith("CANNOT-RUN"), text
