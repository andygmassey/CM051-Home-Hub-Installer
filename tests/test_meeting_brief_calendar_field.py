#!/usr/bin/env python3
"""The pre-meeting brief names the calendar each meeting came from.

The sender can only leave out a calendar the owner asked to ignore if the
meeting it is handed carries that calendar. This runs the vendored
pre_meeting_brief for real (no Hub, no People Graph: the attendee has no email,
so no lookup is made) and reads the field off the output.
"""
import os
import subprocess
import sys
import unittest
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VENDOR = Path(os.environ.get("T2_VENDOR_CM041") or (ROOT / "vendor" / "cm041"))

PROBE = r'''
import json, sys
from datetime import datetime, timedelta
from meeting_syncer import brief
d = (datetime.now() + timedelta(days=2)).strftime("%Y%m%dT%H%M%S")
events = [
    {"summary": "Standup", "start": d, "end": d, "uid": "u-work", "calendar": "Work",
     "attendees": [{"name": "Jane Example"}]},
    {"summary": "Visit", "start": d, "end": d, "uid": "u-none",
     "attendees": [{"name": "Jane Example"}]},
]
out = brief.pre_meeting_brief(days=1, events_provider=lambda n: events)
print(json.dumps([{"uid": b["uid"], "has_key": "calendar" in b, "calendar": b.get("calendar")} for b in out]))
'''


class MeetingBriefCalendarField(unittest.TestCase):
    def test_pre_meeting_brief_carries_the_calendar_of_each_meeting(self):
        res = subprocess.run([sys.executable, "-c", PROBE], cwd=str(VENDOR),
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(res.returncode, 0, msg=res.stderr)
        import json
        rows = {r["uid"]: r for r in json.loads(res.stdout.strip().splitlines()[-1])}
        self.assertEqual(rows["u-work"]["calendar"], "Work")
        self.assertTrue(rows["u-work"]["has_key"])
        # An event with no calendar name carries an empty value, never a crash.
        self.assertEqual(rows["u-none"]["calendar"], "")
        self.assertTrue(rows["u-none"]["has_key"])


if __name__ == "__main__":
    unittest.main()
