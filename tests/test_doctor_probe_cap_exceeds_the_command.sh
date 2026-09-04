#!/usr/bin/env bash
# The doctor probe's cap must sit ABOVE the command it wraps.
#
# WHY THIS EXISTS. MEASURED on the walk box, 2026-09-04, against a daemon that
# was up and answering, three consecutive runs:
#
#     run 1  rc=0  15.7s      min 15.6s
#     run 2  rc=0  15.7s      max 15.7s      the installer's cap was 10s
#     run 3  rc=0  15.6s      spread 0.1s
#
# Every run exits 0 and every run exceeds the cap. The spread is a tenth of a
# second, so 15.7s is the command's NORMAL duration, not a slow sample.
#
# CONSEQUENCE, on every install, for a daemon that is working perfectly:
# health_check closes `status=timeout rc=124`, and the installer's own closing
# line reads "Ostler finished, but 1 install step(s) did not complete cleanly:
# health_check". That was walk 15's only remaining failure.
#
# A CAP BELOW THE NORMAL DURATION OF THE THING IT WRAPS IS NOT A TIMEOUT, IT IS
# A GUARANTEED FAILURE WEARING A TIMEOUT'S NAME. The cap itself is right and
# stays: it exists so a wedged daemon cannot hang the install.
#
# THE TEST DRIVES THE REAL BLOCK rather than asserting the number, because the
# property is "does the cap actually govern the call", which a constant cannot
# show. The default value is checked separately, against a floor derived from
# the measurement above.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# The block can only be exercised where a timeout wrapper exists. Stock macOS
# ships neither, and the block's own comment says so. Refuse rather than
# report a pass we did not earn.
_WRAP=""
command -v gtimeout >/dev/null 2>&1 && _WRAP=gtimeout
[ -z "$_WRAP" ] && { command -v timeout >/dev/null 2>&1 && _WRAP=timeout; }
_SYNTHETIC_WRAPPER=no
if [ -z "$_WRAP" ]; then
    # Stock macOS ships NEITHER, which is what the block's own comment says and
    # is why the old bare `timeout 10` never ran doctor there at all. Rather
    # than go inert on the platform the product ships to, synthesise a real
    # one: it genuinely enforces a cap and genuinely returns 124, so the
    # property under test -- does the cap govern the call -- is still measured.
    #
    # DISCLOSED, because a substituted instrument that says nothing is how a
    # harness ends up testing itself. What is NOT covered here is the SELECTION
    # of the real gtimeout/timeout binary; only its behaviour is.
    mkdir -p "${WORK}/bin"
    cat > "${WORK}/bin/timeout" <<'TMO'
#!/bin/bash
# Minimal timeout(1): `timeout <seconds> <cmd> [args...]`, 124 on cap.
_cap="$1"; shift
"$@" &
_child=$!
( sleep "$_cap"; kill -TERM "$_child" 2>/dev/null ) &
_killer=$!
wait "$_child" 2>/dev/null; _rc=$?
kill -TERM "$_killer" 2>/dev/null
wait "$_killer" 2>/dev/null
[ "$_rc" -ge 128 ] && exit 124
exit "$_rc"
TMO
    chmod +x "${WORK}/bin/timeout"
    PATH="${WORK}/bin:$PATH"
    export PATH
    _WRAP=timeout
    _SYNTHETIC_WRAPPER=yes
    echo "  NOTE: no gtimeout/timeout on PATH, so a synthetic timeout is in use."
    echo "        The cap's BEHAVIOUR is measured; the selection of the real"
    echo "        binary is not covered by this run."
fi

# Read the DEFAULT out of the tree rather than restating it.
_read_default() {
    /usr/bin/grep -oE 'OSTLER_DOCTOR_PROBE_TIMEOUT_S="\$\{OSTLER_DOCTOR_PROBE_TIMEOUT_S:-[0-9]+\}"' "$1" \
        | head -1 | sed -E 's/.*:-([0-9]+)\}.*/\1/'
}

echo "── the default must clear the measured duration with headroom ──"

# 15.7s measured. A floor of 30 is a little under 2x, which is the smallest
# number that is defensibly headroom rather than coincidence, and it leaves
# room for a slower Mac than the M4 mini this was measured on.
_MEASURED_S=16
_FLOOR_S=30
_def="$(_read_default "$SUBJECT")"
if [ -z "$_def" ]; then
    bad "no OSTLER_DOCTOR_PROBE_TIMEOUT_S default found; the cap is a bare literal again and cannot be tuned or tested"
elif [ "$_def" -le "$_MEASURED_S" ]; then
    bad "the cap is ${_def}s and the command measures ${_MEASURED_S}s. Every install would report a timeout for a healthy daemon."
elif [ "$_def" -lt "$_FLOOR_S" ]; then
    bad "the cap is ${_def}s, above the measured ${_MEASURED_S}s but below the ${_FLOOR_S}s floor. That is coincidence, not headroom."
