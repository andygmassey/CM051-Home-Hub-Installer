#!/usr/bin/env bash
# A walk that failed must not report a pass, and must not exit 0.
#
# WHY THIS EXISTS. MEASURED on walk 11, 2026-09-04. The run reached step 38 of
# 38 with THREE failed steps and walk_drive.py adjudicated FAIL. The harness
# printed:
#
#     ---- VERDICT (walk_drive.py's own adjudication) ----
#     0
#
# and the process exited 0. Both numbers were wrong in the same direction.
#
# TWO SEPARATE FAULTS, AND EITHER ALONE IS A FALSE GREEN:
#
#   1. ttywalk.sh printed `--read-result` under the heading "VERDICT".
#      `.walk-rc` holds the RAW EXIT STATUS of install.sh. walk_drive.py's own
#      comment calls it "EVIDENCE ... not the verdict". An install that reaches
#      its end with failed steps exits 0, so the evidence said 0 while the
#      adjudication said FAIL, and the harness published the evidence.
#   2. ttywalk.sh ended on its last `ssh`, so its exit status was that
#      command's. Every walk of the night exited 0, including the ones that
#      died at step 6.
#
# A caller branching on either signal would have called walk 11 green.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DRIVER="${REPO}/scripts/walk_drive.py"
WALK="${REPO}/scripts/ttywalk.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$DRIVER" ] || { echo "CANNOT-RUN: no walk_drive.py at ${DRIVER}" >&2; exit 2; }
[ -f "$WALK" ]   || { echo "CANNOT-RUN: no ttywalk.sh at ${WALK}" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

echo "── the verdict channel must carry the ADJUDICATION, not the exit status ──"

# Drive the reader directly with a fixture HOME. Executed rather than read,
# because the property is which FILE the reader opens, and both files hold a
# bare integer that no pattern can tell apart.
# Args: <.walk-rc contents> <.walk-verdict contents|NONE> <stamp order: fresh|stale>
# Echoes "<exit>|<stdout>"
_read() {
    local rc="$1" vd="$2" order="$3" h="${WORK}/h"
    rm -rf "$h"; mkdir -p "$h"
    if [ "$order" = stale ]; then
        printf '%s\n' "$rc" > "${h}/.walk-rc"
        [ "$vd" = NONE ] || printf '%s\n' "$vd" > "${h}/.walk-verdict"
        sleep 1
        printf 'start\n' > "${h}/.walk-run-start"
    else
        printf 'start\n' > "${h}/.walk-run-start"
        sleep 1
        printf '%s\n' "$rc" > "${h}/.walk-rc"
        [ "$vd" = NONE ] || printf '%s\n' "$vd" > "${h}/.walk-verdict"
    fi
    local out rc2
    out="$(HOME="$h" python3 "$DRIVER" --read-verdict 2>/dev/null)"; rc2=$?
    printf '%s|%s' "$rc2" "$(printf '%s' "$out" | tr -d '[:space:]')"
}

# THE WALK 11 SHAPE: install.sh exited 0, adjudication was FAIL.
_r="$(_read 0 1 fresh)"
case "$_r" in
    "0|1") ok "install.sh exit 0 with an adjudicated FAIL reports 1, not 0" ;;
    "0|0") bad "it reports 0. The reader is still handing back the raw exit status, which is the measured walk-11 false green." ;;
    *)     bad "unexpected: ${_r}" ;;
esac

# CONTROL ON THE OTHER DIRECTION. Without this, a reader hard-wired to print 1
# would pass the limb above.
_r="$(_read 0 0 fresh)"
case "$_r" in
    "0|0") ok "CONTROL: a genuine pass still reports 0, so the fix did not simply hard-fail everything" ;;
    *)     bad "CONTROL: a genuine pass reports ${_r}. A green walk can no longer be reported." ;;
esac

_r="$(_read 2 2 fresh)"
case "$_r" in
    "0|2") ok "CONTROL: CANNOT-RUN survives as its own third state" ;;
    *)     bad "CONTROL: CANNOT-RUN reports ${_r}, so the third state has been collapsed" ;;
esac

echo "── absence and staleness are CANNOT-RUN, never a pass ──"

# A missing verdict must not read as zero. "No walk ran" and "the walk passed"
# print identically the moment absence is allowed to mean success.
_r="$(_read 0 NONE fresh)"
case "$_r" in
    2\|*) ok "a MISSING verdict is CANNOT-RUN, so a walk that died before adjudicating cannot read as a pass" ;;
    0\|*) bad "a missing verdict returns success. Absence is being read as zero." ;;
    *)    bad "a missing verdict gave ${_r}" ;;
esac

_r="$(_read 0 0 stale)"
case "$_r" in
    2\|*) ok "a verdict older than the run start is CANNOT-RUN, so a previous run's pass cannot be reported as this one's" ;;
    0\|*) bad "a STALE verdict is reported as this run's. This is how a crashed walk gets recorded as a pass." ;;
    *)    bad "a stale verdict gave ${_r}" ;;
