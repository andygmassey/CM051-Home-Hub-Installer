#!/usr/bin/env bash
# scripts/verify_tagged_commit_is_green.sh -- a cut must not start on a commit
# whose own checks are red.
# ============================================================================
#
# WHY THIS EXISTS, and it is not the usual reason.
#
# Every other gate found this month answers "the mechanism could not see it".
# This one is the opposite: on 2026-08-23 the information existed, on time, in
# the obvious place, and the operator did not look.
#
#   10:32:44Z  installer-version-consistency  push  42648d92  FAILURE
#   10:33:14Z  ORM pushes tag v1.0.42 at 42648d9
#   10:35:55Z  the cut refuses at `make check-version` -- the SAME defect
#
# Between those first two lines sat a completed, red, thirty-second ubuntu job
# naming the exact drift. What the cut spent instead: a full macOS build, a
# Developer ID signing, an Apple notarisation round trip, and a staple.
#
# THE OPERATOR SHOULD HAVE LOOKED IS NOT A MECHANISM. This is.
#
# ============================================================================
# WHAT IT REFUSES, AND WHAT IT DELIBERATELY DOES NOT
# ============================================================================
#
# REFUSES (exit 1): any COMPLETED check-run on the commit whose conclusion is
#   failure, cancelled, timed_out or action_required.
#
# IGNORES: in_progress and queued runs -- the cut's own workflow is one of them
#   by construction, so refusing on "not yet complete" would refuse every cut.
#   Also ignores neutral, skipped and success, which are not failures.
#
# ALSO EXCLUDES THE CUT WORKFLOW'S OWN JOBS, BY NAME, AND SAYS SO ON EVERY RUN.
# 🔴 This exclusion is not tidiness, it was forced by reality. The first version
# refused the commit that actually shipped: `dry-run=cancelled; cut=cancelled;
# preflight=cancelled`, from a DUPLICATE cut run cancelled after both agents
# pushed the same tag within two minutes. THE CUT CANNOT GATE ON ITSELF -- its
# own jobs are always either running (this attempt) or dead (a previous attempt
# at the same tag), and neither says anything about the commit.
#
# The count excluded is PRINTED. An exclusion nobody can see is how a gate
# quietly stops looking, and this one is broad enough to matter.
#
# CANNOT-RUN (exit 2), never a pass:
#   * the API cannot be reached
#   * the commit has ZERO check-runs. A zero denominator is the failure mode
#     this estate keeps finding; "no checks failed" over an empty set is not a
#     statement about the commit, it is a statement about the query.
#
# The count of what was EXAMINED is printed every run, because a verdict whose
# denominator is invisible cannot be audited.
#
# USAGE
#   scripts/verify_tagged_commit_is_green.sh <sha> [repo]
#   scripts/verify_tagged_commit_is_green.sh --self-test
#
#   OSTLER_CHECKRUNS_JSON=<file>  read check-runs from a file instead of the
#                                 API. The self-test's only lever; it exists so
#                                 the cases below are hermetic.
# ============================================================================
set -uo pipefail

