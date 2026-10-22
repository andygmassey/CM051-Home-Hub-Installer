"""The three CM041 changes this re-vendor grafts, driven through the REAL
vendored ical-server (vendor/cm041/assistant_api/ical-server.py) as a
subprocess, with only the stores stubbed:

  * CM041 #231: /api/v1/meeting/upcoming reads the calendar IN-PROCESS. The
    brief's default calendar URL is not this server, so a server that still
    HTTP-calls /calendar for the brief degrades; the in-process read does not.
    (An explicitly set CALENDAR_API_URL keeps the HTTP read; that seam is
    covered by tests/test_meeting_brief_real_hub.py.)
    With no calendar store at all it must say degraded (never an empty 200).
  * CM041 #232: /api/v1/commitments serves a per-row privacy_level
    (tagged -> that level, untagged -> L2, unparseable -> L3).
  * CM041 #215: GET /api/v1/preferences/derived serves the derived graph and
    degrades loudly when the graph is empty.
  * CM041 #233/#234: the derived route's top-N is round-robin by category;
    no ?tier= reads broad and falls back to all on a pre-tier graph
    (tier_fallback), an explicit ?tier=broad is strict, a bogus tier is 400.
  * CM041 #235: an L3 or unparseable derived node is never served; a served
    node carries privacy_level.

Synthetic data only (example.com, a placeholder owner id). Red on the
pre-re-vendor tree: the derived route 404s, commitments carry no
privacy_level, and meeting/upcoming degrades on the brief's HTTP calendar read.
"""
from __future__ import annotations

import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SERVER = ROOT / "vendor/cm041/assistant_api/ical-server.py"
TOKEN = "fixture-service-token"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

STATE = {"derived": "one"}  # "one" | "empty"


def _bindings(rows):
    return {"head": {"vars": sorted({k for r in rows for k in r})},
            "results": {"bindings": [{k: {"type": "literal", "value": v} for k, v in r.items()}
                                     for r in rows]}}


