#!/usr/bin/env bash
# tests/test_name_repair.sh -- v1018-D658 repair pass.
#
# CM051 #548 stopped the writer stacking names. This repairs the ones
# already stacked. On a real box: 241 nodes with 2+ names, 192 of them
# rendering a second name on the built page.
#
# The load-bearing property is a NEGATIVE one: when two names are of equal
# standing the repair must NOT choose. Andy's call 2026-08-10 was "review
# list". A repair that quietly picks a winner deletes a correct name from a
# customer's graph and there is no undo.
#
# EXIT: 0 all assertions hold. 1 one or more failed.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PYTHON_BIN:-python3}"
MOD="$REPO/vendor/ostler_fda/repair_placeholder_names.py"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

echo "v1018-D658 repair: collapse stacked names, never break a tie"
echo ""
echo "wiring"

[ -f "$MOD" ] || { bad "repair module missing"; printf '\033[0;31mRED\033[0m\n'; exit 1; }

# The rule must be IMPORTED, not restated. A second copy is how the two
# halves of a system come to disagree -- several times over this cut.
if grep -qE 'from (\.)?pwg_ingest import' "$MOD"; then
	ok "the tier rule is imported from pwg_ingest, not restated"
else
	bad "the repair does not import the tier rule -- a local copy will drift"
fi
if grep -qE '^\s*(def _display_name_tier|phoneish = all)' "$MOD"; then
	bad "the repair has its OWN copy of the tier predicate -- delete it and import"
else
	ok "no duplicate tier predicate in the repair module"
fi

# Writing must be opt-in. This deletes names and there is no undo.
if grep -q '"--apply", action="store_true"' "$MOD" && grep -q 'if not args.apply' "$MOD"; then
	ok "dry run is the default; --apply is required to write"
else
	bad "writing is not gated behind --apply"
fi

# NOTHING may be deleted outright. Every losing name must reappear as
# alternateName in the SAME update -- taken from CM041 #109, which was right
# about this where the first draft of this module was wrong: "Mum" is real
# matching signal even when it is the wrong answer to "who is my wife".
if grep -q 'alternateName' "$MOD"; then
	ok "losing names are demoted to alternateName, not destroyed"
else
	bad "no alternateName write -- this repair DELETES names and is irreversible"
fi
if "$PY" - "$MOD" <<'PYEOF2'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
# Walk every CALL to _update (not its definition -- matching `def _update(`
# is what made the first version of this check fail against correct code)
# and require the one carrying DELETE to also carry INSERT + alternateName.
calls = [m.start() for m in re.finditer(r"(?<!def )_update\(", src)]
if not calls:
    sys.exit(2)
ok = False
for start in calls:
    depth, i = 0, src.index("(", start)
    for j in range(i, len(src)):
        if src[j] == "(":
            depth += 1
        elif src[j] == ")":
            depth -= 1
            if depth == 0:
                blk = src[i:j]
                break
    else:
        continue
    if "DELETE" in blk:
        # The SPARQL is assembled from variables, so the literal
        # "alternateName" lives ABOVE the call, not inside it. Looking for
        # it here is what made the first version of this check fail against
        # correct code. The property under test is ATOMICITY: one update
        # carrying both halves. That alternateName is what gets inserted is
        # asserted separately, above.
        ok = "INSERT" in blk
        break
sys.exit(0 if ok else 1)
PYEOF2
then
	ok "the DELETE and the alternateName INSERT are one atomic update"
else
	bad "the demotion is not atomic -- a crash between them loses the name"
fi

# The review list holds real names; it must not land in the repo.
if grep -q 'expanduser("~/.ostler' "$MOD"; then
	ok "the review list is written under ~/.ostler, not into the tree"
else
	bad "the review list path is not a user-local path -- real names could be committed"
fi

echo ""
echo "behaviour (decide() lifted from the SHIPPED module)"
out="$("$PY" "$REPO/tests/helpers/check_name_repair.py" "$REPO" 2>&1)"
while IFS= read -r line; do
	case "$line" in
		PASS:*) ok "${line#PASS: }" ;;
		FAIL:*) bad "${line#FAIL: }" ;;
		*)      [ -n "$line" ] && bad "unexpected harness output: $line" ;;
	esac
done <<< "$out"

echo ""
echo "destructive-path guards (the SHIPPED main(), network stubbed)"
# These live in main(), not in decide(), so the helper above cannot see
# them -- and a grep would pass against a guard placed after the first
# write. This one runs main() and asserts NOTHING is written.
out="$("$PY" "$REPO/tests/helpers/check_repair_guards.py" "$REPO" 2>/dev/null \
	| grep -E '^(PASS|FAIL):')"
[ -n "$out" ] || bad "the guard harness produced no assertions at all"
while IFS= read -r line; do
	case "$line" in
		PASS:*) ok "${line#PASS: }" ;;
		FAIL:*) bad "${line#FAIL: }" ;;
	esac
done <<< "$out"

echo ""
if [ "$fail" -eq 0 ]; then
	printf '\033[0;32mGREEN -- %d assertion(s); the repair cannot guess a winner\033[0m\n' "$pass"
	exit 0
fi
printf '\033[0;31mRED -- %d of %d assertion(s) failed\033[0m\n' "$fail" "$((pass + fail))"
echo "Do not make a tie resolvable to raise the auto-repair count. Andy ruled"
echo "review-list on 2026-08-10 and the deleted name has no undo."
exit 1
