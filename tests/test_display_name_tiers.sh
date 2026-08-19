#!/usr/bin/env bash
# tests/test_display_name_tiers.sh -- v1018-D658.
#
# Ingest names an unknown person after their raw handle and flags it
# `displayNameProvisional` -- "replace me when a real name arrives". A real
# name arrives from another source and NOTHING retracts anything, so the
# node keeps both. 43 person nodes on the founder box carry two names; 5
# rendered wiki pages show one person's identity on another's page.
#
# Root cause: all five displayName writes sit inside
# `if not _person_exists(uri)`. No code path ever updated an EXISTING
# person's name, so the flag was never going to be retracted.
#
# Two halves, asserting different things:
#   1. every ingest source is wired, and there is ONE tier predicate;
#   2. the emitted SPARQL is correct per tier (delegated to the harness).
#
# Half 1 matters because a helper that exists while the call sites do not
# is exactly what v1018-D017 turned out to be, and half 2 alone passes on
# it.
#
# EXIT: 0 all assertions hold. 1 one or more failed.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PYTHON_BIN:-python3}"
SRC="$REPO/vendor/ostler_fda/pwg_ingest.py"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

echo "v1018-D658: a placeholder name is retracted when a better one arrives"
echo ""
echo "wiring"

[ -f "$SRC" ] || { bad "vendor/ostler_fda/pwg_ingest.py missing"; printf '\033[0;31mRED\033[0m\n'; exit 1; }

# Every ingest source must upgrade. Counted, not grepped: five sources,
# and covering four of them is the half-wired failure that ships.
sites="$(grep -c '_upsert_display_name(uri,' "$SRC" || true)"
if [ "${sites:-0}" -eq 5 ]; then
	ok "all 5 ingest sources call the upgrade (imessage/whatsapp/calendar/photos/mail)"
else
	bad "${sites:-0} of 5 ingest sources call the upgrade -- an unwired source keeps its placeholder forever"
fi

# One predicate, not two. The old _is_provisional_display_name must
# DELEGATE to the tier; if the phone-shape test appears twice the two can
# disagree, which is the drift class that produced half of this cut.
shapes="$(grep -c 'phoneish = all' "$SRC" || true)"
if [ "${shapes:-0}" -eq 1 ]; then
	ok "exactly one phone-shape predicate in the module (no drift twin)"
else
	bad "${shapes:-0} phone-shape predicates -- they will disagree; _is_provisional_display_name must delegate to _display_name_tier"
fi

if grep -q 'def _upsert_display_name' "$SRC"; then
	ok "the upgrade helper is defined"
else
	bad "the upgrade helper is gone -- this guard is measuring nothing"
fi

echo ""
echo "behaviour (functions lifted out of the SHIPPED vendored source)"
out="$("$PY" "$REPO/tests/helpers/check_display_name_tiers.py" "$REPO" 2>&1)"
while IFS= read -r line; do
	case "$line" in
		PASS:*) ok "${line#PASS: }" ;;
		FAIL:*) bad "${line#FAIL: }" ;;
		*)      [ -n "$line" ] && bad "unexpected harness output: $line" ;;
	esac
done <<< "$out"

echo ""
if [ "$fail" -eq 0 ]; then
	printf '\033[0;32mGREEN -- %d assertion(s); a placeholder cannot outlive a better name\033[0m\n' "$pass"
	exit 0
fi
printf '\033[0;31mRED -- %d of %d assertion(s) failed\033[0m\n' "$fail" "$((pass + fail))"
echo "Do not relax the tier table to make this pass. It is Andy's ruling of"
echo "2026-08-10 and the flag-stays-set-at-tier-1 half is the load-bearing part."
exit 1
