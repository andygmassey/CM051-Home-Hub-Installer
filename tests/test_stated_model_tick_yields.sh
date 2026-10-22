#!/usr/bin/env bash
#
# tests/test_stated_model_tick_yields.sh
#
# The stated-preference model stage must never get in the way of chat or the
# brief. Runs scripts/ostler-stated-model-tick.sh for real against stub libs and
# a stub interpreter that records its argv.
#
#   A  resource-tier defer       -> exit 0, the interpreter is NOT run
#   B  ingest slot busy          -> exit 0, the interpreter is NOT run
#   C  no resolvable tier model  -> exit 0, NOT run (no guess)
#   D  no slot lib               -> exit 0, NOT run (never without the slot)
#   E  all clear                 -> run ONCE, under ostler_slot_run, with
#                                   --model <the tier model> --cap 200
#   F  an env MODEL override is ignored: the tier model is the only model
#   G  CONTROL: with the stub defer lib swapped for a clear one, the same
#      sandbox runs (so A is not "never runs for some other reason")
#
# Exit 0 pass, 1 fail, 2 cannot-run. Bash 3.2 portable.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAP="${HERE}/../scripts/ostler-stated-model-tick.sh"
[ -r "$WRAP" ] || { echo "CANNOT-RUN: $WRAP unreadable"; exit 2; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $*"; }

mk() {   # mk <name> <defer:0|1> <slot:ok|busy|none> <model:TAG|none>
    local d; d="$(mktemp -d "${TMPDIR:-/tmp}/smt.XXXXXX")"
    mkdir -p "$d/cm019/.venv/bin" "$d/lib" "$d/home"
    printf '#!/bin/sh\necho "$@" >> "%s/ran"\n' "$d" > "$d/cm019/.venv/bin/python3"
    chmod +x "$d/cm019/.venv/bin/python3"
    {
        echo 'ostler_resource_tier_detect() { :; }'
        if [ "$2" = 1 ]; then echo 'ostler_resource_tier_should_defer_nonessential() { OSTLER_DEFER_REASON=load; return 0; }'
        else echo 'ostler_resource_tier_should_defer_nonessential() { return 1; }'; fi
    } > "$d/lib/tier.sh"
    if [ "$4" != none ]; then
        printf 'ostler_detect_total_ram_gb() { echo 16; }\nostler_recommend_model() { echo "%s"; }\n' "$4" > "$d/lib/fit.sh"
    fi
    if [ "$3" != none ]; then
        {
            if [ "$3" = ok ]; then echo 'ostler_slot_acquire() { echo "$1" >> "'"$d"'/slot"; return 0; }'
            else echo 'ostler_slot_acquire() { return 1; }'; fi
            echo 'ostler_slot_run() { echo "run-under-slot" >> "'"$d"'/slot"; "$@"; }'
        } > "$d/lib/slot.sh"
    fi
    echo "$d"
}
run() {  # run <dir> [extra env...]
    local d="$1"; shift
    env -i PATH="$PATH" HOME="$d/home" OSTLER_DIR="$d/ostler" OSTLER_CM019_DIR="$d/cm019" \
        OSTLER_RESOURCE_TIER_LIB="$d/lib/tier.sh" OSTLER_MODEL_FIT_LIB="$d/lib/fit.sh" \
        OSTLER_SLOT_LIB="$d/lib/slot.sh" "$@" bash "$WRAP"
}

d="$(mk a 1 ok tier-model:16g)"; run "$d"; rc=$?
{ [ "$rc" = 0 ] && [ ! -e "$d/ran" ]; } && ok "A tier defer: exit 0, interpreter not run" || bad "A tier defer ran the model (rc=$rc)"

d="$(mk b 0 busy tier-model:16g)"; run "$d"; rc=$?
{ [ "$rc" = 0 ] && [ ! -e "$d/ran" ]; } && ok "B slot busy: yields, interpreter not run" || bad "B slot busy ran the model (rc=$rc)"

d="$(mk c 0 ok none)"; run "$d"; rc=$?
{ [ "$rc" = 0 ] && [ ! -e "$d/ran" ]; } && ok "C no tier model: not run" || bad "C ran without a model (rc=$rc)"

d="$(mk d 0 none tier-model:16g)"; run "$d"; rc=$?
{ [ "$rc" = 0 ] && [ ! -e "$d/ran" ]; } && ok "D no slot lib: not run" || bad "D ran without the slot (rc=$rc)"

d="$(mk e 0 ok tier-model:16g)"; run "$d"; rc=$?
if [ "$rc" = 0 ] && [ "$(wc -l < "$d/ran" 2>/dev/null | tr -d ' ')" = 1 ] \
   && grep -q -- "-m services.enrich.src.derive.stated_model --model tier-model:16g --cap 200" "$d/ran" \
   && grep -q "stated-model" "$d/slot" && grep -q "run-under-slot" "$d/slot"; then
    ok "E all clear: ran once under the slot with the tier model and cap 200"
else bad "E all-clear run is wrong: $(cat "$d/ran" 2>/dev/null) / $(cat "$d/slot" 2>/dev/null)"; fi

d="$(mk f 0 ok tier-model:16g)"; run "$d" OSTLER_MODEL=huge-model:70b OSTLER_STATED_MODEL=huge-model:70b >/dev/null
grep -q "huge-model" "$d/ran" 2>/dev/null && bad "F an env override reached the model flag" || ok "F no env override: only the tier model is used"

d="$(mk g 1 ok tier-model:16g)"; printf 'ostler_resource_tier_should_defer_nonessential() { return 1; }\nostler_resource_tier_detect() { :; }\n' > "$d/lib/tier.sh"; run "$d"
[ -e "$d/ran" ] && ok "G control: with the defer lib cleared the same sandbox runs" || bad "G control did not run, so A proves nothing"

echo "== $PASS pass / $FAIL fail =="
[ "$FAIL" = 0 ]
