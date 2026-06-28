#!/usr/bin/env bash
# lib/permission_queue.sh
#
# Serial, completion-detected permission queue for the Ostler installer.
#
# WHY THIS EXISTS
# ---------------
# The mid-install permission glut (multiple TCC / System Settings / instruction
# windows stacking at ~76%) was previously "fixed" by serialising prompts with
# `sleep`. A sleep is not a gate: if a prompt or a System Settings animation is
# slow, the windows still overlap. That fix failed on the clean-box walk.
#
# This driver serialises by DETECTION OF COMPLETION, never by time:
#
#   For each permission step, in order:
#     1. raise exactly ONE ask (the caller's interact_fn shows one card / opens
#        one pane, bounded by one poll interval).
#     2. POLL the REAL OS permission state (the caller's detect_fn) until it
#        flips to "granted", OR the user explicitly taps Done / Skip.
#     3. only THEN move to the next step.
#
# The poll interval is merely the re-check cadence; a granted state exits the
# loop IMMEDIATELY. There is no fixed total wait, and step N+1 is never raised
# until step N has resolved -- so exactly one instruction is on screen at a
# time (directives 1, 2, 4 in docs/PERMISSION_CHOREOGRAPHY_v2.md).
#
# The driver is deliberately GENERIC: detect_fn and interact_fn are function
# names passed by the caller. Production wires them to osascript dialogs + the
# TCC.db probes in install.sh; the unit test (tests/test_permission_queue.sh)
# wires them to mocks, which is how we prove the loop waits on STATE not TIME
# without spawning a single macOS prompt.
#
# British English throughout. Bash 3.2 compatible (the macOS system bash).

# ── Tunables (overridable by the caller / tests) ───────────────────────────
#
# PERMQ_POLL_SECS   : re-check cadence between state polls (production: a few
#                     seconds; tests: 0 so they never sleep). The GATE is the
#                     state, not this number -- it only bounds how often we
#                     re-read the OS.
# PERMQ_MAX_POLLS   : a safety ceiling so a misconfigured detect_fn (or a user
#                     who walked away without granting or skipping) can never
#                     wedge the install forever. Reaching it yields "timeout",
#                     which -- like a denial -- does NOT block the install
#                     (install.sh has skip-on-deny fallbacks everywhere). On a
#                     real install this is large; the cadence keeps latency low.
: "${PERMQ_POLL_SECS:=3}"
: "${PERMQ_MAX_POLLS:=600}"

# Result of the most-recent step + an ordered audit trail of every step's
# outcome (label:result). The trail lets the unit test assert one-at-a-time
# sequencing and lets install.sh log what happened. Read by install.sh and the
# test harness, so shellcheck's "appears unused" is expected here.
# shellcheck disable=SC2034
PERMQ_LAST_RESULT=""
PERMQ_STEP_ORDER=()
# Scratch slot interact_fn writes the user's action into. A global (not stdout)
# so interact_fn runs in the CURRENT shell -- command substitution would fork a
# subshell and lose any state the production osascript wrapper needs to keep.
PERMQ_ACT=""

