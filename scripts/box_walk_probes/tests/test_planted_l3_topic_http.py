"""HTTP-level planted-topic test. A topic whose only visible text is an L3 mention
must be absent from GET /api/v1/topics and GET /api/v1/topics/<slug>/mentions when
the request carries the service token; without the token both routes must be 401.

The vendored ical-server is started in-process on a free 127.0.0.1 port with a
SYNTHETIC service token set in the environment. The moat HTTP harness lives only on
#3565, so the small server wrapper is local to this file (the same HTTPServer +
server.Handler shape). Nothing under vendor/ is edited.
"""
import importlib.util, json, os, socket, sys, threading, unittest, urllib.error, urllib.request
from http.server import HTTPServer
from pathlib import Path
from unittest.mock import patch

# The reader tree under test (see test_planted_l3_topic_label.py for the default).
ROOT = Path(os.environ.get("CM051_READER_TREE") or Path(__file__).resolve().parents[3])
sys.path.insert(0, str(ROOT / "vendor"))            # ostler_security, pwg_privacy
API = ROOT / "vendor" / "cm041" / "assistant_api"
sys.path.insert(0, str(API))
TOKEN = "synthetic-probe-token"                     # not a credential; test-only
os.environ["OSTLER_SERVICE_TOKEN"] = TOKEN           # set before the server module reads it
_spec = importlib.util.spec_from_file_location("ical_server_http_under_test", API / "ical-server.py")
server = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(server)

PLANT_LABEL = "Qzvorvex mirrion"
PLANT_SLUG = "qzvorvex-mirrion"
CTRL_LABEL = "Control topic plum"
CTRL_SLUG = "control-topic-plum"
ROWS = [
    {"topic": "pwg:topic_plant", "slug": PLANT_SLUG, "label": PLANT_LABEL,
     "m": "pwg:tm_p1", "w": "9", "mpriv": "L3", "conv": "pwg:batch_p1", "cpriv": "L2"},
    {"topic": "pwg:topic_ctrl", "slug": CTRL_SLUG, "label": CTRL_LABEL,
     "m": "pwg:tm_c1", "w": "2", "mpriv": "L2", "conv": "pwg:batch_c1", "cpriv": "L2"},
]


def fake(q):
    if "?topic a pwg:ConversationTopic .\n" in q:
        return ROWS
    if 'pwg:topicSlug "' in q:
        slug = q.split('pwg:topicSlug "', 1)[1].split('"', 1)[0]
        return [{"label": r["label"], "conversation": r["conv"], "weight": r["w"], "channel": "",
                 "sender": "", "date": "2026-01-01", "mpriv": r["mpriv"], "cpriv": r["cpriv"]}
                for r in ROWS if r["slug"] == slug]
    return []


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def get(port, path, token=None):
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}")
    if token is not None:
        req.add_header("X-Ostler-Service", token)
    try:
        with _OPENER.open(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read() or b"{}")


class PlantedTopicHTTP(unittest.TestCase):
    def setUp(self):
        self.port = _free_port()
        self.httpd = HTTPServer(("127.0.0.1", self.port), server.Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()
        self.patch = patch.object(server, "_sparql_select", side_effect=fake)
        self.patch.start()

    def tearDown(self):
        self.patch.stop()
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=2)

    def test_with_token_l3_withheld_and_control_served(self):
        # THE TOKEN IS PASSED HERE. The mutant drops it and this call must go red.
        s1, lst = get(self.port, "/api/v1/topics", token=TOKEN)
        s2, men = get(self.port, f"/api/v1/topics/{PLANT_SLUG}/mentions", token=TOKEN)
        self.assertEqual(s1, 200)
        self.assertEqual(s2, 200)
        # The one allowed echo: the mentions body's "slug" key, equal to the request path slug.
        self.assertEqual(men.get("slug"), PLANT_SLUG, "echoed slug must equal the request path slug")
        men_data = {k: v for k, v in men.items() if k != "slug"}
        blob = json.dumps(lst) + json.dumps(men_data)
        for needle in (PLANT_LABEL, PLANT_SLUG, "Qzvorvex", "mirrion", "qzvorvex"):
            self.assertNotIn(needle, blob, needle)
        self.assertIn(CTRL_SLUG, [t["slug"] for t in lst["topics"]])
        self.assertEqual(len(lst["topics"]), 1, "exactly the L2 control row; the L3-only topic is withheld")

    def test_without_token_both_routes_are_401(self):
        s1, _ = get(self.port, "/api/v1/topics")
        s2, _ = get(self.port, f"/api/v1/topics/{PLANT_SLUG}/mentions")
        self.assertEqual(s1, 401)
        self.assertEqual(s2, 401)


if __name__ == "__main__":
    unittest.main()
