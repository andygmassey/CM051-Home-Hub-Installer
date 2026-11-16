#!/usr/bin/env bash
# F010: (a) the CLT wait never aborts, (b) the GDPR scan is bounded.
# Synthetic fixtures only. Every stub is on PATH or an env seam: no real
# xcode-select, no GUI, no TCC. Each arm has a control or a mutant that must
# go RED, so a pass cannot come from a dead predicate.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SH="${F010_INSTALL_SH:-${HERE}/../install.sh}"
DETECT="${F010_DETECT:-${HERE}/../lib/ostler-detect-exports.sh}"
STRINGS="${HERE}/../install.sh.strings.en-GB.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }

# ── (a) CLT wait ──────────────────────────────────────────────────────────
BLOCK="$TMP/clt_block.sh"
awk '/^# >>> clt-wait$/{f=1;next} /^# <<< clt-wait$/{f=0} f' "$INSTALL_SH" > "$BLOCK"
[[ -s "$BLOCK" ]] || { bad "clt-wait block markers not found in install.sh"; echo "FAILED"; exit 1; }

# run_clt <block-file> <calls-until-installed>  -> sets CLT_RC, CLT_LOG
run_clt() {
    local block="$1" until_n="$2" d; d="$(mktemp -d "$TMP/run.XXXXXX")"
    printf '0' > "$d/calls"
    cat > "$d/xcode-select" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "--install" ]]; then echo install >> "$d/popped"; exit 0; fi
n=\$(cat "$d/calls"); n=\$((n + 1)); printf '%s' "\$n" > "$d/calls"
[[ "\$n" -gt $until_n ]] && exit 0
exit 1
STUB
    chmod +x "$d/xcode-select"
    cat > "$d/harness.sh" <<H
set -euo pipefail
source "$STRINGS"
info() { echo "INFO \$*" >> "$d/log"; }
warn() { echo "WARN \$*" >> "$d/log"; }
ok()   { echo "OK \$*" >> "$d/log"; }
gui_emit() { echo "EMIT \$*" >> "$d/log"; }
fail_with_code() { echo "ABORT \$1" >> "$d/log"; exit 97; }
sleep() { :; }
export OSTLER_XCODE_SELECT_BIN="$d/xcode-select"
source "$block"
echo reached-after-wait >> "$d/log"
H
    CLT_RC=0
    /bin/bash "$d/harness.sh" 2>"$d/err" || CLT_RC=$?
    CLT_LOG="$(cat "$d/log" 2>/dev/null || true)"
    CLT_DIR="$d"
}

# A: 200 failed probes x 10s = 2000s of simulated wait, past the 900s timeout.
run_clt "$BLOCK" 200
if [[ "$CLT_RC" -eq 0 ]] && ! grep -q '^ABORT' <<<"$CLT_LOG" \
   && grep -q 'reached-after-wait' <<<"$CLT_LOG"; then
    ok "slow CLT past the timeout: keeps waiting, no fail_with_code, proceeds once installed"
else bad "slow CLT: rc=$CLT_RC log=$CLT_LOG"; fi
if grep -q "^WARN Still waiting for Apple's developer tools. Click Install developer tools" <<<"$CLT_LOG" \
   && grep -q '^EMIT CLT_WAIT state=timeout' <<<"$CLT_LOG"; then
    ok "after the timeout the screen says so (WARN line + CLT_WAIT state=timeout marker)"
else bad "timeout not announced: $CLT_LOG"; fi
states="$(grep '^EMIT CLT_WAIT' <<<"$CLT_LOG" | sed 's/.*state=//' | tr '\n' ',')"
[[ "$states" == "waiting,timeout,done," ]] && ok "marker order: $states" || bad "marker order: $states"
[[ "$(grep -c 'state=timeout' <<<"$CLT_LOG")" -eq 1 ]] && ok "timeout marker emitted once" || bad "timeout marker count"
[[ -f "$CLT_DIR/popped" ]] && ok "dialog re-popped once at ~2 min" || bad "no re-pop"

# B: already installed at the end of the questions: no wait at all.
run_clt "$BLOCK" 0
if [[ "$CLT_RC" -eq 0 ]] && ! grep -qE '^(INFO|WARN|EMIT|ABORT)' <<<"$CLT_LOG" \
   && [[ ! -f "$CLT_DIR/popped" ]]; then
    ok "CLT already installed: wait skipped (no log, no marker, no pop)"
