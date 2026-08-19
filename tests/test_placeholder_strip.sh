#!/usr/bin/env bash
# tests/test_placeholder_strip.sh -- v1018-D014c.
#
# A customer's wiki page carried a literal `{user_email}`. The cause is NOT
# broken substitution: the enrichment prompts are instructions, the real
# values arrive below a `---` separator, and the `{token}` forms in a
# template are illustrative. `prompts.render()` has zero callers. The model
# simply copies an illustrative token into its answer sometimes, which is
# why the defect is intermittent.
#
# This guard has two halves that assert DIFFERENT things:
#   1. the helper behaves (delegated to the Python harness);
#   2. the shipped write path actually CALLS it -- because a helper that
#      exists while the call site does not is exactly what v1018-D017
#      turned out to be, and a behavioural test alone passes on that.
#
# EXIT: 0 all assertions hold. 1 one or more failed.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PYTHON_BIN:-python3}"
PROC="$REPO/vendor/cm048_pipeline/src/processor.py"

pass=0
fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

echo "v1018-D014c: prompt-template placeholders never reach a customer page"
echo ""
echo "wiring"

if [ ! -f "$PROC" ]; then
	bad "vendor/cm048_pipeline/src/processor.py missing"
	printf '\033[0;31mRED\033[0m\n'; exit 1
fi

# Every write of enrichment output to disk must be preceded by the strip.
# Counted, not merely grepped: there are two write sites (single-chunk and
# merged-chunk) and protecting one is the failure mode that ships.
writes="$(grep -c 'out_path.write_text(rendered)' "$PROC" || true)"
strips="$(grep -c 'strip_placeholder_tokens(rendered)' "$PROC" || true)"
if [ "${writes:-0}" -eq 0 ]; then
	bad "no rendered-output write site found -- this guard is measuring nothing"
elif [ "${writes:-0}" -eq "${strips:-0}" ]; then
	ok "all ${writes} rendered-output write site(s) strip placeholders first"
else
	bad "${writes} write site(s) but only ${strips} strip -- an unprotected write ships the token"
fi

# Order matters: strip BEFORE the write, not after.
if "$PY" - "$PROC" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
# Each write must have a strip within the preceding 15 lines.
lines = src.splitlines()
bad = 0
for i, ln in enumerate(lines):
    if "out_path.write_text(rendered)" in ln:
        window = "\n".join(lines[max(0, i - 15):i])
        if "strip_placeholder_tokens(rendered)" not in window:
            bad += 1
sys.exit(1 if bad else 0)
PYEOF
then
	ok "each strip precedes its write"
else
	bad "a write is not preceded by a strip -- the token reaches disk"
fi

echo ""
echo "behaviour (helper lifted out of vendor/cm048_pipeline/src/)"
out="$("$PY" "$REPO/tests/helpers/check_placeholder_strip.py" "$REPO" 2>&1)"
while IFS= read -r line; do
	case "$line" in
		PASS:*) ok "${line#PASS: }" ;;
		FAIL:*) bad "${line#FAIL: }" ;;
		*)      [ -n "$line" ] && bad "unexpected harness output: $line" ;;
	esac
done <<< "$out"

echo ""
if [ "$fail" -eq 0 ]; then
	printf '\033[0;32mGREEN -- %d assertion(s), no placeholder can reach a page\033[0m\n' "$pass"
	exit 0
fi
printf '\033[0;31mRED -- %d of %d assertion(s) failed\033[0m\n' "$fail" "$((pass + fail))"
echo "Do not widen the token pattern to make this pass. A false positive"
echo "silently edits the customer's own content, which is worse than the"
echo "cosmetic defect this guard exists to stop."
exit 1
