#!/usr/bin/env bash
# tests/test_only_the_users_own_address_book_is_read.sh -- CM051 #1619.
#
# THE ONLY GUARD ON THIS FIX WAS THAT ITS FUNCTION NAME APPEARS IN THE DMG.
#
# #1619 is "a display_name must be a name": person pages on the walk box
# carried names derived from kinship terms. The cause was not a bad derivation
# and not orphaned nodes. macOS `AddressBookSourceSync` pulls ANOTHER DEVICE's
# local address book up into the owning iCloud account, the Hub ingested that
# book too, and a household member's contact naming became the customer's data.
# `_source_is_the_users_own` in the shipped syncer is the fix.
#
# MEASURED on origin/main d0c207fd, with positive controls of the same shape:
#
#   test files naming _source_is_the_users_own    1, and it is the DMG DELIVERY
#                                                 fixture -- it asserts the
#                                                 STRING is in the artefact
#   test files naming _read_abcddb_as_vcards      0
#   CONTROL, test files naming contact_syncer    26
#   workflows naming either                       0
#   CONTROL, workflows naming contact_syncer      6
#
# So a refactor that keeps the name and drops the bundle test, or that
# "tightens" the deliberate fail-open arm into a fail-closed one, passes every
# gate that exists and reproduces #1619 on the next customer with a family
# iCloud. The second of those is the more dangerous: failing closed on an
# unreadable oracle silently empties a customer's whole address book.
#
# TWO HALVES:
#   1. WIRING. The classifier is CALLED, in both shipped copies of the syncer,
#      and the two copies agree. A classifier nobody calls is #1690's shape one
#      module along.
#   2. BEHAVIOUR. The classifier LIFTED OUT OF THE SHIPPED SOURCE and driven
#      against a synthetic Accounts4.sqlite. Delegated to
#      tests/helpers/check_address_book_source_guard.py, which carries its own
#      mutation control.
#
# WHAT THIS DOES NOT SETTLE, and #1619 stays open until a walk does. The gate
# that grades the row reads rendered wiki pages and the Oxigraph store ON A
# BOX. This asserts the classifier is correct and called; it cannot assert that
# a box whose store was populated by a build CARRYING the guard comes back
# clean. That is a measurement, not an inference, and nobody has taken it.
#
# EXIT: 0 all assertions hold. 1 one or more failed. 2 could not run.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PYTHON_BIN:-python3}"
HELPER="$REPO/tests/helpers/check_address_book_source_guard.py"
VENDORED="$REPO/vendor/cm041/contact_syncer/syncer.py"
ROOTCOPY="$REPO/contact_syncer/syncer.py"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
cant() {
	printf '  \033[0;33mCANNOT-RUN\033[0m %s\n' "$1"
	printf '\033[0;33mCANNOT-RUN -- nothing was measured. This is not a pass.\033[0m\n'
	exit 2
}

echo "#1619: only the customer's own address book is read"
echo ""
echo "wiring"

[ -f "$HELPER" ] || cant "behaviour helper missing at ${HELPER}"
[ -f "$VENDORED" ] || cant "the shipped vendored syncer is missing at ${VENDORED}"
command -v "$PY" >/dev/null 2>&1 || cant "no ${PY} on PATH"

