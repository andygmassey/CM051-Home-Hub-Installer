#!/usr/bin/env bash
# scripts/verify_pr_gate_aggregate.sh -- the ONE check branch protection can
# honestly require.
# ============================================================================
#
# WHY THIS EXISTS
# ============================================================================
#
# Measured 2026-09-12: this repository's default branch has NO protection at
# all -- the protection endpoint answers "Branch not protected" and the
# ruleset list is empty. Around 150 workflow files run pull-request checks,
# several call themselves unbypassable in their own header comments, and not
# one of them can block a merge. Red has been mergeable the whole time.
#
# A first attempt to fix this today lasted under a minute. The obvious move --
# require the job literally named `gate` -- fails, because `gate` is a job
# inside two PATH-FILTERED workflows (cannot-run-branch-reachable.yml,
# customer-download-path.yml, plus three more sharing the name), not an
# aggregate. Requiring it would block every PR that does not touch those
# workflows' watched paths: GitHub waits forever for a required check that a
# path filter means will never be reported.
#
# Requiring every check individually is equally unworkable for the same
# reason, doubled: measured the same day, of 142 workflow files with a
# `pull_request:` trigger, 110 are path-filtered by design (they watch the
# files their gate actually proves something about) and only 30 fire
# unconditionally. A required check that a given PR's diff never triggers
# blocks that PR forever.
#
# THE FIX. One workflow, unconditional, exposing exactly one check whose name
# never changes: "CI Required Gate". Branch protection requires only that
# name. This script IS that check's decision: it polls every OTHER check-run
# reported against the PR's head commit until every one of them has concluded,
# then passes only if none failed or was cancelled.
#
# ============================================================================
# THE PART THAT MATTERS MORE THAN THE POLLING
# ============================================================================
#
# A required check that can report success having examined nothing is worse
# than no protection at all, because it LOOKS like protection. Four ways this
# script refuses to pass vacuously, each with a self-test case:
#
#   1. CANNOT REACH THE API             -> CANNOT-RUN (exit 2), never green.
#   2. ZERO check-runs enumerated       -> CANNOT-RUN. A zero denominator is a
#      fact about the query, not about the commit -- this estate's oldest
#      recurring defect (see verify_tagged_commit_is_green.sh, the same shape).
#   3. FEWER THAN THE FLOOR             -> CANNOT-RUN. The floor is not a
#      hand-picked constant that goes stale: it is RECOMPUTED every run from
#      the checked-out tree, counting workflow files whose `pull_request:`
#      trigger carries no `paths:`/`paths-ignore:` filter (this file excluded
#      by name). Those files are the ones GUARANTEED to produce a check-run on
#      every single PR; if fewer of them show up than the tree currently
#      declares, the enumeration itself is suspect and this refuses to guess
#      why. Measured 2026-09-12: floor is 30.
#   4. SAMPLING ONCE                    -> this polls. A check still
#      in_progress or queued when we look is not evidence of anything; the
#      loop waits (bounded by OSTLER_GATE_MAX_WAIT_SECONDS) and re-reads until
#      every non-self check-run has a `completed` status or the window closes.
#      Hitting the window with something still pending is CANNOT-RUN, never a
#      quiet pass -- conflating "I got tired of waiting" with "it finished
#      clean" is exactly the vacuous-pass defect this file exists to refuse.
#
# A conclusion of `skipped` or `neutral` is accepted at face value -- that is
# the normal, reviewed shape of a job with a deliberate `if:` guard, and this
# repository's own idiom (verify_tagged_commit_is_green.sh) already treats it
# that way. What is NOT accepted is a conclusion this script does not
# recognise (a `null` on a completed run, or any future GitHub conclusion
# value not in the known-good or known-bad sets below): that is a skip for a
# reason this script cannot establish, and it fails closed rather than
# guessing it was fine.
#
# ============================================================================
# WHAT THIS DOES NOT PROVE
# ============================================================================
#
# A workflow whose `uses:` cannot resolve fails at STARTUP and produces ZERO
# jobs, therefore ZERO check-runs (see verify_no_invisible_reusable_workflows.sh
# for the incident this describes). Such a workflow is invisible to this
# script exactly as it is invisible to `gh pr checks` and to the PR merge box.
# For any of the 30 unconditional workflows this is caught indirectly: the
# floor undercounts and this refuses. For a path-filtered workflow that goes
# invisible on the one PR that should have triggered it, this script cannot
# tell the difference between "legitimately did not apply" and "silently
# failed to start", because GitHub gives it nothing to look at either way.
# That gap is real and is not this script's to close.
#
# ============================================================================
# USAGE
# ============================================================================
#   scripts/verify_pr_gate_aggregate.sh <head-sha> [owner/repo]
#   scripts/verify_pr_gate_aggregate.sh --self-test
#
# ENV (all optional; defaults are the safe, live-computing ones)
#   OSTLER_GATE_OWN_JOB_NAMES        comma-separated check-run name(s) to
#                                    exclude as self. Default: "CI Required Gate"
#   OSTLER_GATE_FLOOR                override the computed floor (testing only;
#                                    the real run computes it from the tree)
#   OSTLER_GATE_WORKFLOWS_DIR        default: <repo-root>/.github/workflows
#   OSTLER_GATE_SELF_WORKFLOW_FILE   basename excluded from the floor scan.
#                                    Default: ci-required-gate.yml
#   OSTLER_GATE_POLL_INTERVAL_SECONDS  default 20
#   OSTLER_GATE_MAX_WAIT_SECONDS        default 2700 (45 min; the job's own
#                                    timeout-minutes is 60, leaving headroom
#                                    for this script to report CANNOT-RUN
#                                    rather than being killed mid-poll)
#   OSTLER_CHECKRUNS_JSON            test-mode: one fixture, used every poll
#   OSTLER_CHECKRUNS_JSON_SEQUENCE   test-mode: colon-separated fixtures, one
#                                    consumed per poll attempt (repeats the
#                                    last once exhausted) -- how the self-test
#                                    proves this waits rather than sampling
#
# EXIT CODES
#   0  GREEN     -- every non-self check-run concluded success/skipped/neutral
#   1  RED       -- at least one failed, was cancelled, or reported a
#                   conclusion this script does not recognise
#   2  CANNOT-RUN -- nothing was safely established; never treated as a pass
#
# British English throughout; " -- " not em-dashes.
# ============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

