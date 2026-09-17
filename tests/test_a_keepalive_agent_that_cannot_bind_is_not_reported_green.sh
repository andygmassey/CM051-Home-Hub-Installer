#!/usr/bin/env bash
# A KeepAlive agent that can never bind must not be reported as a green install.
#
# WHY THIS EXISTS (CM051 #1574). MEASURED on a box where something else already
# held 11434: com.ostler.ollama restarted 368 times in 40 minutes, about one
# every 7 seconds, for ever, on an install that had already printed "Ollama
# running". The plist carries KeepAlive, so launchd kept relaunching a process
# that could not take the port, and nothing in the install ever asked.
#
# WHY IT PASSED, which is the half that made it invisible. The readiness loop
# wants the port to answer AND our own agent to be running. A foreign Ollama
# answers the first for ever, and the second is momentarily TRUE on every
# respawn, because `state = running` is exactly what a crash-looping job looks
# like between exec and exit. On the _ollama_domain_absent path (no Aqua
# session, so launchd has no gui domain) there is no second condition at all:
# the loop falls back to the curl alone, which a stranger satisfies outright.
#
# SAME ROOT CAUSE AS #1754, OPPOSITE ENDING. There the loop times out and the
# install aborts with ERR-08 naming the holder. Here it never times out, so
# that curated abort is never reached.
#
# THE SUBJECT OF EVERY ARM BELOW IS THE REAL install.sh. The functions under
# test are EXTRACTED from it at run time rather than copied, so a reword that
# drops the check fails here instead of passing against a stale copy. A short
# extraction is CANNOT-RUN, never a pass: "found nothing wrong" and "never
# read the subject" must not print the same way.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
#
# bash 3.2 (macOS system bash) and bash 5 both. No associative arrays, no
# mapfile, no literal hash inside a command substitution.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cannot() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

[ -f "$SUBJECT" ] || cannot "no install.sh at ${SUBJECT}, so nothing was measured"
WORK="$(mktemp -d)" || cannot "no working directory"
trap 'rm -rf "$WORK"' EXIT

SUBJECT_LINES="$(wc -l < "$SUBJECT" | tr -d ' ')"
printf 'SUBJECT: %s (%s lines)\n\n' "$SUBJECT" "$SUBJECT_LINES"

# ---------------------------------------------------------------------------
# EXTRACT, and count what came out.
#
# Each function is defined at four-space indent inside the Ollama branch, so
# its body ends at the first line that is exactly four spaces and a closing
# brace. awk from the definition to that line.
# ---------------------------------------------------------------------------
extract_fn() {
    awk -v want="    $1() {" '
        $0 == want { inside = 1 }
        inside     { print }
        inside && $0 == "    }" { exit }
    ' "$SUBJECT"
}

BIND_FN="$(extract_fn _ollama_bind_failures_since)"
STOP_FN="$(extract_fn _ostler_stop_doomed_ollama_agent)"
BIND_FN_LINES="$(printf '%s\n' "$BIND_FN" | grep -c . || true)"
STOP_FN_LINES="$(printf '%s\n' "$STOP_FN" | grep -c . || true)"

printf 'EXTRACTED: _ollama_bind_failures_since %s lines, _ostler_stop_doomed_ollama_agent %s lines\n' \
    "$BIND_FN_LINES" "$STOP_FN_LINES"

# CONTROL ON THE EXTRACTOR ITSELF, and it runs BEFORE any absence is believed.
# A function name that certainly is not there must come back EMPTY. Without
# this, an extractor that returns the whole file (or the same text for every
# name) would make every arm below pass on nothing.
ABSENT_FN="$(extract_fn _ollama_this_function_does_not_exist_anywhere)"
ABSENT_FN_LINES="$(printf '%s\n' "$ABSENT_FN" | grep -c . || true)"
printf 'CONTROL:   a name that does not exist extracts %s lines (must be 0)\n\n' "$ABSENT_FN_LINES"
[ "$ABSENT_FN_LINES" -eq 0 ] \
    || cannot "the extractor returned ${ABSENT_FN_LINES} lines for a function that does not exist, so it cannot tell present from absent and no arm below would mean anything"

[ "$BIND_FN_LINES" -ge 8 ] \
    || cannot "_ollama_bind_failures_since extracted ${BIND_FN_LINES} lines from install.sh; the check this suite grades is not in the subject, so nothing was measured"
