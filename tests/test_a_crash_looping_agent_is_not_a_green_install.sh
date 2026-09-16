#!/usr/bin/env bash
#
# tests/test_a_crash_looping_agent_is_not_a_green_install.sh
#
# A KeepAlive agent that cannot bind is a crash loop, not an install (#1574).
#
# WHAT WAS MEASURED, AND WHY THE ROW IS A CUSTOMER DEFECT RATHER THAN A TIDY-UP.
#
# Same root cause as #1754, different ending. Both are a foreign process
# holding 11434. In 1754 the readiness loop times out and the install aborts,
# and PR #1995 made that abort name itself. HERE THE INSTALL PASSES: the
# com.ostler.ollama agent then restarted 368 times in 40 minutes, about one
# every seven seconds, for ever, because its plist sets KeepAlive and it can
# never bind.
#
# The install reported "Ollama running" every one of those times.
#
# WHY IT PASSED. The readiness loop demands the port answers AND our own agent
# runs, but it can be satisfied while our agent is doomed, two ways:
#   1. on the _ollama_domain_absent path (no Aqua session, so no gui/ domain)
#      it degrades to THE CURL ALONE, and a foreign Ollama satisfies that;
#   2. with the domain present, "state = running" is caught in the window
#      between a KeepAlive restart and the failed bind. The poll runs every
#      2 s against a process that reappears every few seconds.
#
# THE GAP IS NOT THE OWNERSHIP PREDICATE, and that is worth stating because it
# is where a reader would look first. install.sh already knows reachability is
# not ownership, and _ollama_agent_is_running already parses the state rather
# than the exit code. The gap is that NOTHING READ THE EVIDENCE ON THE SUCCESS
# PATH. The bind failure is already in ollama.err, written by our own agent,
# while the loop is running. The timeout path reads that exact file. The
# success path never did.
#
# UNWORKED BEFORE THIS CHANGE, MEASURED WITH CONTROLS ON THE SAME CORPUS:
#     "#1574" in install.sh : 0
#     CONTROL "#1538"       : 5
#     CONTROL "#1540"       : 19
#     CONTROL "#1754"       : 2
# The controls are non-zero through the identical search, so the zero is a
# finding about the file and not a statement about the reader.
#
# CONSUMER-SIDE, AND THE SUBJECT IS A PERSON. The population is not "people who
# run Ollama". It is EVERY REPEAT INSTALLER: a leftover com.ostler.ollama agent
# from a previous install keeps serving 11434, and nothing in the reset path
# stops it. Such a customer finished the install, was told the local AI was
# running, and had nothing local answering them, while their Mac restarted a
# dead process every seven seconds until they next rebooted. They were not told
# and had no way to find out.
#
# WHAT THIS SUITE ASSERTS. It does not copy the logic. It EXTRACTS the shipped
# code out of install.sh at run time and drives it, so the test cannot pass
# against a file that no longer contains the fix, and refuses as CANNOT-RUN if
# the extraction comes back short. A suite that quietly tests its own copy is
# the failure mode this repo has already paid for.
#
# THE ARM THAT MATTERS MOST IS THE ONE THAT MUST NOT FIRE. One bind error is
# not a crash loop: a previous Ollama shutting down as ours starts produces
# exactly one, and launchd's restart then binds cleanly. Aborting on a single
# line would fail installs that were about to be fine, and that is a worse
# defect than the one being fixed. So arms B, C and E all pin "do not abort".
#
# British English throughout; " -- " not em-dashes, matching this repo.
#
# BASH 3.2 (the macOS system shell the installer ships under). No associative
# arrays, no mapfile, and no literal hash inside a command substitution.
#
# Exit 0 every arm passed / 1 an arm failed / 2 could not run.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${OSTLER_INSTALL_SH:-$REPO_ROOT/install.sh}"

PASS=0
FAIL=0
ok_()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad_() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

cannot_run() {
    printf 'CANNOT RUN: %s\n' "$1" >&2
    printf 'Nothing was measured. This is not a pass.\n' >&2
    exit 2
}

