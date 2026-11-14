#!/usr/bin/env python3
"""The pre-meeting sender honours the owner's calendar rule, across runs.

The sender's python block is extracted from install.sh exactly as written and
run against a local /announce server that counts deliveries. The composer is a
stub with the documented contract: exit 4 with nothing on stdout means "the
owner asked to leave this calendar out" (suppressed, not a failure); exit 0 is
a brief; anything else is a failure to retry. The stub reads the owner's rules
from a file, which stands in for the Hub's durable store, so each run is a new
process reading the same state.

Cases: muted calendar is never sent and is not retried; an unmuted calendar is
sent; the rule set on day 1 still suppresses on day 2 in a fresh process; a
rule that is later cleared lets the next meeting through.
"""
import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INSTALL_SH = Path(os.environ.get("T2_INSTALL_SH") or (ROOT / "install.sh"))

COMPOSER_STUB = r'''#!/usr/bin/env bash
# Composer stub. MODE selects the build being simulated:
#   new            lists "calendar" in composer-capabilities and applies the rule
#   old            predates the feature: no composer-capabilities, rejects --calendar
#   probe_fail     the probe exits 1; the meeting-brief accepts --calendar
#   probe_garbage  the probe exits 0 without listing "calendar"
#   probe_hang     the probe never answers (the sender must time it out)
set -u
MODE="${OSTLER_TEST_MODE:-new}"
RULES_FILE="${OSTLER_TEST_RULES}"
CALLS_LOG="${OSTLER_TEST_CALLS}"
if [ "${1:-}" = "composer-capabilities" ]; then
    case "$MODE" in
        new) echo "calendar"; exit 0 ;;
        old) echo "error: unrecognized subcommand 'composer-capabilities'" >&2; exit 2 ;;
        probe_fail) echo "probe broke" >&2; exit 1 ;;
        probe_garbage) echo "hello"; exit 0 ;;
        probe_hang) sleep 30; exit 0 ;;
    esac
fi
echo "$*" >> "$CALLS_LOG"
cal=""
prev=""
saw_calendar=0
for a in "$@"; do
    if [ "$a" = "--calendar" ]; then saw_calendar=1; fi
    if [ "$prev" = "--calendar" ]; then cal="$a"; fi
    prev="$a"
done
if [ "$saw_calendar" = 1 ] && [ "$MODE" = "old" ]; then
    echo "error: unexpected argument '--calendar' found" >&2
    exit 2
fi
if [ -n "$cal" ] && grep -Fxq -- "$cal" "$RULES_FILE" 2>/dev/null; then
    exit 4
fi
echo "Jane Example: a short grounded brief."
exit 0
'''


def extract_sender_python(text: str) -> str:
    m = re.search(r"OSTLER_BRIEF_HUB_JSON=\"\$\{RESPONSE\}\" python3 - .*? <<'PYEOF' \|\| _send_rc=\$\?\n(.*?)\nPYEOF\n",
                  text, re.S)
    if not m:
        raise AssertionError("sender python block not found in install.sh")
    return m.group(1) + "\n"


def meeting(uid, day_offset, calendar):
    start = datetime(2026, 11, 16, 9, 0, tzinfo=timezone.utc) + timedelta(days=day_offset)
    m = {
        "meeting": "Standup",
        "start": start.strftime("%a %d %b %H:%M"),
        "start_iso": start.isoformat(),
        "uid": uid,
        "location": "",
        "attendees": [{"name": "Jane Example", "wiki_url": "https://wiki.example.com/jane-example",
                       "outstanding_todos": []}],
    }
    if calendar is not None:
        m["calendar"] = calendar
    return m


