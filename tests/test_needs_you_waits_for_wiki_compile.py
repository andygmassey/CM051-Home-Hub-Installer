#!/usr/bin/env python3
"""needs_you_now_birthdays_survive_fallback waits for a live wiki compile to end
before it compiles; it refuses only when the compile never ends (BUSY).

Walk 132 read a live compile as BUSY at once and went CANNOT-RUN.
Static check on the probe's box-side guard, plus a control: the guard with the
wait loop removed must not pass. No box. Exit 0 pass, 1 fail.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "probes",
                     "needs_you_now_birthdays_survive_fallback.sh")


def waits_before_busy(src):
    """True when the box-side guard polls pgrep in a loop (sleep inside) and
    prints BUSY only after the bounded wait."""
    loop = src.find('while pgrep -u "$(id -u)" -f "[w]iki-compiler"')
    end = src.find("done", loop) if loop != -1 else -1
    busy = src.find('echo "BUSY"')
    return loop != -1 and end > loop and "sleep" in src[loop:end] and 0 < busy


def main():
    with open(PROBE, encoding="utf-8") as fh:
        real = fh.read()
    ok_real = waits_before_busy(real)
    # control: the pre-fix one-shot check, which must NOT pass the predicate
    mutant = real.replace('while pgrep -u "$(id -u)" -f "[w]iki-compiler" >/dev/null 2>&1; do',
                          'if pgrep -u "$(id -u)" -f "[w]iki-compiler" >/dev/null 2>&1; then', 1)
    ok_mutant = waits_before_busy(mutant)
    print("real probe waits for a live compile: %s" % ok_real)
    print("control (one-shot check): waits: %s" % ok_mutant)
    if ok_real and not ok_mutant:
        print("PASS")
        return 0
    print("FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())
