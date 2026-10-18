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
#      the checked-out tree, as the number of check-runs this PR is
#      GUARANTEED to get (resolve_expected: unfiltered `pull_request:`
#      workflows whose branches/types admit this PR, every job, every matrix
#      leg; this file excluded by name). Measured 2026-10-17: 40 check-runs
#      from 33 workflows. It used to count FILES (30, later 34).
#   3b. AN EXPECTED CHECK MISSING       -> RED, naming it. Counting alone was
#      not enough: the total it compared against includes every PATH-FILTERED
#      check too, so one required check that never reported (a workflow that
#      failed at startup, with zero jobs) was paid for by any filtered check
#      that did, and this gate stayed GREEN. Each expected check-run is now
#      required by identity, (workflow file, name), and check-runs are keyed
#      the same way, so two workflows' same-named jobs can no longer
#      supersede each other.
#   4. SAMPLING ONCE                    -> this polls. A check still
#      in_progress or queued when we look is not evidence of anything; the
#      loop waits (bounded by OSTLER_GATE_MAX_WAIT_SECONDS) and re-reads until
#      every non-self check-run has a `completed` status or the window closes.
#      Hitting the window with something still pending is CANNOT-RUN, never a
#      quiet pass -- conflating "I got tired of waiting" with "it finished
#      clean" is exactly the vacuous-pass defect this file exists to refuse.
#
# A FIFTH CLASS, not a vacuous pass but its mirror image: a vacuous FAIL. A
# check name can have more than one attempt on the same commit (a concurrency
# rule cancels an in-flight run when the PR is pushed to again, or edited, or
# anything else refires the workflow), and a check-run object is immutable --
# a superseded cancellation stays attached to the commit forever. Evaluating
# every attempt would mean a PR that was ever pushed to twice could never go
# green, which is protection nobody can satisfy. So for each name, only the
# LATEST attempt (by `id`, see the comment where attempts are reduced, below)
# decides: a cancellation superseded by a later success is not a failure; a
# cancellation that is still the latest attempt for its name is one, because
# nobody re-ran it. Measured 2026-09-12, CM051 PR #1937: exactly this shape.
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
#                                    exclude as self. Default now also carries
#                                    cut,preflight,dry-run -- see below.
#
# 🔴 WHY THE CUT'S OWN JOBS ARE EXCLUDED, added 2026-09-19 after a CIRCULAR
# REFUSAL that no amount of fixing the other reds could ever clear.
#   the cut's preflight fails
#   -> this aggregate sees preflight=failure and goes RED on that commit
#   -> the cut's own verify_tagged_commit_is_green sees a red check-run and
#      refuses to cut the commit
#   -> which is the preflight failing
# The cut gate ALREADY excludes cut,preflight,dry-run by name and printed
# "excluded 4 of the cut's own job(s)", correctly. It could not see them
# leaking back in through a DIFFERENTLY-NAMED AGGREGATE. An exclusion by name
# does not survive being re-reported under another name.
#
# THIS IS NOT A WEAKENING, and the measurement is the reason rather than the
# assurance: cut.yml triggers ONLY on `push: tags: v1.0.*` and
# `workflow_dispatch`, never on pull_request. Measured on an ordinary PR head:
# ZERO check-runs named cut, preflight or dry-run, against a control of 46
# total check-runs on the same commit. So on every normal pull request this
# changes NOTHING because there is nothing to exclude. It bites only on a
# frozen cut branch that also carries a PR for its CI surface, which is
# precisely where the loop was.
#
# The cut's jobs remain graded, by the cut's own gate and by the run itself.
# What stops is a PR-level aggregate grading a workflow that is not part of
# the pull request, and then feeding that verdict back into it.
#   OSTLER_GATE_FLOOR                override the computed floor (testing only;
#                                    the real run computes it from the tree)
#   OSTLER_GATE_WORKFLOWS_DIR        default: <repo-root>/.github/workflows
#   OSTLER_GATE_SELF_WORKFLOW_FILE   basename excluded from the floor scan.
#                                    Default: ci-required-gate.yml
#   OSTLER_GATE_POLL_INTERVAL_SECONDS  default 20
#   OSTLER_GATE_MAX_WAIT_SECONDS        default 2700 (45 min). An IDLE window,
#                                    not a total: the clock restarts whenever
#                                    a check starts or finishes, and holds
#                                    while any check is running. A check that
#                                    only sits queued restarts nothing, so a
#                                    lane with nothing running and nothing
#                                    moving still ends in CANNOT-RUN. Added after
#                                    probe-tests queued ~17 min then ran ~31
#                                    min and a total budget gave up (CANNOT-RUN)
#                                    on every PR that triggers it (PR #2799,
#                                    twice). A queue wait is not a hang.
#   OSTLER_GATE_HARD_CAP_SECONDS        default 4500 (75 min). Absolute ceiling
#                                    from the first poll, so a check that
#                                    flaps state forever still ends in
#                                    CANNOT-RUN. The job's timeout-minutes
#                                    (85) must stay above this so the script
#                                    reports CANNOT-RUN rather than being
#                                    killed mid-poll and reporting nothing.
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
# resolve_expected -- WHICH check-runs this pull request is guaranteed to get,
# by workflow file AND name, computed from the tree. Prints one JSON object:
#   {"floor": N, "workflows": {".github/workflows/x.yml":
#                               {"names": [...], "unnamed": k}}}
#
# 🔴 WHY THIS REPLACED A COUNT OF FILES (CM051, 2026-10-17)
#
# The floor used to be "how many workflow files are unconditional", compared
# with the TOTAL of every check-run on the commit. Path-filtered checks are in
# that total too -- 50 to 190 of them on a real PR against a floor of 34 -- so a
# required check that never reported was paid for by any filtered check that
# did. A pull request that broke an unconditional workflow at STARTUP (zero
# jobs, zero check-runs) left the total comfortably above the floor and this
# gate GREEN. That is the very hole the floor existed to close.
#
# So the floor is now the EXPECTED check-runs, and each one is required by
# identity (workflow file + check name), not merely counted. A check-run that
# is expected and never reports is RED, and the message names it.
#
# WHAT COUNTS AS EXPECTED, and why each rule errs towards expecting LESS:
#   * a `pull_request:` trigger with no paths/paths-ignore filter;
#   * whose `branches`/`branches-ignore` admit OSTLER_GATE_BASE_REF -- with a
#     branch filter and no known base ref, the workflow is NOT expected;
#   * whose `types` include OSTLER_GATE_EVENT_ACTION (default types: opened,
#     synchronize, reopened) -- with `types` and no known action, NOT expected;
#   * every job, because a job skipped by its own `if:` or by a failed
#     `needs:` still reports a check-run (conclusion skipped);
#   * one name per matrix leg, "<name> (<v1>, <v2>)", when the job name and
#     the matrix are literal; otherwise the leg counts towards `unnamed`, which
#     requires that many check-runs from that file without naming them;
#   * a reusable-workflow call (`uses:` job) counts as ONE unnamed check-run:
#     its inner names are not knowable from this tree.
# Expecting too little can only make this gate weaker; expecting a check that
# GitHub would never create would make it unpassable. Every rule above picks
# the first failure mode, and the self-test pins each.
# ---------------------------------------------------------------------------
resolve_expected() {
    local wf_dir self
    wf_dir="${OSTLER_GATE_WORKFLOWS_DIR:-$REPO_ROOT/.github/workflows}"
    self="${OSTLER_GATE_SELF_WORKFLOW_FILE:-ci-required-gate.yml}"
    if [ ! -d "$wf_dir" ]; then
        echo "CANNOT-RUN-FLOOR"
        return 2
    fi
    WORKFLOWS_DIR="$wf_dir" SELF_WORKFLOW_FILE="$self" python3 - <<'PY'
import glob, itertools, json, os, re, sys
try:
    import yaml
except Exception:
    print("CANNOT-RUN-FLOOR")
    sys.exit(2)

wf_dir = os.environ["WORKFLOWS_DIR"]
self_file = os.environ["SELF_WORKFLOW_FILE"]
base_ref = os.environ.get("OSTLER_GATE_BASE_REF", "")
action = os.environ.get("OSTLER_GATE_EVENT_ACTION", "")
DEFAULT_TYPES = ["opened", "synchronize", "reopened"]


def glob_rx(pat):
    out, i = [], 0
    while i < len(pat):
        if pat.startswith("**", i):
            out.append(".*"); i += 2
        elif pat[i] == "*":
            out.append("[^/]*"); i += 1
        elif pat[i] == "?":
            out.append("[^/]"); i += 1
        else:
            out.append(re.escape(pat[i])); i += 1
    return re.compile("".join(out) + r"\Z")


def as_list(v):
    if v is None:
        return []
    return v if isinstance(v, list) else [v]


def admits(pr):
    """Does this pull_request trigger certainly fire for THIS pull request?"""
    if pr.get("paths") or pr.get("paths-ignore"):
        return False
    if "branches" in pr or "branches-ignore" in pr:
        if not base_ref:
            return False
        if "branches" in pr:
            pats = [str(b) for b in as_list(pr["branches"])]
            if any(p.startswith("!") for p in pats):
                return False            # order-dependent negation: do not guess
            if not any(glob_rx(p).match(base_ref) for p in pats):
                return False
        if "branches-ignore" in pr:
            if any(glob_rx(str(p)).match(base_ref)
                   for p in as_list(pr["branches-ignore"])):
                return False
    if "types" in pr:
        if not action or action not in [str(t) for t in as_list(pr["types"])]:
            return False
    elif action and action not in DEFAULT_TYPES:
        return False
    return True


def legs(job):
    """[(suffix or None)] per matrix leg; None = cannot name it."""
    strat = job.get("strategy") or {}
    m = strat.get("matrix")
    if m is None:
        return [""]
    if not isinstance(m, dict) or "include" in m or "exclude" in m:
        return [None]
    keys = list(m)
    vals = [m[k] for k in keys]
    if not all(isinstance(v, list) and v for v in vals):
        return [None]
    out = []
    for combo in itertools.product(*vals):
        if not all(isinstance(c, (str, int, float)) and not isinstance(c, bool)
                   for c in combo):
            out.append(None)
            continue
        out.append(" (" + ", ".join(str(c) for c in combo) + ")")
    return out


workflows, floor = {}, 0
for path in sorted(glob.glob(os.path.join(wf_dir, "*.yml")) + glob.glob(os.path.join(wf_dir, "*.yaml"))):
    base = os.path.basename(path)
    if base == self_file:
        continue
    try:
        with open(path) as fh:
            doc = yaml.safe_load(fh)
    except Exception:
        # A file that cannot be parsed cannot be proven to fire. Expecting
        # nothing of it is the weaker direction, never the unpassable one.
        continue
    if not isinstance(doc, dict):
        continue
    on = doc["on"] if "on" in doc else doc.get(True)
    if isinstance(on, str):
        on = {on: None}
    elif isinstance(on, list):
        on = {k: None for k in on}
    if not isinstance(on, dict) or "pull_request" not in on:
        continue
    pr = on.get("pull_request") or {}
    if not isinstance(pr, dict) or not admits(pr):
        continue
    names, unnamed = [], 0
    for jid, job in (doc.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        if "uses" in job:
            unnamed += 1
            continue
        jname = str(job.get("name", jid))
        for suffix in legs(job):
            if suffix is None or "${{" in jname:
                unnamed += 1
            else:
                names.append(jname + suffix)
    if names or unnamed:
        workflows[".github/workflows/" + base] = {"names": names, "unnamed": unnamed}
        floor += len(names) + unnamed
print(json.dumps({"floor": floor, "workflows": workflows}, sort_keys=True))
PY
}

# ---------------------------------------------------------------------------
# resolve_floor -- the anti-vacuity floor: the number of EXPECTED check-runs
# (see resolve_expected), unless OSTLER_GATE_FLOOR overrides it (self-test
# only; a live run must never set this, or the floor stops meaning anything).
# ---------------------------------------------------------------------------
resolve_floor() {
    if [ -n "${OSTLER_GATE_FLOOR:-}" ]; then
        echo "${OSTLER_GATE_FLOOR}"
        return 0
    fi
    local exp
    exp="$(resolve_expected)" || { echo "CANNOT-RUN-FLOOR"; return 2; }
    [ "$exp" = "CANNOT-RUN-FLOOR" ] && { echo "$exp"; return 2; }
    python3 -c 'import json,sys; print(json.loads(sys.argv[1])["floor"])' "$exp" \
        || { echo "CANNOT-RUN-FLOOR"; return 2; }
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
# fetch_runs <sha> <repo> <outfile> <attempt> -- the workflow RUNS at this
# commit, which is the only place a check-run's workflow FILE can be read
# (a check-run carries its run id in its URL, never its path). Needs
# `actions: read`. Same fixture and failure contract as fetch_check_runs.
# In fixture mode with no runs fixture it writes [] -- every check-run then
# keys on its name alone, exactly as before, so older fixtures still mean
# what they meant.
# ---------------------------------------------------------------------------
fetch_runs() {
    local sha="$1" repo="$2" out="$3" attempt="$4"
    if [ -n "${OSTLER_RUNS_JSON_SEQUENCE:-}" ]; then
        local old_ifs="$IFS" seq idx n
        IFS=':' read -r -a seq <<< "$OSTLER_RUNS_JSON_SEQUENCE"
        IFS="$old_ifs"
        n=${#seq[@]}; idx=$((attempt - 1))
        [ "$idx" -ge "$n" ] && idx=$((n - 1))
        cp "${seq[$idx]}" "$out" 2>/dev/null || return 1
        return 0
    fi
    if [ -n "${OSTLER_RUNS_JSON:-}" ]; then
        cp "$OSTLER_RUNS_JSON" "$out" 2>/dev/null || return 1
        return 0
    fi
    if [ -n "${OSTLER_CHECKRUNS_JSON:-}${OSTLER_CHECKRUNS_JSON_SEQUENCE:-}" ]; then
        printf '[]' > "$out"
        return 0
    fi
    if ! gh api "repos/$repo/actions/runs?head_sha=$sha&per_page=100" --paginate --slurp > "$out" 2>"$out.err"; then
        [ -s "$out.err" ] && dim "  gh said (runs): $(tr '\n' ' ' < "$out.err" | cut -c1-300)"
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
    python3 - "$f" "${2:-}" <<'PY'
import json, os, sys

BLOCKING = {"failure", "cancelled", "timed_out", "action_required", "stale"}
GOOD = {"success", "skipped", "neutral"}

f = sys.argv[1]
runs_file = sys.argv[2] if len(sys.argv) > 2 else ""
own = {n.strip() for n in os.environ.get("OSTLER_GATE_OWN_JOB_NAMES", "CI Required Gate,cut,preflight,dry-run").split(",") if n.strip()}
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

# WHICH WORKFLOW FILE each check-run came from. A check-run's URL carries its
# Actions run id; the runs payload maps that id to the file. A check-run whose
# run is unknown (a non-Actions app, or a fixture with no runs) keys on "".
import re as _re
run_path, run_rows = {}, []
try:
    rdoc = json.load(open(runs_file)) if runs_file else []
except Exception as exc:
    print(f"PENDING\t-\t0\t0\t0\tunreadable workflow-runs payload this round: {exc}")
    raise SystemExit(0)
for page in (rdoc if isinstance(rdoc, list) else [rdoc]):
    items = page.get("workflow_runs", []) if isinstance(page, dict) else []
    for w in items:
        run_rows.append(w)
        run_path[str(w.get("id"))] = w.get("path") or ""


def path_of(r):
    m = _re.search(r"/actions/runs/(\d+)/job/", str(r.get("details_url") or r.get("html_url") or ""))
    return run_path.get(m.group(1), "") if m else ""

# ONE CHECK NAME CAN HAVE MULTIPLE ATTEMPTS ON THE SAME COMMIT. A concurrency
# rule (this repo uses `cancel-in-progress` almost everywhere) cancels an
# in-flight run when the same PR is pushed to again, or edited, or anything
# else refires the workflow -- enforce-ledger-write.yml alone listens for
# `edited` deliberately. Each attempt gets its OWN check-run object, and a
# check-run is immutable and permanent: the cancelled one from attempt 1 does
# not disappear when attempt 2 succeeds.
#
# Measured 2026-09-12, CM051 PR #1937, head 3af2269f: `no-invisible-workflows`
# and `ledger-pr` each had TWO check-run entries on the identical head SHA --
# an earlier one, cancelled, and a later one, success -- and evaluating the
# raw list treated the dead cancellation as a live failure. Under real branch
# protection that PR could never have gone green no matter how many times it
# was re-run, because the cancelled attempt is permanent evidence that stays
# attached to the commit forever: pushing twice is routine here, so this was
# "protection nobody can satisfy", worse than the missing protection this
# gate exists to replace.
#
# FOR EACH NAME, ONLY THE LATEST ATTEMPT DECIDES. A cancellation superseded by
# a later success for the SAME name is not a failure; a cancellation that IS
# the latest attempt for its name still is one, because nobody re-ran it and
# nothing verified that check.
#
# Reduced by `id`, not by list order and not by `started_at`/`completed_at`:
#   * list order is a pagination artefact. Nothing in the endpoint's contract
#     promises attempts arrive oldest-first, so trusting it is trusting an
#     accident.
#   * `completed_at` is null on anything not yet finished. Comparing a
#     completed OLD attempt against a still-RUNNING new one by this field
#     would silently keep the old, finished one and hide the pending
#     replacement -- exactly backwards.
#   * `started_at` IS present on every attempt regardless of status (verified
#     against a live queued check-run: it already carries one), but it has
#     one-second resolution, so two attempts created in the same second tie.
#   * `id` is a GitHub-assigned integer, strictly increasing in creation
#     order, present on every check run in every status, and it cannot tie.
#     On the #1937 incident above the cancelled attempt's id (103562866141)
#     is lower than the successful attempt's id (103562901507) for BOTH
#     duplicated names, consistent with creation order, and it stays
#     comparable even while the newer attempt is still queued or running.
#
# 🔴 KEYED BY (WORKFLOW FILE, NAME), NOT BY NAME (CM051, 2026-10-17). Keyed by
# name alone, two DIFFERENT workflows' jobs that share a name were treated as
# two attempts of one check, and the later one silently decided both. Measured
# on real PRs that day: `gate` is a job in four workflows, `predicate-self-test`
# in four, `self-test` in three; PR #2941's 178 check-runs collapsed to 167, so
# eleven were never graded on their own, and a FAILED `gate` from one workflow
# was masked by any later passing `gate` from another. Attempts of the SAME
# check still collapse to the latest, which is what the #1937 fix was for.
latest_by_name = {}
collapsed = 0
for r in runs:
    key = (path_of(r), r.get("name"))
    prior = latest_by_name.get(key)
    if prior is None:
        latest_by_name[key] = r
        continue
    collapsed += 1
    if (r.get("id") or 0) > (prior.get("id") or 0):
        latest_by_name[key] = r
runs = list(latest_by_name.values())

# The anti-vacuity floor counts DISTINCT check NAMES, never raw check-run
# rows. `total` here is computed AFTER the collapse above, so it already is
# that count -- computing it from the pre-collapse list would let re-triggered
# attempts inflate the denominator and quietly loosen the floor the more often
# a PR happens to be pushed to or edited.
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
    # TWO DIFFERENT PROBLEMS USED TO PRINT IDENTICALLY, and the refusal this
    # produces is read by a person deciding whether their PR is broken.
    #
    #   queued      the check has NO RUNNER YET. Nothing has executed. This is
    #               lane starvation and it is not a fact about this PR at all.
    #               On 2026-09-16 six of seven reds across all open PRs were
    #               this, and were read as six defects.
    #   in_progress the check STARTED and has not finished. That one can be a
    #               slow or hung job, and it IS a fact about this PR.
    #
    # Same word ("pending") for both meant the only way to tell them apart was
    # to go and look at the runner queue by hand. Counting them separately
    # costs nothing and answers the question the reader actually has.
    queued = [r for r in pending if (r.get("status") or "") == "queued"]
    started = [r for r in pending if (r.get("status") or "") != "queued"]
    names = ", ".join(sorted(r.get("name") or "?" for r in pending)[:8])
    more = "" if len(pending) <= 8 else f" (+{len(pending) - 8} more)"
    if queued and not started:
        shape = (f"ALL {len(queued)} ARE STILL QUEUED WITH NO RUNNER -- this is "
                 f"lane starvation, not a defect in this PR")
    elif started and not queued:
        shape = f"all {len(started)} have STARTED and not finished"
    else:
        shape = (f"{len(queued)} queued with no runner, "
                 f"{len(started)} started and unfinished")
    print(f"PENDING\t-\t{total}\t{len(completed)}\t{excluded}\t"
          f"{len(pending)} of {total} not yet completed [{shape}]: {names}{more}")
    raise SystemExit(0)

# Every non-self check-run has status == completed from here on.
#
# EVERY EXPECTED CHECK MUST HAVE REPORTED. See resolve_expected for what is
# expected and why. A missing one is decided by its workflow's RUN:
#   run still queued/in progress   -> PENDING (its jobs may not exist yet)
#   run completed                  -> RED: it ran and that check never
#                                     reported (a startup failure is this:
#                                     conclusion failure, zero jobs)
#   no run at all, inside grace    -> PENDING
#   no run at all, after grace     -> RED: the workflow never ran here
expected = {}
exp_file = os.environ.get("OSTLER_GATE_EXPECTED_FILE", "")
if exp_file:
    try:
        expected = json.load(open(exp_file)).get("workflows", {})
    except Exception as exc:
        print(f"DONE\tCANNOT-RUN\t{total}\t{len(completed)}\t{excluded}\t"
              f"the expected-check list is unreadable ({exc}) -- refusing to guess it")
        raise SystemExit(0)
present = {}
for r in runs:
    present.setdefault(path_of(r), set()).add(r.get("name"))
latest_run = {}
for w in run_rows:
    p = w.get("path") or ""
    if p not in latest_run or (w.get("id") or 0) > (latest_run[p].get("id") or 0):
        latest_run[p] = w
try:
    elapsed = int(os.environ.get("OSTLER_GATE_ELAPSED_SECONDS", "0"))
    grace = int(os.environ.get("OSTLER_GATE_MISSING_GRACE_SECONDS", "600"))
except ValueError:
    elapsed, grace = 0, 600
waiting, missing = [], []
for p, want in sorted(expected.items()):
    got = present.get(p, set())
    gone = [n for n in want.get("names", []) if n not in got]
    short = (len(want.get("names", [])) + int(want.get("unnamed", 0))) - len(got)
    if not gone and short <= 0:
        continue
    what = ", ".join(gone) if gone else f"{short} unnamed check-run(s)"
    w = latest_run.get(p)
    if w is not None and w.get("status") != "completed":
        waiting.append(f"{p} (run {w.get('status')}): {what}")
    elif w is not None:
        missing.append(f"{p} ran (conclusion {w.get('conclusion')}) but never reported: {what}")
    elif elapsed < grace:
        waiting.append(f"{p} (no run yet, {elapsed}s of {grace}s grace): {what}")
    else:
        missing.append(f"{p} has NO workflow run at this commit after {elapsed}s: {what}")
if missing:
    print(f"DONE\tRED\t{total}\t{len(completed)}\t{excluded}\t"
          f"{len(missing)} REQUIRED workflow(s) never reported their check(s): "
          + "; ".join(missing))
    raise SystemExit(0)
if waiting:
    print(f"PENDING\t-\t{total}\t{len(completed)}\t{excluded}\t"
          f"waiting on {len(waiting)} required workflow(s): " + "; ".join(waiting))
    raise SystemExit(0)

if total < floor:
    print(f"DONE\tCANNOT-RUN\t{total}\t{len(completed)}\t{excluded}\t"
          f"only {total} non-self check-run(s) ever concluded; the tree's own "
          f"expected check-run count is {floor}. The enumeration itself is "
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
collapsed_note = f"; {collapsed} superseded attempt(s) collapsed" if collapsed else ""
print(f"DONE\tGREEN\t{total}\t{len(completed)}\t{excluded}\tall clean ({skip_note}{collapsed_note})")
PY
}

# ---------------------------------------------------------------------------
# poll_and_decide <sha> <repo> -- the loop. Waits properly; never samples once.
# ---------------------------------------------------------------------------
poll_and_decide() {
    local sha="$1" repo="$2"
    local own interval max_wait floor
    own="${OSTLER_GATE_OWN_JOB_NAMES:-CI Required Gate,cut,preflight,dry-run}"
    interval="${OSTLER_GATE_POLL_INTERVAL_SECONDS:-20}"
    max_wait="${OSTLER_GATE_MAX_WAIT_SECONDS:-2700}"
    hard_cap="${OSTLER_GATE_HARD_CAP_SECONDS:-4500}"

    floor="$(resolve_floor)"
    if [ "$floor" = "CANNOT-RUN-FLOOR" ] || ! [[ "$floor" =~ ^[0-9]+$ ]]; then
        red "CANNOT-RUN: could not compute the anti-vacuity floor (no PyYAML, or no workflows directory)."
        dim "Nothing was measured. This is not a pass."
        return 2
    fi

    # The expected checks, by identity. A self-test that overrides the floor
    # without supplying an expected list is testing the count alone, and gets
    # no identity requirement -- that is how the older fixtures keep meaning
    # what they meant. A LIVE run always computes it, and cannot skip it.
    local exp_file
    exp_file="$(mktemp)"
    if [ -n "${OSTLER_GATE_EXPECTED_JSON:-}" ]; then
        cp "$OSTLER_GATE_EXPECTED_JSON" "$exp_file" || { red "CANNOT-RUN: unreadable OSTLER_GATE_EXPECTED_JSON"; return 2; }
    elif [ -n "${OSTLER_GATE_FLOOR:-}" ]; then
        printf '{"floor": 0, "workflows": {}}' > "$exp_file"
    else
        resolve_expected > "$exp_file" 2>/dev/null
        if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))["workflows"]' "$exp_file" 2>/dev/null; then
            red "CANNOT-RUN: could not compute the expected check-runs from the tree."
            dim "Nothing was measured. This is not a pass."
            rm -f "$exp_file"
            return 2
        fi
    fi
    local n_expected
    n_expected="$(python3 -c 'import json,sys; w=json.load(open(sys.argv[1]))["workflows"]; print(sum(len(v["names"])+v["unnamed"] for v in w.values()))' "$exp_file")"

    dim "polling check-runs for ${sha:0:12} in $repo -- floor=${floor}, ${n_expected} check-run(s) required by identity (base ${OSTLER_GATE_BASE_REF:-unknown}, action ${OSTLER_GATE_EVENT_ACTION:-unknown}), excluding: ${own}"

    local start now elapsed attempt=0 tmp state subverdict total completed excluded detail fetch_rc
    local last_progress sig last_sig="" idle probe running
    start=$(date +%s)
    last_progress=$start
    while true; do
        attempt=$((attempt + 1))
        tmp="$(mktemp)"
        fetch_check_runs "$sha" "$repo" "$tmp" "$attempt"
        fetch_rc=$?
        if [ "$fetch_rc" -eq 0 ]; then
            fetch_runs "$sha" "$repo" "$tmp.runs" "$attempt"
            fetch_rc=$?
        fi
        now=$(date +%s)
        elapsed=$((now - start))

        if [ "$fetch_rc" -ne 0 ]; then
            state="PENDING"; subverdict="-"; total=0; completed=0; excluded=0
            detail="could not read check-runs this round"
        else
            IFS=$'\t' read -r state subverdict total completed excluded detail < <(
                OSTLER_GATE_FLOOR_RESOLVED="$floor" OSTLER_GATE_OWN_JOB_NAMES="$own" \
                OSTLER_GATE_EXPECTED_FILE="$exp_file" OSTLER_GATE_ELAPSED_SECONDS="$elapsed" \
                evaluate "$tmp" "$tmp.runs")
        fi
        # PROGRESS restarts the idle window. It is either of:
        #   * a check STARTED or FINISHED since the last good read: the
        #     (name,status) set of the checks that are no longer queued
        #     changed. A check merely appearing as, or going back to, queued
        #     resets nothing: a queue is not progress.
        #   * a check is RUNNING right now. A 30-minute block is working, not
        #     hung; a check that runs forever is still ended by the hard cap.
        # The gate's own job(s) are left out of both, or the gate, which is
        # always running while it polls, would count as its own progress.
        #
        # The live payload is `gh api --paginate --slurp`: an ARRAY of pages,
        # read here exactly as evaluate() reads it. Until 2026-10-18 this read
        # `.check_runs` off the array, which raised, was swallowed, and left
        # an empty signature that is never progress -- so on every real PR
        # the idle window never restarted and the gate gave up 45 minutes
        # after its first poll however much was happening (#2959, #2962,
        # #2963, #2973: "2704s with no check changing state" while legs were
        # starting and finishing). The fixtures were single objects, so the
        # self-test never saw it.
        #
        # An unreadable payload prints nothing and is never progress, so a
        # dead API cannot extend the window.
        if [ "$fetch_rc" -eq 0 ]; then
            probe="$(OSTLER_GATE_OWN_JOB_NAMES="$own" python3 -c '
import json,os,sys
own = {n.strip() for n in os.environ.get("OSTLER_GATE_OWN_JOB_NAMES", "").split(",") if n.strip()}
try:
    doc = json.load(open(sys.argv[1]))
    if isinstance(doc, list):
        runs = []
        for page in doc:
            runs.extend((page.get("check_runs") or []) if isinstance(page, dict) else [page])
    else:
        runs = doc.get("check_runs") or []
    runs = [r for r in runs if isinstance(r, dict) and r.get("name") not in own]
    running = sum(1 for r in runs if r.get("status") == "in_progress")
    sig = "|".join(sorted("%s:%s" % (r.get("name"), r.get("status"))
                          for r in runs if r.get("status") != "queued"))
    print("%d\t%s" % (running, sig))
except Exception:
    pass' "$tmp" 2>/dev/null)"
            if [ -n "$probe" ]; then
                running="${probe%%$'\t'*}"
                sig="${probe#*$'\t'}"
                if [ "$sig" != "$last_sig" ] || [ "$running" -gt 0 ]; then
                    last_sig="$sig"; last_progress=$now
                fi
            fi
        fi
        idle=$((now - last_progress))
        rm -f "$tmp" "$tmp.err" "$tmp.runs" 2>/dev/null

        dim "  [poll ${attempt}, ${elapsed}s elapsed] EXAMINED ${total} non-self check-run(s) (${completed} completed, ${excluded} excluded as self) -- ${detail}"

        if [ "$state" = "DONE" ]; then
            break
        fi

        if [ "$idle" -ge "$max_wait" ]; then
            state="DONE"; subverdict="CANNOT-RUN"
            detail="timed out after ${elapsed}s (${idle}s with no check changing state) still waiting (last look: ${detail})"
            break
        fi
        if [ "$elapsed" -ge "$hard_cap" ]; then
            state="DONE"; subverdict="CANNOT-RUN"
            detail="timed out at the ${hard_cap}s hard cap after ${elapsed}s, still waiting (last look: ${detail})"
            break
        fi

        sleep "$interval"
    done

    rm -f "$exp_file"
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

    # 1043: queued (no runner yet) vs in_progress (started, unfinished).
    mk allqueued3 '{"check_runs":[
        {"name":"a","status":"completed","conclusion":"success"},
        {"name":"b","status":"completed","conclusion":"success"},
        {"name":"slow-one","status":"queued"}]}'

    mk allstarted3 '{"check_runs":[
        {"name":"a","status":"completed","conclusion":"success"},
        {"name":"b","status":"completed","conclusion":"success"},
        {"name":"slow-one","status":"in_progress"}]}'

    mk mixedpending4 '{"check_runs":[
        {"name":"a","status":"completed","conclusion":"success"},
        {"name":"b","status":"completed","conclusion":"success"},
        {"name":"queued-one","status":"queued"},
        {"name":"running-one","status":"in_progress"}]}'

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

    # THE CIRCULAR CASE, added 2026-09-19. Only the CUT's own preflight failed.
    # Before the cut jobs were excluded here, this aggregate went RED on it, the
    # cut's own green-commit gate then saw a red check-run and refused, and that
    # refusal WAS the preflight failure. A loop no other fix could break.
    printf '%s' '{"check_runs":[
        {"name":"preflight","status":"completed","conclusion":"failure"},
        {"name":"cut","status":"completed","conclusion":"skipped"},
        {"name":"dry-run","status":"completed","conclusion":"skipped"},
        {"name":"gates","status":"completed","conclusion":"success"},
        {"name":"shell-macos","status":"completed","conclusion":"success"}]}' > "$TMP/cutonly.json"
    # ITS CONTROL: a NON-cut job failing must STILL refuse. Without this arm the
    # exclusion could be widened to everything and the suite would stay green.
    printf '%s' '{"check_runs":[
        {"name":"preflight","status":"completed","conclusion":"failure"},
        {"name":"gates","status":"completed","conclusion":"failure"},
        {"name":"shell-macos","status":"completed","conclusion":"success"}]}' > "$TMP/cutplusreal.json"

    # A subshell can't just prefix env vars before a function call the way it
    # can before a binary, so wrap it.
    run_case2() {  # run_case2 <want-rc> <label> <fixture-file> [floor, default 3]
        local want="$1" label="$2" file="$3" floor="${4:-3}"
        (
            OSTLER_CHECKRUNS_JSON="$TMP/$file.json" \
            OSTLER_GATE_FLOOR="$floor" \
            OSTLER_GATE_MAX_WAIT_SECONDS=1 \
            OSTLER_GATE_HARD_CAP_SECONDS=3 \
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
    run_case2 0 "CIRCULAR: only the cut's OWN preflight failed -> GREEN, the loop is broken" cutonly 2
    run_case2 1 "ITS CONTROL: a non-cut job failing alongside it STILL refuses" cutplusreal 2
    run_case2 1 "an unrecognised conclusion refuses -- cannot establish it was a legitimate skip" unknown3

    echo "=== guard: aggregate must not report success having enumerated nothing ==="
    run_case2 2 "ZERO check-runs is CANNOT-RUN even after the wait window (this is the guard: GREEN here would be the bug)" empty
    run_case2 2 "1-of-floor-3 is CANNOT-RUN -- below the anti-vacuity floor" belowfloor
    run_case2 2 "an unparseable payload never resolves and times out CANNOT-RUN" garbage

    echo "=== self-exclusion, by name only ==="
    run_case2 0 "the gate's OWN cancelled check-run does not refuse the commit" ownfail3
    run_case2 1 "CONTROL: a merely SIMILAR name ('ci required gate' lowercase) still refuses" lookalike3

    # 1043: the refusal is read by a PERSON deciding whether their PR is
    # broken. Runner starvation and a stuck job both used to print "pending".
    # These arms assert the two produce DIFFERENT text, and each carries the
    # negative half -- the other shape must be ABSENT -- because a message
    # that contains both phrases distinguishes nothing.
    run_msg() {
        local want="$1" mustnot="$2" label="$3" file="$4" floor="${5:-3}"
        local out
        out=$(
            OSTLER_CHECKRUNS_JSON="$TMP/$file.json" \
            OSTLER_GATE_FLOOR="$floor" \
            OSTLER_GATE_MAX_WAIT_SECONDS=1 \
            OSTLER_GATE_HARD_CAP_SECONDS=3 \
            OSTLER_GATE_POLL_INTERVAL_SECONDS=1 \
            poll_and_decide deadbeefdeadbeef owner/repo 2>&1
        )
        if printf '%s' "$out" | /usr/bin/grep -q "$want" \
           && ! printf '%s' "$out" | /usr/bin/grep -q "$mustnot"; then
            note "PASS  $label"
        else
            note "FAIL  $label"
            note "      wanted /$want/ present AND /$mustnot/ absent"
            fail=1
        fi
    }

    echo "=== 1043: starvation and a stuck check must not print identically ==="
    run_msg "lane starvation" "started and unfinished" \
        "all-queued says LANE STARVATION and does not claim anything started" allqueued3
    run_msg "have STARTED and not finished" "lane starvation" \
        "CONTROL: all-in_progress says STARTED and does NOT blame the lane" allstarted3
    run_msg "1 queued with no runner, 1 started and unfinished" "lane starvation" \
        "a mixed queue reports both counts and claims neither shape" mixedpending4 4

    echo "=== it waits; it does not sample once ==="
    run_case2 2 "one run still in_progress that never settles -> CANNOT-RUN at the hard cap, not GREEN" onepending3
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

    echo "=== the wait window restarts on progress (probe-tests queued 17m, ran 31m) ==="
    # Same polls, state advances every 2 polls: total elapsed (~5s) exceeds the
    # 3s idle window, no single quiet stretch does. Must PASS.
    (
        OSTLER_CHECKRUNS_JSON_SEQUENCE="$TMP/allqueued3.json:$TMP/allqueued3.json:$TMP/allstarted3.json:$TMP/allstarted3.json:$TMP/green3.json" \
        OSTLER_GATE_FLOOR=3 OSTLER_GATE_MAX_WAIT_SECONDS=3 OSTLER_GATE_POLL_INTERVAL_SECONDS=1 \
        poll_and_decide deadbeefdeadbeef owner/repo
    ) >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then note "PASS  rc=$rc  late-start check finishing inside a restarted window passes"; else note "FAIL  rc=$rc want=0  late-start check"; fail=1; fi

    echo "=== a running check is progress; a queued one restarts nothing (live payload shape) ==="
    # Every fixture below is in the LIVE shape, `gh api --paginate --slurp`:
    # an array of pages. Until 2026-10-18 the progress signature could not
    # read that shape, so on real PRs the window never restarted at all.
    # Scale: one poll is 5 minutes, so the 45-minute idle window is 9 s.
    mk s_queued3 '[{"total_count":3,"check_runs":[
        {"name":"a","status":"completed","conclusion":"success"},
        {"name":"b","status":"completed","conclusion":"success"},
        {"name":"slow-one","status":"queued"}]}]'
    mk s_running3 '[{"total_count":3,"check_runs":[
        {"name":"a","status":"completed","conclusion":"success"},
        {"name":"b","status":"completed","conclusion":"success"},
        {"name":"slow-one","status":"in_progress"}]}]'
    mk s_green3 '[{"total_count":3,"check_runs":[
        {"name":"a","status":"completed","conclusion":"success"},
        {"name":"b","status":"completed","conclusion":"success"},
        {"name":"slow-one","status":"completed","conclusion":"success"}]}]'
    mk s_queued4 '[{"total_count":4,"check_runs":[
        {"name":"a","status":"completed","conclusion":"success"},
        {"name":"b","status":"completed","conclusion":"success"},
        {"name":"slow-one","status":"queued"},
        {"name":"late-one","status":"queued"}]}]'
    mk s_queued3_self_running '[{"total_count":4,"check_runs":[
        {"name":"a","status":"completed","conclusion":"success"},
        {"name":"b","status":"completed","conclusion":"success"},
        {"name":"slow-one","status":"queued"},
        {"name":"CI Required Gate","status":"in_progress"}]}]'
    seq_of() {  # seq_of <fixture> <n> -> n colon-joined copies
        local out="" i=0
        while [ "$i" -lt "$2" ]; do out="${out:+$out:}$TMP/$1.json"; i=$((i + 1)); done
        printf '%s' "$out"
    }
    gate_seq() {  # gate_seq <sequence> <max-wait> <hard-cap> -> sets rc, out
        out="$(
            OSTLER_CHECKRUNS_JSON_SEQUENCE="$1" \
            OSTLER_GATE_FLOOR=3 OSTLER_GATE_MAX_WAIT_SECONDS="$2" OSTLER_GATE_HARD_CAP_SECONDS="$3" \
            OSTLER_GATE_POLL_INTERVAL_SECONDS=1 poll_and_decide deadbeefdeadbeef owner/repo 2>&1
        )"
        rc=$?
    }
    # THE 2973 SHAPE: a 15-minute queue, then a block running for 30 minutes
    # and seen still running on the next poll, with no other state change,
    # then green. 50 minutes from the first poll: past the 45-minute window,
    # and nothing was hung. Must PASS. (The pre-fix gate timed this out.)
    gate_seq "$(seq_of s_queued3 3):$(seq_of s_running3 7):$TMP/s_green3.json" 9 60
    if [ "$rc" -eq 0 ]; then note "PASS  rc=$rc  a 15-min queue then a 30-min running block (50 min from the first poll) does not time out"
    else note "FAIL  rc=$rc want=0  a 15-min queue then a 30-min running block timed out"; fail=1; fi
    # A running check holds the window by itself: running for twice the idle
    # window with NO state change, then green. Must PASS.
    gate_seq "$(seq_of s_running3 6):$TMP/s_green3.json" 3 60
    if [ "$rc" -eq 0 ]; then note "PASS  rc=$rc  a check running past the idle window, with no state change, is still waited for"
    else note "FAIL  rc=$rc want=0  a running check was treated as idle"; fail=1; fi
    # CONTROL: genuinely stuck -- nothing running, no state change at all --
    # is CANNOT-RUN, and by the IDLE window, not the hard cap.
    gate_seq "$TMP/s_queued3.json" 3 60
    if [ "$rc" -eq 2 ] && /usr/bin/grep -q "with no check changing state" <<< "$out" && ! /usr/bin/grep -q "hard cap" <<< "$out"; then
        note "PASS  rc=$rc  CONTROL: nothing running and nothing moving is CANNOT-RUN by the idle window"
    else note "FAIL  rc=$rc want=2  a genuinely stuck queue was not ended by the idle window"; fail=1; fi
    # A queued check restarts nothing: a second check APPEARING as queued,
    # again and again, for longer than the hard cap. Counted as progress it
    # would hold the window open until the cap; it must end by the idle
    # window instead.
    flap=""; i=0
    while [ "$i" -lt 12 ]; do flap="${flap:+$flap:}$TMP/s_queued3.json:$TMP/s_queued4.json"; i=$((i + 1)); done
    gate_seq "$flap" 3 20
    if [ "$rc" -eq 2 ] && /usr/bin/grep -q "with no check changing state" <<< "$out" && ! /usr/bin/grep -q "hard cap" <<< "$out"; then
        note "PASS  rc=$rc  checks appearing as queued restart nothing: still CANNOT-RUN by the idle window"
    else note "FAIL  rc=$rc want=2  a queued check was counted as progress"; fail=1; fi
    # The gate's OWN check-run is always running while it polls. It must not
    # count, or the gate would never be idle.
    gate_seq "$TMP/s_queued3_self_running.json" 3 60
    if [ "$rc" -eq 2 ] && /usr/bin/grep -q "with no check changing state" <<< "$out"; then
        note "PASS  rc=$rc  the gate's own running check-run is not progress"
    else note "FAIL  rc=$rc want=2  the gate counted itself as progress"; fail=1; fi
    # A check running forever still ends: the hard cap.
    gate_seq "$TMP/s_running3.json" 3 5
    if [ "$rc" -eq 2 ] && /usr/bin/grep -q "hard cap" <<< "$out"; then
        note "PASS  rc=$rc  a check that runs forever is still ended, by the hard cap"
    else note "FAIL  rc=$rc want=2  a never-ending running check was not capped"; fail=1; fi
    # HARD CAP: never settles; idle window huge, cap must end it. Uses the
    # one-state fixture so the cap (not a state flap) is what trips.
    (
        OSTLER_CHECKRUNS_JSON="$TMP/allstarted3.json" \
        OSTLER_GATE_FLOOR=3 OSTLER_GATE_MAX_WAIT_SECONDS=100 OSTLER_GATE_HARD_CAP_SECONDS=3 \
        OSTLER_GATE_POLL_INTERVAL_SECONDS=1 poll_and_decide deadbeefdeadbeef owner/repo
    ) >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 2 ]; then note "PASS  rc=$rc  hard cap ends a never-settling gate as CANNOT-RUN"; else note "FAIL  rc=$rc want=2  hard cap"; fail=1; fi

    echo "=== a superseded attempt must not outvote the one that replaced it ==="
    # The CM051 #1937 shape: one name has TWO check-run objects on the same
    # commit (a cancelled attempt, then a later successful one). The correct
    # read is the LATEST attempt's conclusion, by `id` -- not list order. Both
    # fixtures below carry the SAME two attempts for "b" in the OPPOSITE
    # array order, so a reducer that (bug-for-bug) trusted "last in the array"
    # or "first in the array" instead of comparing `id` would get exactly one
    # of the two right and the other wrong. Both must pass.
    mk supersede_old_first '{"check_runs":[
        {"id":100,"name":"a","status":"completed","conclusion":"success"},
        {"id":201,"name":"b","status":"completed","conclusion":"cancelled"},
        {"id":205,"name":"b","status":"completed","conclusion":"success"},
        {"id":100,"name":"c","status":"completed","conclusion":"success"}]}'
    mk supersede_new_first '{"check_runs":[
        {"id":100,"name":"a","status":"completed","conclusion":"success"},
        {"id":205,"name":"b","status":"completed","conclusion":"success"},
        {"id":201,"name":"b","status":"completed","conclusion":"cancelled"},
        {"id":100,"name":"c","status":"completed","conclusion":"success"}]}'
    run_case2 0 "GUARD: name b's latest attempt (higher id) succeeded after an earlier cancellation -- must PASS (array order: old, then new)" supersede_old_first
    run_case2 0 "GUARD: same as above, array order reversed (new, then old) -- must still PASS, proving this is not reading list order" supersede_new_first

    # The mirror case: name b's LATEST attempt is the cancellation. Nobody
    # re-ran it, so this must refuse, regardless of array order again.
    mk latest_cancel_old_first '{"check_runs":[
        {"id":100,"name":"a","status":"completed","conclusion":"success"},
        {"id":201,"name":"b","status":"completed","conclusion":"success"},
        {"id":205,"name":"b","status":"completed","conclusion":"cancelled"},
        {"id":100,"name":"c","status":"completed","conclusion":"success"}]}'
    mk latest_cancel_new_first '{"check_runs":[
        {"id":100,"name":"a","status":"completed","conclusion":"success"},
        {"id":205,"name":"b","status":"completed","conclusion":"cancelled"},
        {"id":201,"name":"b","status":"completed","conclusion":"success"},
        {"id":100,"name":"c","status":"completed","conclusion":"success"}]}'
    run_case2 1 "GUARD: name b's latest attempt (higher id) is a cancellation nobody re-ran -- must FAIL (array order: old, then new)" latest_cancel_old_first
    run_case2 1 "GUARD: same as above, array order reversed -- must still FAIL, proving this is not reading list order" latest_cancel_new_first

    # The floor must count DISTINCT NAMES, not raw rows: this fixture has 3
    # names but 4 check-run rows (b has two attempts). Floor 3 must still be
    # satisfied by 3, not demand 4 -- and floor 4 must correctly refuse it.
    run_case2 2 "CONTROL: the SAME clean fixture fails a floor of 4 -- proves total is the collapsed (3), not the raw (4), count" supersede_old_first 4

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

    echo "=== expected check-runs, by identity (CM051, 2026-10-17) ==="
    # Run 11 and 12 are two attempts of workflow a.yml; 22 is b.yml.
    mk runs_ab '{"workflow_runs":[
        {"id":11,"path":".github/workflows/a.yml","status":"completed","conclusion":"failure"},
        {"id":12,"path":".github/workflows/a.yml","status":"completed","conclusion":"success"},
        {"id":22,"path":".github/workflows/b.yml","status":"completed","conclusion":"success"}]}'
    U='https://github.com/o/r/actions/runs'
    # THE COLLISION: two DIFFERENT workflows each have a job named "gate". a.yml's
    # failed; b.yml's (a higher id) passed. Keyed by name, the pass masked it.
    mk collide '{"check_runs":[
        {"id":101,"name":"gate","status":"completed","conclusion":"failure","details_url":"'$U'/11/job/101"},
        {"id":202,"name":"gate","status":"completed","conclusion":"success","details_url":"'$U'/22/job/202"},
        {"id":203,"name":"c","status":"completed","conclusion":"success","details_url":"'$U'/22/job/203"}]}'
    run_case3() {  # run_case3 <want-rc> <label> <checks> <runs> [expected-json] [grace] [maxwait]
        local want="$1" label="$2" checks="$3" rruns="$4" exp="${5:-}" grace="${6:-600}" mw="${7:-1}"
        (
            [ -n "$exp" ] && export OSTLER_GATE_EXPECTED_JSON="$TMP/$exp.json"
            OSTLER_CHECKRUNS_JSON="$TMP/$checks.json" \
            OSTLER_RUNS_JSON="$TMP/$rruns.json" \
            OSTLER_GATE_FLOOR=2 \
            OSTLER_GATE_MISSING_GRACE_SECONDS="$grace" \
            OSTLER_GATE_MAX_WAIT_SECONDS="$mw" \
            OSTLER_GATE_POLL_INTERVAL_SECONDS=1 \
            poll_and_decide deadbeefdeadbeef owner/repo
        ) > "$TMP/last.out" 2>&1
        local rc=$?
        if [ "$rc" -eq "$want" ]; then note "PASS  rc=$rc  $label"; else note "FAIL  rc=$rc want=$want  $label"; fail=1; fi
    }
    said() {  # said <text> <label> -- the last verdict must SAY why
        if [ "$(grep -cF -- "$1" "$TMP/last.out")" -gt 0 ]; then note "PASS  $2"
        else note "FAIL  $2 -- '$1' not in the verdict"; fail=1; fi
    }
    run_case3 1 "GUARD: a.yml's failed 'gate' is NOT masked by b.yml's passing 'gate'" collide runs_ab
    # ITS CONTROL: the same check-runs with no runs payload key on the name
    # alone, which is the old behaviour -- and it goes GREEN. That proves the
    # fixture discriminates: the line above passes because of the keying.
    (OSTLER_CHECKRUNS_JSON="$TMP/collide.json" OSTLER_GATE_FLOOR=2 OSTLER_GATE_MAX_WAIT_SECONDS=1 \
     OSTLER_GATE_POLL_INTERVAL_SECONDS=1 poll_and_decide deadbeefdeadbeef owner/repo) >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then note "PASS  CONTROL: keyed by name alone (the old way) the same fixture goes GREEN -- the hole was real"
    else note "FAIL  CONTROL: name-only keying gave rc=$rc, want 0 -- the collision fixture does not discriminate"; fail=1; fi

    # Attempts of the SAME workflow still collapse to the latest.
    mk sameflow '{"check_runs":[
        {"id":101,"name":"gate","status":"completed","conclusion":"cancelled","details_url":"'$U'/11/job/101"},
        {"id":105,"name":"gate","status":"completed","conclusion":"success","details_url":"'$U'/12/job/105"},
        {"id":203,"name":"c","status":"completed","conclusion":"success","details_url":"'$U'/22/job/203"}]}'
    run_case3 0 "a cancelled attempt superseded by a later run of the SAME workflow still passes" sameflow runs_ab

    # Expected by identity: a.yml must report gate AND x; b.yml must report c.
    printf '%s' '{"floor":3,"workflows":{".github/workflows/a.yml":{"names":["gate","x"],"unnamed":0},".github/workflows/b.yml":{"names":["c"],"unnamed":0}}}' > "$TMP/exp_ax.json"
    run_case3 1 "a REQUIRED check that never reported is RED, though every reported check passed" sameflow runs_ab exp_ax
    said "never reported: x" "  ...and the verdict names the missing check"
    printf '%s' '{"floor":2,"workflows":{".github/workflows/a.yml":{"names":["gate"],"unnamed":0},".github/workflows/b.yml":{"names":["c"],"unnamed":0}}}' > "$TMP/exp_ok.json"
    run_case3 0 "CONTROL: the same check-runs pass when every required check reported" sameflow runs_ab exp_ok

    # A workflow that FAILS AT STARTUP: its run completed, zero jobs reported.
    mk startfail_runs '{"workflow_runs":[
        {"id":12,"path":".github/workflows/a.yml","status":"completed","conclusion":"success"},
        {"id":22,"path":".github/workflows/b.yml","status":"completed","conclusion":"success"},
        {"id":33,"path":".github/workflows/dead.yml","status":"completed","conclusion":"failure"}]}'
    printf '%s' '{"floor":3,"workflows":{".github/workflows/a.yml":{"names":["gate"],"unnamed":0},".github/workflows/b.yml":{"names":["c"],"unnamed":0},".github/workflows/dead.yml":{"names":["d"],"unnamed":0}}}' > "$TMP/exp_dead.json"
    run_case3 1 "a required workflow that failed at STARTUP (zero check-runs) is RED" sameflow startfail_runs exp_dead
    said "dead.yml ran (conclusion failure) but never reported: d" "  ...and says it ran and reported nothing"
    printf '%s' '{"floor":3,"workflows":{".github/workflows/dead.yml":{"names":[],"unnamed":1}}}' > "$TMP/exp_unnamed.json"
    run_case3 1 "an UNNAMED required check-run (reusable call, expression name) is still required" sameflow startfail_runs exp_unnamed

    # No run at all: waited for inside the grace, RED after it.
    run_case3 1 "a required workflow with NO run is RED once the grace has passed" sameflow runs_ab exp_dead 1 5
    said "NO workflow run at this commit" "  ...and says there was no run"
    run_case3 2 "inside the grace it is waited for, not judged (the idle window closes first: CANNOT-RUN)" sameflow runs_ab exp_dead 600 1
    # A run still in progress is waited for; when its check appears, GREEN.
    mk running_runs '{"workflow_runs":[
        {"id":12,"path":".github/workflows/a.yml","status":"in_progress","conclusion":null},
        {"id":22,"path":".github/workflows/b.yml","status":"completed","conclusion":"success"}]}'
    mk only_c '{"check_runs":[
        {"id":203,"name":"c","status":"completed","conclusion":"success","details_url":"'$U'/22/job/203"}]}'
    (
        OSTLER_CHECKRUNS_JSON_SEQUENCE="$TMP/only_c.json:$TMP/sameflow.json" \
        OSTLER_RUNS_JSON_SEQUENCE="$TMP/running_runs.json:$TMP/runs_ab.json" \
        OSTLER_GATE_EXPECTED_JSON="$TMP/exp_ok.json" OSTLER_GATE_FLOOR=1 \
        OSTLER_GATE_MAX_WAIT_SECONDS=10 OSTLER_GATE_POLL_INTERVAL_SECONDS=1 \
        poll_and_decide deadbeefdeadbeef owner/repo
    ) >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then note "PASS  a required check whose run is still in progress is WAITED for, then passes"
    else note "FAIL  rc=$rc want=0  an in-progress required run was judged instead of waited for"; fail=1; fi

    echo "=== which check-runs are EXPECTED, computed from the tree ==="
    EXP_TMP="$(mktemp -d)"
    cat > "$EXP_TMP/plain.yml" <<'YML'
