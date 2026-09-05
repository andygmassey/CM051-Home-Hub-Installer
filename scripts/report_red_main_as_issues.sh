#!/usr/bin/env bash
# A RED MAIN MUST OPEN AN ISSUE. IT MUST NOT BE AN EMAIL TO ANDY.
#
# WHY THIS EXISTS. MEASURED 2026-09-05/06. main went red at eeb20aa4 and stayed
# red across ecef1565 and c6b5932c, about one hour. Nothing in this repo
# noticed. It was found because Andy received four GitHub notification emails,
# screenshotted them and pasted them into a session, then asked the question
# this script answers: "Isn't there some better way than me receiving emails and
# sometimes remembering to copy them to you?"
#
# The failure it hid is the serious kind. `cut-gate-wrappers` red means
# `rollforward_gate.sh` cannot parse the cut, preflight reds, and THE CUT JOB IS
# SKIPPED WITH NOTHING SIGNED while every earlier step still looks fine. A cut
# that quietly does not happen is harder to notice than one that fails.
#
# WHAT IT DOES. Finds UNRECOVERED failures on main, opens ONE issue per
# (workflow, sha), and closes it again when that workflow next goes green on
# main. The issue is the durable artefact: it outlives any session, every agent
# can see it, and once the checklist gate lands it becomes a row that must be
# dispositioned rather than a mail nobody opens.
#
# ── 🔴 THE PAGE IS NOT THE WINDOW. THIS BIT ME TWICE WHILE WRITING IT. ──────
# One push to main fires 136 workflows within the same second. MEASURED:
#
#     per_page=60  on main            60 runs, newest == oldest == 17:43:11Z
#     per_page=100 status=success     100 runs spanning FIVE SECONDS
#
# So a page count is not a time window, at any page size. The first version
# reported "0 failures" with three known reds hours earlier in the same branch,
# and the second still could not see a workflow's own recovery because the
# recovery had already fallen off page one. `created=>` bounds the OLD edge of
# the query; nothing bounds the NEW edge except the page.
#
# The fix is to stop asking a shared firehose a question about one workflow.
# Recovery is asked PER WORKFLOW, on that workflow's own runs endpoint, where
# per_page=1 is exactly "the newest success of this workflow" and pagination
# cannot hide it.
#
# ── THE ZERO HAS A SHAPE ────────────────────────────────────────────────────
# "main is clean" and "the query is broken" both print zero failures, so a
# LIVENESS CONTROL runs first as its own query: main is busy and always has
# runs, so zero there means the instrument is dead, not the branch quiet.
#
# THREE STATES. 0 ran and reported, 2 CANNOT-RUN. A query that could not run is
# not a green main, and this refuses rather than printing a comforting zero.
set -uo pipefail

REPO="${OSTLER_RED_MAIN_REPO:-andygmassey/CM051-Home-Hub-Installer}"
WINDOW_H="${OSTLER_RED_MAIN_WINDOW_H:-24}"
PAGE="${OSTLER_RED_MAIN_PAGE:-100}"
LABEL="main-red"
DRY="${OSTLER_RED_MAIN_DRY_RUN:-0}"

say() { printf '%s\n' "$*"; }
die_cannot_run() { printf 'CANNOT-RUN: %s\n' "$*" >&2; exit 2; }

command -v gh >/dev/null 2>&1 || die_cannot_run "gh is not on PATH, so main's state was NOT measured."
command -v jq >/dev/null 2>&1 || die_cannot_run "jq is not on PATH, so main's state was NOT measured."

TMP="$(mktemp -d)" || die_cannot_run "no working directory"
trap 'rm -rf "$TMP"' EXIT

# `date` differs between BSD and GNU and this runs on both: on the ubuntu
# runner, and on a Mac when a human runs it by hand. Try both spellings and
# refuse if neither works, rather than silently computing a wrong window.
if SINCE="$(date -u -v-"${WINDOW_H}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" && [ -n "$SINCE" ]; then :
elif SINCE="$(date -u -d "${WINDOW_H} hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" && [ -n "$SINCE" ]; then :
else die_cannot_run "neither BSD nor GNU date could compute the window, so the lookback would be wrong."
fi
say "window: failures on main created since ${SINCE} (${WINDOW_H}h)"

