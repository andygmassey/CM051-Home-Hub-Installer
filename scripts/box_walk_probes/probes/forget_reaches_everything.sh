#!/usr/bin/env bash
# forget_reaches_everything -- does forgetting a SYNTHETIC person reach every store? (134)
#
# WALK_WRITES: on the box, plants one synthetic person pair (names carry the
# run stamp, reserved .example URIs) into the graph default graph; plants three
# synthetic conversation bundles under the bundles root (1:1 forgotten, multi-
# party forgotten+control, 1:1 control) and seven points into the Qdrant
# `conversations` collection; kicks the wiki recompile LaunchAgent; calls
# POST /api/v1/people/<forgotten>/forget ONCE; waits for the recompile; reads
# every store; judges. TEARDOWN: calls the same forget route for the CONTROL
# person, which removes the control's graph, Qdrant, bundle and wiki residue
# (the multi-party bundle becomes 1:1 with the control and is deleted). The
# forgotten person's residue is the thing under test and is expected to be
# zero already. Nothing else is written. Under OSTLER_WALK_READ_ONLY=1 (exported
# by run_box_walk.sh) this probe refuses with CANNOT-RUN before any write: the
# runner gates its own seeds, not probes, so the probe gates itself.
#
# QUESTION: after one forget of a synthetic person, is that person gone from
# the graph, the Qdrant conversations gists (facts and summaries), the source
# bundles on disk (1:1 deleted, multi-party redacted), the compiled wiki
# (person, timeline and other pages) and the rollback anchors, while a control
# person planted in the same run survives in each of them?
#
# PRODUCT UNDER TEST (read, not assumed; see lib/forget_reach.py header):
#   CM041 PR #288 b2fb543f2: ical-server.py :11591 route, :2978 handler,
#     forget_conversations.py (bundles, gist_delete_filter, kick).
#   CM044 PR #451 3b5caae41: compiler/erasure.py, compile.py, ledger.
# A build without PR #288 answers the route without the 134 keys and this
# probe says CANNOT-RUN, never PASS. Whether PR #451 is in the build is
# measured by the wiki legs (residue or not), not assumed.
#
# NOT INSTRUMENTED (named, not graded): (1) that the wiki compile has FINISHED
# after the kick. The wait polls launchctl `state = running`, and a kick that
# has not yet started reads as quiet. A residue in the wiki may therefore be
# the stale pre-kick compile. (2) the served docs root (WIKI_OUTPUT_DIR=/wiki/docs
# inside the container, install.sh:22292) is not read: only the host vault at
# ${OSTLER_WIKI_DIR:-~/Ostler/Wiki} is. (3) AI-chat pages are bucketed as
# "other"; their locale path (_locale.heading("ai_chats")) was not checked.
# (4) the planted bundle frontmatter follows the CM041 PR #288 test fixture,
# not conversation_writer.py output, so a wiki that will not render it reads
# CANNOT (precondition), not PASS. (5) the derived state/conversations_mirror
# copy is not judged: it is one tick behind by design (lib/ostler-conversations-mirror.sh).
# (6) facts whose subject is an id rather than the slug (CM048 ingest.py:1132
# "other:<slug or id>") are not matched by gist_delete_filter and are not
# planted, so that leg is unmeasured.
#
# Budgets: OSTLER_FORGET_WIKI_WAIT_S (default 1800), OSTLER_API_BASE via
# OSTLER_PROBE_API_BASE (default 127.0.0.1:8090, as people_seed_and_retrieval).
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="forget_reaches_everything"
PROBE_QUESTION="after one forget of a synthetic person, is that person gone from the graph, the Qdrant conversations gists, the source bundles, the compiled wiki and the rollback anchors, while a control person planted in the same run survives in each?"

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_LIB="${_HERE}/lib/forget_reach.py"
_STORES="graph qdrant_facts qdrant_summaries bundles wiki anchors ledger"

