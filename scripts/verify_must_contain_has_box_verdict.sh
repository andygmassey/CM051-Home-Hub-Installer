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

WALK_CARD=0
if [ "${1:-}" = "--walk-card" ]; then WALK_CARD=1; shift; fi

CUT_VERSION="${1:-}"
if [ -z "${CUT_VERSION}" ]; then
    printf 'CANNOT-RUN: no cut version given.\n' >&2
    printf '            usage: %s [--walk-card] <vX.Y.Z>\n' "$0" >&2
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

# ---------------------------------------------------------------------------
# THE THIRD STATE, AND WHY IT HAD TO EXIST
# ---------------------------------------------------------------------------
# ANDY, 2026-09-02: "I'm beyond fed up with keep making DMGs and doing a walk
# and then hearing that stuff hasn't been fixed that I was told it had."
#
# Before this change the register had TWO outcomes: a row was PROVEN, or the
# cut FAILED. That looks strict and is actually the mechanism that put
# surprises in his hands, because SOME ROWS GENUINELY CANNOT BE PROVEN BEFORE
# A WALK -- anything whose only instrument is a human looking at a screen on a
# machine that does not exist until the DMG is cut. Faced with proven-or-block,
# such a row gets written as TBD, or padded with the nearest gate that is not
# really about it, or quietly dropped. All three roads end at Andy discovering
# it himself.
#
# So `needs-walk:` is a FIRST-CLASS, DECLARED state. It is NOT a soft pass and
# it is never counted as proven. It means exactly one thing:
#
#     ANDY IS THE INSTRUMENT FOR THIS ROW, AND HE IS BEING TOLD SO UP FRONT.
#
# It must still NAME WHAT TO LOOK AT, for the same reason a verdict must name
# its evidence: "needs-walk:v1.0.59" tells him nothing, whereas
# "needs-walk:v1.0.59#settings-has-no-advanced-section" is his checklist line.
#
# The guarantee this buys is narrow and worth stating exactly. It does NOT mean
# nothing will be broken. It means every row reaching him is in one of two
# buckets he has already seen, so anything he hits was either declared unproven
# to him or is a genuinely NEW discovery -- never "we told you that was fixed".
NEEDS_WALK_RE='^needs-walk:[^#]+#[^#]+$'

_is_verdict()    { printf '%s' "$1" | /usr/bin/grep -qE "${VERDICT_RE}"; }
_is_needs_walk() { printf '%s' "$1" | /usr/bin/grep -qE "${NEEDS_WALK_RE}"; }

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

# --- THE DISJOINTNESS CONTROL. The one that matters most here. --------------
#
# `needs-walk:` exists to be HONEST about an unproven row. The instant the
# proven predicate also accepts it, the honesty is gone and every unproven row
# silently reports as proven -- a strictly worse state than the TBD it replaced,
# because it would read as evidence. So the two predicates are asserted
# DISJOINT in both directions, on real values, every run.
for _nw in 'needs-walk:v1.0.59#settings-has-no-advanced-section' \
           'needs-walk:v1.0.59#bursar-shows-a-real-entry'; do
    _is_needs_walk "${_nw}" || { printf '  control-nw FAIL %s must be a valid needs-walk\n' "${_nw}" >&2; _cf=1; }
    if _is_verdict "${_nw}"; then
        printf '  control-nw FAIL %s counted as PROVEN. needs-walk is not evidence.\n' "${_nw}" >&2; _cf=1
    fi
done
# ...and a real verdict must never be mistaken for a needs-walk, or a proven
# row would be handed to Andy to re-check by hand and the card becomes noise.
for _v in 'walk:v1.0.59#store_auth_pth_final' 'gate:test-wiring.yml#test-wiring'; do
    if _is_needs_walk "${_v}"; then
        printf '  control-nw FAIL %s counted as needs-walk\n' "${_v}" >&2; _cf=1
    fi
done
# A needs-walk that does not say WHAT TO LOOK AT is not a declaration, it is a
# shrug. Refused for the same reason 'walk:' alone is refused.
for _bad_nw in 'needs-walk:' 'needs-walk:v1.0.59' 'needs-walk' 'needs-walk:#' 'needs-walk:v1#a#b'; do
    if _is_needs_walk "${_bad_nw}"; then
        printf '  control-nw FAIL %s accepted; a needs-walk must name what to check\n' "${_bad_nw}" >&2; _cf=1
    fi
