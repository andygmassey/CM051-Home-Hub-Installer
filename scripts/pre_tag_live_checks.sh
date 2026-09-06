#!/usr/bin/env bash
# The pre-tag checks that CAN GO STALE WITH NO COMMIT, taken together, stamped.
#
# ============================================================================
# WHY. THIS CLASS HAS NOW KILLED TWO CUTS, ON TWO DIFFERENT GATES.
# ============================================================================
# A pre-tag block contains two kinds of check and nothing distinguished them:
#
#   FROZEN BY THE TAG    pin-by-blob, the plist, payload presence, walk closure
#                        -- a commit is required to change any of these, so a
#                        reading taken an hour ago is still true at tag time.
#
#   LIVE AT READ TIME    the cut checklist (reads the LIVE issue list),
#                        check-orphans (reads the LIVE open-PR list),
#                        main CI (a later push changes it), daemon and wiki
#                        freshness (another repo's main, which nobody in this
#                        repo touches).
#
# Everything in the second column has a shelf life measured in MINUTES, and
# nothing about its number says so. Both deaths were the same mistake:
#
#   v1.0.70  I read `gh pr list --state open` at 13:10Z, TNM opened #1549 at
#            13:14:22Z, I pushed the tag at 13:20:01Z. check-orphans was right
#            and the cut died in nine seconds.
#   v1.0.72  I read the cut checklist at 06:23Z and it was GREEN. TNM filed
#            #1660 at 06:43Z and I filed #1662 at 06:47Z. The 06:49 run went
#            red on main with NO COMMIT BETWEEN. My reading was true when taken
#            and false when quoted.
#
# The fix is not "read more carefully". It is to take the whole live column in
# ONE command, in the minute of the tag, and to STAMP it so a stale reading
# cannot be quoted as a current one.
#
# THIS SCRIPT DOES NOT TAG AND CANNOT. It has no push, no gh release, no git
# tag. It is a reading, and the operator still decides.
#
#   0  every live check green, at the stamp printed
#   1  at least one live check is red
#   2  CANNOT-RUN -- a check could not be taken, which is NOT a pass
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
EPOCH="$(date -u '+%s')"
RED=0; CANT=0; ROWS=()

row() { ROWS+=("$1|$2|$3"); }   # name|verdict|detail

command -v gh >/dev/null 2>&1 || { echo "CANNOT-RUN: gh unavailable; the live column cannot be read at all." >&2; exit 2; }
gh auth status >/dev/null 2>&1 || { echo "CANNOT-RUN: gh is not authenticated; every live check below would report a false absence." >&2; exit 2; }

echo "=== LIVE pre-tag column, taken ${STAMP} ==="
echo

# ── 1. THE CUT CHECKLIST. Reads the live issue list. ────────────────────────
CUTV="${1:-}"
if [ -z "$CUTV" ]; then
    CUTV="$(ls -d "${HERE}"/cuts/v1.0.* 2>/dev/null | sed 's#.*/##' | sort -t. -k3 -n | tail -1)"
fi
if [ -x "${HERE}/tests/test_the_cut_checklist_is_complete.py" ] || [ -f "${HERE}/tests/test_the_cut_checklist_is_complete.py" ]; then
    _o="$(cd "$HERE" && python3 tests/test_the_cut_checklist_is_complete.py 2>&1)"; _rc=$?
    _unreg="$(printf '%s' "$_o" | sed -n 's/.*OPEN issue(s) are not in the checklist: \(\[[^]]*\]\).*/\1/p' | head -1)"
    case "$_rc" in
        0) row "cut checklist (live issues)" "GREEN" "every open issue registered" ;;
        *) RED=1; row "cut checklist (live issues)" "RED" "unregistered: ${_unreg:-see output}. Someone filed an issue since your last reading." ;;
    esac
else
    CANT=1; row "cut checklist (live issues)" "CANNOT-RUN" "test_the_cut_checklist_is_complete.py not found"
fi

