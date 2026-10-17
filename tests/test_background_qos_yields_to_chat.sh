#!/bin/bash
# test_background_qos_yields_to_chat.sh -- v1.0.108 first-run chat-settling fix.
#
# WHAT THIS EXISTS TO PROVE, MEASURED ON ANDY'S BOX 2026-10-16.
#
# During first-run settling the heavy background jobs (the conversation-feed
# Pythons + their pwg-convo subprocess, the wiki summary backfill, enrichment,
# fda-rerun) plus Spotlight drove the 1-minute load to 13 and starved live
# chat: the iOS app showed "Hub offline" and chat hung, even though chat
# answers instantly once the box is calm. The fix lowers the OS scheduling
# priority of OUR heavy jobs so interactive chat -- served by the separate
# `ollama serve` process and the daemon at the default user tier -- outranks
# them on CPU while settling, WITHOUT stopping the enrichment.
#
# The lever is `taskpolicy -b` (background QoS) on the payload launched by
# ostler_slot_run (the one chokepoint the four feeds AND the wiki backfill
# funnel through), with `nice` as the portable fallback and a disable switch.
#
# Every predicate below is proved against a MUTATED input (OSTLER_BG_QOS=0, a
# taskpolicy that is absent) so the positive result cannot be a tautology, and
# the behavioural case runs the payload THROUGH a fake taskpolicy so a green
# means the payload was genuinely launched under the prefix -- not merely that
# the string appears in the file.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

LIB="lib/ostler-ingest-slot.sh"
INSTALL="install.sh"
[ -f "$LIB" ]     || { echo "CANNOT-RUN: $LIB missing";     exit 2; }
[ -f "$INSTALL" ] || { echo "CANNOT-RUN: $INSTALL missing"; exit 2; }

