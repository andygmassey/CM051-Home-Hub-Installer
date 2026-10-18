#!/usr/bin/env bash
#
# test_the_run_at_commit_gate_is_wired_into_the_cut.sh -- #1167.
#
# PROVED-RED-BY: this file, mutations M1, M2 and M3.
#
# ============================================================================
# WHY A SEPARATE TEST FROM THE GATE'S OWN SELF-TEST
# ============================================================================
#
# scripts/verify_declared_gates_ran_at_commit.sh --self-test proves the gate can
# DISCRIMINATE. It cannot prove the gate is ever asked. This one asks the
# consumer-side question instead: on a real cut, does the thing run, and can it
# answer when it does.
#
# Three ways to get that wrong, all of which have happened in this repo:
#
#   1. THE GATE IS NOT INVOKED. #1167's whole subject. A gate that declares
#      itself cut-blocking and is reached only by a workflow that does not fire
#      on the cut is reported "reachable" and never runs.
#
#   2. THE STEP IS MASKABLE. Without `if: always()`, a failure in an earlier
#      step of the same job SKIPS this one, and a skipped gate reports nothing
#      while looking like it was considered.
#
#   3. THE JOB CANNOT REACH THE API IT NEEDS, which is the expensive one and
#      is why this file exists at all. A workflow that declares an explicit
#      `permissions:` block sets every UNLISTED scope to none. That refused the
#      first v1.0.43 tag: verify_tagged_commit_is_green.sh needed `checks:
#      read`, did not have it, and exited 2 CANNOT-RUN. It failed closed, which
#      is right, and it would have failed closed on EVERY cut forever.
#
#      THE NEW GATE READS A DIFFERENT NAMESPACE. `repos/<r>/actions/runs` is
#      the ACTIONS scope, not the checks one, so `checks: read` does nothing
#      for it. The identical defect, one scope over, and nothing in the repo
#      would have caught it before a tag was spent on it.
#
# Every assertion below is paired with a control of the same shape, and each of
# the three is mutation-tested, because a structural test that cannot fail is
# the exact thing #1167 is about.
#
# British English throughout; " -- " not em-dashes.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CUT="$HERE/.github/workflows/cut.yml"
GATE="$HERE/scripts/verify_declared_gates_ran_at_commit.sh"
[ -r "$CUT" ]  || { echo "CANNOT-RUN: no cut.yml at $CUT" >&2; exit 2; }
[ -r "$GATE" ] || { echo "CANNOT-RUN: no gate at $GATE" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3 to parse the workflow" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "CANNOT-RUN: no PyYAML; a regex over YAML is not a parse" >&2; exit 2; }

TMP="$(mktemp -d -t runatcut_XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { printf '  ok    %s\n' "$1"; PASS=$((PASS + 1)); }
no() { printf '  FAIL  %s\n' "$1"; printf '%s\n' "${2:-}" | sed 's/^/        | /'; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# THE READER. Parses the workflow properly rather than grepping it: a `run:`
# line and a commented-out `run:` line look identical to a grep, and the
# permissions question cannot be answered by text at all because an ABSENT
# scope and a scope set to none mean the same thing and look different.
#
# Prints, for a named script:
#   INVOKED     <job>
#   ALWAYS      <job>     when the step carries if: always()
#   TOKEN       <job>     when the step passes a GH_TOKEN env
#   PERM        <job> <scope>=<value>   for each scope the job can use
# ---------------------------------------------------------------------------
cat > "$TMP/read.py" <<'PY'
import sys, yaml

wf_path, needle = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(wf_path))
top_perms = doc.get("permissions") or {}

for job_name, job in (doc.get("jobs") or {}).items():
    if not isinstance(job, dict):
        continue
    perms = job.get("permissions")
    # An explicit job-level block REPLACES the workflow block, and every scope
    # it does not name becomes none. That is the whole of the v1.0.43 defect,
    # so it is modelled rather than assumed.
    effective = dict(top_perms) if perms is None else (
        dict(perms) if isinstance(perms, dict) else {"__all__": perms})
    for step in (job.get("steps") or []):
        if not isinstance(step, dict):
            continue
        run = step.get("run") or ""
        if needle not in run:
            continue
        print("INVOKED\t%s" % job_name)
        if str(step.get("if", "")).strip() == "always()":
            print("ALWAYS\t%s" % job_name)
        env = step.get("env") or {}
        if isinstance(env, dict) and any(k == "GH_TOKEN" for k in env):
            print("TOKEN\t%s" % job_name)
        for scope, value in effective.items():
            print("PERM\t%s\t%s=%s" % (job_name, scope, value))
PY

read_wf() { python3 "$TMP/read.py" "$1" "$2" 2>"$TMP/err" || cat "$TMP/err" >&2; }

GATE_REL="scripts/verify_declared_gates_ran_at_commit.sh"
CONTROL_REL="scripts/verify_tagged_commit_is_green.sh"

echo "test_the_run_at_commit_gate_is_wired_into_the_cut"
echo

# ---------------------------------------------------------------------------
# 0. CONTROL, FIRST. The reader must find the gate that is ALREADY wired next
#    door. If it finds nothing, every zero below means the parser is broken and
#    not that the wiring is missing.
# ---------------------------------------------------------------------------
C="$(read_wf "$CUT" "$CONTROL_REL")"
c_jobs="$(printf '%s\n' "$C" | awk -F'\t' '$1=="INVOKED"{print $2}' | grep -c . || true)"
if [ "${c_jobs:-0}" -eq 0 ]; then
    no "(0) CONTROL FAILED: the reader cannot even find ${CONTROL_REL}, which has been wired into cut.yml since #991. Fix the reader before believing anything below" "$C"
    echo; echo "=== ${PASS} passed / ${FAIL} failed ==="; exit 1
fi
ok "(0) CONTROL: the reader finds the already-wired neighbour ${CONTROL_REL##*/} in ${c_jobs} job(s), so a zero below is a real absence"

G="$(read_wf "$CUT" "$GATE_REL")"
JOBS="$(printf '%s\n' "$G" | awk -F'\t' '$1=="INVOKED"{print $2}' | sort -u)"
n_jobs="$(printf '%s\n' "$JOBS" | grep -c . || true)"

# ---------------------------------------------------------------------------
# 1. INVOKED AT ALL. The #1167 shape is a cut-blocker nothing on the cut path
#    runs.
# ---------------------------------------------------------------------------
[ "${n_jobs:-0}" -gt 0 ] \
    && ok "(1) the run-at-commit gate is invoked by cut.yml, in job(s): $(printf '%s' "$JOBS" | tr '\n' ' ')" \
    || no "(1) the gate declares itself cut-blocking and cut.yml does not invoke it -- the exact #1167 shape" "$G"

# ---------------------------------------------------------------------------
# 2. NOT MASKABLE. A step without if: always() is skipped whenever an earlier
#    step in the same job fails, and the run that most needs this evidence is
#    exactly the run that would not produce it.
# ---------------------------------------------------------------------------
if [ "${n_jobs:-0}" -gt 0 ]; then
    n_always="$(printf '%s\n' "$G" | awk -F'\t' '$1=="ALWAYS"' | grep -c . || true)"
    [ "${n_always:-0}" -eq "${n_jobs:-0}" ] \
        && ok "(2) every invocation carries if: always(), so an earlier red cannot hide this gate's answer" \
        || no "(2) ${n_jobs} invocation(s), only ${n_always} with if: always() -- a maskable gate is a dark gate with extra steps" "$G"
fi

# ---------------------------------------------------------------------------
# 3. THE SCOPE. actions:read, not checks:read. Different namespace, and an
#    unlisted scope in an explicit block is none.
# ---------------------------------------------------------------------------
if [ "${n_jobs:-0}" -gt 0 ]; then
    missing=""
    while IFS= read -r j; do
        [ -n "$j" ] || continue
        printf '%s\n' "$G" | awk -F'\t' -v j="$j" '$1=="PERM" && $2==j {print $3}' \
            | grep -qx 'actions=read' || missing="${missing} ${j}"
    done <<< "$JOBS"
    [ -z "$missing" ] \
        && ok "(3) every job that runs it grants actions: read, so the gate can read the Actions API instead of exiting 2 on every cut" \
        || no "(3) job(s)${missing} run the gate without actions: read. It reads repos/<r>/actions/runs, which checks: read does not cover, so it would exit 2 CANNOT-RUN on every cut -- the v1.0.43 defect, one scope over" "$G"
fi

# ---------------------------------------------------------------------------
# 4. THE TOKEN. `permissions:` grants the scope to the job's GITHUB_TOKEN and
#    does not put that token anywhere gh looks. Measured twice on 2026-08-23:
#    a permission the consumer never receives is not a permission.
# ---------------------------------------------------------------------------
if [ "${n_jobs:-0}" -gt 0 ]; then
    n_tok="$(printf '%s\n' "$G" | awk -F'\t' '$1=="TOKEN"' | grep -c . || true)"
    [ "${n_tok:-0}" -eq "${n_jobs:-0}" ] \
        && ok "(4) every invocation passes GH_TOKEN, so gh runs authenticated rather than exiting 2" \
        || no "(4) ${n_jobs} invocation(s), only ${n_tok} passing GH_TOKEN -- the CLI would run unauthenticated" "$G"
fi

# ===========================================================================
echo
echo "  -- mutation --"
# ===========================================================================
# Each mutant reintroduces one of the three defects. A builder that cannot
# apply its edit exits 3 rather than writing an unchanged copy: a mutant that
# did not apply looks exactly like one that was not caught.
# ===========================================================================

mutate() {   # mutate <out> <python-heredoc-on-stdin>
    python3 - "$CUT" "$1"
}

# M1: UNWIRE IT. cut.yml no longer invokes the gate.
mutate "$TMP/m1.yml" <<'PY'
import sys
src = open(sys.argv[1]).read()
needle = "./scripts/verify_declared_gates_ran_at_commit.sh"
if needle not in src:
    sys.stderr.write("M1 DID NOT APPLY: the gate is not invoked in cut.yml\n")
    raise SystemExit(3)
open(sys.argv[2], "w").write(src.replace(needle, "./scripts/true_nothing_here.sh", 1))
PY
m1=$?

# M2: REVOKE THE SCOPE. actions: read removed from the preflight job.
mutate "$TMP/m2.yml" <<'PY'
import sys
src = open(sys.argv[1]).read()
needle = "      actions: read\n"
if needle not in src:
    sys.stderr.write("M2 DID NOT APPLY: no job-level 'actions: read' to remove\n")
    raise SystemExit(3)
open(sys.argv[2], "w").write(src.replace(needle, "", 1))
PY
m2=$?

# M3: MAKE IT MASKABLE. Drop if: always() from the gate's step.
mutate "$TMP/m3.yml" <<'PY'
import sys
src = open(sys.argv[1]).read()
needle = ("      - name: Every self-declared cut-blocker actually ran at this commit\n"
          "        if: always()\n")
if needle not in src:
    sys.stderr.write("M3 DID NOT APPLY: the gate's step is not where this test expects it\n")
    raise SystemExit(3)
open(sys.argv[2], "w").write(src.replace(
    needle,
    "      - name: Every self-declared cut-blocker actually ran at this commit\n", 1))
PY
m3=$?

check_mutant() {   # check_mutant <label> <builder-rc> <file> <predicate>
    local label="$1" rc="$2" f="$3" pred="$4" out
    if [ "$rc" != 0 ]; then
        no "(${label}) the mutant could not be built, so this direction was not tested" "re-point this test"
        return
    fi
    out="$(read_wf "$f" "$GATE_REL")"
    if eval "$pred"; then
        ok "(${label}) RED ON THE DEFECT: the assertion it targets fails against the mutant"
    else
        no "(${label}) MUTANT SURVIVED: the assertion it targets still passes, so it proves nothing" "$out"
    fi
}

check_mutant M1 "$m1" "$TMP/m1.yml" \
    '[ "$(printf "%s\n" "$out" | awk -F"\t" "\$1==\"INVOKED\"" | grep -c . || true)" -eq 0 ]'

check_mutant M2 "$m2" "$TMP/m2.yml" \
    '! printf "%s\n" "$out" | awk -F"\t" "\$1==\"PERM\"{print \$3}" | grep -qx "actions=read"'

check_mutant M3 "$m3" "$TMP/m3.yml" \
    '[ "$(printf "%s\n" "$out" | awk -F"\t" "\$1==\"ALWAYS\"" | grep -c . || true)" -eq 0 ]'

# A CONTROL ON THE MUTANTS THEMSELVES. M2 and M3 must not have unwired the
# gate as a side effect, or they would be passing for the wrong reason.
for m in m2 m3; do
    out="$(read_wf "$TMP/${m}.yml" "$GATE_REL")"
    [ "$(printf '%s\n' "$out" | awk -F'\t' '$1=="INVOKED"' | grep -c . || true)" -gt 0 ] \
        && ok "(${m}-control) the mutant still invokes the gate, so it fails for the reason it was built to test" \
        || no "(${m}-control) the mutant also unwired the gate, so its red says nothing about the scope or the mask" "$out"
done

echo
echo "EXAMINED: 1 workflow, ${n_jobs:-0} job(s) invoking the gate, 4 assertions, 3 mutants, 1 wiring control."
echo "=== ${PASS} passed / ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
