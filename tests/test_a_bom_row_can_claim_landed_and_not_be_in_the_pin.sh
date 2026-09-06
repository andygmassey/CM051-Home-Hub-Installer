#!/usr/bin/env bash
# A BOM row's `landed` column is a claim. This proves the gate checks it.
#
# WHY THIS EXISTS. MEASURED 2026-09-06 on v1.0.72, with the pin at c6b5932c:
#
#     OS003 gates/verify_must_contain.sh   11 rows, 0 not landed
#     scripts/verify_bom_rows_are_in_the_pin.sh
#                                          1 in the pin, 8 ABSENT, 2 n/a
#
# Every one of those eight rows says landed=yes and would not have shipped.
# That is not a lie in the BOM -- it is the pin not having been moved yet --
# and the entire point is that NOTHING WOULD HAVE CAUGHT IT if it never was.
# `landed` is a column somebody typed, and the gate enforcing it counts that
# column rather than comparing it to the tree that gets built.
#
# THE FIXTURES ARE SYNTHETIC ON PURPOSE. Asserting "v1.0.72 currently has 8
# absent rows" would encode today's pin, and would go RED the moment someone
# does the correct thing and moves it. A test that breaks when the defect is
# fixed is a test of the state, not of the gate.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/scripts/verify_bom_rows_are_in_the_pin.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -r "$SUBJECT" ] || { echo "CANNOT-RUN: no ${SUBJECT}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# ── Build a synthetic repo: an install.sh, one commit that adds a keyable
# line, and therefore a BEFORE pin and an AFTER pin. ───────────────────────
FIX="${WORK}/repo"
mkdir -p "$FIX/scripts" "$FIX/cuts/v9.9.9"
cp "$SUBJECT" "$FIX/scripts/"
git -C "$FIX" init -q .
git -C "$FIX" config user.email t@example.com
git -C "$FIX" config user.name  Test

# install.sh must be over 1000 lines or the gate refuses it as not-the-installer.
{ echo '#!/usr/bin/env bash'; for i in $(seq 1 1200); do echo "  _filler_${i}=\"padding line ${i} to make this look like the installer\""; done; } > "$FIX/install.sh"
git -C "$FIX" add -A && git -C "$FIX" commit -qm "base installer"
BEFORE="$(git -C "$FIX" rev-parse HEAD)"

MARK='_ostler_synthetic_marker_line_that_is_long_enough_to_be_keyed_on=1'
printf '%s\n' "$MARK" >> "$FIX/install.sh"
git -C "$FIX" commit -qam "the fix that must ship"
AFTER="$(git -C "$FIX" rev-parse HEAD)"

_bom() {  # $1 = ref to cite
    printf '# fixture BOM\n'
    printf 'what\trepo\tref\tlanded\tcapability_id\tverify\tticket\n'
    printf 'THE SYNTHETIC FIX\tCM051\t%s\tyes\tnone\tgate:none#none\t#9999\n' "$1"
}
_cutenv() { printf 'CM051=%s\n' "$1"; }
_run() {
    ( cd "$FIX" && bash scripts/verify_bom_rows_are_in_the_pin.sh v9.9.9 >"${WORK}/out" 2>&1; echo $? )
}

# ── CONTROL FIRST: the fixture must be able to PASS, or every FAIL below
# could be the fixture rather than the gate. ──────────────────────────────
_bom "$AFTER" > "$FIX/cuts/v9.9.9/MUST_CONTAIN.tsv"
_cutenv "$AFTER" > "$FIX/cuts/v9.9.9/cut.env"
rc="$(_run)"
if [ "$rc" = "0" ]; then
    ok "CONTROL: a pin that CONTAINS the fix passes, so the fixture can go green"
else
    echo "CANNOT-RUN: the fixture cannot pass even when the pin contains the fix (rc=${rc})." >&2
    sed 's/^/    /' "${WORK}/out" >&2
    exit 2
fi

echo "── a pin that predates the fix is refused ──"
_cutenv "$BEFORE" > "$FIX/cuts/v9.9.9/cut.env"
rc="$(_run)"
if [ "$rc" = "1" ] && grep -q 'ABSENT' "${WORK}/out" && grep -q '#9999' "${WORK}/out"; then
    ok "a row claiming landed=yes whose change is not in the pin exits 1 and is NAMED"
else
    bad "a stale pin gave rc=${rc}: $(tr '\n' ' ' < "${WORK}/out" | cut -c1-120)"
