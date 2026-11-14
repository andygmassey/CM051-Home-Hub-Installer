#!/usr/bin/env python3
"""todos_reach_reminders reads back by the daemon's identifier, never by text;
a timed-out osascript is CANNOT-RUN, never "not found" or a pass; and the walk
measures the residue of reminders it created, with a reset step that removes
earlier walks' reminders by identifier.

Walk 131 (triage B, FAIL 4): the read-back matched the todo text, which the
daemon never uses as a title, and both deletes hit the 60 s osascript timeout.

Stubbed osascript only, no Reminders.app, no box. Synthetic identifiers.
Exit 0 pass, 1 fail.
"""
import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "lib")

# The state file path is read at import time; point it at a throwaway file.
_TMP = tempfile.mkdtemp(prefix="todo-state-")
os.environ["OSTLER_TODO_REMINDERS_STATE"] = os.path.join(_TMP, "created.json")
sys.path.insert(0, LIB)
import todo_reminders_box as box  # noqa: E402
import todo_reminders_probe as probe  # noqa: E402

fails = []


def check(label, ok):
    print(("  ok    " if ok else "  FAIL  ") + label)
    if not ok:
        fails.append(label)


class P:
    def __init__(self, rc=0, out="", err=""):
        self.returncode, self.stdout, self.stderr = rc, out, err


class Reminders:
    """A Reminders.app that knows reminders by id only. Title is the daemon's
    fixed title, so a match on the todo text finds nothing, as on the box."""
    TITLE = "Follow up on conversation"

    def __init__(self, ids, timeout_on=(), refuse=False):
        self.ids = set(ids)
        self.timeout_on = set(timeout_on)
        self.refuse = refuse
        self.scripts = []

    def __call__(self, argv, **kw):
        s = argv[2]
        self.scripts.append(s)
        if self.refuse:
            return P(1, "", "execution error: Not authorized to send Apple events to Reminders. (-1743)")
        target = [i for i in self.ids if '"%s"' % i in s]
        if any('"%s"' % i in s for i in self.timeout_on):
            raise subprocess.TimeoutExpired(argv, kw.get("timeout", 60))
        if " delete " in s:
            for i in target:
                self.ids.discard(i)
            return P(0)
        if " count " in s:
            return P(0, "%d\n" % len(target))
        return P(0, "0\n")


TODO_TEXT = "SYNTHETIC WALK PROBE token: email the counterpart about the Fictionville report"
IDENT = "SYNTH-EK-0001"

# 1. read-back is keyed by the daemon's identifier, never by the todo text
rb_stub = Reminders([IDENT])
r = box._readback(IDENT, rb_stub)
check("read-back by identifier finds the reminder the daemon recorded (found={})".format(r.get("found")),
      r.get("found") is True)
check("read-back script names the identifier, not the todo text",
      rb_stub.scripts and all(IDENT in s for s in rb_stub.scripts) and not any("WALK PROBE" in s for s in rb_stub.scripts))
r = box._readback(None, Reminders([IDENT]))
check("no identifier recorded: read-back not attempted, never 'not found'", r.get("attempted") is False and "found" not in r)

# 2. a read-back timeout is CANNOT-RUN, never 'not found'
r = box._readback(IDENT, Reminders([IDENT], timeout_on=[IDENT]))
check("a timed-out read-back is reported timed_out (not found, not blocked)",
      r.get("timed_out") is True and r.get("found") is None)
rows = [ok for n, ok, _ in probe.judge(dict(probe._good(), readback=r)) if n == probe.DECLARED[2]]
check("the judge reads a timed-out read-back as CANNOT-RUN (None), never FAIL or PASS", rows == [None])

# 3. the delete timeout is its own state, and the judge reads it as CANNOT-RUN
st = Reminders([IDENT], timeout_on=[IDENT])
d = box.delete_reminder(IDENT, st)
check("a delete that times out twice is state timed_out, not failed or deleted",
      d["state"] == "timed_out")
