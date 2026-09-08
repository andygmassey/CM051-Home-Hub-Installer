#!/usr/bin/env bash
# tests/test_collections_are_created_where_readiness_is_proven.sh
# ============================================================================
# THE DEFECT. Every qdrant collection creator in install.sh is one-shot behind a
# single cap:
#
#   _ostler_ensure_qdrant_collections()  waits _QDRANT_COLLECTIONS_READY_CAP
#                                        (300 s) for the store, THEN creates
#   the hoisted #1821 call               runs before the import branch
#   the inline pre-create loop           gated on graph_db_start's readiness
#
# On a slow cold VM the cap expires before qdrant answers. The wait loop stops
# waiting, the creates that follow fail against a store that is not up, and
# NOTHING creates the collections at any later point. The install then finishes
# with an index it promised and never built, and the walk's people probes read a
# store missing the collections they depend on. That is the v1.0.78 walk.
#
# THE FIX under test: at the point where the membership is measured, readiness is
# already PROVEN rather than waited for, because the collection count came back
# as a number from a credentialed GET. So the creator runs once more there and
# the membership is RE-MEASURED per name.
#
# WHAT THIS TEST ASSERTS, and it is behaviour rather than text: extract the fix
# region from the shipped install.sh, drive it with a store that answers LATE,
# and require that the collections end up present. Then remove the creator call
# from that same region and require the test to stop passing, because a region
# that would pass without doing the work is not evidence that the work happens.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SRC="$REPO/install.sh"

PASS=0
FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  [FAIL] %s\n' "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$*" | sed 's/^/         /'; FAIL=$((FAIL + 1)); }

[ -r "$SRC" ] || { printf 'CANNOT-RUN: no install.sh at %s\n' "$SRC"; exit 78; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf 'COLLECTIONS ARE CREATED WHERE READINESS IS PROVEN\n\n'

# ---------------------------------------------------------------------------
# Extract the fix region from the SHIPPED file, so this cannot pass against a
# copy of the logic that only exists in the test.
# ---------------------------------------------------------------------------
region="$(awk '
    /^_INITIAL_HYDRATE_QDRANT_RETRIED=0$/ { f = 1 }
    f { print }
    f && /^fi$/ { exit }
' "$SRC")"

n_lines="$(printf '%s\n' "$region" | grep -c .)"
if [ "$n_lines" -lt 8 ] || [ "$n_lines" -gt 60 ]; then
    bad "extracted ${n_lines} lines for the create-at-proven-ready region, implausible; refusing to eval" \
        "the anchors moved, so this suite measures nothing until they are fixed"
    printf '\n== %s pass / %s fail ==\n' "$PASS" "$FAIL"
    exit 78
fi
ok "extracted the create-at-proven-ready region from the shipped install.sh (${n_lines} lines)"

printf '%s\n' "$region" | grep -q '_ostler_ensure_qdrant_collections' \
    && ok "the region calls the collection creator" \
    || bad "the region does not call the creator at all"

# ---------------------------------------------------------------------------
# A STORE THAT ANSWERS LATE. The membership reader reports `conversations`
# missing until the creator has actually run, and empty afterwards. That is the
# only thing that makes the must-fail arm below real: a reader that cleared
# itself on the second call would pass with or without the creator.
# ---------------------------------------------------------------------------
drive() { # $1 = region to run, $2 = marker file
    local rgn="$1" marker="$2"
    rm -f "$marker"
    (
        set +u
        MSG_INFO_QDRANT_CREATING_AT_PROVEN_READY="creating: %s"
        _INITIAL_HYDRATE_COLLECTIONS_AFTER=4
        _INITIAL_HYDRATE_QDRANT_MISSING="conversations"
        info()     { :; }
        gui_emit() { :; }
        # The late store: the creator succeeds, and only then does the reader
        # report a complete set.
        _ostler_ensure_qdrant_collections() { printf 'called\n' >> "$marker"; return 0; }
        _initial_hydrate_qdrant_missing_required() {
            if [ -s "$marker" ]; then printf ''; else printf 'conversations'; fi
        }
        eval "$rgn"
        printf 'MISSING=[%s] RETRIED=%s\n' "$_INITIAL_HYDRATE_QDRANT_MISSING" "${_INITIAL_HYDRATE_QDRANT_RETRIED:-unset}"
    )
}

out="$(drive "$region" "$WORK/called")"
printf '%s\n' "$out" | grep -q 'MISSING=\[\]' \
    && ok "a store that answers LATE ends with every required collection present" \
    || bad "the collection was still missing after the region ran" "$out"
printf '%s\n' "$out" | grep -q 'RETRIED=1' \
    && ok "the region records that it retried, so the severity block can escalate" \
    || bad "the retried flag was not set" "$out"
[ -s "$WORK/called" ] \
    && ok "the creator was actually invoked (not merely referenced)" \
    || bad "the creator was never called"

# ---------------------------------------------------------------------------
# MUST-FAIL. Strip the creator call out of the SAME region. The reader then
# never clears, so the collection stays missing. If this still passed, the arm
# above would be proving nothing about the creation.
# ---------------------------------------------------------------------------
mutant="$(printf '%s\n' "$region" | sed 's/^\([[:space:]]*\)_ostler_ensure_qdrant_collections || true$/\1: ;/')"
if printf '%s\n' "$mutant" | grep -q '_ostler_ensure_qdrant_collections || true'; then
    bad "the mutation did not land; the must-fail arm below would prove nothing"
else
    ok "the mutation landed (creator call removed from the region)"
    out_m="$(drive "$mutant" "$WORK/called_m")"
    if printf '%s\n' "$out_m" | grep -q 'MISSING=\[\]'; then
        bad "MUST-FAIL: without the creator the collection still came back present" "$out_m"
    else
        ok "MUST-FAIL: without the creator the collection stays missing, so the arm is real"
    fi
fi

# ---------------------------------------------------------------------------
# A store that answers but REFUSES the creates is an error, not a deferral.
# ---------------------------------------------------------------------------
sev="$(awk '
    /^if \[\[ "\$_INITIAL_HYDRATE_QDRANT_MISSING" == CANNOT-RUN:\*/ { f = 1 }
    f { print }
    f && /^fi$/ { n += 1; if (n == 2) exit }
' "$SRC")"
if printf '%s\n' "$sev" | grep -q 'MSG_ERR_QDRANT_COLLECTIONS_UNCREATABLE'; then
    ok "the severity block errs, not warns, once a live store has refused the creates"
else
    bad "no escalation after a retry: a store that answered and refused still only warns"
fi
printf '%s\n' "$sev" | grep -q 'MSG_WARN_QDRANT_COLLECTIONS_MISSING' \
    && ok "and the pre-retry warning is still there for the case that never retried" \
    || bad "the original warning arm was removed"

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
