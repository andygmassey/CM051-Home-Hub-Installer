#!/usr/bin/env bash
# scripts/box_walk_probes/lib/converge_wait.sh
# ============================================================================
# WAIT FOR THE GRAPH TO STOP MOVING, MEASURED. Not for a marker that says so.
#
# WHAT WENT WRONG ON THE v1.0.78 WALK. The install-time dedupe converge is
# SIGKILLed at a flat budget (install.sh :28815-28833) and the catch-up
# LaunchAgent that finishes the job (com.creativemachines.ostler.dedupe-catchup,
# StartInterval 600, RunAtLoad false) does not tick for ten minutes and then
# runs for twenty to forty more. The walk measured inside that window: contacts
# read 1629 during the walk and 1920 an hour later, on the same untouched box.
# people_count_agreement and people_stores_reconcile were not wrong about what
# they saw. They were asked too early, and a disagreement measured mid
# convergence is not a store defect.
#
# WHY THIS DOES NOT WAIT ON dedupe-converge.done, WHICH WAS THE FIRST DESIGN AND
# WAS WRONG. The converge log writes, in the same second:
#     RULE 2 refused 34 of 34 planned merge(s)
#     Converge hit max_rounds=10 without a fixpoint; remaining auto-merges
#         left for the next run
#     converge completed cleanly; marking done
# So .done means THE PROCESS EXITED, never that the graph converged. Gating on
# it would have turned both reconcile probes green on exactly the evidence they
# already had, only later: a declared state accepted in place of a measured one.
# The markers are read here for their killed_at and nothing else.
#
# WHAT IT WAITS FOR INSTEAD: the #1822 predicate applied directly. Two
# INDEPENDENT stores are read and must both stop changing:
#     oxigraph  :7878  SPARQL COUNT of pwg:Person
#     qdrant    :6333  points_count of the `people` collection
# Doctor's hydration count and the people API are VIEWS OF THE SAME OXIGRAPH,
# so they are one instrument wearing two hats and cannot corroborate each other.
# N consecutive readings (default 5) at an interval (default 60 s) in which
# neither store's own count changed, bounded by OSTLER_CONVERGE_WAIT_S.
#
# IT REQUIRES STABILITY, NOT AGREEMENT, AND THAT DISTINCTION IS LOAD-BEARING.
# Whether oxigraph and qdrant agree with each other IS people_stores_reconcile's
# question. A gate that required them to agree before letting that probe run
# could only ever release it when the answer was already yes, so the probe could
# never fail and the walk would be scoring a fixture instead of a store. Each
# store must stop moving; whether they then match is the probe's to report.
#
# IF STABILITY IS NEVER REACHED, BOTH PROBES ARE CANNOT-RUN, with the last
# readings and the killed marker's killed_at quoted. Never FAIL, never PASS: the
# graph was still moving, so neither probe could measure the thing it exists to
# measure, and a walk that reports a defect it did not observe is worse than one
# that says it could not look.
#
# WHAT THIS IS NOT. It does not close the root cause. The product still kills
# its own converge at a flat budget on a large account, converge_kill_is_recorded
# stays FAIL for exactly that reason, and nothing here sets
# OSTLER_DEDUPE_INSTALL_BUDGET_S or any other budget. A walk-only override would
# be the walk encoding the flag it is supposed to be testing.
#
# BASH 3.2 (macOS system bash). No associative arrays, no mapfile.
# ============================================================================

# stable | unstable | unreadable | skipped | unrun
CONVERGE_STATE="unrun"
CONVERGE_DETAIL=""

_cw_box_exec() {
    if [ -z "${OSTLER_BOX_HOST:-}" ]; then
        /bin/sh -c "$1"
    else
        /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=accept-new "$OSTLER_BOX_HOST" "$1"
    fi
}

# The two probes whose reading is only meaningful once the graph has settled.
converge_gates_probe() {
    case "$1" in
        people_count_agreement|people_stores_reconcile) return 0 ;;
        *) return 1 ;;
    esac
}