red()   { printf '\033[0;31m%s\033[0m\n' "$1" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
dim()   { printf '\033[2m%s\033[0m\n' "$1" >&2; }

BLOCKING='failure cancelled timed_out action_required stale'
GOOD='success skipped neutral'

# ---------------------------------------------------------------------------
# resolve_floor -- the anti-vacuity floor, recomputed from the tree every run
# unless OSTLER_GATE_FLOOR overrides it (self-test only; a live run must never
# set this, or the floor stops meaning anything).
# ---------------------------------------------------------------------------
resolve_floor() {
    if [ -n "${OSTLER_GATE_FLOOR:-}" ]; then
        echo "${OSTLER_GATE_FLOOR}"
        return 0
    fi
    local wf_dir self
    wf_dir="${OSTLER_GATE_WORKFLOWS_DIR:-$REPO_ROOT/.github/workflows}"
    self="${OSTLER_GATE_SELF_WORKFLOW_FILE:-ci-required-gate.yml}"
    if [ ! -d "$wf_dir" ]; then
        echo "CANNOT-RUN-FLOOR"
        return 2
    fi
    WORKFLOWS_DIR="$wf_dir" SELF_WORKFLOW_FILE="$self" python3 - <<'PY'
import glob, os, sys
try:
    import yaml
except Exception:
    print("CANNOT-RUN-FLOOR")
    sys.exit(2)

wf_dir = os.environ["WORKFLOWS_DIR"]
self_file = os.environ["SELF_WORKFLOW_FILE"]
count = 0
for path in sorted(glob.glob(os.path.join(wf_dir, "*.yml")) + glob.glob(os.path.join(wf_dir, "*.yaml"))):
    if os.path.basename(path) == self_file:
        continue
    try:
        with open(path) as fh:
            doc = yaml.safe_load(fh)
    except Exception:
        # A workflow file that cannot even be parsed cannot be proven
        # unconditional, so it does not raise the floor. Undercounting here
        # is the safe direction: it can only make the gate MORE willing to
        # refuse, never less.
        continue
    if not isinstance(doc, dict):
        continue
    # PyYAML 1.1 quirk: a bare `on:` key can load under the boolean key
    # `True` rather than the string "on" depending on loader/version.
    on = doc["on"] if "on" in doc else doc.get(True)
    if on is None:
        continue
    has_pr = False
    pr_val = None
    if isinstance(on, dict):
        has_pr = "pull_request" in on
        pr_val = on.get("pull_request")
    elif isinstance(on, list):
        has_pr = "pull_request" in on
    elif isinstance(on, str):
        has_pr = (on == "pull_request")
    if not has_pr:
        continue
    # Bare `pull_request:` (value None) or an empty map is unconditional.
    if pr_val is None or pr_val == {}:
        count += 1
        continue
    if isinstance(pr_val, dict) and "paths" not in pr_val and "paths-ignore" not in pr_val:
        count += 1
print(count)
PY
}

# ---------------------------------------------------------------------------
# fetch_check_runs <sha> <repo> <outfile> <attempt> -- writes the raw
# check-runs payload to <outfile>. Returns 0 on success, non-zero if this
# round could not be read (the caller treats that as PENDING and retries
# until the wait window closes, not as an immediate verdict -- a single
# transient API hiccup must not sink a whole PR).
# ---------------------------------------------------------------------------
fetch_check_runs() {
    local sha="$1" repo="$2" out="$3" attempt="$4"

    if [ -n "${OSTLER_CHECKRUNS_JSON_SEQUENCE:-}" ]; then
        local old_ifs="$IFS" seq idx n
        IFS=':' read -r -a seq <<< "$OSTLER_CHECKRUNS_JSON_SEQUENCE"
        IFS="$old_ifs"
        n=${#seq[@]}
        idx=$((attempt - 1))
        [ "$idx" -ge "$n" ] && idx=$((n - 1))
        [ "$idx" -lt 0 ] && idx=0
        cp "${seq[$idx]}" "$out" 2>/dev/null || {
            dim "  fixture unreadable: ${seq[$idx]}"
            return 1
        }
        return 0
    fi

    if [ -n "${OSTLER_CHECKRUNS_JSON:-}" ]; then
        cp "$OSTLER_CHECKRUNS_JSON" "$out" 2>/dev/null || {
            dim "  fixture unreadable: $OSTLER_CHECKRUNS_JSON"
            return 1
        }
        return 0
    fi

    if ! gh api "repos/$repo/commits/$sha/check-runs" --paginate --slurp > "$out" 2>"$out.err"; then
        # gh's stderr is PRINTED, not swallowed -- `2>/dev/null` on a probe
        # turns a usage error, an auth failure and a real absence into the
        # same silent sentence.
        [ -s "$out.err" ] && dim "  gh said: $(tr '\n' ' ' < "$out.err" | cut -c1-300)"
        rm -f "$out.err"
        return 1
    fi
    rm -f "$out.err"
    return 0
}

# ---------------------------------------------------------------------------
# evaluate <json-file> -- classifies ONE snapshot. Prints a tab-separated
# line: STATE  SUBVERDICT  TOTAL  COMPLETED  EXCLUDED  DETAIL
#   STATE       PENDING (keep polling) or DONE (subverdict is final)
#   SUBVERDICT  only meaningful when STATE=DONE: GREEN, RED, or CANNOT-RUN
# Reads OSTLER_GATE_OWN_JOB_NAMES and the floor from env (both exported by
# the caller before invoking this).
# ---------------------------------------------------------------------------
evaluate() {
    local f="$1"
    python3 - "$f" <<'PY'
import json, os, sys

BLOCKING = {"failure", "cancelled", "timed_out", "action_required", "stale"}
GOOD = {"success", "skipped", "neutral"}

f = sys.argv[1]
own = {n.strip() for n in os.environ.get("OSTLER_GATE_OWN_JOB_NAMES", "CI Required Gate").split(",") if n.strip()}
try:
    floor = int(os.environ["OSTLER_GATE_FLOOR_RESOLVED"])
except Exception:
    print("DONE\tCANNOT-RUN\t0\t0\t0\tno usable floor was resolved -- refusing to guess one")
    raise SystemExit(0)

try:
    doc = json.load(open(f))
except Exception as exc:
    # Unreadable is treated as PENDING here, not an immediate verdict: a
    # single garbled response is retried by the outer loop, and the overall
    # wait window is the backstop that turns a PERSISTENT failure into
    # CANNOT-RUN rather than letting it retry forever.
    print(f"PENDING\t-\t0\t0\t0\tunreadable check-run payload this round: {exc}")
    raise SystemExit(0)

# `gh api --paginate --slurp` returns an ARRAY OF PAGE OBJECTS; a bare fixture
# object (used in tests, and possible from a single-page real response
# depending on gh version) is also accepted. Merged, never truncated -- see
# verify_tagged_commit_is_green.sh's v1.0.51 regression for why truncating a
# multi-page payload is worse than failing to read it at all.
if isinstance(doc, list):
    runs = []
    for page in doc:
        if isinstance(page, dict):
            runs.extend(page.get("check_runs") or [])
        else:
            runs.append(page)
else:
    runs = doc.get("check_runs") or []

seen = len(runs)
runs = [r for r in runs if r.get("name") not in own]
excluded = seen - len(runs)
total = len(runs)

if total == 0:
    # Ambiguous on its own: could be a genuine dead enumeration, or simply
    # too early -- 140-odd workflows do not all queue in the same instant.
    # PENDING lets the outer wait window be the judge; if it is STILL zero
    # when the window closes, that is reported as CANNOT-RUN there, not here.
    print(f"PENDING\t-\t0\t0\t{excluded}\tzero non-self check-run(s) seen so far")
    raise SystemExit(0)

pending = [r for r in runs if r.get("status") != "completed"]
completed = [r for r in runs if r.get("status") == "completed"]

if pending:
    names = ", ".join(sorted(r.get("name") or "?" for r in pending)[:8])
    more = "" if len(pending) <= 8 else f" (+{len(pending) - 8} more)"
    print(f"PENDING\t-\t{total}\t{len(completed)}\t{excluded}\t"
          f"{len(pending)} of {total} not yet completed: {names}{more}")
    raise SystemExit(0)

# Every non-self check-run has status == completed from here on.
if total < floor:
    print(f"DONE\tCANNOT-RUN\t{total}\t{len(completed)}\t{excluded}\t"
          f"only {total} non-self check-run(s) ever concluded; the tree's own "
          f"unconditional-workflow count is {floor}. The enumeration itself is "
          f"suspect -- refusing to guess why fewer showed up.")
    raise SystemExit(0)

bad = [r for r in completed if r.get("conclusion") in BLOCKING]
unknown = [r for r in completed if r.get("conclusion") not in GOOD and r.get("conclusion") not in BLOCKING]

if bad:
    names = "; ".join(f"{r.get('name')}={r.get('conclusion')}" for r in bad)
    print(f"DONE\tRED\t{total}\t{len(completed)}\t{excluded}\tfailed or cancelled: {names}")
    raise SystemExit(0)

if unknown:
    names = "; ".join(f"{r.get('name')}={r.get('conclusion')!r}" for r in unknown)
    print(f"DONE\tRED\t{total}\t{len(completed)}\t{excluded}\t"
          f"unrecognised conclusion, cannot establish it was a legitimate skip: {names}")
    raise SystemExit(0)

skipped = sorted(r.get("name") for r in completed if r.get("conclusion") == "skipped")
skip_note = ("skipped: " + ", ".join(skipped)) if skipped else "none skipped"
print(f"DONE\tGREEN\t{total}\t{len(completed)}\t{excluded}\tall clean ({skip_note})")
PY
}

# ---------------------------------------------------------------------------
# poll_and_decide <sha> <repo> -- the loop. Waits properly; never samples once.
# ---------------------------------------------------------------------------
poll_and_decide() {
    local sha="$1" repo="$2"
    local own interval max_wait floor
    own="${OSTLER_GATE_OWN_JOB_NAMES:-CI Required Gate}"
    interval="${OSTLER_GATE_POLL_INTERVAL_SECONDS:-20}"
    max_wait="${OSTLER_GATE_MAX_WAIT_SECONDS:-2700}"

    floor="$(resolve_floor)"
    if [ "$floor" = "CANNOT-RUN-FLOOR" ] || ! [[ "$floor" =~ ^[0-9]+$ ]]; then
        red "CANNOT-RUN: could not compute the anti-vacuity floor (no PyYAML, or no workflows directory)."
        dim "Nothing was measured. This is not a pass."
        return 2
    fi

    dim "polling check-runs for ${sha:0:12} in $repo -- floor=${floor}, excluding: ${own}"

    local start now elapsed attempt=0 tmp state subverdict total completed excluded detail fetch_rc
    start=$(date +%s)
    while true; do
        attempt=$((attempt + 1))
        tmp="$(mktemp)"
        fetch_check_runs "$sha" "$repo" "$tmp" "$attempt"
        fetch_rc=$?
        now=$(date +%s)
        elapsed=$((now - start))

        if [ "$fetch_rc" -ne 0 ]; then
            state="PENDING"; subverdict="-"; total=0; completed=0; excluded=0
            detail="could not read check-runs this round"
        else
            IFS=$'\t' read -r state subverdict total completed excluded detail < <(
                OSTLER_GATE_FLOOR_RESOLVED="$floor" OSTLER_GATE_OWN_JOB_NAMES="$own" evaluate "$tmp")
        fi
        rm -f "$tmp" "$tmp.err" 2>/dev/null

        dim "  [poll ${attempt}, ${elapsed}s elapsed] EXAMINED ${total} non-self check-run(s) (${completed} completed, ${excluded} excluded as self) -- ${detail}"

        if [ "$state" = "DONE" ]; then
            break
        fi

        if [ "$elapsed" -ge "$max_wait" ]; then
            state="DONE"; subverdict="CANNOT-RUN"
            detail="timed out after ${elapsed}s still waiting (last look: ${detail})"
            break
        fi

        sleep "$interval"
    done

    case "$subverdict" in
        GREEN)
            green "CI REQUIRED GATE GREEN -- ${total} non-self check-run(s) examined, ${excluded} excluded as self, none failed."
            dim "  $detail"
            return 0 ;;
        RED)
            red "CI REQUIRED GATE RED -- refusing to pass ${sha:0:12}."
            dim "  $detail"
            return 1 ;;
        *)
            red "CANNOT-RUN: $detail"
            dim "Nothing was safely established, so this is NOT a pass. A vacuous green is"
            dim "the exact defect this check exists to refuse."
            return 2 ;;
    esac
}

