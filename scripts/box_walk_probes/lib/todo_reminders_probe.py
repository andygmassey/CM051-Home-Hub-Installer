#!/usr/bin/env python3
"""A conversation with a synthetic commitment produces a todo, and it lands
in Apple Reminders. (v1.0.107, FLOW_CENSUS gap #6: "has no coverage at all")

CM048's ``reminders_push.py`` owns the DECISION (privacy + owner gate) and
the SQLite state machine (``~/.ostler/reminders_map.db``); it does NOT call
EventKit -- that is the installed ``ostler-assistant`` binary's job, reading
the same mapping table and flipping ``pending`` rows to ``pushed`` (with a
``calendar_item_identifier``) or to ``permission_denied`` / ``failed``. So a
probe that only calls the CM048 writer and stops has tested the FIRST half
of the pipeline and assumed the second. This probe writes a synthetic todo
through the SHIPPED writer (``apply_push_status_to_todos``, the exact
function the real pipeline calls), then waits for the INSTALLED daemon to
claim the row, then tries to read the result back from Reminders.app itself
-- never trusting the mapping table's "pushed" status as proof the item is
actually visible to the customer.

Four assertions (the fourth, cleanup, was added after walk #19):
  (a) WRITE. The synthetic commitment, run through the real gate, lands a
      ``pending`` row keyed by (user_id, source_session_id, todo_id).
  (b) CLAIM. The installed daemon (not this probe) claims the row within the
      wait budget: status leaves ``pending``.
  (c) VISIBLE. The reminder is actually readable in Reminders.app by its own
      text. A read of Reminders.app from a non-GUI ssh session needs the same
      class of Automation TCC grant as every other Apple-Events probe in
      this suite; when AppleScript is refused for that reason, this is
      CANNOT-RUN, never a pass on the mapping table's word alone.

judge(facts) -> rows, pure, mutation-tested below without a box.
"""
import json
import sys

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78
NA = "N/A"

DECLARED = [
    "write: a synthetic commitment, run through the shipped gate, lands a pending row in reminders_map.db",
    "claim: the installed daemon claims the pending row within the wait budget (EventKit attempted)",
    "visible: the reminder is actually readable in Reminders.app by its own text",
    "cleanup: the reminder the probe created is deleted and verified gone (residue syncs via iCloud into the next walk)",
    "people rules: a seeded 1:1 row is pending or pushed AND no row anywhere carries skip_reason non_human_predicate_unavailable (ical-server.py's People predicates imported on this box)",
    "ostler list: the daemon reports reminders_list present, id_stored, not removed, and holding the pushes (read over ssh from GET /api/status, no console)",
]


