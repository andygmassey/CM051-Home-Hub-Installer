#!/usr/bin/env bash
# MUST_CONTAIN BOM gate
# =============================================================
#
# THE INVARIANT
#
#     every row of the running BOM is landed=yes, AND the commit it names is
#     actually in the tree being cut
#
# ── WHY THE SECOND HALF WAS ADDED, 2026-09-23 ────────────────────────────────
#
# This gate parsed six columns and asserted exactly one of them. `capability_id`
# was read into a variable at the top of the loop and never mentioned again;
# `verify` was printed in --list mode and in the failure text, and never run.
# The verdict came entirely from `landed`, which the manifest declares about
# itself.
#
# MEASURED on cuts/v1.0.101/MUST_CONTAIN.tsv, 34 rows, every one landed=no:
# rewriting the single word `no` to `yes` in all 34, changing nothing else,
# takes this gate from
#     RESULT: RED. The BOM is not satisfied -- do NOT assemble the DMG.
# to
#     RESULT: GREEN. Every BOM row is landed.
# Nine of those rows carry capability_id=none, and among the 34 are
# "the recovery-key marker was bound to the dead staging tree and never
# written" and "ostler-unlock pointed into /tmp, so the recovery key could not
# be redeemed". A gate that a find-and-replace can satisfy is not gating a cut,
# and the thing it was waved through is a recovery key a customer cannot redeem.
#
# SO `landed=yes` NOW COSTS SOMETHING. A row that claims to have landed must
# name a commit that is an ANCESTOR OF THE TREE BEING CUT. That is a fact about
# git objects, not a word in a column, and no edit to this manifest can
# manufacture it.
#
# WHAT THIS CAN AND CANNOT PROVE, stated because the limit matters:
# ancestry proves the commit is IN the tree. It does not prove the commit does
# what the row says. It is the floor, not the ceiling -- but the floor is what
# was missing, and the rows above are what fell through it.
#
# WHAT IT REFUSES TO GUESS. Rows naming another repo (ostler-assistant, CM044,
# HR015) or carrying a ref that is not a bare sha ("TBD", a PR number, a tag
# phrase) cannot be resolved from this checkout. Those are reported UNPROVEN
# and the gate exits 2, CANNOT-RUN. They are NOT counted as landed. Measured
# across all cuts/ manifests: 279 of 353 rows name this repo and 286 carry a
# sha, so the provable majority is most of the BOM; v1.0.101 is 34 for 34.
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
#   exit 0  every row landed AND every claim proven against git
#   exit 1  a row is not landed, or claims landed for a commit that is NOT in
#           this tree  -> do NOT cut
#   exit 2  usage / unreadable / unrecognised schema / a claim that could not
#           be checked from this checkout. Nothing measured is not a pass.
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
# `ref` is what makes a landed claim checkable. It is not in the hard-required
# list above (older manifests predate it), so resolve it defensively: absent
# means every landed row is UNPROVEN, which the summary says out loud.
C_REF="$(col ref || true)"

echo "=================================================================="
echo " MUST_CONTAIN BOM GATE"
echo "   manifest : $MANIFEST"
echo "=================================================================="
echo

# ── THE PREDICATE, AND THE CONTROLS THAT PROVE IT WORKS ──────────────────────
#
# THIS_REPO: the repo column values that mean "resolvable from this checkout".
THIS_REPO_NAMES=" cm051 "

GIT_OK=1
git rev-parse --git-dir >/dev/null 2>&1 || GIT_OK=0

# is_in_tree <sha> -> 0 if <sha> is a commit that this checkout's HEAD descends
# from. Both halves matter: a sha that names a blob, a tag, or nothing at all
# must not read the same as a commit that landed.
is_in_tree() {
    [ "$GIT_OK" -eq 1 ] || return 1
    git cat-file -e "${1}^{commit}" 2>/dev/null || return 1
    git merge-base --is-ancestor "$1" HEAD 2>/dev/null
}

