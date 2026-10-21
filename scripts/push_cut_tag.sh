#!/usr/bin/env bash
# scripts/push_cut_tag.sh <version> <sha>
#
# THE ONLY WAY TO PUSH A CUT TAG. Before the tag exists it REHEARSES the tag
# run: pushes branch rehearse/<version> at <sha> and dispatches cut.yml on it.
# cut.yml runs its OWN preflight job in tag mode for that ref and skips every
# build/ship job. The tag is pushed only if that run, at the SAME SHA,
# concluded success -- read from the run's API `conclusion`, never a log grep.
#
# Why the rehearsal is the tag run's own code and not a local copy: v1.0.103
# and v1.0.104 each spent their one tag push on a preflight refusal. The first
# version of this script re-ran one gate locally; it passed v1.0.104 while the
# tag run's "BOM rows must be in the pinned tree" step refused it. A copy of a
# gate drifts; the job itself cannot.
#
# Tests only: OSTLER_PRETAG_REHEARSE=<cmd> replaces the dispatch and must print
# "<conclusion> <headSha> <run_url>"; OSTLER_PRETAG_DRY_RUN=1 prints the push.
set -euo pipefail

ver="${1:?usage: push_cut_tag.sh <version, e.g. v1.0.105> <sha>}"
sha="${2:?usage: push_cut_tag.sh <version> <sha>}"
case "$ver" in v1.0.*) ;; *) echo "push_cut_tag: '$ver' is not a v1.0.* cut tag" >&2; exit 2 ;; esac
REPO_SLUG="${OSTLER_REPO_SLUG:-andygmassey/CM051-Home-Hub-Installer}"

root="$(git rev-parse --show-toplevel)"
full="$(git -C "$root" rev-parse --verify "${sha}^{commit}")" || { echo "push_cut_tag: $sha is not a commit here" >&2; exit 2; }
if [ -z "${OSTLER_PRETAG_REHEARSE:-}" ] && git -C "$root" ls-remote --exit-code --tags origin "refs/tags/$ver" >/dev/null 2>&1; then
    echo "push_cut_tag: $ver already exists on origin; a version gets ONE tag push" >&2; exit 2
fi

rehearse() {
    local br="rehearse/$ver" since id="" s i
    since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    git -C "$root" push -q --force origin "${full}:refs/heads/${br}"
    trap 'git -C "$root" push -q origin ":refs/heads/'"$br"'" >/dev/null 2>&1 || true' EXIT
    gh workflow run cut.yml --repo "$REPO_SLUG" --ref "$br" >/dev/null
    for i in $(seq 1 40); do
        id="$(gh api "repos/$REPO_SLUG/actions/workflows/cut.yml/runs?event=workflow_dispatch&branch=$br&head_sha=$full&created=>=$since" \
              -q '.workflow_runs | sort_by(.created_at) | last | .id // empty')"
        [ -n "$id" ] && break; sleep 15
    done
    [ -n "$id" ] || { echo "CANNOT-RUN - no-run-found"; return 0; }
    for i in $(seq 1 240); do
        s="$(gh api "repos/$REPO_SLUG/actions/runs/$id" -q '.status')"
        [ "$s" = completed ] && break; sleep 30
    done
    gh api "repos/$REPO_SLUG/actions/runs/$id" -q '"\(.conclusion // "none") \(.head_sha) \(.html_url)"'
}