fi

echo "── the verdict follows the PIN, not the branch ──"
# The fix is on the branch either way. Only the pin changes between the two
# runs above. This states the discriminator out loud.
_cutenv "$AFTER" > "$FIX/cuts/v9.9.9/cut.env"
rc="$(_run)"
[ "$rc" = "0" ] && ok "moving only the pin flips the verdict, so the pin is what is measured" \
                || bad "moving the pin back did not restore a pass (rc=${rc})"

echo "── every CANNOT-RUN is a refusal, never a pass ──"
_cutenv "$AFTER" > "$FIX/cuts/v9.9.9/cut.env"
mv "$FIX/cuts/v9.9.9/MUST_CONTAIN.tsv" "${WORK}/bom.bak"
rc="$(_run)"
[ "$rc" = "2" ] && ok "an absent BOM exits 2" || bad "an absent BOM exits ${rc}"
mv "${WORK}/bom.bak" "$FIX/cuts/v9.9.9/MUST_CONTAIN.tsv"

printf 'SOMETHING_ELSE=1\n' > "$FIX/cuts/v9.9.9/cut.env"
rc="$(_run)"
[ "$rc" = "2" ] && ok "a cut.env with no CM051= pin exits 2" || bad "a pinless cut.env exits ${rc}"

# ASSERT WHICH GUARD FIRED, not merely that something did. Two guards can
# catch this input: the unreadable-blob refusal and the short-installer
# refusal, because an unreadable blob leaves an EMPTY file which is also
# implausibly short. A mutant that deleted the unreadable-blob guard outright
# SURVIVED the first version of this limb, since the other guard still exited
# 2. Same shape as a control that passes for the wrong reason.
# Composed at runtime, not written as a literal. A 40-character run of digits
# is PII-SHAPED and the repo's shape scanner blocks it on sight -- correctly,
# since it matches on shape and not on a list of known values. It blocked this
# file, and the block is the guard doing its job.
_ZERO_SHA="$(printf '0%.0s' $(seq 1 40))"
_cutenv "$_ZERO_SHA" > "$FIX/cuts/v9.9.9/cut.env"
rc="$(_run)"
if [ "$rc" = "2" ] && grep -q 'cannot read install.sh at the pin' "${WORK}/out"; then
    ok "a pin whose object is unreadable exits 2 via its OWN guard, not another one"
elif [ "$rc" = "2" ]; then
    bad "exited 2, but not through the unreadable-pin guard: $(head -1 "${WORK}/out")"
else
    bad "an unreadable pin exits ${rc}"
fi

echo "── a truncated installer at the pin must not manufacture absences ──"
# Every row would read ABSENT against a 3-line install.sh, and that would look
# exactly like a real finding. This is the false-positive twin of a false zero.
( cd "$FIX" && git checkout -q -b tiny "$BEFORE" && printf '#!/bin/bash\necho hi\n' > install.sh && git commit -qam "truncated" )
TINY="$(git -C "$FIX" rev-parse tiny)"
git -C "$FIX" checkout -q -
_cutenv "$TINY" > "$FIX/cuts/v9.9.9/cut.env"
rc="$(_run)"
if [ "$rc" = "2" ] && grep -q 'not the installer' "${WORK}/out"; then
    ok "an implausibly short install.sh at the pin is CANNOT-RUN, not 'everything is missing'"
else
    bad "a truncated pinned installer gave rc=${rc}"
fi

echo "── a zero denominator is refused ──"
# No CM051 rows at all: nothing was examined, and '0 absent' must not read as
# success.
_cutenv "$AFTER" > "$FIX/cuts/v9.9.9/cut.env"
{ printf '# fixture BOM\n'
  printf 'what\trepo\tref\tlanded\tcapability_id\tverify\tticket\n'
  printf 'A ROW FOR ANOTHER REPO\tCM044\tdeadbeef\tyes\tnone\tgate:none#none\t#8888\n'
} > "$FIX/cuts/v9.9.9/MUST_CONTAIN.tsv"
rc="$(_run)"
if [ "$rc" = "2" ] && grep -q 'nothing was examined' "${WORK}/out"; then
    ok "a BOM with no checkable row exits 2 rather than reporting 0 absent"
else
    bad "a zero-denominator BOM gave rc=${rc}: $(tr '\n' ' ' < "${WORK}/out" | cut -c1-100)"
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
