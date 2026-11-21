#!/usr/bin/env python3
"""todos_reach_reminders must retry earlier walks' residue BEFORE it writes.

Walk 132 (2026-11-15) ended with two walk reminders left behind: the forget
step timed out over ssh, and no step ever called `reset`, so the identifiers
stayed in the state file and were never retried. This test reads the probe
source and requires the `reset` box call to come before the `run` box call.

Control: the same check on a copy with the reset line removed must FAIL.
Exit 0 pass, 1 fail. No box, no Reminders.app.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "probes",
                     "todos_reach_reminders.sh")


def residue_before_write(src):
    """True when a box call running the `reset` subcommand appears before the
    `run --token` box call, and both exist."""
    reset_at = src.find("} reset\"")
    run_at = src.find("} run --token")
    return reset_at != -1 and run_at != -1 and reset_at < run_at


def main():
    with open(PROBE, encoding="utf-8") as fh:
        real = fh.read()
    ok_real = residue_before_write(real)
    mutant = "\n".join(l for l in real.splitlines() if "} reset" not in l)
    ok_mutant = residue_before_write(mutant)
    print("real probe: residue cleared before write = %s" % ok_real)
    print("control (reset line removed): residue cleared before write = %s" % ok_mutant)
    if ok_real and not ok_mutant:
        print("PASS: the reset precedes the write, and the control goes red without it")
        return 0
    print("FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())
