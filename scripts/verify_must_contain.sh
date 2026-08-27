#!/usr/bin/env bash
# MUST_CONTAIN BOM gate
# =============================================================
#
# THE INVARIANT
#
#     every row of the running BOM is landed=yes, with evidence
#
# WHY THIS EXISTS (2026-08-07). The cut discipline says "the declarative
# manifest is truth". OS003 cuts/<ver>/MUST_CONTAIN.tsv IS that manifest --
# the running bill of materials for the next cut.
#
# NOTHING READ IT. Not one tool. There were three manifest systems:
#
#     scripts/cut_manifest.v1010.tsv  -> cut_hygiene_gate.sh   (v1.0.10, stale)
#     cut-manifests/*.yaml            -> verify_cut_manifest.py
#     cuts/<ver>/MUST_CONTAIN.tsv     -> NOTHING
#
# and the one nobody read is the one that describes the cut being assembled.
# Point cut_hygiene_gate.sh at it and every row goes red with "class unknown" --
# not failures, just a schema it was never built to parse.
#
# The consequence is worse than a missing check. An unread manifest is never
# UPDATED. On 2026-08-07 all 20 rows said landed=no, including three that had
# demonstrably landed hours earlier (the wiki reskin, the image re-pin, the
# On-this-day fix). A BOM that costs nothing to leave stale becomes a wish
# list, and a wish list cannot gate anything.
#
# This gate makes landed=no cost something.
#
# SCHEMA (header-driven, matched by NAME not position, so adding a column
# cannot silently shift the meaning of another one):
#
#     what  repo  ref  landed  capability_id  verify  ticket
#
# USAGE
#   scripts/verify_must_contain.sh <MUST_CONTAIN.tsv> [--list]
#
#   exit 0  every row landed
#   exit 1  one or more rows not landed  -> do NOT cut
#   exit 2  usage / unreadable / unrecognised schema
#
# --list prints the verify command for every row: the box-walk checklist,
# generated rather than remembered.

set -uo pipefail

MANIFEST="${1:-}"
MODE="${2:-gate}"

die()  { echo "ERROR: $*" >&2; exit 2; }
fail() { echo "FAIL: $*" >&2; }

[[ -n "$MANIFEST" ]] || die "usage: $0 <MUST_CONTAIN.tsv> [--list]
       There is deliberately NO default. A gate with a default manifest
       answers 'which cut am I gating?' by accident -- which is how
       cut_hygiene_gate.sh spent six versions validating v1.0.10."