# MODEL PINS MUST AGREE BEFORE ANY TAG (OS003 #409 arms 6 and 7).
# The installer enforces OSTLER_MODEL_PINS at install time; OS003 release.toml
# [models] is the estate's own record of the same weights. Arm 6 requires the
# two to be equal AND every model install.sh can pull to have an entry; arm 7
# recomputes each fingerprint from registry.ollama.ai. Before this, NO workflow
# ran either arm (gates.yml runs only the offline self-test). The check lives
# HERE because it needs this CM051 tree (read at the SHA being tagged, not
# main) and the network, and cut.yml's preflight cannot reach it: OS003 is
# PRIVATE and this runner's token cannot read it. The OS003 gate and manifest
# are read from OS003 origin/main (fetched) so a working-tree edit cannot
# stand in. CANNOT-RUN refuses too: a pin nobody verified is not a pass, and the
# tag push is the one-per-version resource. Both arm lines must say PASS, so an
# OS003 gate that lacks the arms (pre-#409) refuses rather than waving through.
# Tests: OSTLER_PRETAG_MODELPINS=<cmd> replaces the run (prints the gate's
# output, exit code = the gate's); OSTLER_OS003_DIR picks the checkout;
# OSTLER_PRETAG_NOFETCH=1 skips the fetch (fixture repos have no origin).
# OSTLER_PRETAG_OS003_PIN=<sha> replaces the cuts/REGISTRY_PIN lookup (fixtures).
modelpins() {
    local d="" c t rc
    for c in "${OSTLER_OS003_DIR:-}" "$HOME/Developer/OS003-Ostler-Release" "$HOME/Developer/orm/OS003" "$HOME/Developer/OS003-canonical"; do
        if [ -n "$c" ] && [ -e "$c/.git" ]; then d="$c"; break; fi
    done
    if [ -z "$d" ]; then echo "CANNOT-RUN: no OS003 checkout found (set OSTLER_OS003_DIR)"; return 2; fi
    if [ "${OSTLER_PRETAG_NOFETCH:-0}" != 1 ]; then
        git -C "$d" fetch -q origin main || { echo "CANNOT-RUN: could not fetch OS003 origin/main"; return 2; }
    fi
    # release.toml is read at the OS003 commit THIS cut records (cuts/REGISTRY_PIN
    # in the tree being tagged), not OS003 main: once main moves the pins for the
    # next version, a frozen cut/ branch must still verify against its own record
    # (ORM review of #3094). The gate SCRIPT is taken from origin/main.
    local pin
    pin="${OSTLER_PRETAG_OS003_PIN:-$(git -C "$root" show "$full:cuts/REGISTRY_PIN" 2>/dev/null | awk -F'\t' '$1=="os003_sha"{print $2; exit}')}"
    if [ -z "$pin" ]; then echo "CANNOT-RUN: cuts/REGISTRY_PIN at ${full:0:8} records no os003_sha"; return 2; fi
    if ! git -C "$d" cat-file -e "$pin^{commit}" 2>/dev/null; then echo "CANNOT-RUN: OS003 checkout lacks the recorded commit ${pin:0:8}"; return 2; fi
    t="$(mktemp -d)"; mkdir -p "$t/gates"
    if ! git -C "$d" show origin/main:gates/verify_model_weights_pinned.sh > "$t/gates/verify_model_weights_pinned.sh" 2>/dev/null; then
        rm -rf "$t"; echo "CANNOT-RUN: OS003 origin/main has no gate"; return 2
    fi
    if ! git -C "$d" show "$pin:release.toml" > "$t/release.toml" 2>/dev/null; then
        rm -rf "$t"; echo "CANNOT-RUN: OS003 ${pin:0:8} (cuts/REGISTRY_PIN) has no release.toml"; return 2
    fi
    echo "  model pins read from OS003 ${pin:0:8} (cuts/REGISTRY_PIN), gate from origin/main"
    NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}" OSTLER_CM051_DIR="$root" OSTLER_CM051_REF="$full" \
        bash "$t/gates/verify_model_weights_pinned.sh" 2>&1 && rc=0 || rc=$?
    rm -rf "$t"; return "$rc"
}
echo "push_cut_tag: model pins (OS003 gate arms 6 and 7) at ${full:0:8}"
if [ -n "${OSTLER_PRETAG_MODELPINS:-}" ]; then mpout="$(bash -c "$OSTLER_PRETAG_MODELPINS" 2>&1)" && mprc=0 || mprc=$?
else mpout="$(modelpins)" && mprc=0 || mprc=$?; fi
printf '%s\n' "$mpout" | grep -E 'arm [0-9]|CANNOT-RUN|pass /' | sed 's/^/    /' || true
if [ "$mprc" -ne 0 ] || ! grep -q '\[PASS\] arm 6' <<<"$mpout" || ! grep -q '\[PASS\] arm 7' <<<"$mpout"; then
    echo "push_cut_tag: REFUSED. The model-pin gate (OS003 verify_model_weights_pinned.sh) exited $mprc, or arm 6 / arm 7 did not both PASS, at ${full:0:8}. OSTLER_MODEL_PINS in install.sh and OS003 release.toml [models] must agree, and the registry must still serve those weights; $ver was NOT pushed." >&2; exit 1
fi
echo "push_cut_tag: model pins (arms 6 and 7): GREEN"

# A GREEN CANDIDATE BUILD AT THIS SHA, OR NO TAG (v1.0.109, v1.0.110).
# The rehearsal below is the tag run's PREFLIGHT only. check-manifest reads the
# BUILT .app, so no preflight, dry run or rehearsal can reach it: only the `cut`
# job of a cut/<version> dispatch builds a candidate and runs it. v1.0.110 passed
# its rehearsal and died at check-manifest after the tag was pushed. So: the
# newest workflow_dispatch run of cut.yml on cut/<version> at EXACTLY this SHA
# must have concluded success with its `cut` job success. Read from the API,
# never a log grep. Tests: OSTLER_PRETAG_CANDIDATE=<cmd> prints
# "<cut_job_conclusion> <headSha> <run_url>".
candidate() {
    local br="cut/$ver" id c
    id="$(gh api "repos/$REPO_SLUG/actions/workflows/cut.yml/runs?event=workflow_dispatch&branch=$br&head_sha=$full&per_page=20" \
          -q '[.workflow_runs[] | select(.status=="completed")] | sort_by(.created_at) | last | .id // empty')"
    [ -n "$id" ] || { echo "none - no-completed-candidate-build"; return 0; }
    c="$(gh api "repos/$REPO_SLUG/actions/runs/$id/jobs" -q '[.jobs[] | select(.name=="cut") | .conclusion] | first // "none"')"
    echo "$c $(gh api "repos/$REPO_SLUG/actions/runs/$id" -q '"\(.head_sha) \(.html_url)"')"
}
echo "push_cut_tag: looking for a green cut/$ver candidate build at ${full:0:8}"
if [ -n "${OSTLER_PRETAG_CANDIDATE:-}" ]; then cout="$(bash -c "$OSTLER_PRETAG_CANDIDATE")"; else cout="$(candidate)"; fi
read -r cand_conclusion cand_sha cand_url <<<"$cout"
echo "push_cut_tag: candidate cut job=$cand_conclusion sha=${cand_sha:0:8} $cand_url"
if [ "$cand_sha" != "$full" ]; then
    echo "push_cut_tag: REFUSED. No candidate build of cut/$ver at ${full:0:8} (found ${cand_sha:-nothing}). Dispatch cut.yml on cut/$ver at this SHA and let its cut job finish; $ver was NOT pushed." >&2; exit 1
