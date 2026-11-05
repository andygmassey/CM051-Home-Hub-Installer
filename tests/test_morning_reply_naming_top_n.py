#!/usr/bin/env python3
"""morning_brief_catches_me_up, reply-naming arm: grade only the owed rows the hub
ranks into the shown top N (N = REPLY_MAX_ITEMS, read from oa source, never typed
here), accept a unique first name, count "and N more" against the owed rows past N,
and LOG every row that is not graded with its reason.

Context: v1.0.124 tagged walk, "names who is waiting on a reply (2 of 3)" after oa
#671 lowered the cap from 8 to 5; Archie kept 5. Synthetic people only.

Controls (each must go red for its own reason):
  - a row INSIDE the top N missing from the brief FAILs
  - a row ranked past N passes, when the brief says "and K more" and K is right
  - a WRONG "and K more" count FAILs
  - MUTANT: grading that ignores the rank (grades every owed row) turns the
    past-the-cap case red
  - a non-owed or ambiguous row is dropped AND logged with its reason (a classifier
    drop can never hide behind the cap)
  - a first name shared by two rows is NOT accepted alone
  - the cap is read from source text, and a missing source is NOT INSTRUMENTED

WOW_MOMENTS_SUBJECT=<path> points at another copy. Exit: 0 holds | 1 broken
"""
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SUBJ = os.environ.get("WOW_MOMENTS_SUBJECT") or os.path.join(HERE, "..", "scripts", "box_walk_probes", "lib", "wow_moments.py")
spec = importlib.util.spec_from_file_location("wow_moments_subject", SUBJ)
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)

fail = 0


def check(label, ok, detail=""):
    global fail
    print("  %s  %s%s" % ("ok  " if ok else "FAIL", label, "" if ok else "  [" + str(detail)[-300:] + "]"))
    fail += 0 if ok else 1


def row(name, owed="yes", hours=30, **kw):
    d = {"person_name": name, "resolved": True, "owed": owed, "waiting_hours": hours, "privacy_level": "L1"}
    d.update(kw)
    return d


# Seven owed rows in the hub's order, cap 5: rows 6 and 7 are past the cap.
NAMES = ["Jane Smith", "Tom Jones", "Sam Doe", "John Doe", "Bob Brown",
         "Alex Patel", "Mary Ross"]
OWED7 = [row(n, hours=200 - 10 * i) for i, n in enumerate(NAMES)]
BRIEF5 = ("Worth replying to:\n" + "\n".join("- %s (waiting 2 days)" % n for n in NAMES[:5])
          + "\n- and 2 more in the app")


def run(debts, text, cap=5):
    cap_ = json.loads(json.dumps(w.grade_morning_replies(debts, text, cap)))   # what crosses the wire
    lines, rc = w.judge_morning(dict(MORNING_GOOD, **cap_))
    return "\n".join(lines), rc, cap_


MORNING_GOOD = {"endpoint": 200, "degraded": False, "answered": True, "run_status": "ok",
                "owner_promise": True, "other_promise": False, "prompt_covers_today": True,
                "iso_date_leak": False, "chat_echo": False, "repeats": 0,
                "meetings_graded": 0, "meetings_named": [], "reply_source": "ok"}

# 1. cap read from source, never typed
src = "/// doc\nconst REPLY_MAX_ITEMS: usize = 5;\nconst MAX_ITEMS: usize = 5;\n"
check("the cap is read from the oa source text", w.reply_cap_from_source(src) == 5)
check("a source without the constant gives None, never a guess", w.reply_cap_from_source("const MAX_ITEMS: usize = 5;") is None)
os.environ.pop("OSTLER_REPLY_MAX_ITEMS", None)
check("no cap given: NOT INSTRUMENTED", w.reply_cap() == (None, "NOT INSTRUMENTED"), w.reply_cap())
os.environ["OSTLER_REPLY_MAX_ITEMS"] = "8"
check("cap from the environment the wrapper forwards", w.reply_cap()[0] == 8, w.reply_cap())
os.environ.pop("OSTLER_REPLY_MAX_ITEMS", None)