on: { pull_request: }
jobs:
  a: { runs-on: x, steps: [] }
  b: { name: "Bee", runs-on: x, if: "github.event_name == 'push'", steps: [] }
YML
    cat > "$EXP_TMP/edited-only.yml" <<'YML'
on: { pull_request: { types: [edited] } }
jobs: { e: { runs-on: x, steps: [] } }
YML
    cat > "$EXP_TMP/main-only.yml" <<'YML'
on: { pull_request: { branches: [main] } }
jobs: { m: { runs-on: x, steps: [] } }
YML
    cat > "$EXP_TMP/filtered.yml" <<'YML'
on: { pull_request: { paths: ['x/**'] } }
jobs: { f: { runs-on: x, steps: [] } }
YML
    cat > "$EXP_TMP/matrix.yml" <<'YML'
on: [pull_request]
jobs:
  t: { runs-on: x, strategy: { matrix: { py: ['3.11', '3.12'] } }, steps: [] }
  inc: { runs-on: x, strategy: { matrix: { include: [{ a: 1 }] } }, steps: [] }
  expr: { name: "x ${{ matrix.y }}", runs-on: x, steps: [] }
  call: { uses: ./.github/workflows/other.yml }
YML
    cat > "$EXP_TMP/ci-required-gate.yml" <<'YML'