red()   { printf '\033[0;31m%s\033[0m\n' "$1" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
dim()   { printf '\033[2m%s\033[0m\n' "$1"; }

# Conclusions that BLOCK. Everything else either did not finish or did not fail.
BLOCKING='failure cancelled timed_out action_required'

evaluate() {   # evaluate <json-file> -- prints the verdict, returns 0/1/2
    local f="$1" total completed bad
    python3 - "$f" <<'PY'
import json, sys
BLOCKING = {"failure", "cancelled", "timed_out", "action_required"}
try:
    doc = json.load(open(sys.argv[1]))
except Exception as exc:                       # noqa: BLE001
    print(f"CANNOT-RUN\t0\t0\tunreadable check-run payload: {exc}")
    raise SystemExit(0)
# `gh api --paginate --slurp` returns an ARRAY OF PAGE OBJECTS, not one
# object, so the reader must MERGE across pages. Without --slurp gh
# concatenates one JSON object per page and json.load cannot read it at all:
# that is the v1.0.51 cut blocker, "Extra data: line 1 column 312659",
# refusing run 33267872883 on a commit whose checks were entirely green. The
# gate was only ever going to work while a commit had fewer check-runs than
# one page holds, so it was guaranteed to start refusing as CI grew, and it
# did. Reading page 1 alone would be worse than the crash: it would return
# GREEN over a failure on page 2. The self-test asserts exactly that case.
if isinstance(doc, list):
    runs = []
    for page in doc:
        if isinstance(page, dict):
            runs.extend(page.get("check_runs") or [])
        else:
            runs.append(page)          # a bare list of runs (fixture shape)
else:
    runs = doc.get("check_runs") or []
# The cut's own jobs. Overridable so a workflow rename does not silently
# re-include them, and so the self-test can prove the exclusion is BY NAME.
import os
own = {n.strip() for n in os.environ.get(
    "OSTLER_CUT_JOB_NAMES", "cut,preflight,dry-run").split(",") if n.strip()}
seen = len(runs)
runs = [r for r in runs if r.get("name") not in own]
excluded = seen - len(runs)
total = len(runs)
completed = [r for r in runs if r.get("status") == "completed"]
bad = [r for r in completed if r.get("conclusion") in BLOCKING]
if total == 0:
    print(f"CANNOT-RUN\t0\t0\tthe commit has ZERO check-runs outside the cut's own {excluded} job(s)")
    raise SystemExit(0)
if bad:
    names = "; ".join(f"{r.get('name')}={r.get('conclusion')}" for r in bad)
    print(f"RED\t{total}\t{len(completed)}\t{names}  [excluded {excluded} of the cut's own job(s)]")
    raise SystemExit(0)
print(f"GREEN\t{total}\t{len(completed)}\texcluded {excluded} of the cut's own job(s)")
PY
}

run_check() {  # run_check <sha> <repo>
    local sha="$1" repo="$2" tmp verdict total completed detail
    tmp="$(mktemp)"
    if [ -n "${OSTLER_CHECKRUNS_JSON:-}" ]; then
        cp "$OSTLER_CHECKRUNS_JSON" "$tmp" 2>/dev/null || {
            red "CANNOT-RUN: OSTLER_CHECKRUNS_JSON is unreadable"; rm -f "$tmp"; return 2; }
    elif ! gh api "repos/$repo/commits/$sha/check-runs" --paginate --slurp > "$tmp" 2>"$tmp.err"; then
        red "CANNOT-RUN: could not read check-runs for $sha in $repo."
        dim "Nothing was measured. A cut must not proceed on an unread commit."
        # gh's stderr is PRINTED, not swallowed. `2>/dev/null` on a probe turns
        # a usage error, an auth failure and a real absence into the same
        # silent sentence, and then the operator debugs the wrong thing.
        [ -s "$tmp.err" ] && dim "  gh said: $(tr '\n' ' ' < "$tmp.err" | cut -c1-300)"
        rm -f "$tmp" "$tmp.err"; return 2
    fi
    rm -f "$tmp.err"

    IFS=$'\t' read -r verdict total completed detail < <(evaluate "$tmp")
    rm -f "$tmp"

    dim "tagged-commit checks: $repo @ ${sha:0:12}"
    dim "  EXAMINED ${total:-0} check-run(s), ${completed:-0} completed"

    case "$verdict" in
        GREEN)
            green "TAGGED COMMIT GREEN -- no completed check-run on ${sha:0:12} is failing."
            dim "  $detail"
            dim "NOT PROVEN HERE: that every check has FINISHED. In-progress runs are"
            dim "ignored deliberately -- this cut's own workflow is one of them."
            return 0 ;;
        RED)
            red "TAGGED COMMIT RED -- refusing to cut ${sha:0:12}."
            dim "  $detail"
            dim ""
            dim "This is the 2026-08-23 shape: installer-version-consistency went RED on"
            dim "main at 10:32:44Z and a tag was pushed at the same commit 30 seconds"
            dim "later. The cut then spent a build, a signing and an Apple notarisation"
            dim "to rediscover it. Fix the red, then move the tag."
            return 1 ;;
        *)
            red "CANNOT-RUN: $detail"
            dim "Nothing was measured, so this is NOT a pass. A zero denominator is the"
            dim "failure mode this file exists to refuse."
            return 2 ;;
    esac
}

