#!/usr/bin/env python3
"""morning_brief_catches_me_up: a repeated brief line leaves evidence ON THE BOX.

Instrumentation only. The verdict (brief_repeats count) is unchanged. On a
repeated line the box side writes morning_brief_repeats_*.json into the probe
evidence dir: the line's sha256, the line numbers, and whether the line also
appears in the source rows the brief was built from. The text itself never
goes into that file, and the driver log gets counts only.

Drives box_morning() END TO END with the Hub, gateway and store faked, so the
real code path that writes the evidence is the one under test.
"""
import glob
import hashlib
import importlib.util
import json
import os
import stat
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = importlib.util.spec_from_file_location(
    "wow_moments", os.path.join(ROOT, "scripts", "box_walk_probes", "lib", "wow_moments.py"))
wow = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(wow)

# Synthetic, reserved-looking fixture tokens. None of them may reach the evidence file.
FIXTURE_NAME = "Alex Doe"
FIXTURE_TOKENS = ("Alex Doe", "alex doe", "Alex", "Doe")

REPEATED_NAME_LINE = FIXTURE_NAME + " is waiting for your reply."
BRIEF_NAME_REPEAT = "Today:\n%s\nNothing overdue.\n%s\n" % (REPEATED_NAME_LINE, REPEATED_NAME_LINE)
BRIEF_PROMISE_REPEAT = "Today:\n%s\nNothing overdue.\n%s\n" % (wow.OWNER_PROMISE, wow.OWNER_PROMISE)
BRIEF_CLEAN = "Today:\n%s\nNothing overdue.\n" % REPEATED_NAME_LINE


def _run_brief(brief_text, evidence_dir):
    """box_morning() end to end, with every network and store call faked."""
    os.environ["OSTLER_WALK_EVIDENCE_DIR"] = evidence_dir
    os.environ["OSTLER_REPLY_MAX_ITEMS"] = "3"
    saved = {k: getattr(wow, k) for k in ("_morning_prompt", "_store_update", "_secret", "_hub", "_http")}
    saved_sleep = wow.time.sleep
    wow._morning_prompt = lambda: "Cover today and the promises people owe."
    wow._store_update = lambda sparql: 204
    wow._secret = lambda name, env=None: None
    wow.time.sleep = lambda s: None

    def hub(path):
        if path.startswith("/api/v1/commitments"):
            return 200, {"commitments": [{"action": wow.OWNER_PROMISE}]}
        if path.startswith("/api/v1/reply-debt"):
            return 200, {"debts": []}
        if path.startswith("/api/v1/calendar/today"):
            return 200, {"events": []}
        return 404, None

    def http(method, url, body=None, headers=None, timeout=30):
        if method == "POST":
            return 200, {"job": {"id": "probe-job-1"}}
        if method == "GET":
            return 200, [{"output": brief_text, "status": "ok"}]
        return 200, None

    wow._hub = hub
    wow._http = http
    try:
        return wow.box_morning(wait_s=30)
    finally:
        for k, v in saved.items():
            setattr(wow, k, v)
        wow.time.sleep = saved_sleep


def _evidence_files(d):
    return sorted(glob.glob(os.path.join(d, "morning_brief_repeats_*.json")))


def main():
    fails = []

    def check(label, ok):
        print("  %s  %s" % ("ok   " if ok else "FAIL ", label))
        if not ok:
            fails.append(label)

    # 1. Positive: a repeated line that the sources do NOT contain.
    d1 = tempfile.mkdtemp(prefix="wow-ev-name-")
    out = _run_brief(BRIEF_NAME_REPEAT, d1)
    check("repeat count is unchanged by the instrumentation (1)", out.get("repeats") == 1)
    files = _evidence_files(d1)
    check("a repeated line writes exactly one evidence file", len(files) == 1)
    if files:
        raw = open(files[0], "rb").read()
        ev = json.loads(raw.decode("utf-8"))
        want_sha = hashlib.sha256(wow._norm_item(REPEATED_NAME_LINE).encode("utf-8")).hexdigest()
        ev_events = ev.get("events") or []
        check("evidence carries the sha256 of the normalised repeated line",
              len(ev_events) == 1 and ev_events[0].get("sha256") == want_sha)
        # The fixture: line 1 "Today:", 2 the name line, 3 "Nothing overdue.", 4 the name line again.
        check("evidence carries the repeated line number (4) and the first line number (2)",
              len(ev_events) == 1 and ev_events[0].get("line") == 4 and ev_events[0].get("first_line") == 2)
        check("line not in the source rows is recorded as in_sources false",
              len(ev_events) == 1 and ev_events[0].get("in_sources") is False)
        check("facts block marked NOT INSTRUMENTED (no daemon route reaches it)",
              len(ev_events) == 1 and ev_events[0].get("in_facts") == "NOT INSTRUMENTED")
        leaked = [t for t in FIXTURE_TOKENS if t.encode("utf-8") in raw]
        check("evidence file holds no plaintext fixture name (%s)" % (leaked or "none present"), not leaked)
        mode = stat.S_IMODE(os.stat(files[0]).st_mode)
        check("evidence file is owner-only (0600), got %s" % oct(mode), mode == 0o600)

    # 2. Positive control: a repeated line that the source rows DO contain.
    d2 = tempfile.mkdtemp(prefix="wow-ev-src-")
    out2 = _run_brief(BRIEF_PROMISE_REPEAT, d2)
    files2 = _evidence_files(d2)
    check("the source-row control also writes one evidence file", out2.get("repeats") == 1 and len(files2) == 1)
    if files2:
        ev2 = json.loads(open(files2[0], "rb").read().decode("utf-8"))
        ev_events = ev2.get("events") or []
        check("a repeated line that the source rows contain is recorded as in_sources true",
              len(ev_events) == 1 and ev_events[0].get("in_sources") is True)

    # 3. Negative control: a clean brief writes nothing.
    d3 = tempfile.mkdtemp(prefix="wow-ev-clean-")
    out3 = _run_brief(BRIEF_CLEAN, d3)
    check("a clean brief has no repeats and writes no evidence file",
          out3.get("repeats") == 0 and _evidence_files(d3) == [])

    print("every check held" if not fails else "FAILED: %d" % len(fails))
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
