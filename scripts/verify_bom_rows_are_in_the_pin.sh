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
# AND WHY IT NOW ASKS FOR ANCESTRY AS WELL, FOR A DIFFERENT QUESTION
# ─────────────────────────────────────────────────────────────────────────────
# The paragraph above is about CONTENT: did the fix land in the tree being
# built. Ancestry cannot answer that, and it is not being asked to.
#
# The second question is about the REF ITSELF: can the commit this row cites be
# resolved by whoever reads the BOM next. Those are not the same question and
# only one of them is answered by a blob.
#
# MEASURED 2026-09-09 on v1.0.81. Row 4 cited 34c536c3, the HEAD of CM051
# #1863, whose merge commit is bff5cfd8 and whose branch was deleted. That
# commit exists in exactly one place, refs/pull/1863/head. `git clone` plus
# `git fetch origin main` does not fetch refs/pull, so the object is absent
# from a runner, and this gate printed UNMEASURABLE and exited 0 anyway. The
# same row read as resolvable on the machine that wrote it, whose object store
# happened to carry the pull ref: a gate answering from a local artefact.
#
# ANCESTRY OF THE PIN IS THE INSTRUMENT FOR THAT QUESTION, and it is exact
# rather than a heuristic. If the ref is an ancestor of the pinned commit then
# every clone that can read the pin can read the ref, because reaching the pin
# means reaching everything behind it. If it is not, the row is citing
# something outside the history being built: a PR head, a squash source, or a
# ref someone happened to have fetched.
#
# MEASURED ACROSS THE CUTS BEFORE MAKING IT A REFUSAL, because a rule that
# reds honest rows is worse than the gap it closes. CM051 rows, ref against
# that cut's own pin, every version with a cuts/ directory:
#
#     v1.0.71  3 ancestors, 0 not      v1.0.77  1 ancestor,  0 not
#     v1.0.72 11 ancestors, 0 not      v1.0.78  1 ancestor,  0 not
#     v1.0.73  7 ancestors, 1 not      v1.0.79  2 ancestors, 0 not
#     v1.0.74  2 ancestors, 2 not      v1.0.80  2 ancestors, 0 not
#     v1.0.75  3 ancestors, 0 not      v1.0.81  2 ancestors, 1 not  <- the row
#     v1.0.76  2 ancestors, 0 not
#
# So this refuses exactly one live row and three rows in two cuts that were
# spent months of version numbers ago. It is not a rule the repo has been
# quietly breaking; it is the convention every recent BOM already follows.
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
#
# AND UNMEASURABLE IS NOW ONE OF THEM, WHICH THE COMMENT BELOW CLAIMED FOR
# THREE DAYS WHILE THE CODE DID NOT. The note at the removal-shaped
# discriminator says a row scoring UNMEASURABLE "is CANNOT-RUN, which refuses
# the cut". It was not. There were three exits -- nothing examined, at least
# one absent, otherwise 0 -- and none of them read the unmeasurable counter, so
# an unmeasurable row was printed and then ignored. Measured 2026-09-09 on the
# v1.0.81 BOM in a clone with no pull refs: one row unmeasurable, rc 0, "OK".
# A comment asserting a refusal that the code never implements is worse than no
# comment, because the next reader audits the sentence rather than the branch.
#
# PRECEDENCE, STATED BECAUSE TWO NON-ZERO EXITS CAN BOTH APPLY. A definite
# finding outranks an unanswerable row: exit 1 names something a person can go
# and fix, exit 2 says the question could not be put. Both refuse the cut, and
# the counters for both are printed either way.
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

