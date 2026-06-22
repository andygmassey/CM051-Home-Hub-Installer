#!/usr/bin/env bash
# test_dedupe_defer_background.sh -- v1.0.2 install-orchestration (P0).
#
# The whole-graph dedupe converge pass dominated the install critical path
# (a ~1h50 install was almost entirely this step on a large address book).
# v1.0.2 caps the install-time converge at a hard budget and DEFERS the
# completion to a self-removing post-install LaunchAgent, mirroring the
# wiki AI-summaries split (baseline now, enrichment in the background).
#
# Structural checks assert install.sh carries the cap + the defer wiring.
# Behavioural checks reproduce the budget-cap loop in a sandbox and prove
# (a) a fast converge is NOT deferred and (b) a slow converge IS capped +
# deferred without blocking past the budget.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${HERE}/../install.sh"
STRINGS_SH="${HERE}/../install.sh.strings.en-GB.sh"
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "== structural: install.sh caps + defers the dedupe converge =="
grep -q 'OSTLER_DEDUPE_INSTALL_BUDGET_S' "$INSTALL_SH" \
    && ok "install-time converge budget is env-overridable" \
    || bad "OSTLER_DEDUPE_INSTALL_BUDGET_S budget knob missing"
grep -q '_DEDUPE_WAITED" -ge "\$_DEDUPE_BUDGET_S"' "$INSTALL_SH" \
    && ok "hard time cap enforced against the budget" \
    || bad "hard time cap on the converge is missing"
grep -q '_install_dedupe_catchup_agent' "$INSTALL_SH" \
    && ok "defer hands completion to the catch-up agent" \
    || bad "dedupe catch-up agent install call missing"
grep -q 'com.creativemachines.ostler.dedupe-catchup' "$INSTALL_SH" \
    && ok "catch-up LaunchAgent label present" \
    || bad "dedupe-catchup LaunchAgent label missing"
# The catch-up agent must be torn down on uninstall (bootout + plist rm).
grep -q 'bootout "gui/$(id -u)/com.creativemachines.ostler.dedupe-catchup"' "$INSTALL_SH" \
    && grep -q 'rm -f "${HOME}/Library/LaunchAgents/com.creativemachines.ostler.dedupe-catchup.plist"' "$INSTALL_SH" \
    && ok "catch-up agent is torn down on uninstall" \
    || bad "dedupe-catchup uninstall teardown missing"
# The catch-up wrapper must self-remove once the converge is done and must
# reuse the existing wiki recompile tick (no duplicated compile logic).
grep -q 'DONE_MARKER="${STATE_DIR}/dedupe-converge.done"' "$INSTALL_SH" \
    && ok "catch-up keys completion off the .done marker" \
    || bad "catch-up .done marker wiring missing"
grep -q 'wiki-recompile-tick.sh' "$INSTALL_SH" \
    && ok "catch-up reuses the wiki recompile tick (no new compile logic)" \
    || bad "catch-up does not trigger a wiki recompile"
# i18n: customer-facing defer copy must be locale-driven.
for k in MSG_INFO_DEDUPE_DEFERRED_BACKGROUND MSG_OK_DEDUPE_CATCHUP_LOADED \
         MSG_WARN_DEDUPE_CATCHUP_LOAD_FAILED MSG_INFO_DEDUPE_COMPLETE_NO_CATCHUP; do
    grep -q "^${k}=" "$STRINGS_SH" \
        && ok "string ${k} defined" \
        || bad "string ${k} missing from en-GB catalogue"
done

echo "== behavioural: budget cap defers slow, completes fast =="
# Faithful reproduction of the install.sh cap loop, with a short tick +
# budget so the test is fast. Echoes "deferred" if the cap fired, else
# "merged". Touches a marker on clean completion (the real .done marker).
run_capped() {
    local _cmd="$1" _tick="$2" _budget="$3" _marker="$4"
    rm -f "$_marker"
    ( bash -c "$_cmd" && touch "$_marker" ) >/dev/null 2>&1 &
    local _pid=$! _waited=0 _timed_out=false
    while kill -0 "$_pid" 2>/dev/null; do
        sleep "$_tick"
        _waited=$(( _waited + _tick ))
        if [[ "$_waited" -ge "$_budget" ]] && kill -0 "$_pid" 2>/dev/null; then
            _timed_out=true
            kill "$_pid" 2>/dev/null || true
            sleep 1
            kill -9 "$_pid" 2>/dev/null || true
            break
        fi
    done
    if [[ "$_timed_out" == "true" ]]; then
        wait "$_pid" 2>/dev/null || true
        echo "deferred"
    elif wait "$_pid"; then
        echo "merged"
    else
        echo "failed"
    fi
}

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
M="${TMPD}/done"

# 1. Fast converge (well under budget) -> completes, marker present, NOT deferred.
out="$(run_capped 'sleep 1; exit 0' 1 5 "$M")"
[[ "$out" == "merged" && -f "$M" ]] \
    && ok "fast converge completes within budget (no defer, .done written)" \
    || bad "fast converge wrong (out=$out marker=$( [[ -f "$M" ]] && echo present || echo absent ))"

# 2. Slow converge (exceeds budget) -> capped + deferred, no marker, did
#    NOT block beyond ~budget+tick.
start=$(date +%s)
out="$(run_capped 'sleep 30; exit 0' 1 3 "$M")"
elapsed=$(( $(date +%s) - start ))
[[ "$out" == "deferred" && ! -f "$M" && "$elapsed" -lt 10 ]] \
    && ok "slow converge capped + deferred (no .done, returned in ${elapsed}s)" \
    || bad "slow converge not capped (out=$out elapsed=${elapsed}s marker=$( [[ -f "$M" ]] && echo present || echo absent ))"

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