printf '== a crash-looping agent is not a green install (#1574) ==\n'
printf '   subject: %s\n\n' "$INSTALLER"

[ -r "$INSTALLER" ] || cannot_run "cannot read $INSTALLER"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ollamabind-XXXXXX")" || \
    cannot_run "could not make a scratch directory"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# EXTRACT THE SHIPPED CODE. Never a copy of it.
#
# Three fragments, each taken by its own anchor so a moved block is a
# CANNOT-RUN rather than a silent partial extraction.
# ---------------------------------------------------------------------------
extract_block() {
    awk -v start="$1" -v stop="$2" '
        index($0, start) { f = 1 }
        f { print }
        f && index($0, stop) && !index($0, start) { exit }
    ' "$INSTALLER"
}

FRAG_FAILURES="$WORK/frag_failures.sh"
FRAG_TEARDOWN="$WORK/frag_teardown.sh"
FRAG_VERIFY="$WORK/frag_verify.sh"

extract_block '_ollama_bind_failures_since() {' '    }' > "$FRAG_FAILURES"
extract_block '_ollama_stop_doomed_agent() {'   '    }' > "$FRAG_TEARDOWN"
extract_block '_ollama_binds_failed="$(_ollama_bind_failures_since' \
              'ok "$MSG_OK_OLLAMA_RUNNING"' > "$FRAG_VERIFY"

n_failures="$(wc -l < "$FRAG_FAILURES" | tr -d ' ')"
n_teardown="$(wc -l < "$FRAG_TEARDOWN" | tr -d ' ')"
n_verify="$(wc -l < "$FRAG_VERIFY" | tr -d ' ')"

printf 'EXTRACTED from the shipped installer:\n'
printf '  _ollama_bind_failures_since : %s line(s)\n' "$n_failures"
printf '  _ollama_stop_doomed_agent   : %s line(s)\n' "$n_teardown"
printf '  success-path verification   : %s line(s)\n' "$n_verify"
printf '\n'

# A SHORT EXTRACTION IS A REFUSAL, NEVER A PASS. If the block moved or was
# deleted, every arm below would run against an empty fragment and report a
# clean sheet. That is the exact shape of a gate that cannot fail.
[ "$n_failures" -ge 5 ] || cannot_run \
    "_ollama_bind_failures_since extracted as $n_failures line(s): the helper is not where this test expects, so nothing about it was measured"
[ "$n_teardown" -ge 4 ] || cannot_run \
    "_ollama_stop_doomed_agent extracted as $n_teardown line(s): the teardown is not where this test expects, so nothing about it was measured"
[ "$n_verify" -ge 15 ] || cannot_run \
    "the success-path verification extracted as $n_verify line(s): the block is not where this test expects, so nothing about it was measured"

# ---------------------------------------------------------------------------
# THE HARNESS. Stubs for everything that would touch the box, so the arms
# measure the DECISION and never the machine they run on.
# ---------------------------------------------------------------------------
build_harness() {
    _before="$1"     # bytes of ollama.err at bootstrap time
    _errfile="$2"    # the ollama.err this arm presents
    _grow_after="$3" # text appended during the recheck window, or empty

    cat > "$WORK/harness.sh" <<HARNESS
set -uo pipefail
OLLAMA_LOG_DIR="$(dirname "${_errfile}")"
OLLAMA_PLIST="$WORK/com.ostler.ollama.plist"
MSG_OK_OLLAMA_RUNNING="Ollama running"
MSG_FAIL_OLLAMA_PORT_IN_USE="PORT IN USE holder=%s log=%s"
_ollama_err_bytes_before="${_before}"

warn() { printf 'WARN %s\n' "\$*"; }
info() { printf 'INFO %s\n' "\$*"; }
ok()   { printf 'OK %s\n' "\$*"; }
fail_with_code() { printf 'FAIL_WITH_CODE %s :: %s\n' "\$1" "\$2"; exit 9; }

launchctl() { printf 'LAUNCHCTL %s\n' "\$*" >> "$WORK/launchctl.log"; return 0; }
lsof() { printf 'c%s\n' "\${OSTLER_TEST_PORT_HOLDER:-ollama}"; }

# The recheck window is where a looping agent writes its next failure. The
# sleep is replaced by the append, so the arm is deterministic and instant
# rather than a race against a real clock.
sleep() { ${_grow_after:-:}; }
HARNESS

    cat "$FRAG_FAILURES"  >> "$WORK/harness.sh"
    cat "$FRAG_TEARDOWN"  >> "$WORK/harness.sh"
    cat "$FRAG_VERIFY"    >> "$WORK/harness.sh"
}

