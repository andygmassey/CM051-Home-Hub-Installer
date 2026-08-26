#!/bin/bash
# kickstart_k_probe.sh -- DOES `launchctl kickstart -k` BLOCK ON A PENALTY-BOXED JOB?
#
# I asserted in CM051 #1091 that the other nine `launchctl kickstart` call sites in
# install.sh are safe because they pass -k. THAT WAS AN ASSERTION, NOT A MEASUREMENT.
# If -k also blocks, there are nine more 24-hour deadlocks in the shipping installer
# and the fix is incomplete.
#
# DESIGN
#   SUBJECT  a synthetic LaunchAgent whose program does not exist -> launchd
#            penalty-boxes it (last exit code = 78: EX_CONFIG)
#   CONTROL  a synthetic LaunchAgent whose program DOES exist and exits 0
#
# The control is what makes this readable. Without it, "kickstart took 20s" could be
# my timing harness, ssh latency, or a slow launchd -- not the penalty box. The
# control must return FAST for the subject's slowness to mean anything.
#
# Everything is synthetic and namespaced. Nothing touches a real Ostler agent.
# Cleanup runs on EXIT, including on interrupt.
#
# `timeout` does not exist on macOS, so the bound is an explicit sleep+kill.
# A killed child comes back 143 -- that is the "it blocked" signal, distinct from
# any exit code launchctl itself could return.

set -u

SUB=com.ostler.archie-probe-penaltybox
CTL=com.ostler.archie-probe-healthy
LA="$HOME/Library/LaunchAgents"
UID_N=$(id -u)
DOM="gui/${UID_N}"
BOUND="${BOUND:-90}"  # seconds. FIRST RUN USED 25 AND THAT WAS TOO TIGHT: the
                      # healthy CONTROL under -k took 20s, leaving only a 5s gap to
                      # the subject's 25s kill. A 5s gap is not a discrimination.
                      # -k means kill-then-restart, so it legitimately waits for the
                      # job to die; the bound has to clear that comfortably.
WORK=$(mktemp -d)

cleanup() {
    for l in "$SUB" "$CTL"; do
        launchctl bootout "${DOM}/${l}" >/dev/null 2>&1
        rm -f "${LA}/${l}.plist"
    done
    rm -rf "$WORK"
    echo
    echo "CLEANUP: both synthetic agents booted out and their plists removed."
    for l in "$SUB" "$CTL"; do
        if launchctl print "${DOM}/${l}" >/dev/null 2>&1; then
            echo "  !! ${l} IS STILL LOADED -- remove it by hand."
        elif [ -f "${LA}/${l}.plist" ]; then
            echo "  !! ${l}.plist STILL ON DISK -- remove it by hand."
        else
            echo "  verified gone: ${l}"
        fi
    done
}
trap cleanup EXIT INT TERM

mkplist() {  # $1=label $2=program
    cat > "${LA}/$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>$1</string>
  <key>ProgramArguments</key><array><string>$2</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
}

# Bounded run. Echoes "<rc> <elapsed_seconds>".
bounded() {  # $1..=cmd
    local t0 t1 pid wd rc
    t0=$(date +%s)
    "$@" >"${WORK}/out" 2>&1 &
    pid=$!
    ( sleep "$BOUND"; kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    wd=$!
    wait "$pid" 2>/dev/null; rc=$?
    kill -TERM "$wd" 2>/dev/null
    t1=$(date +%s)
    echo "$rc $((t1 - t0))"
}

verdict() {  # $1=rc $2=elapsed $3=what
    if [ "$1" -ge 143 ] || [ "$2" -ge "$BOUND" ]; then
        printf '  %-42s BLOCKED  (killed at %ss, rc=%s)\n' "$3" "$2" "$1"
        return 1
    fi
    printf '  %-42s returned (%ss, rc=%s)\n' "$3" "$2" "$1"
    return 0
}

mkdir -p "$LA"
printf '#!/bin/sh\nexit 0\n' > "${WORK}/healthy"; chmod +x "${WORK}/healthy"

echo "host: $(hostname -s)  macOS $(sw_vers -productVersion)  $(uname -m)  uid=${UID_N}"
echo "bound: ${BOUND}s"
echo

mkplist "$SUB" "${WORK}/does-not-exist-on-purpose"
mkplist "$CTL" "${WORK}/healthy"
for l in "$SUB" "$CTL"; do
    launchctl bootstrap "$DOM" "${LA}/${l}.plist" >/dev/null 2>&1
done
sleep 3   # let launchd try, fail, and penalty-box the subject

echo "--- STATE (this is the premise; if the subject is not penalty-boxed, STOP) ---"
for l in "$SUB" "$CTL"; do
    printf '%s\n' "$l"
    launchctl print "${DOM}/${l}" 2>/dev/null \
        | /usr/bin/grep -E '^[[:space:]]*(state|last exit code|properties) ' \
        | sed 's/^/    /'
done
echo

if ! launchctl print "${DOM}/${SUB}" 2>/dev/null | /usr/bin/grep -q 'penalty box'; then
    echo "CANNOT-RUN: the subject is NOT in the penalty box, so this measures nothing."
    echo "  Not a pass, and not evidence that -k is safe."
    exit 2
fi

echo "--- MEASUREMENT ---"
FAILED=0

set -- $(bounded launchctl kickstart "${DOM}/${CTL}")
verdict "$1" "$2" "CONTROL   kickstart    healthy agent" || FAILED=1
set -- $(bounded launchctl kickstart -k "${DOM}/${CTL}")
verdict "$1" "$2" "CONTROL   kickstart -k healthy agent" || FAILED=1

if [ "$FAILED" -ne 0 ]; then
    echo
    echo "CANNOT-RUN: a CONTROL blocked. The harness or launchd itself is the problem,"
    echo "  so nothing below is attributable to the penalty box. Not a pass."
    exit 2
fi
echo

set -- $(bounded launchctl kickstart "${DOM}/${SUB}")
verdict "$1" "$2" "SUBJECT   kickstart    penalty-boxed"; PLAIN=$?
set -- $(bounded launchctl kickstart -k "${DOM}/${SUB}")
verdict "$1" "$2" "SUBJECT   kickstart -k penalty-boxed"; DASHK=$?

echo
echo "--- VERDICT ---"
echo "  Control timings are printed above. Read them: a block below is only attributable
  to the penalty box if the controls cleared the bound COMFORTABLY, not narrowly."
if [ "$DASHK" -ne 0 ]; then
    echo "  🔴 -k BLOCKS TOO. My claim in CM051 #1091 was WRONG. The other nine"
    echo "     kickstart call sites in install.sh are NOT safe, and each is a"
    echo "     potential 24-hour deadlock of whatever calls it."
elif [ "$PLAIN" -ne 0 ]; then
    echo "  ✅ -k RETURNS while plain kickstart BLOCKS. My claim holds, and now on"
    echo "     evidence: -k is the discriminator, not luck."
else
    echo "  ⚠️  NEITHER blocked on this box right now. That does NOT prove -k is safe --"
    echo "     it means this box did not reproduce the wedge today. The 23h56m hang was"
    echo "     measured on THIS host, so the trigger is state-dependent and still unknown."
fi
