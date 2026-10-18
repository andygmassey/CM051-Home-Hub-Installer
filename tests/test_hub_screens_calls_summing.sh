#!/usr/bin/env bash
# test_hub_screens_calls_summing.sh (#2603 follow-up, Archie review)
#
# scripts/box_walk_probes/probes/hub_screens_customer_read.sh:62-67 compares
# the Bursar's recorded journal activity against Ollama's own logged call
# count in a 60-minute window. Before this fix it summed `j+=1` per
# JOURNAL LINE; a rolled-up row (RollingUsageRecorder, #2472) folds many
# real Ollama calls into one line, so that comparison silently undercounted
# by the rollup factor -- the Bursar would look like it was missing most of
# Ollama's real activity when every token was actually accounted for.
#
# This test extracts the EXACT embedded Python snippet from the probe
# script (never a hand-copied duplicate, which could drift from the real
# one silently) and runs it against a synthetic HOME with a synthetic
# ollama.log and costs.jsonl, proving:
#
#   1. a rolled-up row with "calls":5 is summed as 5, not counted as 1
#   2. a MUTANT that reverts to counting lines (the pre-fix behaviour)
#      gives a DIFFERENT, WRONG answer on the same fixture -- proving the
#      fix is real and a regression back to row-counting is distinguishable
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="${REPO_ROOT}/scripts/box_walk_probes/probes/hub_screens_customer_read.sh"

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; fail=$((fail+1)); }

[ -f "${PROBE}" ] || { echo "CANNOT-RUN: ${PROBE} absent"; exit 2; }

echo "== hub_screens_customer_read: sums usage.calls, not journal lines =="

# --- extract the real embedded snippet, verbatim -------------------------
SNIPPET="$(sed -n '/python3 - <<.PY./,/^PY" >/p' "${PROBE}" | sed '1d;$d')"
[ -n "${SNIPPET}" ] || { echo "CANNOT-RUN: could not extract the embedded python snippet"; exit 2; }

if grep -q "u.get('calls'" <<<"${SNIPPET}"; then
    ok "CONTROL live: the extracted snippet is the fixed, calls-summing version"
else
    echo "  CANNOT-RUN: the extracted snippet does not match the expected shape -- extraction is unreliable"
    exit 2
fi

# --- build a synthetic HOME with a 5-call window --------------------------
TMPHOME="$(mktemp -d)"
trap 'rm -rf "${TMPHOME}"' EXIT
mkdir -p "${TMPHOME}/.ostler/logs" "${TMPHOME}/.ostler/assistant-config/workspace/state"

# Ollama's own log is LOCAL time (the script applies the local UTC offset
# when parsing it), unlike costs.jsonl's timestamps which are UTC.
NOW_LINE_TIME="$(date +%Y/%m/%d' - '%H:%M:%S)"
for i in 1 2 3 4 5; do
    echo "[GIN] ${NOW_LINE_TIME} |  200 |   1ms |       127.0.0.1 | POST     \"/api/embed\"" \
        >> "${TMPHOME}/.ostler/logs/ollama.log"
done

NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "${TMPHOME}/.ostler/assistant-config/workspace/state/costs.jsonl" <<JSONL
{"id":"t1","session_id":"cm019-ingest-test","usage":{"model":"nomic-embed-text","input_tokens":100,"output_tokens":0,"total_tokens":100,"cost_usd":0.0,"timestamp":"${NOW_ISO}","purpose":"ingesting","calls":5}}
JSONL

# --- run the REAL (extracted) snippet -------------------------------------
real_out="$(HOME="${TMPHOME}" /usr/bin/python3 - <<PYEOF
${SNIPPET}
PYEOF
)"
echo "  real snippet output: ${real_out}"

real_calls="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['journal_calls'])" "${real_out}" 2>/dev/null)"
ollama_calls="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['ollama_calls'])" "${real_out}" 2>/dev/null)"

[ "${real_calls}" = "5" ] && ok "a rolled-up row with calls:5 is summed as 5, not counted as 1 row" \
                           || bad "expected journal_calls=5, got '${real_calls}' (raw: ${real_out})"
[ "${ollama_calls}" = "5" ] && ok "CONTROL: the synthetic ollama.log fixture itself reports 5 calls" \
                             || bad "CONTROL FAILED: expected ollama_calls=5, got '${ollama_calls}' -- the fixture itself is broken"

# --- MUTANT: revert to counting lines (the pre-fix bug) -------------------
MUTANT_SNIPPET="$(sed "s/j+=int(u.get('calls',1) or 1)/j+=1  # MUTANT: counts the row, not its calls/" <<<"${SNIPPET}")"
mutant_out="$(HOME="${TMPHOME}" /usr/bin/python3 - <<PYEOF
${MUTANT_SNIPPET}
PYEOF
)"
mutant_calls="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['journal_calls'])" "${mutant_out}" 2>/dev/null)"

if [ "${mutant_calls}" = "1" ]; then
    ok "MUTANT (row-counting) gives a DIFFERENT, wrong answer (1) on the same fixture -- the fix is real"
else
    bad "mutant produced ${mutant_calls}, expected 1 -- the mutant did not apply, so this proves nothing"
fi

# The actual walk-probe comparison, applied to both: must distinguish a
# real fix (passes the 95% bar) from the mutant (fails it).
python3 -c "
real = ${real_calls:-0}
mutant = ${mutant_calls:-0}
oc = ${ollama_calls:-0}
assert oc > 0, 'control fixture broken'
fixed_pass = (real or 0) >= 0.95 * oc
mutant_pass = (mutant or 0) >= 0.95 * oc
print('FIXED_PASSES_THE_95PCT_BAR' if fixed_pass else 'FIXED_FAILS_BAR_unexpected')
print('MUTANT_FAILS_THE_95PCT_BAR' if not mutant_pass else 'MUTANT_PASSES_BAR_unexpected')
" > /tmp/hub_screens_calls_check.$$ 2>&1 || true
bar_out="$(cat /tmp/hub_screens_calls_check.$$ 2>/dev/null)"; rm -f /tmp/hub_screens_calls_check.$$

grep -q 'FIXED_PASSES_THE_95PCT_BAR' <<<"${bar_out}" && ok "the real (fixed) count passes the walk's 95% bar" \
                                                        || bad "the fixed count did NOT pass the 95% bar: ${bar_out}"
grep -q 'MUTANT_FAILS_THE_95PCT_BAR' <<<"${bar_out}" && ok "the row-counting MUTANT fails the 95% bar -- a regression back to counting rows is caught" \
                                                       || bad "the mutant did not fail the bar -- it would NOT be caught: ${bar_out}"

echo
echo "  passed ${pass}, failed ${fail}"
[ "${fail}" -eq 0 ] || exit 1
exit 0
