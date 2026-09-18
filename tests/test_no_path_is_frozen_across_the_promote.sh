#!/usr/bin/env bash
# A path captured before the promote and used after it points at a deleted tree.
#
# 🔴 INSTANCE SIX OF THE STAGING-PATH FAMILY, AND THE FIRST ONE TO GET A GATE.
# install.sh:353 already records "THIRD OCCURRENCE OF THIS CLASS". Every prior
# instance was fixed as an instance. This is the class.
#
# THE MECHANISM. install.sh installs into a staging tree first, then promotes it
# onto ~/.ostler. `_ostler_set_paths <root>` rebinds OSTLER_DIR and everything
# derived from it, and the promote calls it again with the real root. A variable
# derived from one of those paths but assigned at TOP LEVEL is captured ONCE,
# with whatever value was current, and never rebound. If that happens before a
# promote and the value is used after one, it names a directory that has been
# deleted.
#
# THE INSTANCE THAT PROVED IT, found on a cold walk that reported PASS:
#
#   FileNotFoundError: '~/.ostler/security/tmp*.tmp'
#     -> '/tmp/ostler-prelaunch-<pid>/security/recovery_key_delivered.json'
#
#   RECOVERY_DELIVERY_MARKER  assigned 8432, promote 17438, used 34678
#
# The recovery-key delivery marker was never written and the install reported
# success. The two branches that read it could not fire on any install that
# promotes, which is every install. The recovery key is the one thing that gets
# a customer back in after a lost passphrase.
#
# WHY NOTHING SAW IT. The walk adjudicates on the completion marker, the exit
# code, failed_steps and step status. A Python traceback on stderr is counted,
# printed, and does not affect the verdict. The only tell was a traceback count
# of 1 in a 1,537-line log.
#
# THE PREDICATE IS POSITIONAL, WHICH IS WHAT MAKES IT USABLE. 67 top-level
# assignments derive from a setter-managed path and 66 of them are correct,
# because they are assigned after the promote where the path is already real.
# A presence test would report 67 and be ignored. This reports only: assigned
# before a promote AND used after one.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

python3 - "$@" <<'PY'
import pathlib, re, sys, tempfile, os

PASS, FAIL = [], []
def ok(m):   PASS.append(m); print("  [PASS] %s" % m)
def bad(m):  FAIL.append(m); print("  [FAIL] %s" % m)
def cant(m): print("CANNOT-RUN: %s" % m, file=sys.stderr); sys.exit(2)

#: Below this the extractor has gone blind: a setter managing nothing makes
#: every derivation trivially safe, which is not a pass.
MIN_MANAGED = 10

def is_code(line):
    return bool(line.strip()) and not line.strip().startswith("#")

def analyse(lines):
    """(managed vars, promote call lines, offenders). Raises on a broken read."""
    start = None
    for i, l in enumerate(lines):
        if l.startswith("_ostler_set_paths()"):
            start = i; break
    if start is None:
        raise LookupError("no _ostler_set_paths() definition")
    depth, end = 0, None
    for i in range(start, len(lines)):
        depth += lines[i].count("{") - lines[i].count("}")
        if i > start and depth <= 0:
            end = i; break
    if end is None:
        raise LookupError("the setter's braces do not close")
    managed = {re.match(r'\s*([A-Z_][A-Z0-9_]*)=', l).group(1)
               for l in lines[start:end + 1]
               if re.match(r'\s*([A-Z_][A-Z0-9_]*)=', l)}
    promotes = [i + 1 for i, l in enumerate(lines)
                if "_ostler_promote_prelaunch_tree" in l and is_code(l)
                and not l.strip().endswith("() {")]
    offenders = []
    for i, l in enumerate(lines):
        if start <= i <= end:
            continue
        m = re.match(r'^([A-Z_][A-Z0-9_]*)=(.*)$', l)   # column 0 is top level
        if not m:
            continue
        name, val = m.group(1), m.group(2)
        if name in managed:
            continue
        if not any(re.search(r'\$\{?%s\b' % v, val) for v in managed):
            continue
        assigned = i + 1
        uses = [j + 1 for j, ll in enumerate(lines)
                if j != i and is_code(ll) and re.search(r'\$\{?%s\b' % name, ll)]
        stale = [(p, u) for p in promotes for u in uses if assigned < p < u]
        if stale:
            offenders.append((assigned, name, stale[0]))
    return managed, promotes, offenders

