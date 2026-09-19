#!/usr/bin/env bash
#
# scripts/lib/checkout_guard.sh -- is a checkout a cut gate reads actually the
# reviewed tree, or somebody's branch?
#
# ============================================================================
# WHY THIS EXISTS (#1550, measured during the v1.0.70 cut preflight 2026-09-05)
# ============================================================================
#
# scripts/run_all_cut_gates.sh returned "13 green | 2 red" and refused the
# assembly on that tally. Both reds were artefacts of the operator's own
# environment. Neither was a defect in the cut.
#
#   the operator's canonical CM044 checkout
#     .git is a DIRECTORY            -> passed the worktree guard
#     branch  fix/embed-one-chrome-band-nav-crop
#     rev-list --left-right --count HEAD...origin/main  ->  0   7
#
# Seven commits behind, and the gate compared the shipped image against it:
# "RED wiki image CONTENT". Re-run unchanged against a fresh clone at
# origin/main: rc=0, with its own positive controls firing. The image had not
# changed; the checkout had.
#
# THE GUARD THAT EXISTED TESTED THE WRONG PROPERTY. It asked whether .git was a
# FILE (a worktree). What produces the false verdict is the BRANCH, and a
# canonical clone left on a feature branch has .git as a directory and sails
# straight through.
#
# ============================================================================
# THE HALF THAT WAS STILL MISSING WHEN THIS FILE WAS WRITTEN
# ============================================================================
#
# A branch guard was later added for CM044 alone. Measured on origin/main
# 2026-09-16: OSTLER_ASSISTANT_DIR appeared ZERO times in the 319 lines of
# run_all_cut_gates.sh, against 20 occurrences of CM044_DIR as a positive
# control in the same file, so the zero was real and not a broken pattern.
# Three cut gates read that checkout -- cut provenance, content provenance and
# vendor pair drift -- and every one of them was invoked bare.
#
# 🔴 AND THAT SIDE FAILS THE OTHER WAY. The CM044 case produces a false RED,
# which is expensive and visible. The vendor-pair gate compares the run-source
# enum in ostler-assistant against the array in the CM051 wrapper, so a stale
# branch on that side compares a feature-branch enum with a main wrapper: it
# can produce a false GREEN, which is a cut that shipped unmeasured and nobody
# looked twice. Measured the same day: that checkout sat on
# archie/reconcile-decision-record with src/main.rs a different blob from
# origin/main while the wrapper it is compared against was identical on both.
#
# A FETCH IS PART OF THE CHECK. Comparing HEAD against a
# refs/remotes/origin/main that was last updated days ago is the same class of
# stale one level up, and it reads as a clean comparison. There was no `fetch`
# anywhere in run_all_cut_gates.sh.
#
# ============================================================================
# WHAT IT REFUSES WITH, AND WHY THAT WORD
# ============================================================================
#
# CANNOT-RUN. Not RED and not PASS. A stale checkout means the gate could not
# look: it has not failed and it has not passed. The distinction drives
# opposite actions -- a RED sends someone to rebuild and re-pin an image that
# is already correct, which costs a version number, and two have already been
# spent that way. In run_all_cut_gates.sh a CANNOT-RUN still stops the cut
# (unavailable() counts as red in the tally), so nothing is waved through; the
# operator is told the CHECKOUT is wrong rather than being told the ARTEFACT
# is.
#
# ============================================================================
# THE PROPERTY IS THE TREE, NOT THE BRANCH NAME
# ============================================================================
#
# #1550 proposes refusing when "the branch is not the default". This refuses on
# HEAD not being the tip COMMIT of the default branch, which is the same test
# for every case that produced a false verdict and one case looser: a detached
# HEAD sitting exactly on origin/main has byte-identical content, so the gate
# CAN look, and refusing it would be a false CANNOT-RUN blocking a correct cut.
# The branch name is measured and PRINTED either way, so an operator reading a
# refusal sees which branch they were on.
#
# British English throughout; " -- " not em-dashes.

# Set OSTLER_CUT_GATES_FETCH=0 to compare against the remote ref as already
# cached. It is 1 by default deliberately: a cached ref of unknown age is the
# stale-comparison defect this file exists to stop, one level up.
CHECKOUT_GUARD_FETCH="${OSTLER_CUT_GATES_FETCH:-1}"

# _checkout_default_branch <dir>
# Prints the default branch name. Resolved from origin/HEAD where the clone has
# it, because hardcoding "main" is a claim about someone else's repository.
# Falls back to main, and the caller learns the name it used from the state
# string, so a wrong fallback is visible rather than silent.
_checkout_default_branch() {
    local d="$1" ref
    ref="$(git -C "$d" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
    if [ -n "$ref" ]; then
        printf '%s\n' "${ref#origin/}"
        return 0
    fi
    printf 'main\n'
}