esac

echo "── the harness must EXIT with the verdict ──"

# The bug was structural: the script ended on its last command, so its status
# was that command's. Check that the final statement is an exit driven by the
# verdict, and that a missing verdict exits CANNOT-RUN rather than falling off
# the end.
_lastexit="$(/usr/bin/grep -c '^exit "\$WALK_VERDICT"$' "$WALK")"
if [ "$_lastexit" -ge 1 ]; then
    ok "ttywalk.sh exits with \$WALK_VERDICT"
else
    bad "ttywalk.sh has no 'exit \$WALK_VERDICT'; it still exits with whatever ran last"
fi

_tail="$(awk 'NF && $0 !~ /^[[:space:]]*#/ {last=$0} END {print last}' "$WALK")"
case "$_tail" in
    'exit "$WALK_VERDICT"') ok "and that exit is the LAST executable statement, so nothing can run after it and reset the status" ;;
    *)                      bad "the last executable statement is '${_tail}', not the verdict exit" ;;
esac

if /usr/bin/grep -q 'NO VERDICT WAS RECORDED' "$WALK" && /usr/bin/grep -q 'exit "\$CANNOT_RUN"' "$WALK"; then
    ok "an unrecorded verdict exits CANNOT-RUN rather than falling through to a pass"
else
    bad "there is no CANNOT-RUN arm for a missing verdict; the script can still reach its end with no verdict at all"
fi

# THE HEADING. Publishing the raw exit status under the word VERDICT is what
# made walk 11 readable as green, so the two must not share a label.
if /usr/bin/grep -q 'EXIT CODE install.sh RETURNED (evidence, not a verdict)' "$WALK"; then
    ok "the raw exit status is printed under its own heading and is not called a verdict"
else
    bad "the raw exit status is still published under the VERDICT heading"
fi

echo "── the report must not call a non-ok step zero failures ──"

# MEASURED on walk 13. The run ended `DONE status=ok failed_steps=1` and the
# report printed `status=error steps: 0`. Both statements true. The step that
# actually failed was `STEP_END id=health_check status=timeout rc=124`, and a
# predicate that enumerates the failure words someone thought of cannot see a
# word they did not think of. The honest predicate is "not ok".
_TIMEOUT_LINE='#OSTLER	STEP_END	id=health_check	status=timeout	elapsed_s=110	rc=124'
_OK_LINE='#OSTLER	STEP_END	id=docker_install	status=ok	elapsed_s=3'

# BSD grep has no negative lookahead, so the predicate is tested with the same
# engine ttywalk's report uses: python's re.
_match() {
    python3 -c 'import re,sys; print("YES" if re.search(sys.argv[1], sys.argv[2]) else "NO")' "$1" "$2"
}

_pat="$(/usr/bin/grep -oE "show\('STEP_END not status=ok',[^)]*r'[^']*'" "$WALK" | sed -E "s/.*r'([^']*)'.*/\1/")"
if [ -z "$_pat" ]; then
    bad "ttywalk.sh has no 'STEP_END not status=ok' counter; a timed-out step still reports as zero failures"
else
    if [ "$(_match "$_pat" "$_TIMEOUT_LINE")" = YES ]; then
        ok "the report counts a status=timeout STEP_END as a failure"
    else
        bad "the failure predicate does not match a status=timeout step. This is the measured walk-13 blind spot."
    fi
    if [ "$(_match "$_pat" "$_OK_LINE")" = NO ]; then
        ok "CONTROL: it does NOT count a status=ok step, so the predicate discriminates rather than matching every STEP_END"
    else
        bad "CONTROL: the predicate also matches a status=ok step. It would report every clean walk as failing."
    fi
fi

# The narrow counters must survive as a BREAKDOWN. Collapsing every failure
# kind into one number loses which kind it was, and a timeout and an abort
# need different next actions.
if /usr/bin/grep -q "of which status=error" "$WALK" && /usr/bin/grep -q "of which status=timeout" "$WALK"; then
    ok "and the kinds are still broken out, so a timeout and an error do not print identically"
else
    bad "the failure kinds are no longer broken out"
fi

echo "── the harness must not manufacture a permission it cannot have ──"

# MEASURED on walk 13: the run reached the last step and recorded
# `STEP_END id=health_check status=timeout elapsed_s=110 rc=124` because
# install.sh probes iMessage Automation with osascript, and granting that is a
# macOS TCC decision requiring a GUI click that an ssh session can never make.
# The probe blocks for its full 90s deadline every single walk.
#
# install.sh ships PWG_IMESSAGE_PROBE_OUTCOME for exactly this. The VALUE is
# the whole risk: `granted-and-working` would fabricate a permission the box
# has not got and turn a walk into a lie. `check-failed` is the honest state
# and is the same value install.sh itself records on a real 124.
_shim="$(/usr/bin/grep -oE 'IMESSAGE_SHIM="[^"]*"' "$WALK" | head -1 | sed -E 's/.*"([^"]*)".*/\1/')"
case "$_shim" in
    check-failed)
        ok "the iMessage probe shim is 'check-failed', the honest could-not-determine state" ;;
    granted-and-working)
        bad "the shim is 'granted-and-working'. That FABRICATES a TCC grant this box does not have and makes every walk verdict a lie." ;;
    "")
        bad "no IMESSAGE_SHIM found in ttywalk.sh; the probe will block 90s and time out the last step every walk" ;;
    *)
        bad "the shim is '${_shim}', which is neither the honest state nor a recognised outcome" ;;
