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
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="pair_state_agreement"
PROBE_QUESTION="do the daemon health flag, devices.db, and pair-state file all agree on whether a phone is paired?"

DEVICES_DB="${OSTLER_DEVICES_DB:-\$HOME/.ostler/devices.db}"
# Evaluated ON THE BOX -- a local `~` would expand to the operator's home and
# is correct only while both machines happen to share a username.
CONFIG_TOML="${OSTLER_CONFIG_TOML:-\$HOME/.ostler/assistant-config/config.toml}"
HEALTH_URL="${OSTLER_HEALTH_URL:-http://127.0.0.1:8089/doctor/api/health}"

# --- signal readers. Each prints  true | false | UNAVAILABLE ---------------

signal_health_flag() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then
        printf '%s' "${FAKE_HEALTH:-UNAVAILABLE}"; return
    fi
    local body
    body="$(box_run "curl -sS -m 5 '$HEALTH_URL' 2>/dev/null")"
    if [ -z "$body" ]; then printf 'UNAVAILABLE'; return; fi
    case "$body" in
        *'"paired"'*'true'*) printf 'true' ;;
        *'"paired"'*'false'*) printf 'false' ;;
        *) printf 'UNAVAILABLE' ;;
    esac
}

DEVICES_DB_USED=""   # set by signal_devices_rows so run_probe can report WHICH file

signal_devices_rows() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then
        printf '%s' "${FAKE_DEVICES:-UNAVAILABLE}"; return
    fi
    # 🔴 THIS READ THE WRONG FILE (fixed 2026-08-27). It was hardcoded to
    # $HOME/.ostler/devices.db. MEASURED on the live box, there are TWO:
    #
    #   ~/.ostler/devices.db                              0 bytes, mtime 08-21,
    #                                                     NO SCHEMA AT ALL
    #   ~/.ostler/assistant-config/workspace/devices.db  12288 bytes, mtime 08-24,
    #                                                     table `devices`, 0 rows
    #
    # The daemon writes the SECOND one: api_pairing::DeviceRegistry::new()
    # opens workspace_dir.join("devices.db"), and workspace_dir derives from
    # ZEROCLAW_WORKSPACE (=~/.ostler/assistant-config) plus its own
    # `workspace` subdir. The first is a stale artefact.
    #
    # Reading the stale one made this signal permanently UNAVAILABLE, which
    # is WHY this probe could pass on 2 of 5 signals and why the registry
    # looked like "dead code" -- it is not dead, it was never being read.
    # Same class as task #325: OSTLER_HOME carries two meanings.
    #
    # So: DISCOVER the registry, prefer the one that actually has the schema,
    # and keep "no file" / "file but no schema" / "schema, N rows" as three
    # DISTINCT outcomes. A table-less database must never count as 0 devices.
    local out rest
    out="$(box_run '
      best=""; n_found=0
      for f in $(find "$HOME/.ostler" -maxdepth 4 -name devices.db 2>/dev/null); do
        n_found=$((n_found+1))
        if sqlite3 "$f" ".tables" 2>/dev/null | tr " " "\n" | grep -qx devices; then best="$f"; fi
      done
      if [ "$n_found" -eq 0 ]; then printf "NOFILE"; exit 0; fi
      if [ -z "$best" ]; then printf "NOSCHEMA %s" "$n_found"; exit 0; fi
      c=$(sqlite3 "$best" "select count(*) from devices;" 2>/dev/null)
      printf "OK %s %s" "$c" "$best"
    ')"
    case "$out" in
        NOFILE)    DEVICES_DB_USED="(no devices.db anywhere under ~/.ostler)"
                   printf 'UNAVAILABLE' ;;
        NOSCHEMA*) rest="${out#NOSCHEMA }"
                   DEVICES_DB_USED="${rest} file(s) present, NONE carrying a devices table"
                   printf 'UNAVAILABLE' ;;
        OK*)       rest="${out#OK }"
                   DEVICES_DB_USED="${rest#* }"
                   case "${rest%% *}" in
                       ''|*[!0-9]*) printf 'UNAVAILABLE' ;;
                       0)           printf 'false' ;;
                       *)           printf 'true' ;;
                   esac ;;
        *)         DEVICES_DB_USED="unparseable discovery output"
                   printf 'UNAVAILABLE' ;;
    esac
}

