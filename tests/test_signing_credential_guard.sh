#!/usr/bin/env bash
#
# Does the signing-credential guard fire on the states that actually occur?
#
# Executes bin/require_signing_credentials.sh -- the real file the cut runs --
# rather than a copy of its logic. A guard proven only by a re-implementation
# proves the re-implementation.
#
# THE ARM THAT MATTERS IS B: three of five set. That is not a hypothetical, it
# is the live state of this repo as of 2026-08-10, and it is precisely the
# state the previous one-secret guard PASSED.
#
# Placeholder values only. No real credential is ever read here, and the guard
# itself only tests emptiness.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

GUARD="bin/require_signing_credentials.sh"
ALL="OSTLER_SIGNING_CERT_P12 OSTLER_SIGNING_CERT_PASSWORD OSTLER_NOTARY_KEY OSTLER_NOTARY_KEY_ID OSTLER_NOTARY_ISSUER"
fails=0

if [ ! -x "$GUARD" ]; then
	echo "FAIL  $GUARD missing or not executable -- the cut would call a guard that cannot run"
	exit 1
fi

# The workflow must actually CALL it. A guard nothing invokes is the oldest
# failure mode in this repo's catalogue.
if grep -q 'require_signing_credentials.sh' .github/workflows/cut.yml; then
	echo "PASS  cut.yml invokes the guard"
else
	echo "FAIL  cut.yml does NOT invoke the guard -- it would never run"
	fails=$(( fails + 1 ))
fi

# The guard's own output goes to a FILE, and the verdict goes to stdout.
#
# The first version of this returned the captured output on stdout alongside
# the verdict, so a caller that discarded the output to inspect it separately
# discarded the PASS/FAIL line with it -- four arms ran and reported nothing,
# and the suite still printed GREEN. That is the "runs correctly but nobody
# reads the answer" failure, inside the file written to prevent it. Verdicts
# are never mixed with payload now.
ARM_OUT="$(mktemp)"
trap 'rm -f "$ARM_OUT"' EXIT

arm() {  # $1 = label, $2 = expected rc, rest = names to set
	local label="$1" want="$2"; shift 2
	local rc
	(
		for n in $ALL; do unset "$n"; done
		for n in "$@"; do export "$n=placeholder-not-a-real-value"; done
		bash "$GUARD"
	) >"$ARM_OUT" 2>&1
	rc=$?
	if [ "$rc" = "$want" ]; then
		echo "PASS  $label (rc=$rc)"
	else
		echo "FAIL  $label -- rc=$rc, wanted $want"
		sed 's/^/        /' "$ARM_OUT"
		fails=$(( fails + 1 ))
	fi
}

echo
arm "all five present -> allowed" 0 $ALL

# Arm B additionally asserts the MESSAGE names both missing secrets. A guard
# that fails without saying which one is missing sends you round the loop once
# per secret.
arm "LIVE STATE: 3 of 5 -> blocked" 1 \
	OSTLER_SIGNING_CERT_P12 OSTLER_NOTARY_KEY OSTLER_NOTARY_KEY_ID
for expect in OSTLER_SIGNING_CERT_PASSWORD OSTLER_NOTARY_ISSUER; do
	if grep -q "$expect" "$ARM_OUT"; then
		echo "PASS    names $expect"
	else
		echo "FAIL    does not name $expect"
		fails=$(( fails + 1 ))
	fi
done

arm "none present -> blocked" 1

# The regression test proper: the exact state the OLD guard let through.
arm "only OSTLER_SIGNING_CERT_P12 (what the old guard tested) -> blocked" 1 \
	OSTLER_SIGNING_CERT_P12

echo
if [ "$fails" -eq 0 ]; then
	echo "signing-credential guard: GREEN"
	exit 0
fi
echo "signing-credential guard: RED ($fails failing)"
exit 1
