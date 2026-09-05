#!/usr/bin/env bash
# An absent launchd domain and a not-yet-loaded agent are different answers.
#
# WHY THIS EXISTS. MEASURED on archie, a headless walk account, 2026-09-05,
# walking the v1.0.71 DMG. The install aborted at step 5 of 41:
#
#     STEP_END id=ollama_install status=error elapsed_s=93 rc=1
#     46x Command failed inside a subshell at line 12050 (step ollama_install):
#           launchctl print "gui/$(id -u)/com.ostler.ollama" 2> /dev/null
#      1x Could not start Ollama automatically.
#
# THE SERVICE WAS NOT DOWN. THE QUESTION WAS UNANSWERABLE. Three-way probe on
# the box, and the control is the one that settles it:
#
#     launchctl print gui/502/com.ostler.ollama   rc=125
#     launchctl print gui/502                     rc=125   <- the WHOLE domain
#     launchctl print user/502                    rc=0     <- launchctl is fine
#
# 125 is not about the agent. There is no gui/<uid> domain, because that needs
# an Aqua session, so nothing about ANY agent in it is knowable. 113 -- the
# other non-zero -- IS the answer the poll is designed to receive, and it
# becomes 0 when the agent loads. The pre-fix reader collapsed both onto 1 and
# the loop retried the unanswerable one 46 times.
#
# THE TEST DRIVES THE READER, NOT THE BOX. `launchctl` is stubbed so each of
# the four launchd outcomes can be presented deterministically. A test that
# needed a real headless Mac could only ever run in one place.
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

# Extract the reader from a tree. Pinned to the function name, not a line
# number: a control anchored to a position in a file the same change edits is
# measuring whatever drifted into the slot.
_extract() {
    awk '
        /^_ollama_agent_is_running\(\) \{/ { f = 1 }
        f { print }
        f && /^\}$/ { exit }
    ' "$1"
}

# Drive the reader against a stubbed launchctl. Echoes the return code.
#   $1 tree   $2 stub-rc   $3 stub-stdout
_drive() {
    local tree="$1" src_rc="$2" src_out="$3" fn r="${WORK}/r"
    rm -rf "$r"; mkdir -p "$r/bin"
    fn="$(_extract "$tree")"
    [ -n "$fn" ] || { printf 'NOFN'; return; }
    cat > "$r/bin/launchctl" <<STUB
#!/usr/bin/env bash
printf '%s' "\$(cat <<'OUT'
${src_out}
OUT
)"
exit ${src_rc}
STUB
    chmod +x "$r/bin/launchctl"
    # 🔴 THE CALL MUST SIT IN AN `if`. install.sh runs under `set -Eeuo
    # pipefail` and this harness reproduces that deliberately, so a bare
    # `_ollama_agent_is_running; printf "$?"` exits the script the moment the
    # function returns non-zero and the printf never runs. Every non-zero case
    # then came back EMPTY, and an empty string is not equal to 2, which made
    # two CONTROL assertions pass for the wrong reason. An `if` suppresses
    # set -e for the condition, which is also how install.sh itself calls it.
    {
        printf '%s\n' 'set -Eeuo pipefail'
        printf '%s\n' "$fn"
        printf '%s\n' 'if _ollama_agent_is_running; then _rc=0; else _rc=$?; fi; printf "%s" "$_rc"'
    } > "$r/run.sh"
    PATH="$r/bin:/usr/bin:/bin" bash "$r/run.sh" 2>/dev/null
}

echo "── subject: this tree ──"

_r="$(_drive "$SUBJECT" 125 'Could not print domain: 125: Domain does not support specified action')"
case "$_r" in
    NOFN) echo "CANNOT-RUN: _ollama_agent_is_running was not found in ${SUBJECT}." >&2; exit 2 ;;
    2)    ok "rc=125 (no such domain) returns 2 -- distinguishable, so the poll can stop" ;;
    *)    bad "rc=125 returned ${_r}. An unanswerable query is indistinguishable from a not-yet-loaded agent, and the loop will retry it until it times out." ;;
esac

_r="$(_drive "$SUBJECT" 113 'Bad request.')"
[ "$_r" = "1" ] \
    && ok "CONTROL: rc=113 (domain present, label absent) still returns 1 -- the designed-for not-yet" \
    || bad "rc=113 returned ${_r}, expected 1. The ordinary negative must NOT be treated as unanswerable, or the poll gives up on a service that was about to start."

_r="$(_drive "$SUBJECT" 0 'com.ostler.ollama = {
	state = running
}')"
[ "$_r" = "0" ] \
    && ok "CONTROL: a loaded, running agent still returns 0 -- the fix did not blind the reader" \
    || bad "a running agent returned ${_r}, expected 0. The reader is broken."

_r="$(_drive "$SUBJECT" 0 'com.ostler.ollama = {
	state = not running
}')"
[ "$_r" = "1" ] \
    && ok "CONTROL: loaded but NOT running returns 1 -- state still separates the two rc=0 cases" \
    || bad "loaded-but-dead returned ${_r}, expected 1."

# ── The loop must ACT on the distinction, not merely have it available ──
# A reader that can say 2 and a loop that ignores it is a distinction written
# down and not implemented.
if grep -qF 'eq 2 ' "$SUBJECT" && grep -qF '_ollama_domain_absent' "$SUBJECT"; then
    ok "the poll reads the 2 and degrades once, rather than retrying an unanswerable query"
else
    bad "nothing consumes the 2. The reader can distinguish the cases and the loop cannot act on it."
fi

# The loader must SAY it failed rather than swallowing both attempts.
if grep -qF '_ollama_reg_rc' "$SUBJECT"; then
    ok "the LaunchAgent registration failure is reported at the point of loading"
else
    bad "bootstrap and load can still both fail silently; the only trace stays a poll that blames Ollama 90 seconds later"
fi

# ── NEGATIVE CONTROL, pinned to the tree that produced the abort ─────────
_CONTROL_SHA="2fb58d1e"
echo "── negative control: ${_CONTROL_SHA} (the tree whose walk aborted at step 5) ──"
_ctl="${WORK}/ctl.sh"
if ! git -C "$REPO" show "${_CONTROL_SHA}:install.sh" > "$_ctl" 2>/dev/null; then
    echo "CANNOT-RUN: control blob ${_CONTROL_SHA}:install.sh is unreadable." >&2
    echo "  A shallow clone cannot see it, and scanning nothing must not read" >&2
    echo "  as a passing control." >&2
    exit 2
fi

_r="$(_drive "$_ctl" 125 'Could not print domain: 125: Domain does not support specified action')"
case "$_r" in
    NOFN) echo "CANNOT-RUN: the reader was not found in the control blob." >&2; exit 2 ;;
    2)    bad "control ${_CONTROL_SHA} already returns 2 for rc=125, so this harness is not measuring the change." ;;
    *)    ok "control ${_CONTROL_SHA}: rc=125 returns ${_r}, collapsing the unanswerable case onto the ordinary one -- the defect reproduced" ;;
esac

# CONTROL ON THE CONTROL: the pre-fix reader must still be CORRECT about the
# cases it did handle, or its red above could be general breakage.
_r="$(_drive "$_ctl" 0 'com.ostler.ollama = {
	state = running
}')"
[ "$_r" = "0" ] \
    && ok "CONTROL ON THE CONTROL: the pre-fix reader is right about a running agent, so 125 is the discriminator" \
    || bad "the pre-fix reader also mishandles a running agent (${_r}); its red proves nothing specific."

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
