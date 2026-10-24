"""Owner-set under-18 registry: setter, birthday suggestion, fail-loud, privacy.

Product rule (project_minors_flag): a minor is stored and searchable, but never
nudged, never sent to Reminders, never used for facts or suggestions. PWG #434
stamps extra.about_minor from ~/.ostler/minors.json; these tests pin the WRITER.

Synthetic names only (Sam Doe, Jane Smith, Ben Patel).
"""
from __future__ import annotations

import io
import importlib.util
import json
import logging
import os
import re
import socket
import stat
import sys
import threading
import time
import types
import unittest
import urllib.error
import urllib.request
from contextlib import redirect_stderr, redirect_stdout
from datetime import date
from http.server import HTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
SERVER_FILE = HERE.parent / "ical-server.py"


def _install_ostler_security_stub() -> None:
    try:
        import ostler_security  # noqa: F401
        return
    except Exception:
        pass
    import sqlite3 as _sqlite
    pkg = types.ModuleType("ostler_security")
    pkg.__path__ = []
    sys.modules["ostler_security"] = pkg
    database = types.ModuleType("ostler_security.database")
    database.get_db_connection = lambda path, _key, *a, **k: _sqlite.connect(path)
    sys.modules["ostler_security.database"] = database
    posture = types.ModuleType("ostler_security.posture")
    posture.record_posture = lambda *a, **k: None
    sys.modules["ostler_security.posture"] = posture


_install_ostler_security_stub()
spec = importlib.util.spec_from_file_location("ical_server_minors", SERVER_FILE)
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

NS = "https://schema.ostler.ai/ontology#"
TODAY = date(2026, 10, 23)

SAM = "Sam Doe"            # under 18 on TODAY
SAM_URI = NS + "person_samexample01"
SAM_SLUG = server._wiki_slug(SAM)
SAM_PHONE = "+447700900123"
SAM_EMAIL = "sam.example" + "@" + "example.test"
SAM_CARD = "FIXTURE-CARD-SAM"
ADA = "Jane Smith"            # adult control
ADA_URI = NS + "person_adaexample01"
ADA_SLUG = server._wiki_slug(ADA)
NOYEAR = "Tom Jones"         # birthday without a year
NOYEAR_URI = NS + "person_kitexample01"
GONE = "Mum Jones"           # already do-not-suggest (deceased)
GONE_URI = NS + "person_mumexample01"
GONE_SLUG = server._wiki_slug(GONE)
ALL_SECRETS = (SAM, SAM_SLUG, SAM_PHONE, SAM_EMAIL, SAM_CARD)


