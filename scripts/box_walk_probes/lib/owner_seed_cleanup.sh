#!/usr/bin/env bash
# owner_seed_cleanup_verdict BEFORE AFTER
#
# The owner-employer seed is removed by the probe that judged against it (owner_digest_knows_the_owner).
# This decides whether that removal is CONFIRMED, from the counts the forget printed.
#   BEFORE above zero and AFTER 0   -> confirmed (the delete acted on a real seed). Prints a note, returns 0.
#   AFTER not 0, or AFTER unreadable -> CLEANUP FAILED on a real-data box: prints an ERROR line,
#                                      returns 1. The probe's verdict is NOT changed by this function.
# BEFORE 0 and AFTER 0            -> nothing was there to remove: a note, returns 0.
owner_seed_cleanup_verdict() {
    local before="$1" after="$2"
    if [ "${after:-x}" = "0" ]; then
        if [ "${before:-x}" = "0" ]; then
            printf 'owner-employer seed: nothing to remove (before=0, after=0)\n'
        else
            printf 'owner-employer seed removed at this probe'\''s own end (before=%s, after=0)\n' "${before:-?}"
        fi
        return 0
    fi
    printf 'ERROR: CLEANUP FAILED: owner-employer seed NOT confirmed removed (before=%s, after=%s). It is still in the graph and the next probe will read it.\n' \
        "${before:-?}" "${after:-unreadable}"
    return 1
}
