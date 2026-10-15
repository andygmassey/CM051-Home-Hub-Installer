#!/usr/bin/env bash
# #30: catch-up runs every 30 minutes for the first 48 hours after install,
# then every 4 hours, from ONE LaunchAgent (com.ostler.export-scan,
# StartInterval 1800). A non-due run exits at once; a busy run says why.
#
# Drives the SHIPPED ostler-scan-exports text extracted from install.sh, in a
# sandbox HOME, with a fake clock (OSTLER_CADENCE_NOW) and fake catch-up
# runners that record each invocation. THREE OUTCOMES; CANNOT-RUN is exit 2.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="${REPO}/install.sh"
[ -f "$INSTALL" ] || { echo "CANNOT-RUN: no install.sh" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $*"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }

SB="$(mktemp -d "${TMPDIR:-/tmp}/catchup-cadence.XXXXXX")"
trap 'rm -rf "$SB"' EXIT
awk '/^cat > "\$\{OSTLER_DIR\}\/bin\/ostler-scan-exports" <<'"'"'SCANEOF'"'"'$/{f=1;next} /^SCANEOF$/{f=0} f' \
    "$INSTALL" > "$SB/ostler-scan-exports"
[ -s "$SB/ostler-scan-exports" ] || { echo "CANNOT-RUN: could not extract ostler-scan-exports" >&2; exit 2; }

# The plist: one agent, 30 minute interval.
plist="$(awk '/^SCAN_PLIST=/{f=1} f{print} /^SPEOF$/{if(f)exit}' "$INSTALL")"
[ "$(grep -c 'com.ostler.export-scan' <<<"$plist")" -ge 1 ] || { echo "CANNOT-RUN: plist block not found" >&2; exit 2; }
grep -A1 '<key>StartInterval</key>' <<<"$plist" | grep -q '<integer>1800</integer>' \
    && ok "export-scan plist StartInterval is 1800" || bad "export-scan plist StartInterval is not 1800"

home="$SB/home"
OD="$home/.ostler"
mkdir -p "$OD/lib" "$OD/bin/catchup.d" "$OD/state" "$home/Downloads"
: > "$OD/lib/ostler_catchup.py"
cat > "$OD/bin/catchup.d/10-alpha.sh" <<RUNNER
#!/bin/bash
echo "ran budget=\$1" >> "$SB/invocations.log"
RUNNER
chmod +x "$OD/bin/catchup.d/10-alpha.sh"
INSTALL_TS=1000000000
echo "$INSTALL_TS" > "$OD/state/install_completed_at"

LASTRC=0
# tick <seconds-after-install>: prints the number of runner invocations it caused
tick() {
    local before=0 after=0
    [ -f "$SB/invocations.log" ] && before="$(wc -l < "$SB/invocations.log" | tr -d ' ')"
    HOME="$home" OSTLER_CADENCE_NOW=$((INSTALL_TS + $1)) OSTLER_CATCHUP_BUDGET_SECONDS=600 \
        /bin/bash "$SB/ostler-scan-exports" >/dev/null 2>"$SB/err" || echo "RC" >> "$SB/rc_bad"
    [ -f "$SB/invocations.log" ] && after="$(wc -l < "$SB/invocations.log" | tr -d ' ')"
    echo $((after - before))
}
h=3600
t() { local n; n="$(tick "$1")"; echo "$n"; }

# Inside 48 h: a run every 30 minutes is due.
[ "$(t 60)" = 1 ] && ok "first tick runs catch-up" || bad "first tick did not run"
[ "$(t $((60 + 1800)))" = 1 ] && ok "+30 min runs catch-up" || bad "+30 min did not run"
[ "$(t $((60 + 3600)))" = 1 ] && ok "+60 min runs catch-up" || bad "+60 min did not run"
[ "$(t $((60 + 3600 + 300)))" = 0 ] && ok "a tick 5 min later is not due" || bad "a tick 5 min later ran"
[ "$(t $((47 * h)))" = 1 ] && ok "47 h in: still every 30 min" || bad "47 h in: did not run"
[ "$(t $((47 * h + 1800)))" = 1 ] && ok "47.5 h in: still every 30 min" || bad "47.5 h in: did not run"
# After 48 h: every 4 hours (the last FULL run was at 47 h).
[ "$(t $((49 * h)))" = 0 ] && ok "49 h in: NOT due (2 h since the last full run)" || bad "49 h in: ran"
[ "$(t $((49 * h + 1800)))" = 0 ] && ok "49.5 h in: NOT due (4 h cadence, not 30 min)" || bad "49.5 h in: ran at 30 min cadence after 48 h"
[ "$(t $((51 * h + 60)))" = 1 ] && ok "51 h in: due (4 h after the last full run)" || bad "51 h in: did not run"
[ "$(t $((51 * h + 1860)))" = 0 ] && ok "51.5 h in: NOT due" || bad "51.5 h in: ran"
[ "$(t $((54 * h)))" = 0 ] && ok "54 h in: NOT due" || bad "54 h in: ran"
[ "$(t $((55 * h + 120)))" = 1 ] && ok "55 h in: due again" || bad "55 h in: did not run"
[ ! -f "$SB/rc_bad" ] && ok "every tick exited 0" || bad "a tick exited non-zero: $(tail -2 "$SB/err")"

# No install timestamp (an upgraded box): one is written, and the box gets its 48 h.
rm -f "$OD/state/install_completed_at" "$OD/state/export-scan/last_full_run" "$SB/invocations.log"
HOME="$home" OSTLER_CADENCE_NOW=$((INSTALL_TS + 99999)) /bin/bash "$SB/ostler-scan-exports" >/dev/null 2>&1
[ "$(cat "$OD/state/install_completed_at" 2>/dev/null)" = "$((INSTALL_TS + 99999))" ] \
    && ok "a missing install timestamp is written at first run" || bad "no install timestamp written"
# And catch-up still runs with an empty Downloads.
[ -f "$SB/invocations.log" ] && ok "catch-up ran with an empty Downloads" || bad "catch-up did not run with an empty Downloads"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