else bad "installed case: rc=$CLT_RC log=$CLT_LOG"; fi

# Mutant: restore the abort inside the timeout branch; arm A's predicate must go RED.
MUT="$TMP/clt_mutant.sh"
sed 's/^\( *\)XCODE_TIMEOUT_ANNOUNCED=1$/&\n\1fail_with_code "ERR-02-PREREQ-XCODE-CLI" "x"/' "$BLOCK" > "$MUT"
cmp -s "$BLOCK" "$MUT" && bad "mutant did not change the block"
run_clt "$MUT" 200
if [[ "$CLT_RC" -eq 97 ]] && grep -q '^ABORT ERR-02-PREREQ-XCODE-CLI' <<<"$CLT_LOG"; then
    ok "MUTANT (abort restored) goes RED: detected ABORT rc=97"
else bad "mutant not detected: rc=$CLT_RC"; fi

# ── (b) bounded GDPR scan ─────────────────────────────────────────────────
D="$TMP/Desktop"
mkdir -p "$D/real_export" "$D/oldmac/Library/Preferences" "$D/oldmac/Documents/stuff" \
         "$D/Library/ok_name_at_top"
printf 'First Name,Last Name\nKerry,Lee\n' > "$D/real_export/Connections.csv"
printf 'First Name,Last Name\nA,B\n'      > "$D/oldmac/Documents/stuff/Connections.csv"
printf 'From x\n'                         > "$D/oldmac/Documents/old.mbox"

run_detect() {  # run_detect <mode> [env...] -> DET_OUT DET_ERR DET_RC
    local mode="$1"; shift
    DET_RC=0
    DET_OUT="$(env TMPDIR="$TMP" "$@" bash "$DETECT" "$D" ${mode:+"$mode"} 2>"$TMP/det.err")" || DET_RC=$?
    DET_ERR="$(cat "$TMP/det.err")"
}

run_detect ""
if grep -q 'real_export' <<<"$DET_OUT" && ! grep -q 'oldmac' <<<"$DET_OUT"; then
    ok "nested backup skipped: real export found, planted backup tree not reported"
else bad "default scan: $DET_OUT"; fi
grep -q 'SCAN_SUMMARY skipped_nested_backups=1 budget_hit=0' <<<"$DET_ERR" \
    && ok "counted: $(grep SCAN_SUMMARY <<<"$DET_ERR")" || bad "summary: $DET_ERR"
! grep -q "$TMP" <<<"$(grep SCAN_SUMMARY <<<"$DET_ERR")" && ok "summary carries counts only, no paths" || bad "path leaked"
run_detect --loose
if ! grep -q 'old.mbox' <<<"$DET_OUT" && grep -q 'skipped_nested_backups=1' <<<"$DET_ERR"; then
    ok "--loose: mbox inside the backup is not reported"
else bad "--loose: $DET_OUT"; fi

# Mutant: stop recording prune args; the backup's export must leak and the test go RED.
DMUT="$TMP/detect_mutant.sh"
sed 's/^\( *\)SCAN_PRUNE+=( -path "\$esc" -prune -o )$/\1: no-prune/' "$DETECT" > "$DMUT"
cmp -s "$DETECT" "$DMUT" && bad "detect mutant did not change the file"
leak="$(env TMPDIR="$TMP" bash "$DMUT" "$D" 2>/dev/null || true)"
grep -q 'oldmac' <<<"$leak" && ok "MUTANT (no prune) goes RED: backup tree leaks into hits" || bad "detect mutant not detected"

# Budget: 0 = scan nothing, report budget_hit=1.
run_detect "" OSTLER_SCAN_BUDGET_S=0
if grep -q 'budget_hit=1' <<<"$DET_ERR" && [[ -z "$DET_OUT" ]]; then
    ok "budget 0: scan stops, budget_hit=1, nothing reported"
else bad "budget 0: out=$DET_OUT err=$DET_ERR"; fi

# Budget mid-scan: a find that never returns is killed at the deadline.
mkdir -p "$TMP/slowbin"
printf '#!/bin/sh\nexec sleep 30\n' > "$TMP/slowbin/find"; chmod +x "$TMP/slowbin/find"
t0=$SECONDS
run_detect "" OSTLER_SCAN_BUDGET_S=1 PATH="$TMP/slowbin:$PATH"
el=$((SECONDS - t0))
if grep -q 'budget_hit=1' <<<"$DET_ERR" && [[ "$el" -lt 15 ]]; then
    ok "hung find stopped at the 1s budget (took ${el}s, not 30s)"