IN=0; OUT=0; NA=0; UNMEASURABLE=0; NOTINHIST=0; TOTAL=0
MISSING=""
OUTSIDE=""
while IFS=$'\t' read -r what repo ref landed cap verify ticket; do
    case "${ref:-}" in ""|ref) continue ;; esac
    TOTAL=$((TOTAL+1))
    if [ "${repo:-}" != "CM051" ]; then NA=$((NA+1)); continue; fi
    if ! git -C "$HERE" cat-file -e "${ref}^{commit}" 2>/dev/null; then
        UNMEASURABLE=$((UNMEASURABLE+1))
        echo "  UNMEASURABLE  ${ticket}  ref ${ref} is not an object in this clone"
        continue
    fi
    # IS THE REF ITSELF CITABLE? See the header. This is not the content
    # question and it does not replace the blob comparison below; it is the
    # question of whether the commit this row names is inside the history that
    # is about to be built, and therefore readable by anyone who can read the
    # pin. An ancestor is; a PR head, a squash source or a stray fetched ref is
    # not, and it resolves here only for whoever happens to hold it.
    #
    # A FAILURE, NOT AN UNMEASURABLE. The object is present and the question
    # was answered: the answer is no. Calling it unmeasurable would hide a
    # definite finding behind the softer word.
    if ! git -C "$HERE" merge-base --is-ancestor "${ref}" "${PIN}" 2>/dev/null; then
        NOTINHIST=$((NOTINHIST+1))
        echo "  NOT IN THE PINNED HISTORY  ${ticket}  ref ${ref}"
        OUTSIDE="${OUTSIDE}\n    ${ticket}  ${ref}  $(printf '%s' "$what" | cut -c1-64)"
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
    # A REMOVAL IS AS MEASURABLE AS AN ADDITION, and this gate could not see one.
    #
    # MEASURED 2026-09-08: the v1.0.77 cut died here on CM051 #1835, whose whole
    # substance is REMOVING the #1253 signal-2 block and merging two case labels.
    # Its longest ADDED non-comment install.sh line is 23 characters
    # ("return 0 ;;"), below the 40 floor above, so LINE came back empty and the
    # row scored UNMEASURABLE -- which is CANNOT-RUN, which refuses the cut.
    #
    # The row was not unmeasurable. It was measurable in the other direction:
    # the line the commit DELETED is 78 characters and must now be ABSENT from
    # the pinned blob. That is a stronger claim than presence, not a weaker one:
    # it proves the removal actually landed in the tree being cut, which is
    # exactly what a BOM row for a removal-shaped fix should assert.
    #
    # So before declaring a row unmeasurable, try the removal. Only a commit
    # that neither added nor removed a keyable line is genuinely unmeasurable.
    if [ -z "$LINE" ]; then
        GONE="$(git -C "$HERE" show "$ref" -- install.sh 2>/dev/null \
            | grep '^-' | grep -vE '^---|^-[[:space:]]*#|^-[[:space:]]*$' \
            | sed 's/^-//' \
            | awk '{ if (length($0)>40 && length($0)<200) print length($0)"\t"$0 }' \
            | sort -rn | head -1 | cut -f2-)"
        if [ -n "$GONE" ]; then
            # ABSENT from the pin is the PASS here. Present means the removal
            # never reached the tree being cut.
            if [ "$(grep -cF -- "$GONE" "$PINNED")" -eq 0 ]; then
                IN=$((IN+1))
                echo "  IN THE PIN    ${ticket}  by REMOVAL: the line it deleted is absent from the pinned install.sh"
            else
                OUT=$((OUT+1))
                echo "  ABSENT        ${ticket}  the line it deleted is STILL PRESENT in the pinned install.sh -- the removal did not reach this tree"
            fi
            continue
        fi
    fi
    if [ -z "$LINE" ]; then
        # The commit changed no install.sh line we can key on. That is NOT a
        # pass: say which bucket it is in and why.
        # NOT `... | grep -q`. Under `set -o pipefail`, grep -q exits on the
        # FIRST match and closes the pipe, the producer takes SIGPIPE, and the
        # pipeline's status becomes that signal rather than grep's verdict --
        # so a match can read as a failure. The repo's appcast-ship-wiring
        # ratchet caught this line, which is the gate doing exactly its job.
        # A herestring keeps the producer's output in a variable, so nothing
        # is left to short-circuit. This file declares bash, so the herestring
        # is available; a POSIX-sh consumer would need the `grep -c` form.
        _touched="$(git -C "$HERE" show --name-only --format='' "$ref" 2>/dev/null)"
        if grep -q '^install\.sh$' <<< "$_touched"; then
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
echo "  not in the pinned history : $NOTINHIST"
echo "  not install.sh (nothing to key on in this blob) : $NA"
echo "  unmeasurable: $UNMEASURABLE"

# A run where NOTHING was answered is not a pass. This is the zero-denominator
# shape: 0 absent looks identical whether every row was verified or none was.
# A row refused for citing something outside the pinned history HAS been
# answered, so it counts towards the denominator; leaving it out would let a
# BOM whose every row is uncitable exit 2 as though the gate had been unable
# to look, when in fact it looked and found the defect.
if [ "$((IN + OUT + NOTINHIST))" -eq 0 ]; then
    echo
    echo "CANNOT-RUN: not one row was checkable against the pin, so '0 absent'"
    echo "  here means 'nothing was examined', which must not read as success."
    exit 2
fi

if [ "$OUT" -gt 0 ] || [ "$NOTINHIST" -gt 0 ]; then
    echo
    if [ "$OUT" -gt 0 ]; then
        echo "FAIL: ${OUT} BOM row(s) claim landed=yes and are NOT in the pinned tree:"
        printf "%b\n" "$MISSING"
        echo
        echo "  The pin is what gets BUILT. Re-point CM051= in cuts/${VER}/cut.env to"
        echo "  the commit that actually carries these, AFTER the last merge, then"
        echo "  re-run. Moving it before the last merge is how it goes stale again."
    fi
    if [ "$NOTINHIST" -gt 0 ]; then
        [ "$OUT" -gt 0 ] && echo
        echo "FAIL: ${NOTINHIST} BOM row(s) cite a commit that is NOT in the pinned history:"
        printf "%b\n" "$OUTSIDE"
        echo
        echo "  Each of these resolves HERE and will not resolve on a runner or in"
        echo "  any fresh clone: a PR head, a squash source, or a ref this store"
        echo "  happens to have fetched. Cite the commit the change landed as, the"
        echo "  one reachable from CM051= in cuts/${VER}/cut.env, and re-run."
    fi
    if [ "$UNMEASURABLE" -gt 0 ]; then
        echo
        echo "  ${UNMEASURABLE} further row(s) could not be measured at all; see above."
    fi
    exit 1
fi

# UNMEASURABLE IS A REFUSAL, and until 2026-09-09 it was a line of output.
# A row nobody could measure has not passed. Saying so here is what makes the
# note at the removal-shaped discriminator true.
if [ "$UNMEASURABLE" -gt 0 ]; then
    echo
    echo "CANNOT-RUN: ${UNMEASURABLE} BOM row(s) could not be measured against the pin."
    echo "  Every row that WAS measurable is in the pin, and that is not the same"
    echo "  as the BOM being satisfied. A row is unmeasurable here for one of two"
    echo "  reasons, and both are fixable rather than tolerable: its ref is not an"
    echo "  object in this clone, or its commit changed install.sh without adding"
    echo "  or removing a line long enough to key on."
    exit 2
fi

echo
echo "OK: every checkable BOM row is present in the pinned install.sh."
exit 0