esac

# It must be PASSED to the run, not merely defined.
if /usr/bin/grep -q 'PWG_IMESSAGE_PROBE_OUTCOME=' "$WALK"; then
    ok "and it is exported into the run environment"
else
    bad "IMESSAGE_SHIM is defined but PWG_IMESSAGE_PROBE_OUTCOME is never passed to the run"
fi

# A REDUCTION IN COVERAGE THAT IS NOT DISCLOSED IS A CLAIM THAT IT DID NOT
# HAPPEN. The harness already discloses its staging gap; this one is the same
# shape and must be stated in the run output, not buried in a comment.
if /usr/bin/grep -q 'DOES NOT TEST THE REAL AUTOMATION PROBE' "$WALK"; then
    ok "and the run DISCLOSES that it does not exercise the real probe"
else
    bad "the shim is applied with no disclosure in the run output. A walk that passes would imply TCC was tested."
fi

echo "── no backticks may live inside the double-quoted ssh payloads ──"

# MEASURED on walk 15. The report block is one big DOUBLE-QUOTED ssh argument,
# so the LOCAL shell command-substitutes anything between backticks before the
# payload is sent. Comment text I had written using backticks for marker names
# was executed:
#
#     ttywalk.sh: line 133: DONE: command not found
#     ttywalk.sh: line 133: steps:: command not found
#     ttywalk.sh: line 133: STEP_END: command not found
#
# Harmless only because those words are not commands. The same block with
# `rm -rf ...` in a comment would have run it, with my privileges, on this
# machine, every walk.
_payload_backticks=0
_payload_lines=0
while IFS= read -r _range; do
    _s="${_range%%:*}"; _e="${_range##*:}"
    _n=$(awk -v s="$_s" -v e="$_e" 'NR>=s && NR<=e' "$WALK" | /usr/bin/grep -c '`')
    _payload_backticks=$((_payload_backticks + _n))
    _payload_lines=$((_payload_lines + _e - _s + 1))
done <<RANGES
$(python3 - "$WALK" <<'PYX'
import re, sys
lines = open(sys.argv[1], encoding='utf-8', errors='replace').read().split('\n')
# A double-quoted ssh payload opens with a heredoc inside "..." and closes on
# a line that is the heredoc terminator followed by the closing quote.
for i, l in enumerate(lines, 1):
    if re.search(r'"\s*$', l) or True:
        pass
starts = [i for i, l in enumerate(lines, 1) if re.search(r'<<\'PY\'', l)]
for s in starts:
    for j in range(s, len(lines)):
        if re.match(r'^PY"', lines[j]):
            print("%d:%d" % (s, j + 1))
            break
PYX
)
RANGES

if [ "$_payload_lines" -eq 0 ]; then
    echo "CANNOT-RUN: found no double-quoted ssh payload to examine in ${WALK}." >&2
    echo "  A check that examined nothing must not report a pass." >&2
    exit 2
fi
if [ "$_payload_backticks" -eq 0 ]; then
    ok "0 backticks across ${_payload_lines} line(s) of double-quoted ssh payload"
else
    bad "${_payload_backticks} backtick(s) inside a double-quoted ssh payload. The LOCAL shell executes what is between them before the payload is sent."
fi

# CONTROL ON THE DETECTOR. Without it, a broken range calculation would report
# zero backticks for the same reason it reports zero of anything.
_probe="${WORK}/probe.sh"
printf '%s\n' 'x="$(ssh h "python3 - <<'"'"'PY'"'"'" ' > "$_probe"
printf '%s\n' '# a comment with `a backtick` in it' >> "$_probe"
printf '%s\n' 'PY"' >> "$_probe"
_ctl=$(python3 - "$_probe" <<'PYX'
import re, sys
lines = open(sys.argv[1], encoding='utf-8', errors='replace').read().split('\n')
starts = [i for i, l in enumerate(lines, 1) if re.search(r"<<'PY'", l)]
n = 0
for s in starts:
    for j in range(s, len(lines)):
        if re.match(r'^PY"', lines[j]):
            n += sum(1 for k in range(s - 1, j + 1) if '`' in lines[k])
            break
print(n)
PYX
)
if [ "${_ctl:-0}" -ge 1 ]; then
    ok "CONTROL: the same detector finds a backtick in a fixture payload, so its zero above is a measurement"
else
    bad "CONTROL: the detector found no backtick in a fixture that contains one. Its zero proves nothing."
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