[[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"

# ── Header, by name ───────────────────────────────────────────────────────
HEADER="$(grep -vE '^#' "$MANIFEST" | grep -vE '^[[:space:]]*$' | head -1)"
[[ -n "$HEADER" ]] || die "manifest has no header row: $MANIFEST"

# 🔴 NO `declare -A`. IT IS BASH 4; /bin/bash IS 3.2 ON EVERY MAC, AND THIS
# 🔴 SCRIPT IS INVOKED BY scripts/run_all_cut_gates.sh ON THE CUT HOST.
#
# Measured 2026-08-26: three sibling cut-host gates flipped PASS (bash 5) to
# FAIL (bash 3.2) on bash-4 builtins -- rc 0->1, 0->1, 0->127. They survive
# only because their callers use PATH `bash`, which on this developer's Mac is
# Homebrew 5.x. That is an accident of one machine's PATH, not a property of
# the gate. On a clean Mac `declare -A` is "invalid option".
#
# Same map, portable: a delimited "name=index;" string plus a lookup helper.
# The six indices are resolved ONCE below rather than per row.
COL_MAP=";"
i=0
while IFS= read -r name; do
    name="$(echo "$name" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    [ -n "$name" ] && COL_MAP="${COL_MAP}${name}=${i};"
    i=$((i+1))
done < <(printf '%s' "$HEADER" | tr '\t' '\n')

# col <name> -> prints the column index, or nothing and rc=1 if absent.
# The ";name=" anchoring matters: a bare substring match would let "repo"
# find "source_repo" and silently read the wrong column.
col() {
    _col_rest="${COL_MAP#*;$1=}"
    if [ "$_col_rest" = "$COL_MAP" ]; then return 1; fi
    printf '%s' "${_col_rest%%;*}"
}

# An unrecognised schema is a HARD ERROR. Misparsing it into rows that read
# like content failures is how the last one hid: 21 lines of "class unknown"
# look like 21 problems with the cut, not one problem with the tool.
for required in what repo landed capability_id verify; do
    [[ -n "$(col "$required")" ]] || die "this is not a MUST_CONTAIN manifest.
       missing column: '$required'
       header found:   $HEADER
       expected:       what  repo  ref  landed  capability_id  verify  ticket
       If you meant the PR-hygiene manifest, use scripts/cut_hygiene_gate.sh.
       Refusing to guess -- a misparsed manifest reports tool faults as cut faults."
done

# Resolve once. Under bash 3.2 an unset scalar in an array index is a hard
# error under `set -u`, and these are all proven present by the loop above.
C_WHAT="$(col what)";   C_REPO="$(col repo)";     C_LANDED="$(col landed)"
C_CAPID="$(col capability_id)"; C_VERIFY="$(col verify)"

echo "=================================================================="
echo " MUST_CONTAIN BOM GATE"
echo "   manifest : $MANIFEST"
echo "=================================================================="
echo

total=0; landed=0; notlanded=0
declare -a NOT_LANDED=()

while IFS=$'\t' read -r -a f; do
    [[ ${#f[@]} -lt 2 ]] && continue
    what="${f[$C_WHAT]:-}"
    [[ -z "${what// }" ]] && continue
    [[ "${what:0:1}" == "#" ]] && continue
    # skip the header itself
    [[ "$(echo "$what" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')" == "what" ]] && continue

    repo="${f[$C_REPO]:-}"
    land="$(echo "${f[$C_LANDED]:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    capid="${f[$C_CAPID]:-}"
    verify="${f[$C_VERIFY]:-}"

    total=$((total+1))

    if [[ "$MODE" == "--list" ]]; then
        printf '  [%s] %s\n      repo   %s\n      verify %s\n\n' \
            "${land:-?}" "$what" "$repo" "$verify"
        continue
    fi

    case "$land" in
        yes|y|true|done)
            landed=$((landed+1))
            printf '  \033[32mLANDED\033[0m  %s\n' "$what"
            ;;
        *)
            notlanded=$((notlanded+1))
            NOT_LANDED+=("$what | $repo | verify: $verify")
            printf '  \033[31mNOT YET\033[0m %s  [%s]\n' "$what" "$repo"
            ;;
    esac
done < <(grep -vE '^#' "$MANIFEST")

[[ "$MODE" == "--list" ]] && exit 0

echo
echo "=================================================================="
printf '  %s row(s):  %s landed  |  %s NOT landed\n' "$total" "$landed" "$notlanded"

if [[ "$total" -eq 0 ]]; then
    die "parsed ZERO rows from a manifest that exists. The parser has stopped
       matching -- this gate is now blind, which is indistinguishable from
       a clean BOM."
fi

if [[ "$notlanded" -gt 0 ]]; then
    echo "  RESULT: RED. The BOM is not satisfied -- do NOT assemble the DMG."
    echo
    echo "  Not landed:"
    for n in "${NOT_LANDED[@]}"; do echo "    - $n"; done
    echo
    echo "  Two legitimate ways to clear a row, and only two:"
    echo "    1. land it, then set landed=yes in the manifest"
    echo "    2. decide it is out of this cut, and DELETE the row (with a"
    echo "       note in the cut doc saying why)"
    echo
    echo "  Leaving it at 'no' and cutting anyway is the third way, and it is"
    echo "  how a BOM decays into a wish list."
    echo "=================================================================="
    exit 1
fi

echo "  RESULT: GREEN. Every BOM row is landed."
echo "=================================================================="
exit 0
