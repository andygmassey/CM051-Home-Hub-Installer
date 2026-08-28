#!/usr/bin/env bash
#
# tests/test_loopback_property_fires.sh
#
# PROOF OF LIFE for tests/test_v1010_store_auth_loopback.sh.
#
# That test passing proves nothing on its own -- it would pass
# identically if its predicates were broken. This harness mutates
# install.sh into each defect it claims to catch and requires the
# verdict to flip, then restores and requires green again.
#
# It also proves the OPPOSITE direction, which is the whole point of
# the 2026-08-28 rewrite: the security assertions must be MONOTONE with
# #550. Making a store LESS reachable, or turning enforcement ON, must
# never red them.
#
# ⚠️ NO `sed -i`. GNU wants `sed -i` and BSD wants `sed -i ''`; a script
#    written on macOS with `sed -i ''` fails on ubuntu-latest and vice
#    versa. This estate already carries that class -- 34 gates asserting
#    on install.sh run GNU tools on Linux while install.sh only ever
#    runs under BSD on macOS. So: write to a temp file, then `cat` it
#    back over the original.
#
#    NOT `mv`. `mv` replaces the inode and the destination inherits the
#    TEMP FILE'S mode, which shell redirection creates at umask 644 --
#    silently stripping install.sh's 755 bit and leaving the tree dirty
#    after a green run. Measured here on 2026-08-28: the harness passed
#    all 8 arms and still left `M install.sh (old mode 100755, new mode
#    100644)`. `cat >` keeps the destination inode and its mode.
#
# ⚠️ EVERY ARM PROVES ITS MUTATION APPLIED before reading the verdict.
#    A mutation you have not proved applied is evidence in NEITHER
#    direction: rc=0 then means "nothing changed", not "the guard
#    failed". That error has been made twice in this repo in one day.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || { echo "FAIL: cannot cd to repo root -- CANNOT-RUN" >&2; exit 1; }

SUBJECT="tests/test_v1010_store_auth_loopback.sh"
INSTALL="install.sh"
[ -f "$SUBJECT" ] || { echo "FAIL: ${SUBJECT} not found -- CANNOT-RUN" >&2; exit 1; }
[ -f "$INSTALL" ]  || { echo "FAIL: ${INSTALL} not found -- CANNOT-RUN" >&2; exit 1; }

TMP="$(mktemp -d)"
cp "$INSTALL" "$TMP/install.pristine"
cp "$SUBJECT" "$TMP/subject.pristine"
restore() { cp "$TMP/install.pristine" "$INSTALL"; cp "$TMP/subject.pristine" "$SUBJECT"; }
trap 'restore; rm -rf "$TMP"' EXIT INT TERM

FAILED=0
arm=0
note() { echo "     $*"; }
bad()  { echo "FAIL: $*" >&2; FAILED=1; }

# Verdict of the subject: PASS or FAIL. Never `| grep -q`.
verdict() { if bash "$SUBJECT" >/dev/null 2>&1; then echo PASS; else echo FAIL; fi; }

# Count matches WITHOUT a pipe into grep -q. `grep -c` reads to EOF, so
# it cannot SIGPIPE its producer; a piped `grep -q` under pipefail can,
# and then reports absence for a needle that is present.
#
# No `2>/dev/null`: both files are asserted to exist above, so the only
# thing it could hide is a usage error, and swallowing that turns a
# broken predicate into a confident zero.
count() { grep -cE "$1" "$2" || true; }

# Replace a fixed string, portably, proving the write happened.
sub() {  # $1 file  $2 sed-expr
    sed "$2" "$1" > "$TMP/w" || return 1
    cat "$TMP/w" > "$1"   # NOT mv: mv replaces the inode AND its mode,
                          # so the 755 bit on install.sh is silently lost.
}

check() {  # $1 label  $2 want  $3 applied-proof-desc  $4 applied?(0/1)
    arm=$((arm + 1))
    if [ "$4" -ne 1 ]; then
        bad "arm ${arm} (${1}): MUTATION DID NOT APPLY (${3}).
      rc from the subject would mean nothing either way -- CANNOT-RUN."
        return
    fi
    got="$(verdict)"
    if [ "$got" = "$2" ]; then
        echo "ok: arm ${arm} -- ${1}: ${got} (want ${2}); ${3}"
    else
        bad "arm ${arm} (${1}): got ${got}, want ${2}. ${3}"
    fi
}

echo "── the subject must be green on the committed tree ──────────────"
check "unmutated baseline" PASS "control, no mutation" 1

echo ""
echo "── SECURITY assertions must still FIRE ──────────────────────────"

restore
sub "$INSTALL" 's|"127\.0\.0\.1:7878:7878"|"0.0.0.0:7878:7878"|'
n="$(count '"0\.0\.0\.0:7878:' "$INSTALL")"
check "7878 republished on 0.0.0.0" FAIL "0.0.0.0 lines now ${n}" "$([ "$n" -gt 0 ] && echo 1 || echo 0)"

restore
sub "$INSTALL" 's|"127\.0\.0\.1:7878:7878"|"7878:7878"|'
n="$(count '^[[:space:]]*-[[:space:]]*"7878:7878"' "$INSTALL")"
check "7878 bare map (binds all interfaces)" FAIL "bare lines now ${n}" "$([ "$n" -gt 0 ] && echo 1 || echo 0)"

