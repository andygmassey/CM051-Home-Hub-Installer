#!/usr/bin/env bash
# verify_cut_freshness.sh -- LIVE-HEAD pre-cut freshness gate.
# ===========================================================
#
# THE LEAK THIS PLUGS
# The Ostler DMG is assembled from many independently-versioned inputs: vendored
# source trees (pinned by SHA in vendor/VENDOR_MANIFEST.toml), the ostler-assistant
# daemon tarball (pinned by version in install.sh / gui/Makefile), and the wiki
# Docker images (pinned by digest in install.sh). Every past "built but not in the
# cut" incident had the same shape: a fix MERGED to a source main, but the input
# the cut actually shipped still pointed at an OLDER commit. Examples this gate
# would have caught RED:
#   - a daemon tarball that predated the Ollama tool-calling fix (#216);
#   - wiki images that lagged CM044 main and so shipped WITHOUT the privacy
#     fixes #121 / #122 (BUG-038).
#
# WHAT MAKES THIS GATE DIFFERENT
# It compares every shippable input to the LIVE upstream HEAD on GitHub, via the
# GitHub API -- NOT local git checkouts (which can be sick, stale or on a detached
# rebase), and NOT a manifest's own "ahead-by-N" bookkeeping (which misfires when
# the record itself is stale). The only source of truth it trusts is what GitHub
# reports for the tracked branch RIGHT NOW.
#
# It complements the two existing gates rather than duplicating them:
#   - verify_vendor_fresh.sh  proves vendored trees match their pinned source
#                             (content diff) using LOCAL source checkouts;
#   - verify_cut_provenance.sh proves specific named fixes are present in the
#                             about-to-ship artefacts (marker ledger);
#   - THIS gate proves NOTHING has silently fallen behind live upstream HEAD --
#     including the daemon + wiki-image inputs the other two only spot-check.
#
# NO SILENT DOWNGRADE (the hole this rev closes)
#   A previous rev let a `verify = skip` tree WARN (non-fatal) when stale. That
#   was the leak: a tree whose source IS fetchable from GitHub could silently
#   fall behind. This rev removes that downgrade entirely. Two -- and only two --
#   ways a tree may be anything other than fresh:
#     1. EXEMPTION (auditable allowlist). A GENUINELY unverifiable source (e.g.
#        CM019 -- not a git repo; a source path relocated off GitHub) may opt out
#        ONLY via  verify_exempt = true  PLUS  exempt_reason = "..."  in its
#        manifest entry. Exempt WITHOUT a reason is fail-closed RED. There is no
#        silent WARN: an exemption is a visible, reasoned ledger row.
#     2. DELIBERATE HOLD (the must-acknowledge ledger). A pin may sit BEHIND live
#        HEAD only if its entry carries a hold_ack block:
#          hold_ack_shas             = "<every delta commit, space/comma list>"
#          hold_ack_reason           = "why the pin is held"
#          shipping_bugfixes_grafted = true   (explicit human assertion)
#        On each run the gate enumerates the LIVE path-scoped delta (pin..HEAD).
#        If ANY delta commit is NOT in hold_ack_shas -> RED, naming the
#        un-acknowledged commits and telling the operator to classify each
#        (graft-the-bugfix, or add-to-hold_ack-with-reason). This converts silent
#        drift into a loud decision -- it is what catches the calendar-date bug
#        (HR015 7f7710f) fixed in source but never grafted into the vendored tree.
#
# FAIL-CLOSED, BOUNDED, AUTHORITATIVE
#   * Exit 1 if ANY verifiable input is behind live HEAD without a covering
#     hold_ack, or is exempt without a reason -- the cut CANNOT proceed past here.
#   * Exit 3 (CANNOT VERIFY) -- a DISTINCT, still-non-zero status -- if GitHub is
#     genuinely unreachable after a retry. Never a false "fresh". The cut aborts.
#   * Exit 0 only when every input is FRESH, HELD (fully-acknowledged) or EXEMPT
#     (with a reason).
#   * Every network read has a generous timeout + one retry; a hung endpoint
#     degrades to CANNOT VERIFY, never an infinite wait.
#
# Inputs checked:
#   1. Vendor pins  (vendor/VENDOR_MANIFEST.toml -- per-tree, path-scoped)
#   2. Daemon       (install.sh / gui/Makefile pin -> tag -> PUBLISHED release
#                    asset: .sha256 sidecar + build-info.json commit_sha)
#   3. Wiki images  (install.sh digest -> scripts/wiki_image_provenance.tsv ->
#                    recorded CM044 sha compared against CM044 main HEAD)
#
# Usage:   scripts/verify_cut_freshness.sh
# Env (all optional):
#   CM044_BRANCH               wiki source branch (default: main)
#   WIKI_PROVENANCE_FILE       path to the digest->CM044-sha ledger
#                              (default: scripts/wiki_image_provenance.tsv)
#   FRESHNESS_ONLY             restrict the run to a single vendor tree by name
#                              (ops/debug + self-demo; SKIPS the daemon check)
#   GH_API_TIMEOUT             per-call timeout in seconds (default: 25)
#   FRESHNESS_GH_BIN           override the `gh` binary (tests inject a mock)
#
# British English throughout; " -- " not em-dashes.

set -uo pipefail   # deliberately NOT -e: we classify every failure ourselves.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Reuse the tiny dependency-free TOML reader (vlib_tree_names / vlib_field).
# _vendor_lib.sh sets `set -euo pipefail` when sourced -- undo the -e so a single
# non-zero read cannot abort the whole gate mid-table.
# shellcheck source=scripts/_vendor_lib.sh
. "$SCRIPT_DIR/_vendor_lib.sh"
set +e

# Real cut reads the shipping install.sh / gui Makefile; tests point these at
# fixtures via the *_OVERRIDE env vars.
INSTALL_SH="${INSTALL_SH_OVERRIDE:-$REPO_ROOT/install.sh}"
GUI_MAKEFILE="${GUI_MAKEFILE_OVERRIDE:-$REPO_ROOT/gui/Makefile}"
CM044_BRANCH="${CM044_BRANCH:-main}"
WIKI_PROVENANCE_FILE="${WIKI_PROVENANCE_FILE:-$SCRIPT_DIR/wiki_image_provenance.tsv}"
WIKI_HOLD_ACK_FILE="${WIKI_HOLD_ACK_FILE:-$SCRIPT_DIR/wiki_hold_ack.tsv}"
# Daemon recency: the branch the daemon's own repo tracks, and the ledger that
# lets a pin sit behind it deliberately. Same contract as the wiki hold_ack.
OA_BRANCH="${OA_BRANCH:-main}"
DAEMON_HOLD_ACK_FILE="${DAEMON_HOLD_ACK_FILE:-$SCRIPT_DIR/daemon_hold_ack.tsv}"
FRESHNESS_ONLY="${FRESHNESS_ONLY:-}"
GH_API_TIMEOUT="${GH_API_TIMEOUT:-25}"
GH_BIN="${FRESHNESS_GH_BIN:-gh}"

# --- verdict tallies ---
n_fresh=0
n_stale=0        # RED  -- behind live HEAD w/o hold_ack, or exempt w/o reason
n_held=0         # behind but FULLY acknowledged via hold_ack -- non-fatal
n_exempt=0       # genuinely-unverifiable source, exempt WITH a reason -- non-fatal
n_cannot=0       # could not be checked at all -- fail-closed, distinct exit
# Subset of n_cannot whose cause is "cannot READ the source repo" rather than
# "GitHub unreachable". Tracked separately because the remedies differ: one is
# a credential grant, the other is the network. Initialised here rather than
# on first use -- set -u is on, and an unset read in the verdict block would
# abort the script AFTER all the work, printing nothing.
n_unreadable=0

# Rows for the final table:  input \t pinned \t live \t status
ROWS_FILE="$(mktemp)"
# Human-readable detail lines (RED reasons, un-acked commit lists) printed
# before the verdict so the operator sees exactly what to do.
DETAILS_FILE="$(mktemp)"
trap 'rm -f "$ROWS_FILE" "$DETAILS_FILE"' EXIT
add_detail() { printf '%s\n' "$*" >> "$DETAILS_FILE"; }