class Oxigraph(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        q = (self.rfile.read(n) or b"").decode("utf-8", "replace")
        rows = []
        if "DerivedPreference" in q and STATE["derived"] == "one":
            rows = [{"s": "urn:example:derived/1", "dimension": "genre",
                     "subject": "synthetic jazz", "strength": "0.8",
                     "confidence": "0.9", "intensity": "keen"}]
        elif "DerivedPreference" in q and STATE["derived"] == "tiered13":
            rows = _tiered13_rows()
        elif "DerivedPreference" in q and STATE["derived"] == "levels":
            # The stub ignores SPARQL FILTERs, so this exercises the reader's
            # own refusal of an L3 or unparseable row.
            base = {"dimension": "genre", "strength": "0.8", "intensity": "keen",
                    "tier": "broad", "category": "music"}
            rows = [dict(base, s="urn:example:d/l2", subject="level two item",
                         confidence="0.9", privacy="L2"),
                    dict(base, s="urn:example:d/l3", subject="level three item",
                         confidence="0.95", privacy="L3"),
                    dict(base, s="urn:example:d/bad", subject="unparseable level item",
                         confidence="0.94", privacy="not-a-level")]
        elif "derivedFrom" in q:
            rows = [{"title": "example album"}]
        elif "OutstandingTodo" in q:
            base = {"owner": "user", "status": "open", "deadline": "2026-12-01",
                    "source": "2026-10-01", "createdAt": "2026-10-01T00:00:00Z"}
            rows = [dict(base, todo="urn:example:t1", action="tagged L1", plevel="L1"),
                    dict(base, todo="urn:example:t2", action="untagged"),
                    dict(base, todo="urn:example:t3", action="garbage", plevel="not-a-level")]
        data = json.dumps(_bindings(rows)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/sparql-results+json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST


# 13 categories. "tv" holds the ten most confident rows, so a list ranked by
# confidence alone is all "tv"; every other category holds one weaker row.
# Every row is tier "broad".
CAT13 = ["tv", "films", "music", "books", "food", "travel", "sport", "art",
         "games", "podcasts", "news", "fashion", "science"]


def _tiered13_rows():
    rows = []
    for i in range(10):
        rows.append({"s": "urn:example:d/tv%d" % i, "dimension": "genre",
                     "subject": "tv item %d" % i, "strength": "0.9",
                     "confidence": "%.3f" % (0.99 - i * 0.001),
                     "intensity": "keen", "category": "tv", "tier": "broad"})
    for j, cat in enumerate(CAT13[1:]):
        rows.append({"s": "urn:example:d/%s" % cat, "dimension": "genre",
                     "subject": "%s item" % cat, "strength": "0.5",
                     "confidence": "%.3f" % (0.8 - j * 0.01),
                     "intensity": "casual", "category": cat, "tier": "broad"})
    return rows


LABEL_CATEGORY = {r["subject"]: r["category"] for r in _tiered13_rows()}


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _start(fda_dir):
    edge_port = _free_port()
    edge = ThreadingHTTPServer(("127.0.0.1", edge_port), Oxigraph)
    threading.Thread(target=edge.serve_forever, daemon=True).start()
    work = pathlib.Path(tempfile.mkdtemp())
    port = _free_port()
    env = {k: v for k, v in os.environ.items() if "proxy" not in k.lower()}
    env.pop("OSTLER_DB_KEY", None)
    # No CALENDAR_API_URL: the brief's default HTTP target is 127.0.0.1:8090,
    # which is NOT this server (it listens on a free port), so only an
    # in-process read of this server's calendar can succeed.
    env.pop("CALENDAR_API_URL", None)
    edge_url = "http://127.0.0.1:%d" % edge_port
    env.update({
        "OSTLER_API_PORT": str(port), "OXIGRAPH_URL": edge_url,
        "QDRANT_URL": edge_url, "EMBED_OLLAMA_URL": edge_url,
        "OSTLER_SERVICE_TOKEN": TOKEN, "USER_ID": "fixtureowner",
        "USER_NAME": "Sam Smith", "HOME": str(work), "PWG_HOME": str(work / "pwg"),
        "NO_PROXY": "*", "PYTHONDONTWRITEBYTECODE": "1",
        "WIKI_BASE_URL": "http://wiki.example",
        "OSTLER_FDA_IMPORT_DIR": str(fda_dir),
        "ICAL_SCRIPT": str(work / "no-such-ical-script"),
        "PYTHONPATH": os.pathsep.join([str(ROOT / "vendor/cm041"), str(ROOT / "vendor")]),
    })
    proc = subprocess.Popen([sys.executable, str(SERVER)], env=env, cwd=str(SERVER.parent),
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    url = "http://127.0.0.1:%d" % port
    for _ in range(150):
        if proc.poll() is not None:
            pytest.fail("ical-server exited: " + proc.stderr.read().decode()[-800:])
        try:
            OPENER.open(url + "/health", timeout=1).read()
            break
        except Exception:
            time.sleep(0.1)
    else:
        proc.kill()
        pytest.fail("ical-server did not come up")
    return url, proc, edge


def _stop(proc, edge):
    proc.kill()
    proc.wait(5)
    edge.shutdown()


@pytest.fixture(scope="module")
def server():
    fda = pathlib.Path(tempfile.mkdtemp())
    soon = datetime.now().astimezone() + timedelta(minutes=20)
    (fda / "calendar_events.json").write_text(json.dumps([{
        "title": "Synthetic sync", "start_date": soon.isoformat(timespec="seconds"),
        "end_date": (soon + timedelta(minutes=30)).isoformat(timespec="seconds"),
        "attendees": ["attendee@example.com"], "calendar_name": "Work"}]))
    url, proc, edge = _start(fda)
    yield url
    _stop(proc, edge)


@pytest.fixture(scope="module")
def server_without_calendar():
    url, proc, edge = _start(pathlib.Path(tempfile.mkdtemp()))
    yield url
    _stop(proc, edge)


def get(url, path, timeout=15):
    req = urllib.request.Request(url + path, headers={"Authorization": "Bearer " + TOKEN})
    try:
        with OPENER.open(req, timeout=timeout) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, None


def test_meeting_upcoming_reads_the_calendar_in_process(server):
    t0 = time.monotonic()
    code, body = get(server, "/api/v1/meeting/upcoming?within_minutes=60", timeout=10)
    assert code == 200
    assert not body.get("degraded"), body
    assert time.monotonic() - t0 < 10


def test_meeting_upcoming_says_degraded_when_no_calendar_answers(server_without_calendar):
    code, body = get(server_without_calendar, "/api/v1/meeting/upcoming?within_minutes=60")
    assert code == 200
    assert body.get("degraded") is True, body
    assert "calendar unavailable" in (body.get("reason") or ""), body


def test_commitments_carry_a_per_row_privacy_level(server):
    code, body = get(server, "/api/v1/commitments")
    assert code == 200, body
    levels = {c["action"]: c.get("privacy_level") for c in body["commitments"]}
    assert levels == {"tagged L1": "L1", "untagged": "L2", "garbage": "L3"}, levels


def test_derived_preferences_route_serves_the_graph(server):
    STATE["derived"] = "one"
    code, body = get(server, "/api/v1/preferences/derived")
    assert code == 200
    assert body["degraded"] is False, body
    assert [i["label"] for i in body["items"]] == ["synthetic jazz"]
    assert body["items"][0]["because"] == ["example album"]


def test_derived_preferences_route_degrades_on_an_empty_graph(server):
    STATE["derived"] = "empty"
    try:
        code, body = get(server, "/api/v1/preferences/derived")
    finally:
        STATE["derived"] = "one"
    assert code == 200
    assert body["items"] == [] and body["degraded"] is True, body
    assert body.get("cannot_check"), body


def _derived(server, query=""):
    return get(server, "/api/v1/preferences/derived" + query)


def test_derived_default_falls_back_to_all_on_a_pre_tier_graph(server):
    # CM041 #234: the "one" fixture row carries no tier (a graph written before
    # tiers). No ?tier= reads broad, finds nothing, and serves all, saying so.
    STATE["derived"] = "one"
    code, body = _derived(server)
    assert code == 200, body
    assert body["degraded"] is False and body["items"], body
    assert body.get("tier") == "all" and body.get("tier_fallback") is True, body


def test_derived_explicit_broad_is_strict_on_a_pre_tier_graph(server):
    STATE["derived"] = "one"
    code, body = _derived(server, "?tier=broad")
    assert code == 200, body
    assert body["items"] == [] and body["degraded"] is True, body
    assert "tier_fallback" not in body, body


def test_derived_bogus_tier_is_a_400(server):
    code, _ = _derived(server, "?tier=bogus")
    assert code == 400


def test_derived_top_n_is_round_robin_by_category(server):
    # CM041 #233: with 13 categories and one of them holding the ten most
    # confident rows, no category may take more than ceil(N/3) of the top N.
    STATE["derived"] = "tiered13"
    try:
        for n in (8, 13):
            code, body = _derived(server, "?limit=%d&tier=all" % n)
            assert code == 200 and body["degraded"] is False, body
            cats = [LABEL_CATEGORY[i["label"]] for i in body["items"]]
            assert len(cats) == n, cats
            worst = max(cats.count(c) for c in set(cats))
            assert worst <= -(-n // 3), (n, cats)
    finally:
        STATE["derived"] = "one"


def test_derived_never_serves_an_l3_or_unparseable_node(server):
    STATE["derived"] = "levels"
    try:
        code, body = _derived(server, "?tier=all")
    finally:
        STATE["derived"] = "one"
    assert code == 200 and body["degraded"] is False, body
    assert [i["label"] for i in body["items"]] == ["level two item"], body
    assert body["items"][0].get("privacy_level") == "L2", body
