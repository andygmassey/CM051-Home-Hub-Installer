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
#   # Accept that named repo(s) cannot be reached, as a DELIBERATE decision --
#   # see "PARTIAL RUNS FAIL CLOSED" below. Never set this because a run
#   # happened to fail; set it because a human decided a narrower run is fine.
#   PR_AGE_ALLOW_PARTIAL="andygmassey/CM044-PWG-Personal-Wiki" bash scripts/verify_pr_age.sh
#
#   # Per-owner credential, for an environment with no `gh auth login` (CI).
#   # <OWNER> is the repo owner uppercased, non-alnum -> `_`.
#   PR_AGE_TOKEN_ANDYGMASSEY=... PR_AGE_TOKEN_OSTLER_AI=... bash scripts/verify_pr_age.sh
#
# Exit: 0 clean (or all exempt, or every unreachable repo was declared via
#       PR_AGE_ALLOW_PARTIAL)
#     | 1 violation
#     | 3 cannot verify -- nothing resolved, OR a repo was unreachable and
#       nobody declared that on purpose (fails closed either way)
# ============================================================================

set -uo pipefail

RULE_EFFECTIVE_DATE="${PR_RULE_EFFECTIVE_DATE:-2026-08-06}"
MAX_HOURS="${PR_AGE_HOURS:-48}"
DEFERRALS="${OSTLER_CUT_DEFERRALS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/cut-deferrals.yaml}"
ALLOW_PARTIAL="${PR_AGE_ALLOW_PARTIAL:-}"

# Anti-accretion floor. The pr_exemptions: block is an escape hatch, not a
# parking lot: on 2026-10-17 it held ~783 rows, every one expired, and the gate
# spent its time re-reding a legacy pile instead of policing new debt. The cap
# is the same rule the freshness ledger already encodes -- an exemption must
# DRAIN, it may not ACCRETE -- made arithmetic here. Read from cut-deferrals.yaml
# (pr_exemptions_live_cap:), overridable per-run, default 10. See the LIVE
# EXEMPTION LEDGER section below for what counts as "live".
LIVE_CAP="${PR_AGE_LIVE_CAP:-$(sed -n 's/^pr_exemptions_live_cap:[[:space:]]*//p' "$DEFERRALS" 2>/dev/null | head -1)}"
LIVE_CAP="${LIVE_CAP:-10}"

DEFAULT_REPOS="andygmassey/CM051-Home-Hub-Installer
andygmassey/CM044-PWG-Personal-Wiki
andygmassey/CM041-People-Graph
andygmassey/CM059-Ostler-Editor
andygmassey/CM031-PWG-Companion
andygmassey/HR015-Gaming-PC
ostler-ai/ostler-assistant"

REPOS="${PR_AGE_REPOS:-$DEFAULT_REPOS}"

say() { printf '%s\n' "$*"; }

# Resolve a token for a repo's OWNER, the same mechanism PR #643 gave the
# sibling verify_no_orphaned_fixes.sh. One token is not right for two owners: a
# repo-scoped token cannot read a sibling repo even under the SAME owner, and
# never reads across an org boundary at all (andygmassey/* vs ostler-ai/*).
#
# Precedence:
#   1. An explicit per-owner override, for an environment with no
#      `gh auth login` (CI): PR_AGE_TOKEN_<OWNER>, e.g. PR_AGE_TOKEN_OSTLER_AI.
#      Absent means "fall through", never "use a token that cannot reach here".
#   2. `gh auth token -u <owner>` -- the operator's Mac, multi-account gh CLI.
#   3. Nothing. gh_as() below then calls gh with whatever it already has
#      ambient (an exported GH_TOKEN/GITHUB_TOKEN, or a logged-in session) --
#      exactly the behaviour this script had before this function existed.
token_for_owner() {
    local owner="$1" var tok
    var="PR_AGE_TOKEN_$(printf '%s' "$owner" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"
    var="${var%_}"
    tok="${!var:-}"
    if [[ -z "$tok" ]] && command -v gh >/dev/null 2>&1; then
        tok="$(gh auth token -u "$owner" 2>/dev/null || true)"
    fi
    printf '%s' "$tok"
}

