#!/usr/bin/env bash
# ============================================================================
# drain_pr_exemptions.sh -- clear the legacy pr_exemptions: backlog, phased.
# ============================================================================
# On 2026-10-17 the pr_exemptions: block in cut-deferrals.yaml held ~783 rows,
# every one expired. verify_pr_age.sh now caps the LIVE count and auto-retires
# merged/closed rows FROM THAT COUNT, but it deliberately does not mutate the
# tracked file during a gate run (a gate that rewrites what it checks is not a
# gate). This script is where the file is actually drained, and it is phased
# because the four phases need four different amounts of judgement:
#
#   1. archive-tag     every exemption's PR head is tagged archive/<date>/pr-N
#                      BEFORE anything is closed, so closing can never lose work.
#                      (needs the PR head ref -> gh; guarded, skipped if absent.)
#   2. retire-closed   rows whose PR already merged/closed are dead weight.
#                      SAFE AND MECHANICAL: one `gh pr view` each, then the row
#                      is removed from cut-deferrals.yaml. This is the bulk.
#   3. cluster dupes   the still-open rows are grouped by repo and printed as a
#                      worklist, so duplicates land in one human pass.
#   4. merge/close     a human decision per keeper. NOT automated here -- the
#                      script prints the list and stops.
#
# DRY-RUN BY DEFAULT. Nothing is written and no PR is touched unless a phase
# flag is passed. Idempotent: re-running --retire-closed after a drain is a
# no-op because the rows are already gone.
#
# USAGE
#   bash scripts/drain_pr_exemptions.sh                 # dry-run: show the plan
#   bash scripts/drain_pr_exemptions.sh --retire-closed # remove merged/closed rows (writes the file)
#   bash scripts/drain_pr_exemptions.sh --archive-tag   # tag PR heads (needs gh + push)
#
# Env: OSTLER_CUT_DEFERRALS (file), PR_AGE_REPOS (owner map), PR_AGE_TOKEN_<OWNER>.
# ============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFERRALS="${OSTLER_CUT_DEFERRALS:-${REPO_ROOT}/cut-deferrals.yaml}"
ARCHIVE_DATE="${DRAIN_ARCHIVE_DATE:-$(date +%Y-%m-%d)}"

DEFAULT_REPOS="andygmassey/CM051-Home-Hub-Installer
andygmassey/CM044-PWG-Personal-Wiki
andygmassey/CM041-People-Graph
andygmassey/CM059-Ostler-Editor
andygmassey/CM031-PWG-Companion
andygmassey/HR015-Gaming-PC
ostler-ai/ostler-assistant"
REPOS="${PR_AGE_REPOS:-$DEFAULT_REPOS}"

MODE="dry-run"
case "${1:-}" in
    --retire-closed) MODE="retire-closed" ;;
    --archive-tag)   MODE="archive-tag" ;;
    "" )             MODE="dry-run" ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

say() { printf '%s\n' "$*"; }

[[ -f "$DEFERRALS" ]] || { say "no deferrals file at $DEFERRALS -- nothing to drain"; exit 0; }

# --- shared with verify_pr_age.sh: owner resolution + gh token + state -------
token_for_owner() {
    local owner="$1" var tok
    var="PR_AGE_TOKEN_$(printf '%s' "$owner" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"
    var="${var%_}"; tok="${!var:-}"
    if [[ -z "$tok" ]] && command -v gh >/dev/null 2>&1; then
        tok="$(gh auth token -u "$owner" 2>/dev/null || true)"
    fi
    printf '%s' "$tok"
}
gh_as() { local t="$1"; shift; if [[ -n "$t" ]]; then GH_TOKEN="$t" gh "$@"; else gh "$@"; fi; }

owner_repo_for_short() {
    local short="$1" r
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        [[ "${r#*/}" == "$short" ]] && { printf '%s' "$r"; return; }
    done <<< "$REPOS"
}
pr_state() {
    local repo="$1" num="$2" owner tok st
    owner="${repo%%/*}"; tok="$(token_for_owner "$owner")"
    st="$(gh_as "$tok" pr view "$num" --repo "$repo" --json state --jq '.state' 2>/dev/null)" || st=""
    case "$st" in OPEN) echo OPEN;; CLOSED) echo CLOSED;; MERGED) echo MERGED;; *) echo UNKNOWN;; esac
}

# Emit "ref" for each pr_exemptions entry. Same range rule as the gate:
# everything from the pr_exemptions: line to EOF.
exempt_refs() {
    sed -n '/^pr_exemptions:/,$p' "$DEFERRALS" | awk '
        /^[[:space:]]*-[[:space:]]*ref:/ {
            r=$0; sub(/^[[:space:]]*-[[:space:]]*ref:[[:space:]]*"?/,"",r); sub(/"?[[:space:]]*$/,"",r)
            print r
        }'
}

# Remove whole entries (the `- ref:` line and its indented continuation lines)
# for the refs listed in <file>, preserving every comment and every other entry
# byte-for-byte. An entry's continuation is any following line indented with at
# least four spaces; the entry ends at the next `- ref:`, comment, blank, or
# dedent. Writes the new file to stdout.
strip_refs() { # <refs-to-remove-file>
    awk -v rmfile="$1" '
        BEGIN { while ((getline l < rmfile) > 0) { if (l != "") rm[l]=1 } }
        {
            if ($0 ~ /^[[:space:]]*-[[:space:]]*ref:/) {
                r=$0; sub(/^[[:space:]]*-[[:space:]]*ref:[[:space:]]*"?/,"",r); sub(/"?[[:space:]]*$/,"",r)
                if (r in rm) { skip=1; next }
                else { skip=0; print; next }
            }
            # continuation of an entry: 4+ leading spaces and not a list item.
            if (skip && $0 ~ /^    [^ ]/ && $0 !~ /^[[:space:]]*-/) { next }
            skip=0
            print
        }
    ' "$DEFERRALS"
}

