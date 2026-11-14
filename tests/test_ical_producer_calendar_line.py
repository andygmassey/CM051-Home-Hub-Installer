#!/usr/bin/env python3
"""The iCloud ical-query producer names the calendar each event came from.

Consumer-side proof, not a generator check: the wrapper is extracted from the
installer heredoc exactly as install.sh writes it, run against a stub CalDAV
client with two calendars, and its stdout is parsed by the vendored
parse_ical_output. An owner rule ("ignore calendar Work") can only match an
iCloud event if the calendar name survives that whole chain.

Controls: a second calendar must come back under its own name (so the test
cannot pass by stamping one name on everything), and a calendar with no name
must produce no key at all.
"""
import ast
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INSTALL_SH = Path(os.environ.get("T2_INSTALL_SH") or (ROOT / "install.sh"))
PARSER_SRC = Path(os.environ.get("T2_PARSER_SRC") or (ROOT / "vendor" / "cm041" / "assistant_api" / "ical-server.py"))

STUB_CALDAV = '''
class _Event:
    def __init__(self, data):
        self.data = data

class _Cal:
    def __init__(self, name, events):
        self.name = name
        self._events = events
    def search(self, start=None, end=None, event=True, expand=True):
        return [_Event(e) for e in self._events]

class _Principal:
    def __init__(self, cals):
        self._cals = cals
    def calendars(self):
        return self._cals

class DAVClient:
    def __init__(self, url=None, username=None, password=None):
        pass
    def principal(self):
        return _Principal(CALS)

from datetime import date, timedelta
_D = (date.today() + timedelta(days=3)).strftime("%Y%m%d")  # inside the 14-day window, after today
_WORK = f"BEGIN:VEVENT\\nUID:work-1\\nDTSTART:{_D}T090000\\nDTEND:{_D}T100000\\nSUMMARY:Work standup\\nEND:VEVENT"
_HOME = f"BEGIN:VEVENT\\nUID:home-1\\nDTSTART:{_D}T110000\\nDTEND:{_D}T120000\\nSUMMARY:Dentist\\nEND:VEVENT"
_NONAME = f"BEGIN:VEVENT\\nUID:anon-1\\nDTSTART:{_D}T130000\\nDTEND:{_D}T140000\\nSUMMARY:Unnamed\\nEND:VEVENT"
CALS = [_Cal("Work", [_WORK]), _Cal("Home", [_HOME]), _Cal(None, [_NONAME])]
'''


def extract_wrapper(text: str) -> str:
    m = re.search(r"cat > \"\$ICAL_WRAPPER\" <<'ICALWRAPEOF'\n(.*?)\nICALWRAPEOF\n", text, re.S)
    if not m:
        raise AssertionError("ICALWRAPEOF heredoc not found in install.sh")
    return m.group(1) + "\n"


def parser_functions():
    tree = ast.parse(PARSER_SRC.read_text(encoding="utf-8"))
    wanted = {"parse_ical_output", "_parse_attendee"}
    nodes = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in wanted]
    assert {n.name for n in nodes} == wanted, "parser functions moved; update the test"
    import datetime as _dt
    ns = {"re": re, "datetime": _dt.datetime, "timedelta": _dt.timedelta, "timezone": _dt.timezone}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(PARSER_SRC), "exec"), ns)
    return ns["parse_ical_output"]


class ProducerCalendarLine(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="t2-ical-"))
        self.home = self.tmp / "home"
        (self.home / ".ostler" / ".venv" / "bin").mkdir(parents=True)
        os.symlink(sys.executable, self.home / ".ostler" / ".venv" / "bin" / "python3")
        stubs = self.tmp / "stubs" / "caldav"
        stubs.mkdir(parents=True)
        (stubs / "__init__.py").write_text(STUB_CALDAV, encoding="utf-8")
        wrapper = self.tmp / "ical-query.sh"
        wrapper.write_text(extract_wrapper(INSTALL_SH.read_text(encoding="utf-8")), encoding="utf-8")
        wrapper.chmod(0o755)
        self.wrapper = wrapper
        self.env = {
            "HOME": str(self.home),
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "PYTHONPATH": str(self.tmp / "stubs"),
            "OSTLER_ICLOUD_USER": "placeholder-user@example.com",
            "OSTLER_ICLOUD_APP_PASSWORD": "placeholder-not-a-secret",
        }

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_producer(self):
        res = subprocess.run(["/bin/bash", str(self.wrapper), "14"], env=self.env,
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(res.returncode, 0, msg=res.stderr)
        return res.stdout

    def test_each_icloud_event_carries_its_calendar_name_to_the_parser(self):
        events = parser_functions()(self.run_producer())
        by_uid = {e.get("uid"): e for e in events}
        self.assertEqual(by_uid["work-1"].get("calendar"), "Work")
        self.assertEqual(by_uid["home-1"].get("calendar"), "Home")

    def test_unnamed_calendar_gives_no_calendar_key(self):
        events = parser_functions()(self.run_producer())
        by_uid = {e.get("uid"): e for e in events}
        self.assertIn("anon-1", by_uid)
        self.assertNotIn("calendar", by_uid["anon-1"])


if __name__ == "__main__":
    unittest.main()
