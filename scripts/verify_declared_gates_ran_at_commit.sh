#!/usr/bin/env bash
# scripts/verify_declared_gates_ran_at_commit.sh
#
#   scripts/verify_declared_gates_ran_at_commit.sh <sha> [repo]
#   scripts/verify_declared_gates_ran_at_commit.sh --self-test
#
# ============================================================================
# "REACHABLE FROM THE CUT" IS NOT "RAN ON THE CUT" (#1167)
# ============================================================================
#
# scripts/verify_declared_gates_reachable.sh reports, truthfully:
#
#     22 of 22 EXECUTABLE files declaring themselves cut-blocking are
#     reachable from the cut (95 entry point(s), fixpoint in 7 round(s)).
#     no orphans.
#
# Reachability is computed from ANY entry point. Every workflow counts as one
# regardless of what triggers it, so a gate invoked only by a workflow that
# never fires on the cut's commit is "reachable from the cut" while not having
# run on it. That is a property of the CALL GRAPH; the defect lives in the
# TRIGGER CONDITIONS, which are outside the graph entirely.
#
# MEASURED AGAINST THE GITHUB ACTIONS API, not inferred from the workflow files
# as they stand today, for the commit v1.0.48 was cut from:
#
#     commit bfc1408d39642d91bdf7d831fa9e86baf083ff35
#       customer-download-path.yml       0 runs
#       default-sources-requested.yml    0 runs
#       cut-gate-wrappers.yml  (CONTROL) 1 run, push, success
#       total runs at that commit       69
#
#     CONTROL ON THE QUERY ITSELF: head_sha=000...0 returns 0, so the filter is
#     honoured and the two zeroes above are real absences rather than an
#     unfiltered or broken query. The runs are still within the API's retention,
#     so this is a measurement and not a CANNOT-RUN.
#
# The mechanism is two filters stacking: `push: {branches: [main]}` carries no
# `tags:` key so a tag push does not fire it, AND a `paths:` filter means it
# only fires on main when specific files change. A cut taken from a commit that
# touched none of them has never had those gates run.
#
# ============================================================================
# WHY THE EXISTING GATES DO NOT CATCH IT, INCLUDING THE ONE NEXT DOOR
# ============================================================================
#
# * verify_declared_gates_reachable.sh asserts over REACHABILITY. Its axis three
#   now also reports which declarers cannot fire on a tag push, but that is a
#   statement about triggers in the abstract, against a recorded baseline. It
#   does not look at the commit being cut.
#
# * verify_tagged_commit_is_green.sh -- which runs immediately before this one
#   in cut.yml -- refuses on any COMPLETED check-run whose conclusion is a
#   failure. A gate that never ran leaves NO check-run at all, so it leaves
#   nothing red, and the commit reads green over the absence. Its zero-check-run
#   refusal catches "no checks at all"; it cannot catch "all the checks except
#   this one".
#
# THE TWO ARE COMPLEMENTARY AND NEITHER SUBSUMES THE OTHER: one asks whether
# what ran was green, this one asks whether what should have run, ran.
#
# ============================================================================
# THE BASELINE, AND WHY THERE ISN'T A NEW ONE
# ============================================================================
#
# A gate that is red on the day it lands is a gate people route around. Twelve
# declarers do not run on a tag push today, and that state is ALREADY recorded,
# with a status and a reason per row, in
# scripts/cut_trigger_reachability_baseline.tsv -- axis three's register.
#
# 🔴 THIS GATE READS THAT FILE RATHER THAN OPENING A RIVAL REGISTER. Two files
# recording the same fact drift, and then the question "is this gate allowed not
# to run on the cut?" has two answers. A row there is not an excuse, it is a
# note that somebody decided, or has not yet; the rules for clearing a row are
# in that file's own header and are unchanged by this gate.
#
# So the RED set is: declares itself cut-blocking, IS reached by at least one
# workflow, had NO run at the commit being cut, and is NOT recorded in the
# baseline.
#
# ============================================================================
# EXIT CODES (the trichotomy this repo keeps re-learning)
#   0  every declarer either ran at the commit, or is recorded in the baseline
#   1  a declarer did not run and is not recorded -- named, one per line
#   2  could not run: no python3, no git, no API, zero runs at the commit
#      (a zero denominator), or zero declarers found (a broken pattern)
#
# Exit 2 matters more here than usual. "Nothing failed to run" and "I could not
# enumerate anything" print identically otherwise, and this gate's normal state
# is silence.
#
# ENVIRONMENT
#   OSTLER_WORKFLOW_RUNS_JSON   read the runs from a file instead of the API.
#                               The self-test's only lever; it exists so the
#                               cases below are hermetic.
#   OSTLER_DECLARED_RAN_ROOT    enumerate declarers from this repo root instead
#                               of the current one. The self-test drives a
#                               fixture repo through it.
#   OSTLER_CUT_TRIGGER_BASELINE override the baseline path.
#
# British English throughout; " -- " not em-dashes.
# ============================================================================
set -uo pipefail

