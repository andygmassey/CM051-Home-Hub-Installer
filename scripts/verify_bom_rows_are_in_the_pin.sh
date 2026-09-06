#!/usr/bin/env bash
# verify_bom_rows_are_in_the_pin.sh -- does the tree this cut will actually
# BUILD contain the changes its BOM says it must contain?
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS. MEASURED 2026-09-06 on v1.0.72.
# ─────────────────────────────────────────────────────────────────────────────
# The BOM's stated premise is that "the cut blocks until every row is
# landed=in-artefact". The gate that enforces it, OS003
# gates/verify_must_contain.sh, counts rows whose `landed` column is not `yes`.
# `landed` is a column somebody TYPED. Nothing compares it to the pin.
#
# So, with cuts/v1.0.72/cut.env pinning CM051=c6b5932c:
#
#     verify_must_contain.sh v1.0.72     11 rows, 0 not landed
#     this script, same 11 rows           8 of 9 checkable fixes ABSENT
#                                         from the PINNED install.sh blob,
#                                         all 9 present on main
#
# Every one of those rows says landed=yes. Eight of them would not have
# shipped. That is not a lie in the BOM, it is the pin not having been moved
# yet -- and the point is that NOTHING WOULD HAVE CAUGHT IT if it never was.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY IT COMPARES A BLOB AND NOT ANCESTRY
# ─────────────────────────────────────────────────────────────────────────────
# A cut pin names a COMMIT, but what ships is the install.sh BLOB at that
# commit. Ancestry is valid in one direction only: TRUE proves a change landed,
# FALSE proves nothing, because a squash or a rebase gives content without
# ancestry. Measured here: 10 of 11 BOM refs are not ancestors of the pin, and
# the content check agrees on 8 of them and disagrees on the rest, which is
# exactly why ancestry alone is not the instrument.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHERE IT IS MEANINGFUL
# ─────────────────────────────────────────────────────────────────────────────
# On a TAG PUSH. That is when the pin must already be correct. On a
# workflow_dispatch the pin is legitimately allowed to be behind, so this
# reports CANNOT-RUN rather than a verdict -- the same honest limit
# tests/test_installer_version_matches_the_cut.sh carries for the same reason.
#
# THREE STATES. 0 every checkable row is in the pin. 1 at least one is not.
# 2 CANNOT-RUN: no BOM, no pin, unreadable blob, or no derivable discriminator.
set -uo pipefail

VER="${1:-}"
[ -n "$VER" ] || { echo "usage: $0 <version, e.g. v1.0.72>" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOM="$HERE/cuts/$VER/MUST_CONTAIN.tsv"
ENVF="$HERE/cuts/$VER/cut.env"

[ -r "$BOM" ]  || { echo "CANNOT-RUN: no BOM at $BOM" >&2; exit 2; }
[ -r "$ENVF" ] || { echo "CANNOT-RUN: no cut.env at $ENVF" >&2; exit 2; }

PIN="$(grep -E '^CM051=' "$ENVF" | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'")"
[ -n "$PIN" ] || { echo "CANNOT-RUN: cut.env names no CM051= pin" >&2; exit 2; }

PINNED="$(mktemp)" || exit 2
trap 'rm -f "$PINNED"' EXIT
if ! git -C "$HERE" show "${PIN}:install.sh" > "$PINNED" 2>/dev/null; then
    echo "CANNOT-RUN: cannot read install.sh at the pin ${PIN}." >&2
    echo "  A shallow clone or a missing object reads identically to a clean" >&2
    echo "  tree here, and scanning nothing must not pass." >&2
    exit 2
fi
# A pinned blob that is empty or absurd would make every absence look real.
_pl=$(wc -l < "$PINNED" | tr -d ' ')
if [ "${_pl:-0}" -lt 1000 ]; then
    echo "CANNOT-RUN: that is not the installer -- install.sh at the pin is only ${_pl} lines." >&2
    echo "  Every 'absent' verdict below would be an artefact of the truncation," >&2
    echo "  which is the false-positive twin of a false zero: it looks like a finding." >&2
    exit 2
fi

echo "BOM rows against the pin"
echo "  version : $VER"
echo "  pin     : $PIN  (install.sh, ${_pl} lines)"

IN=0; OUT=0; NA=0; UNMEASURABLE=0; TOTAL=0
MISSING=""
while IFS=$'\t' read -r what repo ref landed cap verify ticket; do
    case "${ref:-}" in ""|ref) continue ;; esac
    TOTAL=$((TOTAL+1))
    if [ "${repo:-}" != "CM051" ]; then NA=$((NA+1)); continue; fi
    if ! git -C "$HERE" cat-file -e "${ref}^{commit}" 2>/dev/null; then
        UNMEASURABLE=$((UNMEASURABLE+1))
        echo "  UNMEASURABLE  ${ticket}  ref ${ref} is not an object in this clone"
        continue
    fi
    # Discriminator: the longest added, non-comment, non-trivial install.sh line
    # this commit introduced. Long enough to be specific, short enough to be a
    # single line in the blob.
    LINE="$(git -C "$HERE" show "$ref" -- install.sh 2>/dev/null \
        | grep '^+' | grep -vE '^\+\+\+|^\+[[:space:]]*#|^\+[[:space:]]*$' \
        | sed 's/^+//' \
        | awk '{ if (length($0)>40 && length($0)<200) print length($0)"\t"$0 }' \
        | sort -rn | head -1 | cut -f2-)"
    if [ -z "$LINE" ]; then
        # The commit changed no install.sh line we can key on. That is NOT a
        # pass: say which bucket it is in and why.
        if git -C "$HERE" show --name-only --format='' "$ref" 2>/dev/null | grep -q '^install\.sh$'; then
            UNMEASURABLE=$((UNMEASURABLE+1))
            echo "  UNMEASURABLE  ${ticket}  touches install.sh but added no keyable line"
        else
            NA=$((NA+1))
        fi
        continue
    fi
    if grep -qF -- "$LINE" "$PINNED"; then
        IN=$((IN+1))
    else
        OUT=$((OUT+1))
        MISSING="${MISSING}\n    ${ticket}  ${ref}  $(printf '%s' "$what" | cut -c1-64)"
    fi
done < <(grep -v '^#' "$BOM" | grep -v '^[[:space:]]*$' | tail -n +2)

echo "  rows        : $TOTAL"
echo "  in the pin  : $IN"
echo "  ABSENT      : $OUT"
echo "  not install.sh (nothing to key on in this blob) : $NA"
echo "  unmeasurable: $UNMEASURABLE"

# A run where NOTHING was checkable is not a pass. This is the zero-denominator
# shape: 0 absent looks identical whether every row was verified or none was.
if [ "$((IN + OUT))" -eq 0 ]; then
    echo
    echo "CANNOT-RUN: not one row was checkable against the pin, so '0 absent'"
    echo "  here means 'nothing was examined', which must not read as success."
    exit 2
fi

if [ "$OUT" -gt 0 ]; then
    echo
    echo "FAIL: ${OUT} BOM row(s) claim landed=yes and are NOT in the pinned tree:"
    printf "%b\n" "$MISSING"
    echo
    echo "  The pin is what gets BUILT. Re-point CM051= in cuts/${VER}/cut.env to"
    echo "  the commit that actually carries these, AFTER the last merge, then"
    echo "  re-run. Moving it before the last merge is how it goes stale again."
    exit 1
fi

echo
echo "OK: every checkable BOM row is present in the pinned install.sh."
exit 0