else bad "hung find: ${el}s err=$DET_ERR"; fi

# Depth cap honoured.
mkdir -p "$D/a/b/c/d/e/f/g"; printf 'x,y\n' > "$D/a/b/c/d/e/f/g/Connections.csv"
run_detect "" OSTLER_SCAN_MAXDEPTH=3
! grep -q "$D/a" <<<"$DET_OUT" && grep -q 'maxdepth=3' <<<"$DET_ERR" \
    && ok "depth cap 3 hides a depth-8 file; summary reports maxdepth=3" || bad "depth cap: $DET_OUT"

# No state dir left behind.
left="$(find "$TMP" -maxdepth 1 -name 'ostler-scan.*' | wc -l | tr -d ' ')"
[[ "$left" -eq 0 ]] && ok "no scan state dir left behind" || bad "$left leftover scan dirs"

# install.sh logs the counts line (wired consumer), embedded copy unchanged elsewhere.
grep -q "GDPR export scan: \${_scan_line#SCAN_SUMMARY }" "$INSTALL_SH" \
    && ok "install.sh consumes SCAN_SUMMARY (wired)" || bad "SCAN_SUMMARY has no consumer in install.sh"

# ── Shared budget across ALL detector invocations in one install ───────────
# Three slow passes (unzip, loose, default) under ONE deadline computed once by
# install.sh's scan-deadline block. Per-call budgets would cost 3 x budget.
DLBLOCK="$TMP/scan_deadline_block.sh"
awk '/^# >>> scan-deadline$/{f=1;next} /^# <<< scan-deadline$/{f=0} f' "$INSTALL_SH" > "$DLBLOCK"
if [[ ! -s "$DLBLOCK" ]]; then
    bad "scan-deadline block markers not found in install.sh"
else
    SD="$TMP/shared_scan"; mkdir -p "$SD"
    # run_three <detector> <budget>: sets T3_EL (seconds), T3_LOG.
    run_three() {
        local det="$1" budget="$2" h="$TMP/three.$RANDOM.sh" t0
        cat > "$h" <<H
set -uo pipefail
info() { echo "INFO \$*" >> "$TMP/three.log"; }
warn() { echo "WARN \$*" >> "$TMP/three.log"; }
export OSTLER_SCAN_BUDGET_S=$budget
unset OSTLER_SCAN_DEADLINE_EPOCH
export TMPDIR="$TMP"
source "$DLBLOCK"
for mode in --unzip --loose ""; do
    err="\$(bash "$det" "$SD" \$mode 2>&1 >/dev/null || true)"
    _ostler_scan_note "\$err"
done
H
        : > "$TMP/three.log"
        t0=$SECONDS
        PATH="$TMP/slowbin:$PATH" /bin/bash "$h" >/dev/null 2>&1 || true
        T3_EL=$((SECONDS - t0)); T3_LOG="$(cat "$TMP/three.log")"
    }
    run_three "$DETECT" 3
    hits="$(grep -c 'shared time budget' <<<"$T3_LOG" || true)"
    lines="$(grep -c 'GDPR export scan: ' <<<"$T3_LOG" || true)"
    if [[ "$T3_EL" -le 5 && "$hits" -eq 1 && "$lines" -ge 3 ]]; then
        ok "three slow passes under one 3s budget took ${T3_EL}s (<=5s); budget-hit logged once"
    else bad "shared budget: ${T3_EL}s hits=$hits summary_lines=$lines log=$T3_LOG"; fi

    # Mutant: restore per-call budgets (detector ignores the shared deadline).
    DMUT2="$TMP/detect_percall.sh"
    sed 's/^SCAN_DEADLINE="\${OSTLER_SCAN_DEADLINE_EPOCH:-}"$/SCAN_DEADLINE=""/' "$DETECT" > "$DMUT2"
    cmp -s "$DETECT" "$DMUT2" && bad "per-call mutant did not change the file"
    run_three "$DMUT2" 3
    if [[ "$T3_EL" -gt 5 ]]; then
        ok "MUTANT (per-call budgets) goes RED: three passes took ${T3_EL}s (>5s)"
    else bad "per-call mutant not detected (${T3_EL}s)"; fi
fi

echo
[[ "$FAILS" -eq 0 ]] && { echo "ALL F010 CLT/SCAN TESTS PASSED"; exit 0; }
echo "$FAILS F010 TEST(S) FAILED" >&2; exit 1
