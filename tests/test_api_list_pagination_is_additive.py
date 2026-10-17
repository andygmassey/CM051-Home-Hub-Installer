"""/api/v1/preferences and /api/v1/people: optional limit/cursor/fields.

Walk #29: preferences answered 55 MB (97,173 items) and people 2 MB, unpaginated.
Both are served by vendor/cm041/assistant_api/ical-server.py (/api/v1/people is
aliased to /people in the same handler). This test drives the REAL server as a
subprocess over synthetic data (a stub Qdrant for people, a JSON artefact for
preferences) and pins:
  * ADDITIVE: with no new parameter the response bytes equal a golden captured
    from the pre-change server (tests/fixtures/pagination_golden_*.json);
  * pages cover the whole set in order with no duplicates and no gaps;
  * `fields` projects, alone (whole set) and with a page;
  * a cursor from a different set is refused (409), junk is 400.
Regenerate the goldens ONLY from a server that predates the change:
  GEN_GOLDEN=1 python3 -m pytest tests/test_api_list_pagination_is_additive.py
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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SERVER = ROOT / "vendor/cm041/assistant_api/ical-server.py"
GOLD = ROOT / "tests/fixtures"
TOKEN = "fixture-service-token"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
N_PEOPLE = 23
N_PREFS = 57

PEOPLE = [{"id": "00000000-0000-0000-0000-%012d" % i,
           "payload": {"display_name": "Person %02d Example" % i,
                       "given_name": "Person%02d" % i, "family_name": "Example",
                       "contact_type": "person"}} for i in range(N_PEOPLE)]
PREFS = {"generated_at": "2026-01-01T00:00:00Z", "schema_version": 1,
         "interests": [{"name": "Topic %03d" % i, "domain": ["Music", "Film", "Food"][i % 3],
                        "score": float((i * 7) % 11) + i / 1000.0,
                        "confidence": 0.5, "polarity": "like",
                        "sources": ["fixture"], "evidence": "e%d" % i}
                       for i in range(N_PREFS)]}


class Qdrant(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        if "/people/points/scroll" in self.path:
            off = int(body.get("offset") or 0)
            lim = int(body.get("limit") or 10)
            pts = PEOPLE[off:off + lim]
            nxt = off + lim if off + lim < len(PEOPLE) else None
            out = {"result": {"points": pts, "next_page_offset": nxt}}
        else:
            out = {"result": {}, "results": {"bindings": []}, "head": {"vars": []}}
        data = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="module")
def server():
    edge_port = _free_port()
    edge = ThreadingHTTPServer(("127.0.0.1", edge_port), Qdrant)
    threading.Thread(target=edge.serve_forever, daemon=True).start()
    work = pathlib.Path(tempfile.mkdtemp())
    prof = work / "interest_profile.json"
    prof.write_text(json.dumps(PREFS))
    port = _free_port()
    env = {k: v for k, v in os.environ.items() if "proxy" not in k.lower()}
    env.pop("OSTLER_DB_KEY", None)
    edge_url = "http://127.0.0.1:%d" % edge_port
    env.update({
        "OSTLER_API_PORT": str(port), "OXIGRAPH_URL": edge_url,
        "QDRANT_URL": edge_url, "EMBED_OLLAMA_URL": edge_url,
        "OSTLER_SERVICE_TOKEN": TOKEN, "USER_ID": "fixtureowner",
        "USER_NAME": "Sam Smith", "HOME": str(work), "PWG_HOME": str(work / "pwg"),
        "OSTLER_INTEREST_PROFILE": str(prof), "NO_PROXY": "*",
        "PYTHONDONTWRITEBYTECODE": "1", "WIKI_BASE_URL": "http://wiki.example",
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
        pytest.fail("ical-server did not come up")
    yield url
    proc.kill()
    proc.wait(5)
    edge.shutdown()


def get(url, path):
    req = urllib.request.Request(url + path, headers={"Authorization": "Bearer " + TOKEN})
    try:
        with OPENER.open(req, timeout=15) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def walk(url, path, key, limit, extra=""):
    seen, cursor, pages = [], "", 0
    while True:
        q = "limit=%d%s&cursor=%s" % (limit, extra, cursor or "start")
        code, raw = get(url, path + "?" + q)
        assert code == 200, raw[:200]
        body = json.loads(raw)
        seen.extend(body[key])
        pages += 1
        cursor = body["next_cursor"]
        assert pages < 500
        if not cursor:
            return seen, pages


@pytest.mark.parametrize("path,name", [("/api/v1/people", "people"),
                                       ("/api/v1/preferences", "preferences")])
def test_default_response_is_byte_identical_to_the_golden(server, path, name):
    code, raw = get(server, path)
    assert code == 200
    g = GOLD / ("pagination_golden_%s.json" % name)
    if os.environ.get("GEN_GOLDEN"):
        g.write_bytes(raw)
    assert raw == g.read_bytes()


def test_people_pages_cover_the_set_without_gaps_or_duplicates(server):
    code, raw = get(server, "/api/v1/people")
    whole = json.loads(raw)["people"]
    assert len(whole) == N_PEOPLE
    for limit in (1, 5, 7, N_PEOPLE, 100):
        got, pages = walk(server, "/api/v1/people", "people", limit)
        assert got == whole, limit
        assert pages == -(-N_PEOPLE // limit)
    ids = [p["id"] for p in got]
    assert len(ids) == len(set(ids))


def test_preferences_pages_cover_the_set_without_gaps_or_duplicates(server):
    whole = json.loads(get(server, "/api/v1/preferences")[1])["interests"]
    assert len(whole) == N_PREFS
    for limit in (1, 10, 13, 100):
        got, _ = walk(server, "/api/v1/preferences", "interests", limit)
        assert got == whole, limit
    names = [i["name"] for i in got]
    assert len(names) == len(set(names))


def test_a_limit_alone_on_preferences_keeps_its_old_meaning(server):
    body = json.loads(get(server, "/api/v1/preferences?limit=5")[1])
    assert len(body["interests"]) == 5 and body["count"] == 5
    assert "next_cursor" not in body


def test_fields_projects_alone_and_with_a_page(server):
    whole = json.loads(get(server, "/api/v1/people")[1])["people"]
    body = json.loads(get(server, "/api/v1/people?fields=id,name")[1])
    assert len(body["people"]) == N_PEOPLE
    assert all(set(p) <= {"id", "name"} for p in body["people"])
    assert [p.get("id") for p in body["people"]] == [p.get("id") for p in whole]
    body = json.loads(get(server, "/api/v1/preferences?fields=name&limit=4")[1])
    assert all(list(i) == ["name"] for i in body["interests"])
    assert len(body["interests"]) == 4 and body["next_cursor"]


def test_bad_and_stale_cursors_are_refused(server):
    assert get(server, "/api/v1/people?limit=5&cursor=!!!")[0] == 400
    assert get(server, "/api/v1/people?limit=0")[0] == 400
    assert get(server, "/api/v1/people?limit=999999")[0] == 400
    cur = json.loads(get(server, "/api/v1/people?limit=5")[1])["next_cursor"]
    # a cursor issued for a different set (different filter) is refused
    assert get(server, "/api/v1/preferences?limit=5&cursor=" + cur)[0] in (400, 409)
    pref_cur = json.loads(get(server, "/api/v1/preferences?cursor=start&fields=name&limit=5")[1])["next_cursor"]
    assert get(server, "/api/v1/preferences?domain=Music&limit=5&cursor=" + pref_cur)[0] == 409