class FakeStore:
    """Just enough of the graph for the minors code: persons, identifiers,
    birthdays, and suppression records, behind patched _sparql_select/update."""

    def __init__(self):
        self.persons = {
            SAM_URI: {"name": SAM, "bday": "2014-03-02",
                      "ids": [("icloud_contact_uid", SAM_CARD), ("phone", SAM_PHONE),
                              ("email", SAM_EMAIL)]},
            ADA_URI: {"name": ADA, "bday": "1985-06-01", "ids": []},
            NOYEAR_URI: {"name": NOYEAR, "bday": "--05-09", "ids": []},
            GONE_URI: {"name": GONE, "bday": "2015-01-01", "ids": []},
        }
        self.suppressions = {GONE_SLUG: "deceased"}   # slug -> reason
        self.updates = []

    def select(self, q):
        if "SELECT ?reason" in q:
            m = re.search(r"<[^>]*suppression_([a-z0-9-]+)>", q)
            slug = m.group(1)
            if slug in self.suppressions:
                return [{"reason": self.suppressions[slug]}]
            return []
        if "?s a pwg:SuggestionSuppression" in q:
            return [{"slug": s} for s in self.suppressions]
        if "SELECT ?p ?name ?bday" in q:
            return [{"p": u, "name": p["name"], "bday": p["bday"]}
                    for u, p in self.persons.items() if p["bday"]]
        if "SELECT DISTINCT ?t ?v" in q:
            return [{"t": t, "v": v} for u, p in self.persons.items()
                    if "<%s>" % u in q for (t, v) in p["ids"]]
        if "VALUES ?v" in q:
            vals = re.findall(r'"([^"]+)"', q)
            return [{"v": v, "name": p["name"]} for p in self.persons.values()
                    for (_t, v) in p["ids"] if v in vals]
        if "SELECT ?person ?name" in q:
            return [{"person": u, "name": p["name"]} for u, p in self.persons.items()]
        return []

    def update(self, q):
        self.updates.append(q)
        m = re.search(r"DELETE WHERE \{ <[^>]*suppression_([a-z0-9-]+)>", q)
        if m:
            self.suppressions.pop(m.group(1), None)
        if "INSERT DATA" in q:
            slug = re.search(r"suppression_([a-z0-9-]+)>", q).group(1)
            reason = re.search(r'pwg:suppressReason "([^"]*)"', q).group(1)
            self.suppressions[slug] = reason


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        d = Path(self.tmp.name)
        self.reg = d / "dot-ostler" / "minors.json"
        self.dis = d / "dot-ostler" / "state" / "minors-dismissed.json"
        self.env = patch.dict(os.environ, {
            "OSTLER_MINORS_FILE": str(self.reg),
            "OSTLER_MINORS_DISMISSED_FILE": str(self.dis)})
        self.env.start()
        self.store = FakeStore()
        self.ps = [
            patch.object(server, "_sparql_select", self.store.select),
            patch.object(server, "_sparql_update", self.store.update),
            patch.object(server, "_load_people_list_self_uris", lambda: set()),
            patch.object(server, "_load_carded_uris", lambda uris: set(uris)),
        ]
        for p in self.ps:
            p.start()

    def tearDown(self):
        for p in self.ps:
            p.stop()
        self.env.stop()
        self.tmp.cleanup()

    def mode(self, p):
        return stat.S_IMODE(os.stat(p).st_mode)

    def mark(self, slug=SAM_SLUG, minor=True):
        return server.api_people_set_minor(slug, {"minor": minor})


