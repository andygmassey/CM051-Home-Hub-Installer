#!/usr/bin/env bash
#
# A CUT MAY NOT CLAIM A ROW IT HAS NOT PROVEN ON A BOX.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS. ANDY, 2026-09-02, VERBATIM:
#
#   "So many examples of stuff I was told was fixed now appears not to be. And
#    I get crappy excuses like 'ohhh, but it was fixed one side'... Fixed is
#    fucking FIXED 100% completely and so that I never ever hear about it ever
#    again."
#
# He is right, and the register already encoded the failure as a data field.
# Measured on cuts/v1.0.58/MUST_CONTAIN.tsv the moment v1.0.58 was published:
#
#     data rows: 9        verify=TBD: 9
#
# NINE OF NINE. Every row in the BOM for a DMG that was cut, signed, notarised
# and published carried verify=TBD -- declared, never verified. The register
# was a list of INTENTIONS wearing the format of a list of FACTS.
#
# That is exactly how "I was told it was fixed" happens. Nobody lied in a
# sentence; the artefact simply shipped with its own evidence column empty and
# the empty column had no consequence.
#
# ---------------------------------------------------------------------------
# THE RULE THIS ENFORCES
#
#   MERGED is not FIXED. ON MAIN is not FIXED. IN THE DMG is not FIXED.
#   A row is FIXED when a named probe returned a verdict against the thing the
#   customer runs. Anything else is NOT FIXED and must be reported that way.
#
# So `verify` must name real evidence. The accepted shapes are deliberately
# narrow, and every one of them points at something a human can go and read:
#
#   walk:<version>#<probe>   a box-walk probe verdict in walks/<version>.tsv
#   box:<host>#<probe>       a probe run on a named box
#   artefact:<sha256-8>#<t>  measured on the published artefact itself
#   gate:<workflow>#<job>    a CI gate that FAILS on the real pre-fix tree
#
# ⚠️ `TBD`, `n/a`, `-`, `pending`, `assumed`, `merged`, `see PR`, and the empty
# string are ALL REFUSED. "merged" is refused ON PURPOSE: it is the single most
# common way a row gets called done, and it is a statement about a PR, not
# about the product.
#
# CANNOT-RUN (exit 2) is a third outcome and is never folded into pass or fail.
set -euo pipefail

CUT_VERSION="${1:-}"
if [ -z "${CUT_VERSION}" ]; then
    printf 'CANNOT-RUN: no cut version given. usage: %s <vX.Y.Z>\n' "$0" >&2
    exit 2
fi

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REG="${HERE}/../cuts/${CUT_VERSION}/MUST_CONTAIN.tsv"

if [ ! -r "${REG}" ]; then
    printf 'CANNOT-RUN: no register at cuts/%s/MUST_CONTAIN.tsv\n' "${CUT_VERSION}" >&2
    printf '            Absence of a register is not an empty register. A cut\n' >&2
    printf '            with nothing to prove has not been described yet.\n' >&2
    exit 2
fi

# A verdict must NAME ITS EVIDENCE. Anchored, so "walk:" alone cannot pass.
VERDICT_RE='^(walk:[^#]+#[^#]+|box:[^#]+#[^#]+|artefact:[0-9a-f]{8}#.+|gate:[^#]+#[^#]+)$'

_is_verdict() { printf '%s' "$1" | /usr/bin/grep -qE "${VERDICT_RE}"; }

# --- CONTROLS. A predicate that has not been shown to fire proves nothing. ---
_cf=0
for _good in 'walk:v1.0.59#store_auth_pth_final' 'box:macstudio-walk5#front_page_populates' \
             'artefact:a1b2c3d4#dmg_bytes_measured' 'gate:store-auth-pth-final-dir.yml#store-auth-pth-final-dir'; do
    _is_verdict "${_good}" || { printf '  control+ FAIL %s rejected and must be accepted\n' "${_good}" >&2; _cf=1; }
done
# The REAL v1.0.58 value plus every soft-pass phrase that has actually been used.
for _bad in 'TBD' '' '-' 'n/a' 'pending' 'assumed' 'merged' 'see PR' 'walk:' 'box:host' 'fixed'; do
    if _is_verdict "${_bad}"; then
        printf '  control- FAIL %s accepted and must be refused\n' "${_bad:-<empty>}" >&2; _cf=1
    fi
done
[ "${_cf}" -eq 0 ] || { printf 'CANNOT-RUN: controls did not fire. No verdict offered.\n' >&2; exit 2; }
printf '  controls: 4 accepted shapes OK, 11 refused shapes OK\n'

# --- the subject -------------------------------------------------------------
total=0; proven=0; unproven=0; bad_lines=""
while IFS= read -r row; do
    case "${row}" in '#'*|'') continue ;; esac
    what="$(printf '%s' "${row}" | /usr/bin/cut -f1)"
    [ "${what}" = "what" ] && continue          # header
    nf="$(printf '%s' "${row}" | /usr/bin/awk -F'\t' '{print NF}')"
    if [ "${nf}" -lt 6 ]; then
        printf 'CANNOT-RUN: a row has %s fields, expected >=6. The register shape\n' "${nf}" >&2
        printf '            changed and this gate would read the wrong column.\n' >&2
        exit 2
    fi
    total=$((total + 1))
    verify="$(printf '%s' "${row}" | /usr/bin/cut -f6)"
    if _is_verdict "${verify}"; then
        proven=$((proven + 1))
    else
        unproven=$((unproven + 1))
        bad_lines="${bad_lines}
    ${what:0:64}
        verify = '${verify}'"
    fi
done < "${REG}"

printf '\ncuts/%s/MUST_CONTAIN.tsv\n' "${CUT_VERSION}"
printf '  rows:     %s\n' "${total}"
printf '  PROVEN:   %s  (verify names a box/walk/artefact/gate verdict)\n' "${proven}"
printf '  UNPROVEN: %s\n\n' "${unproven}"

if [ "${total}" -eq 0 ]; then
    printf 'CANNOT-RUN: ZERO rows. An empty denominator is not a clean result --\n' >&2
    printf '            it means the register or this parser is wrong.\n' >&2
    exit 2
fi

if [ "${unproven}" -ne 0 ]; then
    printf 'FAIL: %s of %s row(s) in this cut are NOT PROVEN ON A BOX.\n' "${unproven}" "${total}" >&2
    printf '%s\n\n' "${bad_lines}" >&2
    printf '      Andy, 2026-09-02: "Fixed is fucking FIXED 100%% completely."\n' >&2
    printf '\n' >&2
    printf '      A row here is a CLAIM THIS CUT MAKES TO A CUSTOMER. Merged is not\n' >&2
    printf '      fixed. On main is not fixed. In the DMG is not fixed. Put a real\n' >&2
    printf '      verdict in the verify column or TAKE THE ROW OUT and say plainly\n' >&2
    printf '      that the cut does not carry it.\n' >&2
    printf '\n' >&2
    printf '      Accepted: walk:<ver>#<probe> · box:<host>#<probe>\n' >&2
    printf '                artefact:<sha8>#<what> · gate:<workflow>#<job>\n' >&2
    exit 1
fi

printf 'PASS: %s of %s row(s) name a verdict measured against the thing the\n' "${proven}" "${total}"
printf '      customer runs. No row is claimed on a merge alone.\n'
exit 0