api() { gh api "$1" > "$2" 2>"${TMP}/err"; }

# ── LIVENESS CONTROL, ITS OWN QUERY ─────────────────────────────────────────
# A clean main legitimately returns zero failures, so the failure query cannot
# double as its own control. This asks something whose answer can never
# legitimately be zero.
api "repos/${REPO}/actions/runs?branch=main&per_page=1" "${TMP}/ctl.json" \
    || { cat "${TMP}/err" >&2 || true; die_cannot_run "the liveness query failed. This is NOT a clean main."; }
jq -e . "${TMP}/ctl.json" >/dev/null 2>&1 || die_cannot_run "the liveness query returned something that is not JSON."
LIVE="$(jq -r '(.workflow_runs // []) | length' "${TMP}/ctl.json")"
case "$LIVE" in ''|*[!0-9]*) die_cannot_run "could not count the control runs." ;; esac
[ "$LIVE" -gt 0 ] || die_cannot_run "the control found ZERO runs on main. main is busy, so the instrument is broken, not the branch quiet."
say "control: main has runs, so the instrument can see this branch"

# ── THE SUBJECT QUERY. Parameters go IN THE URL: `gh api` has no --arg flag,
# and passing one makes it read the value as a positional and hand back a shape
# that reads as an empty result.
api "repos/${REPO}/actions/runs?branch=main&status=failure&created=%3E${SINCE}&per_page=${PAGE}" "${TMP}/fail.json" \
    || { cat "${TMP}/err" >&2 || true; die_cannot_run "the failure query failed. This is NOT a clean main."; }
jq -e . "${TMP}/fail.json" >/dev/null 2>&1 || die_cannot_run "the failure query returned something that is not JSON."

jq -c '(.workflow_runs // []) | map(select(.status == "completed"))
       | .[] | {name, head_sha, created_at, html_url, workflow_id}' "${TMP}/fail.json" > "${TMP}/fail.ndjson"
N_FAIL="$(grep -c . "${TMP}/fail.ndjson" || true)"
say "denominator: ${N_FAIL:-0} completed failure(s) on main in the window"

# Newest success of ONE workflow, asked on that workflow's own endpoint so the
# answer cannot be truncated away by a busy neighbour.
newest_success_for() {
    local wid="$1"
    gh api "repos/${REPO}/actions/workflows/${wid}/runs?branch=main&status=success&per_page=1" 2>/dev/null \
        | jq -r '(.workflow_runs // []) | if length > 0 then .[0].created_at else "" end' 2>/dev/null
}

