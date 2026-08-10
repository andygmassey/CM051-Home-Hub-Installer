#!/usr/bin/env bash
# tests/test_section_contract.sh -- v1018-D014b.
#
# 29 of 129 conversation summaries on the founder box render
# `### Participants` and `### Thread` with no `### Narrative`: the prose
# the section exists for is simply absent, and the surrounding metadata is
# what Andy read as raw prompt scaffolding.
#
# The cause is not a wire-order bug. A chunked document is merged by
# `_merge_chunk_outputs`, which loads `02b_merge_chunks` -- a template that
# declares no `###` headings and never mentions Narrative -- and the
# expected-heading check is `##`-only, so nothing noticed. The check was
# one level coarser than the defect.
#
# Two halves that assert DIFFERENT things:
#   1. the contract behaves (delegated to the Python harness);
#   2. the merge pass actually RECEIVES it and validation actually
#      CHECKS it -- because a helper that exists while the call site does
#      not is exactly what v1018-D017 turned out to be, and a behavioural
#      test alone passes on that.
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

echo "v1018-D014b: a merged document keeps every section it declared"
echo ""
echo "wiring"

if [ ! -f "$PROC" ]; then
	bad "vendor/cm048_pipeline/src/processor.py missing"
	printf '\033[0;31mRED\033[0m\n'; exit 1
fi

# The merge pass must receive the contract. This is THE fix: without it
# the model is never told to keep the sub-sections.
if "$PY" - "$PROC" <<'PYEOF'
import ast, sys
src = open(sys.argv[1], encoding="utf-8").read()
tree = ast.parse(src)
fn = next((n for n in ast.walk(tree)
           if isinstance(n, ast.FunctionDef) and n.name == "_merge_chunk_outputs"), None)
if fn is None:
    sys.exit(2)
body = ast.get_source_segment(src, fn) or ""
sys.exit(0 if "build_section_contract(prompt_name)" in body else 1)
PYEOF
then
	ok "the chunk-merge pass is handed the variant's section contract"
else
	rc=$?
	[ "$rc" = 2 ] && bad "_merge_chunk_outputs is gone -- this guard is measuring nothing" \
	              || bad "the merge pass does NOT receive the contract -- the fix is not wired"
fi

# Both validation sites must use the two-level check. Counted, not
# grepped: there is a first-attempt site and a retry site, and covering
# one is the half-wired failure that ships.
sites="$(grep -c '_validate_document(' "$PROC" || true)"
if [ "${sites:-0}" -ge 3 ]; then
	ok "both validation sites use the two-level check (definition + $((sites - 1)) call sites)"
else
	bad "only $((sites > 0 ? sites - 1 : 0)) validation call site(s) use the two-level check -- expected 2"
fi

# The old one-level call must be gone from the retry path, or a merged
# document with a dropped sub-section still passes on the second attempt.
if grep -qE 'retry_validation = enrichment_validation\.validate_headings' "$PROC"; then
	bad "the retry path still uses the ##-only check"
else
	ok "the retry path no longer uses the ##-only check"
fi

echo ""
echo "behaviour (contract lifted out of vendor/cm048_pipeline/src/)"
out="$("$PY" "$REPO/tests/helpers/check_section_contract.py" "$REPO" 2>&1)"
while IFS= read -r line; do
	case "$line" in
		PASS:*) ok "${line#PASS: }" ;;
		FAIL:*) bad "${line#FAIL: }" ;;
		*)      [ -n "$line" ] && bad "unexpected harness output: $line" ;;
	esac
done <<< "$out"

echo ""
if [ "$fail" -eq 0 ]; then
	printf '\033[0;32mGREEN -- %d assertion(s), a merged document cannot silently lose a section\033[0m\n' "$pass"
	exit 0
fi
printf '\033[0;31mRED -- %d of %d assertion(s) failed\033[0m\n' "$fail" "$((pass + fail))"
echo "Do not narrow the declared sub-section list to make this pass. A"
echo "missing narrative is the defect; the list is what says so."
exit 1