# ===========================================================================
# SELF-TEST
# ===========================================================================
if [ "${1:-}" = "--self-test" ]; then
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    fail=0
    note() { printf '  %s\n' "$*"; }
    mk() { printf '%s' "$2" > "$TMP/$1.json"; }

    ok3()  { printf '{"name":"a","status":"completed","conclusion":"success"}'; }

    # A synthetic "big enough" green fixture: 3 non-self runs, floor forced to 3.
    mk green3 '{"check_runs":[
        {"name":"a","status":"completed","conclusion":"success"},
        {"name":"b","status":"completed","conclusion":"skipped"},
        {"name":"c","status":"completed","conclusion":"neutral"}]}'

    mk red3 '{"check_runs":[
        {"name":"a","status":"completed","conclusion":"success"},
        {"name":"b","status":"completed","conclusion":"failure"},
        {"name":"c","status":"completed","conclusion":"success"}]}'

    mk cancelled3 '{"check_runs":[
        {"name":"a","status":"completed","conclusion":"success"},
        {"name":"b","status":"completed","conclusion":"cancelled"},
        {"name":"c","status":"completed","conclusion":"success"}]}'

    mk unknown3 '{"check_runs":[
        {"name":"a","status":"completed","conclusion":"success"},
        {"name":"b","status":"completed","conclusion":"weird_new_state"},
        {"name":"c","status":"completed","conclusion":"success"}]}'

    mk empty '{"check_runs":[]}'

    mk belowfloor '{"check_runs":[
        {"name":"a","status":"completed","conclusion":"success"}]}'

    mk garbage 'not json at all'

    mk ownfail3 '{"check_runs":[
        {"name":"CI Required Gate","status":"completed","conclusion":"cancelled"},
        {"name":"a","status":"completed","conclusion":"success"},
        {"name":"b","status":"completed","conclusion":"success"},
        {"name":"c","status":"completed","conclusion":"skipped"}]}'

    mk lookalike3 '{"check_runs":[
        {"name":"ci required gate","status":"completed","conclusion":"failure"},
        {"name":"a","status":"completed","conclusion":"success"},
        {"name":"b","status":"completed","conclusion":"success"},
        {"name":"c","status":"completed","conclusion":"success"}]}'

    mk onepending3 '{"check_runs":[
        {"name":"a","status":"completed","conclusion":"success"},
        {"name":"b","status":"in_progress","conclusion":null},
        {"name":"c","status":"completed","conclusion":"success"}]}'

    # A subshell can't just prefix env vars before a function call the way it
    # can before a binary, so wrap it.
    run_case2() {
        local want="$1" label="$2" file="$3"
        (
            OSTLER_CHECKRUNS_JSON="$TMP/$file.json" \
            OSTLER_GATE_FLOOR=3 \
            OSTLER_GATE_MAX_WAIT_SECONDS=1 \
            OSTLER_GATE_POLL_INTERVAL_SECONDS=1 \
            poll_and_decide deadbeefdeadbeef owner/repo
        ) >/dev/null 2>&1
        local rc=$?
        if [ "$rc" -eq "$want" ]; then note "PASS  rc=$rc  $label"; else note "FAIL  rc=$rc want=$want  $label"; fail=1; fi
    }

    echo "=== guard: aggregate must not report success while an input failed ==="
    run_case2 0 "POSITIVE CONTROL: all-clean 3-of-3 (floor 3) -> GREEN" green3
    run_case2 1 "one FAILURE among 3 refuses (this is the guard: GREEN here would be the bug)" red3
    run_case2 1 "one CANCELLED among 3 refuses" cancelled3
    run_case2 1 "an unrecognised conclusion refuses -- cannot establish it was a legitimate skip" unknown3

    echo "=== guard: aggregate must not report success having enumerated nothing ==="
    run_case2 2 "ZERO check-runs is CANNOT-RUN even after the wait window (this is the guard: GREEN here would be the bug)" empty
    run_case2 2 "1-of-floor-3 is CANNOT-RUN -- below the anti-vacuity floor" belowfloor
    run_case2 2 "an unparseable payload never resolves and times out CANNOT-RUN" garbage

    echo "=== self-exclusion, by name only ==="
    run_case2 0 "the gate's OWN cancelled check-run does not refuse the commit" ownfail3
    run_case2 1 "CONTROL: a merely SIMILAR name ('ci required gate' lowercase) still refuses" lookalike3

    echo "=== it waits; it does not sample once ==="
    run_case2 2 "one run still in_progress at the wait window closes -> CANNOT-RUN, not GREEN" onepending3
    (
        OSTLER_CHECKRUNS_JSON_SEQUENCE="$TMP/onepending3.json:$TMP/green3.json" \
        OSTLER_GATE_FLOOR=3 \
        OSTLER_GATE_MAX_WAIT_SECONDS=10 \
        OSTLER_GATE_POLL_INTERVAL_SECONDS=1 \
        poll_and_decide deadbeefdeadbeef owner/repo
    ) >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
        note "PASS  rc=$rc  a check that finishes on the SECOND poll is picked up -- proves this re-reads rather than sampling once"
    else
        note "FAIL  rc=$rc want=0  the second poll's clean result was not picked up"; fail=1
    fi

    echo "=== the floor is recomputed from the tree, not a stale constant ==="
    FLOOR_TMP="$(mktemp -d)"
    cat > "$FLOOR_TMP/unconditional-one.yml" <<'YML'
