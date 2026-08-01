#!/usr/bin/env bash
# verify_branch_truth.sh -- PRE-CUT branch-truth gate (CM051 canonical).
# ============================================================================
#
# THE REGRESSION THIS PLUGS ("reviewed-on-main != shipped")
# v1.0.12 shipped fine. A later cut then rebuilt the daemon from ostler-assistant
# `main`, which had silently DIVERGED from the integration line and DROPPED ~65
# daemon-crate commits (pairing + security hardening) that the previous ship
# already contained -- a straight regression. The provenance gate caught the
# risk mid-cut only after hours of foundational-state archaeology that should
# have been a one-line lookup (see HR015 SHIPPING_LEDGER.yaml header + memory
# reference_hub_provenance_and_branch_content_audit).
#
# THE INVARIANT (fail-closed)
#   A cut may NEVER drop daemon commits a previous ship already contained.
#   The daemon tag THIS cut pins MUST CONTAIN (be a descendant of, or identical
#   to) the daemon tag the LAST cut shipped. Anything else is a regression.
#
#   THIS_DAEMON_TAG        <- gui/Makefile DAEMON_VERSION  (e.g. hub-v0.4.45)
#   LAST_SHIPPED_DAEMON_TAG<- SHIPPING_LEDGER.yaml, newest dmg_cuts.contains_daemon
#
#   Compare  LAST...THIS  on ostler-ai/ostler-assistant and read `.status`:
#     identical | ahead  -> PASS (this cut contains everything the last ship had)
#     behind    | diverged -> FAIL (this cut is MISSING shipped commits)
#
#   Escape hatch for a DELIBERATE rollback: a matching (this,last) row in
#   scripts/branch_truth_ack.tsv downgrades the FAIL to a loud WARN. Empty by
#   default -- a rollback is a visible, reasoned ledger row, never a silent skip.
#
# THE LOUD WARN (visible, non-blocking, ack-silenceable)
#   ALSO compares the pinned tag against ostler-assistant `main` and reports how
#   far each way (ahead/behind). This is the KNOWN-DEFERRED v1.0.14 reconcile:
#   the integration line legitimately sits ahead of main (integration commits)
#   AND behind main (post-tag main churn). It MUST be printed loudly so the
#   divergence is never silent -- but it does NOT fail the cut (tracked deferral).
#
# FAIL-CLOSED, AUTHORITATIVE
#   * Exit 1 if the pinned daemon is behind/diverged from the last ship without a
#     covering ack, or if the ledger / Makefile pin / a tag cannot be read.
#   * Exit 3 (CANNOT VERIFY) -- distinct, still-non-zero -- if GitHub is
#     unreachable after a retry. Never a false "safe".
#   * Exit 0 only when the pinned daemon provably contains the last ship.
#
# Wired into BOTH cut paths so it cannot be skipped:
#   - gui/Makefile  `package` depends on `check-branch-truth` (the DMG)
#   - release.sh    runs it as a preflight (the curl|bash tarball)
#
# Usage:  scripts/verify_branch_truth.sh
# Env (all optional):
#   SHIPPING_LEDGER_FILE   explicit path to SHIPPING_LEDGER.yaml (highest prio)
#   HR015_DIR              HR015 checkout; ledger is ${HR015_DIR}/SHIPPING_LEDGER.yaml
#   BRANCH_TRUTH_ACK_FILE  rollback ack ledger (default scripts/branch_truth_ack.tsv)
#   DAEMON_MAIN_BRANCH     ostler-assistant main branch name (default: main)
#   GUI_MAKEFILE_OVERRIDE  Makefile to read DAEMON_VERSION from (tests)
#   GH_API_TIMEOUT         per-call timeout seconds (default: 25)
#   BRANCH_TRUTH_GH_BIN    override the `gh` binary (tests inject a mock)
#
# British English throughout; " -- " not em-dashes.
# Exit 0 = GREEN (safe to cut). Exit 1 = BLOCK. Exit 3 = CANNOT VERIFY.

set -uo pipefail   # deliberately NOT -e: we classify every failure ourselves.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CM051_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