short() { printf '%.8s' "${1:-}"; }

add_row() { # input  pinned  live  status
    printf '%s\t%s\t%s\t%s\n' "$1" "$(short "$2")" "$(short "$3")" "$4" >> "$ROWS_FILE"
}

# ---------------------------------------------------------------------------
# Portable timeout (macOS ships no coreutils `timeout`). Returns 124 on timeout.
# ---------------------------------------------------------------------------
run_to() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return $?; fi
    if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?; fi
    # Pure-bash fallback (macOS has no coreutils timeout). CRITICAL: this runs
    # inside $(...) command substitution, which does not return until EVERY
    # descendant that inherited the stdout pipe has closed it. The watchdog's
    # `sleep` child would otherwise hold that pipe open for the whole timeout --
    # hanging every call. Redirect the watchdog's fds to /dev/null so its sleep
    # never touches the captured pipe, and reap the sleep child when done.
    "$@" &
    local cpid=$!
    ( sleep "$secs"; kill -0 "$cpid" 2>/dev/null && kill -TERM "$cpid" 2>/dev/null
      sleep 2; kill -0 "$cpid" 2>/dev/null && kill -KILL "$cpid" 2>/dev/null ) >/dev/null 2>&1 &
    local wpid=$!
    local rc=0
    wait "$cpid" 2>/dev/null || rc=$?
    # Tear down the watchdog (and its sleep child) so nothing lingers.
    kill -TERM "$wpid" 2>/dev/null
    pkill -P "$wpid" >/dev/null 2>&1
    wait "$wpid" 2>/dev/null
    [ "$rc" = "143" ] && rc=124
    return "$rc"
}

# ---------------------------------------------------------------------------
# Per-account tokens, fetched once, so we never mutate the operator's ACTIVE gh
# account (source repos live under `andygmassey`, the daemon under `ostler-ai`).
# In mock mode (FRESHNESS_GH_BIN set) we skip real auth entirely.
# ---------------------------------------------------------------------------
# bash 3.2 on the macOS cut host has no associative arrays -- memoise into
# per-account plain variables (_TOK_<account-with-dashes-as-underscores>).
#
# ENVIRONMENT FIRST, AND THAT ORDER IS THE FIX (v1018-D621d).
#
# `gh auth token --user X` is a MULTI-ACCOUNT gh CLI concept. It resolves only
# where a human has logged several accounts in, which is the operator's Mac and
# never a hosted runner. On a runner it returns empty, `api()` then runs with
# GH_TOKEN="" and every request 404s.
#
# That is what produced fifteen byte-identical rows on cut run 31682172040:
#
#   vendor:cm041/assistant_api RED: pinned SHA could not be resolved ...
#   vendor:cm048_pipeline      RED: pinned SHA could not be resolved ...
#   ... 13 more, same string
#
# CONTROLLED before writing this. All 24 pins in VENDOR_MANIFEST.toml resolve
# against live GitHub with an account that HAS access -- 24 of 24, zero bad
# pins -- and all eight source repos report `private=true`. So the pins are
# fine and the checker could not authenticate. #642 made that report HONEST
# (CANNOT-VERIFY rather than "bad pin"); this makes the check RUN.
#
# Same shape, same remedy, as `_gh_token_for` in scripts/verify_cut_manifest.py:
# env first, `gh auth` second, and returning empty is CANNOT-RUN for the caller
# rather than a verdict about the artefact.
#
# The generic OSTLER_GH_TOKEN_<ACCOUNT> form means a third account needs a
# secret, not a code change. OSTLER_RELEASES_TOKEN stays wired for ostler-ai
# because the cut already carries it for exactly that owner.
token_for() {
    local acct="$1"
    [ -n "${FRESHNESS_GH_BIN:-}" ] && { printf 'mock-token'; return 0; }
    local key="_TOK_$(printf '%s' "$acct" | tr -c 'A-Za-z0-9' '_')"
    local cur; eval "cur=\${$key:-}"
    if [ -z "$cur" ]; then
        # 1. Per-account environment secret. Works on a runner AND on the Mac.
        local envname="OSTLER_GH_TOKEN_$(printf '%s' "$acct" | tr 'a-z-' 'A-Z_')"
        eval "cur=\${$envname:-}"
        # 2. The credential the cut already carries for the daemon's owner.
        if [ -z "$cur" ] && [ "$acct" = "ostler-ai" ]; then
            cur="${OSTLER_RELEASES_TOKEN:-}"
        fi
        # 3. Operator's Mac: the multi-account gh CLI. Absent on runners.
        if [ -z "$cur" ]; then
            cur="$(gh auth token --user "$acct" 2>/dev/null)"
        fi
        eval "$key=\$cur"
    fi
    printf '%s' "$cur"
}

# ---------------------------------------------------------------------------
# api <account> <gh-api-args...>
#   Sets API_OUT to stdout. Returns:
#     0 = success (HTTP 200)
#     1 = reachable but the request errored (e.g. 404 -- a *data* answer)
#     2 = UNREACHABLE (network/transport error or timeout, after one retry)
# ---------------------------------------------------------------------------
API_OUT=""
_raw_api() { # account, gh-api-args...
    local acct="$1"; shift
    local tok; tok="$(token_for "$acct")"
    GH_TOKEN="$tok" GH_HOST=github.com run_to "$GH_API_TIMEOUT" "$GH_BIN" api "$@" 2>/dev/null
}
api() {
    local acct="$1"; shift
    local out rc
    out="$(_raw_api "$acct" "$@")"; rc=$?
    if [ "$rc" -eq 0 ]; then API_OUT="$out"; return 0; fi
    # one retry -- transient GitHub 5xx / secondary-rate-limit / blip
    out="$(_raw_api "$acct" "$@")"; rc=$?
    if [ "$rc" -eq 0 ]; then API_OUT="$out"; return 0; fi
    API_OUT="$out"
    [ "$rc" -eq 124 ] && return 2                       # timeout -> unreachable
    # A reachable HTTP error (404/422) comes back as a JSON {"message":...} body.
    if printf '%s' "$out" | grep -q '"message"'; then return 1; fi
    return 2                                            # non-zero, no body -> transport failure
}

# repo_readable <acct> <owner/repo>
#   Echoes: YES | NO
#
#   v1018-D621c. GitHub answers 404 for a repo that does not exist AND for a
#   private repo the caller cannot see. api() classifies any JSON {"message":..}
#   body as rc=1 -> "reachable, no such thing" (line ~202), so a permissions 404
#   on the COMMITS endpoint became NONE -> UNRESOLVED -> "bad pin, or pin absent
#   from the source repo". Fifteen vendor trees reported that at once on cut run
#   31682172040 -- byte-identical, which is the shape of a broken probe rather
#   than fifteen independently broken pins.
#
#   CONTROLLED before writing this (Andy's instruction: do not take the
#   diagnosis as the finding). Five pins resolved by hand with the andygmassey
#   account, which HAS access:
#       cm041/assistant_api  f83d5aee1953  rc=0
#       cm041/ostler_hygiene 11ad1246286e  rc=0
#       cm048_pipeline       2133786a4532  rc=0
#       cm021                e1eefb3d3bd9  rc=0
#       ostler_fda           ab63b7be732d  rc=0
#   Every pin is GOOD. Had one failed to resolve, that pin would be a real
#   defect needing a re-pin -- reclassifying it as CANNOT-VERIFY would have
#   been worse than the bug. They did not, so it is the probe.
#
#   Corroboration from the same control, worth recording: on the commits
#   endpoint GitHub returns 422 "No commit found for SHA" for a readable repo
#   with an absent SHA, and 404 "Not Found" when it cannot show you the repo.
#   Different codes -- but that is not what this relies on, because a 404 can
#   also mean a missing REF. The repo probe is the primary discriminator; the
#   422 is only a sanity check that the two states are distinguishable at all.
repo_readable() {
    local acct="$1" repo="$2" rc
    api "$acct" "repos/$repo" --jq '.full_name'
    rc=$?
    # ONLY the unreadable shape short-circuits. rc=2 (timeout / transport) is a
    # DIFFERENT cannot-run and the callers below already handle it as UNREACH;
    # sweeping it in here would widen the not-checked bucket, which is the
    # warn-bucket-is-not-a-safe-bucket move. Deliberately narrow.
    if [ "$rc" -eq 1 ]; then echo "NO"; return; fi
    echo "YES"
}