# ── 2. OPEN PRs vs the deferral file. The check-orphans limb that is LIVE. ──
# Deliberately NOT the whole orphan gate: its local-branch limbs are about this
# machine and cannot change under you. Only the open-PR set is mutable by a peer
# in the seconds before a tag, and that is the limb that killed v1.0.70.
_defs="${HERE}/cut-deferrals.yaml"
if [ -f "$_defs" ]; then
    _open="$(gh pr list --repo andygmassey/CM051-Home-Hub-Installer --state open --json number -q '.[].number' 2>/dev/null)"
    if [ -z "$_open" ] && ! gh pr list --repo andygmassey/CM051-Home-Hub-Installer --state open --limit 1 >/dev/null 2>&1; then
        CANT=1; row "open PRs vs deferrals" "CANNOT-RUN" "could not list open PRs; an empty list here would be a false all-clear"
    else
        # THE TWO KEY SHAPES ARE EXHAUSTIVE, MEASURED not assumed. Parsed
        # cut-deferrals.yaml across BOTH top-level keys: 225 CM051 refs, of
        # which 98 are PR-NUMBER shaped (tail matches #<digits>):
        #
        #     CM051:#N                      93
        #     CM051-Home-Hub-Installer#N     5
        #     any other shape                0
        #
        # The remaining 127 are BRANCH refs (CM051:fix/..., CM051:pr632,
        # CM051:rb450) and are not PR numbers. Note pr632: a branch named for a
        # PR is NOT that PR's deferral -- the orphan gate's own header records
        # that exact confusion, and the deferral for it is CM051:#632.
        #
        # If a third PR-number shape is ever introduced this reads as
        # UNDEFERRED and reds a tag that should go -- the inverse of the
        # v1.0.70 failure and just as expensive. Re-measure if the count above
        # stops adding up.
        _undeclared=""
        for n in $_open; do
            grep -q "CM051:#${n}\"" "$_defs" || grep -q "CM051-Home-Hub-Installer#${n}\"" "$_defs" || _undeclared="${_undeclared} #${n}"
        done
        _n_open="$(printf '%s\n' $_open | grep -c . || true)"
        if [ -n "$_undeclared" ]; then
            RED=1; row "open PRs vs deferrals" "RED" "${_n_open} open, NOT deferred:${_undeclared} -- check-orphans will red the cut on these"
        else
            row "open PRs vs deferrals" "GREEN" "${_n_open} open, all deferred"
        fi
    fi
else
    CANT=1; row "open PRs vs deferrals" "CANNOT-RUN" "no cut-deferrals.yaml"
fi

# ── 3. main CI, latest run PER WORKFLOW. A later push changes this. ─────────
# An in-progress run has conclusion "", which is NOT null, so `// "x"` never
# substitutes and it matches neither success nor failure. That exact predicate
# once made a wait loop print ALL SETTLED with 42 workflows running. The three
# buckets below must sum to the total, printed, so a fourth state cannot hide.
_ci="$(gh run list --repo andygmassey/CM051-Home-Hub-Installer --branch main --limit 200 \
        --json workflowName,conclusion,createdAt \
        -q '.[] | [.workflowName, .createdAt, ((.conclusion // "") | if . == "" then "RUNNING" else . end)] | @tsv' 2>/dev/null \
      | sort -k1,1 -k2,2r | awk -F'\t' '!seen[$1]++')"
if [ -z "$_ci" ]; then
    CANT=1; row "main CI (latest per workflow)" "CANNOT-RUN" "no runs returned; scanning nothing is not a green main"
else
    _tot="$(printf '%s\n' "$_ci" | grep -c .)"
    _ok="$(printf '%s\n' "$_ci"  | awk -F'\t' '$3=="success"'  | grep -c . || true)"
    _run="$(printf '%s\n' "$_ci" | awk -F'\t' '$3=="RUNNING"'  | grep -c . || true)"
    _bad="$(printf '%s\n' "$_ci" | awk -F'\t' '$3!="success" && $3!="RUNNING" && $3!="skipped"' | grep -c . || true)"
    _names="$(printf '%s\n' "$_ci" | awk -F'\t' '$3!="success" && $3!="RUNNING" && $3!="skipped" {printf "%s ", $1}')"
    if [ "$_bad" -gt 0 ]; then
        RED=1; row "main CI (latest per workflow)" "RED" "${_ok} green / ${_run} running / ${_bad} red of ${_tot} -- ${_names}"
    elif [ "$_run" -gt 0 ]; then
        RED=1; row "main CI (latest per workflow)" "NOT SETTLED" "${_ok} green / ${_run} STILL RUNNING / 0 red of ${_tot}. A tag now spends a version on an unfinished answer."
    else
        row "main CI (latest per workflow)" "GREEN" "${_ok} green / 0 running / 0 red of ${_tot}"
    fi