done
[ "${_cf}" -eq 0 ] || { printf 'CANNOT-RUN: controls did not fire. No verdict offered.\n' >&2; exit 2; }
printf '  controls: 4 accepted shapes OK, 11 refused shapes OK,\n'
printf '            needs-walk disjoint from proven both ways, 5 shrug shapes refused\n'

# --- the subject -------------------------------------------------------------
total=0; proven=0; unproven=0; needswalk=0
bad_lines=""; proven_lines=""; walk_lines=""
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
        proven_lines="${proven_lines}
  ✓ ${what}
      evidence: ${verify}"
    elif _is_needs_walk "${verify}"; then
        # DECLARED unproven. Not a pass, not a failure: a named handover.
        needswalk=$((needswalk + 1))
        walk_lines="${walk_lines}
  ▢ ${what}
      you check: ${verify#needs-walk:}"
    else
        unproven=$((unproven + 1))
        bad_lines="${bad_lines}
    ${what:0:64}
        verify = '${verify}'"
    fi
done < "${REG}"

printf '\ncuts/%s/MUST_CONTAIN.tsv\n' "${CUT_VERSION}"
printf '  rows:        %s\n' "${total}"
printf '  PROVEN:      %s  (verify names a box/walk/artefact/gate verdict)\n' "${proven}"
printf '  NEEDS-WALK:  %s  (declared unproven -- Andy is the instrument)\n' "${needswalk}"
printf '  UNCLASSIFIED:%s\n\n' "${unproven}"

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
    printf '      Or, if it HONESTLY cannot be proven before the walk, say so:\n' >&2
    printf '                needs-walk:<ver>#<what-Andy-should-look-at>\n' >&2
    printf '      That is a declaration, not a pass. It puts the row on his card.\n' >&2
    exit 1
fi

# --- ANTI-VACUITY. A register that proves NOTHING is not a cut. -------------
#
# needs-walk: is honest, and for that reason it is the easiest thing in this
# file to abuse: mark every row needs-walk and the gate goes green having
# verified nothing, while the card hands Andy the entire BOM to check by hand.
# That is the failure this whole mechanism exists to prevent, arriving by the
# front door. So at least one row must carry real evidence.
if [ "${proven}" -eq 0 ]; then
    printf 'FAIL: %s row(s) and NOT ONE names real evidence.\n' "${total}" >&2
    printf '      Every row is needs-walk. That is not a cut, it is a wishlist,\n' >&2
    printf '      and it would hand Andy the whole register to verify by hand.\n' >&2
    exit 1
fi

printf 'PASS: %s of %s row(s) name a verdict measured against the thing the\n' "${proven}" "${total}"
printf '      customer runs. No row is claimed on a merge alone.\n'
if [ "${needswalk}" -ne 0 ]; then
    printf '      %s row(s) are DECLARED unproven and will be handed to Andy\n' "${needswalk}"
    printf '      on the walk card. Run with --walk-card to print it.\n'
fi

# --- THE CARD -------------------------------------------------------------
if [ "${WALK_CARD}" -eq 1 ]; then
    printf '\n'
    printf '════════════════════════════════════════════════════════════════\n'
    printf ' WALK CARD -- %s\n' "${CUT_VERSION}"
    printf '════════════════════════════════════════════════════════════════\n'
    printf '\nALREADY PROVEN BEFORE THIS DMG REACHED YOU (%s)\n' "${proven}"
    printf 'You do not need to check these. Each names the evidence that ran.\n'
    printf '%s\n' "${proven_lines}"
    if [ "${needswalk}" -ne 0 ]; then
        printf '\n────────────────────────────────────────────────────────────────\n'
        printf 'YOU ARE THE INSTRUMENT (%s)\n' "${needswalk}"
        printf 'These CANNOT be proven before a walk. Nobody has verified them.\n'
        printf 'They are listed here BEFORE you start, so that whatever you find\n'
        printf 'is either on this list or genuinely new -- never something you\n'
        printf 'were told was fixed.\n'
        printf '%s\n' "${walk_lines}"
    else
        printf '\n────────────────────────────────────────────────────────────────\n'
        printf 'YOU ARE THE INSTRUMENT (0)\n'
        printf 'Nothing in this cut needs your eyes. Every row was proven.\n'
    fi
    printf '\n════════════════════════════════════════════════════════════════\n'
fi
exit 0