run_arm() {
    build_harness "$1" "$2" "$3"
    ( bash "$WORK/harness.sh" ) > "$WORK/out.txt" 2>&1
    ARM_RC=$?
    ARM_OUT="$(cat "$WORK/out.txt")"
}

BIND_LINE='Error: listen tcp 127.0.0.1:11434: bind: address already in use'

fresh_plist() { printf 'a plist this install wrote\n' > "$WORK/com.ostler.ollama.plist"; }

# THE SHIPPED HELPER READS "${OLLAMA_LOG_DIR}/ollama.err" BY NAME. An arm that
# presents its fixture under any other name is testing nothing: the helper
# finds no file, returns no failures, and the arm passes for the wrong reason.
# The first run of this suite did exactly that and four arms went green
# vacuously, which is why each arm now gets its own directory and the file is
# always called ollama.err.
arm_log() {
    mkdir -p "$WORK/$1"
    printf '%s' "$WORK/$1/ollama.err"
}

ARMS=0

# --- ARM A: a clean log. The healthy install must not be touched. -----------
ARMS=$((ARMS + 1))
ERR="$(arm_log a)"
printf 'slot chatter\nall slots are idle\n' > "$ERR"
fresh_plist
run_arm 0 "$ERR" ""
case "$ARM_OUT" in
    *"OK Ollama running"*)
        case "$ARM_OUT" in
            *FAIL_WITH_CODE*) bad_ "A: a clean log aborted the install" ;;
            *) ok_ "A: a clean ollama.err reports Ollama running and does not abort" ;;
        esac ;;
    *) bad_ "A: a clean log did not reach the ok line (rc=$ARM_RC): $ARM_OUT" ;;
esac

# --- ARM B: THE FRESHNESS ARM. A bind error from a PREVIOUS install. --------
# This is the arm that stops the fix being worse than the defect: ollama.err
# survives across installs, and a whole-file grep would abort a good one.
ARMS=$((ARMS + 1))
ERR="$(arm_log b)"
printf '%s\n' "$BIND_LINE" > "$ERR"
OFFSET_B="$(wc -c < "$ERR" | tr -d ' ')"
printf 'slot chatter after a clean start\n' >> "$ERR"
fresh_plist
run_arm "$OFFSET_B" "$ERR" ""
case "$ARM_OUT" in
    *FAIL_WITH_CODE*) bad_ "B: a bind error from a PREVIOUS install aborted this one" ;;
    *"OK Ollama running"*) ok_ "B: a bind error written before this install is not counted against it" ;;
    *) bad_ "B: did not reach the ok line (rc=$ARM_RC): $ARM_OUT" ;;
esac

# --- ARM C: THE RACE. One failure, then it binds. Must not abort. -----------
ARMS=$((ARMS + 1))
ERR="$(arm_log c)"
printf 'starting\n' > "$ERR"
OFFSET_C="$(wc -c < "$ERR" | tr -d ' ')"
printf '%s\n' "$BIND_LINE" >> "$ERR"
fresh_plist
run_arm "$OFFSET_C" "$ERR" ":"
case "$ARM_OUT" in
    *FAIL_WITH_CODE*) bad_ "C: a single startup bind failure was treated as a crash loop" ;;
    *"OK Ollama running"*)
        case "$ARM_OUT" in
            *"one-off"*) ok_ "C: one bind failure then silence continues, and says it was a one-off" ;;
            *) bad_ "C: continued but never said why, so the operator cannot tell it happened" ;;
        esac ;;
    *) bad_ "C: did not reach the ok line (rc=$ARM_RC): $ARM_OUT" ;;