# ── OPEN one issue per UNRECOVERED (workflow, sha) ──────────────────────────
# Read with `while IFS= read -r` from a file, never `for x in $VAR`: zsh does
# not word-split an unquoted variable, so that loop runs ONCE with the whole
# list and every field is wrong.
while IFS= read -r row; do
    [ -n "$row" ] || continue
    wf="$(printf '%s' "$row"      | jq -r .name)"
    sha="$(printf '%s' "$row"     | jq -r .head_sha)"
    created="$(printf '%s' "$row" | jq -r .created_at)"
    url="$(printf '%s' "$row"     | jq -r .html_url)"
    wid="$(printf '%s' "$row"     | jq -r .workflow_id)"
    short="${sha:0:7}"
    title="main is red: ${wf} at ${short}"

    # A red main that has already recovered is history, not an open defect.
    # Without this, every historical red is reopened on every run and the close
    # loop shuts it again seconds later, which teaches people to ignore the
    # label. ISO-8601 UTC sorts lexicographically, so no date arithmetic is
    # needed and no BSD/GNU difference can bite.
    ok_at="$(newest_success_for "$wid")"
    if [ -n "$ok_at" ] && [ "$created" \< "$ok_at" ]; then
        say "  recovered (green at ${ok_at}): ${wf} at ${short}"
        continue
    fi

    existing="$(gh issue list --repo "$REPO" --state open --label "$LABEL" --limit 100 \
                  --json number,title --jq ".[] | select(.title == \"${title}\") | .number" 2>/dev/null || true)"
    # Only a NUMBER means "already open". MEASURED: when the listing returns
    # anything unexpected (an empty JSON array, an error banner), a bare -n test
    # reads it as an existing issue and SILENTLY SKIPS the report. That is the
    # failure this whole script exists to prevent, reintroduced one layer in.
    case "$existing" in
        '') : ;;
        *[!0-9]*) say "  WARN: the issue listing for ${title} returned something that is not an issue number; treating as NOT open" ; existing='' ;;
        *) say "  already open as #${existing}: ${title}" ; continue ;;
    esac

    say "  OPENING: ${title}"
    [ "$DRY" = "1" ] && continue
    {
        printf '`%s` failed on **main** at `%s` and main has not recovered since.\n\n' "$wf" "$sha"
        printf '    run:  %s\n    sha:  %s\n    when: %s\n\n' "$url" "$sha" "$created"
        printf 'Opened automatically. The previous red main was found by a human reading\n'
        printf 'notification email, an hour after it went red.\n\n'
        printf '**Why this matters more than the red light.** A red cut gate does not\n'
        printf 'merely fail: it can make the cut job SKIP with nothing signed, which\n'
        printf 'looks like a run that simply had nothing to do.\n\n'
        printf 'This issue closes itself when `%s` next succeeds on main. If you fix it,\n' "$wf"
        printf 'you do not need to close it by hand.\n'
    } > "${TMP}/body.md"
    gh issue create --repo "$REPO" --title "$title" --body-file "${TMP}/body.md" \
        --label "$LABEL" >/dev/null 2>&1 || say "  WARN: could not create the issue for ${title}"
done < "${TMP}/fail.ndjson"

# ── CLOSE any main-red issue whose workflow has since gone green ────────────
gh issue list --repo "$REPO" --state open --label "$LABEL" --limit 100 \
    --json number,title --jq '.[] | "\(.number) \(.title)"' > "${TMP}/open.txt" 2>/dev/null || true

while IFS= read -r line; do
    [ -n "$line" ] || continue
    num="${line%% *}"; title="${line#* }"
    case "$title" in "main is red: "*) : ;; *) continue ;; esac
    wf="${title#main is red: }"; wf="${wf% at *}"
    short="${title##* at }"
    wid="$(jq -r --arg w "$wf" 'select(.name == $w) | .workflow_id' "${TMP}/fail.ndjson" 2>/dev/null | head -1)"
    if [ -z "$wid" ]; then
        # Not in this window's failures at all, so resolve the id by name.
        wid="$(gh api "repos/${REPO}/actions/workflows?per_page=100" 2>/dev/null \
                | jq -r --arg w "$wf" '(.workflows // [])[] | select(.name == $w) | .id' 2>/dev/null | head -1)"
    fi
    [ -n "$wid" ] || { say "  SKIP #${num}: could not resolve a workflow id for ${wf}, so recovery was NOT measured"; continue; }
    ok_at="$(newest_success_for "$wid")"
    [ -n "$ok_at" ] || continue
    bad_at="$(jq -r --arg w "$wf" --arg s "$short" \
        'select(.name == $w and (.head_sha | startswith($s))) | .created_at' "${TMP}/fail.ndjson" 2>/dev/null | sort | tail -1)"
    if [ -n "$bad_at" ] && [ "$ok_at" \< "$bad_at" ]; then
        continue   # the green predates the red, so the red still stands
    fi
    say "  CLOSING #${num}: ${wf} has since gone green on main"
    [ "$DRY" = "1" ] && continue
    gh issue close "$num" --repo "$REPO" \
        --comment "\`${wf}\` has since succeeded on main (${ok_at}). Closing automatically." \
        >/dev/null 2>&1 || say "  WARN: could not close #${num}"
done < "${TMP}/open.txt"

say "done."
exit 0
