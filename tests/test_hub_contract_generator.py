"""The hub contract generator and checker: they must be able to go RED.

Hermetic (no gateway checkout needed). The freshness of the committed
hub_contract.yaml is a separate CI job, because it needs the ostler-assistant
source; this file proves the generator and the checker are not tautologies.
"""
import importlib.util
import json
import os
import subprocess
import sys
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load(name, rel):
    spec = importlib.util.spec_from_file_location(name, os.path.join(REPO, rel))
    m = importlib.util.module_from_spec(spec)
    sys.modules[name] = m
    spec.loader.exec_module(m)
    return m


gen = _load("gen_hub_contract", "scripts/gen_hub_contract.py")
chk = _load("hub_contract_check", "scripts/hub_contract_check.py")
with open(os.path.join(REPO, gen.ICAL), encoding="utf-8") as _f:
    ICAL = _f.read()
with open(os.path.join(REPO, gen.DEFAULT_OUT), encoding="utf-8") as _f:
    CONTRACT = json.load(_f)


class IcalExtraction(unittest.TestCase):
    def routes(self, text):
        r, _ = gen.extract_ical(text)
        return {(x["method"], x["path"]): x for x in r}

    def test_real_routes_and_auth(self):
        r = self.routes(ICAL)
        self.assertEqual(r[("POST", "/api/v1/conversation/process")]["auth"], ["service_token"])
        self.assertEqual(r[("GET", "/health")]["auth"], ["none"])
        self.assertIn(("GET", "/api/v1/people/search"), r)  # versioned alias of /people/search

    def test_a_new_route_appears(self):
        mutated = ICAL.replace('if parsed.path == "/api/v1/employer":',
                               'if parsed.path == "/api/v1/zz_new":\n            pass\n'
                               '        if parsed.path == "/api/v1/employer":', 1)
        self.assertNotEqual(mutated, ICAL)
        self.assertIn(("GET", "/api/v1/zz_new"), self.routes(mutated))

    def test_body_limit_change_is_seen(self):
        mutated = ICAL.replace('"MAX_POST_BYTES", "1048576"', '"MAX_POST_BYTES", "65536"')
        self.assertNotEqual(mutated, ICAL)
        r = self.routes(mutated)
        self.assertEqual(r[("POST", "/api/v1/ingest/ios")]["body_limit_bytes"], 65536)

    def test_unparsable_source_is_cannot_run_not_empty(self):
        with self.assertRaises(Exception):
            gen.extract_ical("class Handler:\n    pass\n")


class Checker(unittest.TestCase):
    def setUp(self):
        self.c = chk.HubContract(json.loads(json.dumps(CONTRACT)))

    def call(self, **kw):
        base = dict(method="GET", url="http://127.0.0.1:8090/api/v1/people/search?q=x",
                    headers={"Authorization": "Bearer t"}, token_source="service_token")
        base.update(kw)
        v, _ = self.c.check_call(base)
        return [x[0] for x in v]

    def test_green(self):
        self.assertEqual(self.call(), [])

    def test_no_bearer(self):
        self.assertEqual(self.call(headers={}), ["AUTH_MISSING"])

    def test_wrong_credential(self):
        self.assertEqual(self.call(token_source="device_token"), ["AUTH_WRONG_CREDENTIAL"])

    def test_wrong_port_and_method_and_path(self):
        self.assertEqual(self.call(url="http://127.0.0.1:8089/ws/chat"), ["PORT_MISMATCH"])
        self.assertEqual(self.call(method="DELETE"), ["METHOD_MISMATCH"])
        self.assertEqual(self.call(url="http://127.0.0.1:8090/api/v1/nope"), ["ROUTE_MISSING"])

    def test_body_limits(self):
        kw = dict(method="POST", url="http://127.0.0.1:8090/api/v1/conversation/process",
                  body_keys=["transcript"])
        self.assertEqual(self.call(body_bytes=10, **kw), [])
        self.assertEqual(self.call(body_bytes=5_000_000, **kw), ["BODY_TOO_LARGE"])
        self.assertEqual(self.call(body_bytes=None, **kw), ["BODY_UNBOUNDED"])

    def test_required_request_field_and_absent_response_field(self):
        kw = dict(method="POST", url="http://127.0.0.1:8090/api/v1/conversation/process", body_bytes=10)
        self.assertEqual(self.call(body_keys=["metadata"], **kw), ["REQUEST_FIELD_MISSING"])
        self.assertEqual(self.call(body_keys=["transcript"], reads=["nope"], **kw), ["RESPONSE_FIELD_ABSENT"])

    def test_tampered_copy_is_refused(self):
        import tempfile
        d = tempfile.mkdtemp()
        src = os.path.join(REPO, gen.DEFAULT_OUT)
        import hashlib
        with open(src, "rb") as f:
            good = f.read()
        with open(os.path.join(d, "hub_contract.yaml"), "wb") as f:
            f.write(good + b" ")
        with open(os.path.join(d, "hub_contract.pin.json"), "w") as f:
            json.dump({"contract_sha256": hashlib.sha256(good).hexdigest()}, f)
        with self.assertRaises(AssertionError):
            chk.HubContract.load(os.path.join(d, "hub_contract.yaml"))

    def test_js_port_agrees(self):
        probes = [
            dict(method="GET", url="http://127.0.0.1:8090/api/v1/people/search?q=x", headers={}, token_source="service_token"),
            dict(method="POST", url="http://localhost:8089/api/safari/save", headers={"Authorization": "Bearer x"}, token_source="extension_token"),
            dict(method="POST", url="http://127.0.0.1:8090/api/v1/conversation/process", headers={"Authorization": "Bearer x"},
                 token_source="device_token", body_bytes=None, body_keys=[], reads=["job_id", "zz"]),
        ]
        js = ("const {HubContract}=require(process.argv[1]);"
              "const c=new HubContract(JSON.parse(require('fs').readFileSync(process.argv[2])));"
              "const ps=JSON.parse(process.argv[3]);"
              "console.log(JSON.stringify(ps.map(p=>c.checkCall(p).violations.map(v=>v[0]))));")
        try:
            out = subprocess.check_output(["node", "-e", js, os.path.join(REPO, "scripts/hub_contract_check.js"),
                                           os.path.join(REPO, gen.DEFAULT_OUT), json.dumps(probes)], text=True)
        except FileNotFoundError:
            self.fail("node is required to prove the JS checker agrees with the Python one")
        want = [[x[0] for x in self.c.check_call(p)[0]] for p in probes]
        self.assertEqual(json.loads(out), want)