esac

# --- ARM D: THE DEFECT. Still failing in the window. Must abort. ------------
ARMS=$((ARMS + 1))
ERR="$(arm_log d)"
printf 'starting\n' > "$ERR"
OFFSET_D="$(wc -c < "$ERR" | tr -d ' ')"
printf '%s\n' "$BIND_LINE" >> "$ERR"
fresh_plist
run_arm "$OFFSET_D" "$ERR" "printf '%s\\n' '$BIND_LINE' >> '$ERR'"
case "$ARM_OUT" in
    *"FAIL_WITH_CODE ERR-08-OLLAMA-PORT-11434-IN-USE"*)
        ok_ "D: a second bind failure in the window aborts with the named error" ;;
    *"OK Ollama running"*)
        bad_ "D: an agent still failing to bind was reported as a green install" ;;
    *) bad_ "D: neither aborted nor completed (rc=$ARM_RC): $ARM_OUT" ;;
esac

# --- ARM D2: the abort must NAME THE HOLDER, not say 'unknown'. -------------
ARMS=$((ARMS + 1))
case "$ARM_OUT" in
    *"holder=ollama"*) ok_ "D2: the abort names the process holding the port" ;;
    *) bad_ "D2: the abort did not name the holder: $ARM_OUT" ;;
esac

# --- ARM D3: THE CRASH LOOP MUST BE TAKEN OUT, not left registered. --------
# An abort that leaves a KeepAlive agent behind has not fixed the defect: the
# customer still gets the seven-second restart, just without an install.
ARMS=$((ARMS + 1))
if [ -f "$WORK/com.ostler.ollama.plist" ]; then
    bad_ "D3: the doomed agent's plist survived the abort, so it still crash-loops at every login"
else
    booted=0
    if [ -r "$WORK/launchctl.log" ]; then
        case "$(cat "$WORK/launchctl.log")" in
            *bootout*) booted=1 ;;
        esac
    fi
    if [ "$booted" -eq 1 ]; then
        ok_ "D3: the abort boots the agent out AND removes the plist it wrote"
    else
        bad_ "D3: the plist went but launchctl bootout was never called"
    fi
fi

# --- ARM E: no ollama.err at all. No evidence is not a defect. --------------
ARMS=$((ARMS + 1))
ERR="$(arm_log e)"
rm -f "$ERR"
fresh_plist
run_arm 0 "$ERR" ""
case "$ARM_OUT" in
    *FAIL_WITH_CODE*) bad_ "E: an absent ollama.err aborted the install" ;;
    *"OK Ollama running"*) ok_ "E: an unreadable ollama.err yields no evidence and does not abort" ;;
    *) bad_ "E: did not reach the ok line (rc=$ARM_RC): $ARM_OUT" ;;
esac

# --- ARM F: a rotated (truncated) log must not resurrect an old error. ------
ARMS=$((ARMS + 1))
ERR="$(arm_log f)"
printf '%s\n%s\n' "$BIND_LINE" "$BIND_LINE" > "$ERR"
OFFSET_F=99999
fresh_plist
run_arm "$OFFSET_F" "$ERR" ""
case "$ARM_OUT" in
    *FAIL_WITH_CODE*) bad_ "F: a mark past the end of a rotated log still aborted" ;;
    *"OK Ollama running"*) ok_ "F: an offset beyond a rotated log reads short and does not abort" ;;
    *) bad_ "F: did not reach the ok line (rc=$ARM_RC): $ARM_OUT" ;;
esac

printf '\n'
printf 'ARMS: %s pass / %s fail of %s\n' "$PASS" "$FAIL" "$ARMS"
if [ "$FAIL" -gt 0 ]; then
    printf 'VERDICT: FAIL -- the installer can still report a green install while its own agent cannot bind.\n'
    exit 1
fi
printf 'VERDICT: PASS -- a confirmed bind loop stops the install and names the holder; a one-off does not.\n'
exit 0