self_test() {
    local out rc s n
    out="$(python3 "${_LIB}" --self-test 2>&1)"; rc=$?
    printf '%s\n' "${out}"
    if [ "${rc}" -ne 0 ]; then
        printf 'VERDICT: BROKEN -- forget_reach judge self-test mismatched (rc=%s); the judge cannot be trusted\n' "${rc}"
        exit "${PROBE_EX_FAIL}"
    fi
    n=0
    for s in ${_STORES}; do
        out="$(python3 "${_LIB}" judge --bad-only "${s}")"; rc=$?
        printf -- '--- negative control: residue in %s only\n%s\n' "${s}" "${out}"
        if [ "${rc}" -ne "${PROBE_EX_FAIL}" ]; then
            printf 'VERDICT: BROKEN -- the judge let a residue planted in the %s store alone through (rc=%s); a store the judge does not grade is not measured\n' "${s}" "${rc}"
            exit "${PROBE_EX_FAIL}"
        fi
        n=$((n + $(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT) ')))
    done
    probe_examined "${n}" "forget-reach assertions across seven single-store negative controls (graph, qdrant facts, qdrant summaries, bundles, wiki, anchors, ledger)"
    probe_fail "negative controls behaved: a residue planted in each of the seven stores, alone, turned the verdict FAIL"
}

# Spec for one person, written locally, then staged to the box. Pure JSON, no
# secret. Paths are "~/..." and expanded ON THE BOX by forget_reach.py. Every
# input arrives in the environment, never as a positional argument.
_fr_spec() {
    # _fr_spec <out-file> <slug> <name>
    FR_OUT="$1" FR_SLUG="$2" FR_NAME="$3" python3 - <<'PY'
import json, os
e = os.environ
api = e["FR_API"]
planted = json.loads(e["FR_PLANTED"])
fslug, fname = e["FR_FSLUG"], e["FR_FNAME"]
cslug, cname = e["FR_CSLUG"], e["FR_CNAME"]
spec = {
    "slug": e["FR_SLUG"],
    "api_base": api, "qdrant": e["FR_QDRANT"], "oxigraph": e["FR_OXI"], "store_conf": e["FR_CONF"],
    "bundles_root": e["FR_BUNDLES"], "vault": e["FR_VAULT"], "anchors": e["FR_ANCHORS"],
    "ledger": e["FR_LEDGER"], "token_path": e["FR_TOKEN"], "stamp": e["FR_STAMP"], "date": e["FR_DATE"],
    "forgotten": {"slug": fslug, "name": fname, "uri": "https://probe.example/forget-walk/person/" + fslug},
    "control": {"slug": cslug, "name": cname, "uri": "https://probe.example/forget-walk/person/" + cslug},
    "planted": planted,
}
json.dump(spec, open(e["FR_OUT"], "w"), sort_keys=True)
PY
}

run_probe() {
    if [ "${OSTLER_WALK_READ_ONLY:-0}" = "1" ]; then
        probe_cannot_run "read-only walk: this probe writes a synthetic person and forgets it, so it does not run under --read-only; nothing was written"
    fi
    box_reachable || probe_cannot_run "cannot reach the box; no forget was issued and nothing was measured"

    local api="${OSTLER_PROBE_API_BASE:-http://127.0.0.1:8090}"
    local wiki_wait="${OSTLER_FORGET_WIKI_WAIT_S:-1800}"
    local label="com.creativemachines.ostler.wiki-recompile"
    local stamp_c stamp_d work fslug fname cslug cname remote
    stamp_c="$(date -u +%Y%m%d%H%M%S)"
    stamp_d="$(date -u +%Y-%m-%d)"
    work="$(mktemp -d "${TMPDIR:-/tmp}/forget-reach.XXXXXX")" || probe_cannot_run "could not create a local scratch directory"
    trap "rm -rf '${work}'" EXIT

    fslug="walkforget-alpha-${stamp_c}"; fname="Walkforget Alpha ${stamp_c}"
    cslug="walkforget-bravo-${stamp_c}"; cname="Walkforget Bravo ${stamp_c}"
    remote="/tmp/ostler-probe-forget-$$"

    # Config, resolved ON THE BOX by the reader. These are the defaults the
    # product uses; each is overridable for a box that moved them.
    local planted_json
    planted_json="{\"one_to_one\":\"fw-1to1-${stamp_c}\",\"multi\":\"fw-multi-${stamp_c}\",\"control_one_to_one\":\"fw-ctl-${stamp_c}\"}"
    export FR_API="${api}" FR_PLANTED="${planted_json}" FR_FSLUG="${fslug}" FR_FNAME="${fname}" FR_CSLUG="${cslug}" FR_CNAME="${cname}"
    export FR_QDRANT="${OSTLER_PROBE_QDRANT_BASE:-http://127.0.0.1:6333}"
    export FR_OXI="${OSTLER_OXIGRAPH_URL:-http://127.0.0.1:7878}"
    export FR_CONF="${OSTLER_PROBE_STORE_CURL_CONF:-~/.ostler/secrets/store-curl.conf}"
    export FR_BUNDLES="${OSTLER_FORGET_BUNDLES_ROOT:-~/Ostler/Conversations}"
    export FR_VAULT="${OSTLER_WIKI_DIR:-~/Ostler/Wiki}"
    export FR_ANCHORS="${OSTLER_WIKI_ROLLBACK_ROOT:-~/.ostler/wiki-rollback}"
    export FR_LEDGER="${OSTLER_FORGET_LEDGER:-~/.ostler/queue/forget_audit.log}"
    export FR_TOKEN="${OSTLER_PROBE_TOKEN_PATH:-~/.ostler/secrets/service_token}"
    export FR_STAMP="${stamp_c}" FR_DATE="${stamp_d}"

    # The control's spec is the teardown; the forgotten spec carries the slug to forget.
    _fr_spec "${work}/spec_forgotten.json" "${fslug}" "${fname}" || probe_cannot_run "could not build the forgotten-person spec locally"
    _fr_spec "${work}/spec_control.json" "${cslug}" "${cname}" || probe_cannot_run "could not build the control-person spec locally"

    # Stage the reader and both specs ON THE BOX (base64, as the conversation probe does).
    local b64
    b64="$(base64 < "${_LIB}" | tr -d '\n')"
    box_run "mkdir -p ${remote} && printf %s '${b64}' | base64 -d > ${remote}/forget_reach.py" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the forget-reach reader on the box"
    for f in spec_forgotten spec_control; do
        b64="$(base64 < "${work}/${f}.json" | tr -d '\n')"
        box_run "printf %s '${b64}' | base64 -d > ${remote}/${f}.json" >/dev/null 2>&1 \
            || { box_run "rm -rf ${remote}" >/dev/null 2>&1; probe_cannot_run "could not stage ${f} on the box"; }
    done
    local R="python3 ${remote}/forget_reach.py"

    # 1. PLANT (write). A refusal here is a missing prerequisite, not a pass.
    box_run_v "${R} plant --spec ${remote}/spec_forgotten.json" > "${work}/plant.json" 2> "${work}/plant.err"
    python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('ok') else 1)" "${work}/plant.json" 2>/dev/null \
        || { box_run "rm -rf ${remote}" >/dev/null 2>&1; probe_examined 0 "forget-reach assertions (the seed did not plant)"; probe_cannot_run "the synthetic seed was refused on the box: $(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('reason','no reason; plant.json unreadable'))" "${work}/plant.json" 2>/dev/null || echo "plant produced no readable reply: $(head -c 200 "${work}/plant.err")")"; }

    # 2. WIKI RECOMPILE BEFORE THE FORGET, so the precondition can see the synthetic people.
    box_run_v "/bin/launchctl kickstart gui/\$(id -u)/${label}" >/dev/null 2>&1 \
        || probe_note "kickstart of ${label} before the forget returned non-zero (the wiki may not carry the synthetic people)"
    sleep 5
    _forget_wait_quiet "${label}" "${wiki_wait}" || { _forget_teardown "${R}" "${remote}"; probe_examined 0 "forget-reach assertions (the wiki recompile did not settle)"; probe_cannot_run "the wiki recompile (${label}) was still running after ${wiki_wait}s before the forget; the precondition cannot be read against a compile in progress"; }

    # 3. PRECONDITION READ (read only).
    box_run_v "${R} read --spec ${remote}/spec_forgotten.json" > "${work}/pre.json" 2> "${work}/pre.err" \
        || { _forget_teardown "${R}" "${remote}"; probe_examined 0 "forget-reach assertions (the pre-forget read did not run)"; probe_cannot_run "the pre-forget reader did not run on the box: $(head -c 200 "${work}/pre.err")"; }

    # 4. THE FORGET (write, under test). ONE call.
    box_run_v "${R} forget --spec ${remote}/spec_forgotten.json" > "${work}/forget.json" 2> "${work}/forget.err"

    # 5. WAIT FOR THE KICKED RECOMPILE, then POST-FORGET READ.
    sleep 5
    _forget_wait_quiet "${label}" "${wiki_wait}" || probe_note "the wiki recompile was still running after ${wiki_wait}s; the post-forget wiki read may show a compile that had not finished"
    box_run_v "${R} read --spec ${remote}/spec_forgotten.json" > "${work}/post.json" 2> "${work}/post.err" \
        || { _forget_teardown "${R}" "${remote}"; probe_examined 0 "forget-reach assertions (the post-forget read did not run)"; probe_cannot_run "the post-forget reader did not run on the box: $(head -c 200 "${work}/post.err")"; }

    # 6. TEARDOWN the control person (write), then judge. The judge does not
    #    depend on the teardown result, so a failed teardown cannot hide a verdict.
    _forget_teardown "${R}" "${remote}" > "${work}/teardown.txt" 2>&1

    python3 "${_LIB}" assemble --spec "${work}/spec_forgotten.json" --pre "${work}/pre.json" --post "${work}/post.json" --forget "${work}/forget.json" > "${work}/facts.json" 2>"${work}/assemble.err" \
        || probe_cannot_run "could not assemble the facts document: $(head -c 200 "${work}/assemble.err")"

    local out rc n
    out="$(python3 "${_LIB}" judge "${work}/facts.json")"; rc=$?
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "${n}" "forget-reach assertions (forgotten and control person, across graph, qdrant gists, bundles, wiki, rollback anchors, ledger)"
    [ "${n}" -gt 0 ] || probe_fail "the forget-reach judge printed no assertion; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "forget reached every store for the synthetic person and the control person survived in each" ;;
        78) probe_cannot_run "a forget-reach assertion could not be measured (see the CANNOT lines above)" ;;
        *)  probe_fail "forget left residue or over-erased the control (see the FAIL lines above)" ;;
    esac
}

# _forget_wait_quiet <label> <budget-s>: poll launchctl until the job is not running.
# Returns 0 quiet, 1 budget exhausted, 2 unreadable.
_forget_wait_quiet() {
    local label="$1" budget="$2" waited=0 out
    while :; do
        out="$(box_run_v "/bin/launchctl print gui/\$(id -u)/${label} 2>&1")" || { probe_note "launchctl print ${label}: unreadable"; return 2; }
        case "${out}" in
            *"state = running"*)
                [ "${waited}" -ge "${budget}" ] && return 1
                sleep "${OSTLER_PROBE_TICK_POLL_S:-15}"
                waited=$((waited + ${OSTLER_PROBE_TICK_POLL_S:-15}))
                ;;
            *) return 0 ;;
        esac
    done
}

# _forget_teardown <R> <remote>: forget the CONTROL person, then remove staging.
_forget_teardown() {
    local R="$1" remote="$2"
    box_run_v "${R} forget --spec ${remote}/spec_control.json" 2>&1 | head -c 400
    box_run "rm -rf ${remote}" >/dev/null 2>&1
    true
}

probe_main "$@"
