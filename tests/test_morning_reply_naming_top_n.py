#!/usr/bin/env python3
"""morning_brief_catches_me_up, reply-naming arm. The daemon ranks and caps the list at
REPLY_MAX_ITEMS (oa catchup.rs) and counts the rest as "and N more"; the probe does NOT
re-implement that ranking. Predicate:
  owed <= N : every owed row is named (a unique first name is enough)
  owed >  N : exactly N owed rows are named (WHICH N is not graded), no row the hub says
              is not owed and no invented name is listed, and "and K more" = owed - N
N is READ from the oa commit the cut pins (cut.env DAEMON_COMMIT), never typed here.
Every row not graded is logged with its reason.

Context: v1.0.124 tagged walk, "names who is waiting on a reply (2 of 3)" after oa #671
lowered the cap from 8 to 5. Synthetic people only.

Controls (each must go red for its own reason):
  - owed <= N and one owed row missing from the brief FAILs
  - owed > N: fewer or more than N named FAIL; any N owed rows named PASS
  - a not-owed row listed, an invented name listed: FAIL
  - a wrong or missing "and K more": FAIL
  - MUTANT (grading ignores the cap) and MUTANT (grading re-ranks: hub top N) go RED
  - dropped rows are logged with reasons; the cap is read from source text and a
    missing source is NOT INSTRUMENTED

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


# Seven owed rows in the hub's order, cap 5.
NAMES = ["Jane Smith", "Tom Jones", "Sam Doe", "John Doe", "Bob Brown",
         "Alex Patel", "Mary Ross"]
OWED7 = [row(n, hours=200 - 10 * i) for i, n in enumerate(NAMES)]


def brief_of(names, more=None):
    t = "Worth replying to:\n" + "\n".join("- %s (waiting 2 days)" % n for n in names)
    return t + ("\n- and %d more in the app" % more if more is not None else "")


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
check("no cap given: NOT INSTRUMENTED", w.reply_cap()[0] is None and w.reply_cap()[1] == "NOT INSTRUMENTED", w.reply_cap())
os.environ["OSTLER_REPLY_MAX_ITEMS"] = "8"
os.environ["OSTLER_REPLY_CAP_SRC"] = "oa 0123abcd (cut.env DAEMON_COMMIT)"
check("cap and its pinned source come from the environment the wrapper forwards",
      w.reply_cap() == (8, "oa 0123abcd (cut.env DAEMON_COMMIT)"), w.reply_cap())
os.environ.pop("OSTLER_REPLY_MAX_ITEMS", None)
os.environ.pop("OSTLER_REPLY_CAP_SRC", None)

# 2. owed > N: any N owed rows, shown or not by hub order
for label, shown in (("hub order", NAMES[:5]), ("NOT the hub's top 5", [NAMES[0], NAMES[1], NAMES[2], NAMES[5], NAMES[6]])):
    out, rc, cap_ = run(OWED7, brief_of(shown, 2))
    check("owed 7, cap 5, five owed rows named (%s), 'and 2 more': PASS" % label, rc == w.EX_PASS, out)
check("the two unshown rows are not logged as drops (the daemon chose them, not the probe)",
      "reason=cap_rank" not in out, out)

# 3. RED CONTROLS, owed > N
out, rc, _ = run(OWED7, brief_of(NAMES[:4], 2))
check("owed 7: only 4 owed rows named FAILs", rc == w.EX_FAIL and "names who is waiting on a reply" in out, out)
out, rc, _ = run(OWED7, brief_of(NAMES[:6], 2))
check("owed 7: 6 owed rows named FAILs (more than the cap)", rc == w.EX_FAIL, out)
for bad in (3, 1):
    out, rc, _ = run(OWED7, brief_of(NAMES[:5], bad))
    check("a wrong count ('and %d more') FAILs" % bad, rc == w.EX_FAIL and "equals the owed rows past" in out, out)
out, rc, _ = run(OWED7, brief_of(NAMES[:5]))
check("a missing count FAILs when owed rows are past the cap", rc == w.EX_FAIL, out)

# 4. a not-owed row listed, an invented name listed
with_no = OWED7[:5] + [row("Liz Stewart", owed="no")]
out, rc, _ = run(with_no, brief_of(NAMES[:4] + ["Liz Stewart"]))
check("a row the hub says is NOT owed, listed in the brief: FAIL", rc == w.EX_FAIL and "not owed, and no invented name (1 wrong)" in out, out)
out, rc, _ = run(OWED7, brief_of(NAMES[:4] + ["Ana Invented"], 2))
check("an invented name listed: FAIL", rc == w.EX_FAIL and "(1 wrong)" in out, out)

# 5. owed <= N: every owed row named; the red control stays
OWED4 = OWED7[:4]
out, rc, _ = run(OWED4, brief_of(NAMES[:4]))
check("owed 4 (<= cap), all named, no count line: PASS", rc == w.EX_PASS, out)
out, rc, _ = run(OWED4, brief_of([NAMES[0], NAMES[1], NAMES[3]]))
check("owed <= cap and an owed row missing from the brief FAILs", rc == w.EX_FAIL and "(3 of 4)" in out, out)

# 6. MUTANTS
orig = w.plan_morning_replies
real_grade = w.grade_morning_replies


def ignores_cap(debts, text, cap):
    return real_grade(debts, text, 10 ** 6)          # strict: every owed row must be named


w.grade_morning_replies = ignores_cap
out, rc, _ = run(OWED7, brief_of([NAMES[0], NAMES[1], NAMES[2], NAMES[5], NAMES[6]], 2))
check("MUTANT (grading ignores the cap) goes RED on the five-of-seven case", rc == w.EX_FAIL, out)
w.grade_morning_replies = real_grade


def hub_top_n(debts, text, cap):
    r = real_grade(debts, text, cap)
    owed = [d for d in debts if d.get("owed") == "yes"]
    top = [w._named_morning(text, d, debts) for d in owed[:cap]]
    r["reply_named"], r["reply_graded"] = top, len(top)
    return r


w.grade_morning_replies = hub_top_n
out, rc, _ = run(OWED7, brief_of([NAMES[0], NAMES[1], NAMES[2], NAMES[5], NAMES[6]], 2))
check("MUTANT (grading re-ranks: hub top N) goes RED when the daemon shows other owed rows", rc == w.EX_FAIL, out)
w.grade_morning_replies = real_grade

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
