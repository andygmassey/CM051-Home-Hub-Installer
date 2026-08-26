#!/usr/bin/env bash
# probes/pair_state_agreement.sh
# ============================================================================
# QUESTION: do all available pairing signals on this box tell the same story?
#
# WHY IT MATTERS. Task #265 was the root cause of an entire failed box walk,
# and task #208 was its most customer-visible face: Doctor displayed "Paired:
# Your phone is connected" while devices.db held ZERO rows. The daemon's
# /health returned paired:true from a different source of truth than the table
# that actually stores devices.
#
# A LIE IN THE AFFIRMATIVE DIRECTION IS THE WORST POSSIBLE FAILURE HERE.
# An honest "not paired" sends the customer to the pair flow. A false "paired"
# sends them to support, because every feature that depends on the phone then
# fails for reasons the UI insists are impossible.
#
# THE ASSERTION IS AGREEMENT, NOT A PARTICULAR STATE. An unpaired box is a
# perfectly good result on a fresh install. What must never happen is two
# signals disagreeing.
#
# ── 2026-08-26: THIS PROBE PRODUCED THE LIE IT EXISTS TO CATCH ──────────────
#
# The walk recorded `CANNOT-RUN -- 1 of 3 signals`. That number was itself
# wrong: 0 of 3 were genuinely readable, and the third FABRICATED a confident
# answer. Five defects, each measured, each now under test:
#
#  1. HEALTH_URL pointed at :8089/doctor/api/health -- the Doctor's LIVENESS
#     route. Measured on the box: HTTP 200, body
#     {"status":"healthy","service":"ostler-doctor"}, occurrences of "paired"
#     = ZERO. The flag lives on the DAEMON (:8000/health), which carries
#     paired / companion_paired / require_pairing. Signal 1 was never once
#     readable, on any box, in any walk.
#
#  2. 🔴 THE PARSER MANUFACTURED AN AFFIRMATIVE LIE. It was:
#         case "$body" in *'"paired"'*'true'*) printf 'true' ;;
#     which matches `"paired"` and then ANY LATER `true` anywhere in the body.
#     Measured against real daemon shapes:
#       {"companion_paired":false,"paired":false,"require_pairing":false} -> false
#       {"companion_paired":false,"paired":false,"require_pairing":true}  -> true  ← LIE
#       {"paired":false,"token_paired":false,"healthy":true}              -> true  ← LIE
#     An UNPAIRED box reporting paired, from the probe whose header calls that
#     the worst possible failure. Now matched FIELD-EXACT: `"paired":true`.
#     (`"companion_paired"` and `"token_paired"` cannot collide -- the leading
#     quote in `"paired"` is not present in either.)
#
#  3. 🔴 THE STDERR WAS SWALLOWED TWICE, so deleting the inner redirect would
#     have been an INERT "fix". The reader did `sqlite3 ... 2>/dev/null` AND
#     box_run itself does `ssh ... 2>/dev/null` (lib/probe.sh:120). The reason
#     a read failed IS the answer here, so these readers use box_run_v.
#
#  4. THE `UNAVAILABLE` BRANCH OF THE MARKER READER WAS UNREACHABLE.
#         out=$(ls $DIR/*.json 2>/dev/null | wc -l | tr -d ' ')
#         case "$out" in ''|*[!0-9]*) UNAVAILABLE ;; 0) false ;; *) true ;; esac
#     `wc -l` emits a digit on empty input, so the first arm can never match.
#     A directory that HAS NEVER EXISTED returned `false` -- "definitely not
#     paired" -- and counted itself as a readable signal. That is the whole of
#     the bogus "1 of 3". Existence and readability are now tested ON THE BOX
#     before the count is believed.
#
#  5. 🔴 THE SELF-TEST NEVER EXECUTED A SINGLE READER. Every signal_* began
#     with `if [ "$SELF_TEST_LOCAL" = 1 ]; then printf "$FAKE_..."; return; fi`
#     and self_test only ever called adjudicate(). So three broken readers sat
#     behind a negative control that reported "correct on all 4 combinations".
#     The control could not see them BY CONSTRUCTION.
#     The repair is structural, not three patches: PARSING is now split from
#     TRANSPORT into classify_* functions that are pure, and the self-test
#     drives those directly -- including against real temporary directories.
#     A reader defect now has somewhere to be caught.
#
# CANNOT-RUN IS NOT FAIL AND IS NOT PASS. A signal that could not be read is
# reported with the REASON it could not be read, never as a state.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="pair_state_agreement"
PROBE_QUESTION="do the daemon health flag, devices.db, and pair-state file all agree on whether a phone is paired?"

