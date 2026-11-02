"""v1.0.121 walk: 22 CANNOT-RUN, several of them instrument gaps. One regression test per gap.

  host alias      probe.sh box_lan_host: an ssh ALIAS is not a LAN address (3 security probes)
  minted bearer   stored_secret_sweep: config paired_tokens are enc2: ciphertext, so a bearer is minted
  model stub      send_safety FakeModel: /chat/completions in OpenAI shape, and tools that
                  agent.slim_tool_prompt hides from the array but names in tool_help's description
  l3 fixtures     l3_prefetch: uncommon names, so ~8.8k seeded people cannot crowd the control out
  derive re-kick  smart_prefs _derive_until_pass: a tick that only yielded is kicked again
  is_shown        data_conservation: the 110 MB corpus is padded once, not once per call

All data synthetic; the gateway and the model are loopback stubs.
"""
from __future__ import annotations

import http.client
import json
import os
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "scripts/box_walk_probes/lib"
sys.path.insert(0, str(LIB))

import data_conservation  # noqa: E402
import l3_prefetch  # noqa: E402
import send_safety  # noqa: E402
import smart_prefs  # noqa: E402
import stored_secret_sweep as sweep  # noqa: E402


class BoxLanHost(unittest.TestCase):
    def _run(self, **env):
        with tempfile.TemporaryDirectory() as d:
            fake = Path(d, "ssh")
            fake.write_text("#!/bin/sh\nprintf 'user andy\\nhostname 100.64.0.9\\nport 22\\n'\n")
            fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
            e = {"PATH": d + ":/usr/bin:/bin", "OSTLER_BOX_HOST": "andy@macmini16"}
            e.update(env)
            out = subprocess.run(["bash", "-c", '. "%s/probe.sh"; box_lan_host' % LIB], env=e,
                                 capture_output=True, text=True)
            return out.stdout.strip()

    def test_alias_resolves_to_the_address_ssh_connects_to(self):
        self.assertEqual(self._run(), "100.64.0.9")  # the old ${HOST##*@} gave "macmini16"

    def test_explicit_override_wins(self):
        self.assertEqual(self._run(OSTLER_PAIR_PROBE_HOST="192.0.2.7"), "192.0.2.7")

    def test_the_three_probes_use_it(self):
        for name in ("companion_listener_refuses_unauthenticated", "pair_endpoints_refuse_off_window"):
            src = (ROOT / "scripts/box_walk_probes/probes" / (name + ".sh")).read_text()
            self.assertIn('host="$(box_lan_host)"', src, name)
            self.assertNotIn("BOX_HOST##*@", src, name)


class Gateway(BaseHTTPRequestHandler):
    MINTED = "walk-minted-device-token"

    def log_message(self, *a):
        pass

    def _do(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        ok = self.headers.get("Authorization") == "Bearer " + self.MINTED
        if getattr(type(self), "leak", False) and ok:
            body = ("echo " + self.MINTED).encode()
        else:
            body = b"{}" if ok else b'{"error":"Unauthorized"}'
        self.send_response(200 if ok else 401)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = do_DELETE = _do


class MintedBearer(unittest.TestCase):
    def setUp(self):
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), Gateway)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        (d / "config.toml").write_text('[gateway]\npaired_tokens = ["enc2:00ff00ff00ff00ff00ff"]\n')
        (d / "c.json").write_text(json.dumps({"routes": [
            {"method": "GET", "path": "/api/status", "listener": "gateway", "auth": ["device_bearer"]}]}))
        self.cfg, self.contract = str(d / "config.toml"), str(d / "c.json")

    def tearDown(self):
        Gateway.leak = False
        self.srv.shutdown()
        self.tmp.cleanup()
        os.environ.pop("OSTLER_SWEEP_BEARER", None)

    def _sweep(self):
        return sweep.sweep(self.cfg, self.contract, [self.base], timeout=3)

    def test_ciphertext_alone_is_cannot_run_as_before(self):
        res = self._sweep()
        self.assertIn("no paired token was accepted", res["cannot"])

    def test_minted_bearer_runs_the_authenticated_arm_and_passes(self):
        os.environ["OSTLER_SWEEP_BEARER"] = Gateway.MINTED
        res = self._sweep()
        self.assertIsNone(res["cannot"])
        self.assertEqual(res["bearer_label"], "paired_token[minted]")
        self.assertTrue(any(r["auth"] == "paired_bearer" and r["status"] == 200 for r in res["rows"]))
        self.assertEqual(sweep.judge(res)[1], sweep.EX_PASS)

    def test_a_gateway_that_echoes_the_minted_bearer_is_red(self):
        os.environ["OSTLER_SWEEP_BEARER"] = Gateway.MINTED
        Gateway.leak = True
        lines, rc = sweep.judge(self._sweep())
        self.assertEqual(rc, sweep.EX_FAIL, lines)

    def test_a_bearer_the_gateway_refuses_stays_cannot_run(self):
        os.environ["OSTLER_SWEEP_BEARER"] = "not-the-token"
        self.assertIn("no paired token was accepted", self._sweep()["cannot"])