# GH_TOKEN="$tok" gh ... is NOT equivalent to this when $tok is empty: an
# empty GH_TOKEN means UNAUTHENTICATED, not "fall back to ambient auth". #643
# hit exactly this in the orphan gate (v1.0.22, run 31478119136) and gh_as()
# is that fix, copied here rather than re-derived.
gh_as() {
    local t="$1"; shift
    if [[ -n "$t" ]]; then GH_TOKEN="$t" gh "$@"; else gh "$@"; fi
}

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
            # A YAML inline comment is not part of the value. Left in, BSD
            # `date -j -f` warns and reads the leading date (valid) while GNU
            # `date -d` refuses the whole string (undated): one row, two
            # verdicts by host. Measured 2026-10-18 on the #1818 row.
            sub(/[[:space:]]+#.*$/, "", review)
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

# The pr_exemptions refs carry the SHORT repo name (CM051-Home-Hub-Installer#42),
# but `gh pr view` needs owner/repo. The gate's repo list is the single source of
# truth for which owner each repo lives under, so resolve from it. Empty when the
# ref names a repo this run does not know about -> state UNKNOWN, never a guess.
owner_repo_for_short() { # short-repo-name -> owner/repo (empty if unknown)
    local short="$1" r
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        [[ "${r#*/}" == "$short" ]] && { printf '%s' "$r"; return; }
    done <<< "$REPOS"
}

# Resolve a PR's state with one `gh pr view`, owner-scoped the same way the PR
# listing is (token_for_owner + gh_as). Prints exactly one of OPEN|CLOSED|MERGED|
# UNKNOWN. UNKNOWN is fail-SAFE for the cap below: an unresolved state is never
# counted as live, so a credential gap can only ever UNDER-count, never
# manufacture a cap breach out of an auth error.
pr_state() { # owner/repo  number
    local repo="$1" num="$2" owner tok st
    owner="${repo%%/*}"
    tok="$(token_for_owner "$owner")"
    st="$(gh_as "$tok" pr view "$num" --repo "$repo" --json state --jq '.state' 2>/dev/null)" || st=""
    case "$st" in
        OPEN)   printf 'OPEN' ;;
        CLOSED) printf 'CLOSED' ;;
        MERGED) printf 'MERGED' ;;
        *)      printf 'UNKNOWN' ;;
    esac
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
    _owner="${repo%%/*}"
    _tok="$(token_for_owner "$_owner")"
    if ! json=$(gh_as "$_tok" pr list --repo "$repo" --state open --limit 200 \
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

# ============================================================================
# LIVE EXEMPTION LEDGER -- auto-retire + anti-accretion floor.
# ============================================================================
# The block above checks a PR against its exemption only when the PR is OPEN and
# overdue, because that is the only shape that can produce a RED. But an
# exemption also costs something while its PR is NOT in that shape: a row whose
# PR already merged or closed is dead weight, and a pile of still-live rows is
# the 783-exemption backlog forming again. So, independent of the per-PR sweep:
#
#   * AUTO-RETIRE: for each UNEXPIRED row, resolve the PR's state once. A
#     merged/closed PR's exemption is RETIREABLE -- it defers a PR that no
#     longer exists -- and is dropped from the live count, never a failure.
#   * LIVE CAP: the count of LIVE rows (unexpired AND still-open PR) may not
#     exceed LIVE_CAP. Over the cap is RED: the escape hatch is accreting
#     faster than it drains. Expired rows are NOT live (they are handled by the
#     per-PR RED path above and cleared by scripts/drain_pr_exemptions.sh), so
#     the legacy pile does not itself trip the cap -- only genuine live debt does.
#
# gh calls here are bounded by the number of UNEXPIRED rows, not the whole file:
# an expired row is skipped before any network call.
live_count=0; retireable=0; cap_unknown=0
retireable_names=""; live_names=""
while IFS=$'\t' read -r xref xreview; do
    [[ -z "$xref" ]] && continue
    [[ -n "$xreview" ]] || continue   # undated: not live; caught by the RED path if its PR is overdue
    xrev_epoch=$(date -j -f "%Y-%m-%d" "$xreview" "+%s" 2>/dev/null \
                 || date -d "$xreview" "+%s" 2>/dev/null)
    [[ -n "${xrev_epoch:-}" ]] || continue
    (( xrev_epoch < now_epoch )) && continue   # expired -> not live, no gh call
    xshort="${xref%%#*}"; xnum="${xref#*#}"
    [[ "$xnum" =~ ^[0-9]+$ ]] || continue       # malformed ref, skip the gh call
    xrepo="$(owner_repo_for_short "$xshort")"
    if [[ -z "$xrepo" ]]; then st="UNKNOWN"; else st="$(pr_state "$xrepo" "$xnum")"; fi
    case "$st" in
        OPEN)          live_count=$(( live_count + 1 )); live_names="${live_names}${xref}"$'\n' ;;
        CLOSED|MERGED) retireable=$(( retireable + 1 )); retireable_names="${retireable_names}  - ${xref} (${st})"$'\n' ;;
        UNKNOWN)       cap_unknown=$(( cap_unknown + 1 )) ;;
    esac