signal_pair_marker() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then
        printf '%s' "${FAKE_MARKER:-UNAVAILABLE}"; return
    fi
    local out
    # 🔴 MEASURED 2026-08-26 on the live box: ~/.ostler/paired_devices DOES NOT
    # EXIST. The old body was `ls .../*.json 2>/dev/null | wc -l`, and a failed
    # `ls` still feeds `wc` an empty stream -- so an ABSENT DIRECTORY counted 0
    # and this signal returned a confident `false`, meaning "no device is
    # paired". That is a different fact from "I could not look", and it was the
    # ONE answer that could not be right: the same box carries 35 issued bearer
    # tokens in config.toml. Because the other two signals were UNAVAILABLE,
    # this fail-open `false` was the sole readable signal, and a single signal
    # cannot contradict itself -- so the probe could only ever say INSUFFICIENT
    # while sitting on top of a real split-brain.
    #
    # Ask whether the directory exists BEFORE counting inside it.
    out="$(box_run "if [ -d \"\$HOME/.ostler/paired_devices\" ]; then ls \$HOME/.ostler/paired_devices/*.json 2>/dev/null | wc -l | tr -d ' '; else printf ABSENT; fi")"
    case "$out" in
        ABSENT) printf 'UNAVAILABLE' ;;
        ''|*[!0-9]*) printf 'UNAVAILABLE' ;;
        0) printf 'false' ;;
        *) printf 'true' ;;
    esac
}

# ── THE TWO SIGNALS THAT ARE ACTUALLY READABLE (added 2026-08-26) ──────────
#
# The three readers above all interrogate the dead device registry (#511), so
# on a real box they are all UNAVAILABLE and this probe reported CANNOT-RUN
# forever. These two read surfaces that DEMONSTRABLY EXIST, and on the live box
# they CONTRADICT EACH OTHER -- which is the whole point of this probe.
#
# MEASURED 2026-08-26:
#   config.toml:112            require_pairing  = true
#   GET :8000/admin/paircode   pairing_required = False
# The Doctor faithfully turns that into error_kind="pairing_disabled", so the
# pair-iOS panel cannot mint a recovery QR and a customer whose session dies
# has no way back in. That is task #512, and it is exactly a pairing-state
# disagreement -- the class this probe was built to catch.

signal_config_require_pairing() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then
        printf '%s' "${FAKE_CFG:-UNAVAILABLE}"; return
    fi
    local out
    # `grep -c .` on the extracted value, not `grep -c` on the file: an absent
    # key and a key set to false must not read alike.
    out="$(box_run "/usr/bin/grep -E '^[[:space:]]*require_pairing[[:space:]]*=' \"$CONFIG_TOML\" 2>/dev/null | head -1")"
    case "$out" in
        *true*)  printf 'true' ;;
        *false*) printf 'false' ;;
        *)       printf 'UNAVAILABLE' ;;
    esac
}

signal_gateway_pairing_required() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then
        printf '%s' "${FAKE_GW:-UNAVAILABLE}"; return
    fi
    local out
    # The admin token is read and used ENTIRELY on the box. It is never
    # interpolated into anything this side of the ssh boundary and is never
    # printed -- probe output lands in a durable log.
    #
    # NOTE: do NOT probe :8000 with a plain path and trust the status code.
    # The daemon serves the SPA as a catch-all: every path, including invented
    # ones, returns 200 text/html. Measured. /admin/paircode with the bearer is
    # the only honest read.
    out="$(box_run 'T=$(cat "$HOME/.ostler/secrets/zeroclaw_admin_token" 2>/dev/null); [ -n "$T" ] || exit 0; curl -s --noproxy "*" --max-time 8 -H "Authorization: Bearer $T" http://127.0.0.1:8000/admin/paircode 2>/dev/null' )"
    [ -n "${out:-}" ] || { printf 'UNAVAILABLE'; return; }
    printf '%s' "$out" | python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw: print("UNAVAILABLE"); sys.exit(0)
try:
    d=json.loads(raw)
except Exception:
    print("UNAVAILABLE"); sys.exit(0)
v = d.get("pairing_required") if isinstance(d, dict) else None
# Absent key is UNAVAILABLE, not False. A missing field and a field set to
# false are different facts. Conflating them is the exact defect class that
# left this probe fail-open for who knows how many walks.
print("UNAVAILABLE" if v is None else ("true" if bool(v) else "false"))
' 2>/dev/null || printf 'UNAVAILABLE'
}

# --- the comparison, shared by run_probe and self_test ---------------------