def judge(f):
    out = []

    def add(name, ok, detail=""):
        out.append((name, ok if ok is None or ok == NA else bool(ok), detail))

    write = f.get("write") or {}
    if not write.get("attempted"):
        reason = "NOT MEASURED: could not write the synthetic commitment through the shipped gate ({})".format(write.get("error", "no detail"))
        for d in DECLARED:
            add(d, None, reason)
        return _finish(out)

    add(DECLARED[0], True, "pending row created for todo_id={}".format(write.get("todo_id")))

    push = f.get("push") or {}
    status = push.get("status")
    if status in (None, "pending") and (f.get("tcc_reminders") or {}).get("state") == "absent":
        # Walk #11's real shape: never claimed AND no kTCCServiceReminders row.
        # The daemon cannot write to Reminders before anyone answers the
        # prompt, so this is a missing console grant, not a stalled daemon.
        add(DECLARED[1], None, "CANNOT-RUN: console grant needed. The row was never claimed within {}s and TCC.db has no kTCCServiceReminders row for the assistant, so the Reminders prompt is undecided; only a human at the console can answer it".format(push.get("waited_s", "?")))
    elif status in (None, "pending"):
        add(DECLARED[1], False, "the pending row was never claimed within {}s -- the daemon is not consuming reminders_map.db, or is stalled".format(push.get("waited_s", "?")))
    elif status == "permission_denied":
        # permission_denied is what the daemon reports both when the customer
        # said no and when nobody has been asked yet. Only TCC.db tells them
        # apart (walk #11: no kTCCServiceReminders row at all, read as FAIL).
        tcc = f.get("tcc_reminders") or {}
        ts = tcc.get("state")
        if ts == "absent":
            add(DECLARED[1], None, "CANNOT-RUN: console grant needed. TCC.db has no kTCCServiceReminders row for the assistant, so the Reminders prompt is undecided, not denied; only a human at the console can answer it")
        elif ts == "denied":
            add(DECLARED[1], False, "the daemon claimed the row and Reminders access is DENIED in TCC.db (auth_value={}, status=permission_denied)".format(tcc.get("auth_value")))
        elif ts == "allowed":
            add(DECLARED[1], False, "TCC.db GRANTS Reminders to the assistant (auth_value={}) yet the daemon reports permission_denied".format(tcc.get("auth_value")))
        else:
            add(DECLARED[1], False, "the daemon claimed the row but Reminders (EventKit) access is denied or revoked for it (status=permission_denied; TCC state {}: {})".format(ts or "not read", tcc.get("error") or tcc.get("auth_value") or "no detail"))
    elif status == "failed":
        add(DECLARED[1], False, "the daemon claimed the row but its EventKit write failed (status=failed)")
    elif status == "skipped":
        add(DECLARED[1], False, "the gate skipped a user-owned, non-L3 synthetic commitment (status=skipped, reason={}) -- this should have been eligible".format(push.get("skip_reason")))
    elif status == "pushed":
        add(DECLARED[1], True, "the daemon claimed the row and recorded calendar_item_identifier={}".format(push.get("calendar_item_identifier")))
    else:
        add(DECLARED[1], None, "NOT MEASURED: unrecognised status {!r}".format(status))

    rb = f.get("readback") or {}
    if status != "pushed":
        add(DECLARED[2], None, "NOT MEASURED: no pushed reminder exists to read back")
    elif rb.get("blocked_tcc"):
        add(DECLARED[2], None, "CANNOT-RUN: Automation permission (TCC) refused the AppleScript read of Reminders.app over this ssh session; only a console session can grant it")
    elif not rb.get("attempted"):
        add(DECLARED[2], None, "NOT MEASURED: the read-back was never attempted ({})".format(rb.get("error", "no detail")))
    elif rb.get("found") is True:
        add(DECLARED[2], True, "found 1 reminder matching the synthetic text")
    elif rb.get("found") is False:
        add(DECLARED[2], False, "EventKit confirmed the push, but the reminder is not visible in Reminders.app by its own text")
    else:
        add(DECLARED[2], None, "NOT MEASURED: the read-back gave no clear answer ({})".format(rb.get("error", "no detail")))

    _cleanup(f, out)
    _judge_people_rules(f, out, add)
    _judge_ostler_list(f, out, add, status)
    return _finish(out)


def _cleanup(f, out):
    name = DECLARED[3]
    cl = f.get("cleanup")
    if not cl:
        out.append((name, None, "CANNOT-RUN: the forget step returned nothing; a reminder may be left behind"))
        return
    # Two reminders can be left behind: the solo row's and the seeded 1:1's.
    # FAIL dominates CANNOT-RUN dominates ok, across both.
    parts = [("solo", cl)]
    if cl.get("one_to_one") is not None:
        parts.append(("1:1", cl["one_to_one"]))
    failed, blocked, ok_states = [], [], []
    for label, part in parts:
        r = part.get("reminder") or {}
        st = r.get("state")
        who = "{} reminder id={} titled '{}...'".format(label, part.get("calendar_item_identifier"), cl.get("expected_title", "Follow up"))
        if st in ("deleted", "none_to_delete"):
            ok_states.append(st)
        elif st == "blocked_tcc":
            blocked.append(who)
        else:
            failed.append("{} (delete failed: {})".format(who, r.get("error", "no detail")))
    if failed:
        out.append((name, False, "LEFT BEHIND: " + "; ".join(failed + blocked)))
    elif blocked:
        out.append((name, None, "CANNOT-RUN: Automation permission (TCC) refused the delete over ssh; LEFT BEHIND, delete by hand at the console: " + "; ".join(blocked)))
    else:
        out.append((name, True, ", ".join(ok_states)))


def _judge_people_rules(f, out, add):
    one = f.get("one_to_one") or {}
    n_bad = f.get("predicate_unavailable_rows")
    st = (f.get("one_to_one_push") or {}).get("status")
    if not one.get("attempted") or n_bad is None:
        add(DECLARED[4], None, "NOT MEASURED: the 1:1 row was not written ({}) or the reason count was unreadable".format(one.get("error", "no detail")))
    elif n_bad > 0:
        add(DECLARED[4], False, "{} row(s) carry skip_reason non_human_predicate_unavailable: ical-server.py's People predicates could not be imported on this box, so EVERY push is blocked (fail closed)".format(n_bad))
    elif st in ("pending", "pushed", "permission_denied", "failed"):
        # claimed or not, the GATE passed it: it was written pending, which
        # is only possible if the predicates imported and said "person".
        add(DECLARED[4], True, "1:1 row passed the gate (status={}); 0 rows with non_human_predicate_unavailable".format(st))
    elif st == "skipped":
        add(DECLARED[4], False, "the 1:1 row was skipped by the gate ({}) although its counterpart is name-shaped and not an organisation".format((f.get("one_to_one_push") or {}).get("skip_reason")))
    else:
        add(DECLARED[4], None, "NOT MEASURED: no status for the 1:1 row ({!r})".format(st))