# The DAEMON carries the pairing flag. The Doctor's /doctor/api/health is a
# liveness route and carries no such field -- pointing here was defect 1.
HEALTH_URL="${OSTLER_HEALTH_URL:-http://127.0.0.1:8000/health}"
DEVICES_DB="${OSTLER_DEVICES_DB:-\$HOME/.ostler/devices.db}"
MARKER_DIR="${OSTLER_PAIR_MARKER_DIR:-\$HOME/.ostler/paired_devices}"

# --- classifiers: PURE, no transport, directly under test -------------------
# Each prints  true | false | UNAVAILABLE:<reason>

# classify_health_body <body>
classify_health_body() {
    local body="$1" compact hit
    if [ -z "$body" ]; then printf 'UNAVAILABLE:empty-body'; return; fi
    compact="$(tr -d '[:space:]' <<< "$body")"
    # FIELD-EXACT. Not "contains paired, then contains true somewhere later".
    hit="$(grep -m1 -oE '"paired":(true|false)' <<< "$compact")" || hit=""
    case "$hit" in
        '"paired":true')  printf 'true' ;;
        '"paired":false') printf 'false' ;;
        *)                printf 'UNAVAILABLE:no-paired-field' ;;
    esac
}

# classify_devices_output <stdout> <stderr>
# The REASON is the answer. "no schema" and "cannot read" are different facts,
# and neither of them is "no phone paired".
classify_devices_output() {
    local out="$1" err="$2"
    case "$err" in
        *'no such table'*)       printf 'UNAVAILABLE:no-schema'; return ;;
        *'unable to open'*)      printf 'UNAVAILABLE:cannot-open-db'; return ;;
        *'no such file'*)        printf 'UNAVAILABLE:no-db-file'; return ;;
        *'not found'*)           printf 'UNAVAILABLE:no-sqlite3'; return ;;
        *'authorization denied'*|*'permission denied'*)
                                 printf 'UNAVAILABLE:permission-denied'; return ;;
    esac
    case "$out" in
        '')          printf 'UNAVAILABLE:empty-read' ;;
        *[!0-9]*)    printf 'UNAVAILABLE:non-numeric' ;;
        0)           printf 'false' ;;
        *)           printf 'true' ;;
    esac
}

# classify_marker_token <token>
# <token> is what the box reported: NODIR | NOREAD | <count>
classify_marker_token() {
    case "$1" in
        NODIR)     printf 'UNAVAILABLE:no-marker-dir' ;;
        NOREAD)    printf 'UNAVAILABLE:marker-dir-unreadable' ;;
        '')        printf 'UNAVAILABLE:empty-read' ;;
        *[!0-9]*)  printf 'UNAVAILABLE:non-numeric' ;;
        0)         printf 'false' ;;
        *)         printf 'true' ;;
    esac
}

# classify_marker_dir <dir> -- the LOCAL equivalent, so the self-test can drive
# the same logic against a real filesystem instead of a stubbed string.
classify_marker_dir() {
    local dir="$1"
    if [ ! -d "$dir" ]; then classify_marker_token NODIR; return; fi
    if [ ! -r "$dir" ] || [ ! -x "$dir" ]; then classify_marker_token NOREAD; return; fi
    classify_marker_token "$(ls -1 "$dir"/*.json 2>/dev/null | wc -l | tr -d ' ')"
}

# --- transport: thin, and it does NOT discard stderr ------------------------

signal_health_flag() {
    classify_health_body "$(box_run_v "curl -sS -m 5 '$HEALTH_URL'" 2>&1)"
}

signal_devices_rows() {
    local combined out err
    # stderr is the discriminator, so it must survive BOTH redirect layers.
    combined="$(box_run_v "sqlite3 \"$DEVICES_DB\" 'SELECT COUNT(*) FROM devices;'" 2>&1)"
    # sqlite3 prints errors on stderr and the count on stdout; merged here, a
    # well-formed answer is a bare integer and anything else is a reason.
    case "$combined" in
        ''|*[!0-9]*) out=""; err="$combined" ;;
        *)           out="$combined"; err="" ;;
    esac
    classify_devices_output "$out" "$err"
}

