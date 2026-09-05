#!/usr/bin/env bash
# A port that answers is not our agent being healthy.
#
# WHY THIS EXISTS. MEASURED on the v1.0.71 walk box, 2026-09-05, WHILE THE
# INSTALL PRINTED "Ollama running":
#
#     com.ostler.ollama   state = spawn scheduled   runs = 409   last exit = 1
#     ~/.ostler/logs/ollama.err  14912 bytes, one line repeated:
#         Error: listen tcp 127.0.0.1:11434: bind: address already in use
#     curl 127.0.0.1:11434/api/tags   http=200
#     lsof                            ollama PID 15660, PPID 1, older than the
#                                     install, holds the port
#
# The guard asked two questions -- does something answer 11434, and does a plist
# exist -- and concluded a third: that our agent is healthy. `_ollama_agent_is_running`
# is defined immediately above it and answers exactly that. It was not called.
#
# It is the same conflation the file already warns about ~50 lines earlier,
# where ANOTHER ACCOUNT serving 11434 made a bare probe read as ours. That fix
# separated "is something serving?" from "is it ours?". It did not separate
# "is something serving?" from "is OUR AGENT FAILING?".
#
# THREE STATES OF VERDICT. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# Extract the decision: from the OLLAMA_PLIST assignment to the line that opens
# the install branch. Everything after is the installer body, which this test
# must never run.
_extract_guard() {
    awk '
        /^OLLAMA_PLIST="/ { f = 1 }
        f && /^    info "\$MSG_INFO_STARTING_OLLAMA"/ { print "    echo WOULD_INSTALL"; print "fi"; exit }
        f { print }
    ' "$1"
}

# Drive it. $1 port answers, $2 plist exists, $3 our agent is running.
# Echoes the branch taken: OK / WARN / WOULD_INSTALL.
_drive() {
    local port="$1" plist="$2" agent="$3" guard="$4"
    local d="${WORK}/run"; rm -rf "$d"; mkdir -p "$d/bin"
    # stub curl: succeed or fail exactly as asked
    printf '#!/usr/bin/env bash\nexit %s\n' "$([ "$port" = yes ] && echo 0 || echo 1)" > "$d/bin/curl"
    # stub launchctl so the evidence read in the warn branch has something to say
    printf '#!/usr/bin/env bash\nprintf "\\truns = 409\\nlast exit code = 1\\n"\n' > "$d/bin/launchctl"
    chmod +x "$d/bin/curl" "$d/bin/launchctl"
    local plistpath="${d}/absent.plist"
    [ "$plist" = yes ] && { plistpath="${d}/com.ostler.ollama.plist"; : > "$plistpath"; }
    {
        printf '%s\n' 'set -uo pipefail'
        printf '%s\n' "HOME='${d}'"
        printf '%s\n' 'ok()   { echo OK; }'
        printf '%s\n' 'warn() { echo "WARN $*"; }'
        printf '%s\n' 'info() { :; }'
        printf '%s\n' 'MSG_OK_OLLAMA_RUNNING="running"'
        printf '%s\n' 'MSG_INFO_STARTING_OLLAMA="starting"'
        printf '%s\n' 'MSG_WARN_OLLAMA_PORT_ANSWERS_BUT_AGENT_IS_NOT_RUNNING="served by %s / %s"'
        printf '_ollama_agent_is_running() { return %s; }\n' "$([ "$agent" = yes ] && echo 0 || echo 1)"
        printf '%s\n' "$guard"
    } > "${d}/g.sh"
    mkdir -p "${d}/Library/LaunchAgents"
    [ "$plist" = yes ] && : > "${d}/Library/LaunchAgents/com.ostler.ollama.plist"
    PATH="${d}/bin:${PATH}" bash "${d}/g.sh" 2>/dev/null | head -1
}

_G="$(_extract_guard "$SUBJECT")"
[ -n "$_G" ] || { echo "CANNOT-RUN: the ollama guard was not found in ${SUBJECT}" >&2; exit 2; }

echo "== subject: this tree =="
#      port plist agent   expected
for row in "yes:yes:yes:OK:everything healthy" \
           "yes:yes:no:WARN:THE MEASURED CASE -- the port answers and our agent is dead" \
           "no:yes:no:WOULD_INSTALL:nothing is serving, so install and bootstrap" \
           "no:no:no:WOULD_INSTALL:fresh box"; do
    IFS=: read -r p pl ag want why <<< "$row"
    got="$(_drive "$p" "$pl" "$ag" "$_G")"
    case "$got" in
        "$want"*) ok "port=${p} plist=${pl} agent=${ag} -> ${want}   (${why})" ;;
        *)        bad "port=${p} plist=${pl} agent=${ag} -> '${got}', expected ${want}   (${why})" ;;
    esac
done

# The warn must CARRY THE EVIDENCE, not just assert a state.
got="$(_drive yes yes no "$_G")"
case "$got" in
    *409*|*" 1"*) ok "the warning carries the respawn count and last exit code from launchctl, so the line is evidence rather than a verdict" ;;
    *)            bad "the warning does not carry the launchctl evidence: '${got}'" ;;
esac

# -- NEGATIVE CONTROL, pinned to the tree that printed OK over 409 failures ---
_CONTROL_SHA="ecef1565"
echo "== negative control: ${_CONTROL_SHA} (the tree that printed OK) =="
_ctl="${WORK}/control.sh"
if ! git -C "$REPO" cat-file -e "${_CONTROL_SHA}:install.sh" 2>/dev/null; then
    git -C "$REPO" fetch --depth=1 origin "$_CONTROL_SHA" >/dev/null 2>&1 || true
fi
if ! git -C "$REPO" show "${_CONTROL_SHA}:install.sh" > "$_ctl" 2>/dev/null; then
    echo "CANNOT-RUN: control blob ${_CONTROL_SHA}:install.sh is unreadable." >&2
    echo "  A shallow clone cannot see it, and scanning nothing must not read" >&2
    echo "  as a passing control." >&2
    exit 2
fi
_CG="$(_extract_guard "$_ctl")"
[ -n "$_CG" ] || { echo "CANNOT-RUN: no guard found in the control blob." >&2; exit 2; }

got="$(_drive yes yes no "$_CG")"
case "$got" in
    OK) ok "control ${_CONTROL_SHA}: prints OK while our agent is dead -- the measured defect reproduces" ;;
    *)  bad "control ${_CONTROL_SHA}: gave '${got}', so this harness is not measuring the defect" ;;
esac
got="$(_drive no no no "$_CG")"
case "$got" in
    WOULD_INSTALL) ok "CONTROL ON THE CONTROL: the pre-fix tree still installs on a fresh box, so the agent's health is the discriminator" ;;
    *)             bad "the pre-fix tree gave '${got}' on a fresh box; the discriminator is not what this test claims" ;;
esac

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
