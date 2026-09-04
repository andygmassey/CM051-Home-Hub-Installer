#!/usr/bin/env bash
# THE OLLAMA LAUNCHAGENT MUST NOT BE SKIPPED BECAUSE SOMEONE ELSE'S OLLAMA ANSWERED.
#
# WHY THIS EXISTS. MEASURED 2026-09-04 on the v1.0.66 ARTEFACT walk, on a green
# install, and it is why install_manifest_complete reported a required agent
# missing:
#
#     curl http://127.0.0.1:11434/                    -> 200
#     lsof -nP -iTCP:11434  (as the walk user)        -> NOTHING
#     ~/Library/LaunchAgents/com.ostler.ollama.plist  -> ABSENT
#     #OSTLER STEP_END id=ollama_install status=ok elapsed_s=0
#
# ANOTHER ACCOUNT ON THE SAME MAC WAS SERVING 11434. The pre-fix guard was a
# bare loopback curl with no ownership check:
#
#     if curl -s http://localhost:11434/api/tags &>/dev/null; then
#         ok "already running"          <- taken, because SOMEBODY answered
#     else
#         ... the ONLY place com.ostler.ollama.plist is ever written
#
# so the install ended with no LaunchAgent, nothing to start Ollama at boot,
# and a dependency on a process owned by a different user that vanishes when
# that user logs out. The step said ok in zero seconds.
#
# TWO QUESTIONS WERE CONFLATED:
#   "is something serving 11434?"   -> whether we need to START Ollama
#   "do we have our own agent?"     -> whether this install is COMPLETE
# Only the second is about us.
#
# THIS TEST DRIVES THE CONDITION, NOT THE FILE. The defect is a boolean over
# two inputs, so it is tested as one: four states, and the one that matters is
# serving-but-no-plist.
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

# Pull the guard line out of install.sh rather than restating it, so a reword
# that drops the plist test fails here instead of passing a copy.
GUARD="$(grep -m1 -F 'if curl -s http://localhost:11434/api/tags' "$SUBJECT")"
[ -n "$GUARD" ] || { echo "CANNOT-RUN: the ollama guard line was not found in install.sh." >&2
                     echo "  It was extracted by its curl; a rewrite must fail loudly here" >&2
                     echo "  rather than silently testing nothing." >&2; exit 2; }

# Drive it. serving=0/1 and plist=present/absent; echoes SKIP (do nothing) or CREATE.
_drive() {
    local serving="$1" plist_present="$2" guard="$3" p="${WORK}/com.ostler.ollama.plist"
    rm -f "$p"; [ "$plist_present" = "present" ] && : > "$p"
    cat > "${WORK}/run.sh" <<EOF
set -uo pipefail
OLLAMA_PLIST="$p"
curl() { return $(( serving == 1 ? 0 : 1 )); }
${guard}
    echo SKIP
else
    echo CREATE
fi
EOF
    bash "${WORK}/run.sh" 2>/dev/null
}

echo "── the four states, current tree ──"

r="$(_drive 1 absent "$GUARD")"
[ "$r" = "CREATE" ] \
    && ok "serving + NO plist -> CREATE. This is the measured defect and it is closed." \
    || bad "serving + NO plist -> ${r}. Another account's Ollama still suppresses our LaunchAgent; the install ships without one."

r="$(_drive 1 present "$GUARD")"
[ "$r" = "SKIP" ] \
    && ok "serving + plist present -> SKIP. A complete install is not redone." \
    || bad "serving + plist present -> ${r}. The fix rewrites the agent on every run."

r="$(_drive 0 absent "$GUARD")"
[ "$r" = "CREATE" ] \
    && ok "not serving + NO plist -> CREATE" \
    || bad "not serving + NO plist -> ${r}"

r="$(_drive 0 present "$GUARD")"
[ "$r" = "CREATE" ] \
    && ok "not serving + plist present -> CREATE, so a dead Ollama is still started" \
    || bad "not serving + plist present -> ${r}. A stopped Ollama would never be restarted."

echo "── negative control: the PRE-FIX guard must reproduce the defect ──"
# The shipped v1.0.66 form, stated literally. If this ever stops reproducing,
# the test has lost the thing it watches.
PREFIX_GUARD='if curl -s http://localhost:11434/api/tags &>/dev/null; then'
r="$(_drive 1 absent "$PREFIX_GUARD")"
[ "$r" = "SKIP" ] \
    && ok "pre-fix guard: serving + NO plist -> SKIP, reproducing the v1.0.66 behaviour" \
    || bad "pre-fix guard did NOT reproduce (${r}); this harness is not measuring the defect."

r="$(_drive 0 absent "$PREFIX_GUARD")"
[ "$r" = "CREATE" ] \
    && ok "CONTROL ON THE CONTROL: the pre-fix guard is fine when nothing answers, so SERVING is the discriminator" \
    || bad "the pre-fix guard fails with nothing serving too (${r}); the control proves nothing about the port."

