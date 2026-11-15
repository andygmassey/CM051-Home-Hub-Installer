#!/usr/bin/env python3
"""pair_state_agreement: the device layer adjudicates only its LIVE signals.

Walk 132: the paired_devices/*.json signal is a dead path (no shipped writer),
so it was UNAVAILABLE on every box and left the device layer at 1 of 3
readable. The adjudication now takes the two live signals (daemon health,
devices.db). The real adjudicate() is extracted from the probe and run under bash.

Controls:
  - the device layer still says DISAGREE when the two live signals contradict
  - one live signal readable is INSUFFICIENT, never a pass
  - the probe's call site passes exactly the two live signals (the dead one is gone)
Exit 0 pass, 1 fail.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "probes", "pair_state_agreement.sh")


def adjudicate_source(src):
    m = re.search(r"^adjudicate\(\) \{\n.*?^\}\n", src, re.S | re.M)
    return m.group(0) if m else None


def run_adj(fn_src, *args):
    script = fn_src + '\nadjudicate "$@"\n'
    out = subprocess.run(["bash", "-c", script, "adjudicate"] + list(args),
                         capture_output=True, text=True, stdin=subprocess.DEVNULL)
    return out.stdout.strip().split(" ")[0]


def main():
    with open(PROBE, encoding="utf-8") as fh:
        src = fh.read()
    fn = adjudicate_source(src)
    bad = []
    if not fn:
        bad.append("could not extract adjudicate() from the probe")
    else:
        if run_adj(fn, "true", "true") != "AGREE":
            bad.append("two live signals that agree must AGREE")
        if run_adj(fn, "true", "false") != "DISAGREE":
            bad.append("CONTROL: contradicting live signals must DISAGREE")
        if run_adj(fn, "true", "UNAVAILABLE") != "INSUFFICIENT":
            bad.append("one live signal must be INSUFFICIENT, never a pass")
    call = re.search(r'res_dev="\$\(adjudicate ([^)]*)\)"', src)
    args = call.group(1).split() if call else []
    if args != ['"$h"', '"$d"']:
        bad.append("device-layer call must pass exactly the live signals, got %s" % args)
    if bad:
        print("FAIL: " + "; ".join(bad))
        return 1
    print("PASS: device layer adjudicates h and d only; DISAGREE and INSUFFICIENT controls hold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