adjudicate() {
    # adjudicate <signal> [<signal> ...]
    # Prints a verdict token on stdout: AGREE | DISAGREE | INSUFFICIENT
    # followed by a space and a human-readable detail string.
    #
    # VARIADIC as of 2026-08-26. It used to take exactly three positional
    # signals, all of which read the DEVICE REGISTRY -- a subsystem measured
    # dead on the live box (#511): devices.db is 0 bytes with no schema,
    # /doctor/api/health carries no `paired` key, and ~/.ostler/paired_devices
    # is a path the daemon never writes (0 hits in its binary). All three were
    # therefore permanently UNAVAILABLE, so this probe could only ever return
    # INSUFFICIENT -- a CANNOT-RUN that blocks the cut with no path to green.
    # Widening it to accept N signals lets it also read the surfaces that DO
    # exist, without deleting the three that SHOULD exist once #511 is fixed.
    local seen="" n=0 total=$#

    for v in "$@"; do
        if [ "$v" != "UNAVAILABLE" ]; then
            seen="$seen $v"
            n=$((n + 1))
        fi
    done

    # ONE signal is not agreement. Two signals agreeing is the minimum that
    # means anything, because a single reading cannot contradict itself and
    # would therefore pass forever.
    if [ "$n" -lt 2 ]; then
        printf 'INSUFFICIENT only %s of %s pairing signals were readable' "$n" "$total"
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

    local h d m c g
    # Signals 1-3 read the device registry. MEASURED DEAD on the live box
    # (#511) -- kept because they are the RIGHT signals once it is wired, and
    # deleting them would hide the regression when it is.
    h="$(signal_health_flag)"
    d="$(signal_devices_rows)"
    m="$(signal_pair_marker)"
    # Signals 4-5 read surfaces that exist today, and currently CONTRADICT
    # each other (#512).
    c="$(signal_config_require_pairing)"
    g="$(signal_gateway_pairing_required)"

    probe_note "daemon health paired flag    : $h"
    probe_note "devices.db row count         : $d"
    probe_note "paired_devices/*.json        : $m"
    probe_note "config.toml require_pairing  : $c"
    probe_note "gateway pairing_required     : $g"

    local readable=0
    for v in "$h" "$d" "$m" "$c" "$g"; do
        [ "$v" != "UNAVAILABLE" ] && readable=$((readable + 1))
    done
    probe_examined "$readable" "of 5 pairing signals readable"

    # 🔴 THESE FIVE SIGNALS DO NOT ANSWER THE SAME QUESTION (fixed 2026-08-27).
    #
    # They used to be adjudicated in ONE bucket. They must not be. The daemon
    # source says so explicitly, at api_auth_pair.rs:824-830:
    #
    #   "token_paired (bearer-layer truth) and companion_paired (device-layer
    #    truth) legitimately answer different questions; the fix is not to
    #    conflate them"
    #
    # and the conflation here was worse than that, because signals 4-5 are not
    # even a different LAYER of the same question -- they are a different
    # question entirely:
    #
    #   signals 1-3  "is a device PAIRED?"    <- device-layer state
    #   signals 4-5  "is pairing REQUIRED?"   <- policy
    #
    # A brand-new install has pairing REQUIRED and ZERO devices paired. That is
    # the healthy first-boot state of every customer machine. Adjudicated in one
    # bucket it reads as 2-say-true / 1-says-false and FAILS. I shipped exactly
    # that false FAIL for one commit (b5207302) after fixing the path bug, and a
    # false red blocks a walk just as hard as a real one.
    #
    # Two questions, two adjudications, both still enforced.
    local res_dev res_pol tok_dev tok_pol det_dev det_pol
    res_dev="$(adjudicate "$h" "$d" "$m")"      # device-layer agreement
    res_pol="$(adjudicate "$c" "$g")"           # policy agreement (#512 lives here)
    tok_dev="${res_dev%% *}"; det_dev="${res_dev#* }"
    tok_pol="${res_pol%% *}"; det_pol="${res_pol#* }"

    # COMBINING RULE. Both questions must be ANSWERED for this probe to pass.
    #
    # 🔴 My first version of this combiner required BOTH groups to be
    # INSUFFICIENT before refusing, so one answerable group carried an
    # unanswerable one into a PASS. Measured on the live box: device-layer was
    # 1-of-3 readable (INSUFFICIENT), policy was 2-of-2 AGREE, and the probe
    # printed "VERDICT: PASS". That is a probe reporting a question it could
    # not answer as answered -- the same fail-open this whole suite exists to
    # prevent, introduced by me while fixing the previous one.
    #
    # Precedence, strictest first:
    #   any DISAGREE      -> FAIL         (a contradiction is a defect)
    #   any INSUFFICIENT  -> CANNOT-RUN   (coverage lost, NOT a pass)
    #   otherwise         -> PASS
    # DISAGREE outranks INSUFFICIENT: a proven contradiction is a finding even
    # if the other question is unreadable.
    local result token detail
    if [ "$tok_dev" = "DISAGREE" ]; then
        result="DISAGREE device-layer signals contradict each other: ${det_dev}"
    elif [ "$tok_pol" = "DISAGREE" ]; then
        result="DISAGREE pairing POLICY disagrees with config: ${det_pol}"
    elif [ "$tok_dev" = "INSUFFICIENT" ] && [ "$tok_pol" = "INSUFFICIENT" ]; then
        result="INSUFFICIENT neither question is answerable -- device-layer: ${det_dev}; policy: ${det_pol}"
    elif [ "$tok_dev" = "INSUFFICIENT" ]; then
        result="INSUFFICIENT the DEVICE-LAYER question is unanswerable (${det_dev}); policy answered cleanly (${det_pol}), but one answered question does not cover an unanswered one"
    elif [ "$tok_pol" = "INSUFFICIENT" ]; then
        result="INSUFFICIENT the POLICY question is unanswerable (${det_pol}); device-layer answered cleanly (${det_dev}), but one answered question does not cover an unanswered one"
    else
        result="AGREE device-layer: ${det_dev}; policy: ${det_pol}"
    fi
    token="${result%% *}"
    detail="${result#* }"

    case "$token" in
        DISAGREE)
            probe_fail "pairing state is split-brain: $detail (tasks #265, #208). A false 'paired' is worse than an honest 'not paired'."
            ;;
        INSUFFICIENT)
            # DO NOT reinstate "Is the daemon running?" here. That hint was
            # WRONG and cost real time: on 2026-08-26 the daemon was measured
            # running (pids listening on :8000 AND :8443, /doctor/api/health
            # 200) while this probe still could not read a single signal. The
            # cause was that every signal it had pointed at a subsystem that
            # was never wired (#511). A hint that names the wrong suspect is
            # worse than no hint -- it sends the next reader down a dead path.
            probe_cannot_run "$detail -- one signal cannot contradict itself, so this would pass forever. Check WHICH signals came back UNAVAILABLE in the notes above before assuming the daemon is down; see #511 (dead device registry) and #512 (config vs gateway)."
            ;;
        *)
            probe_pass "$detail"
            ;;
    esac
}

