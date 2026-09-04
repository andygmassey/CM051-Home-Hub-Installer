#!/usr/bin/env python3
"""The red-merge predicate must FIRE on a real red and STAY QUIET on a fixed one.

Without this, audit_red_merges.py is a tool that has only ever printed GREEN, and
"it printed GREEN" would be indistinguishable from "it cannot print anything else".
That is the exact failure the audit itself exists to detect, so it must not be the
audit's own failure.

⚠️ THIS FILE USED TO BE DECORATION, AND I WROTE IT THAT WAY.

The first version carried its own copy of the predicate under a docstring reading
"Mirrors audit_red_merges.py". Every case below passed against the COPY. Breaking
the real script could never have turned this red -- a green light with no bulb
behind it, which is precisely what the new-tests-must-be-wired gate exists to
refuse, and I tripped that gate while adding this file. Mirroring is not testing.
It now IMPORTS the shipping functions, and a binding control below proves it.

Exit: 0 pass, 1 RED (the predicate is wrong), 2 CANNOT-RUN (never a pass).
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_SCRIPTS = os.path.join(os.path.dirname(_HERE), "scripts")
sys.path.insert(0, _SCRIPTS)

# A failed import is CANNOT-RUN, never a pass. If the module moves or stops
# parsing, "the predicate is fine" and "nothing was examined" print identically
# unless this refuses out loud.
try:
    import audit_red_merges as A
except Exception as exc:                                  # noqa: BLE001
    print(f"CANNOT-RUN: cannot import audit_red_merges from {_SCRIPTS}: {exc}")
    print("This is not a pass.")
    sys.exit(2)


def main():
    fails = 0

    # ── BINDING CONTROL ────────────────────────────────────────────────────────
    # Prove the thing under test is the SHIPPING file, not a local copy that has
    # drifted from it. This is the control the first version of this file lacked
    # entirely, and its absence is the whole reason that version was worthless.
    mod_file = os.path.abspath(getattr(A, "__file__", ""))
    want = os.path.join(_SCRIPTS, "audit_red_merges.py")
    if mod_file != os.path.abspath(want):
        print(f"CANNOT-RUN: imported {mod_file}, expected {want}")
        print("Every case below would be testing the wrong file. This is not a pass.")
        return 2
    for fn in ("classify", "last_word_per_name"):
        if not callable(getattr(A, fn, None)):
            print(f"CANNOT-RUN: {want} has no callable {fn}()")
            print("The predicate was re-inlined into main(). This is not a pass.")
            return 2
    print(f"ok   binding: testing the shipping predicate in {os.path.relpath(want, os.path.dirname(_HERE))}")

    def verdict(rows, merged):
        return A.classify(rows, merged)[0]

    def flagged_names(detail):
        """Job names inside a RED-AT-MERGE detail, whatever the key shape is.

        Deliberately shape-agnostic. A mutation that changes the key from
        (workflow, name) to a bare name must produce a READABLE RED here, not a
        ValueError: a traceback exits 1 exactly like a clean failure does, so a
        crashing assertion would let me record "the mutation was caught" when in
        fact the run never reached the case that was supposed to catch it. That
        happened, and it is why this helper exists.
        """
        if not isinstance(detail, dict):
            return set()
        out = set()
        for k in detail:
            out.add(k[1] if isinstance(k, tuple) and len(k) >= 2 else k)
        return out

    # 1. POSITIVE CONTROL -- a genuine red merge. MUST fire.
    v = verdict([("wf-a.yml", "ledger-pr", "failure", "2026-09-01T10:00:00Z")], "2026-09-01T10:05:00Z")
    if v != "RED-AT-MERGE":
        print(f"RED  case 1: a gate that failed and never re-passed read as {v}"); fails += 1
    else:
        print("ok   case 1: genuine red merge flagged")

    # 2. THE ONE I GOT WRONG -- failed, then RE-PASSED before the merge. MUST be green.
    #    This is the case that made me nearly post a false accusation that three
    #    colleagues had merged over their own gate seven times. The real answer was 0.
    v = verdict([("wf-a.yml", "ledger-pr", "failure", "2026-09-01T10:00:00Z"),
                 ("wf-a.yml", "ledger-pr", "success", "2026-09-01T10:03:00Z")], "2026-09-01T10:05:00Z")
    if v != "GREEN":
        print(f"RED  case 2: a SUPERSEDED failure was counted as a verdict -> {v}"); fails += 1
    else:
        print("ok   case 2: superseded failure ignored (this is the bug I shipped first)")

    # 3. Re-passed AFTER the merge -- the fix came too late. MUST fire.
    v = verdict([("wf-a.yml", "ledger-pr", "failure", "2026-09-01T10:00:00Z"),
                 ("wf-a.yml", "ledger-pr", "success", "2026-09-01T10:09:00Z")], "2026-09-01T10:05:00Z")
    if v != "RED-AT-MERGE":
        print(f"RED  case 3: a post-merge fix excused a red merge -> {v}"); fails += 1
    else:
        print("ok   case 3: post-merge success does not excuse the merge")

    # 4. Two names, one red -- must not be masked by the other's success.
    v, detail = A.classify([("wf-a.yml", "ledger-pr", "success", "2026-09-01T10:01:00Z"),
                            ("wf-b.yml", "scan", "failure", "2026-09-01T10:02:00Z")], "2026-09-01T10:05:00Z")
    if v != "RED-AT-MERGE" or "scan" not in flagged_names(detail):
        print(f"RED  case 4: a red check was masked by a different green check -> {v} {detail}"); fails += 1
    else:
        print("ok   case 4: per-NAME grouping keeps one red visible")

    # 5. STILL RUNNING at merge time. MUST be CANNOT-RUN, never GREEN.
    #    A check with conclusion null did not pass; it had not finished. Bucketing
    #    it with the passes makes GREEN mean "nothing had failed YET", and absence
    #    of failure is not a pass.
    v, detail = A.classify([("wf-a.yml", "ledger-pr", "success", "2026-09-01T10:01:00Z"),
                            ("wf-b.yml", "scan", "null", "")], "2026-09-01T10:05:00Z")
    if v != "CANNOT-RUN":
        print(f"RED  case 5: a check still running at merge read as {v} -> {detail}"); fails += 1
    else:
        print("ok   case 5: an unfinished check is CANNOT-RUN, not GREEN")

    # 6. Zero rows. A sha with no runs is unmeasured, not clean.
    v = verdict([], "2026-09-01T10:05:00Z")
    if v != "CANNOT-RUN":
        print(f"RED  case 6: zero check runs read as {v}"); fails += 1
    else:
        print("ok   case 6: zero check runs is CANNOT-RUN, not GREEN")

    # 7. A conclusion string nobody has seen yet must not default to green.
    v = verdict([("wf-b.yml", "scan", "some_new_github_conclusion", "2026-09-01T10:01:00Z")],
                "2026-09-01T10:05:00Z")
    if v == "GREEN":
        print("RED  case 7: an unrecognised conclusion defaulted to GREEN"); fails += 1
    else:
        print(f"ok   case 7: an unrecognised conclusion is not GREEN (got {v})")

    # 8. NAME COLLISION -- the defect my own CI surfaced in this very tool.
    #    `predicate-self-test` is emitted by 4 DIFFERENT workflows in this repo,
    #    and on sha 4d18745c one was red while the others were green. Keyed by
    #    name alone the last green wins and the red vanishes. MUST fire.
    v, detail = A.classify([
        ("calendar-backfill-multiyear.yml", "predicate-self-test", "failure", "2026-09-01T10:01:00Z"),
        ("fda-rerun-ingests.yml",           "predicate-self-test", "success", "2026-09-01T10:02:00Z"),
        ("fda-rerun-recurs.yml",            "predicate-self-test", "success", "2026-09-01T10:03:00Z"),
    ], "2026-09-01T10:05:00Z")
    if v != "RED-AT-MERGE" or "predicate-self-test" not in flagged_names(detail):
        print(f"RED  case 8: a red was MASKED by a same-named check from another workflow "
              f"-> {v} {sorted(flagged_names(detail))}"); fails += 1
    else:
        print("ok   case 8: same job name in 3 workflows, the one red still visible")

    # 9. The collision fix must NOT break supersession. Same workflow, same job,
    #    failed then re-passed: still GREEN. This is the pair that makes the key
    #    correct in both directions -- case 8 alone could be satisfied by keying
    #    on anything unique per run, which would resurrect the 7-of-60 error.
    v = verdict([("wf-a.yml", "ledger-pr", "failure", "2026-09-01T10:00:00Z"),
                 ("wf-a.yml", "ledger-pr", "success", "2026-09-01T10:03:00Z")],
                "2026-09-01T10:05:00Z")
    if v != "GREEN":
        print(f"RED  case 9: keying too finely broke supersession within one workflow -> {v}"); fails += 1
    else:
        print("ok   case 9: re-run within a workflow still supersedes its own failure")

    # ── MUTATION CONTROL ──────────────────────────────────────────────────────
    # Every case above asserts a verdict, so a classify() that returned one
    # constant would fail somewhere. Prove it explicitly anyway: the predicate
    # must be capable of producing all THREE states from the same code path.
    # A two-state predicate is how a warning gets read as a pass.
    seen = {verdict([("wf-a.yml", "a", "failure", "2026-09-01T10:00:00Z")], "2026-09-01T10:05:00Z"),
            verdict([("wf-a.yml", "a", "success", "2026-09-01T10:00:00Z")], "2026-09-01T10:05:00Z"),
            verdict([], "2026-09-01T10:05:00Z")}
    if seen != {"RED-AT-MERGE", "GREEN", "CANNOT-RUN"}:
        print(f"CANNOT-RUN: classify() produced {sorted(seen)}, not all three states.")
        print("A predicate that cannot say all three things has not been tested by the above.")
        return 2
    print("ok   control: classify() demonstrably produces all THREE states")

    print()
    if fails:
        print(f"FAIL: {fails} of 9 predicate cases wrong")
        return 1
    print("PASS: 9 of 9 cases + binding control + 3-state mutation control")
    return 0


if __name__ == "__main__":
    sys.exit(main())