print("-- controls: the predicate must fire, and must not fire on the safe shape --")

SETTER = ["_ostler_set_paths() {",
          '    OSTLER_DIR="$1"',
          '    SECURITY_CONFIG_DIR="${OSTLER_DIR}/security"',
          '    DATA_DIR="${OSTLER_DIR}/data"',
          "}"]

def seeded(before_promote, after_promote):
    out = list(SETTER)
    out += ['_ostler_set_paths "$STAGE"']
    out += before_promote
    out += ["    _ostler_promote_prelaunch_tree"]
    out += after_promote
    return out

# POSITIVE: captured before the promote, used after.
lines = seeded(['MARKER="${SECURITY_CONFIG_DIR}/m.json"'], ['echo "${MARKER}"'])
try:
    _m, _p, off = analyse(lines)
except LookupError as exc:
    cant("the seeded control did not parse (%s), so the reader is broken" % exc)
if [o[1] for o in off] == ["MARKER"]:
    ok("CONTROL: a path captured before the promote and used after it IS reported")
else:
    bad("CONTROL: the seeded offender was NOT reported (%s). The predicate cannot "
        "fire, so a clean subject below would mean nothing." % [o[1] for o in off])

# MUST-MISS: captured AFTER the promote, used after. This is the correct shape
# and it is 66 of the 67 derivations in the real file.
lines = seeded([], ['MARKER="${SECURITY_CONFIG_DIR}/m.json"', 'echo "${MARKER}"'])
_m, _p, off = analyse(lines)
if not off:
    ok("MUST-MISS: a path captured AFTER the promote is not reported")
else:
    bad("MUST-MISS: a correctly-placed derivation was reported. This gate would "
        "flag 66 correct lines and be ignored.")

# MUST-MISS: captured before the promote but never used after one.
lines = seeded(['MARKER="${SECURITY_CONFIG_DIR}/m.json"', 'echo "${MARKER}"'], [])
_m, _p, off = analyse(lines)
if not off:
    ok("MUST-MISS: a path captured and used entirely before the promote is not reported")
else:
    bad("MUST-MISS: a derivation used only before the promote was reported")

print("-- subject: install.sh --")
path = pathlib.Path("install.sh")
if not path.is_file():
    cant("install.sh is not a file")
lines = path.read_text(encoding="utf-8").split("\n")
try:
    managed, promotes, offenders = analyse(lines)
except LookupError as exc:
    cant("%s, so nothing was measured" % exc)

print("     EXAMINED: %d line(s); the setter manages %d path(s); %d promote call site(s)"
      % (len(lines), len(managed), len(promotes)))

if len(managed) < MIN_MANAGED:
    cant("the setter manages only %d path(s), below the floor of %d. The extractor "
         "has gone blind and every derivation would be trivially safe."
         % (len(managed), MIN_MANAGED))
if not promotes:
    cant("no promote call site found. Without one, nothing can be stale across it "
         "and this gate would pass over a question it never asked.")

if offenders:
    bad("%d path(s) are captured before a promote and used after it, so they name "
        "a tree that has been deleted: %s"
        % (len(offenders),
           "; ".join("%s assigned %d, promote %d, used %d" % (n, a, p, u)
                     for a, n, (p, u) in offenders)))
else:
    ok("no path is frozen across the promote (%d derivation site(s) checked, all "
       "either rebound by the setter or assigned after the promote)"
       % sum(1 for l in lines if re.match(r'^[A-Z_][A-Z0-9_]*=', l)))

print()
print("== %d pass / %d fail / %d total ==" % (len(PASS), len(FAIL), len(PASS) + len(FAIL)))
sys.exit(1 if FAIL else 0)
PY