# The call site. `grep -c`, never `grep -q`: this file sets `pipefail` and a
# `producer | grep -q` short-circuits the producer and inverts the verdict.
#
# EXACTLY 2 is the assertion, not "at least 1": one definition and one call. A
# count of 1 means the method is defined and never invoked, which is the
# failure this repo ships most often, and "at least 1" cannot tell the two
# apart.
for f in "$VENDORED" "$ROOTCOPY"; do
	label="${f#$REPO/}"
	if [ ! -f "$f" ]; then
		bad "${label} is absent, so one of the two shipped copies cannot be measured"
		continue
	fi
	n="$(/usr/bin/grep -c '_source_is_the_users_own' "$f" || true)"
	# CONTROL of the same shape in the same file: a sibling method that is
	# certainly present. A zero here means the predicate is broken.
	c="$(/usr/bin/grep -c '_read_abcddb_as_vcards' "$f" || true)"
	if [ "${c:-0}" -eq 0 ]; then
		cant "the CONTROL (_read_abcddb_as_vcards) returns 0 in ${label}, so this grep cannot see a method at all. Investigate the control, not the subject."
	fi
	if [ "${n:-0}" -eq 2 ]; then
		ok "${label}: the classifier is defined AND called (2 refs; control _read_abcddb_as_vcards ${c})"
	else
		bad "${label}: ${n:-0} reference(s) to _source_is_the_users_own, expected 2 (one definition, one call). 1 means defined and never invoked."
	fi
	b="$(/usr/bin/grep -c 'com\.apple\.AddressBookSourceSync' "$f" || true)"
	if [ "${b:-0}" -ge 1 ]; then
		ok "${label}: the discriminating bundle is named in the file that ships"
	else
		bad "${label}: com.apple.AddressBookSourceSync appears 0 times -- the function name can survive while the behaviour does not, and the DMG row greps the NAME"
	fi
done

# The two copies must AGREE. gui/project.yml stages the vendored tree onto the
# Resources root, and install.sh stages whatever is beside it; a graft applied
# to one copy and not the other ships a half-fixed artefact that no single-file
# check can see.
if [ -f "$ROOTCOPY" ]; then
	a="$(/usr/bin/grep -c 'com\.apple\.AddressBookSourceSync' "$VENDORED" || true)"
	b="$(/usr/bin/grep -c 'com\.apple\.AddressBookSourceSync' "$ROOTCOPY" || true)"
	if [ "${a:-0}" -eq "${b:-0}" ] && [ "${a:-0}" -ge 1 ]; then
		ok "both shipped copies of the syncer carry the same guard (${a} each)"
	else
		bad "the two shipped copies DISAGREE: vendored ${a:-0}, repo-root ${b:-0} -- a graft landed on one of them only"
	fi
else
	bad "the repo-root contact_syncer/syncer.py twin is gone; if that is deliberate this assertion needs retiring, not deleting"
fi

echo ""
echo "behaviour (the classifier lifted out of the SHIPPED source)"
# stdout and stderr SEPARATED. The shipped classifier LOGS its verdict for
# every source, by design, so folding stderr into the assertion stream turns
# correct logging into a FAIL. Not `2>/dev/null` either: a real traceback must
# still be readable, so stderr is kept and printed when no assertions arrive.
_err="$(mktemp)"
out="$("$PY" "$HELPER" "$REPO" 2>"$_err")"; rc=$?
if [ "$(printf '%s\n' "$out" | /usr/bin/grep -c -E '^(PASS|FAIL):' || true)" -eq 0 ]; then
	printf '  helper stderr:\n'
	sed 's/^/    /' "$_err"
	rm -f "$_err"
	cant "the behaviour helper emitted no PASS/FAIL assertions (rc=${rc}) -- nothing was measured"
fi
rm -f "$_err"
while IFS= read -r line; do
	case "$line" in
		PASS:*) ok "${line#PASS: }" ;;
		FAIL:*) bad "${line#FAIL: }" ;;
		*)      [ -n "$line" ] && bad "unexpected harness output: $line" ;;
	esac
done <<< "$out"

echo ""
if [ "$fail" -eq 0 ]; then
	printf '\033[0;32mGREEN -- %d assertion(s); only the customer'"'"'s own book is read\033[0m\n' "$pass"
	echo "This does NOT close #1619. The row is graded on a box, and no box has"
	echo "yet been walked whose store was populated by a build carrying the guard."
	exit 0
fi
printf '\033[0;31mRED -- %d of %d assertion(s) failed\033[0m\n' "$fail" "$((pass + fail))"
echo "Do NOT relax the fail-open arms to make this pass. Excluding a source on"
echo "an unreadable oracle empties a customer's address book, which is worse"
echo "than the defect being fixed. That is written into the shipped comment."
exit 1
