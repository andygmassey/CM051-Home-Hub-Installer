#!/usr/bin/env python3
"""todos_reach_reminders must delete the reminder it created, or say loudly it could not.

Walk #19: walk #18's leftover reminder ("Follow up on conversation") came back
through iCloud. The old forget step matched `name is <todo text>`, but the daemon
titles the reminder from reminders_push._format_push_title, so the match found
nothing; and over ssh without the Automation grant the call failed outright.
Both reported reminder_deleted=false, which the probe printed and ignored.

Stubbed osascript, synthetic data only. Exit 0 pass, 1 fail.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "lib")
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


class Stub:
    """A Reminders.app with one reminder; matches by id only."""
    def __init__(self, present=True, delete_rc=0, delete_err="", sticky=False):
        self.present, self.delete_rc, self.delete_err, self.sticky = present, delete_rc, delete_err, sticky
        self.scripts = []

    def __call__(self, argv, **kw):
        s = argv[2]
        self.scripts.append(s)
        if " delete " in s:
            if self.delete_rc:
                return P(self.delete_rc, "", self.delete_err)
            if not self.sticky:
                self.present = False
            return P(0)
        return P(0, "1\n" if self.present else "0\n")


ID = "SYNTH-0000-ek"
# 1. happy path: deleted by id, verified by count
st = Stub()
r = box.delete_reminder(ID, st)
check("delete by recorded id: state deleted, reminder gone", r["state"] == "deleted" and not st.present)
check("the delete targets the recorded id, not the todo text", all(ID in s for s in st.scripts))
# 2. nothing was ever pushed
check("no identifier: none_to_delete, osascript not called", box.delete_reminder("", Stub()) == {"state": "none_to_delete"})
# 3. TCC refusal over ssh
r = box.delete_reminder(ID, Stub(delete_rc=1, delete_err="execution error: Not authorized to send Apple events to Reminders. (-1743)"))
check("TCC refusal: blocked_tcc, not failed, not deleted", r["state"] == "blocked_tcc")
# 4. exit 0 but the reminder is still there
r = box.delete_reminder(ID, Stub(sticky=True))
check("rc 0 yet still present: failed (the count is the proof)", r["state"] == "failed")
# 5. other error
check("other osascript error: failed", box.delete_reminder(ID, Stub(delete_rc=1, delete_err="boom"))["state"] == "failed")

# judge: an unsuccessful delete is never ok
good = probe._good()
def cleanup_row(c):
    g = dict(good, cleanup=c)
    return [ok for n, ok, _ in probe.judge(g) if n == probe.DECLARED[3]]
check("judge: deleted is ok", cleanup_row({"reminder": {"state": "deleted"}}) == [True])
check("judge: blocked_tcc is CANNOT-RUN", cleanup_row({"calendar_item_identifier": ID, "reminder": {"state": "blocked_tcc"}}) == [None])
check("judge: failed is FAIL", cleanup_row({"reminder": {"state": "failed"}}) == [False])
check("judge: the old reminder_deleted=false shape is FAIL", cleanup_row({"reminder_deleted": False}) == [False])
check("judge: no forget output is CANNOT-RUN", [ok for n, ok, _ in probe.judge({k: v for k, v in good.items() if k != "cleanup"}) if n == probe.DECLARED[3]] == [None])
d = [d for n, ok, d in probe.judge(dict(good, cleanup={"calendar_item_identifier": ID, "expected_title": "Follow up on conversation", "reminder": {"state": "blocked_tcc"}})) if n == probe.DECLARED[3]][0]
check("judge: the CANNOT-RUN names the id and the title", ID in d and "Follow up on conversation" in d)

# FAIL dominates: assertions 1-3 FAIL + cleanup blocked_tcc must exit FAIL (1), not CANNOT-RUN (78)
import contextlib, io
bad = dict(good, push={"status": "failed", "waited_s": 5}, readback={},
           cleanup={"calendar_item_identifier": ID, "reminder": {"state": "blocked_tcc"}})
with contextlib.redirect_stdout(io.StringIO()):
    rc = probe.report(probe.judge(bad))
check("a FAIL plus a TCC-blocked cleanup exits FAIL (1), not CANNOT-RUN (78); rc={}".format(rc), rc == probe.EX_FAIL)
with contextlib.redirect_stdout(io.StringIO()):
    rc = probe.report(probe.judge(dict(good, cleanup={"calendar_item_identifier": ID, "reminder": {"state": "blocked_tcc"}})))
check("a TCC-blocked cleanup alone exits CANNOT-RUN (78); rc={}".format(rc), rc == probe.EX_CANNOT)

# the probe wiring: forget's output must reach the judge
sh = open(os.path.join(os.path.dirname(LIB), "probes", "todos_reach_reminders.sh")).read()
check("probe folds the forget output into the judged facts", "f['cleanup']" in sh)
check("the fold lets its stderr through", '"${facts}" "${forgot}" 2>/dev/null' not in sh)

print("FAIL: " + "; ".join(fails) if fails else "PASS")
sys.exit(1 if fails else 0)
