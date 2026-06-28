#!/usr/bin/env bash
#
# tests/test_tailscale_signin_hoisted.sh
#
# WALK-2 (2026-06-28): the Tailscale INSTALL + browser sign-in + tailnet-IP
# capture is HOISTED to install.sh §3.7b -- immediately after the pre-FDA
# staging tree is promoted onto ~/.ostler, and BEFORE the long unattended
# middle (graph DBs, the big AI-model download, every service setup, all
# hydration and the first wiki compile). Combined with the Phase-2 question
# block and the upfront FDA grant, this lands ALL user interaction in the
# first few minutes so the rest of the install is genuinely walk-away.
#
# The original §3.15 step is now a SILENT, non-interactive persist of the
# already-captured OSTLER_TAILSCALE_IP into the daemon .env -- no prompt,
# no browser, no STEP_BEGIN row.
#
# This test pins the invariant so a future edit cannot drag the
# interactive sign-in back down into the unattended middle, nor make the
# late persist interactive again.
#
# Synthetic only. Pure bash + awk.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$INSTALL_SH" ]] || fail "install.sh not found"
bash -n "$INSTALL_SH" || fail "install.sh fails bash -n"
echo "PASS: install.sh parses"

# ── The hoisted sign-in row fires exactly once, as an unconditional step ──
ts_progress_count="$(grep -cE '^progress "Connect your iPhone and Watch" "tailscale_connect"' "$INSTALL_SH")"
[[ "$ts_progress_count" -eq 1 ]] \
    || fail "expected exactly one column-0 'tailscale_connect' progress callsite, found $ts_progress_count"
echo "PASS: single unconditional tailscale_connect progress callsite"

ts_line="$(grep -nE '^progress "Connect your iPhone and Watch" "tailscale_connect"' "$INSTALL_SH" | head -1 | cut -d: -f1)"
graph_line="$(grep -n 'progress "Starting your knowledge graph databases" "graph_db_start"' "$INSTALL_SH" | head -1 | cut -d: -f1)"
[[ -n "$ts_line" && -n "$graph_line" ]] || fail "could not locate tailscale_connect / graph_db_start progress lines"
[[ "$ts_line" -lt "$graph_line" ]] \
    || fail "tailscale_connect progress (line $ts_line) must fire BEFORE graph_db_start (line $graph_line) -- the sign-in is hoisted upfront"
echo "PASS: tailscale_connect fires before graph_db_start ($ts_line < $graph_line)"

# ── The hoist lands AFTER the staging-tree promote (so the LaunchAgent ──
# plist embeds final ~/.ostler paths, not /tmp staging paths). The
# convergence promote sits right before the Docker-services step.
promote_before_graph="$(awk -v g="$graph_line" '
    NR<g && /^[[:space:]]*_ostler_promote_prelaunch_tree[[:space:]]*$/ { last=NR }
    END { print last }
' "$INSTALL_SH")"
[[ -n "$promote_before_graph" && "$promote_before_graph" -lt "$ts_line" ]] \
    || fail "the Tailscale hoist (line $ts_line) must land AFTER a _ostler_promote_prelaunch_tree call (last before graph_db at line ${promote_before_graph:-none}) so the LaunchAgent plist embeds final ~/.ostler paths"
echo "PASS: hoist lands after staging-tree promote (promote $promote_before_graph < sign-in $ts_line)"

# ── The actual install + browser auth happen in the hoisted block ─────
for needle in 'brew install tailscale' 'up --hostname=ostler-hub' 'open -g -a Safari'; do
    n_line="$(grep -nF "$needle" "$INSTALL_SH" | head -1 | cut -d: -f1)"
    [[ -n "$n_line" ]] || fail "expected '$needle' to be present (the hoisted sign-in body)"
    [[ "$n_line" -lt "$graph_line" ]] \
        || fail "'$needle' is at line $n_line, AFTER graph_db_start ($graph_line) -- the install/auth must be hoisted upfront"
done
echo "PASS: brew install + tailscale up + Safari open all fire before graph_db_start"

# ── The hoisted block captures + persists the tailnet IP for the late step ──
grep -q 'printf .*"\$OSTLER_TAILSCALE_IP" > "\${TS_STATE_DIR}/.tailnet-ip"' "$INSTALL_SH" \
    || fail "the hoisted block must persist the captured IP to a durable .tailnet-ip file the late step reads"
grep -q 'export OSTLER_TAILSCALE_IP' "$INSTALL_SH" \
    || fail "the hoisted block must export OSTLER_TAILSCALE_IP so the deferred .env write sees it"
echo "PASS: hoisted block exports + persists the captured tailnet IP"

# ── The late §3.15 step is SILENT: no browser / no install / no prompt ──
# Everything after graph_db_start that touches Tailscale must be the
# .env persist only. No `tailscale up`, no Safari open, no brew install,
# no tailscale_confirm gui_read after graph_db_start.
late_offenders="$(awk -v g="$graph_line" '
    NR>g && (/up --hostname=ostler-hub/ || /brew install tailscale/ || /open -a Safari/ || /open -g -a Safari/ || /gui_read.*tailscale_confirm/) { print NR": "$0 }
' "$INSTALL_SH")"
[[ -z "$late_offenders" ]] \
    || fail "the late §3.15 step must be SILENT, but found interactive/install code after graph_db_start:\n$late_offenders"
echo "PASS: no interactive Tailscale install/auth code after graph_db_start"

# ── The silent late step still persists OSTLER_TAILSCALE_IP to .env ───
silent_hdr="$(grep -n 'Tailscale .env persist (SILENT' "$INSTALL_SH" | head -1 | cut -d: -f1)"
[[ -n "$silent_hdr" && "$silent_hdr" -gt "$graph_line" ]] \
    || fail "the silent §3.15 .env-persist block must exist after graph_db_start"
silent_env_write="$(awk -v s="$silent_hdr" 'NR>=s && /OSTLER_TAILSCALE_IP=\\"\$\{OSTLER_TAILSCALE_IP\}\\"/ { print NR; exit }' "$INSTALL_SH")"
[[ -n "$silent_env_write" ]] \
    || fail "the silent §3.15 block must still write OSTLER_TAILSCALE_IP into the .env"
echo "PASS: silent §3.15 block persists OSTLER_TAILSCALE_IP to .env"

echo "ALL PASS: test_tailscale_signin_hoisted.sh"
