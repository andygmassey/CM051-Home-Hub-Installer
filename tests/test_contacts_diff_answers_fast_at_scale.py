"""F18 (#18, Mini16): GET /api/v1/contacts/diff must answer fast on a big graph.

On a ~6,700-person box the Doctor proxy gave up after its 30s upstream timeout
(502 at 30.04s): the duplicate scan is O(n^2) over names and ran on the request
path. In-process on the synthetic 6,700-person fixture below, build_report took
60.8s and stopped on its own budget with a partial report.

The fix builds the report in a background thread and serves the last finished
one with an "as_of" time; with none yet it answers at once with
degraded/preparing. This drives the REAL api_contacts_diff (vendored
ical-server) over the REAL TidyEngine.build_report, with only the Oxigraph
fetch replaced by an in-memory synthetic graph.

STRAIGHT arm: the 6,700-person call must answer in under 5s. On origin/main it
blocks on the scan (RED). Controls: once a build finishes, the cached report is
the same report build_report produces directly, and carries as_of.
"""
from __future__ import annotations

import importlib.util
import os
import sys
import threading
import time
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "vendor" / "cm041"))

SYLL = ["ka", "lo", "mi", "ren", "tas", "vo", "qui", "zan", "pel", "dor",
        "bri", "sun", "hal", "fen", "gar", "nis"]


def _name(i: int) -> str:
    """Distinct synthetic names, assembled at runtime from syllables."""
    a, b, c, d = i % 16, (i // 16) % 16, (i // 256) % 16, (i // 4096) % 16
    return (SYLL[a] + SYLL[b]).title() + " " + (SYLL[c] + SYLL[d] + SYLL[a]).title()


def _graph(n: int):
    from identity_resolver.batch_resolver import PersonRecord
    out = {}
    for i in range(n):
        uri = f"https://schema.ostler.ai/ontology#person_{i:06d}"
        given, family = _name(i).split(" ", 1)
        p = PersonRecord(uri=uri, display_name=f"{given} {family}",
                         given_name=given, family_name=family)
        if i % 2:
            p.phones = {f"+44770090{i % 1000:04d}"}
        if i % 3 == 0:
            p.emails = {f"user{i}@example.com"}
            p.email_domains = {"example.com"}
        out[uri] = p
    return out


def _load_server():
    os.environ.setdefault("USER_ID", "fixture")
    spec = importlib.util.spec_from_file_location(
        "ical_server_f18", REPO / "vendor" / "cm041" / "assistant_api" / "ical-server.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture()
def server(monkeypatch):
    import identity_resolver.tidy as tidy
    real = tidy.TidyEngine
    graph = {}

    class FixtureEngine(real):
        def __init__(self, oxigraph_url="", qdrant_url="", qdrant_collection="people",
                     config=None):
            from identity_resolver.batch_resolver import DEFAULT_CONFIG
            self.config = {**DEFAULT_CONFIG, **(config or {})}

        def build_report(self, persons=None):
            return real.build_report(self, persons=graph["persons"])

        def close(self):
            pass

    monkeypatch.setattr(tidy, "TidyEngine", FixtureEngine)
    srv = _load_server()
    monkeypatch.setattr(srv, "_ensure_pipeline_on_path", lambda: None, raising=False)
    yield srv, graph, FixtureEngine


def _call_with_deadline(fn, seconds):
    box = {}
    t = threading.Thread(target=lambda: box.setdefault("out", fn()), daemon=True)
    start = time.perf_counter()
    t.start()
    t.join(seconds)
    return box.get("out"), time.perf_counter() - start, t.is_alive()


def test_a_6700_person_graph_answers_under_5_seconds(server):
    srv, graph, _ = server
    graph["persons"] = _graph(6700)
    out, took, still_running = _call_with_deadline(srv.api_contacts_diff, 5.0)
    print(f"\n[F18] 6,700 people: answered={not still_running} in {took:.2f}s "
          f"preparing={out.get('preparing') if out else None}")
    assert not still_running, f"GET /api/v1/contacts/diff still scanning after {took:.1f}s"
    assert took < 5.0
    assert out["degraded"] is True and out["preparing"] is True and out["reason"]


def test_control_the_cached_report_is_the_real_report(server):
    srv, graph, engine = server
    graph["persons"] = _graph(300)
    direct = engine().build_report().to_dict()
    first = srv.api_contacts_diff()
    deadline = time.time() + 60
    while time.time() < deadline:
        out = srv.api_contacts_diff()
        if not out.get("preparing"):
            break
        time.sleep(0.1)
    t0 = time.perf_counter()
    again = srv.api_contacts_diff()
    took = time.perf_counter() - t0
    print(f"\n[F18] 300 people: first preparing={first.get('preparing')}, cached "
          f"items={len(again['items'])} as_of={again.get('as_of')} served in {took*1000:.0f}ms")
    assert again.get("as_of") and not again.get("degraded")
    assert again["total_persons"] == direct["total_persons"] == 300
    assert again["counts"] == direct["counts"] and len(again["items"]) == len(direct["items"])
    assert took < 1.0
