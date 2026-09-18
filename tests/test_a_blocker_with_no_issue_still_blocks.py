#!/usr/bin/env python3
"""BLOCKING is a verdict, and a verdict with no tracker issue still blocks.

TWO DEFECTS, ONE IN EACH DIRECTION, BOTH MEASURED ON cut-manifests/v1.0.100.yaml
ON 2026-09-18.

TOO LOOSE. The predicate took the text before the first colon and asked whether
BLOCKING appeared in it. Seven rows matched and only FOUR declare themselves
blockers. The other three carry the word inside prose whose head happens to have
no early colon, and all three describe work that is DONE:

    1969  "GATED by entry probe-..., WHICH MUST BE MADE BLOCKING. Merged"
    1922  "FIXED AND GUARDED, MERGED as #2005, and it was BLOCKING A REAL PR"
    1012  "FIXED HERE. I reported doctor_page_renders_for_a_customer ..."

TOO WEAK. Every one of the four real blockers declares `repo: none`, because a
measured finding has no tracker issue. Those rows were printed as a note and
then DROPPED, and counted in a pass line reading "N BLOCKING row(s) examined,
all closed or none present". So the word was load-bearing for exactly the rows
that name an issue and inert for the ones that carry a finding, which is all of
them. That is the defect Andy's 2026-09-06 call created this property to stop,
surviving inside the property itself.

THE DISCRIMINATOR IS POSITION AND THE THRESHOLD IS MEASURED, NOT CHOSEN. A row
states its verdict first. On the live board the word sits at index 2 in every
true blocker and at 5 in the documented "FIX (BLOCKING):" form, while the three
false ones carry it at 47 and 66. A window of 24 sits in a gap of 42 characters.

THE HEAD ENDS AT THE FIRST COLON OR THE FIRST FULL STOP, whichever comes first.
Without the full stop, "BLOCKING. MEASURED BY TNM ..." has no colon for a
hundred characters and the whole paragraph becomes the disposition.

Exit 0 all arms pass, 1 any arm fails.
"""
from __future__ import annotations

import importlib.util
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
GATE = ROOT / "tests" / "test_the_cut_checklist_is_complete.py"

PASS = 0
FAIL = 0


def ok(m):
    global PASS
    PASS += 1
    print(f"  ok    {m}")


def bad(m, d=""):
    global FAIL
    FAIL += 1
    print(f"  FAIL  {m}")
    if d:
        print(f"        | {d}")


