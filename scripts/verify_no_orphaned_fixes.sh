#!/usr/bin/env bash
#
# verify_no_orphaned_fixes.sh -- fail the cut when a FIX EXISTS but is not in it.
#
# =============================================================================
# WHY THIS GATE EXISTS
# =============================================================================
# The v1.0.15 box-walk (2026-08-06) found nine defects. SIX of them were
# ALREADY FIXED and had simply never reached main:
#
#   CM044  7f1dc59  dup-decision buttons + settling-card ETA   unmerged branch
#   CM044  1ef16a5  hydration weighted % bar (Option B)        unmerged branch
#   CM051  #632     Back/Continue footer                       LOCAL-ONLY worktree,
#                                                              parent clone deleted
#   CM051  browsing self-create collection                     unmerged branch
#   CM031  #154     hardcoded $24.99 paywall price             OPEN **DRAFT** PR,
#                                                              all checks green,
#                                                              sat 4 days
#
# Andy walked a DMG and hit every one of them. That is not six bugs. It is one
# habit: work gets written, then abandoned before the merge. Every existing cut
# gate passed, because every existing gate asks "is what we pinned present?" --
# never "does a fix exist that we FORGOT to pin?".
#
# Andy, 2026-08-06: "put safe guards in place to not allow shit git hygiene
# like this, as well as against cuts."
#
# =============================================================================
# WHAT IT CHECKS
# =============================================================================
# For every repo that feeds the cut, against the ref actually being shipped:
#
#   1. OPEN PRs (INCLUDING DRAFTS) whose head is not an ancestor  -> RED
#      Drafts are checked LOUDEST: #154 was a green draft for four days.
#   2. Remote branches matching fix/ hotfix/ feat/ carrying commits
#      not in the shipping ref                                    -> RED
#   3. LOCAL-ONLY branches (not on origin at all)                 -> RED
#      This is the #632 class: work that exists on one machine and is one
#      `rm -rf` from gone. It is invisible to every other gate.
#   4. Dirty or untracked work in the cut checkout                -> RED
#
# =============================================================================
# HOW TO DEFER SOMETHING DELIBERATELY
# =============================================================================
# You may absolutely decide a fix is not for this cut. What you may NOT do is
# decide it SILENTLY. Add it to cut-deferrals.yaml with a reason:
#
#   deferrals:
#     - ref: "CM044:feat/wiki-reskin"
#       reason: "Reskin lands in v1.0.17, exemplar signed off but not propagated"
#       until_cut: "v1.0.17"
#
# The deferral file is tracked, so `git log cut-deferrals.yaml` is the history
# of every conscious "not yet". Silence is the bug; a recorded decision is fine.
#
# Usage:  scripts/verify_no_orphaned_fixes.sh [--json]
# Exit:   0 = clean, 1 = orphaned work found, 3 = cannot verify (fail closed)
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFERRALS_FILE="${OSTLER_CUT_DEFERRALS:-${REPO_ROOT}/cut-deferrals.yaml}"

# This script took no arguments at all until the expiry ratchet was added.
# Anything unrecognised is a CANNOT-RUN and not a silent success: a typo'd flag
# that gets ignored produces a run that looks like the one you asked for.
REGEN_EXPIRED=0
case "${1:-}" in
    --regenerate-expired-baseline) REGEN_EXPIRED=1 ;;
    "")                            REGEN_EXPIRED=0 ;;
    *)
        printf 'verify_no_orphaned_fixes: CANNOT-RUN -- unknown argument %s.\n' "'$1'" >&2
        printf '  Usage: %s [--regenerate-expired-baseline]\n' "${BASH_SOURCE[0]}" >&2
        exit 2
        ;;
esac

# The refs whose until_cut has already passed, this run. Compared against a
# committed baseline at the end so the debt can shrink and cannot grow.
#
# OVERRIDABLE so a SELF-TEST can point the ratchet at its own scratch file.
# Without this the self-test's synthetic fixture -- `CM044:fix/later`, written
# `until_cut: v1.0.17` -- is expired against any real cut version, lands in the
# expired set, is absent from the PRODUCTION baseline, and fires the ratchet.
# That is not a hypothesis: it is what stopped the v1.0.44 cut at step 7 on
# 2026-08-24, after `Build, sign, notarise, staple` had been skipped.
# A gate whose self-test writes into the artefact the gate is judging is an
# instrument measuring itself.
EXPIRED_BASELINE="${OSTLER_EXPIRED_BASELINE:-${REPO_ROOT}/tests/expired_deferrals_baseline.txt}"

# 🔴 `mktemp -t <template>` WITHOUT X's IS BSD-ONLY. GNU refuses it outright:
# "mktemp: too few X's in template". This gate ran `mktemp -t ostler-expired-refs`,
# so on every GNU host -- which is ubuntu-latest, where preflight runs on every
# PR -- the command failed, EXPIRED_REFS was EMPTY, and the ratchet compared an
# empty set against a 430-ref baseline and said nothing.
#
# MEASURED 2026-08-24, stubbing exactly that failure into PATH and changing
# nothing else, same shell, same GITHUB_REF_NAME=v1.0.44:
#
#     real mktemp        4 passed, 1 failed   <- ratchet FIRES
#     mktemp -t fails    5 passed, 0 failed   <- ratchet SILENT
#
# So the expiry half of the gate has never measured anything on the surface it
# runs on most, and fired only on the macOS cut job. Green on one surface, red
# on the other, identical input.
#
# Portable form, and a HARD CANNOT-RUN if the file cannot be made: an expired
# set that could not be written must never be read as "nothing expired".
_orphan_gate_tmpfile() {   # _orphan_gate_tmpfile <name> -> prints path, rc 1 on failure
    mktemp "${TMPDIR:-/tmp}/$1.XXXXXX" 2>/dev/null
}
EXPIRED_REFS="$(_orphan_gate_tmpfile ostler-expired-refs)" || {
    printf 'CANNOT-RUN: could not create the expired-refs scratch file under %s.\n' "${TMPDIR:-/tmp}" >&2
    printf '  The expiry ratchet has NOT run. That is not a pass -- it is a gate that could not look.\n' >&2
    exit 2
}
# Every ref is_deferred() is asked about, so the end of this run can subtract
# them from what the file DECLARES and name the deferrals that did nothing.
CONSULTED_REFS="$(_orphan_gate_tmpfile ostler-consulted-refs)" || {
    printf 'CANNOT-RUN: could not create the consulted-refs scratch file under %s.\n' "${TMPDIR:-/tmp}" >&2
    exit 2
}
trap 'rm -f "$CONSULTED_REFS" "$EXPIRED_REFS"' EXIT

red=0
expiry_ratchet_failed=0
warn=0
checked=0
unchecked=0          # declared unverifiable in THIS environment
unverifiable=0       # undeclared and unreachable -- fails closed
unchecked_labels=""

say()  { printf '%s\n' "$*"; }
bad()  { printf '  [RED]  %s\n' "$*" >&2; red=$((red + 1)); }

