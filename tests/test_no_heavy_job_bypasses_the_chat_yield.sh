#!/bin/bash
# test_no_heavy_job_bypasses_the_chat_yield.sh -- v1.0.108.
#
# Archie's ask on #2941: a test that EVERY heavy background job is prevented
# from starving live chat, so a future job added without the plumbing is caught
# HERE instead of on a customer's box.
#
# Two classes of heavy job, two mechanisms, and this test enforces the right
# one for each -- enumerated from the tree so a NEW job cannot quietly join
# without a row. See launch/DESIGN_first_run_resource_governor_v1.0.3.md
# section 9 for the coverage table this mirrors.
#
#   A. Ollama-INGEST ticks (the 4 conversation feeds + the wiki recompile).
#      They contend for the ONE shared Ollama ingest slot, so they MUST funnel
#      through ostler_slot_run, which gives them BOTH the interactive-chat
#      yield (the interactive-chat.active marker) AND, since v1.0.108,
#      background CPU QoS. A tick that bypasses it drives Ollama unthrottled and
#      at full CPU priority -- the starvation this file exists to prevent.
#
#   B. Whole-job background LaunchAgents (fda-rerun, enrich). They are NOT
#      Ollama-ingest-slot contenders -- fda-rerun's LLM use is inside the daemon
#      (governed by ollama_gate), enrich does outbound third-party lookups -- so
#      forcing them through the ingest slot would be wrong. They are
#      backgrounded at the launchd level with ProcessType=Background, the
#      correct lever for a job that is background end to end.
#
# The point is COMPLETENESS: no heavy job is left at full user priority. A
# negative control proves the class-A check discriminates.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
INSTALL="install.sh"
[ -f "$INSTALL" ] || { echo "CANNOT-RUN: no $INSTALL"; exit 2; }

