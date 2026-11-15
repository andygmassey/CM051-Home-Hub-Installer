#!/usr/bin/env bash
# Every prerequisite of gui/Makefile `ship:`, `release:` and `package:` must be classified in
# scripts/ship_prereq_classes.tsv (LINUX = cut.yml preflight, MACOS = cut job pre-build step, BUILD_ONLY with a reason),
# no row may name a target the Makefile no longer lists, check-orphans then check-pr-age must be the LAST LINUX rows,
# and cut.yml must actually invoke run_ship_prereqs.sh for LINUX (in preflight) and MACOS (in cut, before the Build step).
# v1.0.119/126/127 each burnt a tag push on a ship prerequisite that preflight never ran.
# MAKEFILE=<path> overrides the Makefile (mutation proof). Exit 0 ok / 1 defect / 2 cannot run.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
python3 - "${MAKEFILE:-gui/Makefile}" <<'PY'
import sys, re
try:
    import yaml
    mk = open(sys.argv[1]).read().splitlines()
    rows = [l for l in open('scripts/ship_prereq_classes.tsv').read().splitlines() if l and not l.startswith('#')]
    wf = yaml.safe_load(open('.github/workflows/cut.yml'))
except Exception as e:
    print("CANNOT-RUN: %s: %s" % (type(e).__name__, e)); sys.exit(2)
def pre(t):
    m = [l for l in mk if re.match(r'^%s:\s' % t, l)]
    return m[0].split(':', 1)[1].split() if m else None
actual = []
for t in ('ship', 'release', 'package'):
    p = pre(t)
    if p is None: print("CANNOT-RUN: no '%s:' line in Makefile" % t); sys.exit(2)
    actual += [x for x in p if x not in actual]
cls = {}; order = []
for r in rows:
    f = r.split('|')
    if len(f) < 3 or not f[2].strip(): print("FAIL: row without a reason: %r" % r); sys.exit(1)
    if f[1] not in ('LINUX', 'MACOS', 'BUILD_ONLY'): print("FAIL: bad class: %r" % r); sys.exit(1)
    cls[f[0]] = f[1]; order.append(f[0])
bad = []
for t in actual:
    if t not in cls: bad.append("UNCLASSIFIED prerequisite (in neither the preflight list nor BUILD_ONLY): %s" % t)
for t in cls:
    if t not in actual: bad.append("phantom row, not a prerequisite of ship/release/package: %s" % t)
linux = [t for t in order if cls[t] == 'LINUX']
if linux[-2:] != ['check-orphans', 'check-pr-age']: bad.append("check-orphans then check-pr-age must be the LAST LINUX rows, got %s" % linux[-2:])
def runs(steps, c):
    return [i for i, s in enumerate(steps) if 'run_ship_prereqs.sh %s' % c in str(s.get('run', ''))]
pf = wf['jobs']['preflight']['steps']; cut = wf['jobs']['cut']['steps']
if not runs(pf, 'LINUX'): bad.append("preflight job never invokes run_ship_prereqs.sh LINUX")
rm = runs(cut, 'MACOS')
if not rm: bad.append("cut job never invokes run_ship_prereqs.sh MACOS")
else:
    b = [i for i, s in enumerate(cut) if str(s.get('name', '')).startswith('Build, sign')]
    if not b or rm[0] > b[0]: bad.append("MACOS step must come before the Build step")
for b_ in bad: print("FAIL: " + b_)
print("%d prerequisite(s) examined, %d classified LINUX, %d MACOS, %d BUILD_ONLY, %d defect(s)" % (
    len(actual), len(linux), sum(1 for t in cls if cls[t]=='MACOS'), sum(1 for t in cls if cls[t]=='BUILD_ONLY'), len(bad)))
sys.exit(1 if bad else 0)
PY
