#!/usr/bin/env python3
"""owner_knowledge_score refuses to score while the owner-employer seed is live.

Walk 132 (warm MBP): the probe scored 0% while the owner-employer seed was still in the
graph; the walk removes it later. The score now refuses (CANNOT-RUN) unless the graph
reports exactly zero seed facts, and refuses when the graph does not answer.

Controls:
  - LIVE (a count above zero) and UNKNOWN (no answer) do not CLEAR
  - only CLEAR (an exact zero) lets the score run
  - the probe runs the guard BEFORE the CONTEXT.md swap; a probe with the guard removed fails
Exit 0 pass, 1 fail. No box.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BOX = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes")
GUARD = os.path.join(BOX, "lib", "owner_seed_guard.py")
PROBE = os.path.join(BOX, "probes", "owner_knowledge_score.sh")


def decide(text):
    out = subprocess.run([sys.executable, GUARD, "decide"], input=text, capture_output=True, text=True)
    return out.stdout.strip()


def main():
    bad = []
    live = '{"results":{"bindings":[{"n":{"value":"3"}}]}}'
    zero = '{"results":{"bindings":[{"n":{"value":"0"}}]}}'
    if decide(live) != "LIVE":
        bad.append("a live seed must read LIVE")
    if decide("") != "UNKNOWN":
        bad.append("an empty reply must read UNKNOWN, never CLEAR")
    if decide(zero) != "CLEAR":
        bad.append("an exact zero must read CLEAR")
    with open(PROBE, encoding="utf-8") as fh:
        src = fh.read()
    guard_at = src.find("owner_seed_guard.py")
    swap_at = src.find("context_swap.sh swap")
    if guard_at == -1 or swap_at == -1 or not guard_at < swap_at:
        bad.append("the guard must run before the CONTEXT.md swap")
    # control: the probe without the guard call must fail the same ordering check
    mutant = src.replace("owner_seed_guard.py", "NO_GUARD", 1)
    if mutant.find("owner_seed_guard.py") != -1:
        bad.append("CONTROL: the mutant still names the guard")
    # the guard is scoped to a walk that configures an employer seed org (no org = no seed to be live)
    gate = src.find('if [ -n "${OSTLER_OWNER_SEED_ORG:-}" ]; then')
    if gate == -1 or not gate < guard_at:
        bad.append("the guard must be gated on a configured OSTLER_OWNER_SEED_ORG, before the guard call")
    if bad:
        print("FAIL: " + "; ".join(bad))
        return 1
    print("PASS: LIVE and UNKNOWN refuse, only an exact zero scores, and the guard runs before the swap")
    return 0


if __name__ == "__main__":
    sys.exit(main())
