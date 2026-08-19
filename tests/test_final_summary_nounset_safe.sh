#!/usr/bin/env bash
#
# tests/test_final_summary_nounset_safe.sh
#
# CX-123 / #643: the display-only final-summary / success block must NEVER
# abort the install under `set -u` because an OPTIONAL variable is unset on
# some path. A `set -u` abort exits the script with no `gui_done ok`, so the
# GUI infers a failure on a fully-successful install (the false-fail that
# cost cut after cut: CONTACT_COUNT, EXPORTS_DIR, FV_ENABLED, channel flags,
# WIKI_FIRST_COMPILE_OK, IMESSAGE_TCC_STATUS, VANE_OK, HAS_BATTERY, ...).
#
# This test extracts the REAL wrapped block from install.sh and runs it
# under `set -Eeuo pipefail` across a matrix of optional-vars-unset
# scenarios (fresh vs reuse, channels on/off, battery/no-battery,
# FDA/no-FDA, wiki-ok/not, vane-ok/not, contacts/exports present/absent),
# asserting it always reaches `gui_done ok`. A RED control runs the same
# recap WITHOUT the set +u wrap to prove the test detects the abort.
#
# Synthetic only. Pure bash.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${SCRIPT_DIR}/../install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[[ -f "$INSTALL_SH" ]] || { echo "FAIL: install.sh not found" >&2; exit 1; }
bash -n "$INSTALL_SH" || { echo "FAIL: install.sh fails bash -n" >&2; exit 1; }
echo "PASS: install.sh parses"

# Extract the wrapped block: from `_cx123_nounset_was_on=0` through the
# matching `... && set -u` restore line (inclusive).
BLOCK="$(awk '
    /_cx123_nounset_was_on=0/ { on=1 }
    on { print }
    on && /_cx123_nounset_was_on:-0.* && set -u/ { exit }
' "$INSTALL_SH")"
printf '%s\n' "$BLOCK" | grep -q 'set +u' \
    || { echo "FAIL: could not extract the set +u wrapped final-summary block" >&2; exit 1; }
printf '%s\n' "$BLOCK" | grep -q '^gui_done ok' \
    || { echo "FAIL: extracted block does not contain gui_done ok" >&2; exit 1; }
echo "PASS: extracted the real wrapped final-summary block"

# MSG_* vars the block references -> define them as harmless strings.
MSGDEFS="$(printf '%s\n' "$BLOCK" | grep -oE 'MSG_[A-Z0-9_]+' | sort -u | sed 's/$/="x"/')"

LEDGER="$WORK/ledger"

# Build a harness. PRELUDE sets the shell posture + helper stubs + colour
# vars + MSG vars + INSTALL_START (a real value), then the caller appends a
# scenario's variable assignments, then the extracted block, then a marker.
write_harness() {
    local out="$1" scenario_vars="$2" strip_wrap="${3:-0}"
    {
        echo 'set -Eeuo pipefail'
        # ERR trap is irrelevant here (errexit not the failure mode); the
        # failure mode is the set -u unbound-variable abort, which exits
        # before the REACHED marker / gui_done ok.
        echo 'GREEN=""; YELLOW=""; RED=""; NC=""; BOLD=""'
        echo "gui_done(){ printf 'DONE:%s\\n' \"\$1\" >> \"$LEDGER\"; }"
        echo 'gui_log(){ :; }; info(){ :; }; warn(){ :; }; ok(){ :; }; error(){ :; }'
        echo 'INSTALL_START=0'
        printf '%s\n' "$MSGDEFS"
        printf '%s\n' "$scenario_vars"
        if [[ "$strip_wrap" == 1 ]]; then
            # RED control: drop the set +u / set -u lines so the recap runs
            # under the inherited set -u.
            printf '%s\n' "$BLOCK" | grep -vE '^set \+u$|_cx123_nounset_was_on'
        else
            printf '%s\n' "$BLOCK"
        fi
        echo "printf 'REACHED_END\\n'"
    } > "$out"
}

