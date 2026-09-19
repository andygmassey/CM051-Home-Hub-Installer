#!/usr/bin/env bash
# The wiki-provenance row in scripts/pre_tag_live_checks.sh used to be a
# HARDCODED "DEFERRED" whose detail asserted that the wiki image pins were
# byte-identical to the ones v1.0.74 verified. That string ended with its own
# escape clause -- "if a future cut moves either pin, this row is a lie" -- and
# v1.0.101 moved both pins to the v0.1.34 images. Measured then: the two
# digests it named scored 0 in install.sh while the live pin scored 1.
#
# A VERDICT PRINTED FROM A STRING LITERAL CANNOT GO RED. The condition lived in
# a comment addressed to a human, and no human re-checked it across the cuts in
# between. This test exists so the row cannot go back to being asserted: it
# drives the real block from the real script against three synthetic trees and
# requires three DIFFERENT answers.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="${HERE}/scripts/pre_tag_live_checks.sh"
pass=0; fail=0
ok()   { printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

block="$(sed -n '/^# The digests that a previous cut/,/^fi$/p' "$SUBJECT")"
if [ -z "$block" ]; then
	printf '  [FAIL] CANNOT-RUN: the computed block was not found in %s\n' "$SUBJECT"
	printf '\n== 0 pass / 1 fail ==\n'; exit 2
fi

run_case () {  # $1 = install.sh content -> prints "VERDICT|detail"
	local d; d="$(mktemp -d)"
	printf '%s\n' "$1" > "${d}/install.sh"
	{ printf 'row () { printf "%%s|%%s\\n" "$2" "$3"; }\n'; printf '%s\n' "$block"; } > "${d}/run.sh"
	( cd "$d" && bash run.sh )
	rm -rf "$d"
}

UNCH="$(run_case 'image: ghcr.io/x/ostler-wiki-site@sha256:77eee04f13b1aaaa
image: ghcr.io/x/ostler-wiki-compiler@sha256:64debb2e2209bbbb')"
MOVED="$(run_case 'image: ghcr.io/x/ostler-wiki-site@sha256:52bd37a1bbfc1111
image: ghcr.io/x/ostler-wiki-compiler@sha256:7cd2dd8b73f22222')"
BLIND="$(run_case 'no image lines here at all')"

case "$UNCH"  in DEFERRED\|*already\ passed*) ok "pins UNCHANGED -> DEFERRED, and says the cut is RE-checking";;
                 *) bad "pins unchanged gave: ${UNCH:0:90}";; esac
case "$MOVED" in DEFERRED\|*PINS\ HAVE\ MOVED*) ok "pins MOVED -> DEFERRED, and says NO previous cut has seen them";;
                 *) bad "pins moved gave: ${MOVED:0:90}";; esac
case "$BLIND" in CANNOT-RUN\|*)                 ok "pins UNREADABLE -> CANNOT-RUN, not DEFERRED and not a pass";;
                 *) bad "unreadable gave: ${BLIND:0:90}";; esac

# The point of the whole exercise: the three cases must not agree.
if [ "$UNCH" != "$MOVED" ] && [ "$MOVED" != "$BLIND" ] && [ "$UNCH" != "$BLIND" ]; then
	ok "THE DISCRIMINATOR: all three inputs produce DIFFERENT output, so the verdict is computed"
else
	bad "two or more cases produced identical output -- the verdict is not reading its input"
fi

# A control that must FAIL if the row is ever re-hardcoded.
if printf '%s' "$block" | grep -q 'install.sh'; then
	ok "CONTROL: the block still reads install.sh rather than asserting a constant"
else
	bad "the block no longer reads install.sh -- it has been re-hardcoded"
fi

printf '\n== %d pass / %d fail ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
