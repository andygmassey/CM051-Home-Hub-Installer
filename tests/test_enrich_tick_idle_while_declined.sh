#!/usr/bin/env bash
# tests/test_enrich_tick_idle_while_declined.sh
# ============================================================================
# CB136-WALK-UPGRADE-PATH (R02), option (b): the recurring enrich job is installed
# on every box and idles while the owner has declined. This test runs the REAL
# tick wrapper (extracted from install.sh's ENRTICKEOF heredoc) with the network
# tools shimmed on PATH to RECORD any call.
#
#   T1  declined: the wrapper stands down ("standing down, nothing sent") and
#       makes ZERO curl calls, which is every outbound path it has
#   T2  accepted (positive control): the same wrapper gets past the gate and calls
#       curl. Without this, T1 could pass because the wrapper never ran.
#   T3  declined, prior accept gone (no .env at all): stands down too
#
# MUTANT: INSTALL_SH=<a copy with the consent gate removed> must turn T1 red.
# Exit 0 pass, 1 assertion failed, 2 cannot-run.
# ============================================================================
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${INSTALL_SH:-${REPO}/install.sh}"
[ -r "$SRC" ] || { echo "CANNOT-RUN: cannot read $SRC"; exit 2; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
TICK="$WORK/ostler-enrich-tick"
awk '/cat > "\$wrapper" <<'"'"'ENRTICKEOF'"'"'/{f=1; next} f && /^ENRTICKEOF$/{exit} f{print}' "$SRC" > "$TICK"
if [ ! -s "$TICK" ] || ! grep -q 'standing down, nothing sent' "$TICK"; then
    echo "CANNOT-RUN: the tick wrapper was not found in $SRC"; exit 2
fi
SHIM="$WORK/shim"; mkdir -p "$SHIM"
for tool in curl nc; do
    cat > "$SHIM/$tool" <<SHIMEOF
#!/bin/sh
echo "$tool \$*" >> "$WORK/net_calls.log"
exit 1
SHIMEOF
    chmod +x "$SHIM/$tool"
done
fails=0
run_tick() {   # name, decision-line-or-empty (empty = no config/.env at all)
    local name="$1" line="$2" dir="$WORK/$1"
    mkdir -p "$dir/config" "$dir/logs" "$dir/services/cm019/.venv/bin"
    # The wrapper needs a CM019 interpreter to get past its preflight. A recording
    # stand-in: any run of it is an enrichment launch, counted with the network calls.
    cat > "$dir/services/cm019/.venv/bin/python3" <<PYEOF
#!/bin/sh
echo "cm019-enrich \$*" >> "$WORK/net_calls.log"
exit 0
PYEOF
    chmod +x "$dir/services/cm019/.venv/bin/python3"
    rm -f "$WORK/net_calls.log"
    [ -n "$line" ] && printf '%s\n' "$line" > "$dir/config/.env"
    env -i PATH="$SHIM:/usr/bin:/bin" HOME="$dir" OSTLER_DIR="$dir" \
        /bin/bash "$TICK" >/dev/null 2>&1
    local rc=$?
    local calls=0
    [ -f "$WORK/net_calls.log" ] && calls=$(wc -l < "$WORK/net_calls.log" | tr -d ' ')
    local stood=no
    grep -q 'standing down, nothing sent' "$dir/logs/enrich.log" 2>/dev/null && stood=yes
    echo "  $name: rc=$rc network_calls=$calls stood_down=$stood" >&2
    printf '%s %s %s\n' "$rc" "$calls" "$stood"
}
expect_idle() {   # name, result-line
    set -- $2
    if [ "$2" = 0 ] && [ "$3" = yes ]; then echo "    held (idle, no network call)"; else echo "    FAILED want calls=0 stood_down=yes, got calls=$2 stood_down=$3"; fails=$((fails+1)); fi
}
r=$(run_tick T1_declined 'OSTLER_CONSENT_ENRICHMENT_DECISION="declined"'); expect_idle T1 "$r"
r=$(run_tick T3_no_answer ''); expect_idle T3 "$r"
r=$(run_tick T2_accepted_control 'OSTLER_CONSENT_ENRICHMENT_DECISION="accepted"')
set -- $r
if [ "$2" -ge 1 ] && [ "$3" = no ]; then echo "    held (control: accepted reaches the network path, $2 call(s))"; else echo "    FAILED control: accepted did not reach the network path (calls=$2 stood_down=$3)"; fails=$((fails+1)); fi
if [ "$fails" -eq 0 ]; then echo "PASS: a declined tick stands down with zero network calls; the accepted control reaches the network"; exit 0; fi
echo "FAIL: $fails check(s)"; exit 1