check("the delete was retried once before timed_out (2 delete calls)",
      sum(1 for s in st.scripts if " delete " in s) == 2)
cl = [ok for n, ok, _ in probe.judge(dict(probe._good(), cleanup={"calendar_item_identifier": IDENT, "reminder": d}))
      if n == probe.DECLARED[3]]
check("a timed-out cleanup is CANNOT-RUN, never PASS", cl == [None])

# 4. state file: written on push, dropped on verified delete
box.state_add(IDENT)
check("state file records the identifier the daemon returned", box.state_load()[0] == [IDENT])
box.state_add("SYNTH-EK-0002")
box.state_drop(IDENT)
check("state_drop removes only the verified identifier", box.state_load()[0] == ["SYNTH-EK-0002"])
box.state_drop("SYNTH-EK-0002")
check("state file empty after both are dropped", box.state_load()[0] == [])

# 5. reset removes earlier walks' reminders by identifier, measured residue 0
box.state_add("SYNTH-EK-OLD1")
box.state_add("SYNTH-EK-OLD2")
rs = Reminders(["SYNTH-EK-OLD1", "SYNTH-EK-OLD2"])
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    box.cmd_reset([], runner=rs)
rst = json.loads(buf.getvalue())["reset"]
check("reset removes both earlier reminders and measures residue 0 (before={}, residue_after={})".format(
    rst.get("before"), rst.get("residue_after")), rst.get("before") == 2 and rst.get("residue_after") == 0)
check("reset left the state file empty", box.state_load()[0] == [])
check("reset deleted by identifier, not by title", all("SYNTH-EK-OLD" in s for s in rs.scripts))

# 6. reset over a refusing or timing-out Reminders leaves the residue COUNTED, not hidden
box.state_add("SYNTH-EK-STUCK")
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    box.cmd_reset([], runner=Reminders(["SYNTH-EK-STUCK"], refuse=True))
rst = json.loads(buf.getvalue())["reset"]
check("a refused reset keeps the residue and reports the measured count (residue_after={})".format(rst.get("residue_after")),
      rst.get("residue_after") == 1 and box.state_load()[0] == ["SYNTH-EK-STUCK"])
rows = [(ok, d) for n, ok, d in probe.judge(dict(probe._good(), reset={"reset": rst})) if n == probe.DECLARED[6]]
check("the judge names the residue as CANNOT-RUN with the count, never a pass",
      len(rows) == 1 and rows[0][0] is None and "1 reminder(s)" in rows[0][1])

# 6b. the cleanup verdict carries the MEASURED residue count, not just the words
rc_ok = [d for n, ok, d in probe.judge(dict(probe._good(), cleanup={"calendar_item_identifier": IDENT,
          "reminder": {"state": "deleted"}, "residue": {"count": 2}})) if n == probe.DECLARED[3]][0]
check("the cleanup verdict prints the measured residue count (2)", "still recorded after cleanup: 2" in rc_ok)
rc_none = [d for n, ok, d in probe.judge(dict(probe._good(), cleanup={"calendar_item_identifier": IDENT,
          "reminder": {"state": "deleted"}, "residue": {"count": 0}})) if n == probe.DECLARED[3]][0]
check("a zero residue is printed as 0, not omitted", "still recorded after cleanup: 0" in rc_none)

# 7. a missing state file is an empty list, a corrupt one is an error, never 0
bad = os.path.join(_TMP, "corrupt.json")
with open(bad, "w") as fh:
    fh.write("{not json")
ids, err = box.state_load(bad)
check("a corrupt state file is an error, not an empty (zero) list", ids == [] and err is not None)
box_path_before = box.STATE_PATH
box.STATE_PATH = bad
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    box.cmd_reset([], runner=Reminders([]))
box.STATE_PATH = box_path_before
rst = json.loads(buf.getvalue())["reset"]
check("reset over a corrupt state file reports an error and no residue count", rst.get("error") and rst.get("residue_after") is None)

print("FAIL: " + "; ".join(fails) if fails else "PASS")
sys.exit(1 if fails else 0)