# A gate that has never been observed failing is not known to be able to fail,
# and this one decides whether a DMG is assembled. So the predicate is exercised
# in BOTH directions before it is trusted with a single row, every run.
if [ "$GIT_OK" -eq 1 ]; then
    _ctl_head="$(git rev-parse HEAD 2>/dev/null)"
    _ctl_bad=0

    # POSITIVE: HEAD is trivially in the tree. If this is false the predicate is
    # broken and every row would read NOT LANDED -- a whole-cut block from a
    # tool fault.
    is_in_tree "$_ctl_head" || { echo "CONTROL FAILED: HEAD is not recognised as in-tree" >&2; _ctl_bad=1; }

    # NEGATIVE 1: the empty-tree object exists but is not a commit. It must not
    # pass. This is the "a sha that resolves to something else" branch.
    if is_in_tree "4b825dc642cb6eb9a060e54bf8d69288fbee4904"; then
        echo "CONTROL FAILED: the empty-tree object was accepted as a landed commit" >&2
        _ctl_bad=1
    fi

    # NEGATIVE 2: asymmetry. HEAD cannot be an ancestor of its own parent. A
    # predicate that answers yes to everything passes NEGATIVE 1 and fails here.
    _ctl_parent="$(git rev-parse --verify HEAD~1 2>/dev/null || true)"
    if [ -n "$_ctl_parent" ]; then
        if git merge-base --is-ancestor "$_ctl_head" "$_ctl_parent" 2>/dev/null; then
            echo "CONTROL FAILED: HEAD reported as an ancestor of HEAD~1" >&2
            _ctl_bad=1
        fi
    fi

    if [ "$_ctl_bad" -ne 0 ]; then
        die "the landed-ness predicate failed its own controls. Refusing to judge a
       BOM with an instrument that is not known to work."
    fi
fi

total=0; landed=0; notlanded=0; unproven=0
declare -a NOT_LANDED=()
declare -a UNPROVEN=()

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
            # The claim is now checked, not accepted. `ref` must name a commit
            # this checkout descends from.
            _repo_key="$(echo "$repo" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
            _ref="$(echo "${f[$C_REF]:-}" | tr -d '[:space:]')"
            if [ -z "${C_REF}" ] || [ -z "$_ref" ]; then
                unproven=$((unproven+1))
                UNPROVEN+=("$what | $repo | no ref to check")
                printf '  \033[33mUNPROVEN\033[0m %s  [no ref]\n' "$what"
            elif [ "${THIS_REPO_NAMES#* $_repo_key }" = "$THIS_REPO_NAMES" ]; then
                unproven=$((unproven+1))
                UNPROVEN+=("$what | $repo | ref $_ref is in another repo, not checkable here")
                printf '  \033[33mUNPROVEN\033[0m %s  [%s: not this repo]\n' "$what" "$repo"
            elif ! [[ "$_ref" =~ ^[0-9a-f]{7,40}$ ]]; then
                unproven=$((unproven+1))
                UNPROVEN+=("$what | $repo | ref '$_ref' is not a bare sha")
                printf '  \033[33mUNPROVEN\033[0m %s  [ref not a sha: %s]\n' "$what" "$_ref"
            elif is_in_tree "$_ref"; then
                landed=$((landed+1))
                printf '  \033[32mLANDED\033[0m  %s  [%s]\n' "$what" "${_ref:0:12}"
            else
                notlanded=$((notlanded+1))
                NOT_LANDED+=("$what | $repo | claims landed=$land but $_ref is NOT in this tree")
                printf '  \033[31mFALSE CLAIM\033[0m %s  [%s not in this tree]\n' "$what" "${_ref:0:12}"
            fi
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
printf '  %s row(s):  %s landed (proven)  |  %s NOT landed  |  %s unproven\n' \
    "$total" "$landed" "$notlanded" "$unproven"

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
    echo
    echo "  A row marked LANDED whose commit is not in this tree is reported as"
    echo "  FALSE CLAIM above. Editing the landed column does not clear it."
    echo "=================================================================="
    exit 1
fi

# CANNOT-RUN OUTRANKS GREEN, AND ONLY GREEN. A row whose claim could not be
# checked has not been checked; saying so is the whole point of the change that
# added this branch.
if [[ "$unproven" -gt 0 ]]; then
    echo "  RESULT: CANNOT-RUN. Every checkable row landed, but ${unproven} claim(s)"
    echo "          could not be checked from this checkout."
    echo
    echo "  Unproven:"
    for u in "${UNPROVEN[@]}"; do echo "    - $u"; done
    echo
    echo "  Each needs its commit confirmed in the repo it names, by hand or by a"
    echo "  gate that can see that repo. An unproven row is not a landed row."
    echo "=================================================================="
    exit 2
fi

echo "  RESULT: GREEN. Every BOM row is landed, and every claim was checked"
echo "          against git: each ref names a commit this tree descends from."
echo "=================================================================="
exit 0
