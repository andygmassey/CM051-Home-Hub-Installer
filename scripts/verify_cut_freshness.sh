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
# FAIL-CLOSED, BOUNDED, AUTHORITATIVE
#   * Exit 1 if ANY shippable (verify=full) input is behind live HEAD -- the cut
#     mechanism must be UNABLE to proceed past this gate with a stale input.
#   * Exit 3 (CANNOT VERIFY) -- a DISTINCT, still-non-zero status -- if GitHub is
#     genuinely unreachable after a retry. Never a false "fresh". The cut aborts.
#   * Exit 0 only when every full input equals (or already contains) live HEAD.
#   * Every network read has a generous timeout + one retry; a hung endpoint
#     degrades to CANNOT VERIFY, never an infinite wait.
#   * verify=skip trees are still REPORTED (their freshness is visible) but a
#     stale skip-tree WARNs rather than reds -- unless FRESHNESS_SKIP_STRICT=1.
#
# Inputs checked:
#   1. Vendor pins  (vendor/VENDOR_MANIFEST.toml -- per-tree, path-scoped)
#   2. Daemon       (install.sh / gui/Makefile pin -> ostler-assistant tag ->
#                    compared against the integration branch HEAD)
#   3. Wiki images  (install.sh digest -> scripts/wiki_image_provenance.tsv ->
#                    recorded CM044 sha compared against CM044 main HEAD)
#
# Usage:   scripts/verify_cut_freshness.sh
# Env (all optional):
#   DAEMON_INTEGRATION_BRANCH  ostler-assistant branch the daemon must track
#                              (default: integration/hub-v1.0.9)
#   CM044_BRANCH               wiki source branch (default: main)
#   WIKI_PROVENANCE_FILE       path to the digest->CM044-sha ledger
#                              (default: scripts/wiki_image_provenance.tsv)
#   FRESHNESS_SKIP_STRICT=1    make a stale verify=skip tree RED, not WARN
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
DAEMON_INTEGRATION_BRANCH="${DAEMON_INTEGRATION_BRANCH:-integration/hub-v1.0.9}"
CM044_BRANCH="${CM044_BRANCH:-main}"
WIKI_PROVENANCE_FILE="${WIKI_PROVENANCE_FILE:-$SCRIPT_DIR/wiki_image_provenance.tsv}"
FRESHNESS_SKIP_STRICT="${FRESHNESS_SKIP_STRICT:-0}"
GH_API_TIMEOUT="${GH_API_TIMEOUT:-25}"
GH_BIN="${FRESHNESS_GH_BIN:-gh}"

# --- verdict tallies ---
n_fresh=0
n_stale=0        # RED  -- a full input behind live HEAD (fail the cut)
n_warn=0         # visible, non-fatal (skip trees, unmapped sources)
n_cannot=0       # GitHub unreachable -- fail-closed, distinct exit

# Rows for the final table:  input \t pinned \t live \t status
ROWS_FILE="$(mktemp)"
trap 'rm -f "$ROWS_FILE"' EXIT

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
token_for() {
    local acct="$1"
    [ -n "${FRESHNESS_GH_BIN:-}" ] && { printf 'mock-token'; return 0; }
    local key="_TOK_$(printf '%s' "$acct" | tr -c 'A-Za-z0-9' '_')"
    local cur; eval "cur=\${$key:-}"
    if [ -z "$cur" ]; then
        cur="$(gh auth token --user "$acct" 2>/dev/null)"
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
        CM048) acct=andygmassey; owner="andygmassey/CM048-PWG-Conversation-Processing" ;;
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

# Record a verdict into the tallies + table, applying skip-tree downgrade.
record() { # input  pinned  live  verdict  is_skip
    local input="$1" pinned="$2" live="$3" verdict="$4" is_skip="$5"
    local base="${verdict%%:*}" disp="$verdict"
    case "$base" in
        FRESH)
            n_fresh=$((n_fresh+1)); disp="FRESH" ;;
        STALE|DIVERGED)
            if [ "$is_skip" = "1" ] && [ "$FRESHNESS_SKIP_STRICT" != "1" ]; then
                n_warn=$((n_warn+1)); disp="WARN ${verdict} (skip)"
            else
                n_stale=$((n_stale+1)); disp="RED ${verdict}"
            fi ;;
        UNREACH)
            if [ "$is_skip" = "1" ]; then n_warn=$((n_warn+1)); disp="WARN cannot-verify (skip)"
            else n_cannot=$((n_cannot+1)); disp="CANNOT-VERIFY"; fi ;;
        UNRESOLVED|*)
            # A shippable input we cannot resolve is fail-closed; a skip tree WARNs.
            if [ "$is_skip" = "1" ]; then n_warn=$((n_warn+1)); disp="WARN unresolved (skip)"
            else n_stale=$((n_stale+1)); disp="RED unresolved"; fi ;;
    esac
    add_row "$input" "$pinned" "$live" "$disp"
}