def _judge_ostler_list(f, out, add, status):
    rl = f.get("reminders_list") or {}
    if not rl.get("read"):
        add(DECLARED[5], None, "CANNOT-RUN: could not read the daemon's status ({})".format(rl.get("error", "no detail")))
    elif not rl.get("present_in_status"):
        add(DECLARED[5], False, "GET /api/status has no reminders_list: the installed daemon predates the Ostler list (or the field was dropped)")
    elif rl.get("available") is False:
        add(DECLARED[5], None, "N/A-on-this-build: the daemon reports reminders push is not built in (available=false)")
    elif not rl.get("measured") and rl.get("authorization") in ("not_determined", "denied", "restricted"):
        add(DECLARED[5], None, "CANNOT-RUN (tcc): the list is unmeasured because the daemon's Reminders permission is {} (reminders_list.authorization); only a human at the console can answer the prompt or grant it".format(rl.get("authorization")))
    elif not rl.get("measured"):
        add(DECLARED[5], False, "the daemon has not measured the list yet (measured=false) after the wait budget; the watcher is not ticking")
    elif rl.get("removed"):
        add(DECLARED[5], False, "the daemon reports the Ostler list REMOVED (stored id gone); pushes are paused")
    elif status not in ("pushed",):
        add(DECLARED[5], None, "NOT MEASURED: nothing was pushed this run (status={}), so the list may legitimately not exist yet (present={}, id_stored={})".format(status, rl.get("present"), rl.get("id_stored")))
    elif not (rl.get("present") and rl.get("id_stored")):
        add(DECLARED[5], False, "a reminder was pushed but the daemon reports the Ostler list present={}, id_stored={}".format(rl.get("present"), rl.get("id_stored")))
    elif not (isinstance(rl.get("pushed_in_list"), int) and rl["pushed_in_list"] >= 1):
        add(DECLARED[5], False, "the Ostler list exists but holds {} reminders after a push".format(rl.get("pushed_in_list")))
    else:
        add(DECLARED[5], True, "Ostler list present, id stored, not removed, holds {} reminder(s)".format(rl["pushed_in_list"]))


def _finish(out):
    names = [n for n, _, _ in out]
    missing = [x for x in DECLARED if x not in names]
    out.append(("todo-reminders probe: every declared assertion produced a row", not missing, ", ".join(missing)))
    return out


# ---------------------------------------------------------------------------
# self-test
# ---------------------------------------------------------------------------

def _good():
    return {
        "write": {"attempted": True, "todo_id": "abc123"},
        "push": {"status": "pushed", "waited_s": 12, "calendar_item_identifier": "ek-9f8e"},
        "readback": {"attempted": True, "blocked_tcc": False, "found": True},
        "cleanup": {"db_deleted": True, "calendar_item_identifier": "ek-9f8e",
                    "expected_title": "Follow up on conversation", "reminder": {"state": "deleted"}},
        "one_to_one": {"attempted": True, "todo_id": "def456"},
        "one_to_one_push": {"status": "pushed", "waited_s": 9},
        "predicate_unavailable_rows": 0,
        "reminders_list": {"read": True, "present_in_status": True, "available": True, "measured": True,
                           "present": True, "id_stored": True, "pushed_in_list": 2, "removed": False},
    }