signal_pair_marker() {
    # Existence and readability are decided ON THE BOX, before any count.
    classify_marker_token "$(box_run_v \
        "if [ ! -d $MARKER_DIR ]; then echo NODIR; \
         elif [ ! -r $MARKER_DIR ] || [ ! -x $MARKER_DIR ]; then echo NOREAD; \
         else ls -1 $MARKER_DIR/*.json 2>/dev/null | wc -l | tr -d ' '; fi" 2>&1)"
}

# --- the comparison, shared by run_probe and self_test ---------------------

adjudicate() {
    # adjudicate <health> <devices> <marker>
    # Prints a verdict token on stdout: AGREE | DISAGREE | INSUFFICIENT
    # followed by a space and a human-readable detail string.
    local h="$1" d="$2" m="$3"
    local seen="" n=0

    for v in "$h" "$d" "$m"; do
        # UNAVAILABLE:<reason> is still UNAVAILABLE. Match the PREFIX, so a
        # reason string can never be mistaken for a state.
        case "$v" in
            UNAVAILABLE*) : ;;
            *) seen="$seen $v"; n=$((n + 1)) ;;
        esac
    done

    # ONE signal is not agreement. Two signals agreeing is the minimum that
    # means anything, because a single reading cannot contradict itself and
    # would therefore pass forever.
    if [ "$n" -lt 2 ]; then
        printf 'INSUFFICIENT only %s of 3 pairing signals were readable' "$n"
        return
    fi

    local t=0 f=0
    for v in $seen; do
        if [ "$v" = "true" ]; then t=$((t + 1)); else f=$((f + 1)); fi
    done

    if [ "$t" -gt 0 ] && [ "$f" -gt 0 ]; then
        printf 'DISAGREE %s of %s signals say paired and %s say not paired' "$t" "$n" "$f"
        return
    fi
    printf 'AGREE all %s readable signals say paired=%s' "$n" "$([ "$t" -gt 0 ] && echo true || echo false)"
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "cannot reach box ${OSTLER_BOX_HOST:-(local)} over ssh; no pairing signals read"
    fi

    local h d m
    h="$(signal_health_flag)"
    d="$(signal_devices_rows)"
    m="$(signal_pair_marker)"

    # NAME THE SUBJECT, not just the instrument.
    probe_note "daemon health paired flag : $h   <- $HEALTH_URL"
    probe_note "devices.db row count      : $d   <- $DEVICES_DB"
    probe_note "pair marker *.json        : $m   <- $MARKER_DIR"

    local readable=0
    for v in "$h" "$d" "$m"; do
        case "$v" in UNAVAILABLE*) : ;; *) readable=$((readable + 1)) ;; esac
    done
    probe_examined "$readable" "of 3 pairing signals readable (a reason, not a state, is NOT readable)"

    local result
    result="$(adjudicate "$h" "$d" "$m")"
    local token="${result%% *}"
    local detail="${result#* }"

    case "$token" in
        DISAGREE)
            probe_fail "pairing state is split-brain: $detail (tasks #265, #208). A false 'paired' is worse than an honest 'not paired'."
            ;;
        INSUFFICIENT)
            probe_cannot_run "$detail -- one signal cannot contradict itself, so this would pass forever. Reasons above name which surface failed and why."
            ;;
        *)
            probe_pass "$detail"
            ;;
    esac
}

self_test() {
    local r tmp
    probe_examined 16 "synthetic combinations across 3 classifiers + the adjudicator (negative control)"

    # ── A. THE ADJUDICATOR (4 cases; these are the ones that always passed) ──

    r="$(adjudicate true false UNAVAILABLE:x)"
    if [ "${r%% *}" != "DISAGREE" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: health=true vs devices=false adjudicated as '${r%% *}', not DISAGREE. This probe cannot detect task #208."
    fi
    r="$(adjudicate false false false)"
    if [ "${r%% *}" != "AGREE" ]; then
        probe_pass "NEGATIVE CONTROL OVER-FIRED: a consistently unpaired box adjudicated as '${r%% *}'. It would fail every fresh install."
    fi
    r="$(adjudicate true true true)"
    if [ "${r%% *}" != "AGREE" ]; then
        probe_pass "NEGATIVE CONTROL OVER-FIRED: a consistently paired box adjudicated as '${r%% *}'."
    fi
    r="$(adjudicate true UNAVAILABLE:x UNAVAILABLE:y)"
    if [ "${r%% *}" != "INSUFFICIENT" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: a single readable signal adjudicated as '${r%% *}'. One signal cannot contradict itself, so this probe would report agreement forever."
    fi

    # ── B. HEALTH PARSER. Cases 2 and 3 are the MEASURED affirmative lie. ────

    r="$(classify_health_body '{"companion_paired":false,"paired":false,"require_pairing":false}')"
    [ "$r" = "false" ] || probe_pass "HEALTH PARSER: honest unpaired body read as '$r', expected false."

    r="$(classify_health_body '{"companion_paired":false,"paired":false,"require_pairing":true}')"
    [ "$r" = "false" ] || probe_pass "🔴 HEALTH PARSER LIES AFFIRMATIVE: paired=false with a later true field read as '$r'. This is the exact #208 shape and the worst failure this probe has."

    r="$(classify_health_body '{"paired":false,"token_paired":false,"healthy":true}')"
    [ "$r" = "false" ] || probe_pass "🔴 HEALTH PARSER LIES AFFIRMATIVE: paired=false with a trailing healthy:true read as '$r'."

    r="$(classify_health_body '{"paired":true,"require_pairing":true}')"
    [ "$r" = "true" ] || probe_pass "HEALTH PARSER: a genuinely paired body read as '$r', expected true."

    r="$(classify_health_body '{"status":"healthy","service":"ostler-doctor"}')"
    case "$r" in UNAVAILABLE*) : ;; *) probe_pass "HEALTH PARSER: the Doctor liveness body (no paired field) read as '$r'. A body without the field is UNAVAILABLE, never a state." ;; esac

    r="$(classify_health_body '')"
    case "$r" in UNAVAILABLE*) : ;; *) probe_pass "HEALTH PARSER: an empty body read as '$r'." ;; esac

    # ── C. DEVICES READER. A reason must never become a state. ──────────────

    r="$(classify_devices_output '' 'Error: in prepare, no such table: devices')"
    case "$r" in UNAVAILABLE:no-schema) : ;; *) probe_pass "DEVICES READER: 'no such table' classified as '$r'. A 0-byte db with no schema is NOT 'no phone paired'." ;; esac

    r="$(classify_devices_output '' 'Error: unable to open database file')"
    case "$r" in UNAVAILABLE*) : ;; *) probe_pass "DEVICES READER: an unopenable db classified as '$r'." ;; esac

    r="$(classify_devices_output '' 'sqlite3: command not found')"
    case "$r" in UNAVAILABLE*) : ;; *) probe_pass "DEVICES READER: missing sqlite3 classified as '$r'." ;; esac

    r="$(classify_devices_output '0' '')"
    [ "$r" = "false" ] || probe_pass "DEVICES READER: a real zero-row count classified as '$r', expected false. An empty TABLE is a legitimate unpaired box."

    r="$(classify_devices_output '3' '')"
    [ "$r" = "true" ] || probe_pass "DEVICES READER: 3 rows classified as '$r', expected true."

    # ── D. MARKER READER, against a REAL filesystem. Defect 4 lived here. ───

    tmp="$(mktemp -d "${TMPDIR:-/tmp}/f2b.XXXXXX")" || tmp=""
    if [ -z "$tmp" ]; then
        probe_pass "MARKER READER: CANNOT-RUN -- mktemp -d failed, so the filesystem cases did not execute. That is not a pass."
    else
        r="$(classify_marker_dir "$tmp/never-existed")"
        case "$r" in UNAVAILABLE:no-marker-dir) : ;; *) probe_pass "🔴 MARKER READER FABRICATES: a directory that has never existed classified as '$r'. It must be UNAVAILABLE -- reporting 'false' invents a confident 'not paired' from a surface that is not there, and inflates the readable count." ;; esac

        r="$(classify_marker_dir "$tmp")"
        [ "$r" = "false" ] || probe_pass "MARKER READER: an EXISTING but empty marker dir classified as '$r', expected false. An empty dir on a real box is a genuine 'not paired'."

        : > "$tmp/device-a.json"
        r="$(classify_marker_dir "$tmp")"
        [ "$r" = "true" ] || probe_pass "MARKER READER: a dir with 1 marker classified as '$r', expected true."

        rm -rf "$tmp"
    fi

    # ── E. THE PREFIX GUARD. A reason must not be counted as a signal. ──────

    r="$(adjudicate UNAVAILABLE:no-schema UNAVAILABLE:no-marker-dir UNAVAILABLE:no-paired-field)"
    if [ "${r%% *}" != "INSUFFICIENT" ]; then
        probe_pass "ADJUDICATOR: three reasons adjudicated as '${r%% *}'. UNAVAILABLE:<reason> must match the UNAVAILABLE prefix, or a reason string is counted as a readable state."
    fi

    probe_fail "negative control behaved correctly on all 16 combinations (affirmative-lie parser caught, reasons kept distinct from states, marker fabrication caught on a real filesystem, adjudicator unchanged)"
}

probe_main "$@"