# gh_head <acct> <owner/repo> <ref> [path]
#   Echoes: <sha> | NONE (reachable, no such commit/path) | UNREACH
gh_head() {
    local acct="$1" repo="$2" ref="$3" path="${4:-}"
    local rc
    if [ -n "$path" ] && [ "$path" != "." ]; then
        api "$acct" "repos/$repo/commits?sha=$ref&path=$path&per_page=1" --jq '.[0].sha // "NONE"'
    else
        api "$acct" "repos/$repo/commits/$ref" --jq '.sha'
    fi
    rc=$?
    if [ "$rc" -eq 2 ]; then echo "UNREACH"; return; fi
    if [ "$rc" -eq 1 ]; then echo "NONE"; return; fi
    local v; v="$(printf '%s' "$API_OUT" | tr -d '[:space:]')"
    [ -z "$v" ] && v="NONE"
    echo "$v"
}

# gh_compare <acct> <owner/repo> <base> <head>
#   Echoes: "<status> <ahead_by> <behind_by>"  |  "UNREACH"  |  "NONE"
#   status is identical|ahead|behind|diverged. ahead_by = commits <head> has
#   that <base> does not (i.e. how far <base> is BEHIND <head>).
gh_compare() {
    local acct="$1" repo="$2" base="$3" head="$4" rc
    api "$acct" "repos/$repo/compare/$base...$head" \
        --jq '(.status) + " " + (.ahead_by|tostring) + " " + (.behind_by|tostring)'
    rc=$?
    if [ "$rc" -eq 2 ]; then echo "UNREACH"; return; fi
    if [ "$rc" -eq 1 ]; then echo "NONE"; return; fi
    printf '%s' "$API_OUT" | tr -d '\n'
}

# freshness_verdict <acct> <owner/repo> <pinned_sha> <live_head>
#   Compares pinned to live_head. Echoes a status token:
#     FRESH | STALE:+<n> | DIVERGED:+<n> | UNRESOLVED | UNREACH
freshness_verdict() {
    local acct="$1" repo="$2" pinned="$3" live="$4"
    [ "$live" = "UNREACH" ] && { echo "UNREACH"; return; }
    [ "$live" = "NONE" ]    && { echo "UNRESOLVED"; return; }
    # Exact match is unambiguously fresh (also covers the common case cheaply).
    if [ "$live" = "$pinned" ]; then echo "FRESH"; return; fi
    local cmp; cmp="$(gh_compare "$acct" "$repo" "$pinned" "$live")"
    [ "$cmp" = "UNREACH" ] && { echo "UNREACH"; return; }
    [ "$cmp" = "NONE" ]    && { echo "UNRESOLVED"; return; }
    local status ahead; status="${cmp%% *}"; ahead="$(printf '%s' "$cmp" | awk '{print $2}')"
    case "$status" in
        identical|behind) echo "FRESH" ;;   # pinned already contains live_head
        ahead)            echo "STALE:+${ahead}" ;;
        diverged)         echo "DIVERGED:+${ahead}" ;;
        *)                echo "UNRESOLVED" ;;
    esac
}

# ---------------------------------------------------------------------------
# Source-repo resolution: map a manifest source_repo placeholder to a live
# GitHub (account, owner/repo) plus the path PREFIX inside that repo.
#   "$CM041"            -> andygmassey/CM041-People-Graph          prefix=""
#   "$HR015/ostler_fda" -> andygmassey/HR015-Gaming-PC            prefix="ostler_fda"
#   "$CM019/02 - Code"  -> (unmapped; CM019 is not a git repo)
# Prints:  <account> <owner/repo> <path-prefix>   (empty repo => unmapped)
# ---------------------------------------------------------------------------
resolve_github() {
    local raw="$1"
    raw="${raw#\$}"                       # strip leading $
    local var="${raw%%/*}"                # first path segment = placeholder name
    local prefix=""
    [ "$raw" != "$var" ] && prefix="${raw#*/}"
    local acct owner
    case "$var" in
        CM041) acct=andygmassey; owner="andygmassey/CM041-People-Graph" ;;
        CM019) acct=andygmassey; owner="andygmassey/personal-world-graph" ;;
        CM048) acct=andygmassey; owner="andygmassey/CM048-PWG-Conversation-Processing" ;;
        CM052) acct=andygmassey; owner="andygmassey/CM052" ;;
        CM021) acct=andygmassey; owner="andygmassey/email-intelligence" ;;
        CM024) acct=andygmassey; owner="andygmassey/evernote-knowledge" ;;
        CM059) acct=andygmassey; owner="andygmassey/CM059-Ostler-Editor" ;;
        CM044) acct=andygmassey; owner="andygmassey/CM044-PWG-Personal-Wiki" ;;
        HR015) acct=andygmassey; owner="andygmassey/HR015-Gaming-PC" ;;
        *)     acct="";          owner="" ;;   # CM019 etc -- no GitHub source
    esac
    printf '%s\t%s\t%s\n' "$acct" "$owner" "$prefix"
}

# Join a repo path-prefix with a manifest source_path ("." = repo root).
join_path() {
    local prefix="$1" sub="$2"
    [ "$sub" = "." ] && sub=""
    if [ -n "$prefix" ] && [ -n "$sub" ]; then printf '%s/%s' "$prefix" "$sub"
    elif [ -n "$prefix" ]; then printf '%s' "$prefix"
    else printf '%s' "$sub"; fi
}

# Classify a verdict for a NON-vendor input (daemon, wiki images). These carry
# no hold_ack / exemption: a stale daemon or wiki image is ALWAYS fail-closed.
classify_simple() { # input  pinned  live  verdict
    local input="$1" pinned="$2" live="$3" verdict="$4"
    local base="${verdict%%:*}"
    case "$base" in
        FRESH)          n_fresh=$((n_fresh+1));  add_row "$input" "$pinned" "$live" "FRESH" ;;
        UNREACH)        n_cannot=$((n_cannot+1)); add_row "$input" "$pinned" "$live" "CANNOT-VERIFY" ;;
        STALE|DIVERGED) n_stale=$((n_stale+1));   add_row "$input" "$pinned" "$live" "RED ${verdict}" ;;
        *)              n_stale=$((n_stale+1));   add_row "$input" "$pinned" "$live" "RED unresolved" ;;
    esac
}

# Read a manifest field as a boolean. Tolerates  field = true  and  field = "true".
manifest_bool() { # tree  field
    local v; v="$(vlib_field "$1" "$2" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    [ "$v" = "true" ] && { echo true; return; }
    echo false
}

# Is <sha> acknowledged by <list> (space/comma-separated, entries may be short)?
# Prefix-tolerant in BOTH directions so a 12-hex ack matches a 40-hex delta sha.
sha_in_list() { # sha  list
    local c="$1" e
    for e in $(printf '%s' "$2" | tr ',' ' '); do
        [ -z "$e" ] && continue
        case "$c" in "$e"*) return 0 ;; esac
        case "$e" in "$c"*) return 0 ;; esac
    done
    return 1
}

# Enumerate the LIVE path-scoped delta: SHAs of commits touching <gpath> on
# <branch> that are AHEAD of <pin> (newest first, one per line into DELTA_OUT).
# Sets DELTA_STATUS:
#   OK       enumerated precisely (pin found within the path history)
#   OVERFLOW pin not within the newest 100 path-commits -- catastrophically stale
#   DIVERGED pin absent from the path history (side branch / rewritten)
#   UNREACH  GitHub unreachable
DELTA_OUT=""
DELTA_STATUS=""
path_delta_shas() { # acct  owner/repo  branch  gpath  pin
    local acct="$1" repo="$2" branch="$3" gpath="$4" pin="$5"
    DELTA_OUT=""; DELTA_STATUS=""
    if [ -n "$gpath" ] && [ "$gpath" != "." ]; then
        api "$acct" "repos/$repo/commits?sha=$branch&path=$gpath&per_page=100" --jq '.[].sha'
    else
        api "$acct" "repos/$repo/commits?sha=$branch&per_page=100" --jq '.[].sha'
    fi
    local rc=$?
    if [ "$rc" -eq 2 ]; then DELTA_STATUS=UNREACH; return; fi
    if [ "$rc" -eq 1 ]; then DELTA_STATUS=DIVERGED; return; fi
    local list="$API_OUT" line acc="" found=0 n=0
    while IFS= read -r line; do
        line="$(printf '%s' "$line" | tr -d '[:space:]')"
        [ -z "$line" ] && continue
        n=$((n+1))
        case "$line" in "$pin"*) found=1; break ;; esac
        case "$pin" in "$line"*) found=1; break ;; esac
        acc="$acc$line