PASS=0; FAIL=0
ok() { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
no() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        | /'; FAIL=$((FAIL+1)); }

echo "test_no_heavy_job_bypasses_the_chat_yield (v1.0.108)"
echo

# ---------------------------------------------------------------------
# Class A: every Ollama-ingest tick funnels through ostler_slot_run.
# Enumerated from the tree, not a hand list, so a new feed is seen.
# ---------------------------------------------------------------------
echo "== Class A: Ollama-ingest ticks funnel through ostler_slot_run =="
INGEST_TICKS=()
for f in vendor/*_source/bin/*-bundle-tick.sh wiki-recompile/bin/wiki-recompile-tick.sh; do
    [ -f "$f" ] && INGEST_TICKS+=("$f")
done

# Denominator floor: a glob that silently matched nothing would make every
# per-file loop below vacuously green. The four conversation feeds + the wiki
# recompile are the known minimum on this tree.
if [ "${#INGEST_TICKS[@]}" -ge 5 ]; then
    ok "enumerated ${#INGEST_TICKS[@]} Ollama-ingest tick wrapper(s) (>= the 5 known)"
else
    no "found only ${#INGEST_TICKS[@]} ingest tick wrappers; the enumeration regressed, so a green below would be vacuous"
fi

for f in "${INGEST_TICKS[@]}"; do
    if grep -q 'ostler_slot_run' "$f"; then
        ok "funnels through ostler_slot_run: $f"
    else
        no "BYPASSES the slot (no ostler_slot_run): $f" \
           "this tick drives Ollama at full CPU priority and never yields to live chat"
    fi
done

# NEGATIVE CONTROL: a copy with the funnel stripped must read as a bypass, or
# the per-file check above proves nothing. File-based grep, never a pipe into
# grep -q (the pipefail ratchet).
CTRL="$(mktemp)"; trap 'rm -f "$CTRL"' EXIT
grep -v 'ostler_slot_run' "${INGEST_TICKS[0]}" > "$CTRL"
if grep -q 'ostler_slot_run' "$CTRL"; then
    no "NEGATIVE CONTROL mis-built: the stripped copy still contains ostler_slot_run"
else
    ok "NEGATIVE CONTROL: a tick with the funnel stripped reads as a bypass (the check discriminates)"
fi

# ---------------------------------------------------------------------
# Class B: the whole-job background LaunchAgents carry ProcessType Background,
# so they are not left at full user priority either.
# ---------------------------------------------------------------------
echo
echo "== Class B: whole-job background agents run at ProcessType Background =="

fda_block="$(awk '/<string>com.ostler.fda-rerun<\/string>/{f=1} f{print} /^FDARPEOF$/{f=0}' "$INSTALL")"
if grep -q '<string>Background</string>' <<<"$fda_block"; then
    ok "fda-rerun: ProcessType Background"
else
    no "fda-rerun runs at full user QoS (no ProcessType Background in its plist)"
fi

enrich_block="$(awk '/local label="com.ostler.enrich"/{f=1} f{print} /^ENRPLIST$/{f=0}' "$INSTALL")"
if grep -q '<string>Background</string>' <<<"$enrich_block"; then
    ok "enrich: ProcessType Background"
else
    no "enrich runs at full user QoS (no ProcessType Background in its plist)"
fi

# ---------------------------------------------------------------------
# Class C (v1.0.124): the jobs that ANSWER the Hub screens are never
# backgrounded, and the in-VM compile yields to the serving containers.
# The v1.0.123 walk: under first-run ingest (load 8 to 19) the wiki missed
# 45 s and Timeline/People missed 30 s, all fine at idle. The daemon (gateway
# :8443: pages, fonts, /wiki/s/, people/timeline proxies) shipped as
# ProcessType Background; ical-server (people/timeline) had none (Standard).
# ---------------------------------------------------------------------
echo
echo "== Class C: the Hub-serving jobs run Interactive; the compile yields =="
DAEMON_PLIST="assistant-agent/launchd/com.creativemachines.ostler.assistant.plist"
plist_pt() { sed -n '/<key>ProcessType<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}'; }
ical_block() { awk '/^ICALPLISTEOF$/{f=0} f{print} /<<ICALPLISTEOF$/{f=1}' "$1"; }
compiler_weight() { awk '/^  wiki-compiler:$/{f=1;next} f&&/^  [a-z-]+:$/{f=0} f&&/^    cpu_shares:/{print $2}' "$1"; }
judge_c() {  # $1 daemon plist, $2 install.sh; prints FAIL lines, rc 1 on any
    local bad=0 d i w
    d="$(plist_pt < "$1")"; i="$(ical_block "$2" | plist_pt)"; w="$(compiler_weight "$2")"
    [ "$d" = Interactive ] || { echo "daemon ProcessType='${d}'"; bad=1; }
    [ "$i" = Interactive ] || { echo "ical-server ProcessType='${i}'"; bad=1; }
    { [ -n "$w" ] && [ "$w" -lt 1024 ]; } 2>/dev/null || { echo "wiki-compiler cpu_shares='${w}'"; bad=1; }
    return $bad
}
if [ -f "$DAEMON_PLIST" ] && out="$(judge_c "$DAEMON_PLIST" "$INSTALL")"; then
    ok "daemon + ical-server ProcessType Interactive; wiki-compiler cpu_shares $(compiler_weight "$INSTALL") < 1024"
else
    no "a Hub-serving job is backgrounded or the compile is at full weight" "${out:-no daemon plist at $DAEMON_PLIST}"
fi
# NEGATIVE CONTROLS: each of the three shipped shapes, re-introduced on a copy,
# must read as a failure, or the green above proves nothing.
_t="$(mktemp -d)"; trap 'rm -rf "$_t"' EXIT
sed 's#<string>Interactive</string>#<string>Background</string>#' "$DAEMON_PLIST" > "$_t/d.plist"
judge_c "$_t/d.plist" "$INSTALL" >/dev/null && no "CONTROL: a Background daemon plist read as Interactive" || ok "NEGATIVE CONTROL: the v1.0.123 Background daemon plist reads as a failure"
awk '/^ICALPLISTEOF$/{f=0} f&&/<key>ProcessType<\/key>/{getline; next} {print} /<<ICALPLISTEOF$/{f=1}' "$INSTALL" > "$_t/i.sh"
judge_c "$DAEMON_PLIST" "$_t/i.sh" >/dev/null && no "CONTROL: an ical-server plist with no ProcessType read as Interactive" || ok "NEGATIVE CONTROL: an ical-server plist with no ProcessType reads as a failure"
grep -v '^    cpu_shares: 256$' "$INSTALL" > "$_t/w.sh"
judge_c "$DAEMON_PLIST" "$_t/w.sh" >/dev/null && no "CONTROL: a full-weight wiki-compiler read as yielding" || ok "NEGATIVE CONTROL: a wiki-compiler with no cpu_shares reads as a failure"

echo
echo "-------------------------------------------------------------"
printf 'heavy-job coverage: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
