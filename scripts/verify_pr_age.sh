#!/usr/bin/env bash
#
# verify_pr_age.sh -- a PR must reach main (or be closed) within 48 hours.
#
# ============================================================================
# WHY THIS EXISTS
# ============================================================================
# On 2026-08-06 a sweep of six repos found 176 open PRs and 458 unmerged
# branches carrying genuinely unique work (sampled 60, zero were already in
# main by patch-id -- this is real un-landed code, not squash-merge residue).
#
# That backlog is not untidiness. It is the arithmetic result of a workflow
# where "done" meant "PR open" rather than "merged to main": dozens of task
# descriptions read literally "commit + push + open PR (no merge)". Intake had
# a valve, outflow did not, and nobody measured the gap between the two rates.
#
# What it cost, concretely:
#   * The v1.0.15 box-walk hit SIX defects that were already fixed and sitting
#     unmerged. Andy found every one of them by hand on a DMG that had passed
#     forty other gates.
#   * Work got rebuilt because earlier attempts were invisible: FOUR separate
#     "on this day current year" branches, THREE "person-page quality cluster"
#     branches. Paid for four times, shipped zero times.
#
# So: a wall-clock deadline on the queue itself. A PR that cannot clear in two
# days is telling you something -- it is too big, it is blocked, or nobody
# actually wants it. All three are worth surfacing while the context is still
# in someone's head.
#
# ============================================================================
# THE RULE
# ============================================================================
#   Every PR opened on or after RULE_EFFECTIVE_DATE must be MERGED or CLOSED
#   within 48 hours of opening.
#
#   Deliberately blocked is fine. SILENTLY blocked is not. Record an exemption
#   in cut-deferrals.yaml under `pr_exemptions:` with a reason and a review
#   date, and this gate accepts it -- while still printing it, so it cannot
#   fade into the background.
#
# The rule is NOT retroactive. The 176 PRs that predate it are a known legacy
# backlog with its own phased sweep (archive-tag everything, cluster the
# duplicates, merge keepers, close the rest citing the tag). Applying the rule
# retroactively would put the gate permanently in the red on day one, and a
# gate that is always red is a gate that gets bypassed -- which is the exact
# habit this is meant to break.
#
# ============================================================================
# USAGE
#   bash scripts/verify_pr_age.sh              # all repos, fail on violation
#   PR_AGE_HOURS=24 bash scripts/verify_pr_age.sh
#   PR_AGE_REPOS="andygmassey/CM044-PWG-Personal-Wiki" bash scripts/verify_pr_age.sh
#
# Exit: 0 clean (or all exempt) | 1 violation | 3 cannot verify (fails closed)
# ============================================================================

set -uo pipefail

RULE_EFFECTIVE_DATE="${PR_RULE_EFFECTIVE_DATE:-2026-08-06}"
MAX_HOURS="${PR_AGE_HOURS:-48}"
DEFERRALS="${OSTLER_CUT_DEFERRALS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/cut-deferrals.yaml}"

DEFAULT_REPOS="andygmassey/CM051-Home-Hub-Installer
andygmassey/CM044-PWG-Personal-Wiki
andygmassey/CM041-People-Graph
andygmassey/CM059-Ostler-Editor
andygmassey/CM031-PWG-Companion
andygmassey/HR015-Gaming-PC
ostler-ai/ostler-assistant"

REPOS="${PR_AGE_REPOS:-$DEFAULT_REPOS}"

say() { printf '%s\n' "$*"; }

# Exempt refs, one per line, from the pr_exemptions: block of cut-deferrals.yaml.
# Parsed with grep/sed rather than a YAML library so this has no dependencies
# beyond git/gh -- the same reason the sibling gates avoid python.
exempt_refs() {
    [[ -f "$DEFERRALS" ]] || return 0
    # POSIX classes, not \s: BSD sed/grep on macOS do not understand the GNU
    # shorthand, and silently fail to strip the prefix rather than erroring --
    # so the exemption never matched and the escape hatch was dead. Caught by
    # testing that the hatch actually works, not just that the gate goes red.
    sed -n '/^pr_exemptions:/,$p' "$DEFERRALS" \
        | grep -oE '^[[:space:]]*-[[:space:]]*ref:[[:space:]]*"?[^"]+"?' \
        | sed -E 's/^[[:space:]]*-[[:space:]]*ref:[[:space:]]*"?//; s/"?[[:space:]]*$//'
}

