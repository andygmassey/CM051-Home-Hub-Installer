#!/usr/bin/env bash
# owner_digest_knows_the_owner -- does the assistant's always-on digest know
# who it works for, and can the chat say where they have worked? (v1.0.107 #10)
#
# CONTEXT.md is injected into every chat prompt. If it has no "About you", or
# declares "nothing stored" for a section whose store is full, the assistant
# answers questions about its own owner from nothing. Three assertions, graded
# by lib/owner_digest.py from COUNTS and yes/no facts only:
#   (a) a non-empty "## About you" with a "- Work:" line naming >= 1
#       organisation, plus non-empty top-people and preferences sections;
#   (b) no "nothing stored" line for a section whose store holds data, every
#       store count measured on the box;
#   (c) "Where have I worked?" is answered with the seed organisation, which
#       the runner imports through the customer's own LinkedIn-export path
#       (lib/owner_employer_seed.sh).
# Runs after hydration; before it, every arm is CANNOT-RUN. The digest text,
# store contents and reply prose never leave the box.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="owner_digest_knows_the_owner"
PROBE_QUESTION="after hydration, does CONTEXT.md carry an About-you section with an organisation, non-empty people and preferences, no false 'nothing stored', and does the chat name the owner's seeded employer?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"

self_test() {
    if python3 "${_HERE}/lib/owner_digest.py" --self-test; then
        probe_examined 11 "mutated owner-digest facts"
        probe_fail "negative control behaved: an empty digest fails (a) and (b), a digest without the organisation fails (c), and every mutant went red by its own assertion"
    fi
    probe_examined 11 "mutated owner-digest facts"
    probe_pass "SELF-TEST BROKEN: the owner-digest judge let a known-bad fixture through"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; the digest was never read"
    local remote facts rc n
    remote="/tmp/ostler-probe-owner-digest-$$.py"
    box_run "printf %s '$(base64 < "${_HERE}/lib/owner_digest.py" | tr -d '\n')' | base64 -d > ${remote}" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the owner-digest reader on the box"
    facts="$(mktemp)"
    box_run "python3 ${remote} box --seed-org '${OSTLER_OWNER_SEED_ORG:-ExampleCo}' --seed-state '${OSTLER_OWNER_SEED_STATE:-unrun}' --neighbour-state '${OSTLER_NEIGHBOUR_SEED_STATE:-unrun}' --pref-seed-state '${OSTLER_PREF_SEED_STATE:-unrun}'; rm -f ${remote}" > "${facts}" 2>/dev/null
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${facts}" 2>/dev/null \
        || { rm -f "${facts}"; probe_cannot_run "the box-side reader returned no facts"; }
    out="$(python3 "${_HERE}/lib/owner_digest.py" judge "${facts}")"; rc=$?
    rm -f "${facts}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT|N/A) ')"
    probe_examined "${n}" "owner-digest assertions"
    [ "${n}" -gt 0 ] || probe_fail "the owner-digest judge printed no assertion; a silent probe is not a pass"
    # The seeding side removes its own seed. owner_knowledge_score ran after this probe and was
    # refused because the employer fact was still live (walk 132, MBP). The judgement above is
    # already taken, so removing the seed here changes no verdict. The forget prints the count
    # before and after: "before" above zero is the positive control (the seed was there and
    # the delete acted on it); "after=0" is the removal. Anything else is reported, never silent.
    if [ "${OSTLER_OWNER_SEED_STATE:-}" = "seeded" ] && [ "${OSTLER_OWNER_SEED_KEEP:-0}" != "1" ]; then
        . "${_HERE}/lib/owner_employer_seed.sh"
        _oes_out="$(owner_employer_seed_forget 2>&1)"
        printf '%s\n' "${_oes_out}" | sed 's/^/  own-end: /'
        _oes_before="$(printf '%s\n' "${_oes_out}" | sed -n 's/.*OES before=\([0-9]*\).*/\1/p' | tail -1)"
        _oes_after="$(printf '%s\n' "${_oes_out}" | sed -n 's/.*OES after=\([0-9]*\).*/\1/p' | tail -1)"
        # Archie's ruling: a removal that is not confirmed is a CLEANUP FAILED error on the
        # real-data box, printed to stderr and reflected in the cleanup step's exit status.
        # The probe's verdict below is NOT changed by it.
        . "${_HERE}/lib/owner_seed_cleanup.sh"
        _oc="$(owner_seed_cleanup_verdict "${_oes_before:-}" "${_oes_after:-}")"; _ocrc=$?
        printf '%s\n' "${_oc}" | sed 's/^/  own-end: /'
        if [ "${_ocrc}" -ne 0 ]; then
            # Archie's ruling: an unconfirmed removal on the real-data box is an ERROR and a
            # non-zero cleanup status. It does not change the verdict below.
            OWNER_SEED_CLEANUP_RC=1
            printf '%s\n' "${_oc}" >&2
        else
            OWNER_SEED_CLEANUP_RC=0
        fi
        probe_note "owner-employer seed cleanup status: rc=${OWNER_SEED_CLEANUP_RC}"
    fi

    case "${rc}" in
        0)  probe_pass "the digest knows the owner and the chat names the seeded employer" ;;
        78) probe_cannot_run "an owner-digest assertion could not be measured (see the CANNOT lines above)" ;;
        *)  probe_fail "the digest or the chat does not know the owner (see the FAIL lines above)" ;;
    esac
}

probe_main "$@"
