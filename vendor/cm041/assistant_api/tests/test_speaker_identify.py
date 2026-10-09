"""speaker_identify: resolution order, never guessing, corrections. Synthetic data."""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import speaker_identify as si  # noqa: E402

DIR = [{"name": "Jane Doe"}, {"name": "Alex Ross"}, {"name": "Raj Patel"}, {"name": "Raj Patel"}]
slug = lambda n: n.lower().replace(" ", "-")  # noqa: E731


class Identify(unittest.TestCase):
    def setUp(self):
        self.store = Path(tempfile.mkdtemp()) / "c.json"

    def run_id(self, transcript, attendees, operator=("Sam Smith",)):
        body, status = si.identify({"transcript": transcript, "attendees": attendees},
                                   DIR, operator, slug, self.store)
        self.assertEqual(status, 200)
        return {s["label"]: s for s in body["speakers"]}

    def test_sole_remote_attendee_is_named(self):
        r = self.run_id("User: hi\nRemote: hello\n", ["Sam Smith", "Jane Doe"])
        self.assertEqual(r["Remote"]["person_id"], "jane-doe")
        self.assertEqual(r["Remote"]["confidence"], si.SOLE_REMOTE_CONFIDENCE)
        self.assertEqual(r["User"]["display_name"], "Sam Smith")

    def test_several_attendees_is_never_guessed(self):
        r = self.run_id("Remote: hello\n", ["Sam Smith", "Jane Doe", "Alex Ross"])
        self.assertIsNone(r["Remote"]["display_name"])
        self.assertEqual(r["Remote"]["confidence"], 0.0)

    def test_named_label_matches_attendee_and_first_name(self):
        r = self.run_id("Jane Doe: a\nAlex: b\n", ["Jane Doe", "Alex Ross", "Sam Smith"])
        self.assertEqual(r["Jane Doe"]["person_id"], "jane-doe")
        self.assertEqual(r["Alex"]["display_name"], "Alex Ross")
        self.assertEqual(r["Alex"]["confidence"], si.FIRST_NAME_CONFIDENCE)

    def test_not_in_contacts_and_ambiguous_contacts_are_capped(self):
        r = self.run_id("Remote: x\n", ["Sam Smith", "Carl Brown"])
        self.assertIsNone(r["Remote"]["person_id"])
        self.assertLessEqual(r["Remote"]["confidence"], si.NOT_IN_CONTACTS_CAP)
        r = self.run_id("Remote: x\n", ["Sam Smith", "Raj Patel"])
        self.assertIsNone(r["Remote"]["person_id"])
        self.assertLessEqual(r["Remote"]["confidence"], si.AMBIGUOUS_CONTACT_CAP)

    def test_attendee_address_forms(self):
        self.assertEqual(si.clean_attendee("Jane Doe <jane@example.com>"), "Jane Doe")
        self.assertEqual(si.clean_attendee("jane.doe@example.com"), "jane doe")
        self.assertEqual(si.clean_attendee(5), "")

    def test_correction_applies_only_when_the_name_is_an_attendee(self):
        body, st = si.record_corrections(
            {"attendees": ["Jane Doe", "Alex Ross"],
             "corrections": [{"label": "Remote", "display_name": "Alex Ross"}]}, slug, self.store)
        self.assertEqual((st, body["stored"]), (200, 1))
        r = self.run_id("Remote: x\n", ["Jane Doe", "Alex Ross", "Sam Smith"])
        self.assertEqual(r["Remote"]["display_name"], "Alex Ross")
        self.assertEqual(r["Remote"]["confidence"], si.CORRECTION_CONFIDENCE)
        r = self.run_id("Remote: x\n", ["Jane Doe", "Carl Brown", "Sam Smith"])
        self.assertNotEqual(r["Remote"]["display_name"], "Alex Ross")

    def test_phone_update_request_shape_is_accepted(self):
        body, st = si.record_corrections(
            {"meeting_id": "m1", "identifications": [
                {"speaker_label": "Speaker 2", "person_id": None, "display_name": "Jane Doe",
                 "confidence": 1.0, "status": "confirmed"},
                {"speaker_label": "Speaker 3", "person_id": None, "display_name": None,
                 "confidence": 0.0, "status": "unknown"}]}, slug, self.store)
        self.assertEqual((st, body["stored"], body["skipped"]), (200, 1, 1))

    def test_validation(self):
        for bad in ({}, {"transcript": ""}, {"transcript": "x", "attendees": "a"},
                    {"transcript": "x", "attendees": [1]}, {"transcript": "x", "duration": "9"},
                    []):
            self.assertEqual(si.identify(bad, DIR, (), slug, self.store)[1], 400, bad)
        for bad in ({}, {"corrections": []}, {"corrections": [{"label": "R"}]},
                    {"corrections": [{"display_name": "J"}]}, {"meeting_id": "../x", "corrections": [{}]}):
            self.assertEqual(si.record_corrections(bad, slug, self.store)[1], 400, bad)
        many = [{"label": f"L{i}", "display_name": "J"} for i in range(si.MAX_CORRECTIONS_PER_REQUEST + 1)]
        self.assertEqual(si.record_corrections({"corrections": many}, slug, self.store)[1], 413)

    def test_store_is_private_and_deduplicated(self):
        for _ in range(3):
            si.record_corrections({"corrections": [{"label": "Remote", "display_name": "Jane Doe"}]},
                                  slug, self.store)
        self.assertEqual(len(si.load_corrections(self.store)), 1)
        self.assertEqual(self.store.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