is_exempt() {
    local needle="$1"
    while IFS= read -r e; do
        [[ -n "$e" && "$e" == "$needle" ]] && return 0
    done < <(exempt_refs)
    return 1
}

effective_epoch=$(date -j -f "%Y-%m-%d" "$RULE_EFFECTIVE_DATE" "+%s" 2>/dev/null \
                  || date -d "$RULE_EFFECTIVE_DATE" "+%s" 2>/dev/null)
if [[ -z "${effective_epoch:-}" ]]; then
    say "CANNOT VERIFY: could not parse RULE_EFFECTIVE_DATE=$RULE_EFFECTIVE_DATE" >&2
    exit 3
fi
now_epoch=$(date "+%s")
cutoff_seconds=$(( MAX_HOURS * 3600 ))

violations=0
legacy=0
exempted=0
checked=0
unreachable=0

say "== PR age gate: merge or close within ${MAX_HOURS}h (rule effective ${RULE_EFFECTIVE_DATE}) =="
say ""

while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    if ! json=$(gh pr list --repo "$repo" --state open --limit 200 \
                 --json number,title,createdAt,isDraft 2>/dev/null); then
        say "  [warn] ${repo}: could not list PRs (auth/billing?) -- NOT checked"
        unreachable=$(( unreachable + 1 ))
        continue
    fi
    checked=$(( checked + 1 ))

    while IFS=$'\t' read -r num created draft title; do
        [[ -z "$num" ]] && continue
        created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created" "+%s" 2>/dev/null \
                        || date -d "$created" "+%s" 2>/dev/null)
        [[ -z "${created_epoch:-}" ]] && continue

        # Pre-rule PRs are the legacy backlog, counted but not fatal.
        if (( created_epoch < effective_epoch )); then
            legacy=$(( legacy + 1 ))
            continue
        fi

        age=$(( now_epoch - created_epoch ))
        (( age <= cutoff_seconds )) && continue

        hours=$(( age / 3600 ))
        ref="${repo#*/}#${num}"
        if is_exempt "$ref"; then
            say "  [DEFERRED] ${ref} open ${hours}h -- exemption recorded"
            exempted=$(( exempted + 1 ))
            continue
        fi
        marker=""; [[ "$draft" == "true" ]] && marker=" (DRAFT)"
        say "  [RED]  ${ref} open ${hours}h${marker}: ${title}"
        violations=$(( violations + 1 ))
    done < <(printf '%s' "$json" | python3 -c '
import json,sys
for p in json.load(sys.stdin):
    print("\t".join([str(p["number"]), p["createdAt"],
                     str(p["isDraft"]).lower(), p["title"].replace("\t"," ")]))
' 2>/dev/null)
done <<< "$REPOS"

say ""
say "== ${checked} repo(s) checked | ${violations} over ${MAX_HOURS}h | ${exempted} exempt | ${legacy} pre-rule =="

if (( legacy > 0 )); then
    say ""
    say "NOTE: ${legacy} PR(s) predate the rule and are NOT failing this gate."
    say "They are the legacy backlog from the 2026-08-06 sweep. Every unmerged"
    say "branch tip is preserved as archive/2026-08-06/<branch>, so closing one"
    say "can never lose work. Clear them via the phased sweep, not by widening"
    say "this rule."
fi

if (( checked == 0 )); then
    say ""
    say "CANNOT VERIFY: no repo produced a PR listing. Failing closed." >&2
    exit 3
fi

if (( violations > 0 )); then
    cat >&2 <<EOF

ERROR: ${violations} PR(s) have been open longer than ${MAX_HOURS}h.

A PR that cannot clear in two days is too big, blocked, or unwanted. All three
are worth knowing NOW, while whoever wrote it still remembers why.

For each RED above:
  * merge it to main (unmerged equals not shipped), or
  * close it -- the branch tip survives as a tag, so nothing is lost, or
  * record an exemption in cut-deferrals.yaml under pr_exemptions:, with a
    reason and a review date.

Deliberately blocked is fine. Silently blocked is what produced a 176-PR
backlog and six fixes that Andy found by hand on a shipped DMG.
EOF
    exit 1
fi

say "GREEN: no PR has outstayed the ${MAX_HOURS}h limit."
exit 0