run_scenario() {
    local name="$1" vars="$2"
    : > "$LEDGER"
    write_harness "$WORK/h.sh" "$vars" 0
    local out
    out="$(bash "$WORK/h.sh" 2>&1 || true)"
    if ! grep -q '^DONE:ok' "$LEDGER" 2>/dev/null; then
        echo "FAIL[$name]: block did not reach gui_done ok (set -u abort on an unset optional)" >&2
        echo "--- output ---"; echo "$out" >&2
        exit 1
    fi
    echo "PASS[$name]: reached gui_done ok"
}

# Core vars that are ALWAYS set by the time the summary runs (they would be
# set on any path; we provide them so the test exercises the OPTIONAL gap,
# not a core-var gap). Everything NOT listed here is deliberately left UNSET.
CORE='USER_NAME=Alex; USER_ID=alex-1; ASSISTANT_NAME=Ostler; USER_TZ=UTC;
COUNTRY_CODE=44; AI_MODEL=qwen3.5:9b; HEALTHY=true; OSTLER_DIR=/tmp/o;
CONFIG_DIR=/tmp/o/config; DATA_DIR=/tmp/o/data; LOGS_DIR=/tmp/o/logs;
SECURITY_CONFIG_DIR=/tmp/o/sec'

# ── Scenario matrix (each leaves the unmentioned optionals UNSET) ──────
run_scenario "all-optionals-unset (worst case: fresh, nothing set)" "$CORE"
run_scenario "reuse-typical (everything populated)" "$CORE
CONTACT_COUNT=2395; EXPORTS_DIR=/tmp/o/imports; FV_ENABLED=true;
WIKI_FIRST_COMPILE_OK=true; CHANNEL_IMESSAGE_ENABLED=true;
CHANNEL_EMAIL_ENABLED=true; CHANNEL_WHATSAPP_ENABLED=true;
CHANNEL_IMESSAGE_ALLOWED='+1...'; CHANNEL_EMAIL_USERNAME=alex@example.com;
IMESSAGE_TCC_STATUS=granted-and-working; VANE_OK=true; HAS_BATTERY=true"
run_scenario "channels-all-off" "$CORE
CHANNEL_IMESSAGE_ENABLED=false; CHANNEL_EMAIL_ENABLED=false; CHANNEL_WHATSAPP_ENABLED=false"
run_scenario "imessage-only + tcc-denied" "$CORE
CHANNEL_IMESSAGE_ENABLED=true; IMESSAGE_TCC_STATUS=tcc-denied"
run_scenario "no-battery + vane-down + wiki-not-compiled" "$CORE
HAS_BATTERY=false; VANE_OK=false; WIKI_FIRST_COMPILE_OK=false"
run_scenario "fda-zero + contacts-unset + exports-unset" "$CORE
FDA_OK=0"
run_scenario "partial-health (HEALTHY=false branch)" "USER_NAME=Alex; USER_ID=alex-1;
ASSISTANT_NAME=Ostler; USER_TZ=UTC; COUNTRY_CODE=44; AI_MODEL=qwen3.5:9b;
HEALTHY=false; OSTLER_DIR=/tmp/o; CONFIG_DIR=/c; DATA_DIR=/d; LOGS_DIR=/l;
SECURITY_CONFIG_DIR=/s"

# ── RED control: the SAME recap without the wrap MUST abort ────────────
: > "$LEDGER"
write_harness "$WORK/red.sh" "$CORE" 1
red_out="$(bash "$WORK/red.sh" 2>&1 || true)"
if grep -q '^DONE:ok' "$LEDGER" 2>/dev/null; then
    echo "FAIL[red-control]: recap WITHOUT the set +u wrap still reached gui_done ok -- the test cannot prove the wrap is load-bearing on this host" >&2
    exit 1
fi
if ! grep -qiE 'unbound variable' <<<"$red_out"; then
    echo "NOTE[red-control]: did not see the literal 'unbound variable' message, but the block did not reach gui_done ok (still a fail, as required)"
fi
echo "PASS[red-control]: without the wrap the recap aborts before gui_done ok (proves the wrap is the fix)"

echo ""
echo "ALL PASS: test_final_summary_nounset_safe.sh"
