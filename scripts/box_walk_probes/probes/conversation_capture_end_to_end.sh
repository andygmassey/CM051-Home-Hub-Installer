#!/usr/bin/env bash
# conversation_capture_end_to_end -- does iPhone/Watch conversation capture
# work end to end on a real Hub install? (v1.0.107 #10, CORE to the product
# per Andy)
#
# Measures the path a paired iPhone or Watch actually uses, which nothing on
# any walk had exercised before this probe: POST a synthetic two-speaker
# transcript to /api/v1/conversation/process through the TLS companion
# gateway (:8443, device bearer), poll /api/v1/conversation/status/{id}
# until it reports complete (bounded; a timeout is reported as a FAIL with
# the last status seen, never a hang), assert all four artefacts the
# CLAUDE.md "Human-conversation 4-artefact spec" requires exist under
# ~/Documents/Ostler/Conversations/<date>/<slug>-<id>/ (summary.md,
# transcript.md, todos.md, each frontmatter-tagged -- the fourth "artefact",
# metadata, is folded into that frontmatter rather than a fourth file; see
# vendor/cm048_pipeline/src/conversation_writer.py's own docstring), confirm
# the conversation is still findable afterward (GET
# /api/v1/conversation/{id}/speakers; this codebase has no free-text
# conversation search/list route today), and confirm a second same-day
# conversation gets its own folder without disturbing the first.
#
# The two POSTs are a WRITE and happen in lib/conversation_capture_seed.sh,
# gated on READ_ONLY like every other seed (#2564). This probe only READS:
# it polls status, reads the filesystem, and makes GET calls, reusing the
# SAME device bearer the seed minted (via a box-side file path, never the
# raw value -- see that file's header comment).
#
# DEPENDENCY, STATED PLAINLY (same shape as PR #2653's "Depends on"):
# this probe exercises the gateway's GET-proxying of
# /api/v1/conversation/status/{id} and the ical-server processing-path
# handling, both under separate, concurrent fix PRs at the time this probe
# was written. Until both land, this probe is expected to FAIL on main --
# that FAIL is the defect this instrument exists to prove, not a bug in the
# probe. See the PR body for which commits to re-check against once those
# land.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="conversation_capture_end_to_end"
PROBE_QUESTION="through the paired gateway (:8443, device bearer): is a synthetic conversation accepted, does its status reach completed, do all three artefacts land frontmatter-tagged, is it still findable afterward, and does a second same-day conversation get its own folder without touching the first?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"

self_test() {
    if python3 "${_HERE}/lib/conversation_capture_e2e.py" --self-test; then
        probe_examined 5 "conversation-capture assertions, against real fixture folders plus synthetic mutants"
        probe_fail "negative control behaved: a real fixture folder with todos.md deliberately removed FAILS the artefacts assertion, and every other mutant (rejected submission, status timeout, 404 findability check, colliding folders, a changed first conversation) went red by its own assertion"
    fi
    probe_examined 5 "conversation-capture assertions, against real fixture folders plus synthetic mutants"
    probe_pass "SELF-TEST BROKEN: the conversation-capture judge let a known-bad fixture through"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; conversation capture was never exercised"

    if [ "${OSTLER_CONVCAP_SEED_STATE:-unrun}" != "seeded" ]; then
        probe_examined 0 "conversation-capture assertions (the seed did not reach 'seeded')"
        probe_cannot_run "lib/conversation_capture_seed.sh reports seed state '${OSTLER_CONVCAP_SEED_STATE:-unrun}'; no conversation was submitted through the gateway, so nothing downstream could be measured"
    fi

    local remote facts rc n
    remote="/tmp/ostler-probe-convcap-$$.py"
    box_run "printf %s '$(base64 < "${_HERE}/lib/conversation_capture_e2e.py" | tr -d '\n')' | base64 -d > ${remote}" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the conversation-capture reader on the box"

    facts="$(mktemp)"
    box_run "python3 ${remote} box \
        --seed-state '${OSTLER_CONVCAP_SEED_STATE:-unrun}' \
        --job-id-1 '${OSTLER_CONVCAP_JOB_ID_1:-}' \
        --job-id-2 '${OSTLER_CONVCAP_JOB_ID_2:-}' \
        --device-token-file '${OSTLER_CONVCAP_DEVICE_TOKEN_FILE:-\$HOME/.ostler/walk-seed/.convcap-devtoken}' \
        --date '${OSTLER_CONVCAP_DATE:-}' \
        --gateway '${OSTLER_CONVCAP_GATEWAY:-https://127.0.0.1:8443}' \
        --status-budget-s '${OSTLER_CONVCAP_STATUS_BUDGET_S:-180}'; rm -f ${remote}" > "${facts}" 2>/dev/null

    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${facts}" 2>/dev/null \
        || { rm -f "${facts}"; probe_cannot_run "the box-side reader returned no facts"; }

    out="$(python3 "${_HERE}/lib/conversation_capture_e2e.py" judge "${facts}")"; rc=$?
    rm -f "${facts}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT|N/A) ')"
    probe_examined "${n}" "conversation-capture assertions"
    [ "${n}" -gt 0 ] || probe_fail "the conversation-capture judge printed no assertion; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "conversation capture works end to end: accepted, completed, all artefacts present and frontmatter-tagged, findable afterward, and a second conversation does not disturb the first" ;;
        78) probe_cannot_run "a conversation-capture assertion could not be measured (see the CANNOT lines above)" ;;
        *)  probe_fail "conversation capture is broken somewhere in the path (see the FAIL lines above)" ;;
    esac
}

probe_main "$@"
