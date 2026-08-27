#!/usr/bin/env bash
# THE CONSTRUCT IS GUARDED. THE BEHAVIOUR WAS NOT.
#
# #889/#1124 fixed two sites where `unzip -Z1 "$z" | grep -qiE ...` under
# `pipefail` inverts: grep exits 0 on first match, the pipe closes, unzip dies
# with SIGPIPE (141), pipefail promotes 141 to the pipeline status, and the
# `if` reads FALSE on an archive that DOES carry a signature. The customer
# symptom is silent: a real export sits in ~/Downloads and is never unzipped,
# so every parser downstream sees nothing and nothing says why.
#
# What guards it today is tests/pipefail_shortcircuit_baseline.txt -- a ratchet
# over the TEXT of the construct. That stops the pattern spreading. It cannot
# tell you the DETECTOR WORKS, and it would go green against a detector that
# had been rewritten into some new way of failing.
#
# The existing tests/test_gdpr_export_detect.sh builds its fixture from a
# handful of files. Measured: a zip that small does not invert, so that test
# passed identically BEFORE and AFTER #1124. It cannot distinguish the fix from
# the bug, which is precisely the residual this file closes.
#
# ============================================================================
# WHAT MAKES THE FIXTURE LOAD-BEARING -- MEASURED, NOT ASSUMED
# ============================================================================
#
# On macOS 15 / UnZip 6.00, in bash, with the signature member FIRST:
#
#   entries   listing bytes   old `| grep -q` form inverted
#   501       6,016           5/5
#   2001      24,016          5/5
#   20001     240,016         5/5
#
# and with the SAME 20,001 entries but the signature LAST: 0/5.
#
# SIZE IS NOT THE DISCRIMINATOR. MATCH POSITION IS. A match near the start lets
# grep exit while unzip is still writing; a match at the end means grep has
# already consumed everything and there is no reader to lose. That is why the
# fixture below puts the signature member first and why limb 3 proves the
# last-position case does NOT invert -- without that, someone would "simplify"
# the fixture and quietly turn limb 1 into a formality.
#
# 🔴 A NOTE ON THE HARNESS ITSELF. The first time these numbers were taken the
# probe ran under zsh and reported 0/5 for everything -- including the printf
# control that is KNOWN to invert. The control failing is what exposed it: the
# reading was CANNOT-RUN, not PASS. This file is `#!/usr/bin/env bash` and limb
# 1 re-proves the premise on every run for the same reason.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }
finish() { printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ] || exit 1; exit 0; }