"
    done <<EOF
$list
EOF
    if [ "$found" -eq 1 ]; then DELTA_STATUS=OK; DELTA_OUT="$acc"
    elif [ "$n" -ge 100 ]; then DELTA_STATUS=OVERFLOW
    else DELTA_STATUS=DIVERGED; fi
}

echo "=== Cut-freshness gate (live GitHub HEAD) ==="
echo "manifest:            $VLIB_MANIFEST"
echo "daemon provenance:   ${OSTLER_RELEASES_REPO:-ostler-ai/ostler-releases} release asset -> tag -> commit"
echo "wiki source branch:  andygmassey/CM044-PWG-Personal-Wiki @ $CM044_BRANCH"
echo "provenance ledger:   $WIKI_PROVENANCE_FILE"
echo

# ===========================================================================
# 1. VENDOR PINS
# ===========================================================================
while IFS= read -r tree; do
    [ -z "$tree" ] && continue
    [ -n "$FRESHNESS_ONLY" ] && [ "$tree" != "$FRESHNESS_ONLY" ] && continue
    pinned="$(vlib_field "$tree" pinned_sha)"
    subpath="$(vlib_field "$tree" source_path)"
    srcrepo="$(vlib_field "$tree" source_repo)"
    exempt="$(manifest_bool "$tree" verify_exempt)"
    exreason="$(vlib_field "$tree" exempt_reason)"

    # --- EXEMPTION: an auditable allowlist, never a silent WARN. A genuinely
    #     unverifiable source may opt out ONLY with a reason. No reason => RED. ---
    if [ "$exempt" = "true" ]; then
        if [ -z "$exreason" ]; then
            n_stale=$((n_stale+1))
            add_row "vendor:$tree" "$pinned" "-" "RED exempt-without-reason"
            add_detail "vendor:$tree RED: verify_exempt=true but exempt_reason is empty -- add an auditable reason or remove the exemption."
        else
            n_exempt=$((n_exempt+1))
            add_row "vendor:$tree" "$pinned" "exempt" "EXEMPT"
            add_detail "vendor:$tree EXEMPT: $exreason"
        fi
        continue
    fi

    # A non-git pin on a NON-exempt tree is unverifiable -> fail-closed (this was
    # the silent-WARN hole). Mark it verify_exempt + exempt_reason if truly so.
    if [ "$pinned" = "WORKING_TREE" ] || [ -z "$pinned" ]; then
        n_stale=$((n_stale+1))
        add_row "vendor:$tree" "$pinned" "-" "RED non-git-pin"
        add_detail "vendor:$tree RED: pin is '$pinned' but the tree is not exempt. If the source is genuinely unverifiable, add verify_exempt = true + exempt_reason; otherwise pin a real SHA."
        continue
    fi

    IFS=$'\t' read -r acct owner prefix < <(resolve_github "$srcrepo")
    if [ -z "$owner" ]; then
        n_stale=$((n_stale+1))
        add_row "vendor:$tree" "$pinned" "-" "RED no-github-source"
        add_detail "vendor:$tree RED: source_repo '$srcrepo' maps to no GitHub repo and the tree is not exempt. Wire a source or add verify_exempt = true + exempt_reason."
        continue
    fi

    # v1018-D621c. Establish that we can READ the source repo before asking any
    # question about the pin. Without this a permissions 404 is indistinguishable
    # from an absent commit, and the row asserts "bad pin" from evidence that
    # says only "I cannot see that repo". Voice matches the EXEMPT rows below:
    # a real reason, not a shrug.
    if [ "$(repo_readable "$acct" "$owner")" = "NO" ]; then
        n_cannot=$((n_cannot+1))
        n_unreadable=$((n_unreadable+1))
        add_row "vendor:$tree" "$pinned" "-" "CANNOT-VERIFY unreadable-source"
        add_detail "vendor:$tree CANNOT-VERIFY: cannot read $owner with the '$acct' account -- the repo is private or this token lacks scope for it. The pin was NOT evaluated; this says nothing about whether it is fresh. Grant the runner's token read access to $owner, then re-run."
        continue
    fi

    gpath="$(join_path "$prefix" "$subpath")"
    live="$(gh_head "$acct" "$owner" "main" "$gpath")"
    verdict="$(freshness_verdict "$acct" "$owner" "$pinned" "$live")"
    base="${verdict%%:*}"

    case "$base" in
        FRESH)
            n_fresh=$((n_fresh+1)); add_row "vendor:$tree" "$pinned" "$live" "FRESH" ;;
        UNREACH)
            n_cannot=$((n_cannot+1)); add_row "vendor:$tree" "$pinned" "$live" "CANNOT-VERIFY" ;;
        STALE|DIVERGED)
            # A pin behind HEAD is allowed ONLY via a hold_ack that acknowledges
            # EVERY commit in the live delta AND asserts the bugfixes are grafted.
            hold_shas="$(vlib_field "$tree" hold_ack_shas)"
            hold_reason="$(vlib_field "$tree" hold_ack_reason)"
            grafted="$(manifest_bool "$tree" shipping_bugfixes_grafted)"
            if [ -z "$hold_shas" ]; then
                n_stale=$((n_stale+1))
                add_row "vendor:$tree" "$pinned" "$live" "RED ${verdict}"
                add_detail "vendor:$tree RED ${verdict} vs live HEAD, NO hold_ack. Classify each un-grafted commit below: graft the bugfix into the vendored tree, or add its SHA to hold_ack_shas with a reason + shipping_bugfixes_grafted = true."
                path_delta_shas "$acct" "$owner" "main" "$gpath" "$pinned"
                if [ "$DELTA_STATUS" = "OK" ]; then
                    _list=""; while IFS= read -r c; do [ -n "$c" ] && _list="$_list ${c:0:12}"; done <<EOF
$DELTA_OUT
EOF
                    add_detail "    un-acknowledged delta commits (pin..HEAD, path $gpath):$_list"
                fi
            else
                path_delta_shas "$acct" "$owner" "main" "$gpath" "$pinned"
                if [ "$DELTA_STATUS" = "UNREACH" ]; then
                    n_cannot=$((n_cannot+1))
                    add_row "vendor:$tree" "$pinned" "$live" "CANNOT-VERIFY delta"
                elif [ "$DELTA_STATUS" != "OK" ]; then
                    n_stale=$((n_stale+1))
                    add_row "vendor:$tree" "$pinned" "$live" "RED delta-$DELTA_STATUS"
                    add_detail "vendor:$tree RED: cannot enumerate the pin..HEAD delta ($DELTA_STATUS) -- the pin is either off the branch history or >100 path-commits behind. Re-pin to current HEAD, then re-run."
                else
                    unacked=""
                    while IFS= read -r c; do
                        [ -z "$c" ] && continue
                        sha_in_list "$c" "$hold_shas" || unacked="$unacked ${c:0:12}"
                    done <<EOF
