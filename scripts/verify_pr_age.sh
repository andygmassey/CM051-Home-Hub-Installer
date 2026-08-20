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
# Emit "ref<TAB>review_by" for each entry in the pr_exemptions: block.
#
# POSIX classes, not \s: BSD sed/grep on macOS do not understand the GNU
# shorthand, and fail SILENTLY rather than erroring -- the first cut of this
# parser never matched anything, so the escape hatch was dead and nobody would
# have known until the first genuine blocker.
exempt_entries() {
    [[ -f "$DEFERRALS" ]] || return 0
    sed -n '/^pr_exemptions:/,$p' "$DEFERRALS" | awk '
        /^[[:space:]]*-[[:space:]]*ref:/ {
            if (ref != "") print ref "\t" review
            ref = $0; sub(/^[[:space:]]*-[[:space:]]*ref:[[:space:]]*"?/, "", ref)
            sub(/"?[[:space:]]*$/, "", ref); review = ""
            next
        }
        /^[[:space:]]*review_by:/ {
            review = $0; sub(/^[[:space:]]*review_by:[[:space:]]*"?/, "", review)
            sub(/"?[[:space:]]*$/, "", review)
        }
        END { if (ref != "") print ref "\t" review }
    '
}

# Verdict for a ref: "none" | "valid" | "expired" | "undated".
#
# An exemption MUST expire. Without this the escape hatch is unbounded: one
# line buys permanent immunity, pr_exemptions: silently becomes the new
# 176-PR backlog, and the rule launders the problem instead of fixing it.
# An undated exemption is rejected for the same reason -- "blocked, no idea
# until when" is precisely the state that produced this mess.
exempt_verdict() {
    local needle="$1" ref review
    while IFS=$'\t' read -r ref review; do
        [[ "$ref" == "$needle" ]] || continue
        if [[ -z "$review" ]]; then
            printf 'undated'; return
        fi
        local rev_epoch
        rev_epoch=$(date -j -f "%Y-%m-%d" "$review" "+%s" 2>/dev/null \
                    || date -d "$review" "+%s" 2>/dev/null)
        if [[ -z "${rev_epoch:-}" ]]; then
            printf 'undated'; return
        fi
        if (( rev_epoch < now_epoch )); then
            printf 'expired'; return
        fi
        printf 'valid'; return
    done < <(exempt_entries)
    printf 'none'
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
unreachable_names=""

say "== PR age gate: merge or close within ${MAX_HOURS}h (rule effective ${RULE_EFFECTIVE_DATE}) =="
say ""

while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    if ! json=$(gh pr list --repo "$repo" --state open --limit 200 \
                 --json number,title,createdAt,isDraft 2>/dev/null); then
        say "  [warn] ${repo}: could not list PRs (auth/billing?) -- NOT checked"
        unreachable=$(( unreachable + 1 ))
        unreachable_names="${unreachable_names}${repo}"$'\n'
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
        case "$(exempt_verdict "$ref")" in
            valid)
                say "  [DEFERRED] ${ref} open ${hours}h -- exemption valid"
                exempted=$(( exempted + 1 )); continue ;;
            expired)
                say "  [RED]  ${ref} open ${hours}h: EXEMPTION EXPIRED -- re-decide it"
                violations=$(( violations + 1 )); continue ;;
            undated)
                say "  [RED]  ${ref} open ${hours}h: exemption has no usable review_by date"
                violations=$(( violations + 1 )); continue ;;
        esac
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
# THE DENOMINATOR IS PART OF THE VERDICT.
#
# This line used to read "N repo(s) checked", which is the numerator alone. On
# a hosted runner GH_TOKEN is the repo-scoped secrets.GITHUB_TOKEN, so every
# sibling repo's `gh pr list` fails, each prints one [warn] line, and the run
# ends "1 repo(s) checked | 0 over 48h" -- indistinguishable, at a glance or to
# a scrape, from a clean sweep of the whole estate.
#
# Measured 2026-08-20 on the same tree in the same hour:
#     all 7 repos reachable (operator Mac)   -> 17 over 48h, rc=1
#     CM051 only     (what CI can resolve)   ->  0 over 48h, rc=0
#
# So the count of repos it COULD NOT read belongs in the headline, not in
# scrollback above it.
total_repos=$(( checked + unreachable ))
say "== ${checked} of ${total_repos} repo(s) checked | ${violations} over ${MAX_HOURS}h | ${exempted} exempt | ${legacy} pre-rule =="

# The verdict word, so a partial run can never be read as a complete one. Its
# sibling verify_no_orphaned_fixes.sh has said "GREEN, PARTIAL" and "NOT
# CHECKED IN THIS ENVIRONMENT" since #643; this gate is the same shape and was
# silent about it. Same repo, same cut, two gates -- now the same honesty.
if (( unreachable > 0 )); then
    colour="GREEN"; (( violations > 0 )) && colour="RED"
    say "== VERDICT: ${colour}, PARTIAL -- ${unreachable} of ${total_repos} repo(s) NOT CHECKED =="
    say ""
    say "NOT CHECKED IN THIS ENVIRONMENT:"
    while IFS= read -r r; do [[ -n "$r" ]] && say "  - ${r}"; done <<< "$unreachable_names"
    say ""
    say "This run says NOTHING about those repos either way -- it did not fail to"
    say "find overdue PRs there, it failed to look. The usual cause is a"
    say "repo-scoped token: gh cannot list a sibling repo's PRs even under the"
    say "same owner. Re-run where all accounts resolve (the operator's Mac)"
    say "before treating this verdict as estate-wide."
else
    colour="GREEN"; (( violations > 0 )) && colour="RED"
    say "== VERDICT: ${colour} -- all ${total_repos} repo(s) checked =="
fi

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