REPO="ostler-ai/ostler-assistant"
ACCT="ostler-ai"
GUI_MAKEFILE="${GUI_MAKEFILE_OVERRIDE:-${CM051_DIR}/gui/Makefile}"
ACK_FILE="${BRANCH_TRUTH_ACK_FILE:-${SCRIPT_DIR}/branch_truth_ack.tsv}"
MAIN_BRANCH="${DAEMON_MAIN_BRANCH:-main}"
GH_API_TIMEOUT="${GH_API_TIMEOUT:-25}"
GH_BIN="${BRANCH_TRUTH_GH_BIN:-gh}"

# --- colour helpers (house style: info/ok/warn/err) ------------------------
if [ -t 1 ]; then C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_0=$'\033[0m'
else C_G=""; C_R=""; C_Y=""; C_0=""; fi
info() { printf '        %s\n' "$*"; }
ok()   { printf '  %sPASS%s  %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %sWARN%s  %s\n' "$C_Y" "$C_0" "$*"; }
err()  { printf '  %sFAIL%s  %s\n' "$C_R" "$C_0" "$*" >&2; }

short() { printf '%.8s' "${1:-}"; }

# ---------------------------------------------------------------------------
# Portable timeout (macOS ships no coreutils `timeout`). Returns 124 on timeout.
# Mirrors verify_cut_freshness.sh::run_to so behaviour matches the sibling gate.
# ---------------------------------------------------------------------------
run_to() {
    local secs="$1"; shift
    if command -v timeout  >/dev/null 2>&1; then timeout  "$secs" "$@"; return $?; fi
    if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?; fi
    "$@" &
    local cpid=$!
    ( sleep "$secs"; kill -0 "$cpid" 2>/dev/null && kill -TERM "$cpid" 2>/dev/null
      sleep 2;       kill -0 "$cpid" 2>/dev/null && kill -KILL "$cpid" 2>/dev/null ) >/dev/null 2>&1 &
    local wpid=$!
    local rc=0
    wait "$cpid" 2>/dev/null || rc=$?
    kill -TERM "$wpid" 2>/dev/null
    pkill -P "$wpid" >/dev/null 2>&1
    wait "$wpid" 2>/dev/null
    [ "$rc" = "143" ] && rc=124
    return "$rc"
}

# ---------------------------------------------------------------------------
# token_for / api -- fetch the ostler-ai token ONCE (never mutate the operator's
# ACTIVE gh account). In mock mode (BRANCH_TRUTH_GH_BIN set) skip real auth.
# ---------------------------------------------------------------------------
_TOKEN=""
token_for() {
    [ -n "${BRANCH_TRUTH_GH_BIN:-}" ] && { printf 'mock-token'; return 0; }
    [ -z "$_TOKEN" ] && _TOKEN="$(gh auth token --user "$ACCT" 2>/dev/null)"
    printf '%s' "$_TOKEN"
}

# api <gh-api-args...> -> sets API_OUT. Returns:
#   0 = success (HTTP 200), 1 = reachable but errored (e.g. 404 data answer),
#   2 = UNREACHABLE (network/transport error or timeout, after one retry).
API_OUT=""
_raw_api() {
    local tok; tok="$(token_for)"
    GH_TOKEN="$tok" GH_HOST=github.com run_to "$GH_API_TIMEOUT" "$GH_BIN" api "$@" 2>/dev/null
}
api() {
    local out rc
    out="$(_raw_api "$@")"; rc=$?
    if [ "$rc" -eq 0 ]; then API_OUT="$out"; return 0; fi
    out="$(_raw_api "$@")"; rc=$?            # one retry -- transient 5xx / blip
    if [ "$rc" -eq 0 ]; then API_OUT="$out"; return 0; fi
    API_OUT="$out"
    [ "$rc" -eq 124 ] && return 2            # timeout -> unreachable
    if printf '%s' "$out" | grep -q '"message"'; then return 1; fi   # reachable HTTP error
    return 2                                 # non-zero, no body -> transport failure
}