self_test() {
    SELF_TEST_LOCAL=1
    probe_examined 6 "synthetic signal combinations (negative control)"

    # 1. The #208 shape: health says paired, devices.db is empty. MUST disagree.
    local r
    r="$(adjudicate true false UNAVAILABLE)"
    if [ "${r%% *}" != "DISAGREE" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: health=true vs devices=false adjudicated as '${r%% *}', not DISAGREE. This probe cannot detect task #208."
    fi

    # 2. Honest unpaired box. MUST agree.
    r="$(adjudicate false false false)"
    if [ "${r%% *}" != "AGREE" ]; then
        probe_pass "NEGATIVE CONTROL OVER-FIRED: a consistently unpaired box adjudicated as '${r%% *}'. It would fail every fresh install."
    fi

    # 3. Honest paired box. MUST agree.
    r="$(adjudicate true true true)"
    if [ "${r%% *}" != "AGREE" ]; then
        probe_pass "NEGATIVE CONTROL OVER-FIRED: a consistently paired box adjudicated as '${r%% *}'."
    fi

    # 4. Only one signal readable. MUST refuse rather than pass, because a
    #    lone signal agrees with itself by construction.
    r="$(adjudicate true UNAVAILABLE UNAVAILABLE)"
    if [ "${r%% *}" != "INSUFFICIENT" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: a single readable signal adjudicated as '${r%% *}'. One signal cannot contradict itself, so this probe would report agreement forever."
    fi

    # 5. THE LIVE BOX SHAPE, 2026-08-26. The three device-registry signals are
    #    all dead (#511) and the two readable ones contradict each other
    #    (#512: config says require_pairing=true, gateway says
    #    pairing_required=False). This MUST adjudicate DISAGREE. If it comes
    #    back INSUFFICIENT the widening did not take, and the probe is back to
    #    a permanent CANNOT-RUN that blocks the cut with no path to green.
    r="$(adjudicate UNAVAILABLE UNAVAILABLE UNAVAILABLE true false)"
    if [ "${r%% *}" != "DISAGREE" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: the live-box shape (3 registry signals dead, config=true vs gateway=false) adjudicated as '${r%% *}', not DISAGREE. This probe cannot detect #512, and reverts to a permanent CANNOT-RUN."
    fi

    # 6. Two readable signals that AGREE must still pass, or every correctly
    #    configured box goes red on this row.
    r="$(adjudicate UNAVAILABLE UNAVAILABLE UNAVAILABLE true true)"
    if [ "${r%% *}" != "AGREE" ]; then
        probe_pass "NEGATIVE CONTROL OVER-FIRED: config and gateway both saying true adjudicated as '${r%% *}'. A correctly configured box would fail this row."
    fi

    probe_fail "negative control behaved correctly on all 6 combinations (split-brain caught, consistent states passed, single-signal refused, live #512 shape caught, healthy 2-signal box cleared)"
}

probe_main "$@"