$DELTA_OUT
EOF
                    if [ -n "$unacked" ]; then
                        n_stale=$((n_stale+1))
                        add_row "vendor:$tree" "$pinned" "$live" "RED ${verdict} unacked"
                        add_detail "vendor:$tree RED: delta commit(s) NOT in hold_ack_shas:$unacked"
                        add_detail "    classify each: graft-the-bugfix (then re-run), or add its SHA to hold_ack_shas with a reason."
                    elif [ "$grafted" != "true" ]; then
                        n_stale=$((n_stale+1))
                        add_row "vendor:$tree" "$pinned" "$live" "RED hold_ack no-grafted-assert"
                        add_detail "vendor:$tree RED: hold_ack covers the delta but shipping_bugfixes_grafted is not asserted true. Graft the bugfixes among the held commits, then set shipping_bugfixes_grafted = true."
                    elif [ -z "$hold_reason" ]; then
                        n_stale=$((n_stale+1))
                        add_row "vendor:$tree" "$pinned" "$live" "RED hold_ack no-reason"
                        add_detail "vendor:$tree RED: hold_ack_shas present but hold_ack_reason is empty. Record WHY the pin is held."
                    else
                        n_held=$((n_held+1))
                        add_row "vendor:$tree" "$pinned" "$live" "HELD ${verdict}"
                        add_detail "vendor:$tree HELD ${verdict}: every delta commit acknowledged. Reason: $hold_reason"
                    fi
                fi
            fi ;;
        *) # UNRESOLVED
            n_stale=$((n_stale+1))
            add_row "vendor:$tree" "$pinned" "$live" "RED unresolved"
            add_detail "vendor:$tree RED: the source repo IS readable, but the pinned SHA does not resolve in it -- the pin is genuinely bad or the commit is absent from that repo. Re-pin, or mark verify_exempt + reason if the source is genuinely unverifiable." ;;
    esac
done < <(vlib_tree_names)

# ===========================================================================
# 2. DAEMON  (install.sh / gui/Makefile pin -> tag -> release bytes -> source
#    commit -> vs live ostler-ai/ostler-assistant HEAD)
#    Not a vendor tree, so there is no verify_exempt. There IS a hold_ack, in
#    scripts/daemon_hold_ack.tsv, on the recency link only: the four
#    provenance links are never waivable, because a broken chain means the
#    installer downloads bytes nobody can account for.
# ===========================================================================

