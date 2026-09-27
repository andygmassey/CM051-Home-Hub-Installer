#!/usr/bin/env bash
# A tag rehearsal (dispatch on refs/heads/rehearse/v1.0.NN) must run the TAG
# RUN'S OWN preflight job in tag mode and must never build or ship.
#   1. SAME JOB: there is exactly one preflight job, and every tag-only switch
#      in it (OSTLER_CUT_IN_PROGRESS, the BOM-in-pin step, the installer-version
#      step, the version resolver) also fires for a rehearse ref.
#   2. NO SIDE EFFECTS: every other job's `if:` excludes rehearse refs.
#   3. Mutants: dropping the exclusion from `cut`, or the rehearse arm from the
#      BOM step, must each turn this test red.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
check() {
python3 - "$1" <<'PY'
import sys, yaml
p = sys.argv[1]; y = yaml.safe_load(open(p)); jobs = y["jobs"]
R = "startsWith(github.ref, 'refs/heads/rehearse/v1.0.')"
bad = []
if "preflight" not in jobs: bad.append("no preflight job")
steps = jobs["preflight"]["steps"]
envs = [str(s.get("env", {}).get("OSTLER_CUT_IN_PROGRESS")) for s in steps if "OSTLER_CUT_IN_PROGRESS" in (s.get("env") or {})]
if not envs: bad.append("preflight sets OSTLER_CUT_IN_PROGRESS nowhere")
for e in envs:
    if R not in e: bad.append("an OSTLER_CUT_IN_PROGRESS in preflight ignores rehearse refs")
def step(name):
    m = [s for s in steps if s.get("name") == name]
    return m[0] if m else None
for nm in ("BOM rows must be in the pinned tree", "The installer's own version IS the version being cut"):
    s = step(nm)
    if s is None: bad.append("preflight lost step: " + nm)
    elif R not in str(s.get("if", "")): bad.append("tag-only step skips rehearsal: " + nm)
res = step("Resolve which cut this run is about")
if res is None or "REHEARSE_REF" not in str(res.get("env", {})) or "REHEARSE_REF" not in res.get("run", ""):
    bad.append("version resolver does not read the rehearse ref")
for n, j in jobs.items():
    if n == "preflight": continue
    cond = str(j.get("if", ""))
    if "!" + R not in cond.replace(" ", "").replace("!startsWith", "!startsWith") and ("!" + R) not in cond:
        bad.append(f"job `{n}` can run on a rehearse ref (if: {cond or '<none>'})")
for b in bad: print("  FAIL " + b)
sys.exit(1 if bad else 0)
PY
}
pass=0; fail=0
if check .github/workflows/cut.yml; then echo "  ok   cut.yml: rehearsal runs the tag preflight and nothing else"; pass=$((pass+1)); else echo "  FAIL cut.yml"; fail=$((fail+1)); fi
m=$(mktemp)
sed "s/ \&\& !startsWith(github.ref, 'refs\/heads\/rehearse\/v1.0.'))\$/)/" .github/workflows/cut.yml > "$m"
if cmp -s "$m" .github/workflows/cut.yml; then echo "  FAIL mutant 1 did not apply"; fail=$((fail+1));
elif check "$m" >/dev/null; then echo "  FAIL mutant 1 (cut job reachable on a rehearsal) survived"; fail=$((fail+1));
else echo "  ok   mutant 1 caught: cut job reachable on a rehearsal"; pass=$((pass+1)); fi
python3 - "$m" <<'PY'
import sys
p='.github/workflows/cut.yml'; s=open(p).read()
a="        if: startsWith(github.ref, 'refs/tags/v1.0.') || startsWith(github.ref, 'refs/heads/rehearse/v1.0.')\n        run: |\n          set -euo pipefail\n          VER="
s=s.replace(a,"        if: startsWith(github.ref, 'refs/tags/v1.0.')\n        run: |\n          set -euo pipefail\n          VER=",1)
open(sys.argv[1],'w').write(s)
PY
if cmp -s "$m" .github/workflows/cut.yml; then echo "  FAIL mutant 2 did not apply"; fail=$((fail+1));
elif check "$m" >/dev/null; then echo "  FAIL mutant 2 (BOM step skips rehearsal) survived"; fail=$((fail+1));
else echo "  ok   mutant 2 caught: BOM-in-pin step skips the rehearsal"; pass=$((pass+1)); fi
rm -f "$m"
echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
