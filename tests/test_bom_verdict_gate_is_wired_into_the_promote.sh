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