# ---------------------------------------------------------------------------
# DAEMON RECENCY: docs-only delta suppression (v1018-D621f, Andy 2026-08-13)
#
# The daemon recency check compares the pinned commit against ostler-assistant
# main WHOLE-REPO, unlike every vendor tree, which is path-scoped. On the
# 2026-08-13 cut that made a two-file markdown commit -- aa488a4d, editing
# .github/workflows/README.md and master-branch-flow.md -- a cut blocker
# demanding a fresh signed + notarised daemon release that could not differ by
# one byte.
#
# DENYLIST, NOT AN INCLUSION LIST. Andy's ruling, and the reason matters: an
# inclusion list ("only crates/** counts") fails in the WRONG DIRECTION. Add a
# new shipping directory, forget to list it, and the gate goes quietly green on
# a genuinely stale daemon. A denylist fails closed both ways -- anything not
# explicitly known-inert keeps the daemon RED.
#
# EVERY ENTRY CARRIES ITS REASON:
#
#   .github/**   CI configuration and workflow documentation. Not compiled, not
#                in the release tarball. The tarball is OstlerAssistant.app
#                wrapping the Mach-O; .github/ never reaches a customer.
#
#   *.md         Documentation. VERIFIED, not assumed: all 10 include_str! /
#                include_bytes! sites in ostler-assistant embed .txt or .rs and
#                none embeds a .md. The one that would have mattered is
#                crates/ostler-consent-gate/src/wording.rs -- consent text is
#                legally significant -- and it embeds wording_data/*.txt, so a
#                consent change moves a .txt and stays RED. If markdown is ever
#                include_str!'d, DELETE THIS ENTRY.
#
#   docs/**      Documentation tree. Same argument as *.md, by location rather
#                than extension, so a non-.md asset under docs/ is covered too.
#
# NOT denylisted on purpose, though it is tempting: tests/**. A test change can
# encode a behaviour change, and the daemon's own test suite is part of how we
# know the binary is sound. Silence there would be the inclusion-list failure
# wearing different clothes.
#
# FAIL CLOSED ON DOUBT. UNKNOWN (API error, or a file list at the 300-entry cap
# where the un-listed remainder could contain anything) is treated exactly like
# NO. The only path to suppression is a positive, complete answer.
# ---------------------------------------------------------------------------
path_is_inert() { # <path> -> 0 if denylisted (cannot affect the shipped daemon)
    case "$1" in
        .github/*)  return 0 ;;
        docs/*)     return 0 ;;
        *.md)       return 0 ;;
        *)          return 1 ;;
    esac
}

# delta_is_docs_only <acct> <owner/repo> <base> <head>
#   Echoes: YES | NO | UNKNOWN
delta_is_docs_only() {
    local acct="$1" repo="$2" base="$3" head="$4" rc files n
    # One call: compare's files[] is the UNION of changed files across the whole
    # range, so this does not scale with the number of commits.
    api "$acct" "repos/$repo/compare/${base}...${head}" --jq '.files[].filename'
    rc=$?
    [ "$rc" -ne 0 ] && { echo "UNKNOWN"; return; }
    files="$API_OUT"
    # An EMPTY file list with a non-empty commit range is not "no changes" -- it
    # is an answer we do not understand. Do not read it as docs-only.
    [ -z "$files" ] && { echo "UNKNOWN"; return; }
    n="$(printf '%s
' "$files" | grep -c .)"
    # GitHub caps compare files[] at 300. At the cap the list is potentially
    # truncated and the unseen remainder could be anything at all.
    [ "$n" -ge 300 ] && { echo "UNKNOWN"; return; }
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        path_is_inert "$f" || { echo "NO"; return; }
    done <<EOF
$files
EOF
    echo "YES"
}

# ---------------------------------------------------------------------------
# DAEMON RECENCY -- the fifth link.
#
# Links 1-4 bind the pin to the exact bytes a customer downloads, and bind
# those bytes back to a source commit. They say nothing about whether that
# commit is CURRENT. A daemon can be perfectly coherent -- valid tag, published
# non-draft release, sidecar matching gui/Makefile, build-info matching the tag
# -- and still sit far behind oa main with a launch-blocking fix in the gap.
#
# Measured 2026-08-12 on CM051 main 89ae51c: pin hub-v0.4.54 @ 782a6195 scored
# "FRESH tag+sha256+build-info" while ostler-ai/ostler-assistant main HEAD was
# 10b003a0 -- the WhatsApp merge -- 29 commits ahead. WhatsApp was merged and
# reached nobody, and this gate was green on the daemon that omitted it. The
# file header has promised this check since the gate was written ("proves
# NOTHING has silently fallen behind live upstream HEAD -- including the daemon
# + wiki-image inputs"); the body stopped honouring it for the daemon at
# v1.0.16. A header is a claim about a gate, never the gate.
#
# Why it went missing, and why THIS form does not rot the same way: the old
# check compared the pin against $DAEMON_INTEGRATION_BRANCH -- a hand-maintained
# branch NAME. When that branch was abandoned the comparison read "diverged,
# ahead 3, behind 123" on a healthy daemon, so it was removed rather than
# re-anchored to something durable. This one compares against the daemon repo's
# own tracked branch HEAD, which cannot be abandoned without abandoning the
# product, and it gives a deliberate hold the same auditable, must-acknowledge
# escape that vendor trees and wiki images already have. A hold is a loud
# decision with a name on it, not a silent WARN.
# ---------------------------------------------------------------------------
check_daemon_recency() { # pin  daemon_commit
    local pin="$1" commit="$2"
    local oa_head verdict base rc
    local hold_shas="" hold_grafted="" hold_reason="" rp="" unacked="" s ln

    oa_head="$(gh_head ostler-ai ostler-ai/ostler-assistant "$OA_BRANCH")"
    verdict="$(freshness_verdict ostler-ai ostler-ai/ostler-assistant "$commit" "$oa_head")"
    base="${verdict%%:*}"

    if [ "$base" = FRESH ]; then
        n_fresh=$((n_fresh+1))
        add_row "daemon (${pin})" "${commit:0:8}" "${commit:0:8}" "FRESH tag+sha256+build-info+recency"
        return
    fi
    if [ "$base" != STALE ] && [ "$base" != DIVERGED ]; then
        # UNREACH / UNRESOLVED. Never a false pass and never a false RED: the
        # provenance chain already passed, so say exactly what is unasserted.
        n_cannot=$((n_cannot+1))
        add_row "daemon (${pin})" "${commit:0:8}" "-" "CANNOT-VERIFY recency"
        add_detail "daemon CANNOT-VERIFY recency (${verdict}): could not resolve ostler-ai/ostler-assistant ${OA_BRANCH} HEAD. The four provenance links PASSED; recency is unasserted, not green."
        return
    fi

    # Behind live HEAD. Consult the hold_ack ledger. A row matches only if its
    # pinned_sha_prefix is a prefix of the daemon commit -- so a re-pin
    # invalidates the ack and forces the decision to be made again.
    if [ -f "$DAEMON_HOLD_ACK_FILE" ]; then
        while IFS=$'\t' read -r rpin rshas rgraft rreason; do
            case "$rpin" in ''|'#'*) continue ;; esac
            case "$commit" in "$rpin"*) ;; *) continue ;; esac
            rp="$rpin"
            hold_shas="$rshas"
            hold_grafted="$(printf '%s' "$rgraft" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
            hold_reason="$rreason"
            break
        done < "$DAEMON_HOLD_ACK_FILE"
    fi

    # Before calling a lag a defect, ask whether the delta can affect the
    # shipped daemon at all. Suppression here is NOT a hold: a hold is a
    # deliberate decision to ship known-stale code and needs a written reason.
    # This is the narrower claim that nothing in the delta reaches the binary.
    local docsonly; docsonly="$(delta_is_docs_only ostler-ai ostler-ai/ostler-assistant "$commit" "$oa_head")"
    if [ "$docsonly" = "YES" ]; then
        n_fresh=$((n_fresh+1))
        add_row "daemon (${pin})" "${commit:0:8}" "${oa_head:0:8}" "FRESH docs-only-delta"
        add_detail "daemon: ${verdict} vs ostler-ai/ostler-assistant ${OA_BRANCH}, but EVERY file in the delta is documentation (.github/**, docs/**, *.md). None of it is compiled or shipped, so a re-cut could not change one byte. Not a hold_ack -- no stale code is being shipped. Any non-doc file in the delta returns this to RED."
        return
    fi

    if [ -z "$hold_shas" ]; then
        n_stale=$((n_stale+1))
        add_row "daemon (${pin})" "${commit:0:8}" "${oa_head:0:8}" "RED ${verdict}"
        add_detail "daemon RED ${verdict} vs live ostler-ai/ostler-assistant ${OA_BRANCH}, NO hold_ack in $DAEMON_HOLD_ACK_FILE. The shipped daemon predates commits on the daemon's own main. Cut a new daemon release and re-pin, OR add a row (pinned_sha_prefix<TAB>delta_shas<TAB>true<TAB>reason) covering every delta commit."
        if [ "$docsonly" = "UNKNOWN" ]; then
            add_detail "    (the docs-only check could not complete, so it did not suppress anything -- this RED stands on the delta itself)"
        fi
        return
    fi
    if [ -z "$hold_reason" ]; then
        n_stale=$((n_stale+1))
        add_row "daemon (${pin})" "${commit:0:8}" "${oa_head:0:8}" "RED hold_ack no-reason"
        add_detail "daemon RED: $DAEMON_HOLD_ACK_FILE row ($rp) has hold_ack_shas but an empty reason. Record WHY the daemon pin is held behind its own main."
        return
    fi
    if [ "$hold_grafted" != true ]; then
        n_stale=$((n_stale+1))
        add_row "daemon (${pin})" "${commit:0:8}" "${oa_head:0:8}" "RED hold_ack no-grafted-assert"
        add_detail "daemon RED: $DAEMON_HOLD_ACK_FILE row ($rp) has hold_ack_shas + reason but shipping_bugfixes_grafted is not true. Assert that no held commit is a shipping bugfix, then set the column to true."
        return
    fi

    api ostler-ai "repos/ostler-ai/ostler-assistant/compare/${commit}...${oa_head}" \
        --jq '.commits[].sha'
    rc=$?
    if [ "$rc" -eq 2 ]; then
        n_cannot=$((n_cannot+1))
        add_row "daemon (${pin})" "${commit:0:8}" "${oa_head:0:8}" "CANNOT-VERIFY hold_ack (compare unreachable)"
        return
    fi
    if [ "$rc" -eq 1 ]; then
        n_stale=$((n_stale+1))
        add_row "daemon (${pin})" "${commit:0:8}" "${oa_head:0:8}" "RED compare-failed"
        return
    fi
    while IFS= read -r ln; do
        s="$(printf '%s' "$ln" | tr -d '[:space:]')"
        [ -z "$s" ] && continue
        if ! sha_in_list "$s" "$hold_shas"; then
            unacked="$unacked $s"
        fi
    done <<< "$API_OUT"
    if [ -n "$unacked" ]; then
        n_stale=$((n_stale+1))
        add_row "daemon (${pin})" "${commit:0:8}" "${oa_head:0:8}" "RED hold_ack partial"
        add_detail "daemon RED: delta commit(s) NOT in hold_ack_shas:$unacked"
        add_detail "    classify each: cut a daemon release containing it (then re-pin + re-run), or add its SHA to hold_ack_shas with a reason."
        return
    fi
    n_held=$((n_held+1))
    add_row "daemon (${pin})" "${commit:0:8}" "${oa_head:0:8}" "HELD hold_ack"
    add_detail "daemon HELD: all delta commits acknowledged (reason: ${hold_reason})"
}

check_daemon() {
sh_pin="$(grep -m1 -E '^OSTLER_ASSISTANT_VERSION=' "$INSTALL_SH" 2>/dev/null \
          | sed -E 's/.*:-([0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._]+)?)\}.*/\1/')"
mk_pin="$(grep -m1 -E '^DAEMON_VERSION[[:space:]]*\?=' "$GUI_MAKEFILE" 2>/dev/null \
          | sed -E 's/.*\?=[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._]+)?).*/\1/')"
daemon_pin="${mk_pin:-$sh_pin}"

if [ -n "$mk_pin" ] && [ -n "$sh_pin" ] && [ "$mk_pin" != "$sh_pin" ]; then
    n_stale=$((n_stale+1))
    add_row "daemon:pin-mismatch" "$mk_pin" "$sh_pin" "RED Makefile!=install.sh"
elif [ -z "$daemon_pin" ]; then
    n_cannot=$((n_cannot+1))
    add_row "daemon" "-" "-" "CANNOT-VERIFY no-pin-read"
else
    # Resolve the pin to a daemon commit. Try the tag shapes, most-specific first.
    daemon_commit=""; daemon_unreach=0
    for cand in "hub-v${daemon_pin}" "v${daemon_pin}" "${daemon_pin}"; do
        h="$(gh_head ostler-ai ostler-ai/ostler-assistant "$cand")"
        if [ "$h" = "UNREACH" ]; then daemon_unreach=1; continue; fi
        if [ "$h" != "NONE" ] && [ -n "$h" ]; then daemon_commit="$h"; break; fi
    done
    if [ -z "$daemon_commit" ]; then
        if [ "$daemon_unreach" = "1" ]; then
            n_cannot=$((n_cannot+1)); add_row "daemon" "$daemon_pin" "-" "CANNOT-VERIFY unreachable"
        else
            n_stale=$((n_stale+1)); add_row "daemon" "$daemon_pin" "-" "RED no-tag-for-pin"
        fi
    else
        # ARTEFACT-PROVENANCE CHAIN, not a branch comparison.
        #
        # This check used to compare the pin against $DAEMON_INTEGRATION_BRANCH,
        # defaulted to "integration/hub-v1.0.9". By v1.0.16 that branch was
        # abandoned: the comparison read "diverged, ahead 3, behind 123" and went
        # RED on a perfectly coherent daemon. A gate keyed to a hand-maintained
        # branch NAME rots silently and then cries wolf -- and the next person
        # rightly ignores it, which is how a real divergence would have sailed
        # through. Worse, the branch it named was not even the shipping line: the
        # pin is a TAG, and install.sh downloads a RELEASE ASSET.
        #
        # So verify what actually reaches the customer, which cannot rot:
        #   1. the pinned version resolves to a tag           (done above)
        #   2. a published, non-draft release exists for it on the repo
        #      install.sh really fetches from
        #   3. that release's .sha256 sidecar == the Makefile's DAEMON_SHA256
        #      -- binds the pin to the exact BYTES the installer downloads
        #   4. its build-info.json commit_sha == the tag's commit
        #      -- binds those bytes back to source
        # Any break in the chain is RED and names which link failed.
        rel_repo="$(grep -m1 -E 'OSTLER_ASSISTANT_REPO:-' "$INSTALL_SH" 2>/dev/null \
                    | sed -E 's/.*:-([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)\}.*/\1/')"
        rel_repo="${rel_repo:-ostler-ai/ostler-releases}"
        mk_sha="$(grep -m1 -E '^DAEMON_SHA256[[:space:]]*\?=' "$GUI_MAKEFILE" 2>/dev/null \
                  | sed -E 's/.*\?=[[:space:]]*([0-9a-f]{64}).*/\1/')"
        # Every call goes through `api ostler-ai`, NOT bare `gh` (v1018-D029).
        # As first written this block shelled out to `gh` directly, which
        # bypassed three things the rest of this script depends on:
        #   1. $GH_BIN / FRESHNESS_GH_BIN -- so the daemon chain could not be
        #      mocked, and its self-test cases could never pass. The gate sat
        #      red from 2026-08-01 through v1.0.16/17/18 for exactly this.
        #   2. run_to $GH_API_TIMEOUT -- an unbounded API call in a gate that
        #      times out every other call.
        #   3. the rc=2 UNREACHABLE signal -- so a network failure here was
        #      indistinguishable from "no release exists" and reported RED.
        #      That is a FALSE POSITIVE in the fail-closed direction, which is
        #      how a gate teaches people to ignore it.
        rel_ep="repos/${rel_repo}/releases/tags/hub-v${daemon_pin}"
        api ostler-ai "$rel_ep"; rel_rc=$?
        rel_json="$API_OUT"

        if [ "$rel_rc" -eq 2 ]; then
            n_cannot=$((n_cannot+1))
            add_row "daemon (${daemon_pin})" "$daemon_commit" "-" "CANNOT-VERIFY unreachable"
            add_detail "daemon CANNOT-VERIFY: ${rel_repo} unreachable while resolving the published release. Not asserting anything about the artefact."
        elif [ "$rel_rc" -ne 0 ] || [ -z "$rel_json" ]; then
            n_stale=$((n_stale+1))
            add_row "daemon (${daemon_pin})" "$daemon_commit" "-" "RED no-published-release"
            add_detail "daemon RED: no published release hub-v${daemon_pin} on ${rel_repo} -- install.sh downloads from there, so every customer install would 404."
        else
            d_draft="$(printf '%s' "$rel_json" | sed -n 's/.*"draft":[[:space:]]*\([a-z]*\).*/\1/p' | head -1)"
            side_id=""
            api ostler-ai "$rel_ep" --jq '.assets[]|select(.name|endswith(".sha256"))|.id' \
                && side_id="$(printf '%s' "$API_OUT" | head -1)"
            pub_sha=""
            [ -n "$side_id" ] && api ostler-ai "repos/${rel_repo}/releases/assets/${side_id}" \
                -H "Accept: application/octet-stream" \
                && pub_sha="$(printf '%s' "$API_OUT" | awk '{print $1; exit}')"
            bi_id=""
            api ostler-ai "$rel_ep" --jq '.assets[]|select(.name|endswith("build-info.json"))|.id' \
                && bi_id="$(printf '%s' "$API_OUT" | head -1)"
            bi_commit=""
            [ -n "$bi_id" ] && api ostler-ai "repos/${rel_repo}/releases/assets/${bi_id}" \
                -H "Accept: application/octet-stream" \
                && bi_commit="$(printf '%s' "$API_OUT" \
                | sed -n 's/.*"commit_sha":[[:space:]]*"\([0-9a-f]*\)".*/\1/p' | head -1)"

            if [ "$d_draft" = "true" ]; then
                n_stale=$((n_stale+1))
                add_row "daemon (${daemon_pin})" "$daemon_commit" "draft" "RED release-is-draft"
                add_detail "daemon RED: release hub-v${daemon_pin} on ${rel_repo} is a DRAFT -- not downloadable by a customer."
            elif [ -n "$mk_sha" ] && [ -n "$pub_sha" ] && [ "$mk_sha" != "$pub_sha" ]; then
                n_stale=$((n_stale+1))
                add_row "daemon (${daemon_pin})" "${mk_sha:0:8}" "${pub_sha:0:8}" "RED sha256-mismatch"
                add_detail "daemon RED: gui/Makefile DAEMON_SHA256 (${mk_sha}) != the published sidecar (${pub_sha}). The installer would reject the tarball it downloads."
            elif [ -z "$pub_sha" ]; then
                n_stale=$((n_stale+1))
                add_row "daemon (${daemon_pin})" "$daemon_commit" "-" "RED no-sha256-asset"
                add_detail "daemon RED: release hub-v${daemon_pin} has no .sha256 sidecar -- the pin cannot be bound to the shipped bytes."
            elif [ -n "$bi_commit" ] && [ "${bi_commit}" != "${daemon_commit}" ]; then
                n_stale=$((n_stale+1))
                add_row "daemon (${daemon_pin})" "${daemon_commit:0:8}" "${bi_commit:0:8}" "RED built-from-other-commit"
                add_detail "daemon RED: tag hub-v${daemon_pin} points at ${daemon_commit}, but the published binary's build-info.json says it was built from ${bi_commit}. The shipped daemon is not the tagged source."
            else
                # Links 1-4 passed: the pin is bound to the shipped bytes and
                # those bytes to this source commit. Link 5 asks the question
                # they cannot: is that commit current? See check_daemon_recency.
                check_daemon_recency "$daemon_pin" "$daemon_commit"
            fi
        fi
    fi
fi
}
[ -z "$FRESHNESS_ONLY" ] && check_daemon