fi
if [ "$cand_conclusion" != "success" ]; then
    echo "push_cut_tag: REFUSED. The candidate build's cut job concluded '$cand_conclusion' at ${full:0:8} (check-manifest runs there); $ver was NOT pushed." >&2; exit 1
fi
echo "push_cut_tag: rehearsing the tag run for $ver at ${full:0:8}"
if [ -n "${OSTLER_PRETAG_REHEARSE:-}" ]; then out="$(bash -c "$OSTLER_PRETAG_REHEARSE")"; else out="$(rehearse)"; fi
read -r conclusion run_sha run_url <<<"$out"
echo "push_cut_tag: rehearsal conclusion=$conclusion sha=${run_sha:0:8} $run_url"
if [ "$run_sha" != "$full" ]; then
    echo "push_cut_tag: REFUSED. The rehearsal ran at ${run_sha:-nothing}, not ${full:0:8}; $ver was NOT pushed." >&2; exit 1
fi
if [ "$conclusion" != "success" ]; then
    echo "push_cut_tag: REFUSED. The tag run's own preflight concluded '$conclusion' at ${full:0:8}; $ver was NOT pushed." >&2; exit 1
fi
# PR-AGE LOOKAHEAD, IMMEDIATELY BEFORE THE PUSH. v1.0.114 spent its one tag
# here (2026-10-20): the candidate's check-pr-age was green, then CM051 #2993
# crossed 48h in the ~90 min before the tag run reached `make check-pr-age`,
# which refused, and no DMG was built. The candidate's pass is stale by the tag
# run, so re-ask now with the limit pulled in by a lookahead: any PR that will
# cross 48h within OSTLER_PRETAG_PRAGE_LOOKAHEAD_H (default 3) refuses here,
# before anything is pushed. Same scope as the cut job can see (CM051), same
# exemption file (this tree's cut-deferrals.yaml), and TZ=UTC because the
# script parses createdAt in local time. Tests: OSTLER_PRETAG_PRAGE=<cmd>
# replaces the whole check; OSTLER_PRETAG_PRAGE_GH_PATH prepends a fake gh.
# `&& prc=0 || prc=$?` because this script runs under set -e, where a bare
# failing assignment would exit silently with no REFUSED line.
la="${OSTLER_PRETAG_PRAGE_LOOKAHEAD_H:-3}"
if [ -n "${OSTLER_PRETAG_PRAGE:-}" ]; then
    pout="$(bash -c "$OSTLER_PRETAG_PRAGE" 2>&1)" && prc=0 || prc=$?
else
    pout="$(cd "$root" && PATH="${OSTLER_PRETAG_PRAGE_GH_PATH:+$OSTLER_PRETAG_PRAGE_GH_PATH:}$PATH" TZ=UTC \
        PR_AGE_HOURS=$(( 48 - la )) PR_AGE_REPOS="${OSTLER_PRETAG_PRAGE_REPOS:-andygmassey/CM051-Home-Hub-Installer}" \
        bash scripts/verify_pr_age.sh 2>&1)" && prc=0 || prc=$?
fi
if [ "$prc" -ne 0 ]; then
    printf '%s\n' "$pout" | grep -E '\[RED\]|CANNOT' >&2
    echo "push_cut_tag: REFUSED. A PR crosses 48h within ${la}h (or already has), so the tag run's check-pr-age would refuse AFTER the push and spend $ver. Merge, close or exempt it in cut-deferrals.yaml on cut/$ver (a new candidate), then re-run; $ver was NOT pushed." >&2
    exit 1
fi
echo "push_cut_tag: PR-age with a ${la}h lookahead: GREEN"
if [ "${OSTLER_PRETAG_DRY_RUN:-0}" = "1" ]; then
    echo "DRY-RUN: git tag $ver $full && git push origin $ver"; exit 0
fi
git -C "$root" tag "$ver" "$full"
git -C "$root" push origin "$ver"
