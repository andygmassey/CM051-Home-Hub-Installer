#!/usr/bin/env bash
# tests/test_a8_excuses_only_a_planned_restart.sh
#
# CM051 row 2220. The v1.0.102 walk FAILED acceptance check A8 on a healthy
# box: the assistant was running and answering, and `launchctl list` showed
# its last exit as -15 because install.sh restarts it on purpose with
# `launchctl kickstart -k` at the end of the install. A planned restart read
# as a crash.
#
# This runs the REAL A8 block of the acceptance gate, with the remote side
# executed locally against a stub `launchctl` and a fake HOME. Four arms:
#   planned   -15, running, marker for that label   -> PASS (red on the old gate)
#   nomarker  -15, running, no marker               -> FAIL
#   stopped   -15, NOT running, marker              -> FAIL
#   crash     exit 1, running, marker               -> FAIL
# and it checks that _ks_bounded -k in install.sh writes the marker the gate
# reads, so the two halves cannot drift apart.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/box_walk_probes/acceptance_gate_v1013.sh"
LABEL="com.creativemachines.ostler.assistant"
fails=0
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# The A8 block is lifted out of the gate by its own markers and run with
# `box` and `result` stubbed, so the code tested is the code a walk runs, on
# old and new gates alike. (Running the whole gate against a stub host takes
# minutes of timeouts; this takes a second.)
A8_BLOCK="$W/a8.sh"
awk '/^# -- A8 --/{f=1} f&&/^echo "=====/{exit} f{print}' "$GATE" > "$A8_BLOCK"
[ -s "$A8_BLOCK" ] || { echo "FAIL: could not lift the A8 block out of $GATE"; exit 1; }

run_arm() {  # run_arm <name> <pid> <exit> <with_marker 0|1> <expect PASS|FAIL>
    local name="$1" pid="$2" code="$3" mark="$4" want="$5"
    local d="$W/$name"; mkdir -p "$d/bin" "$d/hm/.ostler/state"
    [ "$mark" = 1 ] && printf '%s\t%s\n' "$LABEL" 1790000000 > "$d/hm/.ostler/state/planned_restarts.tsv"
    cat > "$d/bin/launchctl" <<L
#!/bin/sh
[ "\$1" = list ] || exit 0
printf 'PID\tStatus\tLabel\n'
printf '%s\t%s\t%s\n' "$pid" "$code" "$LABEL"
printf '4242\t0\tcom.ostler.doctor\n'
L
    chmod +x "$d/bin/launchctl"
    local line
    line=$(D="$d" bash -c '
        set -uo pipefail
        box(){ HOME="$D/hm" PATH="$D/bin:/usr/bin:/bin" /bin/bash -c "$1"; }
        result(){ printf "%s %s %s -- %s\n" "$1" "$2" "$3" "${4:-}"; }
        . "'"$A8_BLOCK"'"
    ' 2>&1 | grep -E '^(PASS|FAIL|CANNOT) A8' | head -1 || true)
    if [ "$(printf '%s' "$line" | grep -c "^$want A8")" -gt 0 ]; then
        printf 'ok    %-9s -> %s\n' "$name" "$want"
    else
        printf 'FAIL  %-9s wanted %s, got: %s\n' "$name" "$want" "${line:-<no A8 line>}"
        fails=$((fails + 1))
    fi
}

run_arm planned  63654 -15 1 PASS
run_arm nomarker 63654 -15 0 FAIL
run_arm stopped  -     -15 1 FAIL
run_arm crash    63654 1   1 FAIL

# The writer half: _ks_bounded -k must append the label the gate looks for.
d="$W/writer"; mkdir -p "$d/bin" "$d/hm"
printf '#!/bin/sh\nexit 0\n' > "$d/bin/launchctl"; chmod +x "$d/bin/launchctl"
awk '/^_ks_bounded\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$ROOT/install.sh" > "$d/fn.sh"
HOME="$d/hm" PATH="$d/bin:/usr/bin:/bin" bash -c ". '$d/fn.sh'; _ks_bounded 'gui/501/$LABEL' -k; _ks_bounded 'gui/501/com.ostler.doctor'"
if [ "$(cut -f1 "$d/hm/.ostler/state/planned_restarts.tsv" 2>/dev/null | grep -c -x -F "$LABEL")" -eq 1 ] \
   && [ "$(grep -c 'com.ostler.doctor' "$d/hm/.ostler/state/planned_restarts.tsv" 2>/dev/null || true)" -eq 0 ]; then
    printf 'ok    writer    -> _ks_bounded -k marks the label; a plain kickstart does not\n'
else
    printf 'FAIL  writer    -> marker file wrong or missing\n'; fails=$((fails + 1))
fi

[ "$fails" -eq 0 ] && { echo "PASS: A8 excuses only a recorded, running, SIGTERM restart"; exit 0; }
echo "FAIL: $fails arm(s)"; exit 1