restore
# DEFAULT-AGNOSTIC ON PURPOSE. This arm used to mutate the literal `:-0`, which
# silently stopped applying the moment the committed default became `:-1`
# (2026-08-28, the #550 flip). It did NOT read as a pass -- the harness caught
# it and reported MUTATION DID NOT APPLY / CANNOT-RUN, which is the whole
# reason that check exists. But a mutation arm that is one edit away from
# testing nothing is a trap, so it now matches EITHER default.
#
# The property under test was never "the default is 0". It is "the expansion
# is DEFAULTED AT ALL" -- a bare $OSTLER_STORE_AUTH_ENFORCE under `set -u` is
# an unbound-variable abort, and without `set -u` it is an empty string that
# silently takes the else-branch. Both are the gate's business; neither
# depends on which default is committed.
sub "$INSTALL" 's|OSTLER_STORE_AUTH_ENFORCE:-[01]|OSTLER_STORE_AUTH_ENFORCE|g'
n="$(count 'OSTLER_STORE_AUTH_ENFORCE:-[01]' "$INSTALL")"
check "enforcement switch default deleted" FAIL "defaulted expansions now ${n}" "$([ "$n" -eq 0 ] && echo 1 || echo 0)"

echo ""
echo "── MONOTONICITY: an enforce-state change must NOT red the gate ──"
echo "   (this is what the 2026-08-28 rewrite bought; the pre-rewrite"
echo "    form FAILED both of the next two arms)"

restore
# INVERTED 2026-08-28, and the inversion is the point. This arm used to mutate
# :-0 -> :-1 and assert PASS: "enforcement flipped ON (the actual #550 plan)".
# Once the flip LANDED, that mutation became a no-op on the committed tree --
# the arm still reported PASS, but it was passing on a tree it had not changed.
# A vacuous green is worse than a red: nothing reports it.
#
# So it now travels the only direction that is still a real edit: OFF, the
# opt-out. The assertion is unchanged in spirit -- a legitimate change of the
# enforcement state must not make this gate red, because this gate is about
# LOOPBACK PUBLICATION and not about who holds a credential.
sub "$INSTALL" 's|OSTLER_STORE_AUTH_ENFORCE:-1|OSTLER_STORE_AUTH_ENFORCE:-0|g'
n0="$(count 'OSTLER_STORE_AUTH_ENFORCE:-0' "$INSTALL")"
n1="$(count 'OSTLER_STORE_AUTH_ENFORCE:-1' "$INSTALL")"
check "enforcement flipped OFF (the opt-out escape hatch)" PASS \
      ":-1 now ${n1}, :-0 now ${n0}" "$([ "$n1" -eq 0 ] && [ "$n0" -gt 0 ] && echo 1 || echo 0)"

restore
sub "$INSTALL"  '/^[[:space:]]*-[[:space:]]*"127\.0\.0\.1:7878:7878"$/d'
# Two explicit patterns, NOT `/start/,+1d`: relative addressing (addr,+N)
# is a GNU extension and BSD sed rejects it. The row is two lines, so
# delete each by its own content. The applied-proof below counts the
# result, so a half-applied delete is caught rather than assumed.
sub "$SUBJECT"  '/^    "7878"   # store-proxy -> Oxigraph SPARQL. Same shape/d'
sub "$SUBJECT"  '/^             # answer is the proxy credential, not an unpublish\./d'
np="$(count '^[[:space:]]*-[[:space:]]*"[^"]*:7878"' "$INSTALL")"
nr="$(count '^[[:space:]]*"7878"' "$SUBJECT")"
check "7878 unpublished AND its functional row deleted" PASS \
      "publishes now ${np}, STILL_DEPENDED_ON rows for 7878 now ${nr}" \
      "$([ "$np" -eq 0 ] && [ "$nr" -eq 0 ] && echo 1 || echo 0)"

echo ""
echo "── the FUNCTIONAL half must still fire on a silent unpublish ────"

restore
sub "$INSTALL" '/^[[:space:]]*-[[:space:]]*"127\.0\.0\.1:7878:7878"$/d'
np="$(count '^[[:space:]]*-[[:space:]]*"[^"]*:7878"' "$INSTALL")"
nr="$(count '^[[:space:]]*"7878"' "$SUBJECT")"
check "7878 unpublished with the row LEFT IN PLACE" FAIL \
      "publishes ${np} but STILL_DEPENDED_ON still claims it (${nr} row)" \
      "$([ "$np" -eq 0 ] && [ "$nr" -gt 0 ] && echo 1 || echo 0)"

echo ""
echo "── restore, and the subject must be green again ─────────────────"
restore
np="$(count '^[[:space:]]*-[[:space:]]*"[^"]*:7878"' "$INSTALL")"
check "tree restored" PASS "7878 publishes back to ${np}" "$([ "$np" -gt 0 ] && echo 1 || echo 0)"

echo ""
if [ "$FAILED" -ne 0 ]; then
    echo "loopback property proof-of-life: FAIL" >&2
    exit 1
fi
echo "loopback property proof-of-life: PASS (${arm} arms)"
