#!/usr/bin/env bash
# The full-history catch-up is DRIVEN, not just written (v1.0.108).
#
# lib/ostler_catchup.py on its own is a library nobody calls. The customer
# only gets older history if com.ostler.export-scan's script, ostler-scan-exports
# (written by install.sh from a quoted heredoc), actually runs every registered
# family runner, with a bounded budget, every tick, whether or not a new export
# is in Downloads. This drives the SHIPPED script text, extracted from
# install.sh, in a sandbox HOME, and the shipped runner generator
# (_ostler_catchup_register), with a fake interpreter that records its argv.
#
# THREE OUTCOMES. CANNOT-RUN (exit 2) is not a pass.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="${REPO}/install.sh"
[ -f "$INSTALL" ] || { echo "CANNOT-RUN: no install.sh" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $*"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }

SB="$(mktemp -d "${TMPDIR:-/tmp}/catchup-scan.XXXXXX")"
trap 'rm -rf "$SB"' EXIT

# ── 1. the shipped ostler-scan-exports text ─────────────────────────────────
awk '/^cat > "\$\{OSTLER_DIR\}\/bin\/ostler-scan-exports" <<'"'"'SCANEOF'"'"'$/{f=1;next} /^SCANEOF$/{f=0} f' \
    "$INSTALL" > "$SB/ostler-scan-exports"
[ -s "$SB/ostler-scan-exports" ] || { echo "CANNOT-RUN: could not extract ostler-scan-exports from install.sh" >&2; exit 2; }
chmod +x "$SB/ostler-scan-exports"

home="$SB/home"
mkdir -p "$home/.ostler/lib" "$home/.ostler/bin/catchup.d" "$home/Downloads"
: > "$home/.ostler/lib/ostler_catchup.py"
for n in 10-alpha 20-beta; do
    cat > "$home/.ostler/bin/catchup.d/${n}.sh" <<EOF
#!/bin/bash
echo "${n} budget=\$1" >> "$SB/invocations.log"
EOF
    chmod +x "$home/.ostler/bin/catchup.d/${n}.sh"
done

HOME="$home" OSTLER_CATCHUP_BUDGET_SECONDS=600 /bin/bash "$SB/ostler-scan-exports" >/dev/null 2>"$SB/scan.err"
rc=$?
[ "$rc" -eq 0 ] && ok "ostler-scan-exports exits 0 with an empty Downloads" || bad "ostler-scan-exports rc=$rc: $(tail -3 "$SB/scan.err")"

if [ ! -f "$SB/invocations.log" ]; then
    bad "NO catch-up runner was invoked: export-scan never walks history backwards"
else
    lines="$(cat "$SB/invocations.log")"
    first="$(sed -n 1p "$SB/invocations.log")"
    second="$(sed -n 2p "$SB/invocations.log")"
    [ "$(wc -l < "$SB/invocations.log" | tr -d ' ')" = "2" ] && ok "both registered runners ran" || bad "runners invoked: ${lines}"
    [ "$first" = "10-alpha budget=300" ] && ok "first runner got a fair half of 600 s: ${first}" || bad "first: ${first}"
    b2="${second##*budget=}"
    { [ "${second%% *}" = "20-beta" ] && [ "$b2" -ge 290 ] && [ "$b2" -le 600 ]; } \
        && ok "second runner got what was left: ${second}" || bad "second: ${second}"
fi
if grep -q "catch-up 10-alpha budget=300s rc=0" "$home/.ostler/logs/catchup.log" 2>/dev/null; then
    ok "each runner's rc is recorded in logs/catchup.log"
else
    bad "no rc line in catchup.log"
fi

# CONTROL: without the core, nothing runs (a missing lib is not a crash).
rm -f "$SB/invocations.log" "$home/.ostler/lib/ostler_catchup.py"
HOME="$home" /bin/bash "$SB/ostler-scan-exports" >/dev/null 2>&1
[ ! -f "$SB/invocations.log" ] && ok "CONTROL: no core, no runner invoked" || bad "CONTROL: a runner ran with no core"

# CONTROL: a zero budget runs nothing.
: > "$home/.ostler/lib/ostler_catchup.py"
HOME="$home" OSTLER_CATCHUP_BUDGET_SECONDS=0 /bin/bash "$SB/ostler-scan-exports" >/dev/null 2>&1
[ ! -f "$SB/invocations.log" ] && ok "CONTROL: a zero budget invokes nothing" || bad "CONTROL: a zero budget still ran a runner"

# ── 2. the shipped runner generator ─────────────────────────────────────────
awk '/^_ostler_catchup_register\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}' "$INSTALL" > "$SB/register.sh"
[ -s "$SB/register.sh" ] || { echo "CANNOT-RUN: _ostler_catchup_register not found in install.sh" >&2; exit 2; }

cat > "$SB/fakepy" <<EOF
#!/bin/bash
{ printf '%s\n' "PYTHONPATH=\$PYTHONPATH" "FX_TOKEN=\${FX_TOKEN:-}"; printf 'ARG %s\n' "\$@"; } > "$SB/fakepy.out"
EOF
chmod +x "$SB/fakepy"

(
    OSTLER_DIR="$SB/stage"; OSTLER_FINAL_DIR="$SB/final"
    # shellcheck source=/dev/null
    . "$SB/register.sh"
    _ostler_catchup_register 30-messages "$SB/fakepy" "fx.mod:adapters" 0 "/opt/extra" "FX_TOKEN=a b"
    _ostler_catchup_register 40-slotted "$SB/fakepy" "fx.mod:adapters" 1 ""
)
R="$SB/stage/bin/catchup.d/30-messages.sh"
if [ -x "$R" ]; then
    HOME="$home" /bin/bash "$R" 42
    out="$(cat "$SB/fakepy.out" 2>/dev/null)"
    printf '%s\n' "$out" | grep -qx "PYTHONPATH=$SB/final/lib:/opt/extra" \
        && ok "runner puts the FINAL lib dir on PYTHONPATH, not the staging tree" || bad "PYTHONPATH wrong: $(printf '%s\n' "$out" | head -1)"
    printf '%s\n' "$out" | grep -qx "FX_TOKEN=a b" && ok "KEY=VALUE survives with a space in it" || bad "env not exported"
    want="ARG -m ARG ostler_catchup ARG run ARG --family ARG messages ARG --adapters ARG fx.mod:adapters ARG --budget-seconds ARG 42"
    got="$(printf '%s\n' "$out" | grep '^ARG' | tr '\n' ' ' | sed 's/ $//')"
    [ "$got" = "$want" ] && ok "runner invokes ostler_catchup run with the budget it was given" || bad "argv: ${got}"
else
    bad "the generator wrote no runner at $R"
fi

S="$SB/stage/bin/catchup.d/40-slotted.sh"
rm -f "$SB/fakepy.out"
mkdir -p "$SB/ws/ingest-ollama.lock.d"
msg="$(HOME="$home" OSTLER_STATE_DIR="$SB/ws" /bin/bash "$S" 42)"
if [ ! -f "$SB/fakepy.out" ] && printf '%s' "$msg" | grep -q '"slot_busy"'; then
    ok "a slotted runner yields at once while another feed holds the model slot"
else
    bad "slotted runner with the slot held: ran=$([ -f "$SB/fakepy.out" ] && echo yes || echo no) said=${msg}"
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ]