DETECT="lib/ostler-detect-exports.sh"
[ -f "$DETECT" ] || { bad "detector not found at ${DETECT} -- nothing to measure"; finish; }
command -v zip >/dev/null 2>&1 || { bad "CANNOT-RUN: no zip(1), so no fixture can be built. This is not a pass."; finish; }
command -v unzip >/dev/null 2>&1 || { bad "CANNOT-RUN: no unzip(1). This is not a pass."; finish; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FILLER=800   # comfortably above the measured 501-entry floor, still ~1s to build

printf '\n=== export detection: a LARGE zip must still be detected ===\n\n'

# --- build ------------------------------------------------------------------
# `zip` records members in the order it is GIVEN them, so naming the signature
# first is what puts it at line 1 of the listing.
build_zip() {  # $1=out  $2=first|last  $3=with-signature|no-signature
    local out="$1" where="$2" sig="$3" d
    d="$TMP/src.$$.$RANDOM"; mkdir -p "$d"
    python3 - "$d" "$FILLER" <<'PY'
import sys, os
d, n = sys.argv[1], int(sys.argv[2])
for i in range(n):
    open(os.path.join(d, "filler_%06d.txt" % i), "w").close()
PY
    [ "$sig" = with-signature ] && : > "$d/Connections.csv"
    rm -f "$out"
    if [ "$sig" = with-signature ] && [ "$where" = first ]; then
        ( cd "$d" && zip -q "$out" Connections.csv && zip -qr "$out" . -x Connections.csv )
    elif [ "$sig" = with-signature ]; then
        ( cd "$d" && zip -qr "$out" . -x Connections.csv && zip -q "$out" Connections.csv )
    else
        ( cd "$d" && zip -qr "$out" . )
    fi
    rm -rf "$d"
}

# The pre-fix construct, reproduced verbatim so limb 1 measures the real thing.
old_form_inverts() {  # $1=zip -> prints N of 5
    local z="$1" inv=0 r
    for r in 1 2 3 4 5; do
        ( set -o pipefail; unzip -Z1 "$z" 2>/dev/null | grep -qiE 'Connections\.csv' ) || inv=$((inv+1))
    done
    printf '%s' "$inv"
}

BIG="$TMP/my-linkedin-export.zip"
build_zip "$BIG" first with-signature
ENTRIES="$(unzip -Z1 "$BIG" | grep -c '')"
SIGLINE="$(unzip -Z1 "$BIG" | grep -n 'Connections\.csv' | cut -d: -f1)"

# --- 1. POSITIVE CONTROL ON THE PREMISE -------------------------------------
# If the old construct does NOT invert on this fixture, the fixture is too
# small or the platform behaves differently, and limb 2 proves nothing. Say so
# instead of banking a green.
INV="$(old_form_inverts "$BIG")"
if [ "$INV" -eq 5 ]; then
    ok "POSITIVE CONTROL: the pre-fix 'unzip -Z1 | grep -q' inverts 5/5 on this fixture (${ENTRIES} entries, signature at line ${SIGLINE})"
else
    bad "POSITIVE CONTROL: the pre-fix construct inverted only ${INV}/5 on ${ENTRIES} entries. The fixture cannot tell the fix from the bug, so limb 2's green would be worthless. Raise FILLER, or investigate whether this platform's unzip ignores SIGPIPE."
    finish
fi

# --- 2. THE BEHAVIOUR -------------------------------------------------------
# The thing a customer actually cares about: the detector unzips it.
DL="$TMP/Downloads"; mkdir -p "$DL"; cp "$BIG" "$DL/"
bash "$DETECT" "$DL" --unzip >/dev/null 2>&1 || true
if [ -d "$DL/my-linkedin-export" ]; then
    ok "BEHAVIOUR: a ${ENTRIES}-entry signature-bearing zip IS auto-unzipped by ${DETECT}"
else
    bad "BEHAVIOUR: a ${ENTRIES}-entry signature-bearing zip was NOT unzipped. This is the #889 customer symptom, live: a real export sits in Downloads and every parser downstream sees nothing."
fi

# --- 3. MATCH POSITION IS THE DISCRIMINATOR, NOT SIZE -----------------------
# Guards the FIXTURE. Without this, shrinking or reordering it would silently
# turn limb 1 into a formality that always passes.
LAST="$TMP/sig-last.zip"
build_zip "$LAST" last with-signature
INV_LAST="$(old_form_inverts "$LAST")"
if [ "$INV_LAST" -eq 0 ]; then
    ok "DISCRIMINATOR: same size, signature LAST -> the old form does NOT invert (0/5). Position, not size, is the mechanism"
else
    bad "DISCRIMINATOR: signature-last inverted ${INV_LAST}/5, so this file's account of the mechanism is wrong and the comment block above is misleading."
fi

# --- 4. NEGATIVE CONTROL ----------------------------------------------------
# A detector that unzipped everything would pass limb 2 while detecting nothing.
NOSIG="$TMP/Downloads/holiday-photos.zip"
build_zip "$NOSIG" first no-signature
bash "$DETECT" "$DL" --unzip >/dev/null 2>&1 || true
if [ -d "$TMP/Downloads/holiday-photos" ]; then
    bad "NEGATIVE CONTROL: a zip with NO signature was unzipped too, so limb 2 is satisfied by 'unzip everything' and proves nothing about detection."
else
    ok "NEGATIVE CONTROL: a same-size zip with NO signature is left alone -- limb 2 measures detection, not blanket extraction"
fi

finish