# gh_tag_sha <tag> -> echoes the COMMIT sha the tag resolves to (dereferencing
# an annotated tag), or "NONE" (no such tag) or "UNREACH".
gh_tag_sha() {
    local tag="$1" rc line objsha objtype
    api "repos/${REPO}/git/refs/tags/${tag}" --jq '.object.sha + " " + .object.type'
    rc=$?
    [ "$rc" -eq 2 ] && { echo "UNREACH"; return; }
    [ "$rc" -eq 1 ] && { echo "NONE";    return; }
    line="$(printf '%s' "$API_OUT" | tr -d '\r')"
    objsha="${line%% *}"; objtype="${line##* }"
    [ -z "$objsha" ] && { echo "NONE"; return; }
    if [ "$objtype" = "tag" ]; then
        api "repos/${REPO}/git/tags/${objsha}" --jq '.object.sha'
        rc=$?
        [ "$rc" -eq 2 ] && { echo "UNREACH"; return; }
        [ "$rc" -eq 1 ] && { echo "NONE";    return; }
        objsha="$(printf '%s' "$API_OUT" | tr -d '[:space:]')"
        [ -z "$objsha" ] && { echo "NONE"; return; }
    fi
    echo "$objsha"
}

# gh_compare <base> <head> -> echoes "<status> <ahead_by> <behind_by>"
#   status = identical|ahead|behind|diverged. ahead_by = commits <head> has that
#   <base> does not. Or "UNREACH" / "NONE".
gh_compare() {
    local base="$1" head="$2" rc
    api "repos/${REPO}/compare/${base}...${head}" \
        --jq '(.status) + " " + (.ahead_by|tostring) + " " + (.behind_by|tostring)'
    rc=$?
    [ "$rc" -eq 2 ] && { echo "UNREACH"; return; }
    [ "$rc" -eq 1 ] && { echo "NONE";    return; }
    printf '%s' "$API_OUT" | tr -d '\r\n'
}

# ---------------------------------------------------------------------------
# Locate the shipping ledger. Explicit override wins; then HR015_DIR; then a
# small ordered candidate list (sibling-layout + the cut-machine canonical
# location). Overridable at every step -- release infra, never ships in the DMG.
# ---------------------------------------------------------------------------
find_ledger() {
    local c
    if [ -n "${SHIPPING_LEDGER_FILE:-}" ]; then printf '%s' "$SHIPPING_LEDGER_FILE"; return; fi
    local -a cands=()
    [ -n "${HR015_DIR:-}" ] && cands+=("${HR015_DIR}/SHIPPING_LEDGER.yaml")
    cands+=(
        "${CM051_DIR}/../HR015 - Gaming PC/SHIPPING_LEDGER.yaml"
        "${CM051_DIR}/SHIPPING_LEDGER.yaml"
        "${CM051_DIR}/launch/SHIPPING_LEDGER.yaml"
        # Cut-machine canonical location (Andy's MBP layout: CM051 lives in
        # ~/Developer, HR015 in ~/Documents/Projects -- NOT siblings). Overridable
        # via SHIPPING_LEDGER_FILE / HR015_DIR above.
        "${HOME}/Documents/Projects/HR015 - Gaming PC/SHIPPING_LEDGER.yaml"
    )
    for c in "${cands[@]}"; do
        [ -r "$c" ] && { printf '%s' "$c"; return; }
    done
    printf '%s' "${cands[0]}"   # report the primary candidate in the error
}

# newest dmg_cuts.contains_daemon from the ledger (entries are newest-first).
ledger_last_daemon() {
    awk '
        /^dmg_cuts:/            { inseg=1; next }
        inseg && /^[A-Za-z_]/   { inseg=0 }            # next top-level key ends the section
        inseg && $1=="contains_daemon:" { print $2; exit }
    ' "$1"
}

# ---------------------------------------------------------------------------
echo "=== Branch-truth pre-cut gate (CM051) ==="
echo "daemon repo: ${REPO}"