fi

# ── 4. ANOTHER REPO'S main. Nobody here can change it and nobody here watches
#      it. This is what killed the v1.0.72 build: the daemon pin went stale
#      while every CM051 check stayed green.
_dpin="$(sed -n 's/^DAEMON_COMMIT=\([0-9a-f]*\).*/\1/p' "${HERE}/cuts/${CUTV}/cut.env" 2>/dev/null | head -1)"
if [ -n "$_dpin" ]; then
    _dhead="$(gh api repos/ostler-ai/ostler-assistant/commits/main --jq '.sha' 2>/dev/null)"
    if [ -z "$_dhead" ]; then
        CANT=1; row "daemon pin vs oa/main" "CANNOT-RUN" "could not read ostler-assistant main; a stale pin would pass unnoticed"
    else
        # COUNT THE WAY THE GATE THAT DECIDES COUNTS. permanent-daemon-freshness
        # scopes to crates/**, because a commit touching only .gitignore or docs
        # cannot reach the built binary. A bare ahead_by disagrees with the gate
        # -- measured: 7 total vs 6 touching crates -- and two numbers for one
        # question sends the reader hunting for which is wrong. Print BOTH, and
        # decide on the scoped one.
        _cmp="$(gh api "repos/ostler-ai/ostler-assistant/compare/${_dpin}...${_dhead:0:40}" 2>/dev/null)"
        _ahead="$(printf '%s' "$_cmp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ahead_by",""))' 2>/dev/null)"
        if [ -n "$_ahead" ] && [ "$_ahead" -gt 0 ] 2>/dev/null; then
            _touch=0
            for _sha in $(printf '%s' "$_cmp" | python3 -c 'import json,sys; print(" ".join(c["sha"] for c in json.load(sys.stdin).get("commits",[])[:20]))' 2>/dev/null); do
                gh api "repos/ostler-ai/ostler-assistant/commits/${_sha}" --jq '.files[].filename' 2>/dev/null \
                    | grep -q '^crates/' && _touch=$((_touch + 1))
            done
            RED=1; row "daemon pin vs oa/main" "RED" "oa/main is ${_ahead} commit(s) ahead of pin ${_dpin}, ${_touch} touching crates/** -- and crates/** is what permanent-daemon-freshness counts. It fails INSIDE the build, after signing has started."
        elif [ "${_ahead:-x}" = "0" ]; then
            row "daemon pin vs oa/main" "GREEN" "pin ${_dpin} == oa/main"
        else
            CANT=1; row "daemon pin vs oa/main" "CANNOT-RUN" "compare API gave no ahead_by; a stale pin would pass unnoticed"
        fi
    fi
else
    CANT=1; row "daemon pin vs oa/main" "CANNOT-RUN" "no DAEMON_COMMIT in cuts/${CUTV}/cut.env"
fi

# ── report ─────────────────────────────────────────────────────────────────
printf '  %-30s  %-12s  %s\n' "CHECK" "VERDICT" "DETAIL"
for r in "${ROWS[@]}"; do
    printf '  %-30s  %-12s  %s\n' "${r%%|*}" "$(echo "$r" | cut -d'|' -f2)" "${r##*|}"
done
echo
_age=$(( $(date -u '+%s') - EPOCH ))
echo "  taken at ${STAMP}, completed ${_age}s later."
echo
echo "  ⚠️  EVERY ROW ABOVE IS LIVE. None of them needs a commit to change."
echo "      Two cuts have died on a reading that was true when taken:"
echo "      v1.0.70 (a PR opened in the 10-minute gap) and v1.0.72 (two issues"
echo "      filed in the 26-minute gap). PUSH THE TAG IN THIS MINUTE OR RETAKE."
echo

if [ "$CANT" -ne 0 ]; then echo "VERDICT: CANNOT-RUN -- a live check could not be taken. That is not a pass."; exit 2; fi
if [ "$RED"  -ne 0 ]; then echo "VERDICT: RED -- do not tag."; exit 1; fi
echo "VERDICT: GREEN at ${STAMP} -- and only at ${STAMP}."
exit 0