class ModelStub(unittest.TestCase):
    HELP = ("Get a tool's full description. Additional tools available this way: "
            "browser, sessions_send.")

    def _body(self, text, stream=False, hidden=True):
        tools = [{"type": "function", "function": {"name": "memory_recall", "description": "x"}},
                 {"type": "function", "function": {"name": "tool_help", "description": self.HELP if hidden else "x"}}]
        return {"model": "probe-model", "stream": stream, "tools": tools,
                "messages": [{"role": "user", "content": text}]}

    def test_a_tool_named_in_tool_help_is_offered(self):
        m = send_safety.FakeModel()
        self.assertEqual(m._offered(self._body("hi")), {"memory_recall", "tool_help", "browser", "sessions_send"})
        self.assertNotIn("sessions_send", m._offered(self._body("hi", hidden=False)))

    def _post(self, body):
        m = send_safety.FakeModel()
        m.start()
        try:
            c = http.client.HTTPConnection("127.0.0.1", m.port, timeout=5)
            c.request("POST", "/chat/completions", json.dumps(body), {"Content-Type": "application/json"})
            r = c.getresponse()
            return r.status, r.read().decode(), m
        finally:
            m.stop()

    def test_chat_completions_non_stream_carries_the_scripted_send(self):
        st, raw, m = self._post(self._body("SENDREQ-zqabc1 please send"))
        msg = json.loads(raw)["choices"][0]["message"]
        self.assertEqual(st, 200)
        call = msg["tool_calls"][0]["function"]
        self.assertEqual(call["name"], "sessions_send")
        args = json.loads(call["arguments"])
        self.assertIn("zqabc1", args["message"])
        self.assertEqual(args["recipient"], send_safety.TARGET)
        self.assertTrue(any(r["offered_send"] for r in m.requests))

    def test_the_owner_request_sends_to_the_owners_own_sink(self):
        _, raw, _ = self._post(self._body("OWNREQ-zqabc3 please save"))
        args = json.loads(json.loads(raw)["choices"][0]["message"]["tool_calls"][0]["function"]["arguments"])
        self.assertEqual(args["recipient"], send_safety.OWNER)
        self.assertEqual(args["session_id"], "probe-sink-zqabc3")

    def test_a_stub_serving_only_the_ollama_shape_gives_the_daemon_nothing(self):
        m = send_safety.FakeModel(("ollama",))
        m.start()
        try:
            c = http.client.HTTPConnection("127.0.0.1", m.port, timeout=5)
            c.request("POST", "/chat/completions", json.dumps(self._body("SENDREQ-zqabc4 go")), {"Content-Type": "application/json"})
            body = json.loads(c.getresponse().read().decode())
        finally:
            m.stop()
        self.assertNotIn("choices", body)
        self.assertEqual(m.requests, [])

    def test_chat_completions_stream_ends_with_done_and_tool_calls(self):
        st, raw, _ = self._post(self._body("SENDREQ-zqabc2 please send", stream=True))
        self.assertTrue(raw.rstrip().endswith("data: [DONE]"))
        frames = [json.loads(l[6:]) for l in raw.splitlines() if l.startswith("data: {")]
        self.assertEqual(frames[0]["choices"][0]["delta"]["tool_calls"][0]["function"]["name"], "sessions_send")
        self.assertEqual(frames[-1]["choices"][0]["finish_reason"], "tool_calls")