echo "── the guard must still consult BOTH inputs ──"
case "$GUARD" in
    *'api/tags'*'OLLAMA_PLIST'*) ok "the shipped guard tests the port AND our own plist" ;;
    *) bad "the shipped guard no longer names OLLAMA_PLIST: ${GUARD}" ;;
esac

echo "── THE HEALTH ARM: it FIRED on the v1.0.66 artefact walk ──"
# Measured: health_check closed ok and logged "Ollama healthy" while the walked
# account had NO agent and the 200 came from another account's ollama. Worse
# than the create-skip: not "skip the install" but HIDE A FAILED ONE, inside
# the step whose job is to notice.
# The condition spans TWO physical lines (it ends in a backslash continuation),
# so a bare `grep -m1` returns a fragment ending in `\` and the driven script
# is a syntax error that reports EMPTY. Follow the continuation.
HGUARD="$(awk '/if curl -sf http:\/\/localhost:11434\/api\/tags/ {
                   line = $0
                   while (line ~ /\\$/) { sub(/\\$/, "", line); getline nxt; line = line nxt }
                   print line; exit
               }' "$SUBJECT")"
if [ -z "$HGUARD" ]; then
    echo "CANNOT-RUN: the health arm was not found in install.sh." >&2; exit 2
fi

# Drive it. `agent` is one of: running | dead | absent -- and the middle one is
# the whole point. MEASURED on macOS, three labels, three outcomes:
#
#     absent label            rc=113   (no state line)
#     loaded but NOT running  rc=0     state = not running
#     loaded AND running      rc=0     state = running
#
# rc=0 covers BOTH running and dead, so a stub that only returns an exit code
# cannot tell them apart -- which is exactly the blindness the first version of
# this fix had. The stub therefore emits the STATE LINE launchd really prints.
_health() {
    local answered="$1" agent="$2"
    local lc_out lc_rc
    case "$agent" in
        running) lc_out='	state = running'      ; lc_rc=0   ;;
        dead)    lc_out='	state = not running'  ; lc_rc=0   ;;
        absent)  lc_out=''                        ; lc_rc=113 ;;
        *)       echo "BAD_FIXTURE"; return ;;
    esac
    cat > "${WORK}/h.sh" <<EOF
set -uo pipefail
curl() { return $(( answered == 1 ? 0 : 1 )); }
launchctl() { printf '%s\n' ${lc_out:+"$(printf '%q' "$lc_out")"}; return ${lc_rc}; }
ok() { echo OK; }
${HGUARD}
    ok
else
    echo UNHEALTHY
fi
EOF
    bash "${WORK}/h.sh" 2>/dev/null
}

r="$(_health 1 absent)"
[ "$r" = "UNHEALTHY" ] \
    && ok "port answers, our agent ABSENT -> UNHEALTHY. This is the arm that fired on walk 6." \
    || bad "port answers + agent absent -> ${r}. A foreign Ollama still reports this install healthy."

r="$(_health 1 dead)"
[ "$r" = "UNHEALTHY" ] \
    && ok "port answers, our agent LOADED BUT NOT RUNNING -> UNHEALTHY. launchctl returns rc=0 here, so an exit-code gate would pass it." \
    || bad "port answers + agent loaded-but-dead -> ${r}. THIS IS THE rc=0 BLINDNESS: registration is not runnability."

r="$(_health 1 running)"
[ "$r" = "OK" ] \
    && ok "port answers AND our agent is running -> healthy" \
    || bad "a genuinely healthy Ollama reports ${r}; the fix reddens working installs."

r="$(_health 0 running)"
[ "$r" = "UNHEALTHY" ] \
    && ok "our agent runs but nothing answers -> UNHEALTHY, so a dead port is still caught" \
    || bad "a dead port with our agent running reports ${r}."

case "$HGUARD" in
    *launchctl*state\ =\ running*|*state\ =\ running*launchctl*)
        ok "the health arm parses state = running, not launchctl's exit code" ;;
    *launchctl*)
        bad "the health arm calls launchctl but does not parse the state. rc=0 covers BOTH running and dead, so this passes a parked agent: ${HGUARD}" ;;
    *)  bad "the health arm no longer names launchctl: ${HGUARD}" ;;
esac

echo "── and it must NOT be built on lsof ──"
# install.sh's own _port_is_our_own_forward records that an unprivileged lsof
# returns no pid for a foreign-owned holder, so lsof is EMPTY on exactly this
# collision (#549). An lsof-shaped check here would be the same defect again.
case "$HGUARD" in
    *lsof*) bad "the health arm uses lsof, which returns empty on the cross-account collision it would be written for (#549)." ;;
    *) ok "the health arm does not use lsof, which cannot see a foreign-owned holder" ;;
esac

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