[ "$STOP_FN_LINES" -ge 5 ] \
    || cannot "_ostler_stop_doomed_ollama_agent extracted ${STOP_FN_LINES} lines from install.sh; the stop helper this suite grades is not in the subject, so nothing was measured"

# Drive the real extracted function against a fixture log.
drive_bind() {
    local logfile="$1" offset="$2"
    cat > "${WORK}/run.sh" <<EOF
set -uo pipefail
${BIND_FN}
_ollama_bind_failures_since "${logfile}" "${offset}"
EOF
    bash "${WORK}/run.sh" 2>/dev/null
}

BIND_LINE='time=2026-09-16T11:02:04Z level=ERROR msg="error listening on port" error="listen tcp 127.0.0.1:11434: bind: address already in use"'
CHATTER='slot print_timing: prompt eval time = 12.3 ms'

echo "== what OUR agent wrote, and only what our agent wrote =="

# ARM 1. The live defect. Our agent failed to bind after the offset, so the
# count is positive and the install has something to refuse on.
printf '%s\n%s\n%s\n' "$CHATTER" "$BIND_LINE" "$CHATTER" > "${WORK}/live.err"
r="$(drive_bind "${WORK}/live.err" 0)"
if [ "${r:-0}" -gt 0 ]; then
    ok "a bind failure written during this install is counted (${r})"
else
    bad "a bind failure written during this install counted ${r:-nothing}, so the crash loop stays invisible and the install still reports green"
fi

# ARM 2. THE CONTROL THAT MAKES THE OFFSET REAL, same corpus, same shape. A
# bind failure from a PREVIOUS install sits below the offset and is not this
# install's finding. If this arm goes red the check aborts healthy installs on
# a stale line, which is the expensive direction.
printf '%s\n%s\n' "$BIND_LINE" "$CHATTER" > "${WORK}/stale.err"
STALE_OFF="$(wc -c < "${WORK}/stale.err" | tr -d ' ')"
printf '%s\n' "$CHATTER" >> "${WORK}/stale.err"
r="$(drive_bind "${WORK}/stale.err" "$STALE_OFF")"
if [ "${r:-1}" -eq 0 ]; then
    ok "CONTROL: a bind failure from a PREVIOUS install is below the offset and is not counted"
else
    bad "a stale bind failure counted ${r}, so a healthy install would be aborted on a line written before it started"
fi

# ARM 3. CONTROL. A quiet log yields nothing, or the abort fires on every
# unrelated install and stops meaning anything.
printf '%s\n%s\n' "$CHATTER" 'all slots are idle' > "${WORK}/quiet.err"
r="$(drive_bind "${WORK}/quiet.err" 0)"
if [ "${r:-1}" -eq 0 ]; then
    ok "CONTROL: a log with no bind failure counts 0, so the abort cannot fire spuriously"
else
    bad "a clean log counted ${r}"
fi

# ARM 4. CONTROL. An ABSENT log must not crash and must not invent. Its only
# consumer promotes a POSITIVE count into an abort, so "could not look" must
# read as 0 here rather than as a finding.
r="$(drive_bind "${WORK}/no-such-file.err" 0)"
if [ "${r:-1}" -eq 0 ]; then
    ok "CONTROL: an absent log counts 0 rather than erroring or inventing a finding"
else
    bad "an absent log counted ${r}, so an unreadable file would abort an install"
fi

echo
echo "== the discriminator: a settled race is not a crash loop =="

# ARM 5. A live loop keeps writing. Second sample taken after the first, new
# bind failures appear in it, so the verdict is crash-looping.
printf '%s\n%s\n' "$CHATTER" "$BIND_LINE" > "${WORK}/loop.err"
LOOP_OFF="$(wc -c < "${WORK}/loop.err" | tr -d ' ')"
printf '%s\n%s\n' "$BIND_LINE" "$BIND_LINE" >> "${WORK}/loop.err"
r="$(drive_bind "${WORK}/loop.err" "$LOOP_OFF")"
if [ "${r:-0}" -gt 0 ]; then
    ok "a loop that is STILL failing after the resample point is counted (${r}), so the install refuses"
else
    bad "a live crash loop counted ${r:-nothing} in the second window, so the install would call it a settled race and report green"
fi