class Harness(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="t2-sender-"))
        self.rules = self.tmp / "rules.txt"
        self.rules.write_text("", encoding="utf-8")
        self.calls = self.tmp / "calls.txt"
        self.calls.touch()
        self.composer = self.tmp / "composer.sh"
        self.composer.write_text(COMPOSER_STUB, encoding="utf-8")
        self.composer.chmod(0o755)
        self.posts = []
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                n = int(self.headers.get("Content-Length", 0))
                outer.posts.append(json.loads(self.rfile.read(n) or b"{}"))
                self.send_response(200)
                self.end_headers()

            def log_message(self, *a):
                pass

        self.server = http.server.HTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.src = extract_sender_python(INSTALL_SH.read_text(encoding="utf-8"))
        self.script = self.tmp / "sender.py"
        self.script.write_text(self.src, encoding="utf-8")
        self.db = self.tmp / "sent_briefs.db"
        # The installer creates this table in bash before the python block runs.
        import sqlite3
        schema = re.search(r"(CREATE TABLE IF NOT EXISTS sent_briefs \(.*?\));", INSTALL_SH.read_text(encoding="utf-8"), re.S).group(1)
        conn = sqlite3.connect(self.db)
        conn.execute(schema)
        conn.commit()
        conn.close()
        self.log = self.tmp / "sender.log"

    def tearDown(self):
        self.server.shutdown()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def set_rules(self, *calendars):
        self.rules.write_text("\n".join(calendars) + ("\n" if calendars else ""), encoding="utf-8")

    def run_tick(self, *meetings, mode="new"):
        hub = {"meetings": list(meetings), "considered": len(meetings), "filtered": []}
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "OSTLER_BRIEF_HUB_JSON": json.dumps(hub),
            "OSTLER_BRIEF_COMPOSER": str(self.composer),
            "OSTLER_BRIEF_OWNER_NAME": "Sam",
            "OSTLER_TEST_RULES": str(self.rules),
            "OSTLER_TEST_CALLS": str(self.calls),
            "OSTLER_TEST_MODE": mode,
        }
        res = subprocess.run([sys.executable, str(self.script), str(self.db), self.url,
                              str(self.log), "http://127.0.0.1:8090", str(self.tmp), "brief-channel", "en-GB"],
                             env=env, capture_output=True, text=True, timeout=60)
        return res

    def log_text(self):
        return self.log.read_text(encoding="utf-8") if self.log.exists() else ""

    def sent_keys(self):
        import sqlite3
        conn = sqlite3.connect(self.db)
        try:
            return {r[0] for r in conn.execute("SELECT key FROM sent_briefs")}
        finally:
            conn.close()