def load():
    spec = importlib.util.spec_from_file_location("_cutgate", GATE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# Verbatim heads from the live board. The three FALSE ones are quoted because a
# fixture invented from the predicate can only encode the shape it already
# handles, and these three are exactly what it did NOT handle.
DECLARES = [
    ("\U0001f534 BLOCKING. MEASURED BY TNM ON THE BOX 2026-09-18, read-only", "2155"),
    ("\U0001f534 BLOCKING (both halves are now built and neither is proven on a box): ANDY DECIDED", "971"),
    ("FIX (BLOCKING): the documented disposition form", "the form named in the gate's own comment"),
    ("BLOCKING: bare, no marker", "the simplest possible form"),
]
DOES_NOT_DECLARE = [
    ("GATED by entry probe-ostler-unlock-reachable-by-name, WHICH MUST BE MADE BLOCKING. Merged", "1969"),
    ("FIXED AND GUARDED, MERGED as #2005, and it was BLOCKING A REAL PR WHEN IT WAS FIXED. This", "1922"),
    ("FIXED HERE. I reported doctor_page_renders_for_a_customer as written, and it was BLOCKING", "1012"),
    ("NOT BLOCKING (reporting accuracy): the documented negative form", "the gate's own comment"),
    ("DEFER: nothing here at all", "a row with no such word"),
]


def main():
    print("test_a_blocker_with_no_issue_still_blocks")
    m = load()

    # ── 0. CONTROL FIRST: the predicate discriminates at all. ────────────
    # An arm list of "these are true" and "these are false" passes for a
    # predicate that returns a constant only if one list is empty. Both are
    # non-empty and both verdicts must appear.
    verdicts = {m._says_blocking(t) for t, _ in DECLARES + DOES_NOT_DECLARE}
    if verdicts == {True, False}:
        ok("(0) CONTROL: the predicate returns both verdicts across the fixtures, "
           "so it is not a constant")
    else:
        bad("(0) CONTROL FAILED: the predicate returned only %r" % verdicts)
        return 1

    for text, who in DECLARES:
        if m._says_blocking(text):
            ok(f"(1) declares itself blocking: {who}")
        else:
            bad(f"(1) a real blocker was MISSED: {who}", text[:80])

    for text, who in DOES_NOT_DECLARE:
        if not m._says_blocking(text):
            ok(f"(2) not a verdict, so not counted: {who}")
        else:
            bad(f"(2) prose read as a verdict: {who}", text[:80])

    # ── 3. NOTHING IS DROPPED SILENTLY. ─────────────────────────────────
    # A narrower predicate that says nothing about what it declined to read is
    # how coverage shrinks unnoticed. The three measured false positives must
    # be REPORTED by the companion reader.
    missed = [who for text, who in DOES_NOT_DECLARE[:3]
              if not m._mentions_blocking_outside_the_verdict(text)]
    if not missed:
        ok("(3) every row carrying the word outside its verdict is still reported")
    else:
        bad("(3) rows carrying the word are neither counted nor reported", str(missed))
    if m._mentions_blocking_outside_the_verdict(DECLARES[0][0]):
        bad("(3b) a real blocker was ALSO reported as a mere mention, so the two "
            "buckets overlap and the counts double-count")
    else:
        ok("(3b) the two buckets are disjoint: a real blocker is not also a mention")

    # ── 4. THE THRESHOLD, PINNED FROM BOTH SIDES. ───────────────────────
    w = m._BLOCKING_VERDICT_WINDOW
    inside = "X" * w + "BLOCKING: reasoning"
    outside = "X" * (w + 1) + "BLOCKING: reasoning"
    if m._says_blocking(inside) and not m._says_blocking(outside):
        ok(f"(4) the window is exactly {w}: at {w} it is a verdict, at {w + 1} it is not")
    else:
        bad(f"(4) the window at {w} does not discriminate",
            f"inside={m._says_blocking(inside)} outside={m._says_blocking(outside)}")

    # ── 5. THE HEAD ENDS AT A FULL STOP, NOT ONLY AT A COLON. ───────────
    # Without this, a row whose first colon is a hundred characters away has a
    # whole paragraph for a disposition, which is how 1922 and 1012 matched.
    if m._disposition("BLOCKING. then a sentence: with a colon later") == "BLOCKING":
        ok("(5) the disposition stops at the first full stop")
    else:
        bad("(5) the disposition ran past the full stop",
            repr(m._disposition("BLOCKING. then a sentence: with a colon later")))

    # ── 6. THE PROPERTY ON THE LIVE BOARD, not a count. ─────────────────
    # A count would go stale on the next row. The invariant is that every row
    # the predicate calls a blocker really does lead with the word.
    import yaml
    manifest = m.newest_manifest()
    if manifest is None:
        bad("(6) CANNOT-RUN: no per-cut manifest to read")
        return 1
    rows = (yaml.safe_load(manifest.read_text(encoding="utf-8")) or {}).get("open_issues") or []
    declared = [r for r in rows if m._says_blocking(str(r.get("gate", "")))]
    if not declared:
        bad("(6) NO row on the live board declares itself blocking, so this arm "
            "measured nothing. That is a zero denominator, not a clean sheet")
    else:
        stragglers = [r["issue"] for r in declared
                      if m._disposition(str(r.get("gate", ""))).find("BLOCKING") > w]
        if stragglers:
            bad("(6) a row was counted whose verdict does not lead with the word",
                str(stragglers))
        else:
            ok(f"(6) all {len(declared)} row(s) counted on {manifest.name} lead with "
               "the word in their verdict")

    # ── 7. THE WIRING ARM, AND IT IS THE ONE THAT MATTERS. ──────────────
    # Everything above tests a PREDICATE. A perfect predicate whose verdict the
    # gate then prints as a note and drops is exactly the defect this change
    # exists to remove, and every arm above passes on it. So the gate itself is
    # driven, as a cut, and its output read.
    import os
    import subprocess
    env = dict(os.environ, OSTLER_CUT_IN_PROGRESS="1")
    run = subprocess.run([sys.executable, str(GATE)], capture_output=True,
                         text=True, env=env, cwd=str(ROOT))
    out = run.stdout + run.stderr
    marker = "declare themselves BLOCKING and name no tracker issue"

    # 🔴 THE ASSERTION IS THAT ONE LINE CARRIES BOTH, NOT THAT THE OUTPUT
    # CONTAINS BOTH. The first version of this arm asked for `marker in out and
    # "CUT IS BLOCKED" in out`, and the mutant that put these rows back to a
    # note SURVIVED it: the ungated-rows property prints its own CUT IS BLOCKED
    # line, the note prints the marker, and two independent facts satisfied a
    # conjunction that was meant to pin one. Caught by running the mutant, not
    # by reading the arm.
    def _fail_line_with(text, needle):
        return [l for l in text.splitlines()
                if "CUT IS BLOCKED" in l and needle in l]

    if _fail_line_with(out, marker):
        ok("(7) the gate itself FAILS a cut ON THAT LINE for rows that declare "
           "themselves blocking and name no tracker issue")
    else:
        bad("(7) the predicate is right and the gate does not act on it: a "
            "blocker with no tracker issue still blocks nothing",
            out[-400:] + "  [tail 400 chars, said so here]")

    # CONTROL on the same command: OUTSIDE a cut the same rows must be reported
    # and must NOT fail. Without this, arm 7 passes for a gate that refuses
    # unconditionally, which would stop every pull request in the repository.
    run2 = subprocess.run([sys.executable, str(GATE)], capture_output=True,
                          text=True, cwd=str(ROOT))
    out2 = run2.stdout + run2.stderr
    if marker in out2 and not _fail_line_with(out2, marker) and run2.returncode == 0:
        ok("(7b) CONTROL: outside a cut the same rows are reported by number, on "
           "a line that is NOT a failure, and the gate exits 0")
    else:
        bad(f"(7b) CONTROL FAILED: outside a cut the gate exited {run2.returncode}, "
            "or did not report the rows, or reported them as a failure",
            out2[-400:] + "  [tail 400 chars, said so here]")

    print()
    print(f"=== {PASS} passed / {FAIL} failed ===")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