done < <(exempt_entries)

cap_over=0
say "== live exemptions: ${live_count} open / cap ${LIVE_CAP} | ${retireable} retireable (PR merged/closed) | ${cap_unknown} unresolved =="
if (( retireable > 0 )); then
    say ""
    say "RETIREABLE -- these exemptions defer a PR that has already merged or closed."
    say "They are NOT failing this gate, but they are dead weight. Clear them with:"
    say "  bash scripts/drain_pr_exemptions.sh --retire-closed"
    printf '%s' "$retireable_names"
fi
if (( live_count > LIVE_CAP )); then
    cap_over=1
    say ""
    say "== VERDICT: RED -- ${live_count} LIVE exemptions exceed the cap of ${LIVE_CAP} =="
fi

# ============================================================================
# PARTIAL RUNS FAIL CLOSED, DELIBERATELY.
# ============================================================================
# This used to stop at printing the shortfall. Printing is not enforcement:
# the exit code below still fell through to "0 violations found -> GREEN",
# and PARTIAL was decoration on a pass. Measured 2026-09-12 against the live
# estate: the one repo CI can resolve carried 1 PR over 30 days unmarked; the
# six it could not see carried 13 between them. The debt accumulated exactly
# where the gate was blind, while every run reported success.
#
# So: an unreachable repo is now a FAILURE unless a human named it on purpose.
# PR_AGE_ALLOW_PARTIAL is that decision -- same grammar as PR_AGE_REPOS above,
# a comma-separated list of the exact "owner/repo" strings this gate would
# otherwise refuse to pass over silently. Partitioned below into repos that
# WERE declared (a real, recorded choice to narrow this run) and repos that
# were not (an accident of which credential happened to be active).
declared=0
undeclared=0
declared_names=""
undeclared_names=""
if (( unreachable > 0 )); then
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        if [[ ",${ALLOW_PARTIAL}," == *",${r},"* ]]; then
            declared=$(( declared + 1 ))
            declared_names="${declared_names}${r}"$'\n'
        else
            undeclared=$(( undeclared + 1 ))
            undeclared_names="${undeclared_names}${r}"$'\n'
        fi
    done <<< "$unreachable_names"
fi