# ARM 6. A handover that resolved writes nothing more, so the second window is
# empty and the install continues. This is the arm that keeps the fix from
# failing a healthy box.
printf '%s\n%s\n' "$CHATTER" "$BIND_LINE" > "${WORK}/settled.err"
SETTLED_OFF="$(wc -c < "${WORK}/settled.err" | tr -d ' ')"
printf '%s\n%s\n' "$CHATTER" 'all slots are idle' >> "${WORK}/settled.err"
r="$(drive_bind "${WORK}/settled.err" "$SETTLED_OFF")"
if [ "${r:-1}" -eq 0 ]; then
    ok "CONTROL: a bind failure that settled writes nothing into the second window, so a healthy install is not aborted"
else
    bad "a settled handover counted ${r} in the second window, so healthy installs would abort"
fi

echo
echo "== is any of it reachable by a customer =="

# ARM 7. The check must sit AFTER the readiness loop and BEFORE the line that
# tells the customer Ollama is running. Placed after it, the sentence they read
# is unchanged and this whole change is decorative.
GREEN_LN="$(awk '/^    ok "\$MSG_OK_OLLAMA_RUNNING"$/ { print NR }' "$SUBJECT" | tail -1)"
CHECK_LN="$(awk '/_ollama_bind_fails="\$\(_ollama_bind_failures_since/ { print NR; exit }' "$SUBJECT")"
LOOP_END_LN="$(awk -v stop="${GREEN_LN:-0}" 'NR < stop && $0 == "    done" { n = NR } END { print n }' "$SUBJECT")"
if [ -n "$CHECK_LN" ] && [ -n "$GREEN_LN" ] && [ -n "$LOOP_END_LN" ] \
   && [ "$LOOP_END_LN" -lt "$CHECK_LN" ] && [ "$CHECK_LN" -lt "$GREEN_LN" ]; then
    ok "the check at :${CHECK_LN} runs after the readiness loop ends at :${LOOP_END_LN} and before the green line at :${GREEN_LN}"
else
    bad "could not establish that the check runs between the loop and the green line (loop_end=${LOOP_END_LN:-none} check=${CHECK_LN:-none} green=${GREEN_LN:-none}); the customer still reads 'Ollama running' over a crash loop"
fi

# ARM 8. BOTH curated exits must take the agent back out. DENOMINATOR 2: the
# pre-existing #1754 timeout abort and the new post-loop abort. An install that
# stops while leaving a registered KeepAlive agent behind has left the 368
# restarts running, which is the harm this row is about.
ERR08_COUNT="$(grep -c 'fail_with_code "ERR-08-OLLAMA-PORT-11434-IN-USE"' "$SUBJECT" || true)"
STOP_CALLS="$(grep -c '^ *_ostler_stop_doomed_ollama_agent$' "$SUBJECT" || true)"
printf '  DENOMINATOR: %s ERR-08 abort sites, %s stop calls\n' "$ERR08_COUNT" "$STOP_CALLS"
if [ "$ERR08_COUNT" -ge 2 ] && [ "$STOP_CALLS" -ge "$ERR08_COUNT" ]; then
    ok "every ERR-08 abort site (${ERR08_COUNT}) is matched by a stop call (${STOP_CALLS}), so no curated exit leaves a crash-looper behind"
else
    bad "ERR-08 abort sites=${ERR08_COUNT} stop calls=${STOP_CALLS}: an abort path leaves the KeepAlive agent registered, so the restarts continue after the install gives up"
fi

# ARM 9. The stop must REMOVE THE PLIST, not merely bootout. A bootout lasts
# until the next login; the file is what brings the agent back, so without this
# the loop returns the next time the customer logs in and nothing says so.
if [ "$(printf '%s\n' "$STOP_FN" | grep -c 'rm -f "\$OLLAMA_PLIST"')" -gt 0 ]; then
    ok "the stop helper removes the plist, so the agent does not return at the next login"
else
    bad "the stop helper does not remove the plist, so launchd loads it again at the next login and the 7-second restarts resume"
fi

# ARM 10. The stop must cover BOTH launchd domains. Registration tries
# bootstrap into gui/<uid> and falls back to `launchctl load`, which lands
# wherever the caller is, so booting out only one domain leaves the other one
# running.
DOMAINS="$(printf '%s\n' "$STOP_FN" | grep -c 'launchctl bootout' || true)"
if [ "$DOMAINS" -ge 2 ]; then
    ok "the stop helper boots out ${DOMAINS} domains, covering the bootstrap and the legacy load path"
else
    bad "the stop helper boots out ${DOMAINS} domain(s); the agent registered by the other path keeps restarting"
fi

printf '\n== %d pass / %d fail / %d total ==\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