# Run gh with an EXPLICIT token when we resolved one, and with the AMBIENT
# environment when we did not.
#
# The previous form was `GH_TOKEN="$tok" gh ...` at both call sites, which
# looks equivalent and is not: when $tok is empty it exports GH_TOKEN as the
# empty string, and an empty GH_TOKEN does not mean "fall back", it means
# "unauthenticated". So the assignment intended to ADD credentials actively
# STRIPPED the ones the environment already had.
#
# Measured on the v1.0.22 cut (run 31478119136). `gh auth token -u <owner>`
# returns nothing on a hosted runner -- there is no `gh auth login` there --
# so every PR lookup ran unauthenticated and answered:
#
#   gh: To use GitHub CLI in a GitHub Actions workflow, set the GH_TOKEN
#       environment variable
#
# branch_landed() treats a failed lookup as "not landed", so that produced a
# RED naming a BRANCH for what was actually a missing credential. The branch
# it named did turn out to be genuinely unmerged, which is the dangerous part:
# a blind instrument returned the right answer, and would have been believed.
#
# The consequence worth spelling out: setting GH_TOKEN in the workflow would
# NOT have fixed this on its own. The script would have overwritten it.
gh_as() {
    local t="$1"; shift
    if [[ -n "$t" ]]; then GH_TOKEN="$t" gh "$@"; else gh "$@"; fi
}
note() { printf '  [warn] %s\n' "$*"; warn=$((warn + 1)); }
ok()   { printf '  [ok]   %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Deferrals. A ref listed here is a CONSCIOUS decision and does not fail the
# cut -- but it is always PRINTED, so nothing is ever silently absent.
# ---------------------------------------------------------------------------
is_deferred() {
    local ref="$1"
    # RECORD WHAT WAS ASKED. This lookup is one-directional: it answers "is this
    # ref deferred", and never "is this deferral reachable". A deferral for a ref
    # this gate can never generate is consumed by NOTHING and reports NOTHING, so
    # an inert hold reads exactly like a satisfied one. See the reverse sweep at
    # the end of this script, and CM051 #788 for the incident.
    printf '%s\n' "$ref" >> "$CONSULTED_REFS"
    [[ -f "$DEFERRALS_FILE" ]] || return 1
    grep -qE "^[[:space:]]*-?[[:space:]]*ref:[[:space:]]*[\"']?${ref}[\"']?[[:space:]]*$" \
        "$DEFERRALS_FILE"
}

# Read a deferral's reason, INCLUDING the YAML block-scalar form.
#
# This used to take only the text after `reason:` on that one line. For
# `reason: >-` -- which is how every substantial reason in this file is
# written, because they run to paragraphs -- that text is the literal string
# ">-", so the gate printed:
#
#     [warn] deferred: daemon:#312 -- >-
#
# MEASURED 2026-08-17 on this file: 21 of 594 refs rendered as a bare block
# scalar token, including the three daemon rows renewed for the v1.0.34 cut.
#
# That is not cosmetic. A deferral's whole justification is that the hold is
# a RECORDED DECISION rather than a silent absence, and the record is the
# reason text. Printing ">-" turns "this is deferred and here is why" into
# "this is deferred", which is the state the file exists to abolish. It also
# hides expiry instructions: the vault-state row's own text says the gate
# must speak up again at the next cut, and the gate was structurally unable
# to say it.
#
# Handles: same-line plain/quoted scalars (unchanged), and `>`, `>-`, `|`,
# `|-` followed by an indented block, folded onto one line for the warn
# output. Empty after the key is treated as a block too.
deferral_reason() {
    local ref="$1"
    awk -v want="$ref" '
        # NOTE: exit runs the END rule, where `collecting` would still be 1
        # and would flush a second time. Clearing it first is what makes this
        # print exactly once. (Caught by the printed output being duplicated.)
        function flush_block() {
            collecting = 0
            gsub(/[[:space:]]+/, " ", buf)
            sub(/^ /, "", buf); sub(/ $/, "", buf)
            print buf
            exit
        }
        # Collecting a block scalar: indented lines continue it, anything
        # at or left of the key indent ends it.
        collecting {
            if ($0 ~ /^[[:space:]]*$/) { buf = buf " "; next }
            match($0, /^[[:space:]]*/)
            if (RLENGTH > key_indent) {
                line = $0; gsub(/^[[:space:]]+/, "", line)
                # NO QUOTE STRIPPING HERE, and the asymmetry with the inline
                # arm below is the whole point. On an inline scalar the quotes
                # are YAML SYNTAX and must come off. Inside a block scalar they
                # are literal CONTENT, and stripping them rewrites the reason.
                #
                # Found in review, on the worst possible row: this cut renews
                # daemon:fix/vault-state-default-status-none, whose reason says
                # the bug was "degraded to status '' not 'none'". Stripped, the
                # gate printed "degraded to status not none" -- which states the
                # OPPOSITE of the defect. Measured over the whole file, 13 rows
                # rendered a reason that was not their reason.
                #
                # That is the same failure as printing the bare block marker,
                # only quieter: a mangled why still reads as an explanation.
                buf = buf " " line
                next
            }
            flush_block()
        }
        $0 ~ /ref:/ {
            line = $0; gsub(/.*ref:[[:space:]]*/, "", line)
            gsub(/["'"'"']/, "", line); gsub(/[[:space:]]*$/, "", line)
            cur = (line == want)
        }
        cur && /reason:/ {
            r = $0; gsub(/.*reason:[[:space:]]*/, "", r)
            gsub(/[[:space:]]*$/, "", r)
            if (r == ">-" || r == ">" || r == "|" || r == "|-" || r == "") {
                match($0, /^[[:space:]]*/); key_indent = RLENGTH
                collecting = 1; buf = ""
                next
            }
            # Strip ONE MATCHING OUTER PAIR, not every quote in the string.
            # The old gsub removed inner quotes too, so an inline reason
            # citing a value -- 'none', "do not do this" -- was printed
            # without them. Measured: 4 rows file-wide, and they are the
            # remainder of the same defect the block arm above carries a
            # comment about. Truncation-shaped rather than meaning-inverting,
            # but a reason is evidence and evidence is quoted.
            if ((substr(r, 1, 1) == "\"" && substr(r, length(r), 1) == "\"") ||
                (substr(r, 1, 1) == "'"'"'" && substr(r, length(r), 1) == "'"'"'")) {
                r = substr(r, 2, length(r) - 2)
            }
            print r; exit
        }
        END { if (collecting) flush_block() }
    ' "$DEFERRALS_FILE" 2>/dev/null
}

# until_cut is written on nearly every deferral and, until now, was read by
# NOTHING. is_deferred() matches on `ref:` alone, so a row saying "defer to
# v1.0.20" kept deferring at v1.0.21, v1.0.22 and v1.0.23. Every deferral in
# the file is, in practice, permanent.
#
# Reported and not enforced, deliberately, and the reason still holds -- but the
# NUMBER in it was an estimate and it was wrong by four times. Measured on a
# complete run at v1.0.43 (2026-08-24): 426 refs have expired, not "roughly a
# hundred", and only FOUR of them say v1.0.20 or earlier. Enforcing expiry would
# turn all 426 RED and block the cut outright, which is fixing the ledger by
# burning the release, so it stays advisory; making it blocking is a post-launch
# change once the backlog is worked down.
#
# It is no longer UNBOUNDED, which is the part that was actually wrong. See THE
# EXPIRY RATCHET near the end of this file: the expired set is baselined by ref,
# a NEW expiry fails, and a disappearing one prints "regenerate and commit".
deferral_until() {
    local ref="$1"
    awk -v want="$ref" '
        $0 ~ /ref:/ {
            line = $0; gsub(/.*ref:[[:space:]]*/, "", line)
            gsub(/["'"'"']/, "", line); gsub(/[[:space:]]*$/, "", line)
            cur = (line == want)
        }
        cur && /until_cut:/ {
            u = $0; gsub(/.*until_cut:[[:space:]]*/, "", u)
            gsub(/["'"'"']/, "", u); print u; exit
        }
    ' "$DEFERRALS_FILE" 2>/dev/null
}

# The version being cut, for expiry comparison only. GITHUB_REF_NAME is the
# tag on a tag-triggered run; empty elsewhere, in which case expiry is simply
# not evaluated rather than guessed at.
CUT_VERSION="${OSTLER_CUT_VERSION:-${GITHUB_REF_NAME:-}}"
expired_deferrals=0

# 🔴 WITHOUT A CUT VERSION, NOTHING CAN EXPIRE, AND THAT IS NOT THE SAME AS
# NOTHING HAVING EXPIRED.
#
# Every expiry comparison is `until_cut < CUT_VERSION`. With CUT_VERSION empty
# the numeric extraction yields nothing and no row can ever be expired, so the
# expired set is EMPTY BY CONSTRUCTION. The block that reports the ratchet then
# read that empty set as a measurement and printed
#
#     expiry ratchet: 0 expired now, 426 baselined, 6 repo(s) checked
#     426 baselined ref(s) no longer expire. Re-run with
#     --regenerate-expired-baseline and commit, so they cannot come back:
#
# on a run whose header said `6 repo(s) checked, 0 NOT CHECKED`, which is the
# most authoritative-looking run this script can produce. Taking that advice
# would have written a baseline containing nothing, deleted all 426 refs, and
# retired the ratchet completely -- and the existing regeneration guard would
# not have stopped it, because it only refuses when a repo went UNCHECKED.
#
# MEASURED 2026-08-24, driving the comparison in deferred_note directly with six
# real until_cut values and changing nothing but this variable:
#
#     CUT_VERSION=<empty>   expired 0 of 6
#     CUT_VERSION=v1.0.45   expired 4 of 6
#
# v1.0.27, v1.0.34, v1.0.41 and v1.0.20 expire against v1.0.45; v1.0.45 itself
# and v1.0.50 do not. So the zero is caused by the missing version and by nothing
# else, and the denominator is stated so the zero can be read.
#
# So: not evaluated is a THIRD state, and it is printed as one.
#
# A FUNCTION so it can be exercised without the four-minute six-repo scan, the
# same reason expiry_ratchet_sets is one. See
# tests/test_expiry_needs_a_cut_version.sh.
# expiry_is_evaluable <cut-version-string> -> rc 0 evaluable / 1 not.
# The brace-on-the-same-line, nothing-after-it shape is load-bearing: the test
# lifts this function out with a sed range anchored on `^expiry_is_evaluable() {$`.
expiry_is_evaluable() {
    local _v
    _v="$(printf '%s' "${1:-}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    [[ -n "$_v" ]]
}

if expiry_is_evaluable "${CUT_VERSION:-}"; then
    EXPIRY_EVALUABLE=1
else
    EXPIRY_EVALUABLE=0
fi

deferred_note() {
    local ref="$1" why="$2" until_v suffix=""
    until_v="$(deferral_until "$ref")"
    # Compare only the leading vX.Y.Z; several rows carry trailing prose such as
    # "v1.0.20 -- PRIORITY, first into the next wiki rebuild".
    local u_num c_num
    u_num="$(printf '%s' "${until_v:-}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    c_num="$(printf '%s' "${CUT_VERSION:-}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [[ -n "$u_num" && -n "$c_num" && "$u_num" != "$c_num" ]]; then
        # Expired iff until_cut sorts strictly BEFORE the version being cut.
        if [[ "$(printf '%s\n%s\n' "${u_num#v}" "${c_num#v}" | sort -V | head -1)" == "${u_num#v}" ]]; then
            suffix="  [EXPIRED: said ${u_num}, cutting ${c_num}]"
            expired_deferrals=$((expired_deferrals + 1))
            printf '%s\n' "$ref" >> "$EXPIRED_REFS"
        fi
    fi
    note "DEFERRED  ${ref} -- ${why}${suffix}"
}

report_orphan() {
    local ref="$1" detail="$2"
    if is_deferred "$ref"; then
        local why; why="$(deferral_reason "$ref")"
        deferred_note "$ref" "${why:-no reason recorded}"
    else
        bad "${ref}"
        printf '         %s\n' "$detail" >&2
        printf '         Merge it, or record the deferral in %s\n' \
            "$(basename "$DEFERRALS_FILE")" >&2
    fi
}

# ---------------------------------------------------------------------------
# ANCESTRY IS NOT LANDING. DO NOT REINTRODUCE `merge-base --is-ancestor` AS
# THE ANSWER TO "DID THIS BRANCH LAND".
#
# CM051 has allow_squash_merge=true. A squash merge creates a NEW commit, so
# the branch head is never reachable from main -- for a FULLY MERGED branch,
# forever. `ostler-ai/ostler-assistant` is rebase-merge-only, which has the
# same consequence. Measured 2026-08-11 against three merged CM051 PRs:
#
#     PR #559  merged   main..head ahead_by = 1   -> ancestry says "unmerged"
#     PR #556  merged   main..head ahead_by = 6   -> ancestry says "unmerged"
#     PR #555  merged   main..head ahead_by = 1   -> ancestry says "unmerged"
#
# The old predicate therefore produced SIX false REDs on the v1.0.19 preflight
# and `git fetch --prune` gave 15 before and 15 after: structural, not stale.
# The only sanctioned way past this gate is cut-deferrals.yaml, so a
# false-positive blocker asks the operator to attest to fifteen untrue things
# -- while its own error text says "Do NOT bypass this gate. Bypassing it is
# the habit it exists to stop." A broken blocker manufactures the habit it
# forbids. That is worse than no gate.
#
# Ancestry survives ONLY as a cheap pre-filter: if the branch IS an ancestor
# it certainly landed, so we can skip the network call. A non-ancestor proves
# nothing and must be escalated to PR merge state.
#
# Returns: 0 = landed (reason on stdout)
#          2 = an OPEN PR exists (the PR loop reports it; do not double-report)
#          1 = not landed, or could not be determined -- FAIL CLOSED
# ---------------------------------------------------------------------------
branch_landed() {
    local gh_repo="$1" path="$2" branch="$3" rev="$4" ship_sha="$5" tok="${6:-}" \
          pr_num="${7:-}"

    # `rev` and `branch` are DIFFERENT THINGS and conflating them cost an hour.
    #
    # `branch` is the NAME GitHub knows ("fix/foo") -- what `gh pr list --head`
    # needs. `rev` is something git can resolve HERE, which for a branch that
    # exists only on the remote is "origin/fix/foo". Passing the bare name as
    # the rev makes merge-base fail to resolve, which is indistinguishable from
    # "not an ancestor", which escalates to a PR lookup, which for a branch
    # pushed without a PR answers NONE -- a RED for work sitting on main.
    #
    # Measured while building this: four CM051 branches (fix/632-button-footer-
    # baseline, fix/install-grep-c-arith-leak, fix/strings-emdash-gate-green,
    # fix/wiki-pin-orphan-blob-lines-v1.0.3) are all ancestors of origin/main
    # and all four went RED on my first draft. A rewrite of a blocking gate can
    # introduce false positives just as easily as it removes them; that is what
    # the "remote-only branch that IS an ancestor" self-test case is for.
    if [[ -n "$rev" ]] && \
       git -C "$path" rev-parse --verify --quiet "${rev}^{commit}" >/dev/null && \
       git -C "$path" merge-base --is-ancestor "$rev" "$ship_sha"; then
        printf 'commits are ancestors of the shipping ref\n'; return 0
    fi

    # No repo or no gh means we CANNOT answer. Say so and fail closed; do not
    # let an unanswerable question read as "landed".
    if [[ -z "$gh_repo" ]] || ! command -v gh >/dev/null 2>&1; then
        return 1
    fi

    local js verdict num
    # NO 2>/dev/null. A usage error, an auth failure and a genuinely empty
    # result all look identical once stderr is discarded, and every one of
    # those reads as "no PR" -- which here means RED, but on the next edit
    # could just as easily mean GREEN. Fourth stderr-suppression incident of
    # 2026-08-10/11; the rule is now: never suppress a probe's stderr.
    #
    # When the caller resolved a PR NUMBER, ask about that number. `pr list
    # --head` matches on the branch name GitHub knows, and a `prN` mirror is
    # named after the PR, never after its head ref -- so the name lookup asks
    # a question with no possible answer and gets NONE, which reads as RED.
    # Measured 2026-08-15 on CM051: 0 of 105 `prN` mirrors carried a name
    # matching their PR's headRefName, so this limb was RED for all 105.
    if [[ -n "$pr_num" ]]; then
        if ! js="$(gh_as "$tok" pr view "$pr_num" --repo "$gh_repo" \
                     --json number,state,mergedAt 2>&1)"; then
            printf '  [warn] gh pr view failed for %s#%s: %s\n' \
                "$gh_repo" "$pr_num" "$(printf '%s' "$js" | head -1)" >&2
            return 1
        fi
        # Wrap the single object so the shared parser below sees a list.
        js="[${js}]"
    elif ! js="$(gh_as "$tok" pr list --repo "$gh_repo" --head "$branch" \
                 --state all --limit 20 --json number,state,mergedAt 2>&1)"; then
        printf '  [warn] gh pr list failed for %s#%s: %s\n' \
            "$gh_repo" "$branch" "$(printf '%s' "$js" | head -1)" >&2
        return 1
    fi

    verdict="$(printf '%s' "$js" | python3 -c '
import json,sys
try:
    prs = json.load(sys.stdin)
except Exception:
    sys.exit(3)
merged = [p for p in prs if p.get("mergedAt")]
if merged:
    p = merged[0]; print("MERGED %s %s" % (p["number"], p["mergedAt"])); raise SystemExit
op = [p for p in prs if p.get("state") == "OPEN"]
if op:
    print("OPEN %s" % op[0]["number"]); raise SystemExit
if prs:
    print("CLOSED %s" % prs[0]["number"]); raise SystemExit
print("NONE")
')" || { printf '  [warn] unparseable gh output for %s\n' "$branch" >&2; return 1; }

    case "$verdict" in
        MERGED*)
            printf 'PR #%s merged %s\n' "$(awk '{print $2}' <<<"$verdict")" \
                                        "$(awk '{print $3}' <<<"$verdict")"
            return 0 ;;
        OPEN*)
            printf 'open PR #%s\n' "$(awk '{print $2}' <<<"$verdict")"
            return 2 ;;
        CLOSED*)
            # A closed-unmerged PR is normally real orphaned work. The one
            # honest exception is a REPLACEMENT merge: #542 was closed, and
            # main carries 4467e49 "(replaces #542) (#543)". The content
            # landed by another route, and the convention is machine-readable.
            num="$(awk '{print $2}' <<<"$verdict")"
            local hit
            hit="$(git -C "$path" log --extended-regexp \
                      --grep="replaces #${num}([^0-9]|\$)" \
                      --format='%h %s' "$ship_sha" 2>/dev/null | head -1)"
            if [[ -n "$hit" ]]; then
                printf 'PR #%s closed but replaced on the shipping ref: %s\n' "$num" "$hit"
                return 0
            fi
            return 1 ;;
        *)
            return 1 ;;
    esac
}