# --- THIS_DAEMON_TAG from the Makefile pin ---------------------------------
DAEMON_VERSION="$(grep -m1 -E '^DAEMON_VERSION[[:space:]]*\?=' "${GUI_MAKEFILE}" 2>/dev/null \
    | sed -E 's/.*\?=[[:space:]]*([^[:space:]#]+).*/\1/')"
if [ -z "${DAEMON_VERSION}" ]; then
    err "cannot read DAEMON_VERSION from ${GUI_MAKEFILE}"
    info "the gate cannot know which daemon this cut pins -- fix the pin, re-run."
    exit 1
fi
case "${DAEMON_VERSION}" in
    hub-v*) THIS_TAG="${DAEMON_VERSION}" ;;
    *)      THIS_TAG="hub-v${DAEMON_VERSION}" ;;
esac

# --- LAST_SHIPPED_DAEMON_TAG from the ledger -------------------------------
LEDGER="$(find_ledger)"
if [ ! -r "${LEDGER}" ]; then
    err "SHIPPING_LEDGER.yaml not found/readable (looked for: ${LEDGER})"
    info "set SHIPPING_LEDGER_FILE=/path/to/SHIPPING_LEDGER.yaml (or HR015_DIR) and re-run."
    info "the ledger is the ONLY record of what the last cut actually shipped -- fail-closed."
    exit 1
fi
LAST_TAG="$(ledger_last_daemon "${LEDGER}")"
if [ -z "${LAST_TAG}" ]; then
    err "no dmg_cuts.contains_daemon entry in ${LEDGER}"
    info "the ledger has no record of a last-shipped daemon -- cannot prove non-regression."
    exit 1
fi

echo "ledger:      ${LEDGER}"
echo "this pin:    DAEMON_VERSION=${DAEMON_VERSION} -> tag ${THIS_TAG}"
echo "last ship:   dmg_cuts[newest].contains_daemon -> tag ${LAST_TAG}"
echo

# --- resolve both tags to shas (proves each tag exists) --------------------
THIS_SHA="$(gh_tag_sha "${THIS_TAG}")"
LAST_SHA="$(gh_tag_sha "${LAST_TAG}")"
for pair in "this:${THIS_TAG}:${THIS_SHA}" "last:${LAST_TAG}:${LAST_SHA}"; do
    which="${pair%%:*}"; rest="${pair#*:}"; tag="${rest%%:*}"; sha="${rest##*:}"
    case "${sha}" in
        UNREACH)
            err "GitHub unreachable resolving ${which} daemon tag ${tag}"
            info "network/transport failure after retry -- cannot verify. Re-run on a connected cut host."
            exit 3 ;;
        NONE|"")
            err "${which} daemon tag ${tag} does not exist on ${REPO}"
            info "the pin/ledger references a tag that was never pushed -- fail-closed."
            exit 1 ;;
    esac
done
info "this ${THIS_TAG} = $(short "${THIS_SHA}")   last ${LAST_TAG} = $(short "${LAST_SHA}")"

# ===========================================================================
# HARD FAIL -- the pinned daemon must CONTAIN the last-shipped daemon.
# ===========================================================================
HARD_RC=0
CMP="$(gh_compare "${LAST_TAG}" "${THIS_TAG}")"
case "${CMP}" in
    UNREACH)
        err "GitHub unreachable comparing ${LAST_TAG}...${THIS_TAG}"
        info "cannot verify non-regression -- fail-closed. Re-run on a connected cut host."
        exit 3 ;;
    NONE)
        err "compare ${LAST_TAG}...${THIS_TAG} returned no data (bad ref?)"
        exit 1 ;;