# ── Single step ────────────────────────────────────────────────────────────
#
# permq_run_step <label> <detect_fn> <interact_fn>
#
#   detect_fn   : function name. RETURNS 0 (success) when the REAL OS permission
#                 state is granted, non-zero otherwise. Run in the CURRENT shell
#                 (no command substitution) so a detect that needs to keep state
#                 -- or a test mock that counts its calls -- works. The function
#                 reads the real state internally (e.g. a TCC.db query).
#   interact_fn : function name. Displays ONE instruction card / opens ONE
#                 System Settings pane, bounded to roughly one poll interval,
#                 then sets the global PERMQ_ACT to the user's action:
#                     "skip" -> user chose to defer this permission
#                     "done" -> user says they have actioned it (we re-verify)
#                     "wait" -> card timed out with no choice (keep polling)
#                 In production this is an osascript `display dialog ... giving
#                 up after PERMQ_POLL_SECS` with Done + Skip buttons; the
#                 `giving up after` bounds the cycle so we re-read the OS state
#                 every interval WHILE keeping a clickable Done/Skip. The card
#                 is shown at most once per cycle, so only one window is ever up.
#
# Returns 0 when the step resolved (granted / skipped / done), 1 only on the
# safety-ceiling timeout. A non-zero return is informational -- callers do not
# abort the install on it.
#
# Sets PERMQ_LAST_RESULT to one of:
#   granted          - detect_fn confirmed the grant (the happy path)
#   skipped          - user tapped Skip
#   done_unverified  - user tapped Done but detect_fn still cannot confirm it
#                      (e.g. an ask whose grant we cannot cleanly poll on this
#                      macOS -- see the daemon-Automation note in the design
#                      doc; the user's explicit Done is the backstop)
#   timeout          - safety ceiling reached without a grant or a user action
permq_run_step() {
    local label="$1" detect_fn="$2" interact_fn="$3"
    local polls=0 result="" act=""

    while true; do
        # 1. STATE FIRST. The gate is the real permission state; if it is
        #    already granted we advance immediately, no matter what the card
        #    is doing. This is the line that makes serialisation state-based
        #    rather than time-based. detect_fn runs in the current shell.
        if "$detect_fn"; then
            result="granted"
            break
        fi

        # 2. Show the one card (bounded by one poll interval) and see whether
        #    the user made an explicit choice. interact_fn writes PERMQ_ACT.
        PERMQ_ACT="wait"
        "$interact_fn"
        act="$PERMQ_ACT"
        case "$act" in
            skip)
                result="skipped"
                break
                ;;
            done)
                # Trust-but-verify: the user says they actioned it; re-read the
                # real state. If we can confirm, it is a clean grant; if we
                # cannot poll this permission on this macOS, honour the user's
                # explicit Done as the backstop rather than looping forever.
                if "$detect_fn"; then
                    result="granted"
                else
                    result="done_unverified"
                fi
                break
                ;;
            *)
                # "wait" / anything else: the card timed out with no choice.
                # Re-loop and re-read the state. The interval-bounded card IS
                # the inter-poll cadence, so we do not sleep separately here
                # when interact_fn already blocked for the interval. The
                # explicit sleep below covers the test/mocked path where
                # interact_fn returns instantly.
                if [[ "${PERMQ_POLL_SECS:-3}" -gt 0 ]]; then
                    sleep "${PERMQ_POLL_SECS}" 2>/dev/null || true
                fi
                ;;
        esac

        polls=$((polls + 1))
        if [[ "$polls" -ge "${PERMQ_MAX_POLLS:-600}" ]]; then
            result="timeout"
            break
        fi
    done

    # Read by install.sh + the test harness, not within this file.
    # shellcheck disable=SC2034
    PERMQ_LAST_RESULT="$result"
    PERMQ_STEP_ORDER+=("${label}:${result}")

    case "$result" in
        granted|skipped|done_unverified) return 0 ;;
        *) return 1 ;;
    esac
}

# ── Run a queue of steps strictly in order ─────────────────────────────────
#
# permq_run <label1> <detect1> <interact1>  <label2> <detect2> <interact2> ...
#
# Steps run sequentially: step N+1's functions are not touched until step N has
# resolved. A step that ends denied / timeout does NOT abort the queue -- the
# install proceeds with reduced functionality (skip-on-deny), matching the rest
# of install.sh. Resets the audit trail at the start of each run.
permq_run() {
    PERMQ_STEP_ORDER=()
    while [[ "$#" -ge 3 ]]; do
        permq_run_step "$1" "$2" "$3" || true
        shift 3
    done
}

# ── Convenience: did a given labelled step end granted? ────────────────────
# Reads the audit trail. Lets install.sh branch on a specific outcome.
permq_step_result() {
    local want_label="$1" entry
    # Guard the empty-array case so callers running under `set -u` (install.sh
    # does) do not trip "unbound variable" on a fresh queue.
    [[ "${#PERMQ_STEP_ORDER[@]}" -eq 0 ]] && { printf 'absent'; return 0; }
    for entry in "${PERMQ_STEP_ORDER[@]}"; do
        if [[ "${entry%%:*}" == "$want_label" ]]; then
            printf '%s' "${entry#*:}"
            return 0
        fi
    done
    printf '%s' "absent"
}
