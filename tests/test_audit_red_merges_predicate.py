#!/usr/bin/env python3
"""The red-merge predicate must FIRE on a real red and STAY QUIET on a fixed one.

Without this, audit_red_merges.py is a tool that has only ever printed GREEN, and
"it printed GREEN" would be indistinguishable from "it cannot print anything else".
That is the exact failure the audit itself exists to detect, so it must not be the
audit's own failure.

The three cases below are the three that matter, and case 2 is the one my first
implementation got wrong -- it reported RED for a gate that had already re-passed.
"""
import sys

BAD = {"failure", "cancelled", "timed_out", "action_required", "stale"}


def last_word_per_name(rows, merged):
    """Mirrors audit_red_merges.py: last conclusion per NAME at or before merged."""
    last = {}
    for name, concl, done in rows:
        if done and done > merged:
            continue
        prev = last.get(name)
        if prev is None or done >= prev[1]:
            last[name] = (concl, done)
    return {n: c for n, (c, _) in last.items() if c in BAD}


def main():
    fails = 0

    # 1. POSITIVE CONTROL -- a genuine red merge. MUST fire.
    rows = [("ledger-pr", "failure", "2026-09-01T10:00:00Z")]
    bad = last_word_per_name(rows, "2026-09-01T10:05:00Z")
    if not bad:
        print("RED  case 1: a gate that failed and never re-passed was NOT flagged"); fails += 1
    else:
        print(f"ok   case 1: genuine red merge flagged -> {bad}")

    # 2. THE ONE I GOT WRONG -- failed, then RE-PASSED before the merge. MUST stay quiet.
    rows = [("ledger-pr", "failure", "2026-09-01T10:00:00Z"),
            ("ledger-pr", "success", "2026-09-01T10:03:00Z")]
    bad = last_word_per_name(rows, "2026-09-01T10:05:00Z")
    if bad:
        print(f"RED  case 2: a SUPERSEDED failure was counted as a verdict -> {bad}"); fails += 1
    else:
        print("ok   case 2: superseded failure correctly ignored (this is the bug I shipped first)")

    # 3. Re-passed AFTER the merge -- the fix came too late. MUST fire.
    rows = [("ledger-pr", "failure", "2026-09-01T10:00:00Z"),
            ("ledger-pr", "success", "2026-09-01T10:09:00Z")]
    bad = last_word_per_name(rows, "2026-09-01T10:05:00Z")
    if not bad:
        print("RED  case 3: a post-merge fix was allowed to excuse a red merge"); fails += 1
    else:
        print(f"ok   case 3: post-merge success does not excuse the merge -> {bad}")

    # 4. Two names, one red -- must not be masked by the other's success.
    rows = [("ledger-pr", "success", "2026-09-01T10:01:00Z"),
            ("scan", "failure", "2026-09-01T10:02:00Z")]
    bad = last_word_per_name(rows, "2026-09-01T10:05:00Z")
    if "scan" not in bad:
        print("RED  case 4: a red check was masked by a different green check"); fails += 1
    else:
        print(f"ok   case 4: per-NAME grouping keeps one red visible -> {bad}")

    print()
    if fails:
        print(f"FAIL: {fails} of 4 predicate cases wrong")
        return 1
    print("PASS: 4 of 4 -- the predicate fires on reds and stays quiet on fixed ones")
    return 0


if __name__ == "__main__":
    sys.exit(main())