class Shape(unittest.TestCase):
    def test_contract_has_every_listener_and_unique_ids(self):
        ls = {r["listener"] for r in CONTRACT["routes"]}
        self.assertEqual(ls, {"gateway", "doctor", "ical", "store_qdrant", "store_oxigraph"})
        ids = [r["id"] for r in CONTRACT["routes"]]
        self.assertEqual(len(ids), len(set(ids)))

    def test_no_server_line_numbers_or_hashes(self):
        # A hash or line number would make every client pin stale on unrelated edits.
        self.assertNotIn("sources", CONTRACT)
        for r in CONTRACT["routes"]:
            self.assertNotRegex(r["source"], r":\d+$")


class CompanionPortsPerRoute(unittest.TestCase):
    """8443 serves ONLY companion_route_table (ostler-assistant v1.0.108).
    A route the table does not mount must not carry the companion port, so a
    contract that still lists [8000, 8443] for it is STALE and reds
    contract-is-current."""

    TABLE = (
        "pub(crate) fn companion_route_table() -> Vec<CompanionRoute> {\n"
        "    vec![\n"
        '        r("/health", &["GET"], false, get(handle_health)),\n'
        "        // r(\"/admin/paircode\", &[\"GET\"], false, get(x)),\n"
        '        r("/api/v1/people/{*rest}", &["GET", "POST"], false, get(a).post(b)),\n'
        "    ]\n}\n"
        "pub(crate) fn build_companion_router(state: AppState) -> Router {}\n"
    )

    def test_table_is_parsed_per_method_and_comments_are_ignored(self):
        got = gen.companion_allowlist(self.TABLE)
        self.assertEqual(got, {("GET", "/health"), ("GET", "/api/v1/people/{rest}"),
                               ("POST", "/api/v1/people/{rest}")})

    def test_a_route_absent_from_the_table_is_8000_only(self):
        c = gen.companion_allowlist(self.TABLE)
        self.assertEqual(gen.gateway_ports("GET", "/admin/paircode", c, 8443), [8000])
        self.assertEqual(gen.gateway_ports("POST", "/health", c, 8443), [8000])
        self.assertEqual(gen.gateway_ports("GET", "/health", c, 8443), [8000, 8443])

    def test_a_stale_both_ports_entry_differs_from_the_regenerated_one(self):
        c = gen.companion_allowlist(self.TABLE)
        stale = {"method": "GET", "path": "/admin/paircode", "ports": [8000, 8443]}
        regen = dict(stale, ports=gen.gateway_ports("GET", "/admin/paircode", c, 8443))
        self.assertNotEqual(json.dumps(stale, sort_keys=True), json.dumps(regen, sort_keys=True))

    def test_no_table_means_the_legacy_shared_router(self):
        self.assertIsNone(gen.companion_allowlist("fn build_gateway_router() {}"))
        self.assertEqual(gen.gateway_ports("GET", "/admin/paircode", None, 8443), [8000, 8443])

    def test_a_table_with_no_entries_is_cannot_run_not_legacy(self):
        empty = ("fn companion_route_table() -> Vec<CompanionRoute> { vec![] }\n"
                 "fn build_companion_router() {}\n")
        with self.assertRaises(gen.CannotRun):
            gen.companion_allowlist(empty)


if __name__ == "__main__":
    unittest.main()