else
    ok "the cap defaults to ${_def}s, clear of the measured ${_MEASURED_S}s with headroom"
fi

echo "── and the cap must actually govern the call ──"

# Drive the real shape: a wrapper selected the way install.sh selects it, a
# command that outlives the cap, and the 124/137 fold.
_drive() {
    local cap="$1" sleep_s="$2" r="${WORK}/r"; rm -rf "$r"; mkdir -p "$r"
    cat > "${r}/fake-doctor" <<FAKE
#!/bin/bash
sleep ${sleep_s}
echo "doctor output"
FAKE
    chmod +x "${r}/fake-doctor"
    cat > "${r}/run.sh" <<'RUN'
set -uo pipefail
RECORDED=""
gui_step_record_rc() { RECORDED="$1"; }
_DOCTOR_TIMEOUT_WRAP=""
if command -v gtimeout >/dev/null 2>&1; then
    _DOCTOR_TIMEOUT_WRAP="gtimeout ${OSTLER_DOCTOR_PROBE_TIMEOUT_S}"
elif command -v timeout >/dev/null 2>&1; then
    _DOCTOR_TIMEOUT_WRAP="timeout ${OSTLER_DOCTOR_PROBE_TIMEOUT_S}"
fi
_DOCTOR_PROBE_RC=0
DOCTOR_OUTPUT=$($_DOCTOR_TIMEOUT_WRAP "${ASSISTANT_BINARY}" doctor 2>&1) || {
    _DOCTOR_PROBE_RC=$?
    DOCTOR_OUTPUT="__DOCTOR_INVOCATION_FAILED__"
}
if [[ "$_DOCTOR_PROBE_RC" -eq 124 ]] || [[ "$_DOCTOR_PROBE_RC" -eq 137 ]]; then
    gui_step_record_rc "$_DOCTOR_PROBE_RC"
fi
printf 'rc=%s recorded=%s' "$_DOCTOR_PROBE_RC" "${RECORDED:-none}"
RUN
    OSTLER_DOCTOR_PROBE_TIMEOUT_S="$cap" ASSISTANT_BINARY="${r}/fake-doctor" \
        bash "${r}/run.sh" 2>/dev/null
}

_r="$(_drive 1 4)"
case "$_r" in
    "rc=124 recorded=124") ok "a command that outlives the cap is killed and its 124 is folded into the step" ;;
    "rc=0 recorded=none")  bad "the cap did not fire on a command that outlives it. The wrapper is not governing the call." ;;
    *)                     bad "a command outliving the cap gave '${_r}', expected rc=124 recorded=124" ;;
esac

# CONTROL. Without it, a change that recorded 124 unconditionally would pass
# the limb above, and every healthy install would report a timeout again.
_r="$(_drive 10 0)"
case "$_r" in
    "rc=0 recorded=none") ok "CONTROL: a command that finishes inside the cap records nothing, so a healthy daemon does not redden the step" ;;
    *)                    bad "CONTROL: a fast command gave '${_r}', expected rc=0 recorded=none" ;;
esac

# ── NEGATIVE CONTROL, pinned to the cut whose walk measured the timeout ──
# 7b2130ac is v1.0.65. Its cap is the bare literal 10, below the command.
_CONTROL_SHA="7b2130ac"
echo "── negative control: ${_CONTROL_SHA} (the cut whose walk timed out) ──"
_ctl="${WORK}/control.sh"
if ! git -C "$REPO" cat-file -e "${_CONTROL_SHA}:install.sh" 2>/dev/null; then
    git -C "$REPO" fetch --depth=1 origin "$_CONTROL_SHA" >/dev/null 2>&1 || true
fi
if ! git -C "$REPO" cat-file -p "${_CONTROL_SHA}:install.sh" > "$_ctl" 2>/dev/null || [ ! -s "$_ctl" ]; then
    echo "CANNOT-RUN: control blob ${_CONTROL_SHA}:install.sh is unreadable." >&2
    exit 2
fi

_ctl_def="$(_read_default "$_ctl")"
_ctl_lit="$(/usr/bin/grep -oE '(gtimeout|timeout) 10"' "$_ctl" | head -1)"
if [ -n "$_ctl_def" ]; then
    bad "control ${_CONTROL_SHA} already has a tunable default (${_ctl_def}); this harness is not reading what changed"
elif [ -n "$_ctl_lit" ]; then
    ok "control ${_CONTROL_SHA}: the cap is the bare literal 10, below the ${_MEASURED_S}s the command takes"
else
    echo "CANNOT-RUN: could not find the cap in the control blob at all." >&2
    echo "  Neither a tunable default nor the literal 10 is present, so the" >&2
    echo "  comparison this control exists to make cannot be made." >&2
    exit 2
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