PASS=0; FAIL=0
ok() { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
no() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        | /'; FAIL=$((FAIL+1)); }

echo "test_background_qos_yields_to_chat (v1.0.108)"
echo

# ---------------------------------------------------------------------
# Section 1: _ostler_slot_bg_prefix resolves the right launcher, and the
# negative controls prove each branch is distinguishable.
# ---------------------------------------------------------------------
echo "== Section 1: the background-QoS prefix resolver =="
WS="$(mktemp -d)"; trap 'rm -rf "$WS"' EXIT

# A fake taskpolicy that is executable (its contents do not matter here).
cat > "$WS/taskpolicy" <<'FAKE'
#!/bin/sh
printf 'INVOKED %s\n' "$*" >> "$TP_MARKER"
shift   # drop the -b
exec "$@"
FAKE
chmod +x "$WS/taskpolicy"

# shellcheck source=/dev/null
. "$LIB"

if ! command -v _ostler_slot_bg_prefix >/dev/null 2>&1; then
    no "the lib does not define _ostler_slot_bg_prefix at all" \
       "ostler_slot_run has no way to launch the payload at background QoS."
else
    ok "the lib defines _ostler_slot_bg_prefix"

    got="$(OSTLER_TASKPOLICY_BIN="$WS/taskpolicy" _ostler_slot_bg_prefix)"
    if [ "$got" = "$WS/taskpolicy -b" ]; then
        ok "taskpolicy present -> prints '<taskpolicy> -b'"
    else
        no "taskpolicy present should print '<taskpolicy> -b'" "got: '${got}'"
    fi

    # NEGATIVE CONTROL: the disable switch must blank the prefix, or the
    # positive case above proves nothing (it would be on no matter what).
    got="$(OSTLER_TASKPOLICY_BIN="$WS/taskpolicy" OSTLER_BG_QOS=0 _ostler_slot_bg_prefix)"
    if [ -z "$got" ]; then
        ok "NEGATIVE CONTROL: OSTLER_BG_QOS=0 -> empty prefix"
    else
        no "OSTLER_BG_QOS=0 must blank the prefix" "got: '${got}'"
    fi

    # Fallback: no taskpolicy on this host -> nice, the portable launcher.
    got="$(OSTLER_TASKPOLICY_BIN="$WS/does-not-exist" _ostler_slot_bg_prefix)"
    if [ "$got" = "nice -n 10" ]; then
        ok "taskpolicy absent -> falls back to 'nice -n 10'"
    else
        no "with no taskpolicy the prefix should fall back to nice" "got: '${got}'"
    fi
fi

# ---------------------------------------------------------------------
# Section 2: ostler_slot_run LAUNCHES the payload through the prefix.
# This is the one that fails on the old code: before this fix
# ostler_slot_run ran "$@" directly and never consulted any prefix, so the
# fake taskpolicy is never invoked.
# ---------------------------------------------------------------------
echo
echo "== Section 2: ostler_slot_run launches its payload at background QoS =="

run_payload() {
    # $1 = extra env assignment (e.g. OSTLER_BG_QOS=0, or empty).
    local extra="$1" run_ws
    run_ws="$(mktemp -d)"
    cat > "$run_ws/probe.sh" <<PROBE
set -u
export OSTLER_STATE_DIR="$run_ws"
export TP_MARKER="$run_ws/tp.marker"
export OSTLER_TASKPOLICY_BIN="$WS/taskpolicy"
$extra
. "$PWD/$LIB"
ostler_slot_acquire "qos-test" >/dev/null 2>&1 || { echo "ACQUIRE_FAILED"; exit 9; }
ostler_slot_run /bin/sh -c 'echo PAYLOAD_RAN > "\$OSTLER_STATE_DIR/payload.out"'
PROBE
    bash "$run_ws/probe.sh" >/dev/null 2>&1
    # Emit: did the payload run, and was the fake taskpolicy invoked?
    local ran=no inv=no
    [ -f "$run_ws/payload.out" ] && grep -q PAYLOAD_RAN "$run_ws/payload.out" && ran=yes
    [ -f "$run_ws/tp.marker" ] && grep -q INVOKED "$run_ws/tp.marker" && inv=yes
    printf '%s %s\n' "$ran" "$inv"
    rm -rf "$run_ws"
}

read -r ran inv <<<"$(run_payload '')"
if [ "$ran" = "yes" ] && [ "$inv" = "yes" ]; then
    ok "payload ran AND was launched through taskpolicy -b (ran=$ran invoked=$inv)"
else
    no "ostler_slot_run must launch its payload through the background-QoS prefix" \
       "payload ran=$ran, taskpolicy invoked=$inv (old code: invoked=no)"
fi

# NEGATIVE CONTROL: disabled -> payload still runs, but NOT under taskpolicy.
read -r ran inv <<<"$(run_payload 'export OSTLER_BG_QOS=0')"
if [ "$ran" = "yes" ] && [ "$inv" = "no" ]; then
    ok "NEGATIVE CONTROL: OSTLER_BG_QOS=0 -> payload runs, taskpolicy NOT invoked (ran=$ran invoked=$inv)"
else
    no "with OSTLER_BG_QOS=0 the payload must still run but not under taskpolicy" \
       "payload ran=$ran, taskpolicy invoked=$inv"
fi

# ---------------------------------------------------------------------
# Section 3: the lib install.sh ships carries the prefix (delivery), and
# fda-rerun -- the one wholly-background LaunchAgent that lacked it -- now
# runs at background QoS, with an upgrade trigger so existing boxes get it.
# ---------------------------------------------------------------------
echo
echo "== Section 3: install.sh delivers the fix to the box =="

grep -q '_ostler_slot_bg_prefix' "$INSTALL" \
    && ok "install.sh embeds the background-QoS resolver in the slot lib" \
    || no "install.sh does not carry _ostler_slot_bg_prefix; the sealed ticks would run at full priority"

# fda-rerun: ProcessType=Background in its plist heredoc.
fda_block="$(awk '/<string>com.ostler.fda-rerun<\/string>/{f=1} f{print} /^FDARPEOF$/{f=0}' "$INSTALL")"
if printf '%s' "$fda_block" | grep -q '<string>Background</string>'; then
    ok "fda-rerun plist carries ProcessType Background"
else
    no "fda-rerun plist has no ProcessType Background; its 5-year-window ingest runs at full priority"
fi

# The upgrade trigger: an existing un-backgrounded plist is rewritten, AND
# the rewrite boots the old job out (or the box keeps running the old one).
grep -q 'FDA_RERUN_WAS_UNBACKGROUNDED=1' "$INSTALL" \
    && ok "install.sh rewrites an existing fda-rerun plist that lacks the key" \
    || no "no upgrade trigger: every box that already has the plist stays unthrottled forever (#768/#769 shape)"
grep -q 'FDA_RERUN_WAS_UNBACKGROUNDED" == "1"' "$INSTALL" \
    && ok "the rewrite boots the old fda-rerun job out so the new QoS takes effect" \
    || no "the un-backgrounded rewrite never boots the old job out; the fix is on disk, not in force"

# Regression guard: enrichment was ALREADY backgrounded; do not lose it.
grep -q 'com.ostler.enrich' "$INSTALL" && \
awk '/local label="com.ostler.enrich"/{f=1} f{print} /^ENRPLIST$/{f=0}' "$INSTALL" | grep -q '<string>Background</string>' \
    && ok "enrichment plist still carries ProcessType Background (regression guard)" \
    || no "enrichment lost its ProcessType Background"

echo
echo "-------------------------------------------------------------"
printf 'background-qos: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