def self_test():
    import copy
    fails = []

    def row(f, i):
        return [ok for n, ok, _ in judge(f) if n == DECLARED[i]]

    g = _good()
    if any(ok is not True for _, ok, _ in judge(g)):
        print("SELF-TEST BROKEN: the good fixture fails: {}".format([(n, d) for n, ok, d in judge(g) if ok is not True]))
        return EX_FAIL
    print("  ok    good fixture: every assertion passes")

    dry = {"write": {"attempted": False, "error": "no settings.yaml user_id"}}
    if any(row(dry, i) != [None] for i in range(6)):
        fails.append("a failed write should cascade CANNOT-RUN to all six: {}".format([row(dry, i) for i in range(6)]))
    else:
        print("  ok    a failed write cascades CANNOT-RUN to all six assertions, never a pass")

    stuck = copy.deepcopy(g); stuck["push"] = {"status": "pending", "waited_s": 120}
    if row(stuck, 1) != [False]:
        fails.append("a pending row never claimed should FAIL (b): {}".format(row(stuck, 1)))
    else:
        print("  ok    mutant caught: the pending row is never claimed within the wait budget")

    denied = copy.deepcopy(g); denied["push"] = {"status": "permission_denied", "waited_s": 10}
    if row(denied, 1) != [False]:
        fails.append("permission_denied should FAIL (b): {}".format(row(denied, 1)))
    else:
        print("  ok    mutant caught: the daemon reports permission_denied")

    # Walk #11: the daemon says permission_denied, and TCC.db is read to tell
    # an undecided prompt (no row) from a real refusal.
    for state, want, label in (("absent", None, "CANNOT-RUN (console grant needed)"),
                               ("denied", False, "FAIL"),
                               ("allowed", False, "FAIL (granted, yet the daemon says denied)")):
        t = copy.deepcopy(g)
        t["push"] = {"status": "permission_denied", "waited_s": 10}
        t["tcc_reminders"] = {"state": state, "auth_value": {"denied": [0], "allowed": [2]}.get(state)}
        if row(t, 1) != [want]:
            fails.append("permission_denied with TCC {} should be {} (b): {}".format(state, want, row(t, 1)))
        else:
            print("  ok    permission_denied with TCC row {}: {}".format(state, label))

    # Walk #11 as it actually happened: NEVER CLAIMED. With no TCC row it is a
    # missing console grant; with the grant present a stall is a real FAIL.
    for state, want, label in (("absent", None, "CANNOT-RUN (console grant needed)"),
                               ("allowed", False, "FAIL (granted, and the daemon still never claimed it)"),
                               ("denied", False, "FAIL")):
        t = copy.deepcopy(g)
        t["push"] = {"status": "pending", "waited_s": 90}
        t["tcc_reminders"] = {"state": state, "auth_value": {"denied": [0], "allowed": [2]}.get(state)}
        if row(t, 1) != [want]:
            fails.append("never-claimed with TCC {} should be {} (b): {}".format(state, want, row(t, 1)))
        else:
            print("  ok    never claimed with TCC row {}: {}".format(state, label))

    tcc = copy.deepcopy(g); tcc["readback"] = {"attempted": True, "blocked_tcc": True}
    if row(tcc, 2) != [None]:
        fails.append("a TCC-blocked read-back should be CANNOT-RUN (c), got {}".format(row(tcc, 2)))
    else:
        print("  ok    a TCC-blocked AppleScript read is CANNOT-RUN, never a pass on the mapping table's word alone")

    missing = copy.deepcopy(g); missing["readback"] = {"attempted": True, "blocked_tcc": False, "found": False}
    if row(missing, 2) != [False]:
        fails.append("pushed but not visible in Reminders.app should FAIL (c): {}".format(row(missing, 2)))
    else:
        print("  ok    mutant caught: EventKit says pushed but the reminder is not actually visible")

    for label, cl, want in (
            ("delete refused by TCC", {"calendar_item_identifier": "ek-1", "reminder": {"state": "blocked_tcc"}}, None),
            ("delete failed", {"calendar_item_identifier": "ek-1", "reminder": {"state": "failed", "error": "boom"}}, False),
            ("reminder_deleted=false in the old shape", {"reminder_deleted": False, "db_deleted": True}, False),
            ("forget returned nothing", None, None)):
        c = copy.deepcopy(g); c["cleanup"] = cl
        if row(c, 3) != [want]:
            fails.append("cleanup {} should be {} (d): {}".format(label, want, row(c, 3)))
        else:
            print("  ok    cleanup mutant caught: {}".format(label))
    # the 1:1 reminder is judged too: FAIL dominates
    for label, one, want in (
            ("1:1 delete failed", {"calendar_item_identifier": "ek-2", "reminder": {"state": "failed", "error": "boom"}}, False),
            ("1:1 delete refused by TCC", {"calendar_item_identifier": "ek-2", "reminder": {"state": "blocked_tcc"}}, None),
            ("1:1 deleted", {"calendar_item_identifier": "ek-2", "reminder": {"state": "deleted"}}, True)):
        c = copy.deepcopy(g); c["cleanup"]["one_to_one"] = one
        if row(c, 3) != [want]:
            fails.append("cleanup {} should be {} (d): {}".format(label, want, row(c, 3)))
        else:
            print("  ok    cleanup mutant caught: {}".format(label))
    c = copy.deepcopy(g); c["cleanup"]["reminder"] = {"state": "blocked_tcc"}
    c["cleanup"]["one_to_one"] = {"reminder": {"state": "failed", "error": "x"}}
    if row(c, 3) != [False]:
        fails.append("FAIL must dominate CANNOT-RUN across both reminders: {}".format(row(c, 3)))
    else:
        print("  ok    FAIL dominates CANNOT-RUN across the solo and 1:1 reminders")
    named = [d for n, ok, d in judge(dict(g, cleanup={"calendar_item_identifier": "ek-1", "reminder": {"state": "blocked_tcc"}})) if n == DECLARED[3]]
    if not named or "ek-1" not in named[0] or "Follow up" not in named[0]:
        fails.append("a CANNOT-RUN cleanup must name the reminder: {}".format(named))

    # people rules: import failure must FAIL (not read as generic), and a 1:1
    # row that never got written must not pass.
    for label, mut, want in (
        ("an import failure (rows with the distinct reason)", {"predicate_unavailable_rows": 3}, False),
        ("a 1:1 row skipped by the gate", {"one_to_one_push": {"status": "skipped", "skip_reason": "non_human_sender"}}, False),
        ("an unreadable reason count", {"predicate_unavailable_rows": None}, None),
        ("a 1:1 row that was never written", {"one_to_one": {"attempted": False, "error": "x"}}, None),
    ):
        t = copy.deepcopy(g); t.update(mut)
        if row(t, 4) != [want]:
            fails.append("people rules: {} should be {}: {}".format(label, want, row(t, 4)))
        else:
            print("  ok    mutant caught (people rules): {}".format(label))

    # ostler list
    for label, rl, push, want in (
        ("the list REMOVED", {"removed": True, "present": False}, None, False),
        ("a pushed reminder but the list absent", {"present": False}, None, False),
        ("a pushed reminder, no id stored", {"id_stored": False}, None, False),
        ("a pushed reminder, 0 in the list", {"pushed_in_list": 0}, None, False),
        ("a daemon with no reminders_list field", {"__drop__": True}, None, False),
        ("status endpoint unreadable", {"__unread__": True}, None, None),
        ("nothing pushed this run", {}, {"status": "pending", "waited_s": 90}, None),
        ("unmeasured, permission not_determined", {"measured": False, "authorization": "not_determined"}, None, None),
        ("unmeasured, permission denied", {"measured": False, "authorization": "denied"}, None, None),
        ("unmeasured, permission GRANTED (count unreadable)", {"measured": False, "authorization": "authorized"}, None, False),
        ("unmeasured, permission unknown", {"measured": False, "authorization": ""}, None, False),
    ):
        t = copy.deepcopy(g)
        if rl.get("__drop__"):
            t["reminders_list"] = {"read": True, "present_in_status": False}
        elif rl.get("__unread__"):
            t["reminders_list"] = {"read": False, "error": "HTTP 401"}
        else:
            t["reminders_list"].update(rl)
        if push:
            t["push"] = push
        if row(t, 5) != [want]:
            fails.append("ostler list: {} should be {}: {}".format(label, want, row(t, 5)))
        else:
            print("  ok    mutant caught (ostler list): {}".format(label))

    if [ok for n, ok, _ in judge({}) if n in DECLARED and ok is True]:
        fails.append("an empty collection reads as a pass")
    if fails:
        print("SELF-TEST FAIL: " + "; ".join(fails))
        return EX_FAIL
    print("SELF-TEST PASS: good fixture passes, every mutant caught by their own assertion")
    return EX_PASS


def report(rows):
    for name, ok, detail in rows:
        tag = "  N/A   " if ok == NA else ("  ok    " if ok is True else ("  CANNOT " if ok is None else "  FAIL  "))
        print(tag + name + ("" if ok is True or not detail else "  -- " + detail))
    fails = [n for n, ok, _ in rows if ok is False]
    cannot = [n for n, ok, _ in rows if ok is None]
    print("EXAMINED: {} todo-reminders assertions ({} failed, {} not measured)".format(len(rows), len(fails), len(cannot)))
    return EX_FAIL if fails else (EX_CANNOT if cannot else EX_PASS)


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    if argv[:1] == ["judge"]:
        return report(judge(json.load(open(argv[1]))))
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
