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

echo
echo "-------------------------------------------------------------"
printf 'heavy-job coverage: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