# 2. all top-5 named, 2 past the cap counted correctly: passes
out, rc, cap_ = run(OWED7, BRIEF5)
check("top 5 named and 'and 2 more' correct: PASS", rc == w.EX_PASS, out)
check("graded exactly the top 5", cap_["reply_graded"] == 5, cap_["reply_graded"])
check("the two rows past the cap are LOGGED with their rank", out.count("reason=cap_rank_") == 2, out)

# 3. RED CONTROL: a row inside the top N missing from the brief
text = BRIEF5.replace("- Sam Doe (waiting 2 days)\n", "")
out, rc, _ = run(OWED7, text)
check("a row inside the top N missing from the brief FAILs", rc == w.EX_FAIL and "names who is waiting on a reply (4 of 5)" in out, out)

# 4. a row past N is not required
text = BRIEF5  # Fay and Gus are not named, as designed
out, rc, _ = run(OWED7, text)
check("rows ranked past N pass as 'and N more'", rc == w.EX_PASS and "Alex" not in text, out)

# 5. RED CONTROL: the count is wrong
for bad in ("- and 3 more in the app", "- and 1 more in the app"):
    out, rc, _ = run(OWED7, BRIEF5.replace("- and 2 more in the app", bad))
    check("a wrong count (%s) FAILs" % bad[2:], rc == w.EX_FAIL and "equals the owed rows past" in out, out)
out, rc, _ = run(OWED7, BRIEF5.replace("\n- and 2 more in the app", ""))
check("a missing count FAILs when owed rows are past the cap", rc == w.EX_FAIL, out)

# 6. MUTANT: grading ignores the rank
orig = w.plan_morning_replies


def ignores_rank(debts, cap):
    p = orig(debts, 10 ** 6)
    p["cap"] = cap
    return p


w.plan_morning_replies = ignores_rank
out, rc, _ = run(OWED7, BRIEF5)
check("MUTANT (grading ignores the rank) goes RED on the past-the-cap case", rc == w.EX_FAIL, out)
w.plan_morning_replies = orig

# 7. a classifier drop is logged, never hidden behind the cap
mixed = [row("Tom Jones"), row("Sam Doe", owed="no"), row("John Doe", owed="ambiguous"),
         row("Bob Brown", owed=None), row("Liz Stewart", resolved=False)]
text = "- Tom Jones (waiting 1 day)\n- Bob Brown (waiting 1 day)"
out, rc, cap_ = run(mixed, text)
reasons = sorted(d["reason"] for d in cap_["reply_drops"])
check("not_owed, ambiguous and unsaved rows are each logged with a reason",
      reasons == ["no_judge", "not_owed", "unsaved_number"], reasons)
check("a row with no hub verdict (older Hub) is still graded, as before",
      cap_["reply_graded"] == 2 and rc == w.EX_PASS, cap_["reply_graded"])
check("a dropped row is not required in the brief", rc == w.EX_PASS, out)
check("no name leaks through the drop log", "Doe" not in out and "Stewart" not in out and "Sam" not in out, out)

# 8. a first name alone, when unique
out, rc, _ = run([row("Raj Patel")], "- Raj (waiting 1 day)")
check("a unique first name alone counts as naming the person", rc == w.EX_PASS, out)
out, rc, _ = run([row("Jane Smith"), row("Jane Doe")], "- Jane (waiting 1 day)")
check("a first name two rows share is NOT enough", rc == w.EX_FAIL, out)
out, rc, _ = run([row("Raj Patel")], "- Someone (waiting 1 day)")
check("an absent person still FAILs", rc == w.EX_FAIL, out)

# 9. no cap known: legacy top 3, no count check, said so
out, rc, cap_ = run(OWED7, "\n".join("- %s" % n for n in NAMES[:3]), cap=None)
check("cap NOT INSTRUMENTED: legacy top 3 graded, no count check, labelled", rc == w.EX_PASS and cap_["reply_graded"] == 3
      and "NOT INSTRUMENTED" in out and "equals the owed rows" not in out, out)

# 10. owed rows within the cap need no count
out, rc, _ = run(OWED7[:4], "\n".join("- %s" % n for n in NAMES[:4]))
check("owed rows within the cap: no 'more' line needed", rc == w.EX_PASS, out)

print("morning reply naming top N: %s" % ("holds" if not fail else "BROKEN (%d)" % fail))
sys.exit(1 if fail else 0)