red()   { printf '\033[0;31m%s\033[0m\n' "$1" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
dim()   { printf '\033[2m%s\033[0m\n' "$1"; }

# The SAME pattern verify_declared_gates_reachable.sh enumerates on. Kept
# identical on purpose: two gates disagreeing about who is a cut-blocker is
# worse than one gate, because each can be quoted against the other.
DECLARE_RE='BLOCK THE CUT|BLOCKS THE CUT|CUT BLOCKER|blocks? the release|MUST NOT SHIP|DO NOT ASSEMBLE'

command -v python3 >/dev/null 2>&1 || { red "CANNOT-RUN: no python3"; exit 2; }
command -v git     >/dev/null 2>&1 || { red "CANNOT-RUN: no git"; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="${OSTLER_DECLARED_RAN_ROOT:-$HERE}"
BASELINE="${OSTLER_CUT_TRIGGER_BASELINE:-$REPO_ROOT/scripts/cut_trigger_reachability_baseline.tsv}"

evaluate() {   # evaluate <repo-root> <declare-re> <runs-json> <baseline> ; 0/1/2
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, os, re, subprocess, sys

root, declare_re, runs_path, baseline_path = sys.argv[1:5]


def tracked(r):
    out = subprocess.run(["git", "-C", r, "ls-files"], capture_output=True, text=True)
    if out.returncode != 0:
        return None
    return [p for p in out.stdout.splitlines() if p]


def declarers(r, pattern):
    # -I skips binary files; -l names files; -n is deliberately absent because
    # the line number is not the subject here.
    out = subprocess.run(
        ["git", "-C", r, "grep", "-lniE", pattern, "--", "."],
        capture_output=True, text=True)
    # rc 1 means no match, which is a real answer. rc >1 is a broken query and
    # must not print as "nothing declares itself".
    if out.returncode > 1:
        return None
    return sorted(p for p in out.stdout.splitlines() if p)


EXEC_SUFFIX = (".sh", ".bash", ".py", ".zsh")


def is_executable_declarer(r, p):
    """The population verify_declared_gates_reachable.sh uses, restated.

    Kept byte-compatible in behaviour with is_executable_declarer() in that
    file: extension, workflow, Makefile, then the exec bit or a shebang.
    """
    if p.endswith(EXEC_SUFFIX):
        return True
    if p.startswith(".github/workflows/"):
        return True
    base = os.path.basename(p)
    if base in ("Makefile", "makefile", "GNUmakefile") or p.endswith(".mk"):
        return True
    full = os.path.join(r, p)
    if os.access(full, os.X_OK) and os.path.isfile(full):
        return True
    try:
        with open(full, "rb") as fh:
            return fh.read(2) == b"#!"
    except OSError:
        return False


NAME_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.\-]*\.(?:sh|bash|py|zsh|mk)\b")


def build_graph(r, files):
    """basename -> paths, and path -> the paths its text names.

    A NAME and not a full path, because that is how these files actually invoke
    each other: `bash tests/test_x.sh`, `python3 scripts/y.py`, `$HERE/z.sh`.
    Matching on full paths alone misses every relative and variable-prefixed
    invocation, which is most of them.
    """
    by_name = {}
    for p in files:
        by_name.setdefault(os.path.basename(p), []).append(p)
    names = {}
    for p in files:
        try:
            with open(os.path.join(r, p), "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            names[p] = set()
            continue
        hits = set()
        for m in NAME_RE.finditer(text):
            for target in by_name.get(m.group(0), ()):
                if target != p:
                    hits.add(target)
        names[p] = hits
    return names


def load_runs(path):
    with open(path) as fh:
        doc = json.load(fh)
    # `gh api --paginate --slurp` returns an ARRAY OF PAGE OBJECTS. Reading page
    # one alone would be worse than crashing: it would report a workflow absent
    # because its run sat on page two. See verify_tagged_commit_is_green.sh's
    # v1.0.51 regression for the same trap in the other gate.
    runs = []
    if isinstance(doc, list):
        for page in doc:
            if isinstance(page, dict):
                runs.extend(page.get("workflow_runs") or [])
            elif isinstance(page, list):
                runs.extend(page)
    elif isinstance(doc, dict):
        runs = doc.get("workflow_runs") or []
    return runs


files = tracked(root)
if not files:
    print("CANNOT-RUN\tgit ls-files returned nothing under %s" % root)
    raise SystemExit(2)

decl = declarers(root, declare_re)
if decl is None:
    print("CANNOT-RUN\tthe declarer query failed (git grep exited >1), so the "
          "population is unknown. A zero here would be a broken pattern, not a "
          "solved problem.")
    raise SystemExit(2)
decl = [p for p in decl if is_executable_declarer(root, p)]
if not decl:
    print("CANNOT-RUN\t0 EXECUTABLE files declare themselves cut-blocking under "
          "%s. Every repo in this estate has some; a zero means the pattern "
          "stopped matching." % root)
    raise SystemExit(2)

try:
    runs = load_runs(runs_path)
except Exception as exc:                        # noqa: BLE001
    print("CANNOT-RUN\tunreadable workflow-run payload: %s" % exc)
    raise SystemExit(2)

if not runs:
    # THE ZERO DENOMINATOR. "No gate failed to run" over an empty run list is a
    # statement about the query, not about the commit.
    print("CANNOT-RUN\tthe commit has ZERO workflow runs. That is a query that "
          "could not see, or a commit nothing ever ran on -- either way this "
          "gate has observed nothing and a pass would be manufactured.")
    raise SystemExit(2)

# workflow file path -> the strongest thing that happened to it at this commit
RAN, SCHEDULED = "ran", "scheduled"
state = {}
for r in runs:
    path = r.get("path") or ""
    if not path:
        continue
    status = (r.get("status") or "").lower()
    concl = (r.get("conclusion") or "").lower()
    if status in ("queued", "in_progress", "waiting", "requested", "pending"):
        state.setdefault(path, SCHEDULED)
        continue
    # A completed run with conclusion "skipped" means every job was skipped by
    # an `if:`. The workflow fired and the gate did NOT execute, which is the
    # question this file asks, so it does not count as having run.
    if concl and concl != "skipped":
        state[path] = RAN

graph = build_graph(root, files)
workflows = [p for p in files if p.startswith(".github/workflows/")
             and (p.endswith(".yml") or p.endswith(".yaml"))]

# Forward reach from each workflow, so every declarer learns which workflows
# could have executed it. Bounded by the file count, so it terminates.
reached_by = {}
for w in workflows:
    seen, frontier = set(), [w]
    while frontier:
        cur = frontier.pop()
        for nxt in graph.get(cur, ()):
            if nxt not in seen:
                seen.add(nxt)
                frontier.append(nxt)
    for f in seen:
        reached_by.setdefault(f, set()).add(w)

recorded = {}
try:
    with open(baseline_path, encoding="utf-8") as fh:
        for line in fh:
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.rstrip("\n").split("\t")
            if parts and parts[0]:
                recorded[parts[0]] = parts[1] if len(parts) > 1 else "RECORDED"
except OSError:
    recorded = {}

ran, sched, accepted, unreached, missing = [], [], [], [], []
for d in decl:
    ws = sorted(reached_by.get(d, ()))
    if d.startswith(".github/workflows/"):
        ws = sorted(set(ws) | {d})
    if not ws:
        # No workflow reaches it at all. That is axis one's finding (#1164) and
        # this gate must not restate it as a trigger defect; it is counted and
        # named so the denominator is visible.
        unreached.append(d)
        continue
    states = {state.get(w) for w in ws}
    if RAN in states:
        ran.append(d)
    elif SCHEDULED in states:
        sched.append(d)
    elif d in recorded:
        accepted.append((d, recorded[d]))
    else:
        missing.append((d, ws))

print("EXAMINED\t%d executable declarer(s), %d workflow(s) in the tree, "
      "%d workflow run(s) at this commit, %d baseline row(s)"
      % (len(decl), len(workflows), len(runs), len(recorded)))
print("TALLY\tran=%d scheduled=%d recorded=%d not-reached-by-any-workflow=%d "
      "DID-NOT-RUN=%d" % (len(ran), len(sched), len(accepted), len(unreached),
                          len(missing)))
for d in unreached:
    print("UNREACHED\t%s" % d)
for d, why in accepted:
    print("RECORDED\t%s\t%s" % (d, why))
for d, ws in missing:
    print("MISSING\t%s\t%s" % (d, ",".join(ws)))

raise SystemExit(1 if missing else 0)
PY
}

# ---------------------------------------------------------------------------
# SELF-TEST. Hermetic: a fixture repo and a recorded run list, so the arms
# below have known correct answers rather than whatever the estate looks like
# today.
# ---------------------------------------------------------------------------
self_test() {
    local tmp pass=0 fail=0 out rc
    tmp="$(mktemp -d -t declran_XXXXXX)"
    trap 'rm -rf "$tmp"' RETURN
    ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
    no() { printf '  FAIL  %s\n' "$1"; printf '%s\n' "${2:-}" | sed 's/^/        | /'; fail=$((fail + 1)); }

    local r="$tmp/repo"
    mkdir -p "$r/.github/workflows" "$r/scripts"
    git init -q "$r"
    git -C "$r" config user.email a@example.com
    git -C "$r" config user.name a

    # COMPOSED, NOT WRITTEN LITERALLY. DECLARE_RE matches on prose, so a
    # fixture carrying the literal phrase would make THIS FILE a declarer,
    # which it is not. Same trap the axis-three test documents: a fixture that
    # carries the flag it plants.
    local p1='BLOCKS THE' p2='CUT' decl
    decl="# This ${p1} ${p2}."
    printf '#!/usr/bin/env bash\n%s\nexit 0\n' "$decl" > "$r/scripts/gate_that_ran.sh"
    printf '#!/usr/bin/env bash\n%s\nexit 0\n' "$decl" > "$r/scripts/gate_that_did_not.sh"
    chmod +x "$r/scripts/gate_that_ran.sh" "$r/scripts/gate_that_did_not.sh"
    cat > "$r/.github/workflows/ran.yml" <<'YEOF'
name: ran
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash scripts/gate_that_ran.sh
YEOF
    cat > "$r/.github/workflows/didnot.yml" <<'YEOF'
name: didnot
on:
  push:
    branches: [main]
    paths: ['scripts/gate_that_did_not.sh']
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash scripts/gate_that_did_not.sh
YEOF
    git -C "$r" add -A
    git -C "$r" commit -qm fixture

    # The recorded reading: one workflow ran at the commit, the other did not.
    cat > "$tmp/runs.json" <<'JEOF'
{"workflow_runs": [
  {"path": ".github/workflows/ran.yml", "status": "completed", "conclusion": "success"}
]}
JEOF
    printf '[]\n' > "$tmp/empty.json"
    cat > "$tmp/skipped.json" <<'JEOF'
{"workflow_runs": [
  {"path": ".github/workflows/ran.yml",    "status": "completed", "conclusion": "success"},
  {"path": ".github/workflows/didnot.yml", "status": "completed", "conclusion": "skipped"}
]}
JEOF
    cat > "$tmp/pages.json" <<'JEOF'
[{"workflow_runs": [{"path": ".github/workflows/ran.yml", "status": "completed", "conclusion": "success"}]},
 {"workflow_runs": [{"path": ".github/workflows/didnot.yml", "status": "completed", "conclusion": "success"}]}]
JEOF
    : > "$tmp/baseline-empty.tsv"
    printf '# path\tstatus\tnote\n.github/workflows/didnot.yml\tDECIDED\tfixture\nscripts/gate_that_did_not.sh\tDECIDED\tfixture\n' > "$tmp/baseline-full.tsv"

    echo "verify_declared_gates_ran_at_commit --self-test"
    echo

    # 1. THE DEFECT. A declarer whose only workflow did not run at the commit.
    out="$(evaluate "$r" "$DECLARE_RE" "$tmp/runs.json" "$tmp/baseline-empty.tsv")"; rc=$?
    if [ "$rc" != 1 ]; then
        no "(1) a gate that did not run at the commit was not caught (rc=${rc})" "$out"
    elif printf '%s\n' "$out" | grep -q '^MISSING	scripts/gate_that_did_not.sh'; then
        ok "(1) a declarer whose workflow had no run at the commit is named, rc=1"
    else
        no "(1) rc=1 but the missing gate is not named" "$out"
    fi

    # 2. POSITIVE CONTROL. The declarer whose workflow DID run must not be
    #    named, or arm 1 would just mean everything is reported missing.
    printf '%s\n' "$out" | grep -q '^MISSING	scripts/gate_that_ran.sh' \
        && no "(2) CONTROL FAILED: a gate that DID run was also reported missing" "$out" \
        || ok "(2) CONTROL: the declarer whose workflow ran is not reported missing"

    # 3. The baseline is honoured, and it is axis three's file, not a new one.
    out="$(evaluate "$r" "$DECLARE_RE" "$tmp/runs.json" "$tmp/baseline-full.tsv")"; rc=$?
    [ "$rc" = 0 ] \
        && ok "(3) a declarer recorded in the axis-three baseline is accepted, rc=0" \
        || no "(3) a recorded declarer still failed the gate (rc=${rc})" "$out"

    # 4. ZERO DENOMINATOR. No runs at the commit is CANNOT-RUN, never a pass.
    out="$(evaluate "$r" "$DECLARE_RE" "$tmp/empty.json" "$tmp/baseline-empty.tsv")"; rc=$?
    [ "$rc" = 2 ] \
        && ok "(4) zero workflow runs at the commit is CANNOT-RUN (rc=2), not a clean bill" \
        || no "(4) an empty run list returned rc=${rc}, expected 2" "$out"

    # 5. A SKIPPED RUN IS NOT A RUN. The workflow fired and every job was
    #    skipped by an if:, so the gate did not execute.
    out="$(evaluate "$r" "$DECLARE_RE" "$tmp/skipped.json" "$tmp/baseline-empty.tsv")"; rc=$?
    if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q '^MISSING	scripts/gate_that_did_not.sh'; then
        ok "(5) a run whose conclusion is 'skipped' does not count as having run"
    else
        no "(5) a skipped run was accepted as the gate having run (rc=${rc})" "$out"
    fi

    # 6. PAGINATION. `gh api --slurp` returns an array of PAGE objects. Reading
    #    page one alone would report a workflow absent whose run is on page two.
    out="$(evaluate "$r" "$DECLARE_RE" "$tmp/pages.json" "$tmp/baseline-empty.tsv")"; rc=$?
    [ "$rc" = 0 ] \
        && ok "(6) runs are merged across pages, so a run on page two is not read as an absence" \
        || no "(6) a run on page two was missed (rc=${rc})" "$out"

    # 7. A BROKEN PATTERN IS CANNOT-RUN, NOT A CLEAN TREE. A pattern that
    #    matches nothing prints exactly like a repo with no cut-blockers.
    out="$(evaluate "$r" 'ZZZ_NOTHING_MATCHES_THIS_ZZZ' "$tmp/runs.json" "$tmp/baseline-empty.tsv")"; rc=$?
    [ "$rc" = 2 ] \
        && ok "(7) a pattern matching zero declarers is CANNOT-RUN, not 'nothing to check'" \
        || no "(7) a zero population returned rc=${rc}, expected 2" "$out"

    echo
    echo "EXAMINED: 7 arms over one fixture repo, 2 declarers, 2 workflows, 4 recorded run lists."
    echo "=== ${pass} passed / ${fail} failed ==="
    [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit $?
fi

SHA="${1:-}"
REPO="${2:-${GITHUB_REPOSITORY:-}}"
if [ -z "$SHA" ]; then
    red "CANNOT-RUN: usage: $0 <sha> [repo]   (or --self-test)"
    exit 2
fi

RUNS_JSON="${OSTLER_WORKFLOW_RUNS_JSON:-}"
TMPD=""
if [ -z "$RUNS_JSON" ]; then
    if [ -z "$REPO" ]; then
        red "CANNOT-RUN: no repo given and GITHUB_REPOSITORY is unset, so there is nothing to query."
        exit 2
    fi
    command -v gh >/dev/null 2>&1 || { red "CANNOT-RUN: no gh on PATH and no OSTLER_WORKFLOW_RUNS_JSON"; exit 2; }
    TMPD="$(mktemp -d -t declran_api_XXXXXX)"
    trap 'rm -rf "$TMPD"' EXIT
    RUNS_JSON="$TMPD/runs.json"
    # --slurp because --paginate without it concatenates one JSON object per
    # page and nothing can parse the result. The reader merges pages.
    if ! gh api --paginate --slurp \
            "repos/${REPO}/actions/runs?head_sha=${SHA}&per_page=100" \
            > "$RUNS_JSON" 2>"$TMPD/err"; then
        red "CANNOT-RUN: the Actions API could not be read for ${REPO}@${SHA}."
        sed 's/^/  /' "$TMPD/err" >&2
        exit 2
    fi
fi

dim "verify-declared-gates-ran: ${REPO:-<fixture>} @ ${SHA}"
OUT="$(evaluate "$REPO_ROOT" "$DECLARE_RE" "$RUNS_JSON" "$BASELINE")"
RC=$?

printf '%s\n' "$OUT" | sed 's/^/  /'

case "$RC" in
    0) green "verify-declared-gates-ran: every self-declared cut-blocker either ran at this commit, is scheduled to, or is recorded in ${BASELINE##*/}." ;;
    1)
        red "verify-declared-gates-ran: a gate that declares itself cut-blocking DID NOT RUN at the commit being cut, and is not recorded."
        red "  Reachable from the cut is not the same as ran on the cut (#1167). Each"
        red "  MISSING row names the workflows that could have executed it; none of"
        red "  them produced a run at this commit. Give the gate a trigger that fires"
        red "  on the cut, or record the decision in ${BASELINE##*/} with a reason."
        ;;
    *)
        red "verify-declared-gates-ran: CANNOT-RUN. A check that did not happen is not a check that passed."
        ;;
esac
exit "$RC"
