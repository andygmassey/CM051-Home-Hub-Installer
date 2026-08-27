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
# 🔴 THE PLATFORM MATRIX, ALL THREE MEASURED, NONE ASSUMED:
#
#   this developer Mac (UnZip 6.00, Darwin 25.4)  inverts 5/5 from 501 entries
#   ubuntu-latest runner                          0/5 at every rung to 1.44 MB
#   macos-latest runner                           0/5 at every rung to 1.44 MB
#
# So the defect is real, and NEITHER HOSTED RUNNER CAN WITNESS IT. See the
# workflow: this file is a REPORTER in CI, not a gate, and it says so.
#
# 🔴 AND ON LINUX 801 ENTRIES INVERTS 0/5. Measured on an ubuntu-latest runner,
# not reasoned about: the first CI run of this file failed its own positive
# control and said so. The floor is set by how much of the listing the kernel
# will absorb before unzip blocks, and that differs between Darwin and Linux.
# Which is why the size below is a LADDER that climbs until the control fires,
# and reports CANNOT-RUN if none of the rungs do.
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
# CANNOT-RUN IS A THIRD STATE AND GETS ITS OWN EXIT CODE. Collapsing it into 0
# would be the exact defect this whole family is about; collapsing it into 1
# would make a platform that cannot host the measurement look like a product
# defect. 3, and the caller decides.
cannot_run() { printf '  CANNOT-RUN  %s\n\n0 passed, 0 failed, 1 could not run\n' "$*"; exit 3; }

DETECT="lib/ostler-detect-exports.sh"
[ -f "$DETECT" ] || { bad "detector not found at ${DETECT} -- nothing to measure"; finish; }
command -v zip >/dev/null 2>&1   || cannot_run "no zip(1), so no fixture can be built."
command -v unzip >/dev/null 2>&1 || cannot_run "no unzip(1)."

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# THE FLOOR IS PLATFORM-DEPENDENT, SO IT IS MEASURED, NOT HARDCODED.
#
# A fixed 800 was measured on macOS (floor 501) and PROVED WRONG ON LINUX: the
# first CI run of this file reported "inverted only 0/5 on 801 entries" and
# failed rather than banking a green -- which is the file working, not the file
# broken. The mechanism is the PIPE BUFFER: unzip only takes SIGPIPE if it is
# still writing when grep exits, so the listing has to exceed what the kernel
# will absorb, and that size differs between Darwin and Linux.
#
# So the ladder escalates until the POSITIVE CONTROL fires, and reports
# CANNOT-RUN if none of the rungs do. The size that works is then printed --
# a number nobody has to trust from a comment.
FILLER_LADDER=(800 8000 30000 80000)

printf '\n=== export detection: a LARGE zip must still be detected ===\n\n'

# --- build ------------------------------------------------------------------
# `zip` records members in the order it is GIVEN them, so naming the signature
# first is what puts it at line 1 of the listing.
build_zip() {  # $1=out  $2=first|last  $3=with|no-signature  $4=filler count
    local out="$1" where="$2" sig="$3" n="$4" d
    d="$TMP/src.$$.$RANDOM"; mkdir -p "$d"
    python3 - "$d" "$n" <<'PY'
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

# --- 1. POSITIVE CONTROL ON THE PREMISE, AT A SIZE THAT IS MEASURED ---------
# Climb until the pre-fix construct actually inverts. A fixture on which it
# does NOT invert cannot tell the fix from the bug, so limb 2's green would be
# worthless -- and the whole file exists because a too-small fixture is exactly
# how tests/test_gdpr_export_detect.sh passed identically before and after the
# fix it was supposed to be guarding.
BIG="$TMP/my-linkedin-export.zip"
FILLER=""; INV=0; ENTRIES=0; SIGLINE=0; LADDER_TRIED=""
for _n in "${FILLER_LADDER[@]}"; do
    build_zip "$BIG" first with-signature "$_n"
    ENTRIES="$(unzip -Z1 "$BIG" | grep -c '')"
    LISTING="$(unzip -Z1 "$BIG" | wc -c | tr -d ' ')"
    INV="$(old_form_inverts "$BIG")"
    LADDER_TRIED="${LADDER_TRIED}${LADDER_TRIED:+, }${ENTRIES}e/${LISTING}B->${INV}/5"
    if [ "$INV" -eq 5 ]; then FILLER="$_n"; break; fi
done
SIGLINE="$(unzip -Z1 "$BIG" | grep -n 'Connections\.csv' | cut -d: -f1)"

if [ -n "$FILLER" ]; then
    ok "POSITIVE CONTROL: the pre-fix 'unzip -Z1 | grep -q' inverts 5/5 at ${ENTRIES} entries / ${LISTING} B listing, signature at line ${SIGLINE} [ladder: ${LADDER_TRIED}]"
else
    cannot_run "no rung of the ladder made the pre-fix construct invert [${LADDER_TRIED}]. This platform's unzip does not die on SIGPIPE at any listing size tried, so limb 2 cannot distinguish the fix from the bug HERE. That is NOT a pass and NOT a product defect -- it is a host that cannot host the measurement. Exit 3."
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
build_zip "$LAST" last with-signature "$FILLER"
INV_LAST="$(old_form_inverts "$LAST")"
if [ "$INV_LAST" -eq 0 ]; then
    ok "DISCRIMINATOR: same size, signature LAST -> the old form does NOT invert (0/5). Position, not size, is the mechanism"
else
    bad "DISCRIMINATOR: signature-last inverted ${INV_LAST}/5, so this file's account of the mechanism is wrong and the comment block above is misleading."
fi

# --- 4. NEGATIVE CONTROL ----------------------------------------------------
# A detector that unzipped everything would pass limb 2 while detecting nothing.
NOSIG="$TMP/Downloads/holiday-photos.zip"
build_zip "$NOSIG" first no-signature "$FILLER"
bash "$DETECT" "$DL" --unzip >/dev/null 2>&1 || true
if [ -d "$TMP/Downloads/holiday-photos" ]; then
    bad "NEGATIVE CONTROL: a zip with NO signature was unzipped too, so limb 2 is satisfied by 'unzip everything' and proves nothing about detection."
else
    ok "NEGATIVE CONTROL: a same-size zip with NO signature is left alone -- limb 2 measures detection, not blanket extraction"
fi

finish
