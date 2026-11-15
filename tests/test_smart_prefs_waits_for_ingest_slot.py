#!/usr/bin/env python3
"""The smart-prefs derive probe must not kick the derive agent while the shared
ingest slot is held: a tick that finds the slot busy only yields (walk 132:
seven yields in a row behind com.ostler.fda-rerun, and four probes CANNOT-RUN).

Fake clock and fake slot, no launchctl, no box. Exit 0 pass, 1 fail.
Control: the same loop with the slot wait removed kicks into a held slot and
this test goes red.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "lib")
sys.path.insert(0, LIB)
os.environ.setdefault("OSTLER_SMARTPREFS_SLOT_POLL_S", "15")
import smart_prefs as sp  # noqa: E402


class Fake:
    def __init__(self, held_polls):
        self.t = 0.0
        self.held_polls = held_polls  # slot reads as held for this many polls
        self.polls = 0
        self.kicks_while_held = 0
        self.kicks = 0

    def clock(self):
        return self.t

    def nap(self, s):
        self.t += s

    def held(self):
        self.polls += 1
        return self.polls <= self.held_polls

    def kick(self):
        self.kicks += 1
        if self.held_polls >= self.polls:
            self.kicks_while_held += 1
        return (0, "")

    def wait(self, prev, budget):
        # a tick reports only once it has actually been allowed to run
        if self.kicks >= 1:
            return True, {"outcome": "ran", "last_run_at": "x", "ts": "2026-11-16T00:00:00Z"}
        return False, {"outcome": "yielded", "ts": None}


def run(held_polls, with_slot_wait):
    f = Fake(held_polls)
    pre = (lambda b: sp._slot_wait(b, clock=f.clock, nap=f.nap, held=f.held)) if with_slot_wait else None
    if with_slot_wait:
        sp._slot_wait(1200, clock=f.clock, nap=f.nap, held=f.held)
    sp._derive_until_pass(None, 240, 1800, kick=f.kick, wait=f.wait, clock=f.clock, nap=f.nap,
                          since=None, pre_kick=pre)
    return f


def main():
    bad = []
    # 1. slot free after 3 polls: wait returns True, nap ran 3 times.
    f = Fake(3)
    free = sp._slot_wait(1200, clock=f.clock, nap=f.nap, held=f.held)
    if not free or f.t != 45.0:
        bad.append("slot free after 3 polls: free=%s t=%s" % (free, f.t))
    # 2. slot never frees inside the budget: wait returns False.
    f = Fake(10 ** 6)
    if sp._slot_wait(60, clock=f.clock, nap=f.nap, held=f.held) is not False:
        bad.append("held past the budget must return False")
    # 3. the derive loop never kicks while the slot is held (with the wait).
    f = run(held_polls=3, with_slot_wait=True)
    if f.kicks_while_held != 0 or f.kicks < 1:
        bad.append("with the wait: kicks=%d kicks_while_held=%d" % (f.kicks, f.kicks_while_held))
    # 4. control: the same loop WITHOUT the wait kicks into a held slot.
    g = run(held_polls=3, with_slot_wait=False)
    if g.kicks_while_held == 0:
        bad.append("CONTROL: without the wait the loop should have kicked while held")
    print("kicks with wait: %d (while held %d); control without wait: %d (while held %d)"
          % (f.kicks, f.kicks_while_held, g.kicks, g.kicks_while_held))
    if bad:
        print("FAIL: " + "; ".join(bad))
        return 1
    print("PASS: the derive kick waits for the ingest slot, and the control kicks into it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
