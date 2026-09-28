#!/usr/bin/env bash
# hub_screens_render_for_a_customer -- open the Hub like a customer and judge
# what it SHOWS, not what the engine answers (#106c, item s).
#
# Andy, v1.0.105 console walk, 2026-09-28: an unstyled wiki (every stylesheet
# a 401), a Timeline that ended part way through today with every row labelled
# MEETING, companies in People, a "Not me" that did not stick and a Tailscale
# switch reading OFF while Tailscale ran. Every probe before this one asked the
# engine over ssh; none opened a page, so all of it passed six walks.
#
# The WIKI is the first assertion group and the one the tag cannot go without:
# every stylesheet the in-app wiki loads must arrive as text/css, the theme
# header must be painted and the body font must not be the browser default.
# The wiki screenshot is saved into the walk record (OSTLER_WALK_SCREENS_DIR,
# else ./walk-screens/<timestamp>) as the visual evidence.
#
# Runs on the WALK DRIVER: forwards the box's Hub (127.0.0.1:8000) over ssh and
# drives headless Chromium (Playwright) at it with the box's own admin token.
# "Not me" persistence WRITES a correction, so it runs only when
# OSTLER_SCREENS_ALLOW_WRITE=1 (walk boxes); on a customer's box it is skipped
# and named as skipped.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="hub_screens_render_for_a_customer"
PROBE_QUESTION="opened as a customer would, is the wiki styled, does Timeline open on today with history reachable and real types, are People only people, does Not me stick, and does the Tailscale switch tell the truth?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"
_PY="${OSTLER_SCREENS_PYTHON:-${HOME}/walkdriver/pwvenv/bin/python}"

self_test() {
    if python3 "${_HERE}/lib/hub_screens.py" --self-test; then
        probe_examined 13 "mutated screen facts"
        probe_pass "every screen assertion fails on its mutant and the good fixture passes"
    fi
    probe_examined 13 "mutated screen facts"
    probe_fail "the screen judge did not catch every mutant (see above)"
}

run_probe() {
    [ -n "${OSTLER_BOX_HOST:-}" ] || probe_cannot_run "OSTLER_BOX_HOST is unset: this probe runs on the walk driver against a box"
    [ -x "${_PY}" ] || probe_cannot_run "no Playwright python at ${_PY} (set OSTLER_SCREENS_PYTHON; see scripts/box_walk_probes/README.md)"

    local out tokfile port fwd_pid ts_state rc
    out="${OSTLER_WALK_SCREENS_DIR:-$PWD/walk-screens/$(date -u +%Y%m%dT%H%M%SZ)}"
    mkdir -p "${out}" || probe_cannot_run "cannot create ${out}"
    tokfile="$(mktemp)"
    trap 'rm -f "${tokfile}"; [ -n "${fwd_pid:-}" ] && kill "${fwd_pid}" 2>/dev/null' EXIT

    box_run "cat \$HOME/.ostler/secrets/zeroclaw_admin_token" > "${tokfile}" 2>/dev/null
    [ -s "${tokfile}" ] || probe_cannot_run "could not read the box's Hub admin token over ssh"

    ts_state="$(box_run "s=\$HOME/.ostler/tailscale/tailscaled.sock; t=\$(command -v tailscale || echo /opt/homebrew/bin/tailscale); [ -S \"\$s\" ] && \"\$t\" --socket \"\$s\" status --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys; print(\"yes\" if json.load(sys.stdin).get(\"BackendState\")==\"Running\" else \"no\")' || echo no" 2>/dev/null | tail -n 1)"
    case "${ts_state}" in yes|no) ;; *) ts_state="unknown" ;; esac

    port="$(( 20000 + RANDOM % 20000 ))"
    ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
        -N -L "${port}:127.0.0.1:8000" "${OSTLER_BOX_HOST}" &
    fwd_pid=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        /usr/bin/curl -s -o /dev/null --noproxy '*' --max-time 2 "http://127.0.0.1:${port}/" && break
        sleep 1
    done

    set -- collect --base "http://127.0.0.1:${port}" --token-file "${tokfile}" \
        --out "${out}" --tailscale-running "${ts_state}"
    [ "${OSTLER_SCREENS_ALLOW_WRITE:-0}" = "1" ] && set -- "$@" --allow-write
    "${_PY}" "${_HERE}/lib/hub_screens.py" "$@"
    rc=$?
    probe_note "screenshots and facts: ${out}"
    [ "${OSTLER_SCREENS_ALLOW_WRITE:-0}" = "1" ] || probe_note "Not me persistence SKIPPED: read-only mode (set OSTLER_SCREENS_ALLOW_WRITE=1 on a walk box)"
    case "${rc}" in
        0)  probe_examined "$(grep -c '' "${out}/facts.json" 2>/dev/null || echo 0)" "lines of screen facts"
            probe_pass "every screen assertion held; wiki screenshot at ${out}/wiki.png" ;;
        78) probe_cannot_run "the browser could not run (see above)" ;;
        *)  probe_examined 1 "screen check run"
            probe_fail "a customer-visible screen is wrong (see the FAIL lines above; screenshots in ${out})" ;;
    esac
}

probe_main "$@"
