#!/usr/bin/env bash
# bin/redact_selftest.sh -- proves bin/lib_redact.sh before it is trusted.
#
# rollforward_gate.sh runs this before it evaluates a single gate. A leak
# guard that has never been watched failing is not a guard, and this one is
# on the path that carries a customer's graph off their machine.
#
# Three sections, and the third is the one that matters:
#
#   LEAK      -- must be redacted. A miss here is a PII leak.
#   SURVIVE   -- must pass through byte-identical. A hit here is the bug that
#                turned every date in a failure report into <number-redacted>.
#   ACCEPTED  -- known over-redaction, asserted on purpose so it reads as a
#                decision rather than being rediscovered as a defect.
#
# `--prove` re-runs the LEAK and SURVIVE sets against the two predicates this
# repo has actually shipped, and asserts each one goes red. A predicate that
# passes this suite unchanged when swapped for a known-broken one is not
# discriminating, and the suite would be measuring nothing.
#
# Every fixture is synthetic. UK numbers are from the Ofcom drama ranges
# (07700 900xxx, 020 7946 0xxx) and US numbers from 555-01xx, which exist
# precisely so that examples never collide with a real subscriber.
#
# EXIT: 0 every assertion holds. 1 one or more failed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib_redact.sh
. "$HERE/lib_redact.sh"

PROVE=0
[ "${1:-}" = "--prove" ] && PROVE=1

pass=0
fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

# The predicate under test is whichever `redact` is currently defined, so the
# --prove mode can substitute a historical one and reuse every case below.
must_redact() {
	local label="$1" text="$2" out
	out="$(printf '%s' "$text" | redact)"
	if [ "$out" = "$text" ]; then
		bad "$label -- passed through unredacted: $text"
	elif printf '%s' "$out" | grep -q '<number-redacted>\|<email-redacted>'; then
		ok "$label"
	else
		bad "$label -- altered but not redacted: $out"
	fi
}

must_survive() {
	local label="$1" text="$2" out
	out="$(printf '%s' "$text" | redact)"
	if [ "$out" = "$text" ]; then
		ok "$label"
	else
		bad "$label -- was altered: $text  ->  $out"
	fi
}

run_leak_set() {
	must_redact "intl, spaced"            "escalated to +44 7700 900123 overnight"
	must_redact "intl, unspaced"          "escalated to +447700900123 overnight"
	must_redact "intl, hyphenated"        "escalated to +44-7700-900123 overnight"
	must_redact "intl, non-UK dialling"   "escalated to +852 5555 0123 overnight"
	must_redact "national trunk, spaced"  "escalated to 07700 900123 overnight"
	must_redact "national trunk, tight"   "escalated to 07700900123 overnight"
	must_redact "landline in parentheses" "escalated to (020) 7946 0958 overnight"
	must_redact "bare long digit run"     "handle 5550100999 on the account"
	must_redact "email address"           "owner is someone@example.com here"
	must_redact "email beside a name"     "Person A <someone@example.com> matched"
}

run_survive_set() {
	# The ISO date is first because it is the case that was broken, and if it
	# ever breaks again this is the line that says so.
	must_survive "ISO date"             "cut v1.0.18 gated on 2026-08-10 and held"
	must_survive "ISO timestamp"        "stamped 2026-08-10T02:31:00Z by the runner"
	must_survive "date range"           "window 2026-08-01 to 2026-08-09 inclusive"
	must_survive "semver"               "daemon hub-v0.4.50 against installer 1.0.18"
	must_survive "trunk-lookalike semver" "wrapper 0.4.50 embeds frontend 0.13.2"
	must_survive "clock time"           "step began 02:31:00 and ran to 04:12:55"
	must_survive "loopback and port"    "gateway listening on 127.0.0.1:8000 only"
	must_survive "row counts"           "42 person nodes carry 2+ distinct names"
	must_survive "byte sizes"           "236KB transcript, 2.8x the next largest"
	must_survive "short SHA with letters" "landed as 8076740a on main, not b0b3831"
	must_survive "percentages"          "converged 16% -> 1.8% after install"
}

echo "redactor self-test -- bin/lib_redact.sh"
echo ""
echo "LEAK (must be redacted)"
run_leak_set
echo ""
echo "SURVIVE (must pass through untouched)"
run_survive_set
echo ""
echo "ACCEPTED over-redaction (deliberate -- see lib_redact.sh)"
for t in "build stamp 20260810 in the artefact name" "all-digit short sha 8076740 on main"; do
	if [ "$(printf '%s' "$t" | redact)" != "$t" ]; then
		ok "${t%% *} run of 7+ digits is redacted, as designed"
	else
		bad "${t%% *} -- expected over-redaction, got none; the digit-run rule has changed"
	fi
done

if [ "$PROVE" -eq 1 ]; then
	echo ""
	echo "PROVE (each historical predicate must fail this suite)"

	# Predicate as originally shipped: any 8+ character run drawn from the
	# separator class. Catches every phone shape and eats every ISO date.
	redact() {
		sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email-redacted>/g' \
		    | sed -E 's/(^|[^0-9A-Za-z])\+?[0-9][0-9 ()._-]{7,}[0-9]/\1<number-redacted>/g'
	}
	before=$fail; sub_p=$pass; sub_f=$fail
	run_survive_set >/dev/null 2>&1
	if [ "$fail" -gt "$before" ]; then
		ok "original over-matcher is caught by the SURVIVE set ($((fail - before)) case(s))"
	else
		bad "original over-matcher passed SURVIVE -- the suite is not discriminating"
	fi
	pass=$sub_p; fail=$sub_f

	# Predicate proposed as the date fix: international-only plus consecutive
	# digits. Dates survive; separated national numbers leak.
	redact() {
		sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email-redacted>/g' \
		    | sed -E 's/(^|[^0-9A-Za-z+])\+[0-9][0-9 ()._-]{6,}[0-9]/\1<number-redacted>/g' \
		    | sed -E 's/(^|[^0-9A-Za-z])[0-9]{7,}/\1<number-redacted>/g'
	}
	before=$fail; sub_p=$pass; sub_f=$fail
	run_leak_set >/dev/null 2>&1
	if [ "$fail" -gt "$before" ]; then
		ok "international-only fix is caught by the LEAK set ($((fail - before)) case(s))"
	else
		bad "international-only fix passed LEAK -- the suite would not have caught the hole"
	fi
	pass=$sub_p; fail=$sub_f
fi

echo ""
if [ "$fail" -eq 0 ]; then
	printf '\033[0;32mGREEN -- %d assertion(s)\033[0m\n' "$pass"
	exit 0
fi
printf '\033[0;31mRED -- %d of %d assertion(s) failed\033[0m\n' "$fail" "$((pass + fail))"
echo "Do not relax a LEAK case to make this pass. This redactor is what stands"
echo "between a customer's graph and the cut log."
exit 1