echo "=== Cut-freshness gate (live GitHub HEAD) ==="
echo "manifest:            $VLIB_MANIFEST"
echo "daemon integration:  ostler-ai/ostler-assistant @ $DAEMON_INTEGRATION_BRANCH"
echo "wiki source branch:  andygmassey/CM044-PWG-Personal-Wiki @ $CM044_BRANCH"
echo "provenance ledger:   $WIKI_PROVENANCE_FILE"
echo

# ===========================================================================
# 1. VENDOR PINS
# ===========================================================================
while IFS= read -r tree; do
    [ -z "$tree" ] && continue
    pinned="$(vlib_field "$tree" pinned_sha)"
    subpath="$(vlib_field "$tree" source_path)"
    srcrepo="$(vlib_field "$tree" source_repo)"
    verify="$(vlib_field "$tree" verify)"
    is_skip=0; [ "$verify" = "skip" ] && is_skip=1

    # Non-git pin (CM019 WORKING_TREE) -- freshness is undefined; report + WARN.
    if [ "$pinned" = "WORKING_TREE" ] || [ -z "$pinned" ]; then
        n_warn=$((n_warn+1))
        add_row "vendor:$tree" "$pinned" "-" "WARN no-git-pin"
        continue
    fi

    IFS=$'\t' read -r acct owner prefix < <(resolve_github "$srcrepo")
    if [ -z "$owner" ]; then
        n_warn=$((n_warn+1))
        add_row "vendor:$tree" "$pinned" "-" "WARN no-github-source"
        continue
    fi

    gpath="$(join_path "$prefix" "$subpath")"
    live="$(gh_head "$acct" "$owner" "main" "$gpath")"
    verdict="$(freshness_verdict "$acct" "$owner" "$pinned" "$live")"
    record "vendor:$tree" "$pinned" "$live" "$verdict" "$is_skip"
done < <(vlib_tree_names)

# ===========================================================================
# 2. DAEMON  (install.sh / gui/Makefile pin -> tag -> vs integration HEAD)
# ===========================================================================
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
    integ_head="$(gh_head ostler-ai ostler-ai/ostler-assistant "$DAEMON_INTEGRATION_BRANCH")"
    if [ -z "$daemon_commit" ]; then
        if [ "$daemon_unreach" = "1" ] || [ "$integ_head" = "UNREACH" ]; then
            n_cannot=$((n_cannot+1)); add_row "daemon" "$daemon_pin" "-" "CANNOT-VERIFY unreachable"
        else
            n_stale=$((n_stale+1)); add_row "daemon" "$daemon_pin" "-" "RED no-tag-for-pin"
        fi
    else
        verdict="$(freshness_verdict ostler-ai ostler-ai/ostler-assistant "$daemon_commit" "$integ_head")"
        record "daemon (${daemon_pin})" "$daemon_commit" "$integ_head" "$verdict" 0
    fi
fi

# ===========================================================================
# 3. WIKI IMAGES  (install.sh digest -> provenance ledger -> vs CM044 main HEAD)
# ===========================================================================
cm044_head="$(gh_head andygmassey andygmassey/CM044-PWG-Personal-Wiki "$CM044_BRANCH")"
for key in wiki-compiler wiki-site; do
    digest="$(grep -m1 -E "image: ghcr.io/ostler-ai/ostler-${key}@sha256:" "$INSTALL_SH" 2>/dev/null \
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
    record "wiki:$key" "$cm044_sha" "$cm044_head" "$verdict" 0
done

# ===========================================================================
# TABLE + VERDICT
# ===========================================================================
echo "INPUT                              PINNED    LIVE HEAD  STATUS"
echo "-----------------------------------------------------------------------"
while IFS=$'\t' read -r input pinned live status; do
    printf '%-34s %-9s %-10s %s\n' "$input" "$pinned" "$live" "$status"
done < "$ROWS_FILE"
echo "-----------------------------------------------------------------------"
echo "fresh=$n_fresh  stale/RED=$n_stale  warn=$n_warn  cannot-verify=$n_cannot"
echo

if [ "$n_stale" -gt 0 ]; then
    echo "GATE: RED -- $n_stale shippable input(s) lag live upstream HEAD (or are unresolved)." >&2
    echo "      Re-pin / re-vendor / rebuild each RED input to current HEAD, then re-run. DO NOT CUT." >&2
    exit 1
fi
if [ "$n_cannot" -gt 0 ]; then
    echo "GATE: CANNOT VERIFY -- $n_cannot input(s) could not be checked against GitHub (unreachable)." >&2
    echo "      This is fail-closed: the cut must NOT proceed on an unverified input. Restore network + re-run." >&2
    exit 3
fi
if [ "$n_warn" -gt 0 ]; then
    echo "GATE: GREEN with $n_warn warning(s) -- skip-marked / non-git inputs reported but not enforced."
    echo "      (set FRESHNESS_SKIP_STRICT=1 to make a stale skip-tree fatal)"
else
    echo "GATE: GREEN -- every shippable input is at (or ahead of) live upstream HEAD."
fi
exit 0
