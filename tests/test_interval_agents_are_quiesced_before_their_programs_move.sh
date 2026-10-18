#!/usr/bin/env bash
# A StartInterval agent must not be running while its program is rewritten.
#
# THE DEFECT, MEASURED ON THE MINI 2026-09-18 on a fresh v1.0.100 install:
#
#   export-scan.err written   23:43:47   ostler-scan-exports placed  23:45:33
#   fda-rerun.err  written    23:43:37   ostler-fda placed           23:45:33
#
# Both errors predate their own program by roughly 110 seconds. launchd fires a
# StartInterval job on its own schedule regardless of what the installer is
# doing, so during the window where bin/ is being replaced the program is
# transiently absent, the tick exits non-zero, and launchctl KEEPS that
# last-exit until the next interval: one hour for fda-rerun, FOUR for
# export-scan. A freshly upgraded box therefore carries two agents in a failed
# state for up to four hours, on an install that succeeded.
#
# WHAT IT COSTS BEYOND THE LOG LINE. acceptance_gate_v1013 arm A8 is
# "LaunchAgents exit clean". It FAILS deterministically on any walk run inside
# that window and PASSES on a box that has been up a few hours. Same probe,
# same box, same sha, opposite verdict, with a fresh install as the only
# variable. That is the artefact-versus-history confusion in one probe, and it
# is why a same-box green must never close an artefact question.
#
# The text the customer gets is the sharpest part: "re-run the installer to
# repair" -- the installer that just ran and created the condition.
#
# WHY THE EXISTING GUARDS DO NOT COVER IT. The deferred fda-rerun load refuses
# to REGISTER the job before its program exists, and export-scan is
# bootstrapped after its program is written. Both fix the FRESH install.
# Neither touches a job ALREADY registered by a previous install: the fda-rerun
# bootout is gated on the old plist being legacy or pathless, and export-scan
# has no bootout at all. An upgrade from a current-form install quiesces
# nothing, which is exactly the box this was measured on.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

python3 - "$@" <<'PY'
import pathlib, re, sys

PASS, FAIL = [], []
def ok(m):   PASS.append(m); print("  [PASS] %s" % m)
def bad(m):  FAIL.append(m); print("  [FAIL] %s" % m)
def cant(m): print("CANNOT-RUN: %s" % m, file=sys.stderr); sys.exit(2)

AGENTS = ("com.ostler.export-scan", "com.ostler.fda-rerun")
QUIESCE = "_ostler_quiesce_interval_agents"


def analyse(lines):
    """(quiesce call line, {program: write line}, labels named in the helper)."""
    call = None
    for i, l in enumerate(lines):
        if l.startswith(QUIESCE) and not l.rstrip().endswith("() {"):
            call = i + 1
            break
    writes = {}
    for i, l in enumerate(lines):
        m = re.search(r'cat > "\$\{OSTLER_DIR\}/(bin/[a-z-]+)"', l)
        if m and m.group(1) not in writes:
            writes[m.group(1)] = i + 1
    # labels named inside the helper body
    start = next((i for i, l in enumerate(lines) if l.startswith(QUIESCE + "() {")), None)
    labels = set()
    if start is not None:
        depth = 0
        for i in range(start, len(lines)):
            depth += lines[i].count("{") - lines[i].count("}")
            for a in AGENTS:
                if a in lines[i]:
                    labels.add(a)
            if i > start and depth <= 0:
                break
    return call, writes, labels


print("-- controls: the ordering predicate must fire in both directions --")

GOOD = ['%s() {' % QUIESCE, '    :', '}', '%s' % QUIESCE,
        'cat > "${OSTLER_DIR}/bin/ostler-fda" <<\'X\'', 'X']
BAD = ['%s() {' % QUIESCE, '    :', '}',
       'cat > "${OSTLER_DIR}/bin/ostler-fda" <<\'X\'', 'X', '%s' % QUIESCE]

c, w, _ = analyse(GOOD)
if c and w and c < min(w.values()):
    ok("CONTROL: a quiesce BEFORE the payload write reads as correctly ordered")
else:
    bad("CONTROL: a correctly ordered fixture did not read as ordered (call=%s writes=%s). "
        "The reader is broken." % (c, w))

c, w, _ = analyse(BAD)
if c and w and c > min(w.values()):
    ok("CONTROL: a quiesce AFTER the payload write is detectable, so this gate can fail")
else:
    bad("CONTROL: a mis-ordered fixture was not detected. This gate cannot fail and "
        "its pass below would mean nothing.")

print("-- subject: install.sh --")
path = pathlib.Path("install.sh")
if not path.is_file():
    cant("install.sh is not a file")
lines = path.read_text(encoding="utf-8").split("\n")
call, writes, labels = analyse(lines)

print("     EXAMINED: %d line(s); %d bin/ payload write(s) found" % (len(lines), len(writes)))

if not writes:
    cant("no bin/ payload write was found, so ordering was not measured. The write "
         "form changed and this gate is blind.")

if call is None:
    bad("%s is never CALLED. The two interval agents keep running while their "
        "programs are replaced, and launchctl holds the resulting failure for up "
        "to four hours." % QUIESCE)
else:
    guarded = {p: ln for p, ln in writes.items() if p in ("bin/ostler-fda", "bin/ostler-scan-exports")}
    if not guarded:
        cant("neither interval-agent program was found among the payload writes, so "
             "the subjects of this gate are absent")
    late = {p: ln for p, ln in guarded.items() if ln < call}
    if late:
        bad("the quiesce at line %d runs AFTER %s, so those agents tick against a "
            "program being rewritten underneath them"
            % (call, ", ".join("%s (line %d)" % (p, ln) for p, ln in sorted(late.items()))))
    else:
        ok("the quiesce at line %d precedes every interval-agent program write (%s)"
           % (call, ", ".join("%s line %d" % (p, ln) for p, ln in sorted(guarded.items()))))

missing = [a for a in AGENTS if a not in labels]
if call is not None and missing:
    bad("the quiesce does not name %s, so those agents are not stopped" % ", ".join(missing))
elif call is not None:
    ok("the quiesce names both interval agents (%s)" % ", ".join(sorted(labels)))

print()
print("== %d pass / %d fail / %d total ==" % (len(PASS), len(FAIL), len(PASS) + len(FAIL)))
sys.exit(1 if FAIL else 0)
PY