esac
STATUS="${CMP%% *}"
case "${STATUS}" in
    identical)
        ok "pinned daemon ${THIS_TAG} is IDENTICAL to last ship ${LAST_TAG} -- no dropped commits" ;;
    ahead)
        ok "pinned daemon ${THIS_TAG} is AHEAD of last ship ${LAST_TAG} (${CMP#* } ahead/behind) -- contains everything shipped" ;;
    behind|diverged)
        # Regression: this cut is missing commits the last ship contained. Check
        # the rollback ack ledger before hard-failing.
        ACKED=0
        if [ -r "${ACK_FILE}" ]; then
            while IFS=$'\t' read -r a_this a_last a_reason; do
                case "${a_this}" in ''|\#*) continue ;; esac
                a_this="$(printf '%s' "$a_this" | tr -d '[:space:]')"
                a_last="$(printf '%s' "$a_last" | tr -d '[:space:]')"
                if [ "${a_this}" = "${THIS_TAG}" ] && [ "${a_last}" = "${LAST_TAG}" ]; then
                    ACKED=1; ACK_REASON="${a_reason}"; break
                fi
            done < "${ACK_FILE}"
        fi
        if [ "${ACKED}" -eq 1 ]; then
            warn "pinned daemon ${THIS_TAG} is ${STATUS} vs last ship ${LAST_TAG} -- DOWNGRADED by branch_truth_ack.tsv"
            info "acked rollback: ${ACK_REASON:-<no reason recorded>}"
            info "(intentional rollback -- proceeding, but this cut drops commits the last ship contained)"
        else
            err "pinned daemon ${THIS_TAG} is ${STATUS} vs last ship ${LAST_TAG} -- DROPS SHIPPED COMMITS"
            info "compare ${LAST_TAG}...${THIS_TAG} = ${CMP} (behind>0 means the last ship has commits this pin lacks)"
            info "this is the v1.0.12-class regression: a cut may never drop what a previous ship contained."
            info "FIX: re-pin DAEMON_VERSION to a tag that DESCENDS from ${LAST_TAG} (graft-forward, do not rebuild from a diverged main),"
            info "     or -- for a DELIBERATE rollback -- add a row to ${ACK_FILE}:  ${THIS_TAG}<TAB>${LAST_TAG}<TAB><reason>"
            HARD_RC=1
        fi ;;
    *)
        err "unexpected compare status '${STATUS}' for ${LAST_TAG}...${THIS_TAG} (raw: ${CMP})"
        HARD_RC=1 ;;
esac

# ===========================================================================
# LOUD WARN -- pinned tag vs main (the known-deferred v1.0.14 reconcile).
# Never fails the cut; MUST be printed so the divergence is never silent.
# ===========================================================================
echo
echo "--- deferred-reconcile visibility (pin vs ${MAIN_BRANCH}, NON-blocking) ---"
MCMP="$(gh_compare "${MAIN_BRANCH}" "${THIS_TAG}")"
case "${MCMP}" in
    UNREACH|NONE|"")
        warn "could not compare ${MAIN_BRANCH}...${THIS_TAG} (${MCMP:-empty}) -- reconcile status UNKNOWN this run" ;;
    *)
        M_STATUS="${MCMP%% *}"; M_REST="${MCMP#* }"
        M_AHEAD="${M_REST%% *}"; M_BEHIND="${M_REST##* }"
        if [ "${M_STATUS}" = "identical" ]; then
            ok "pinned daemon ${THIS_TAG} is IDENTICAL to ${MAIN_BRANCH} -- fully reconciled"
        else
            warn "pinned daemon ${THIS_TAG} DIVERGES from ${MAIN_BRANCH}: ${M_AHEAD} ahead, ${M_BEHIND} behind (status=${M_STATUS})"
            info "${M_AHEAD} commit(s) are on the integration line but NOT on ${MAIN_BRANCH} (integration-only work)."
            info "${M_BEHIND} commit(s) are on ${MAIN_BRANCH} but NOT in this pin (post-tag main churn / deferred reconcile)."
            info "This is the tracked v1.0.14 integration->main reconcile -- surfaced loudly, NOT blocking this cut."
        fi ;;
esac

# --- verdict ---------------------------------------------------------------
echo
echo "=== Verdict ==="
if [ "${HARD_RC}" -eq 0 ]; then
    echo "  ${C_G}BRANCH-TRUTH GREEN${C_0} -- pinned daemon contains the last ship. Safe to cut."
    exit 0
else
    echo "  ${C_R}BRANCH-TRUTH RED${C_0} -- pinned daemon drops commits the last ship contained. DO NOT CUT."
    exit 1
fi
