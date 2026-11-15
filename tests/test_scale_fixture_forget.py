"""Walk #27 shape sweep S7a: the scale fixture had no teardown.

On macmini16-walk 9000 of 11154 reminders_knowledge points and 18000 of
18971 apple_notes_knowledge chunks were fixture text left by earlier walks.
Every seeded record must carry the fixture tag, and `forget` must delete
exactly the tagged points and count what is left. Qdrant is a fake here,
which models scroll paging and delete. All data synthetic.
"""
from __future__ import annotations

import random
import sys
import unittest
from pathlib import Path

LIB = Path(__file__).resolve().parents[1] / "scripts/box_walk_probes/lib"
sys.path.insert(0, str(LIB))
import scale_fixture as sf  # noqa: E402


class FakeQdrant:
    def __init__(self, cols):
        self.cols = {c: dict(pts) for c, pts in cols.items()}

    def __call__(self, url, body):
        col = url.split("/collections/")[1].split("/")[0]
        pts = self.cols[col]
        if "/points/delete" in url:
            for i in body["points"]:
                pts.pop(i, None)
            return {"result": {"status": "completed"}}
        ids = sorted(pts)
        start = body.get("offset") or 0
        page = ids[start:start + body["limit"]]
        nxt = start + body["limit"] if start + body["limit"] < len(ids) else None
        return {"result": {"points": [{"id": i, "payload": pts[i]} for i in page],
                           "next_page_offset": nxt}}


class ScaleFixtureForget(unittest.TestCase):
    def test_every_seeded_record_carries_the_fixture_tag(self):
        rnd = random.Random(1)
        ppl = sf.people(rnd, 10)
        for r in sf._reminders(rnd, ppl, 50):
            self.assertIn(sf.FIXTURE_TAGS["reminders_knowledge"][1], r["notes"])
        for n in sf._notes(rnd, 5):
            self.assertTrue(n["evernote_guid"].startswith(sf.FIXTURE_TAGS["apple_notes_knowledge"][1]))

    def test_forget_deletes_the_tagged_points_and_keeps_the_customers(self):
        rem = {i: {"content": "Call Alex about the venue (%d) Synthetic reminder %d for the walk scale fixture." % (i, i)}
               for i in range(2500)}
        rem.update({10_000 + i: {"content": "Pick up the dry cleaning"} for i in range(30)})
        notes = {i: {"evernote_guid": "fixture-note-%06d" % (i // 3), "content": "Synthetic note."} for i in range(1200)}
        notes.update({20_000 + i: {"evernote_guid": "a1b2c3-%d" % i, "content": "Recipe ideas"} for i in range(7)})
        q = FakeQdrant({"reminders_knowledge": rem, "apple_notes_knowledge": notes})
        out = sf.forget("http://qdrant.invalid", "/nonexistent", post=q)
        self.assertEqual(out["reminders_knowledge"], {"examined": 2530, "tagged": 2500, "left": 0})
        self.assertEqual(out["apple_notes_knowledge"], {"examined": 1207, "tagged": 1200, "left": 0})
        self.assertEqual(len(q.cols["reminders_knowledge"]), 30)
        self.assertEqual(len(q.cols["apple_notes_knowledge"]), 7)

    def test_control_a_customer_note_is_never_a_fixture_point(self):
        self.assertFalse(sf.is_fixture_point("apple_notes_knowledge", {"evernote_guid": "note-fixture-1"}))
        self.assertFalse(sf.is_fixture_point("reminders_knowledge", {"content": "walk scale fixture"}))

    def test_the_neighbour_note_is_forgotten_too(self):
        upd = sf.neighbour_forget_update()
        self.assertIn(sf.NEIGHBOUR_FACT, upd)
        self.assertIn(sf.NEIGHBOUR_URI, upd)

    def test_the_neighbour_vector_is_forgotten_by_exact_uri_only(self):
        calls = []
        out = sf.forget_neighbour_vector("http://q.invalid", "/x", post=lambda u, b: calls.append((u, b)) or {})
        self.assertEqual(out, "forgotten")
        (url, body), = calls
        self.assertIn("/collections/people/points/delete", url)
        self.assertEqual(body["filter"]["must"][0], {"key": "person_uri", "match": {"value": sf.NEIGHBOUR_URI}})

    def test_a_failed_vector_delete_is_reported_not_swallowed(self):
        def boom(u, b):
            raise OSError("down")
        self.assertEqual(sf.forget_neighbour_vector("http://q.invalid", "/x", post=boom), "failed-OSError")


if __name__ == "__main__":
    unittest.main()
