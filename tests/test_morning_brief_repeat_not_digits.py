#!/usr/bin/env python3
"""A morning brief repeat is the SAME item twice, never two items that differ
only in leading digits. Two meetings at different times and two counts are not
repeats. Only list markers ("- ", "* ", a bullet, "N. ", "N) ") are stripped.

RED on the old code: _norm_item stripped leading digits, so "09:00 Standup" and
"15:00 Standup" normalised to the same string and read as a repeat (false FAIL).
Synthetic data only. Exit 0 pass, 1 fail.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "lib"))
import wow_moments as w  # noqa: E402

fails = []


def check(label, ok):
    print(("  ok    " if ok else "  FAIL  ") + label)
    if not ok:
        fails.append(label)


check("two same-title meetings at different times are NOT a repeat",
      w.brief_repeat_events("09:00 Standup\n15:00 Standup") == [])
check("two counts with different numbers are NOT a repeat",
      w.brief_repeat_events("You have 2 emails waiting\nYou have 5 emails waiting") == [])
check("a bare leading number is kept, not stripped",
      w._norm_item("2 emails") == "2 emails")
check("a list marker is stripped: '- Book the dentist' == 'Book the dentist'",
      w._norm_item("- Book the dentist") == "book the dentist")
check("a numbered list marker is stripped: '3. Book the dentist'",
      w._norm_item("3. Book the dentist") == "book the dentist")
check("a genuine repeat across two bullet markers is still caught",
      len(w.brief_repeat_events("- Book the dentist\n* Book the dentist")) == 1)
check("a genuine repeat of an identical timed line is still caught",
      len(w.brief_repeat_events("09:00 Standup\n09:00 Standup")) == 1)

print("FAIL: " + "; ".join(fails) if fails else "PASS")
sys.exit(1 if fails else 0)
