#!/usr/bin/env bash
# vane_background_fetch_settles -- v1.0.118 W5 + W8.
#
# QUESTION: did local web search (Vane) finish downloading in the background,
#           and if not, is the background download alive and saying why?
#
# Since v1.0.118 the 3.4 GB Vane image is pulled AFTER the install by the
# LaunchAgent com.ostler.vane-fetch, which writes ~/.ostler/state/vane-fetch.json.
# A background job that nothing checks ships dark, so this probe reads that
# file and the agent on the box:
#
#   PASS        state=ready AND the fetcher's own credentialled check answers
#               now (a stale "ready" over a dead container is not a pass).
#   CANNOT-RUN  pending: the job is loaded and its state is fresh (written in
#               the last 3 h): deferred, starting, pulling, retrying or
#               waiting. The verdict names the state, try N of M, and the
#               last error. Not a pass: web search is not there yet.
#   FAIL        no state file (the fetcher never ran: unwired), the agent is
#               not registered, "ready" but the credentialled check fails, an
#               unknown state, or a not-ready state not written for 3 h
#               (stalled; a live job rewrites it at every try and every wait, and one try
#               takes at most ~90 min even on a 0.5 MB/s link).
#
# --self-test drives judge() with fabricated readings and must go red.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="vane_background_fetch_settles"
PROBE_QUESTION="did local web search (Vane) finish downloading in the background, and if not, is the background download alive and saying why?"

STALE_S="${OSTLER_PROBE_VANE_STALE_S:-10800}"

# judge <state> <age_s> <agent_registered:yes|no> <healthy_now:yes|no>
#   -> PASS | PENDING | FAIL:<reason>
judge() {
    _s="$1"; _age="$2"; _agent="$3"; _ok="$4"
    case "$_s" in
        "")    printf 'FAIL:no-state-file\n'; return ;;
        ready)
            if [ "$_ok" = yes ]; then printf 'PASS\n'; else printf 'FAIL:ready-but-not-answering\n'; fi
            return ;;
        deferred|starting|pulling|retrying|waiting) ;;
        *)     printf 'FAIL:unknown-state\n'; return ;;
    esac
    # A still-downloading Vane that answers anyway (the run finished between
    # two reads) is ready in fact.
    if [ "$_ok" = yes ]; then printf 'PASS\n'; return; fi
    [ "$_agent" = yes ] || { printf 'FAIL:agent-not-registered\n'; return; }
    case "$_age" in ''|*[!0-9]*) printf 'FAIL:state-age-unreadable\n'; return ;; esac
    [ "$_age" -le "$STALE_S" ] || { printf 'FAIL:stalled\n'; return; }
    printf 'PENDING\n'
}

self_test() {
    fails=""; n=0
    t() { n=$((n + 1)); [ "$(judge "$1" "$2" "$3" "$4")" = "$5" ] || fails="${fails} $6"; }
    t ready 10 yes yes PASS                              ready-not-pass
    t ready 10 yes no  FAIL:ready-but-not-answering      stale-ready-passed
    t pulling 60 yes no PENDING                          pulling-not-pending
    t retrying 600 yes no PENDING                        retrying-not-pending
    t waiting 3000 yes no PENDING                        waiting-not-pending
    t deferred 30 yes no PENDING                         deferred-not-pending
    t pulling 60 no no FAIL:agent-not-registered         unregistered-agent-pending
    t pulling 99999 yes no FAIL:stalled                  stalled-read-as-pending
    t '' 0 yes no FAIL:no-state-file                     unwired-not-fail
    t bogus 10 yes no FAIL:unknown-state                 unknown-state-not-fail
    t pulling x yes no FAIL:state-age-unreadable         unreadable-age-pending
    t pulling 60 yes yes PASS                            answering-pending-not-pass
    probe_examined "$n" "fabricated readings"
    if [ -z "$fails" ]; then
        probe_fail "NEGATIVE CONTROL DEMONSTRATED (expected red for --self-test): ${n} of ${n} readings judged as designed; ready needs a live credentialled answer, a missing state file, an unregistered agent, a stale state and an unknown state all FAIL, and only a fresh not-ready state is pending"
    fi
    probe_pass "SELF-TEST BROKEN:${fails}"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing was asked"
    local home state_file raw state attempt max err updated now age agent ok verdict
    home="$(box_run 'printf %s "$HOME"')"
    [ -n "$home" ] || probe_cannot_run "could not read \$HOME on the box"
    state_file="${home}/.ostler/state/vane-fetch.json"
    raw="$(box_run "cat '${state_file}' 2>/dev/null")"
    state="$(printf '%s' "$raw" | sed -n 's/.*"state":"\([a-z]*\)".*/\1/p' | head -n 1)"
    attempt="$(printf '%s' "$raw" | sed -n 's/.*"attempt":\([0-9]*\).*/\1/p')"
    max="$(printf '%s' "$raw" | sed -n 's/.*"max_tries":\([0-9]*\).*/\1/p')"
    err="$(printf '%s' "$raw" | sed -n 's/.*"last_error":"\([^"]*\)".*/\1/p')"
    updated="$(printf '%s' "$raw" | sed -n 's/.*"updated_at":\([0-9]*\).*/\1/p')"
    now="$(box_run 'date +%s')"
    age=""
    case "${updated}${now}" in ''|*[!0-9]*) ;; *) age=$((now - updated)) ;; esac
    agent="$(box_run 'launchctl print "gui/$(id -u)/com.ostler.vane-fetch" >/dev/null 2>&1 && echo yes || echo no')"
    [ "$agent" = yes ] || agent=no
    ok="$(box_run "OSTLER_DIR='${home}/.ostler' /bin/bash '${home}/.ostler/bin/ostler-vane-fetch' healthy >/dev/null 2>&1 && echo yes || echo no")"
    [ "$ok" = yes ] || ok=no
    probe_examined 1 "background web search download (state=${state:-none}, agent=${agent}, credentialled-check=${ok})"
    verdict="$(judge "$state" "$age" "$agent" "$ok")"
    case "$verdict" in
        PASS)    probe_pass "web search is ready: the fetcher recorded state=ready${attempt:+ after try ${attempt}} and Vane answered the install's own credential just now" ;;
        PENDING) probe_cannot_run "pending: web search is still downloading in the background (state=${state}, try ${attempt:-?} of ${max:-?}, state written ${age}s ago${err:+, last error: ${err}}). The job is registered and alive. Not a pass until it is ready" ;;
        FAIL:no-state-file) probe_fail "no ${state_file}: the background web search download never ran, so nothing will ever fetch Vane on this box (unwired)" ;;
        FAIL:agent-not-registered) probe_fail "web search is not ready (state=${state}) and com.ostler.vane-fetch is not registered with launchd, so nothing will retry it" ;;
        FAIL:stalled) probe_fail "web search is not ready (state=${state}) and the fetcher has not written its state for ${age}s, longer than one try takes even on a 0.5 MB/s link" ;;
        FAIL:ready-but-not-answering) probe_fail "the fetcher recorded ready but Vane does not answer the install's own credential now" ;;
        *) probe_fail "web search state could not be judged (${verdict}, state='${state}')" ;;
    esac
}

probe_main "$@"