class L3Fixtures(unittest.TestCase):
    def test_names_are_uncommon_and_distinct(self):
        names = [s["name"] for s in l3_prefetch.SUBJECTS.values()]
        self.assertEqual(len(set(names)), 2)
        for n in names:
            self.assertNotIn(n, ("Jane Doe", "John Smith"))


class DeriveRekick(unittest.TestCase):
    def _drive(self, outcomes):
        seq, kicks, now = list(outcomes), [], [0.0]

        def wait(prev, budget):
            o = seq.pop(0)
            return o == "written", {"outcome": o}

        def kick():
            kicks.append(1)
            return 0, ""

        def nap(s):
            now[0] += s

        res = smart_prefs._derive_until_pass("p", 240, 900, kick=kick, wait=wait,
                                             clock=lambda: now[0], nap=nap)
        return res, len(kicks)

    def test_yielded_twice_then_a_pass_is_ran_after_seed(self):
        (ran, st), kicks = self._drive(["yielded", "deferred", "written"])
        self.assertTrue(ran)
        self.assertEqual(kicks, 2)

    def test_a_tick_that_never_passes_stops_at_the_total_budget(self):
        res, kicks = self._drive(["yielded"] * 50)
        self.assertFalse(res[0])
        self.assertLess(kicks, 50)

    def test_other_outcomes_are_not_kicked_again(self):
        (ran, st), kicks = self._drive(["not_written"])
        self.assertFalse(ran)
        self.assertEqual(kicks, 0)


class TaintedRelease(unittest.TestCase):
    """A release the daemon logged, followed by the tool itself erroring, is the instrument
    unable to see a send (CANNOT-RUN), not 'the yes released nothing' (FAIL). A release that
    never happened stays FAIL."""

    def _cap(self, snippet, released):
        cap = send_safety._good("tainted")
        tok = cap["toks"]["subject"]
        rs = [r for r in cap["model"]["send_results"] if r["label"] == tok]
        cap["model"]["send_results"].append(dict(rs[0], kind="ok", snippet=snippet))
        # the second "yes" re-emits the call and gets a different (later) result
        cap["model"]["send_results"].append(dict(rs[0], kind="denied", snippet="Denied: one-shot"))
        cap["sink"][tok] = 0
        for at in ("after_yes", "after_second_yes"):
            cap["sink_at"][at][tok] = 0
        cap["log"]["released"] = released
        return cap

    def test_tool_error_after_a_logged_release_is_cannot_run(self):
        v = send_safety.judge_tainted(self._cap("Error executing sessions_send: Channel 'imessage' not found.", 1))
        self.assertEqual(v.code(), send_safety.EX_CANNOT, v.rows)

    def test_no_logged_release_and_no_send_is_still_fail(self):
        v = send_safety.judge_tainted(self._cap("Error executing sessions_send: Channel 'imessage' not found.", 0))
        self.assertEqual(v.code(), send_safety.EX_FAIL, v.rows)

    def test_a_release_with_a_clean_tool_result_and_no_send_is_still_fail(self):
        v = send_safety.judge_tainted(self._cap("Poll created on 'imessage'", 1))
        self.assertEqual(v.code(), send_safety.EX_FAIL, v.rows)


class ConservationBudget(unittest.TestCase):
    def test_default_budget_covers_the_measured_collect(self):
        src = (ROOT / "scripts/box_walk_probes/probes/data_conservation.sh").read_text()
        self.assertIn('OSTLER_CONSERVATION_COLLECT_BUDGET_S:-1800}', src)  # measured 1196s on the 8.8k-person box


class TickWaitBudget(unittest.TestCase):
    def test_default_hold_outlasts_a_measured_full_tick(self):
        src = (ROOT / "scripts/box_walk_probes/lib/probe.sh").read_text()
        self.assertIn('OSTLER_PROBE_TICK_WAIT_S:-1800}', src)  # tick measured ~1150s; 900 ended CANNOT-RUN mid-tick