name: unconditional-one
on:
  pull_request:
jobs:
  x: { runs-on: ubuntu-latest, steps: [] }
YML
    cat > "$FLOOR_TMP/unconditional-two.yml" <<'YML'
name: unconditional-two
on:
  pull_request: {}
jobs:
  x: { runs-on: ubuntu-latest, steps: [] }
YML
    cat > "$FLOOR_TMP/path-filtered.yml" <<'YML'
name: path-filtered
on:
  pull_request:
    paths: ['some/file.sh']
jobs:
  x: { runs-on: ubuntu-latest, steps: [] }
YML
    cat > "$FLOOR_TMP/push-only.yml" <<'YML'
name: push-only
on:
  push:
    branches: [main]
jobs:
  x: { runs-on: ubuntu-latest, steps: [] }
YML
    cat > "$FLOOR_TMP/ci-required-gate.yml" <<'YML'
name: ci-required-gate
on:
  pull_request:
jobs:
  gate: { runs-on: ubuntu-latest, steps: [] }
YML
    computed="$(OSTLER_GATE_WORKFLOWS_DIR="$FLOOR_TMP" resolve_floor)"
    if [ "$computed" = "2" ]; then
        note "PASS  floor computed as 2 (two unconditional workflows; the path-filtered one, the push-only one, and THIS SCRIPT'S OWN FILE are all correctly excluded)"
    else
        note "FAIL  floor computed as '$computed', want 2"; fail=1
    fi
    rm -rf "$FLOOR_TMP"

    # CONTROL: an OSTLER_GATE_FLOOR override still works (needed so the fixed
    # cases above are hermetic, and useful if a live floor computation is ever
    # wrong and needs a documented, visible override rather than a silent one).
    run_case2 0 "CONTROL: OSTLER_GATE_FLOOR override is honoured, not ignored" green3

    echo
    if [ "$fail" -eq 0 ]; then
        echo "RESULT: PASSED -- a failed/cancelled/unrecognised input refuses, an empty or"
        echo "        below-floor enumeration refuses, self-exclusion is by exact name only,"
        echo "        and a still-pending check is waited for, not sampled once."
        exit 0
    fi
    echo "RESULT: FAILED"
    exit 1
fi

SHA="${1:-}"
REPO="${2:-${GITHUB_REPOSITORY:-}}"
[ -n "$SHA" ]  || { red "usage: $0 <head-sha> [owner/repo]   or   $0 --self-test"; exit 2; }
[ -n "$REPO" ] || { red "CANNOT-RUN: no repo given and GITHUB_REPOSITORY is unset."; exit 2; }
poll_and_decide "$SHA" "$REPO"