# ===========================================================================
# 3. WIKI IMAGES  (install.sh digest -> provenance ledger -> vs CM044 main HEAD)
#    hold_ack (HR015 #238 sub-item 2, 2026-08-01 ORM): a wiki pin may sit
#    behind live CM044 HEAD only if scripts/wiki_hold_ack.tsv carries a matching
#    row (same key + same pinned_sha_prefix) whose hold_ack_shas covers EVERY
#    delta commit AND whose reason is non-empty AND shipping_bugfixes_grafted
#    is asserted true. Mirrors the vendor-tree hold_ack contract; any
#    un-acknowledged delta commit stays fail-closed RED.
# ===========================================================================
check_wiki() {
cm044_head="$(gh_head andygmassey andygmassey/CM044-PWG-Personal-Wiki "$CM044_BRANCH")"
for key in wiki-compiler wiki-site; do
    # Namespace-AGNOSTIC on purpose. CI (release-images.yml) publishes to
    # ghcr.io/creativemachines-ai/*, but install.sh ships ghcr.io/ostler-ai/*
    # -- the automated path does not feed the shipped path (CM044 #643). This
    # grep was pinned to the CI namespace, so it never matched the shipped
    # line and this check has NEVER verified a wiki digest: it reported
    # "no-digest-in-install.sh" against an install.sh that has always carried
    # one. It failed CLOSED, which is the only reason it was not a shipping
    # defect -- had the namespaces been the other way round it would have
    # verified an image the customer never pulls. Match any owner, and let the
    # provenance ledger bind digest -> CM044 sha regardless of registry path.
    digest="$(grep -m1 -E "image: ghcr\.io/[a-z0-9-]+/ostler-${key}@sha256:" "$INSTALL_SH" 2>/dev/null \
              | sed -E 's/.*@(sha256:[0-9a-f]+).*/\1/')"
    if [ -z "$digest" ]; then
        n_stale=$((n_stale+1))
        add_row "wiki:$key" "-" "-" "RED no-digest-in-install.sh"
        continue
    fi
    # Look the digest up in the provenance ledger -> recorded CM044 source sha.
    cm044_sha=""
    if [ -f "$WIKI_PROVENANCE_FILE" ]; then
        cm044_sha="$(awk -F'\t' -v k="$key" -v d="$digest" \
            '/^[[:space:]]*#/ {next} NF>=3 && $1==k && $2==d {print $3; exit}' \
            "$WIKI_PROVENANCE_FILE")"
    fi
    if [ -z "$cm044_sha" ]; then
        # FAIL-CLOSED: a pinned digest with no recorded source binding is
        # unverifiable -- a repin that forgot to record provenance.
        n_stale=$((n_stale+1))
        add_row "wiki:$key" "$digest" "-" "RED unrecorded-provenance"
        continue
    fi
    verdict="$(freshness_verdict andygmassey andygmassey/CM044-PWG-Personal-Wiki "$cm044_sha" "$cm044_head")"
    base="${verdict%%:*}"
    # FRESH / UNREACH / unresolved: same behaviour as before.
    if [ "$base" = FRESH ] || [ "$base" != STALE ] && [ "$base" != DIVERGED ]; then
        classify_simple "wiki:$key" "$cm044_sha" "$cm044_head" "$verdict"
        continue
    fi
    # STALE / DIVERGED: consult wiki_hold_ack.tsv. A row matches only if the
    # key equals AND the pinned_sha_prefix is a prefix of the recorded CM044
    # sha (defensive: a re-pin invalidates the ack, forcing re-decision).
    hold_shas=""
    hold_grafted=""
    hold_reason=""
    if [ -f "$WIKI_HOLD_ACK_FILE" ]; then
        while IFS=$'\t' read -r rk rp rshas rgraft rreason; do
            case "$rk" in ''|'#'*) continue ;; esac
            [ "$rk" = "$key" ] || continue
            case "$cm044_sha" in "$rp"*) ;; *) continue ;; esac
            hold_shas="$rshas"
            hold_grafted="$(printf '%s' "$rgraft" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
            hold_reason="$rreason"
            break
        done < "$WIKI_HOLD_ACK_FILE"
    fi
    if [ -z "$hold_shas" ]; then
        n_stale=$((n_stale+1))
        add_row "wiki:$key" "$cm044_sha" "$cm044_head" "RED ${verdict}"
        add_detail "wiki:$key RED ${verdict} vs live CM044 HEAD, NO hold_ack in $WIKI_HOLD_ACK_FILE. Add a row (key<TAB>pinned_sha_prefix<TAB>delta_shas<TAB>true<TAB>reason) covering every delta commit, OR rebuild the wiki image + re-pin."
        continue
    fi
    if [ -z "$hold_reason" ]; then
        n_stale=$((n_stale+1))
        add_row "wiki:$key" "$cm044_sha" "$cm044_head" "RED hold_ack no-reason"
        add_detail "wiki:$key RED: $WIKI_HOLD_ACK_FILE row for $key ($rp) has hold_ack_shas but empty reason. Record WHY the pin is held."
        continue
    fi
    if [ "$hold_grafted" != true ]; then
        n_stale=$((n_stale+1))
        add_row "wiki:$key" "$cm044_sha" "$cm044_head" "RED hold_ack no-grafted-assert"
        add_detail "wiki:$key RED: $WIKI_HOLD_ACK_FILE row for $key ($rp) has hold_ack_shas + reason but shipping_bugfixes_grafted is not true. Graft the bugfixes among the held commits (or assert they are not launch-blocking), then set the column to true."
        continue
    fi
    # Enumerate the live delta commits and require EVERY one is in hold_shas.
    api andygmassey "repos/andygmassey/CM044-PWG-Personal-Wiki/compare/$cm044_sha...$cm044_head" \
        --jq '.commits[].sha'
    rc=$?
    if [ "$rc" -eq 2 ]; then
        n_cannot=$((n_cannot+1))
        add_row "wiki:$key" "$cm044_sha" "$cm044_head" "CANNOT-VERIFY hold_ack (compare unreachable)"
        continue
    fi
    if [ "$rc" -eq 1 ]; then
        n_stale=$((n_stale+1))
        add_row "wiki:$key" "$cm044_sha" "$cm044_head" "RED compare-failed"
        continue
    fi
    unacked=""
    while IFS= read -r ln; do
        s="$(printf '%s' "$ln" | tr -d '[:space:]')"
        [ -z "$s" ] && continue
        if ! sha_in_list "$s" "$hold_shas"; then
            unacked="$unacked $s"
        fi
    done <<< "$API_OUT"
    if [ -n "$unacked" ]; then
        n_stale=$((n_stale+1))
        add_row "wiki:$key" "$cm044_sha" "$cm044_head" "RED hold_ack partial"
        add_detail "wiki:$key RED: delta commit(s) NOT in hold_ack_shas:$unacked"
        add_detail "    classify each: graft-the-bugfix (then re-run), or add its SHA to hold_ack_shas with a reason."
        continue
    fi
    n_held=$((n_held+1))
    add_row "wiki:$key" "$cm044_sha" "$cm044_head" "HELD hold_ack"
    add_detail "wiki:$key HELD: all delta commits acknowledged (reason: ${hold_reason})"