# Report a branch UNLESS it is deferred, or it demonstrably landed, or an open
# PR already covers it. Every outcome is PRINTED -- silence is the bug this
# gate exists to stop, so "landed" is stated, not assumed.
maybe_orphan_branch() {
    local ref="$1" branch="$2" rev="$3" detail="$4" \
          gh_repo="$5" path="$6" ship_sha="$7" tok="${8:-}" pr_num="${9:-}"

    if is_deferred "$ref"; then
        local why; why="$(deferral_reason "$ref")"
        deferred_note "$ref" "${why:-no reason recorded}"
        return
    fi

    local why rc
    why="$(branch_landed "$gh_repo" "$path" "$branch" "$rev" "$ship_sha" "$tok" \
             "$pr_num")"; rc=$?
    case "$rc" in
        0) ok "${ref}: landed -- ${why}" ; return ;;
        2) ok "${ref}: ${why} -- reported once, by the PR check below" ; return ;;
    esac

    bad "${ref}"
    printf '         %s\n' "$detail" >&2
    printf '         Merge it, or record the deferral in %s\n' \
        "$(basename "$DEFERRALS_FILE")" >&2
}

# ---------------------------------------------------------------------------
# 1 + 2 + 3: per-repo branch and PR checks.
#   $1 repo label   $2 checkout path   $3 shipping ref   $4 gh "owner/name" ("" to skip PRs)
# ---------------------------------------------------------------------------
check_repo() {
    local label="$1" path="$2" ship_ref="$3" gh_repo="${4:-}"

    # An unverifiable repo is a FAILURE, not a note.
    #
    # On the v1.0.16 cut this gate printed "4 repo(s) checked" and went GREEN
    # while CM044 and the daemon were both silently skipped -- their *_DIR
    # variables defaulted to the empty string, so "$path/.git" was "/.git" and
    # the -d test simply failed. The daemon was 162 commits ahead of its own
    # origin/main at the time and nothing said a word. That is the same shape
    # as the ships-dark writer bug: the check exists, reports success, and
    # inspects nothing.
    #
    # If a repo genuinely is not on this machine, say so explicitly via
    # OSTLER_ORPHAN_GATE_SKIP="label1,label2" -- a deliberate, visible act.
    if [[ -z "$path" ]]; then
        if [[ ",${OSTLER_ORPHAN_GATE_SKIP:-}," == *",${label},"* ]]; then
            # COUNT IT. This branch used to return without touching a counter,
            # so a repo declared-skipped AND carrying an empty path vanished
            # from the coverage line altogether: the summary printed
            # "0 NOT CHECKED" while this repo had, in fact, not been checked.
            #
            # MEASURED on two arms differing only in how the same operator act
            # was spelled, everything else identical (0 checked, 0 orphaned,
            # 1 warning):
            #     ghost with EMPTY path         -> "0 NOT CHECKED"
            #     ghost with unresolvable path  -> "1 NOT CHECKED"
            # One declaration, two coverage figures. The zero is the dangerous
            # one, because a zero here reads as complete coverage rather than as
            # a repo nobody looked at.
            #
            # It also fed the --regenerate-expired-baseline refusal further
            # down, which guards on `unchecked -gt 0`. An all-empty-path run
            # looked like FULL coverage to that guard and would have been
            # allowed to overwrite the baseline from a run that saw nothing --
            # the precise thing that refusal exists to prevent.
            note "${label}: NOT CHECKED HERE (declared in OSTLER_ORPHAN_GATE_SKIP, no path configured)"
            unchecked_labels="${unchecked_labels}${unchecked_labels:+, }${label}"
            unchecked=$((unchecked + 1))
            return
        fi
        bad "${label}: no checkout path configured -- cannot verify"
        printf '         Set %s_DIR (or cut.env), or skip deliberately with\n' "$label" >&2
        printf '         OSTLER_ORPHAN_GATE_SKIP=%s\n' "$label" >&2
        return
    fi

    # `.git` is a FILE, not a directory, inside a git worktree. Testing for a
    # directory makes this gate worktree-blind (same defect as #649), so ask
    # git itself rather than guessing at the layout.
    if ! git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
        if [[ ",${OSTLER_ORPHAN_GATE_SKIP:-}," == *",${label},"* ]]; then
            note "${label}: NOT CHECKED HERE (declared in OSTLER_ORPHAN_GATE_SKIP)"
            unchecked_labels="${unchecked_labels}${unchecked_labels:+, }${label}"
            unchecked=$((unchecked + 1))
            return
        fi
        # "I could not look" is NOT "there is abandoned work", and this line
        # used to say the second while meaning the first.
        #
        # On the v1.0.22 cut every one of CM044, CM041, CM059, CM031 and the
        # daemon reported here, because their default paths are $HOME/Developer
        # and $HOME/Documents/Projects -- the OPERATOR's Mac. On a hosted
        # runner $HOME is /Users/runner and none of them can exist. The gate
        # then printed five [RED]s and "6 orphaned", which reads as six
        # abandoned fixes and was in fact one real finding plus five absent
        # directories.
        #
        # That is the shape this whole gate exists to prevent, turned inward:
        # a check reporting a verdict it never measured. It is also why
        # check-orphans could never have passed in hosted CI on any tag --
        # a hard gate encoding an environmental assumption
        # (feedback_dont_invent_environmental_facts_in_hard_gates).
        #
        # Still fails closed when UNDECLARED: silence is the bug, and an
        # unreachable repo nobody has thought about is exactly the silence.
        # Declaring it in OSTLER_ORPHAN_GATE_SKIP is a conscious "this
        # environment cannot see this repo", the same contract as a deferral.
        bad "${label}: CANNOT VERIFY -- ${path} is not a git checkout here"
        printf '         This is NOT a finding of orphaned work. Nothing was measured.\n' >&2
        printf '         Point %s_DIR at a checkout, or declare it unverifiable in\n' "$label" >&2
        printf '         this environment with OSTLER_ORPHAN_GATE_SKIP=%s\n' "$label" >&2
        unverifiable=$((unverifiable + 1))
        return
    fi
    checked=$((checked + 1))
    say ""
    say "-- ${label} (${ship_ref})"
    # Per-repo, because the closing "nothing orphaned" line used to read the
    # GLOBAL counter: once ANY repo went red, no later clean repo could ever
    # say it was clean. Cosmetic, but it is the same class of bug as the rest
    # of this file -- a status line that does not describe what it names.
    local red_at_entry="$red"

    # Per-repo credentials. The cut spans TWO GitHub accounts (andygmassey
    # owns CM0xx, ostler-ai owns the daemon), and `gh auth switch` is GLOBAL --
    # whichever account is active, the other account's repos answer 404
    # "Repository not found", which reads like a permissions bug.
    #
    # On the first honest run of this gate that is exactly what happened:
    # switching to ostler-ai so the daemon could be checked made CM044, CM041,
    # CM031 and CM059 all report "fetch failed; results may be stale". A gate
    # whose answer depends on ambient shell state is not a gate.
    #
    # So resolve the token for the repo's OWNER and use it explicitly.
    local _owner="" _tok="" _auth="" _tok_src=""
    _owner="${gh_repo%%/*}"

    # 1. AN EXPLICIT PER-OWNER TOKEN, highest precedence.
    #
    # A hosted runner has no `gh auth login`, so the per-owner lookup below
    # finds nothing and the fallback is the workflow's own GITHUB_TOKEN, which
    # is scoped to the repo the workflow runs in. `ostler-ai/ostler-assistant`
    # is a DIFFERENT ORG, so that listing could never succeed and the limb went
    # CANNOT VERIFY on every cut. It is not enough to set GH_TOKEN in the
    # workflow -- one token cannot be right for four owners at once, and the
    # cut repo's own limb needs the repo-scoped one.
    #
    # So: name the owner in the variable. `ostler-ai` -> OSTLER_AI.
    #     OSTLER_ORPHAN_GATE_TOKEN_OSTLER_AI
    #     OSTLER_ORPHAN_GATE_TOKEN_ANDYGMASSEY
    # Anything not [A-Za-z0-9] becomes `_`, uppercased. Absent means "fall
    # through", never "use a token that cannot reach here".
    if [[ -n "$_owner" ]]; then
        local _ovar
        _ovar="OSTLER_ORPHAN_GATE_TOKEN_$(printf '%s' "$_owner" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"
        _ovar="${_ovar%_}"
        _tok="${!_ovar:-}"
        [[ -n "$_tok" ]] && _tok_src="$_ovar"
    fi

    # 2. A LOCAL `gh auth login` for that owner.
    if [[ -z "$_tok" ]] && [[ -n "$_owner" ]] && command -v gh >/dev/null 2>&1; then
        _tok="$(gh auth token -u "$_owner" 2>/dev/null || true)"
        [[ -n "$_tok" ]] && _tok_src="gh auth token -u ${_owner}"
    fi
    # On a hosted runner there is no `gh auth login`, so the per-owner lookup
    # above returns nothing and the ONLY credential available is the workflow's
    # own. Fall back to it. It reaches THIS repo and no other -- a repo-scoped
    # GITHUB_TOKEN cannot read a sibling repo even under the same owner -- so
    # this makes the cut repo's own PR check work in CI and changes nothing for
    # the siblings, which is exactly the true division of what CI can see.
    if [[ -z "$_tok" ]]; then
        _tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
        [[ -n "$_tok" ]] && _tok_src="workflow GITHUB_TOKEN (repo-scoped)"
    fi

    _timeout=""; command -v gtimeout >/dev/null 2>&1 && _timeout="gtimeout 30"
    # WHETHER THE FETCH SUCCEEDED DECIDES WHAT THE REFS MEAN, so it is recorded
    # rather than only mentioned.
    #
    # This fetch carries --prune, so on success a branch deleted upstream loses
    # its remote-tracking ref and cannot be reported as unmerged work. That is
    # why #526's premise -- "prune before the gate" -- is already satisfied on
    # the happy path, and why a stale-ref cross-check there would be solving a
    # problem the fetch has already solved.
    #
    # THE HAZARD IS THE FAILURE PATH. When the fetch fails, this used to emit a
    # note() -- a WARN, which cannot fail the gate -- and then read the stale
    # cache anyway, reporting its contents as findings. Every remote-branch
    # verdict below is then derived from refs that may be arbitrarily old:
    # branches long since merged and deleted still appear as orphans, and
    # branches created since are invisible. A warn bucket is not a safe bucket.
    local _fetched=1
    if [[ -n "$_tok" ]]; then
        # base64 wraps at 76 columns on macOS; an embedded newline corrupts the
        # header and the fetch fails in a way that looks like a bad token.
        _auth="$(printf 'x-access-token:%s' "$_tok" | base64 | tr -d '\n')"
        $_timeout git -c "http.extraheader=AUTHORIZATION: basic ${_auth}" \
            -C "$path" fetch -q origin --prune 2>/dev/null || _fetched=0
    else
        $_timeout git -C "$path" fetch -q origin --prune 2>/dev/null || _fetched=0
    fi
    if [[ "$_fetched" -eq 0 ]]; then
        bad "${label}: CANNOT VERIFY -- git fetch --prune FAILED, so refs/remotes/origin is a cache of unknown age"
        printf '         Every remote-branch verdict for %s would be derived from\n' "$label" >&2
        printf '         those refs. A branch merged and deleted upstream still looks\n' >&2
        printf '         unmerged here, and one created since is invisible. This is NOT\n' >&2
        printf '         a finding of orphaned work and it is NOT a pass.\n' >&2
        printf '         Fix the network or the credentials and re-run. To proceed with\n' >&2
        printf '         the blindness DECLARED, name the repo in OSTLER_ORPHAN_GATE_SKIP.\n' >&2
        unverifiable=$((unverifiable + 1))
        return
    fi

    local ship_sha
    ship_sha="$(git -C "$path" rev-parse --verify "$ship_ref" 2>/dev/null)" || {
        bad "${label}: shipping ref '${ship_ref}' does not resolve"
        return
    }

    # -- 3. LOCAL-ONLY branches (the #632 class) ----------------------------
    #
    # "No remote-tracking ref" does NOT mean "never pushed". Every repo here
    # has delete_branch_on_merge, so the remote branch is REMOVED at merge and
    # the local one is left behind. Four of the six false REDs on 2026-08-11
    # were exactly this: merged work described as "One rm -rf from gone".
    # branch_landed() settles it against PR merge state.
    #
    # A local branch named `prN` or `prNmerge` is NOT work. It is a mirror of
    # `refs/pull/N/head` (or `/merge`) left behind by a fetch refspec such as
    # `refs/pull/*/head:refs/heads/pr*`. GitHub holds those refs permanently,
    # so the content cannot be lost and there is nothing to push.
    #
    # Two separate defects came out of treating them as branches, and BOTH
    # were measured on CM051 on 2026-08-15 with 105 such mirrors present:
    #
    #   1. The lookup could not answer. `pr list --head pr632` matches on the
    #      name GitHub knows, and a mirror is named for the PR NUMBER, never
    #      for its head ref. 0 of 105 mirror names matched their PR's real
    #      headRefName, so every one answered NONE and every one went RED.
    #
    #   2. The KEY could not match a deferral. This limb emitted `CM051:pr632`
    #      while every deferral for that work is recorded as `CM051:#632` --
    #      67 such rows existed and not one could ever be consulted, because
    #      no deferral in the file uses the `prN` spelling.
    #
    # So 105 of 112 REDs were the gate misreading its own fetch artefacts. A
    # permanently-RED blocking gate is worse than no gate: the only sanctioned
    # way past it is a deferral, so it asks the operator to attest to a
    # hundred untrue things, which is the exact habit it exists to stop.
    #
    # Normalising to the PR number fixes both at once -- the number is what
    # the deferral file already keys on, and what `pr view` can answer.
    local b
    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        [[ "$b" == "HEAD" ]] && continue
        if ! git -C "$path" show-ref -q --verify "refs/remotes/origin/$b" 2>/dev/null; then
            local n; n="$(git -C "$path" rev-list --count "${ship_sha}..$b" 2>/dev/null || echo '?')"
            local key="${label}:${b}" pr_num="" detail
            detail="LOCAL-ONLY branch, no remote ref and no merged PR, ${n} commit(s) not in ${ship_ref}. One rm -rf from gone."
            if [[ "$b" =~ ^pr([0-9]+)(merge)?$ ]]; then
                pr_num="${BASH_REMATCH[1]}"
                key="${label}:#${pr_num}"
                detail="local mirror of refs/pull/${pr_num}/ -- PR #${pr_num} is neither merged nor open, ${n} commit(s) not in ${ship_ref}."
            fi
            maybe_orphan_branch "$key" "$b" "$b" "$detail" \
                "$gh_repo" "$path" "$ship_sha" "$_tok" "$pr_num"
        fi
    done < <(git -C "$path" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)

    # -- 2. remote fix/feat branches not in the shipping ref ----------------
    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        local short="${b#origin/}"
        [[ "$short" == "HEAD" || "$short" == "main" || "$short" == "master" ]] && continue
        case "$short" in
            fix/*|hotfix/*|feat/*|feature/*) ;;
            *) continue ;;
        esac
        local n; n="$(git -C "$path" rev-list --count "${ship_sha}..$b" 2>/dev/null || echo '?')"
        maybe_orphan_branch "${label}:${short}" "$short" "$b" \
            "unmerged branch, ${n} commit(s) not in ${ship_ref}" \
            "$gh_repo" "$path" "$ship_sha" "$_tok"
    done < <(git -C "$path" for-each-ref --format='%(refname:short)' refs/remotes/origin 2>/dev/null)

    # -- 1. OPEN PRs, drafts included ---------------------------------------
    # PER-LABEL, same grammar as OSTLER_ORPHAN_GATE_SKIP above.
    #
    # It used to be `[[ -n ... ]]` -- a global boolean -- while its sibling on
    # the CHECKOUT axis took a comma list of labels. So "skip the daemon" was
    # expressible on one axis and not the other, and an operator facing the
    # daemon's cross-org CANNOT VERIFY had two choices: leave it undeclared and
    # keep a red cut, or set the boolean and silence the open-PR limb for EVERY
    # repo -- including the one the cut is being made FROM. That is the option
    # someone reaches for under cut pressure, and it aims the blindness at the
    # repo that matters most. See #1166.
    #
    # The three legacy blanket values still work, because tests and habits
    # depend on them, but they now NAME what they silenced instead of doing it
    # quietly. Anything else is read as a comma-separated label list.
    local _pr_skip="" _pr_skip_why=""
    if [[ ",${OSTLER_ORPHAN_GATE_SKIP_PR:-}," == *",${label},"* ]]; then
        _pr_skip=1; _pr_skip_why="declared for ${label} in OSTLER_ORPHAN_GATE_SKIP_PR"
    else
        case "${OSTLER_ORPHAN_GATE_SKIP_PR:-}" in
            1|true|all)
                _pr_skip=1
                _pr_skip_why="BLANKET (OSTLER_ORPHAN_GATE_SKIP_PR=${OSTLER_ORPHAN_GATE_SKIP_PR}) -- this silences the open-PR limb for EVERY repo, including ${label}. Name labels instead: OSTLER_ORPHAN_GATE_SKIP_PR=${label}" ;;
        esac
    fi
    if [[ -n "$_pr_skip" ]]; then
        note "${label}: PR check SKIPPED -- ${_pr_skip_why}"
    elif [[ -n "$gh_repo" ]] && command -v gh >/dev/null 2>&1; then
        local prs pr_rc pr_err
        # GH_TOKEN for the repo's OWNER, not whichever account `gh auth switch`
        # last left active -- see the fetch block above for why that matters.
        #
        # 🔴 NO `2>/dev/null`, AND THE EXIT CODE IS KEPT. Until 2026-08-27 this
        # read `... 2>/dev/null) || prs=""`, which did three harmful things at
        # once:
        #
        #   1. THREW AWAY THE ERROR. The branch below could then only GUESS at
        #      the cause -- its message literally said "(auth/billing?)". The
        #      one string that would have named it was discarded on the way.
        #   2. COLLAPSED FAILURE INTO ABSENCE. A cross-org 404, an expired
        #      token, a billing stop and a repo with genuinely zero open PRs
        #      all produced the same empty string. "Found nothing" and "could
        #      not look" printed identically, which is the whole family of
        #      defect this gate exists to close.
        #   3. FED note(), NOT bad(). note() increments `warn`, and `warn` is
        #      NEVER CONSULTED in the exit block -- measured: exit reads
        #      `red`, `checked`, `expiry_ratchet_failed` and `unchecked`, and
        #      nothing else. So the gate printed a [warn], carried on, and --
        #      because `red` had not moved -- ended the repo with
        #      `ok "<label>: nothing orphaned"` and the run with
        #      "GREEN: every written fix is either shipping or consciously
        #      deferred." It ASSERTED a clean result for a repo whose open PRs
        #      it had never listed.
        #
        # This file already states the correct rule 190 lines up: "An
        # unverifiable repo is a FAILURE, not a note." The PR limb was the one
        # place that did not follow it. Routing to bad() + `unverifiable` also
        # suppresses the per-repo "nothing orphaned" line for free, because
        # that line is guarded on `red` not having moved.
        #
        # DELIBERATE ESCAPE HATCH, ALREADY PRESENT: a runner that genuinely
        # cannot authenticate sets OSTLER_ORPHAN_GATE_SKIP_PR and gets the
        # SKIP branch above. That is a DECLARED blindness, which is honest.
        # An undeclared one is not.
        pr_err="$(mktemp)"
        prs="$(gh_as "${_tok:-}" pr list --repo "$gh_repo" --state open --limit 100 \
                 --json number,title,headRefName,isDraft 2>"$pr_err")"; pr_rc=$?
        if [[ "$pr_rc" -ne 0 ]]; then
            bad "${label}: CANNOT VERIFY -- listing open PRs for ${gh_repo} FAILED (exit ${pr_rc})"
            printf '         This is NOT a finding of orphaned work, and it is NOT a pass.\n' >&2
            printf '         The open-PR limb did not run, so nothing here says whether\n' >&2
            printf '         %s has unmerged work outside this cut.\n' "$gh_repo" >&2
            printf '         gh said:\n' >&2
            sed 's/^/           /' "$pr_err" >&2
            printf '         Fix the credentials, or declare the blindness with\n' >&2
            printf '         OSTLER_ORPHAN_GATE_SKIP_PR=1 -- do not leave it undeclared.\n' >&2
            unverifiable=$((unverifiable + 1))
            rm -f "$pr_err"
            return
        fi
        rm -f "$pr_err"
        # `[]` is a SUCCESSFUL listing of zero open PRs -- a real measurement,
        # and distinguishable from the failure above only because the exit
        # code is now kept.
        #
        # 🔴 BUT AN EMPTY LIST IS THE ONE ANSWER A BLIND TOKEN CAN ALSO PRODUCE.
        # `gh pr list` exits 0 with `[]` for a repo it can see and that has no
        # open PRs. Some auth failures raise and are caught above; a token that
        # resolves but cannot read pull requests can return an empty page
        # instead. Zero-with-no-error is therefore the shape a silent auth
        # regression wears, and it is the shape that reads as a clean pass.
        #
        # POSITIVE CONTROL, and it asks the RIGHT question. The first version
        # asked "has this repo ever had a PR" -- which rejected six legitimate
        # zero-PR fixtures in orphan_gate_selftest.sh, because "no PRs ever" is
        # a real state and not evidence of blindness. What actually
        # distinguishes blind from empty is whether the token can SEE THE REPO
        # AT ALL. So: read the repo's own metadata with the SAME token. If that
        # fails, the empty list measured nothing. If it succeeds, the zero is
        # real, however boring the repo.
        #
        # Runs ONLY on an empty list, so it costs one extra call in the one
        # case that is ambiguous, and none otherwise.
        local _pr_n
        _pr_n="$(printf '%s' "${prs:-[]}" | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(-1)' 2>/dev/null || printf '%s' -1)"
        # ENABLED BY THE CALLER, and deliberately so. The gate's own fixtures
        # in scripts/orphan_gate_selftest.sh use synthetic repos that no token
        # can read; running the control against them turns eight legitimately
        # GREEN arms red, which would make this change a net loss. The hazard
        # it guards -- a cross-org listing that returns an empty page instead
        # of an error -- exists on the CUT, so the cut turns it on. Off means
        # "not asked", and the zero is reported exactly as it was before.
        if [[ "${_pr_n:-0}" -eq 0 && -n "${OSTLER_ORPHAN_GATE_PR_CONTROL:-}" ]]; then
            local ctl ctl_rc ctl_err
            ctl_err="$(mktemp)"
            # 🔴 THE CONTROL MUST EXERCISE THE SUBJECT'S PERMISSION, NOT MERELY
            # SHARE ITS TOKEN.
            #
            # v1 of this control read `repos/{owner}/{repo}`. That needs
            # Metadata: read. The subject, `gh pr list`, needs Pull requests:
            # read. On a fine-grained PAT Metadata is MANDATORY for any repo
            # access at all, so a token with metadata and no pull-requests
            # permission PASSED the control and returned `[]` -- precisely the
            # false green the control exists to stop. Sharing a token is not
            # sharing a scope, and a control that can succeed for a reason the
            # subject cannot is not a control. Board #522.
            #
            # `/pulls` needs the SAME permission the subject needs. And the
            # discriminator is the HTTP STATUS, not the array length: 200 with
            # `[]` means "allowed to look, nothing there" -- a real zero for a
            # repo that has never had a PR -- while 403/404 means "not allowed
            # to look", which is what `gh` exits non-zero on. So this does not
            # require the repo to have PRs, only that the token may ask.
            ctl="$(gh_as "${_tok:-}" api "repos/${gh_repo}/pulls?state=all&per_page=1" 2>"$ctl_err")"; ctl_rc=$?
            if [[ "$ctl_rc" -ne 0 ]]; then
                bad "${label}: CANNOT VERIFY -- open-PR list was empty AND the token cannot read pull requests on ${gh_repo}"
                printf '         An empty list and a blind token look identical, so the\n' >&2
                printf '         control asks the pulls endpoint with the SAME token AND\n' >&2
                printf '         the SAME permission the listing needs (Pull requests:\n' >&2
                printf '         read). It was refused, so the listing did not measure\n' >&2
                printf '         zero open PRs -- it measured nothing.\n' >&2
                printf '         A repo-metadata probe would NOT have caught this: on a\n' >&2
                printf '         fine-grained PAT, Metadata is mandatory for any access\n' >&2
                printf '         and is granted by tokens that cannot read PRs at all.\n' >&2
                printf '         token source: %s\n' "${_tok_src:-none}" >&2
                [[ -s "$ctl_err" ]] && { printf '         gh said:\n' >&2; sed 's/^/           /' "$ctl_err" >&2; }
                printf '         Give this owner a token that can read it:\n' >&2
                printf '           OSTLER_ORPHAN_GATE_TOKEN_%s\n' \
                    "$(printf '%s' "${_owner}" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_' | sed 's/_$//')" >&2
                unverifiable=$((unverifiable + 1))
                rm -f "$ctl_err"
                return
            fi
            rm -f "$ctl_err"
            note "${label}: zero open PRs, and the pulls endpoint answered with the same token AND permission -- a real zero (token: ${_tok_src:-none})"
        fi
        if [[ "${_pr_n:-0}" -gt 0 ]]; then
            local line
            while IFS=$'\t' read -r num title head draft; do
                [[ -z "${num:-}" ]] && continue
                git -C "$path" merge-base --is-ancestor "origin/$head" "$ship_sha" 2>/dev/null \
                    && continue
                local tag="OPEN PR"
                [[ "$draft" == "true" ]] && tag="OPEN **DRAFT** PR"
                report_orphan "${label}:#${num}" \
                    "${tag} '${title}' (head ${head}) is NOT in ${ship_ref}"
            done < <(printf '%s' "$prs" | python3 -c '
import json,sys
for p in json.load(sys.stdin):
    print("\t".join([str(p["number"]), p["title"].replace("\t"," "),
                     p["headRefName"], str(p["isDraft"]).lower()]))
' 2>/dev/null)
        fi
    elif [[ -n "$gh_repo" ]]; then
        # Same reasoning as the auth failure above: a missing `gh` means the
        # limb DID NOT RUN. It was a note(), and note() cannot fail the gate.
        bad "${label}: CANNOT VERIFY -- gh is not installed, open-PR limb NOT run"
        printf '         Nothing was measured about unmerged PRs in %s.\n' "$gh_repo" >&2
        printf '         Install gh, or declare it with OSTLER_ORPHAN_GATE_SKIP_PR=1.\n' >&2
        unverifiable=$((unverifiable + 1))
        return
    fi

    # -- 4. dirty tree -------------------------------------------------------
    if [[ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]]; then
        report_orphan "${label}:working-tree" \
            "uncommitted or untracked changes in the cut checkout"
    fi

    [[ "$red" -eq "$red_at_entry" ]] && ok "${label}: nothing orphaned"
}

# ---------------------------------------------------------------------------
say "== verify_no_orphaned_fixes: is any FIX written but not shipping? =="
[[ -f "$DEFERRALS_FILE" ]] \
    && say "   deferrals: $(basename "$DEFERRALS_FILE")" \
    || say "   deferrals: none recorded"

# cut.env names every input; source it so this gate and the cut agree.
if [[ -f "${REPO_ROOT}/cut.env" ]]; then
    set -a; . "${REPO_ROOT}/cut.env"; set +a
fi

# Repo set. Injectable so the gate is testable in isolation and so an
# operator can narrow a run: OSTLER_ORPHAN_GATE_REPOS="label|path|ref|ghrepo;..."
if [[ -n "${OSTLER_ORPHAN_GATE_REPOS:-}" ]]; then
    IFS=';' read -ra _entries <<< "$OSTLER_ORPHAN_GATE_REPOS"
    for _e in "${_entries[@]}"; do
        [[ -z "$_e" ]] && continue
        IFS='|' read -r _l _p _r _g <<< "$_e"
        check_repo "${_l}" "${_p}" "${_r:-origin/main}" "${_g:-}"
    done
else
check_repo "CM051" "$REPO_ROOT" "origin/main" "andygmassey/CM051-Home-Hub-Installer"
check_repo "CM044" "${CM044_DIR:-$HOME/Developer/CM044-PWG-Personal-Wiki}" "origin/main" "andygmassey/CM044-PWG-Personal-Wiki"
check_repo "CM041" "${CM041_DIR:-$HOME/Developer/cm041-fresh}" "origin/main" "andygmassey/CM041-People-Graph"
check_repo "CM059" "${CM059_DIR:-$HOME/Documents/Projects/CM059 - Ostler Editor}" "origin/main" "andygmassey/CM059-Ostler-Editor"
check_repo "CM031" "${CM031_DIR:-$HOME/Documents/Projects/CM031 - PWG Companion}" "origin/main" "andygmassey/CM031-PWG-Companion"
check_repo "daemon" "${OSTLER_ASSISTANT_DIR:-$HOME/Developer/ostler-assistant}" "origin/main" "ostler-ai/ostler-assistant"
fi

say ""
say "== summary: ${checked} repo(s) checked, ${red} orphaned, ${warn} warning(s), ${unchecked} NOT CHECKED =="

# A gate that goes quiet about its own coverage gets read as covering
# everything. Name the unchecked repos every run, not only when something is
# wrong -- a green line saying "5 repos not checked" is the whole point.
# ---------------------------------------------------------------------------
# THE EXPIRY RATCHET
#
# Expiry is still not blocking, and the reason is unchanged and correct: the
# backlog is large enough that switching it on would fail the cut outright,
# which is fixing the ledger by burning the release.
#
# What HAS changed is that "not blocking" used to mean "unbounded". The number
# could grow every cut and the only signal was a line of advisory output nobody
# had to act on. A ratchet costs nothing, blocks no cut that was going to pass,
# and makes the debt monotonic.
#
# MEASURED 2026-08-24, cutting v1.0.43, a COMPLETE run: 6 repos checked, 0 NOT
# CHECKED, 461 deferrals consulted, 426 distinct refs EXPIRED.
#
#   326 said v1.0.27   87 said v1.0.34   4 said v1.0.41
#     4 said v1.0.39    4 said v1.0.18   1 said v1.0.40
#
#   daemon 131   CM051 102   CM031 71   CM044 55   CM041 45   CM059 22
#
# The old comment above this block said "roughly a hundred rows currently carry
# an until_cut at or before v1.0.20". Measured: FOUR say v1.0.20 or earlier, and
# 426 have expired in total. The estimate was low by a factor of four and named
# the wrong version, which matters because it is the stated reason enforcement
# is off, and a reason nobody can check is a reason that stops being read.
#
# READ THE DENOMINATOR BEFORE QUOTING ANY OF THIS. cut-deferrals.yaml carries
# 634 until_cut values; the gate only CONSULTS a deferral when it has an orphan
# to explain, so 461 is the population here, not 634. Both numbers are true of
# different things and they are not interchangeable.
#
# And take the number from a run that FINISHED. This one takes about four
# minutes because it makes a network call per ref, and a partially written log
# read mid-flight gave 103 expired against a real 426 -- a four-fold
# under-count that looked entirely plausible.
#
# THE BASELINE IS A LIST, NOT A COUNT. A count cannot see a swap: fix one,
# add one, and the total is unchanged while a new deferral has quietly gone
# past its deadline.
if [[ "$expired_deferrals" -gt 0 ]]; then
    say ""
    say "   ${expired_deferrals} deferral(s) are marked [EXPIRED]: their until_cut named a"
    say "   version older than the one being cut, so they are still deferring past"
    say "   their own stated deadline. Not blocking (yet). Work them down."
fi

# The comparison, as a function, so it can be tested in a second instead of the
# four minutes a full run costs. A ratchet that can only be exercised by the
# thing it lives inside is a ratchet nobody exercises.
#
# Usage: expiry_ratchet_sets <current-sorted> <baseline> <out-new> <out-gone>
# Returns 0 always; the caller decides what a non-empty <out-new> means.
expiry_ratchet_sets() {
    local current="$1" baseline="$2" out_new="$3" out_gone="$4"
    local base_clean="${out_new}.base"
    if [[ -f "$baseline" ]]; then
        grep -v '^[[:space:]]*#' "$baseline" 2>/dev/null \
            | grep -v '^[[:space:]]*$' \
            | sort -u > "$base_clean" || : > "$base_clean"
    else
        : > "$base_clean"
    fi
    # comm needs both sides sorted with the same collation. LC_ALL is pinned
    # because sort -u above and sort -u at the call site must agree, and a
    # locale difference between them produces a silent phantom diff.
    LC_ALL=C comm -23 <(LC_ALL=C sort -u "$current") <(LC_ALL=C sort -u "$base_clean") > "$out_new"
    LC_ALL=C comm -13 <(LC_ALL=C sort -u "$current") <(LC_ALL=C sort -u "$base_clean") > "$out_gone"
}

sort -u "$EXPIRED_REFS" 2>/dev/null > "${EXPIRED_REFS}.sorted" || : > "${EXPIRED_REFS}.sorted"

if [[ "$REGEN_EXPIRED" -eq 1 ]]; then
    if [[ "$EXPIRY_EVALUABLE" -eq 0 ]]; then
        say ""
        say "REFUSING TO REGENERATE: this run has no cut version, so NOTHING could" >&2
        say "expire and the expired set is empty BY CONSTRUCTION, not by measurement." >&2
        say "Writing it as the baseline would delete every ref in it and retire the" >&2
        say "ratchet, on the run that looks most authoritative because every repo" >&2
        say "resolved." >&2
        say "" >&2
        say "Re-run with the version you are cutting:" >&2
        say "    OSTLER_CUT_VERSION=v1.0.NN scripts/verify_no_orphaned_fixes.sh --regenerate-expired-baseline" >&2
        exit 2
    fi
    if [[ "$unchecked" -gt 0 ]]; then
        say ""
        say "REFUSING TO REGENERATE: ${unchecked} repo(s) were NOT CHECKED in this" >&2
        say "environment, so this run did not see the whole expired set. Writing it" >&2
        say "as the baseline would silently DELETE every expired ref those repos" >&2
        say "would have produced, and the ratchet would then never flag them again." >&2
        say "Regenerate from the operator run, where all repos resolve." >&2
        exit 2
    fi
    mkdir -p "$(dirname "$EXPIRED_BASELINE")"
    {
        printf '%s\n' "# Deferrals whose until_cut has already passed."
        printf '%s\n' "# Regenerate: scripts/verify_no_orphaned_fixes.sh --regenerate-expired-baseline"
        printf '%s\n' "# A NEW ref here is a failure. A ref that disappears is progress: re-run"
        printf '%s\n' "# with --regenerate-expired-baseline and commit, so it cannot come back."
        cat "${EXPIRED_REFS}.sorted"
    } > "$EXPIRED_BASELINE"
    say ""
    say "wrote $(wc -l < "${EXPIRED_REFS}.sorted" | tr -d ' ') expired ref(s) to ${EXPIRED_BASELINE}"
fi

if [[ "$EXPIRY_EVALUABLE" -eq 0 ]]; then
    say ""
    say "   expiry ratchet: NOT EVALUATED. No cut version was given, so no deferral"
    say "   can be past its until_cut and the expired set is empty by construction."
    say "   This run says NOTHING about expiry, in either direction, and in"
    say "   particular it is not evidence that any baselined ref has stopped"
    say "   expiring. Set OSTLER_CUT_VERSION=v1.0.NN to evaluate it."
elif [[ -f "$EXPIRED_BASELINE" ]]; then
    expiry_ratchet_sets "${EXPIRED_REFS}.sorted" "$EXPIRED_BASELINE" \
                        "${EXPIRED_REFS}.new" "${EXPIRED_REFS}.gone"
    new_expired="$(cat "${EXPIRED_REFS}.new")"
    gone_expired="$(cat "${EXPIRED_REFS}.gone")"
    base_n="$(wc -l < "${EXPIRED_REFS}.new.base" | tr -d ' ')"
    now_n="$(wc -l < "${EXPIRED_REFS}.sorted" | tr -d ' ')"
    say ""
    say "   expiry ratchet: ${now_n} expired now, ${base_n} baselined, ${checked} repo(s) checked"
    if [[ "$unchecked" -gt 0 ]]; then
        say "   ADVISORY THIS RUN: ${unchecked} repo(s) were NOT CHECKED, so a ref that"
        say "   would be new cannot be seen from here. A clean ratchet in a partial run"
        say "   is not evidence the set is clean."
    fi
    if [[ -n "$gone_expired" ]]; then
        # grep -c, not ${#var}: ${#var} is the STRING LENGTH in bash, so a
        # single 40-character ref would have reported itself as 40 refs.
        gone_n="$(printf '%s\n' "$gone_expired" | grep -c . )"
        say "   ${gone_n} baselined ref(s) no longer expire. Re-run with"
        say "   --regenerate-expired-baseline and commit, so they cannot come back:"
        printf '%s\n' "$gone_expired" | sed 's/^/       /'
    fi
    if [[ -n "$new_expired" ]] && [[ "$unchecked" -eq 0 ]]; then
        {
            printf '\n'
            printf 'ERROR: a deferral went past its until_cut and is not in the baseline.\n\n'
            printf '%s\n' "$new_expired" | sed 's/^/    /'
            printf '\n'
            printf 'Expiry is not blocking, but GROWTH is. Either work the deferral\n'
            printf '(merge it, or re-defer it to a version that has not been cut), or if\n'
            printf 'it is genuinely new debt, re-run with --regenerate-expired-baseline\n'
            printf 'and say in the commit why the debt grew.\n'
        } >&2
        # NOT red. `red` means "work exists that is not in what you are about
        # to ship", and the exit block prints exactly that sentence. An expired
        # deferral is a different fact and deserves a different sentence; using
        # the same counter would have printed the orphaned-work paragraph for a
        # bookkeeping failure and sent the reader looking for missing commits.
        expiry_ratchet_failed=1
    elif [[ -n "$new_expired" ]]; then
        new_n="$(printf '%s\n' "$new_expired" | grep -c . )"
        say "   ${new_n} ref(s) are newly expired but this run is PARTIAL, so this"
        say "   is reported and not counted. Re-run where every repo resolves."
    fi
else
    say ""
    say "   expiry ratchet: NO BASELINE at ${EXPIRED_BASELINE}."
    say "   ${expired_deferrals} deferral(s) expired this run and nothing is bounding that"
    say "   number. Run --regenerate-expired-baseline on a full run and commit it."
fi

if [[ "$unchecked" -gt 0 ]]; then
    say ""
    say "   NOT CHECKED IN THIS ENVIRONMENT: ${unchecked_labels}"
    say "   These were declared unverifiable here, so this run says NOTHING about"
    say "   them either way. They are covered by the OPERATOR run of this script"
    say "   on the build machine, where all three gh accounts resolve. If that run"
    say "   did not happen, these repos went unexamined."
fi

# ---------------------------------------------------------------------------
# REVERSE SWEEP: which DECLARED deferrals did nothing this run?
#
# is_deferred() only ever answers forwards. Nothing has ever checked that a
# deferral is reachable, so a ref the gate cannot generate sits in the file
# looking handled and holding nothing. CM051 #788 recorded
# `daemon:fix/vault-state-default-status-none`, a BRANCH key, while this gate
# keys open PRs as `daemon:#312`, a PR-NUMBER key. It never matched. It read as
# satisfied for its entire life.
#
# UNCONSULTED is not automatically a defect. It means exactly one thing: this
# deferral was not asked about, so it held nothing THIS RUN. Three causes, and
# the reader has to tell them apart:
#   1. the ref is malformed or in the wrong key shape  -> fix it
#   2. the work has since LANDED                       -> delete the deferral
#   3. its repo was not checked here                   -> excluded below, not
#                                                         reported, because that
#                                                         would be noise
#
# ADVISORY. It prints a ratio and does not fail the run, because turning it
# blocking today would red-line a file with 576 entries that predate the check.
# A permanent red teaches people red means nothing, which is the failure this
# script's own header warns about.
# ---------------------------------------------------------------------------
deferral_reachability_report() {
    # Defaults are :- against a possibly-UNSET name, not just an empty one.
    # `${3:-$unchecked_labels}` is itself an unbound-variable error under set -u,
    # which is how the self-test below caught this function before it shipped.
    local DEFERRALS_FILE="${1:-${DEFERRALS_FILE:-}}"
    local CONSULTED_REFS="${2:-${CONSULTED_REFS:-}}"
    local unchecked_labels="${3:-${unchecked_labels:-}}"
    if [[ -f "$DEFERRALS_FILE" ]]; then
        declared_refs="$(sed -nE 's/^[[:space:]]*-?[[:space:]]*ref:[[:space:]]*["'"'"']?([^"'"'"']+)["'"'"']?[[:space:]]*$/\1/p' \
                         "$DEFERRALS_FILE" | sed 's/[[:space:]]*$//' | sort -u)"
        consulted="$(sort -u "$CONSULTED_REFS" 2>/dev/null || true)"
        n_declared=$(printf '%s\n' "$declared_refs" | grep -c . || true)
        n_consulted=$(printf '%s\n' "$consulted" | grep -c . || true)

        # VACUITY CONTROL. If nothing was consulted at all, this sweep has measured
        # nothing and must say so rather than report every deferral as unconsulted.
        if [[ "$n_consulted" -eq 0 ]]; then
            say ""
            say "   DEFERRAL REACHABILITY: CANNOT-RUN. is_deferred() was never called,"
            say "   so this run says NOTHING about which deferrals bind. Not a pass."
        else
            unconsulted="$(comm -23 <(printf '%s\n' "$declared_refs") <(printf '%s\n' "$consulted"))"
            # Exclude repos this environment did not check -- their deferrals could
            # not have been consulted no matter how well-formed they are.
            if [[ -n "$unchecked_labels" ]]; then
                for _lbl in ${unchecked_labels//,/ }; do
                    _lbl="${_lbl// /}"
                    [[ -z "$_lbl" ]] && continue
                    unconsulted="$(printf '%s\n' "$unconsulted" | grep -v "^${_lbl}:" || true)"
                done
            fi
            n_unconsulted=$(printf '%s\n' "$unconsulted" | grep -c . || true)
            say ""
            say "   DEFERRAL REACHABILITY: ${n_consulted} of ${n_declared} declared deferral(s) were consulted"
            say "   this run; ${n_unconsulted} were NOT (excluding repos not checked here)."
            if [[ "$n_unconsulted" -gt 0 ]]; then
                say "   A deferral nothing asks about holds nothing. Either the ref is in the"
                say "   wrong key shape, or the work has landed and the row should go."
                printf '%s\n' "$unconsulted" | head -20 | while IFS= read -r _r; do
                    [[ -n "$_r" ]] && say "     UNCONSULTED  ${_r}"
                done
                if [[ "$n_unconsulted" -gt 20 ]]; then
                    say "     ... and $((n_unconsulted - 20)) more (showing 20 of ${n_unconsulted})"
                fi
            fi
        fi
    fi
}

deferral_reachability_report "$DEFERRALS_FILE" "$CONSULTED_REFS" "$unchecked_labels"

if [[ "$red" -gt 0 ]]; then
    if [[ "$unverifiable" -gt 0 ]]; then
        printf '\n' >&2
        printf 'NOTE: %d of the %d RED(s) above are CANNOT-VERIFY, not orphaned work.\n' \
            "$unverifiable" "$red" >&2
        printf '      Nothing was measured for those. Either point their *_DIR at a\n' >&2
        printf '      checkout, or declare them in OSTLER_ORPHAN_GATE_SKIP. Do not\n' >&2
        printf '      read them as a finding, and do not read them as a pass.\n' >&2
    fi
    cat >&2 <<'EOF'

ERROR: work exists that is NOT in what you are about to ship.

This is the exact failure that produced the v1.0.15 walk: six fixes were
already written and none of them reached main, so Andy hit every one of
them by hand on a DMG that passed all forty other gates.

For each RED above, either:
  * merge it to main (preferred -- unmerged equals not shipped), or
  * record a deliberate deferral, with a reason, in cut-deferrals.yaml

Do NOT bypass this gate. Bypassing it is the habit it exists to stop.
EOF
    exit 1
fi

if [[ "$checked" -eq 0 ]]; then
    say "CANNOT VERIFY: no repo checkouts resolved. Failing closed." >&2
    exit 3
fi

if [[ "$expiry_ratchet_failed" -ne 0 ]]; then
    say "" >&2
    say "FAIL: no orphaned work, but the expired-deferral set GREW. See above." >&2
    exit 1
fi

if [[ "$unchecked" -gt 0 ]]; then
    say "GREEN, PARTIAL: every written fix in the ${checked} repo(s) CHECKED HERE is"
    say "shipping or consciously deferred. ${unchecked} repo(s) were not examined."
    exit 0
fi
say "GREEN: every written fix is either shipping or consciously deferred."
exit 0
