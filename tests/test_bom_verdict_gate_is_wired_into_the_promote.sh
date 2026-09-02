#!/usr/bin/env bash
#
# THE BOM-VERDICT GATE MUST BE INVOKED, NOT MERELY PRESENT.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# CM051 #1322 added scripts/verify_must_contain_has_box_verdict.sh -- 137 lines
# that refuse a cut claiming rows it has not proven -- and wired it to NOTHING.
# Measured on origin/main @82a2d4fd the morning after it merged:
#
#   grep -rn verify_must_contain_has_box_verdict .   ->  0 hits
#   CONTROL, same grep, same tree: verify_walk_record ->  found in tests/,
#                                                        cut-manifests/, walks/
#
# The control fires, so that zero is real: the script existed and nothing ran
# it. That is #449's class exactly (run_all_cut_gates.sh, invoked by nothing),
# committed by the same author who had recorded #449 as a lesson.
#
# A GATE THAT IS NOT INVOKED IS INDISTINGUISHABLE FROM A GATE THAT PASSES.
#
# ---------------------------------------------------------------------------
# TWO HALVES, AND THIS TEST IS HONEST ABOUT WHICH IS WHICH
# ---------------------------------------------------------------------------
# HALF 1 (BEHAVIOURAL): the gate is run against two real registers and its
#   exit code is read. This is a measurement.
#
# HALF 2 (WIRING, and it is WEAKER -- say so): publish_release.sh is read and
#   asserted to name the gate and to set PROMOTE=0 on a non-zero result. This
#   is a SOURCE assertion, not a behavioural one. It CANNOT prove the promote
#   is actually withheld, because that needs a real release run with gh, a
#   signed DMG and a repo. What it CAN do is fail the moment someone deletes
#   the call or softens it to a warning -- which is the regression that
#   actually happened. Its limit is stated here rather than left for a reader
#   to discover.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HERE}/.."
GATE="${ROOT}/scripts/verify_must_contain_has_box_verdict.sh"
PUBLISH="${ROOT}/scripts/publish_release.sh"

for f in "$GATE" "$PUBLISH"; do
    if [ ! -r "$f" ]; then
        printf 'CANNOT-RUN: not readable: %s\n' "$f" >&2
        exit 2
    fi
done

fail=0

# --- HALF 1: BEHAVIOURAL. The gate must REFUSE an unproven register. ---------
#
# The subject is the REAL v1.0.58 register, not a synthetic one: 9 rows, 9 with
# verify=TBD, shipped exactly like that. If this register ever stops being
# refused, the gate has been gutted.
if [ -r "${ROOT}/cuts/v1.0.58/MUST_CONTAIN.tsv" ]; then
    set +e
    "$GATE" v1.0.58 >/dev/null 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 1 ]; then
        printf '  behaviour+ OK   the REAL v1.0.58 register (9 rows, 9 TBD) is REFUSED, rc=1\n'
    else
        printf '  behaviour+ FAIL v1.0.58 register returned rc=%s, expected 1 (refused).\n' "$rc" >&2
        printf '                  The gate no longer refuses the register that motivated it.\n' >&2
        fail=1
    fi
else
    # Absence is not a pass. If the motivating register is gone this test has
    # lost its subject and must say so rather than quietly skipping.
    printf 'CANNOT-RUN: cuts/v1.0.58/MUST_CONTAIN.tsv is absent -- that register\n' >&2
    printf '            IS the behavioural subject. No verdict.\n' >&2
    exit 2
fi

# --- HALF 1b: BEHAVIOURAL. The gate must ACCEPT a register that IS proven. ---
#
# Without this arm, a gate that refuses EVERYTHING would pass the arm above.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "${tmp}/cuts/v9.9.9" "${tmp}/scripts"
cp "$GATE" "${tmp}/scripts/"
printf 'what\trepo\tref\tlanded\tcapability_id\tverify\tticket\n' \
    > "${tmp}/cuts/v9.9.9/MUST_CONTAIN.tsv"
printf 'a proven row\tcm051\tdeadbeef\tyes\tsome_capability\tgate:store-auth-pth-final-dir.yml#store-auth-pth-final-dir\tarchie\n' \
    >> "${tmp}/cuts/v9.9.9/MUST_CONTAIN.tsv"
set +e
"${tmp}/scripts/verify_must_contain_has_box_verdict.sh" v9.9.9 >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    printf '  behaviour- OK   a register whose row NAMES a verdict is ACCEPTED, rc=0\n'
else
    printf '  behaviour- FAIL a proven register returned rc=%s, expected 0.\n' "$rc" >&2
    printf '                  A gate that refuses everything proves nothing.\n' >&2
    fail=1
fi

# --- HALF 2: WIRING. Weaker by construction -- see the header. ---------------
if /usr/bin/grep -q 'verify_must_contain_has_box_verdict\.sh' "$PUBLISH"; then
    printf '  wiring     OK   publish_release.sh names the gate\n'
else
    printf '  wiring     FAIL publish_release.sh does NOT invoke the gate.\n' >&2
    printf '                  This is the exact state #1322 shipped in: the script\n' >&2
    printf '                  exists and nothing runs it.\n' >&2
    fail=1