# One reading of both stores, printed as "<oxigraph> <qdrant>". A store that
# cannot be read prints "x" for its half, so an unreadable store can never be
# mistaken for a stable one: "x x" repeated is not stability, and the loop
# below refuses to count it.
#
# The credential is presented with -K, exactly as the probes do, and the path
# carries a literal $HOME expanded ON THE BOX rather than here (#1284: a path
# containing an unexpanded $HOME makes curl exit 26 before it issues anything,
# which reads as a dead store).
_cw_read_pair() {
    local conf="${OSTLER_PROBE_STORE_CURL_CONF:-\$HOME/.ostler/secrets/store-curl.conf}"
    local oxi="${OSTLER_OXIGRAPH_URL:-http://127.0.0.1:7878/query}"
    local qd="${OSTLER_QDRANT_URL:-http://127.0.0.1:6333}"
    local coll="${OSTLER_PROBE_COLLECTION:-people}"
    _cw_box_exec "
        _q='SELECT (COUNT(DISTINCT ?p) AS ?n) WHERE { ?p a <https://schema.ostler.ai/ontology#Person> }'
        _o=\$(/usr/bin/curl -sS --noproxy '*' --max-time 20 -K '${conf}' \
                -H 'Content-Type: application/sparql-query' \
                -H 'Accept: application/sparql-results+json' \
                --data-binary \"\$_q\" '${oxi}' 2>/dev/null \
             | /usr/bin/python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)[\"results\"][\"bindings\"][0][\"n\"][\"value\"])
except Exception:
    print(\"x\")' 2>/dev/null)
        _p=\$(/usr/bin/curl -sS --noproxy '*' --max-time 20 -K '${conf}' \
                '${qd}/collections/${coll}' 2>/dev/null \
             | /usr/bin/python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)[\"result\"][\"points_count\"])
except Exception:
    print(\"x\")' 2>/dev/null)
        printf '%s %s\n' \"\${_o:-x}\" \"\${_p:-x}\"
    " 2>/dev/null
}

converge_wait() {
    local state_dir="${OSTLER_CONVERGE_STATE_DIR:-\$HOME/.ostler/state}"
    local killed_m="${state_dir}/dedupe-converge.killed"
    local budget="${OSTLER_CONVERGE_WAIT_S:-2700}"
    local need="${OSTLER_STABILITY_READS:-5}"
    local gap="${OSTLER_STABILITY_INTERVAL_S:-60}"

    printf -- '--- CONVERGE: waiting for the two stores to STOP MOVING ---\n'

    if [ "${OSTLER_CONVERGE_SKIP:-0}" = "1" ]; then
        CONVERGE_STATE="skipped"
        CONVERGE_DETAIL="stability wait skipped by OSTLER_CONVERGE_SKIP=1"
        printf '  SKIPPED by OSTLER_CONVERGE_SKIP=1. The people probes will read whatever\n'
        printf '  state the graph is in, which on a fresh install is a moving one.\n\n'
        return 1
    fi

    printf '  instruments: oxigraph :7878 COUNT(pwg:Person), qdrant :6333 points_count(people)\n'
    printf '  two INDEPENDENT stores. Doctor and the people API are views of the same\n'
    printf '  oxigraph, so they cannot corroborate it.\n'
    printf '  predicate: %s consecutive readings %ss apart in which NEITHER count changed\n' "$need" "$gap"
    printf '  stability, NOT agreement: whether they match is people_stores_reconcile s\n'
    printf '  question, and gating on it would mean that probe could never fail.\n'
    printf '  budget: %ss (OSTLER_CONVERGE_WAIT_S)\n' "$budget"

    # THE BUDGET MUST ADVANCE EVEN WHEN THE SLEEP DOES NOT. Accounting used to
    # add `gap` per iteration, so an interval of 0 left `waited` at 0 for ever
    # and the loop never terminated: a walk that hangs rather than one that
    # reports CANNOT-RUN, which is the one thing this file promises not to do.
    # Found by this lib's own test hanging on its zero-interval fixture. The
    # sleep stays exactly as configured; only the accounting is floored.
    local step="$gap"
    [ "$step" -lt 1 ] && step=1
    local waited=0 same=0 prev="" cur=""
    while [ "$waited" -lt "$budget" ]; do
        cur="$(_cw_read_pair)"
        cur="$(printf '%s' "$cur" | tr -d '\r' | tail -1)"
        case "$cur" in
            *x*|"")
                # A store we could not read is not a stable store. Reset, so a
                # dead endpoint can never accumulate into a "settled" verdict.
                printf '  [%4ss] unreadable: %s (streak reset)\n' "$waited" "${cur:-no answer}"
                same=0; prev=""
                ;;
            "$prev")
                same=$((same + 1))
                printf '  [%4ss] %s  unchanged (%s of %s)\n' "$waited" "$cur" "$same" "$need"
                ;;
            *)
                [ -n "$prev" ] && printf '  [%4ss] %s  CHANGED from %s (streak reset)\n' "$waited" "$cur" "$prev"
                [ -z "$prev" ] && printf '  [%4ss] %s  first reading\n' "$waited" "$cur"
                same=1; prev="$cur"
                ;;
        esac
        if [ "$same" -ge "$need" ]; then
            CONVERGE_STATE="stable"
            CONVERGE_DETAIL="both stores held ${cur} across ${need} readings ${gap}s apart after ${waited}s"
            printf '  STABLE. Both counts held at "%s" across %s readings. The people probes\n' "$cur" "$need"
            printf '  now measure a settled graph rather than a moving one.\n\n'
            return 0
        fi
        sleep "$gap"
        waited=$((waited + step))
    done

    local killed_info
    killed_info="$(_cw_box_exec "cat ${killed_m} 2>/dev/null | tr '\n' ' '" 2>/dev/null)"
    case "$prev" in
        ""|*x*) CONVERGE_STATE="unreadable" ;;
        *)      CONVERGE_STATE="unstable" ;;
    esac
    CONVERGE_DETAIL="the graph was still moving after ${budget}s: the last reading of (oxigraph pwg:Person, qdrant people points) was [${cur:-no answer}] and it did not hold for ${need} readings ${gap}s apart.${killed_info:+ The install-time converge was killed [${killed_info}] and the catch-up agent (com.creativemachines.ostler.dedupe-catchup, StartInterval 600, RunAtLoad false) had not finished.} A count read now is mid-convergence, not a store defect."
    printf '  NOT STABLE after %ss. Last reading: %s\n' "$budget" "${cur:-no answer}"
    [ -n "$killed_info" ] && printf '  killed marker: %s\n' "$killed_info"
    printf '  people_count_agreement and people_stores_reconcile will be CANNOT-RUN.\n'
    printf '  A coverage statement, not a product verdict: never FAIL, never PASS.\n\n'
    return 1
}
