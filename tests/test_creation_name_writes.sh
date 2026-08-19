#!/usr/bin/env bash
# tests/test_creation_name_writes.sh -- v1018-D011.
#
# The name rule lives in `_display_name_tier` and is enforced by
# `_upsert_display_name`, which every ingest source calls. It was never the
# only writer. Each source ALSO emitted a `pwg:displayName` inside its own
# `if not _person_exists(uri)` creation INSERT, and that write went nowhere
# near the tier.
#
# On a FRESH INSTALL nothing exists, so the creation branch is the branch
# EVERY customer takes, and the guarded upsert running immediately after
# could only ever look at a value it had already lost the argument about:
#
#   * a kinship word off a Photos face label or a calendar attendee was
#     written, then declined, then kept (v1018-D659 enforced second);
#   * a handle from calendar/photos/mail was written with no
#     `displayNameProvisional`, and the tier-2 guard is
#     `!BOUND(?old) || BOUND(?prov)` -- name bound, no flag, both disjuncts
#     false -- so a real name arriving later could never land.
#
# Two halves, asserting different things:
#   1. the helper is wired at all five creation sites, and no site still
#      hand-rolls a displayName triple;
#   2. the SPARQL the SHIPPED `ingest_*` functions actually emit (delegated
#      to the harness, which drives them against synthetic extractor JSON).
#
# Half 1 alone is the v1018-D017 failure -- a helper that exists while the
# call sites do not. Half 2 alone passes on a module where the helper is
# perfect and nothing calls it.
#
# EXIT: 0 all assertions hold. 1 one or more failed.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PYTHON_BIN:-python3}"
SRC="$REPO/vendor/ostler_fda/pwg_ingest.py"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

echo "v1018-D011: the creation write obeys the same name rule as the upgrade"
echo ""
echo "wiring"

[ -f "$SRC" ] || { bad "vendor/ostler_fda/pwg_ingest.py missing"; printf '\033[0;31mRED\033[0m\n'; exit 1; }

if grep -q 'def _creation_name_triples' "$SRC"; then
	ok "the creation-name helper is defined"
else
	bad "the creation-name helper is gone -- this guard is measuring nothing"
fi

# Counted, not grepped. Five sources; covering four is the half-wired
# failure that ships, and it is exactly what this row turned out to be.
sites="$(grep -c '_creation_name_triples(uri,' "$SRC" || true)"
if [ "${sites:-0}" -eq 5 ]; then
	ok "all 5 creation sites route the name through the helper (imessage/whatsapp/calendar/photos/mail)"
else
	bad "${sites:-0} of 5 creation sites route the name through the helper -- an unrouted source writes whatever it was handed"
fi

# NO site may still hand-roll the triple. The helper being present is not
# the same as the raw write being gone, and a leftover raw write is the
# whole defect -- it runs FIRST and wins.
raw="$(grep -cE '^[[:space:]]*f.<\{uri\}> pwg:displayName ' "$SRC" || true)"
if [ "${raw:-0}" -eq 0 ]; then
	ok "no creation site still hand-rolls a pwg:displayName triple"
else
	bad "${raw:-0} hand-rolled pwg:displayName triple(s) remain in a creation INSERT -- they run before the guard and win"
fi

# The rule must stay in ONE place. A second tier table is the drift class
# that produced this cut.
tiers="$(grep -c 'def _display_name_tier' "$SRC" || true)"
if [ "${tiers:-0}" -eq 1 ]; then
	ok "exactly one tier predicate in the module (the helper delegates, it does not restate)"
else
	bad "${tiers:-0} tier predicates -- two copies of a rule are two rules"
fi

echo ""
echo "behaviour (the SHIPPED ingest_* functions, driven against synthetic JSON)"
out="$("$PY" "$REPO/tests/helpers/check_creation_name_writes.py" "$REPO" 2>&1)"
while IFS= read -r line; do
	case "$line" in
		PASS:*)   ok "${line#PASS: }" ;;
		FAIL:*)   bad "${line#FAIL: }" ;;
		"        (raised "*) printf '%s\n' "$line" ;;
		*)        [ -n "$line" ] && bad "unexpected harness output: $line" ;;
	esac
done <<< "$out"

echo ""
if [ "$fail" -eq 0 ]; then
	printf '\033[0;32mGREEN -- %d assertion(s); a creation write cannot outrank the name rule\033[0m\n' "$pass"
	exit 0
fi
printf '\033[0;31mRED -- %d of %d assertion(s) failed\033[0m\n' "$fail" "$((pass + fail))"
exit 1