class SenderCalendarRule(Harness):
    def test_muted_calendar_is_never_sent_and_is_not_retried(self):
        self.set_rules("Work")
        res = self.run_tick(meeting("u-work-1", 0, "Work"))
        self.assertEqual(res.returncode, 0, msg=res.stderr)
        self.assertEqual(self.posts, [], "a muted calendar's meeting was delivered")
        self.assertIn("suppressed", self.log_text())
        self.assertIn("--calendar Work", self.calls.read_text(encoding="utf-8"))
        # Handled, so the next tick does not retry it (an empty brief would be retried).
        self.assertIn("u-work-1|2026-11-16T09:00:00+00:00", self.sent_keys())
        self.assertEqual(res.stderr.count("CANNOT-DELIVER"), 0)

    def test_unmuted_calendar_is_still_sent(self):
        self.set_rules("Work")
        res = self.run_tick(meeting("u-home-1", 0, "Home"))
        self.assertEqual(res.returncode, 0, msg=res.stderr)
        self.assertEqual(len(self.posts), 1, "an unmuted calendar's brief was not delivered")
        self.assertEqual(self.posts[0].get("meeting_uid"), "u-home-1")

    def test_rule_set_on_day_one_still_applies_on_day_two_in_a_new_process(self):
        self.set_rules("Work")
        self.run_tick(meeting("u-work-d1", 0, "Work"))           # day 1, process A
        res = self.run_tick(meeting("u-work-d2", 1, "Work"))     # day 2, process B
        self.assertEqual(res.returncode, 0, msg=res.stderr)
        self.assertEqual(self.posts, [], "the day-1 rule did not hold on day 2")

    def test_clearing_the_rule_lets_the_next_meeting_through(self):
        self.set_rules("Work")
        self.run_tick(meeting("u-work-d1", 0, "Work"))
        self.set_rules()
        res = self.run_tick(meeting("u-work-d2", 1, "Work"))
        self.assertEqual(res.returncode, 0, msg=res.stderr)
        self.assertEqual([p["meeting_uid"] for p in self.posts], ["u-work-d2"])

    def test_meeting_without_a_calendar_name_is_sent_not_suppressed(self):
        self.set_rules("Work")
        res = self.run_tick(meeting("u-nocal-1", 0, None))
        self.assertEqual(res.returncode, 0, msg=res.stderr)
        self.assertEqual(len(self.posts), 1)
        self.assertNotIn("--calendar", self.calls.read_text(encoding="utf-8"))

    # --- Version skew (Sparkle): the composer may predate --calendar. -------

    def test_old_composer_sends_the_brief_exactly_once_and_says_so(self):
        self.set_rules("Work")
        res = self.run_tick(meeting("u-old-1", 0, "Work"), mode="old")
        self.assertEqual(res.returncode, 0, msg=res.stderr)
        self.assertEqual([p["meeting_uid"] for p in self.posts], ["u-old-1"])
        # The second tick must not send it again, and must not retry it either.
        self.run_tick(meeting("u-old-1", 0, "Work"), mode="old")
        self.assertEqual(len(self.posts), 1, "the brief was sent more than once")
        self.assertIn("calendar rules not applied: composer too old", self.log_text())
        self.assertNotIn("--calendar", self.calls.read_text(encoding="utf-8"))
        self.assertNotIn("CANNOT-DELIVER", res.stderr)

    def test_new_composer_applies_the_rule(self):
        self.set_rules("Work")
        res = self.run_tick(meeting("u-new-work", 0, "Work"), meeting("u-new-home", 0, "Home"), mode="new")
        self.assertEqual(res.returncode, 0, msg=res.stderr)
        self.assertEqual([p["meeting_uid"] for p in self.posts], ["u-new-home"])
        self.assertIn("--calendar Work", self.calls.read_text(encoding="utf-8"))
        self.assertNotIn("composer too old", self.log_text())

    def test_probe_failure_falls_back_to_the_old_behaviour_sent_once(self):
        self.set_rules("Work")
        res = self.run_tick(meeting("u-pf-1", 0, "Work"), mode="probe_fail")
        self.assertEqual(res.returncode, 0, msg=res.stderr)
        self.assertEqual([p["meeting_uid"] for p in self.posts], ["u-pf-1"])
        self.assertIn("calendar rules not applied: composer too old", self.log_text())
        self.assertNotIn("--calendar", self.calls.read_text(encoding="utf-8"))

    def test_probe_that_hangs_falls_back_to_the_old_behaviour_sent_once(self):
        self.set_rules("Work")
        res = self.run_tick(meeting("u-ph-1", 0, "Work"), mode="probe_hang")
        self.assertEqual(res.returncode, 0, msg=res.stderr)
        self.assertEqual([p["meeting_uid"] for p in self.posts], ["u-ph-1"])
        self.assertIn("calendar rules not applied", self.log_text())

    def test_probe_garbage_falls_back_to_the_old_behaviour_sent_once(self):
        self.set_rules("Work")
        res = self.run_tick(meeting("u-pg-1", 0, "Work"), mode="probe_garbage")
        self.assertEqual(res.returncode, 0, msg=res.stderr)
        self.assertEqual([p["meeting_uid"] for p in self.posts], ["u-pg-1"])
        self.assertIn("calendar rules not applied", self.log_text())


if __name__ == "__main__":
    unittest.main()