class TestSetter(Base):
    def test_mark_writes_the_registry_mode_0600(self):
        body, status = self.mark()
        self.assertEqual(status, 200, body)
        data = json.loads(self.reg.read_text())
        self.assertEqual(data["version"], 1)
        e = data["minors"][0]
        self.assertEqual((e["slug"], e["names"]), (SAM_SLUG, [SAM]))
        self.assertIn(SAM_PHONE, e["identifiers"])
        self.assertEqual(self.mode(self.reg), 0o600)

    def test_mode_stays_0600_after_a_rewrite_and_dir_is_private(self):
        self.mark()
        self.reg.chmod(0o644)               # something loosened it
        self.mark(minor=False)
        self.assertEqual(self.mode(self.reg), 0o600)
        self.assertEqual(self.mode(self.reg.parent), 0o700)

    def test_no_tmp_file_left_after_a_failed_write(self):
        self.mark()
        before = self.reg.read_bytes()
        with patch.object(server.os, "replace", side_effect=OSError("boom")):
            with self.assertRaises(OSError):
                self.mark(minor=False)
        self.assertEqual(self.reg.read_bytes(), before)
        self.assertEqual([p.name for p in self.reg.parent.iterdir()
                          if ".tmp-" in p.name], [])

    def test_write_is_atomic_via_replace(self):
        calls = []
        real = os.replace
        with patch.object(server.os, "replace",
                          side_effect=lambda a, b: (calls.append((a, b)), real(a, b))[1]):
            self.mark()
        self.assertEqual(len(calls), 1)
        self.assertEqual(Path(calls[0][1]), self.reg)
        self.assertNotEqual(Path(calls[0][0]), self.reg)

    def test_unmark_removes_and_is_idempotent(self):
        self.mark()
        body, status = self.mark(minor=False)
        self.assertEqual((status, body["changed"]), (200, True))
        self.assertEqual(json.loads(self.reg.read_text())["minors"], [])
        body, status = self.mark(minor=False)
        self.assertEqual((status, body["changed"]), (200, False))

    def test_mark_twice_is_idempotent(self):
        self.mark()
        body, _ = self.mark()
        self.assertFalse(body["changed"])
        self.assertEqual(len(json.loads(self.reg.read_text())["minors"]), 1)

    def test_corrupt_registry_refuses_and_leaves_bytes_unchanged(self):
        self.reg.parent.mkdir(parents=True)
        self.reg.write_bytes(b"{not json")
        body, status = self.mark()
        self.assertEqual(status, 503)
        self.assertEqual(body["registry"], "unreadable")
        self.assertEqual(self.reg.read_bytes(), b"{not json")

    def test_wrong_shape_registry_is_unreadable(self):
        self.reg.parent.mkdir(parents=True)
        for bad in (b'[]', b'{"minors": "x"}', b'{"minors": [1]}', b'{"version":1}'):
            self.reg.write_bytes(bad)
            self.assertEqual(self.mark()[1], 503, bad)
            self.assertEqual(server.api_minors_list()[1], 503, bad)

    def test_list_absent_is_ok_and_empty_corrupt_is_503(self):
        self.assertEqual(server.api_minors_list(), ({"registry": "ok", "minors": []}, 200))
        self.mark()
        body, _ = server.api_minors_list()
        self.assertEqual(body["minors"], [{"slug": SAM_SLUG, "name": SAM}])
        self.reg.write_text("{")
        self.assertEqual(server.api_minors_list()[1], 503)

    def test_unknown_slug_is_404_and_bool_is_required(self):
        self.assertEqual(self.mark("nobody-here")[1], 404)
        self.assertFalse(self.reg.exists())
        self.assertEqual(server.api_people_set_minor(SAM_SLUG, {"minor": "yes"})[1], 400)
        self.assertEqual(server.api_people_set_minor(SAM_SLUG, {})[1], 400)
        self.assertEqual(server.api_people_set_minor("Bad Slug", {"minor": True})[1], 400)

    def test_marking_also_suppresses_every_proactive_surface(self):
        self.mark()
        self.assertEqual(self.store.suppressions.get(SAM_SLUG), "minor")

    def test_unmark_clears_only_a_minor_suppression(self):
        self.mark()
        self.mark(minor=False)
        self.assertNotIn(SAM_SLUG, self.store.suppressions)

    def test_deceased_record_is_not_overwritten_or_cleared(self):
        self.store.persons[GONE_URI]["bday"] = "2015-01-01"
        self.mark(GONE_SLUG)
        self.assertEqual(self.store.suppressions[GONE_SLUG], "deceased")
        self.mark(GONE_SLUG, minor=False)
        self.assertEqual(self.store.suppressions[GONE_SLUG], "deceased")

    def test_shared_family_line_is_not_recorded(self):
        landline = "+441134960456"
        self.store.persons[SAM_URI]["ids"].append(("phone", landline))
        self.store.persons[ADA_URI]["ids"].append(("phone", landline))
        self.mark()
        ids = json.loads(self.reg.read_text())["minors"][0]["identifiers"]
        self.assertNotIn(landline, ids)