done
}
[ -z "$FRESHNESS_ONLY" ] && check_wiki

# ===========================================================================
# TABLE + VERDICT
# ===========================================================================
echo "INPUT                              PINNED    LIVE HEAD  STATUS"
echo "-----------------------------------------------------------------------"
while IFS=$'\t' read -r input pinned live status; do
    printf '%-34s %-9s %-10s %s\n' "$input" "$pinned" "$live" "$status"
done < "$ROWS_FILE"
echo "-----------------------------------------------------------------------"
echo "fresh=$n_fresh  held=$n_held  exempt=$n_exempt  stale/RED=$n_stale  cannot-verify=$n_cannot"
echo

# Detail block: RED reasons, EXEMPT reasons, HELD reasons + un-acked commits.
if [ -s "$DETAILS_FILE" ]; then
    echo "DETAIL:"
    sed 's/^/  /' "$DETAILS_FILE"
    echo
fi

if [ "$n_stale" -gt 0 ]; then
    echo "GATE: RED -- $n_stale input(s) lag live upstream HEAD without a covering hold_ack," >&2
    echo "      are exempt without a reason, or are unresolved. For each RED above: graft the" >&2
    echo "      bugfix + re-pin, add a hold_ack (with shipping_bugfixes_grafted = true) covering" >&2
    echo "      the whole delta, or add verify_exempt + exempt_reason. Then re-run. DO NOT CUT." >&2
    exit 1
fi
if [ "$n_cannot" -gt 0 ]; then
    echo "GATE: CANNOT VERIFY -- $n_cannot input(s) could not be checked against GitHub." >&2
    # Name the CAUSE, because the two causes have different remedies and only
    # one of them is "restore network". On cut run 31685172775 fifteen trees
    # landed here for want of a credential while this line said "unreachable"
    # and advised restoring the network -- an accurate exit code wearing the
    # wrong explanation, which sends the operator at the wrong thing.
    if [ "$n_unreadable" -gt 0 ]; then
        echo "      $n_unreadable of them: the SOURCE REPO could not be read with the account the gate" >&2
        echo "      used. GitHub answers 404 for a private repo exactly as for a missing one, so this" >&2
        echo "      says nothing about the pin. Grant that token read access to the repos named above." >&2
        echo "      Do NOT re-pin them: no evidence has been produced that they are stale." >&2
    fi
    if [ "$n_cannot" -gt "$n_unreadable" ]; then
        echo "      $((n_cannot - n_unreadable)) of them: GitHub was unreachable (network or timeout). Restore network + re-run." >&2
    fi
    echo "      This is fail-closed: the cut must NOT proceed on an unverified input." >&2
    exit 3
fi
extra=""
[ "$n_held" -gt 0 ]   && extra="$extra $n_held held (acknowledged)"
[ "$n_exempt" -gt 0 ] && extra="$extra${extra:+,} $n_exempt exempt (with reason)"
if [ -n "$extra" ]; then
    echo "GATE: GREEN -- every input is fresh, held or exempt.$extra. See DETAIL above (audit them)."
else
    echo "GATE: GREEN -- every shippable input is at (or ahead of) live upstream HEAD."
fi
exit 0