on: { pull_request: }
jobs: { gate: { runs-on: x, steps: [] } }
YML
    exp_is() {  # exp_is <base> <action> <want-json> <label>
        local got
        got="$(OSTLER_GATE_WORKFLOWS_DIR="$EXP_TMP" OSTLER_GATE_BASE_REF="$1" OSTLER_GATE_EVENT_ACTION="$2" resolve_expected)"
        if [ "$got" = "$3" ]; then note "PASS  $4"
        else note "FAIL  $4"; note "      got  $got"; note "      want $3"; fail=1; fi
    }
    W='.github/workflows'
    exp_is main synchronize '{"floor": 8, "workflows": {"'$W'/main-only.yml": {"names": ["m"], "unnamed": 0}, "'$W'/matrix.yml": {"names": ["t (3.11)", "t (3.12)"], "unnamed": 3}, "'$W'/plain.yml": {"names": ["a", "Bee"], "unnamed": 0}}}' \
        "base main, synchronize: every job (even an if:-guarded one), one name per matrix leg, unnameable legs counted, path-filtered/types-excluded/self NOT expected"
    exp_is release synchronize '{"floor": 7, "workflows": {"'$W'/matrix.yml": {"names": ["t (3.11)", "t (3.12)"], "unnamed": 3}, "'$W'/plain.yml": {"names": ["a", "Bee"], "unnamed": 0}}}' \
        "a base the branch filter excludes: that workflow is not expected"
    exp_is '' '' '{"floor": 7, "workflows": {"'$W'/matrix.yml": {"names": ["t (3.11)", "t (3.12)"], "unnamed": 3}, "'$W'/plain.yml": {"names": ["a", "Bee"], "unnamed": 0}}}' \
        "base and action unknown: branch- and types-filtered workflows are NOT expected (never unpassable)"
    exp_is main edited '{"floor": 1, "workflows": {"'$W'/edited-only.yml": {"names": ["e"], "unnamed": 0}}}' \
        "action 'edited': only a workflow whose types include it is expected; default types do not fire on it"
    rm -rf "$EXP_TMP"

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