class TestSuggestions(Base):
    def sug(self):
        return server.api_minors_suggestions(today=TODAY)

    def test_under_18_appears_adult_and_no_year_do_not(self):
        body, status = self.sug()
        self.assertEqual(status, 200)
        slugs = [s["slug"] for s in body["suggestions"]]
        self.assertIn(SAM_SLUG, slugs)
        self.assertNotIn(ADA_SLUG, slugs)
        self.assertNotIn(server._wiki_slug(NOYEAR), slugs)
        self.assertEqual(body["suggestions"][0]["age"], 12)

    def test_age_boundary(self):
        f = server._age_from_birthday
        self.assertEqual(f("2008-10-23", TODAY), 18)   # turns 18 today: not a minor
        self.assertEqual(f("2008-10-24", TODAY), 17)
        self.assertIsNone(f("2027-01-01", TODAY))
        self.assertIsNone(f("--10-23", TODAY))
        self.assertIsNone(f("2014-02-30", TODAY))

    def test_already_do_not_suggest_is_not_asked_about(self):
        slugs = [s["slug"] for s in self.sug()[0]["suggestions"]]
        self.assertNotIn(GONE_SLUG, slugs)

    def test_calling_the_route_never_marks_anyone(self):
        self.sug()
        self.sug()
        self.assertFalse(self.reg.exists(), "suggestion auto-marked")
        self.assertEqual(self.store.updates, [])

    def test_already_marked_is_not_asked_again(self):
        self.mark()
        self.store.suppressions.clear()
        self.assertNotIn(SAM_SLUG, [s["slug"] for s in self.sug()[0]["suggestions"]])

    def test_dismissal_is_remembered_across_a_fresh_process(self):
        body, status = server.api_minors_dismiss(SAM_SLUG)
        self.assertEqual((status, body["dismissed"]), (200, True))
        self.assertEqual(self.mode(self.dis), 0o600)
        self.assertNotIn(SAM_SLUG, [s["slug"] for s in self.sug()[0]["suggestions"]])
        spec2 = importlib.util.spec_from_file_location("ical_server_minors2", SERVER_FILE)
        fresh = importlib.util.module_from_spec(spec2)
        spec2.loader.exec_module(fresh)
        with patch.object(fresh, "_sparql_select", self.store.select), \
             patch.object(fresh, "_load_people_list_self_uris", lambda: set()), \
             patch.object(fresh, "_load_carded_uris", lambda uris: set(uris)):
            out = fresh.api_minors_suggestions(today=TODAY)[0]["suggestions"]
        self.assertNotIn(SAM_SLUG, [s["slug"] for s in out])

    def test_corrupt_registry_is_503_for_suggestions(self):
        self.reg.parent.mkdir(parents=True)
        self.reg.write_text("nope")
        self.assertEqual(self.sug()[1], 503)

    def test_corrupt_dismissed_file_refuses_overwrite(self):
        self.dis.parent.mkdir(parents=True)
        self.dis.write_bytes(b"zzz")
        self.assertEqual(server.api_minors_dismiss(SAM_SLUG)[1], 503)
        self.assertEqual(self.dis.read_bytes(), b"zzz")


class TestFailLoudAtIngest(Base):
    """The Doctor/ingest contract: a corrupt file is 'unreadable' under the
    SAME rule PWG #434 MinorsRegistry.load applies, so ingest halts exactly
    when this module says 503."""

    def test_same_rule_as_pwg_loader(self):
        self.reg.parent.mkdir(parents=True)
        for raw, readable in ((b'{"minors": []}', True), (b'{', False),
                              (b'{"minors": 3}', False), (b'[]', False)):
            self.reg.write_bytes(raw)
            try:
                server._read_minors_entries(self.reg)
                ok = True
            except server.MinorsRegistryUnreadable:
                ok = False
            self.assertEqual(ok, readable, raw)