fi

# The call must DEMOTE, not merely warn. A gate whose failure only prints is a
# gate that passes.
if /usr/bin/grep -q 'withholding the promote' "$PUBLISH"; then
    printf '  demote     OK   a non-zero result withholds the promote\n'
else
    printf '  demote     FAIL the gate is called but its failure does not set PROMOTE=0.\n' >&2
    fail=1
fi

# Fail CLOSED when the gate is absent, same rule the walk gate already follows.
if /usr/bin/grep -q 'treating as NO row evidence' "$PUBLISH"; then
    printf '  failclosed OK   an ABSENT gate reads as no evidence, not as a pass\n'
else
    printf '  failclosed FAIL an absent gate would read as satisfied -- that is how a\n' >&2
    printf '                  deleted check becomes a silent promotion.\n' >&2
    fail=1
fi

# --- HALF 3: THE WALK CARD. Behavioural, and it must not be a loophole. -----
#
# ANDY, 2026-09-02: "I'm beyond fed up with keep making DMGs and doing a walk
# and then hearing that stuff hasn't been fixed that I was told it had. That
# stops NOW."
#
# `needs-walk:` gives a row an honest third state so it reaches him DECLARED
# rather than as a surprise. These arms exist because that state is also the
# easiest thing here to abuse -- mark everything needs-walk and the gate goes
# green having proven nothing.
tmp3="$(mktemp -d)"
trap 'rm -rf "$tmp" "$tmp3"' EXIT
mkdir -p "${tmp3}/cuts/v7.7.7" "${tmp3}/scripts"
cp "$GATE" "${tmp3}/scripts/"
_G3="${tmp3}/scripts/verify_must_contain_has_box_verdict.sh"
_hdr() { printf 'what\trepo\tref\tlanded\tcapability_id\tverify\tticket\n' > "${tmp3}/cuts/v7.7.7/MUST_CONTAIN.tsv"; }
_row() { printf '%s\tcm051\tdeadbeef\tyes\tcap\t%s\tarchie\n' "$1" "$2" >> "${tmp3}/cuts/v7.7.7/MUST_CONTAIN.tsv"; }

# 3a. A mixed register passes AND the card names both buckets.
_hdr; _row 'proven thing' 'gate:test-wiring.yml#test-wiring'
      _row 'human-only thing' 'needs-walk:v7.7.7#open-Settings-check-no-Advanced'
set +e; out3="$("$_G3" --walk-card v7.7.7 2>&1)"; rc3=$?; set -e
if [ "$rc3" -eq 0 ] \
   && printf '%s' "$out3" | grep -q 'ALREADY PROVEN BEFORE THIS DMG REACHED YOU (1)' \
   && printf '%s' "$out3" | grep -q 'YOU ARE THE INSTRUMENT (1)' \
   && printf '%s' "$out3" | grep -q 'open-Settings-check-no-Advanced'; then
    printf '  card       OK   both buckets printed, and the unproven row names what to check\n'
else
    printf '  card       FAIL --walk-card did not print the two buckets. rc=%s\n' "$rc3" >&2
    fail=1
fi

# 3b. ANTI-VACUITY. All-needs-walk is a wishlist, not a cut.
_hdr; _row 'a' 'needs-walk:v7.7.7#look-a'; _row 'b' 'needs-walk:v7.7.7#look-b'
set +e; out3b="$("$_G3" v7.7.7 2>&1)"; rc3b=$?; set -e
if [ "$rc3b" -eq 1 ] && printf '%s' "$out3b" | grep -q 'NOT ONE names real evidence'; then
    printf '  vacuity    OK   a register that proves NOTHING is refused\n'
else
    printf '  vacuity    FAIL all-needs-walk returned rc=%s, expected 1.\n' "$rc3b" >&2
    printf '                  Without this, needs-walk is a green button.\n' >&2
    fail=1
fi

# 3c. A needs-walk that does not say WHAT TO LOOK AT is a shrug, not a
#     declaration, and must be refused exactly like TBD was.
_hdr; _row 'proven thing' 'gate:x.yml#y'; _row 'shrug' 'needs-walk:v7.7.7'
set +e; out3c="$("$_G3" v7.7.7 2>&1)"; rc3c=$?; set -e
if [ "$rc3c" -eq 1 ]; then
    printf '  shrug      OK   needs-walk with no #what is refused\n'
else
    printf '  shrug      FAIL a contentless needs-walk was accepted (rc=%s).\n' "$rc3c" >&2
    fail=1
fi

printf '\n'
if [ "$fail" -ne 0 ]; then
    printf 'FAIL: the BOM-verdict gate is not wired into the promote as specified.\n' >&2
    exit 1
fi
printf 'PASS: gate refuses the real unproven register, accepts a proven one, and\n'
printf '      publish_release.sh invokes it, demotes on failure, and fails closed\n'
printf '      when it is missing. (The wiring half is a SOURCE assertion -- it\n'
printf '      cannot prove a live promote was withheld. Stated, not hidden.)\n'
exit 0