say "== drain pr_exemptions ($MODE) =="
say "file: $DEFERRALS"
say ""

# Resolve every ref's state (one gh pr view each). Bucket them.
closed_file="$(mktemp)"; open_file="$(mktemp)"; unknown_file="$(mktemp)"
trap 'rm -f "$closed_file" "$open_file" "$unknown_file"' EXIT
total=0
while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    total=$(( total + 1 ))
    short="${ref%%#*}"; num="${ref#*#}"
    if [[ ! "$num" =~ ^[0-9]+$ ]]; then printf '%s\n' "$ref" >> "$unknown_file"; continue; fi
    repo="$(owner_repo_for_short "$short")"
    if [[ -z "$repo" ]] || ! command -v gh >/dev/null 2>&1; then
        printf '%s\n' "$ref" >> "$unknown_file"; continue
    fi
    case "$(pr_state "$repo" "$num")" in
        MERGED|CLOSED) printf '%s\n' "$ref" >> "$closed_file" ;;
        OPEN)          printf '%s\t%s\n' "$short" "$ref" >> "$open_file" ;;
        *)             printf '%s\n' "$ref" >> "$unknown_file" ;;
    esac
done < <(exempt_refs)

# grep -c always prints a count (0 when empty) and exits 1 on no-match; capture
# the number and ignore the exit code -- an `|| echo 0` would append a SECOND
# zero and corrupt the arithmetic below.
n_closed=$(grep -c . "$closed_file" 2>/dev/null); n_closed=${n_closed:-0}
n_open=$(grep -c . "$open_file" 2>/dev/null); n_open=${n_open:-0}
n_unknown=$(grep -c . "$unknown_file" 2>/dev/null); n_unknown=${n_unknown:-0}
say "total exemptions: ${total} | merged/closed: ${n_closed} | open: ${n_open} | unresolved: ${n_unknown}"
say ""

if [[ "$MODE" == "archive-tag" ]]; then
    command -v gh >/dev/null 2>&1 || { say "gh not available -- cannot archive-tag"; exit 3; }
    say "Phase 1 -- archive-tag PR heads before any close (archive/${ARCHIVE_DATE}/pr-N):"
    while IFS=$'\t' read -r short ref; do
        [[ -z "$ref" ]] && continue
        num="${ref#*#}"; repo="$(owner_repo_for_short "$short")"
        say "  would tag ${repo}#${num} head as archive/${ARCHIVE_DATE}/pr-${num}"
    done < "$open_file"
    say ""
    say "Archive-tagging mutates remote tags and is left to a human run with push"
    say "rights -- the commands above are the plan, not an executed sweep."
    exit 0
fi

# Phase 3 -- cluster the still-open rows by repo, the human worklist.
if (( n_open > 0 )); then
    say "Phase 3 -- OPEN exemptions, clustered by repo (merge keepers / close rest, by hand):"
    sort "$open_file" | awk -F'\t' '{ if ($1 != last) { print "  " $1 ":"; last=$1 } print "    " $2 }'
    say ""
fi
if (( n_unknown > 0 )); then
    say "UNRESOLVED (repo not in PR_AGE_REPOS, or gh unavailable) -- not drained:"
    sed 's/^/  - /' "$unknown_file"
    say ""
fi

if (( n_closed == 0 )); then
    say "Nothing to retire: no exemption defers a merged/closed PR."
    [[ "$MODE" == "retire-closed" ]] && say "(file unchanged)"
    exit 0
fi

say "Phase 2 -- RETIREABLE (PR already merged/closed), ${n_closed} row(s):"
sed 's/^/  - /' "$closed_file"
say ""

if [[ "$MODE" != "retire-closed" ]]; then
    say "DRY RUN -- nothing written. Re-run with --retire-closed to remove the"
    say "${n_closed} retireable row(s) above from ${DEFERRALS}."
    exit 0
fi

tmp="$(mktemp)"
strip_refs "$closed_file" > "$tmp"
# Safety: the new file must be SMALLER (rows removed) and must still parse as
# having the pr_exemptions: anchor. Never write a file that lost the anchor.
if ! grep -q '^pr_exemptions:' "$tmp"; then
    say "REFUSED: rewrite lost the pr_exemptions: anchor -- not writing." >&2
    rm -f "$tmp"; exit 1
fi
remaining="$(sed -n '/^pr_exemptions:/,$p' "$tmp" | grep -c '^[[:space:]]*-[[:space:]]*ref:')"
expected=$(( total - n_closed ))
if [[ "$remaining" != "$expected" ]]; then
    say "REFUSED: expected ${expected} rows after retiring ${n_closed} of ${total}, got ${remaining} -- not writing." >&2
    rm -f "$tmp"; exit 1
fi
mv "$tmp" "$DEFERRALS"
say "Retired ${n_closed} merged/closed exemption(s). ${remaining} row(s) remain."
say "Review the diff and commit: git diff -- ${DEFERRALS#"$REPO_ROOT"/}"
exit 0