if [ "${1:-}" = "--self-test" ]; then
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    fail=0
    note() { printf '  %s\n' "$*"; }
    mk() { printf '%s' "$2" > "$TMP/$1.json"; }

    mk green   '{"check_runs":[{"name":"a","status":"completed","conclusion":"success"},{"name":"b","status":"completed","conclusion":"skipped"}]}'
    mk red     '{"check_runs":[{"name":"a","status":"completed","conclusion":"success"},{"name":"installer-version-consistency","status":"completed","conclusion":"failure"}]}'
    mk running '{"check_runs":[{"name":"cut","status":"in_progress","conclusion":null},{"name":"a","status":"completed","conclusion":"success"}]}'
    mk empty   '{"check_runs":[]}'
    mk cancel  '{"check_runs":[{"name":"a","status":"completed","conclusion":"cancelled"}]}'
    mk neutral '{"check_runs":[{"name":"a","status":"completed","conclusion":"neutral"}]}'
    mk garbage 'not json at all'

    run_case() {
        local want="$1" label="$2" file="$3" rc
        OSTLER_CHECKRUNS_JSON="$TMP/$file.json" run_check deadbeefdeadbeef owner/repo >/dev/null 2>&1
        rc=$?
        if [ "$rc" -eq "$want" ]; then note "PASS  rc=$rc  $label"; else note "FAIL  rc=$rc want=$want  $label"; fail=1; fi
    }

    run_case 0 "POSITIVE CONTROL: all completed checks pass -> GREEN" green
    run_case 1 "one completed FAILURE refuses the cut" red
    run_case 0 "an in-progress run does NOT refuse (the cut's own job is one)" running
    run_case 2 "ZERO check-runs is CANNOT-RUN, never a pass" empty
    run_case 1 "a CANCELLED check refuses -- a gate that did not report is not a pass" cancel
    run_case 0 "a NEUTRAL conclusion is not a failure" neutral
    run_case 2 "an unreadable payload is CANNOT-RUN, not green" garbage

    # THE v1.0.51 BLOCKER, asserted in all three directions. This is a
    # REGRESSION TEST ON A DEFECT THAT ACTUALLY FIRED: run 33267872883 refused
    # to cut a commit whose checks were all green, because the fetch used
    # --paginate WITHOUT --slurp and json.load died at the first page boundary.
    # `slurpred` is the one that matters: reading only page 1 would report
    # GREEN over a failure on page 2, which is strictly worse than the crash
    # was, so the fix is not allowed to pass by truncating.
    mk slurped  '[{"check_runs":[{"name":"a","status":"completed","conclusion":"success"}]},{"check_runs":[{"name":"b","status":"completed","conclusion":"success"}]}]'
    mk slurpred '[{"check_runs":[{"name":"a","status":"completed","conclusion":"success"}]},{"check_runs":[{"name":"z","status":"completed","conclusion":"failure"}]}]'
    mk concat   '{"check_runs":[{"name":"a","status":"completed","conclusion":"success"}]}{"check_runs":[{"name":"b","status":"completed","conclusion":"success"}]}'
    run_case 0 "a SLURPED multi-page payload parses and passes" slurped
    run_case 1 "a failure on the SECOND page still refuses -- pages are MERGED, not truncated" slurpred
    run_case 2 "the OLD concatenated shape is CANNOT-RUN, never a silent pass" concat

    # The self-exclusion. Broad exclusions are how a gate quietly stops
    # looking, so both directions are asserted: it drops the cut's OWN jobs,
    # and it drops NOTHING ELSE.
    mk ownfail '{"check_runs":[{"name":"cut","status":"completed","conclusion":"cancelled"},{"name":"preflight","status":"completed","conclusion":"cancelled"},{"name":"a","status":"completed","conclusion":"success"}]}'
    mk onlyown '{"check_runs":[{"name":"cut","status":"completed","conclusion":"cancelled"}]}'
    run_case 0 "the cut's OWN cancelled jobs do not refuse the commit" ownfail
    run_case 2 "a commit with ONLY the cut's own jobs is CANNOT-RUN, not green" onlyown

    # CONTROL: the exclusion is BY NAME. A differently-named job with the same
    # conclusion must still refuse, or "exclude the cut" becomes "exclude
    # anything that looks like it".
    mk lookalike '{"check_runs":[{"name":"cut-freshness","status":"completed","conclusion":"failure"}]}'
    run_case 1 "CONTROL: a job merely NAMED like the cut still refuses" lookalike

    # And the override must actually override, or a workflow rename silently
    # re-includes the cut's jobs and every cut refuses itself.
    OSTLER_CUT_JOB_NAMES="a" OSTLER_CHECKRUNS_JSON="$TMP/red.json" run_check x owner/repo >/dev/null 2>&1
    if [ $? -eq 1 ]; then
        note "PASS  OSTLER_CUT_JOB_NAMES changes the exclusion set (the real failure still refuses)"
    else
        note "FAIL  the exclusion override did not take effect"; fail=1
    fi

    echo
    if [ "$fail" -eq 0 ]; then
        echo "RESULT: PASSED -- red refuses, green passes, and an empty answer is neither"
        exit 0
    fi
    echo "RESULT: FAILED"
    exit 1
fi

SHA="${1:-}"
REPO="${2:-${GITHUB_REPOSITORY:-andygmassey/CM051-Home-Hub-Installer}}"
[ -n "$SHA" ] || { red "usage: $0 <sha> [owner/repo]   or   $0 --self-test"; exit 2; }
run_check "$SHA" "$REPO"