class TestNothingIsLogged(Base):
    def test_whole_flow_prints_and_logs_nothing_identifying(self):
        buf_o, buf_e = io.StringIO(), io.StringIO()
        stream = io.StringIO()
        h = logging.StreamHandler(stream)
        root = logging.getLogger()
        root.addHandler(h)
        old = root.level
        root.setLevel(logging.DEBUG)
        try:
            with redirect_stdout(buf_o), redirect_stderr(buf_e):
                self.mark()
                server.api_minors_list()
                server.api_minors_suggestions(today=TODAY)
                server.api_minors_dismiss(SAM_SLUG)
                self.reg.write_text("{")
                self.mark()
                server.api_minors_list()
                self.reg.unlink()
                self.mark(minor=False)
        finally:
            root.removeHandler(h)
            root.setLevel(old)
        blob = buf_o.getvalue() + buf_e.getvalue() + stream.getvalue()
        for secret in ALL_SECRETS:
            self.assertNotIn(secret, blob)

    def test_no_logging_call_in_the_minors_code_interpolates_anything(self):
        src = SERVER_FILE.read_text()
        start = src.index("class MinorsRegistryUnreadable")
        end = src.index("def api_people_forget(slug):")
        block = src[start:end]
        # Strip comments/docstring prose that merely mention the words.
        code = "\n".join(l for l in block.splitlines() if not l.strip().startswith("#"))
        self.assertIsNone(re.search(r"\b(print|logging|logger|log)\s*[.(]", code),
                          "the minors code must not print or log at all")
        self.assertNotIn("sys.stderr", code)


class TestRoutesBehindAuth(unittest.TestCase):
    """Real HTTP + real _guard: no token, no answer."""

    TOKEN = "minors-test-token"

    def setUp(self):
        self.saved = {k: os.environ.get(k) for k in (
            "OSTLER_SERVICE_TOKEN", "PWG_SERVICE_TOKEN", "OSTLER_TEST_AUTOAUTH")}
        os.environ.pop("OSTLER_TEST_AUTOAUTH", None)
        os.environ.pop("PWG_SERVICE_TOKEN", None)
        os.environ["OSTLER_SERVICE_TOKEN"] = self.TOKEN
        self.tmp = TemporaryDirectory()
        self.env = patch.dict(os.environ, {
            "OSTLER_MINORS_FILE": str(Path(self.tmp.name) / "m.json"),
            "OSTLER_MINORS_DISMISSED_FILE": str(Path(self.tmp.name) / "d.json")})
        self.env.start()
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        self.port = s.getsockname()[1]
        s.close()
        self.httpd = HTTPServer(("127.0.0.1", self.port), server.Handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        time.sleep(0.1)
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.env.stop()
        self.tmp.cleanup()
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def req(self, method, path, auth=True, body=None):
        r = urllib.request.Request(
            "http://127.0.0.1:%d%s" % (self.port, path), method=method,
            data=body, headers={"Content-Type": "application/json"})
        if auth:
            r.add_header("Authorization", "Bearer " + self.TOKEN)
        try:
            with self.opener.open(r, timeout=5) as resp:
                return resp.status, json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"{}")

    def test_every_route_is_401_without_the_token(self):
        for method, path, body in (
                ("GET", "/api/v1/minors", None),
                ("GET", "/api/v1/minors/suggestions", None),
                ("POST", "/api/v1/people/sam-doe/minor", b'{"minor": true}'),
                ("POST", "/api/v1/people/sam-doe/minor-suggestion/dismiss", b"{}")):
            self.assertEqual(self.req(method, path, auth=False, body=body)[0], 401, path)
        self.assertFalse((Path(self.tmp.name) / "m.json").exists())
        self.assertFalse((Path(self.tmp.name) / "d.json").exists())

    def test_routes_are_reachable_with_the_token(self):
        self.assertEqual(self.req("GET", "/api/v1/minors"),
                         (200, {"registry": "ok", "minors": []}))
        code, _ = self.req("POST", "/api/v1/people/sam-doe/minor-suggestion/dismiss",
                           body=b"{}")
        self.assertEqual(code, 200)
        code, _ = self.req("POST", "/api/v1/people/sam-doe/minor",
                           body=b'{"minor": "x"}')
        self.assertEqual(code, 400)


if __name__ == "__main__":
    unittest.main()
