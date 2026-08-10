#!/usr/bin/env bash
# tests/test_enrich_budget.sh -- addresses v1018-D031.
#
# The enrichment step was never STUCK. Every LLM call in it was already
# individually bounded at 900s, which is exactly why no per-call timeout
# could have fixed this. The step simply has an enormous BOUNDED worst
# case:
#
#   3-4 chunks x 900s + merge 900s + validation retry 900s   ~= 1h15m
#   x MAX_RETRIES (3) + backoff                              ~= 4h30m
#
# Four and a half hours, by design, for one email. On the shipped box a
# 236KB newsletter thread (2.8x the next largest document on disk) sat in
# this step holding the shared ingest lock, and all four conversation
# feeds stopped behind it.
#
# So the ceiling belongs on the STEP. Each model call is handed whatever
# remains of the document's allowance, so the total cannot exceed it
# however the transcript happens to chunk.
#
# The fourth assertion below is the one that matters most: `_is_retryable`
# ends in `return True`, so every unrecognised exception is retried.
# A budget that is retryable is not a budget -- MAX_RETRIES would multiply
# the ceiling by three, which is the arithmetic that created this defect.
#
# EXIT: 0 all assertions hold. 1 one or more failed.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PYTHON_BIN:-python3}"
SRC="$REPO/vendor/cm048_pipeline/src/processor.py"

pass=0
fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

echo "v1018-D031: the enrichment step has a total wall-clock allowance"
echo ""
echo "structure"

if [ ! -f "$SRC" ]; then
	bad "vendor/cm048_pipeline/src/processor.py missing"
	printf '\033[0;31mRED\033[0m\n'; exit 1
fi

# No model call may carry a bare per-call constant: every one takes what
# is left of the document's allowance instead.
if grep -qE "timeout=900\.0," "$SRC"; then
	bad "a model call still uses a fixed per-call timeout, so the step total is unbounded"
else
	ok "no model call carries a fixed per-call timeout"
fi

sites="$(grep -c "timeout=_budget_timeout()" "$SRC" || true)"
if [ "${sites:-0}" -eq 4 ]; then
	ok "all 4 model calls draw on the document allowance"
else
	bad "expected 4 budget-bounded model calls, found ${sites:-0} -- an unbounded one defeats the total"
fi

# Armed on entry, released on exit: a later step must not inherit a spent
# budget, and a _run_step retry must start from a full one.
if "$PY" - "$SRC" <<'PYEOF'
import ast, sys
fns = {n.name: n for n in ast.parse(open(sys.argv[1]).read()).body
       if isinstance(n, ast.FunctionDef)}
f = fns.get("_step_enrich")
sys.exit(0 if f and any(isinstance(n, ast.Global) for n in ast.walk(f))
              and any(isinstance(n, ast.Try) for n in ast.walk(f)) else 1)
PYEOF
then
	ok "the allowance is armed on entry and released in a finally"
else
	bad "allowance not armed/released around the step -- it would leak or stay unset"
fi

# THE ONE THAT MATTERS: _is_retryable ends in `return True`.
if "$PY" - "$SRC" <<'PYEOF'
import ast, sys

# Parsed, not grepped. The first cut of this check tested
# `"return True" in <text before the guard>` and failed on the WORD
# "return True" inside the explanatory comment directly above the guard --
# a false RED produced by the test's own prose. Structure is the only
# reliable way to ask "does any catch-all precede this branch".
fns = {n.name: n for n in ast.parse(open(sys.argv[1]).read()).body
       if isinstance(n, ast.FunctionDef)}
f = fns.get("_is_retryable")
if f is None:
    sys.exit(1)

guard_at = None
for i, stmt in enumerate(f.body):
    if (isinstance(stmt, ast.If)
            and any(isinstance(n, ast.Name) and n.id == "EnrichmentBudgetExceeded"
                    for n in ast.walk(stmt.test))
            and any(isinstance(n, ast.Return)
                    and isinstance(n.value, ast.Constant) and n.value.value is False
                    for n in stmt.body)):
        guard_at = i
        break
if guard_at is None:
    sys.exit(1)

# No unconditional `return True` may sit above it.
for stmt in f.body[:guard_at]:
    if (isinstance(stmt, ast.Return) and isinstance(stmt.value, ast.Constant)
            and stmt.value.value is True):
        sys.exit(1)
sys.exit(0)
PYEOF
then
	ok "budget exhaustion is NOT retryable, and the guard precedes the catch-alls"
else
	bad "budget exhaustion would be retried -- MAX_RETRIES multiplies the ceiling by three"
fi

# --- Behaviour, executed from the shipped source ------------------------
echo ""
echo "behaviour (helpers lifted out of vendor/cm048_pipeline/src/processor.py)"
out="$("$PY" "$REPO/tests/helpers/check_enrich_budget.py" "$SRC" 2>&1)"
while IFS= read -r line; do
	case "$line" in
		PASS:*) ok "${line#PASS: }" ;;
		FAIL:*) bad "${line#FAIL: }" ;;
		*)      [ -n "$line" ] && bad "unexpected harness output: $line" ;;
	esac
done <<< "$out"

echo ""
if [ "$fail" -eq 0 ]; then
	printf '\033[0;32mGREEN -- %d assertion(s), the step cannot outrun its allowance\033[0m\n' "$pass"
	exit 0
fi
printf '\033[0;31mRED -- %d of %d assertion(s) failed\033[0m\n' "$fail" "$((pass + fail))"
echo "Do not raise the allowance to make this pass. A four-hour step holds the"
echo "shared ingest lock and stops every conversation feed behind it."
exit 1