class DoctorUnits(unittest.TestCase):
    """v1.0.121 "whatsapp|people shown 41211 vs stored 314": the Doctor's whatsapp item_count is
    41,211 MESSAGES; the row counts PEOPLE. A count in another unit must not be an unscoped fact."""
    SOURCES = {"sources": [
        {"source": "whatsapp", "item_count": 41211, "last_run_count": 42305, "item_unit": "messages"},
        {"source": "people", "item_count": 8794, "item_unit": None},
        {"source": "contacts", "item_count": 2393, "item_unit": "contacts"},
        {"source": "imessage", "item_count": 86969, "last_run_count": 196283, "item_unit": "messages"}]}

    def _collect(self):
        orig = data_conservation._http
        data_conservation._http = lambda *a, **k: (200, self.SOURCES)
        try:
            facts, meta = {}, {}
            data_conservation.collect_doctor(facts, meta, {})
            return facts
        finally:
            data_conservation._http = orig

    def test_a_messages_count_is_not_the_unscoped_item_count(self):
        f = self._collect()
        self.assertNotIn("doctor.whatsapp.item_count", f)
        self.assertEqual(f["doctor.whatsapp.item_count.messages"], 41211)

    def test_people_and_contacts_counts_stay_unscoped(self):
        f = self._collect()
        self.assertEqual((f["doctor.people.item_count"], f["doctor.contacts.item_count"]), (8794, 2393))

    def test_last_run_count_is_untouched_for_the_imessage_row(self):
        self.assertEqual(self._collect()["doctor.imessage.last_run_count"], 196283)

    def test_the_whatsapp_people_row_is_not_measured_not_inflated(self):
        exp = {"rows": [{"id": "whatsapp/people", "source": "whatsapp", "category": "people", "unit": "people",
                         "facts": {"in": "i", "stored": "s", "shown": "doctor.whatsapp.item_count"}}]}
        facts = dict(self._collect(), i=314, s=314)
        rows, counts = data_conservation.adjudicate(exp, facts)
        self.assertEqual(counts["INFLATED"], 0, rows)
        self.assertEqual(rows[0]["verdict"], "NOT-MEASURED", rows)
        facts["doctor.whatsapp.item_count"] = 41211   # the control: the unscoped fact WOULD be INFLATED
        rows, counts = data_conservation.adjudicate(exp, facts)
        self.assertEqual(counts["INFLATED"], 1, rows)


class PeopleRowCountsEveryWriter(unittest.TestCase):
    def test_in_sums_both_writers_of_the_people_collection(self):
        exp = json.load(open(ROOT / "scripts/box_walk_probes/fixtures/data_conservation/expected.json"))
        for prof in exp["profiles"].values():
            row = [r for r in prof["rows"] if r.get("id") == "people/all"][0]
            self.assertEqual(row["facts"]["in"], ["hyd.people.item_count", "hyd.contacts.item_count"])


class IsShown(unittest.TestCase):
    PAGES = ["alpha beta gamma delta", "the quick brown fox", "x" * 40 + " omega"]

    def _corpus(self):
        return " \n ".join(self.PAGES)

    def test_same_answers_as_the_naive_check(self):
        c = self._corpus()
        for t in ("alpha beta", "Beta, GAMMA!", "gamma delta the", "quick brown fox", "fox", "omega", "ega",
                  "alpha gamma", "", "   ", "absent words here", "brown fox omega"):
            n = data_conservation._norm(t)
            want = bool(n) and (" " + n + " ") in (" " + c + " ")
            self.assertEqual(data_conservation.is_shown(t, c), want, t)

    def test_the_corpus_is_not_copied_per_call(self):
        import time
        big = " \n ".join(["lorem ipsum dolor sit amet " * 40] * 20000)  # ~21 MB
        t0 = time.time()
        for i in range(3000):
            data_conservation.is_shown("zzabsent%d word" % i, big)
        self.assertLess(time.time() - t0, 1.5)  # the per-call " " + corpus + " " took > 10 s here


if __name__ == "__main__":
    unittest.main()