# _checkout_tip_state <dir>
# Prints ONE of:
#   ok
#   not-a-git-checkout
#   no-default-ref|<default>
#   fetch-failed|<default>|<branch>|<ahead>|<behind>
#   off-tip|<default>|<branch>|<ahead>|<behind>
#
# Always returns 0. The verdict is the STRING, so a caller cannot mistake a
# non-zero exit from git for a verdict about the checkout -- which is the
# mistake that turns "could not look" into "failed".
_checkout_tip_state() {
    local d="$1" def branch lr ahead behind fetch_failed=0
    git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || { printf 'not-a-git-checkout\n'; return 0; }
    def="$(_checkout_default_branch "$d")"
    if [ "$CHECKOUT_GUARD_FETCH" = 1 ]; then
        git -C "$d" fetch --quiet origin "$def" >/dev/null 2>&1 || fetch_failed=1
    fi
    git -C "$d" rev-parse --verify --quiet "refs/remotes/origin/${def}" >/dev/null 2>&1 \
        || { printf 'no-default-ref|%s\n' "$def"; return 0; }
    branch="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '?')"
    # THE DENOMINATOR OF THE COMPARISON, both sides of it. `--count HEAD..x`
    # answers only "behind" and a checkout can be off the tip by being AHEAD --
    # local commits nobody reviewed are exactly as unreviewed as missing ones.
    lr="$(git -C "$d" rev-list --left-right --count "HEAD...origin/${def}" 2>/dev/null || printf '? ?')"
    ahead="$(printf '%s' "$lr" | awk '{print ($1 == "" ? "?" : $1)}')"
    behind="$(printf '%s' "$lr" | awk '{print ($2 == "" ? "?" : $2)}')"
    if [ "$fetch_failed" = 1 ]; then
        printf 'fetch-failed|%s|%s|%s|%s\n' "$def" "$branch" "$ahead" "$behind"
        return 0
    fi
    if [ "$ahead" = 0 ] && [ "$behind" = 0 ]; then
        printf 'ok\n'
        return 0
    fi
    printf 'off-tip|%s|%s|%s|%s\n' "$def" "$branch" "$ahead" "$behind"
}

# _checkout_explain <var-name> <dir> <state>
# Turns a state string into the sentence an operator reads next to a refusal.
# It names the variable, the path, the branch and both counts, because a
# refusal that does not say what was found sends its reader hunting a defect
# that was never detected.
_checkout_explain() {
    local var="$1" d="$2" s="$3" kind def branch ahead behind rest
    kind="${s%%|*}"
    rest="${s#*|}"
    def="${rest%%|*}"; rest="${rest#*|}"
    branch="${rest%%|*}"; rest="${rest#*|}"
    ahead="${rest%%|*}"; behind="${rest#*|}"
    case "$kind" in
        ok)
            printf '%s is at the tip of its default branch.' "$var"
            ;;
        not-a-git-checkout)
            printf '%s is not a git checkout: %s. The gates that read it compare the cut against its working tree, so there is nothing to compare against.' "$var" "$d"
            ;;
        no-default-ref)
            printf "%s (%s) has no refs/remotes/origin/%s, so whether it is the reviewed tree COULD NOT BE EVALUATED. That is not a stale checkout and not a fresh one: this check observed nothing." "$var" "$d" "$def"
            ;;
        fetch-failed)
            printf "%s (%s) could not fetch origin/%s, so the only comparison available is against a cached ref of unknown age -- the same staleness one level up. As cached it is on '%s', %s ahead / %s behind. Fetch it by hand, or set OSTLER_CUT_GATES_FETCH=0 to accept the cached ref, and re-run." "$var" "$d" "$def" "$branch" "$ahead" "$behind"
            ;;
        off-tip)
            printf "%s (%s) is NOT at the tip of origin/%s: HEAD is on '%s', %s ahead / %s behind. Comparing the cut against a tree that is not the reviewed one produces a verdict about the checkout and not about the artefact -- a RED on something provably correct, or a GREEN on something that was never compared. Run: git -C '%s' fetch origin %s && git -C '%s' checkout %s && git -C '%s' merge --ff-only, then re-run." "$var" "$d" "$def" "$branch" "$ahead" "$behind" "$d" "$def" "$d" "$def" "$d"
            ;;
        *)
            printf '%s (%s) is in a state this guard does not recognise: %s' "$var" "$d" "$s"
            ;;
    esac
}
