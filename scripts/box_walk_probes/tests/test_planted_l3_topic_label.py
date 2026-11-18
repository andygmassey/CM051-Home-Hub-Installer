"""Planted topic whose only visible text is an L3 mention: its label, slug and
counts must appear NOWHERE in /topics or /topics/<slug>/mentions output."""
import importlib.util, json, os, sys, unittest
from pathlib import Path
from unittest.mock import patch
# The reader tree under test. Default: this checkout. CM051_READER_TREE points at
# any tree that has vendor/cm041 (e.g. a git-archive of db1cb5a9 for the gate-less RED).
ROOT = Path(os.environ.get("CM051_READER_TREE") or Path(__file__).resolve().parents[3])
sys.path.insert(0, str(ROOT / "vendor"))            # ostler_security, pwg_privacy
API = ROOT / "vendor" / "cm041" / "assistant_api"
sys.path.insert(0, str(API))
_spec = importlib.util.spec_from_file_location("ical_server_under_test", API / "ical-server.py")
server = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(server)

# DIRECT HANDLER CALLS, not HTTP. The moat HTTP harness (test_l3_withheld_moat_readers.py)
# exists only on #3565, so it cannot be the loader on the gate-less tree. The handlers
# topics_list / topic_mentions are the code that would withhold the row; the HTTP layer
# only routes to them. Their auth (service token, X-Ostler-Service) is HTTP-side and is
# NOT exercised here: nothing in this test bypasses it, because nothing here passes it.

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
        out = []
        for r in ROWS:
            if r["slug"] == slug:
                out.append({"label": r["label"], "conversation": r["conv"],
                            "weight": r["w"], "channel": "", "sender": "",
                            "date": "2026-01-01", "mpriv": r["mpriv"], "cpriv": r["cpriv"]})
        return out
    return []

class PlantedTopic(unittest.TestCase):
    def test_l3_only_topic_text_is_nowhere_and_control_is_served(self):
        with patch.object(server, "_sparql_select", side_effect=fake):
            lst, s1 = server.topics_list()
            men, s2 = server.topic_mentions(PLANT_SLUG)
            ctl, s3 = server.topic_mentions(CTRL_SLUG)
        self.assertEqual(s1, 200)
        # Echoed caller slug, excluded (Archie ruling): the response echoes the request
        # path's slug; asserted equal below so it cannot carry a store value.
        men_data = {k: v for k, v in men.items() if k != "slug"}
        blob = json.dumps(lst) + json.dumps(men_data)
        for needle in (PLANT_LABEL, PLANT_SLUG, "Qzvorvex", "mirrion", "qzvorvex"):  # men echo of request slug excluded
            self.assertNotIn(needle, blob, needle)
        self.assertIn(CTRL_SLUG, [t["slug"] for t in lst["topics"]])
        self.assertEqual(ctl["count"], 1)
        self.assertEqual(lst["withheld"]["l3"], 1)
        self.assertEqual(men["count"], 0)
        self.assertEqual(men["slug"], PLANT_SLUG)  # the caller's own input, echoed
        self.assertEqual(men["slug"], PLANT_SLUG, "echoed slug must equal the request path slug")

if __name__ == "__main__":
    unittest.main()