# The verdict word, so a partial run can never be read as a complete one. Its
# sibling verify_no_orphaned_fixes.sh has said "GREEN, PARTIAL" and "NOT
# CHECKED IN THIS ENVIRONMENT" since #643; this gate is the same shape and was
# silent about it. Same repo, same cut, two gates -- now the same honesty.
#
# An UNDECLARED blind spot can never be certified GREEN, whatever the checked
# repos found -- that is the whole fix. A DECLARED one keeps the ordinary
# colour, because a human already chose to accept the gap.
if (( unreachable > 0 )); then
    if (( undeclared > 0 )); then
        say "== VERDICT: RED, PARTIAL -- ${undeclared} of ${total_repos} repo(s) NOT CHECKED and NOT DECLARED =="
    else
        colour="GREEN"; (( violations > 0 )) && colour="RED"
        say "== VERDICT: ${colour}, PARTIAL (DECLARED) -- ${declared} of ${total_repos} repo(s) deliberately narrowed via PR_AGE_ALLOW_PARTIAL =="
    fi
    say ""
    say "NOT CHECKED IN THIS ENVIRONMENT:"
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        marker=""
        [[ ",${ALLOW_PARTIAL}," == *",${r},"* ]] && marker=" (declared in PR_AGE_ALLOW_PARTIAL)"
        say "  - ${r}${marker}"
    done <<< "$unreachable_names"
    say ""
    if (( undeclared > 0 )); then
        say "This run says NOTHING about ${undeclared} of those repo(s) either way -- it did"
        say "not fail to find overdue PRs there, it failed to look, and nobody said that"
        say "was fine. The usual cause is a repo-scoped token: gh cannot list a sibling"
        say "repo's PRs even under the same owner, and never across an org boundary."
        say ""
        say "This run FAILS (see exit code) rather than passing quietly. Restore access"
        say "(a per-owner credential -- see PR_AGE_TOKEN_<OWNER> at the top of this"
        say "script) and re-run, or accept a genuinely narrowed run on purpose:"
        first_undeclared="$(head -1 <<< "$undeclared_names")"
        say "  PR_AGE_ALLOW_PARTIAL=\"${first_undeclared}\" bash scripts/verify_pr_age.sh"
        say "That is a decision someone takes, not an accident of which credential"
        say "happened to be active."
    else
        say "Every unreachable repo above was named in PR_AGE_ALLOW_PARTIAL -- a"
        say "deliberate, recorded decision to narrow this run, not a credential"
        say "accident. This does NOT mean those repos are clean; it means nobody asked."
    fi
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

# The anti-accretion floor. Reported as exit 1 (a real, found problem) ahead of
# the "could not look" exit 3 below, for the same reason violations are: a
# definite breach must not be laundered into a vaguer "cannot verify". The count
# is monotonic in resolved-OPEN rows only, so an unresolved state can never cause
# this -- if we are over the cap, we have hard evidence of it.
if (( cap_over > 0 )); then
    cat >&2 <<EOF

ERROR: ${live_count} LIVE exemptions (unexpired, PR still open) exceed the cap of
${LIVE_CAP}. The pr_exemptions: block is an escape hatch, not a parking lot, and
it is accreting faster than it drains -- exactly how 176 open PRs became 783
exemptions.

Bring the live count back under ${LIVE_CAP}:
  * merge or close the PRs these exemptions defer (that retires the row), or
  * if the backlog is genuinely legacy, drain it:
      bash scripts/drain_pr_exemptions.sh --retire-closed   # safe, closed/merged only
  * raise the cap ONLY as a deliberate, recorded decision in cut-deferrals.yaml
    (pr_exemptions_live_cap:) -- not to quiet this run.
EOF
    exit 1
fi

# THIS IS THE FIX. An undeclared blind spot is a failure, never a footnote --
# see "PARTIAL RUNS FAIL CLOSED" above. Checked AFTER violations, on purpose:
# a real violation found in what WAS checked is reported as that violation
# (exit 1, above), not laundered into a vaguer "could not verify" (exit 3).
# Reusing exit 3 here, rather than inventing a fourth code, means the existing
# CI wrapper (gui/Makefile check-pr-age) already prints the right remedy for
# this case with no wrapper change: "COULD NOT RUN ... it failed to look ...
# DO NOT SHIP."
if (( undeclared > 0 )); then
    cat >&2 <<EOF

ERROR: ${undeclared} repo(s) this gate is supposed to police could NOT be
checked, and nobody declared that on purpose.

A gate that could not look has not found "no violations" -- it has found
nothing. Reporting success here is exactly how debt accumulates: measured
2026-09-12, the one repo CI could resolve had 1 unmarked PR over 30 days old;
the six it could not see had 13 between them.

Restore access -- usually a per-owner credential, see PR_AGE_TOKEN_<OWNER> at
the top of scripts/verify_pr_age.sh -- and re-run. Or accept a genuinely
narrowed run as a deliberate decision:
  PR_AGE_ALLOW_PARTIAL="owner/repo1,owner/repo2" bash scripts/verify_pr_age.sh

DO NOT SHIP on the strength of a run that did not look everywhere it claims to.
EOF
    exit 3
fi

say "GREEN: no PR has outstayed the ${MAX_HOURS}h limit."
exit 0
