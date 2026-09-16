#!/usr/bin/env bash
# tests/test_a_green_install_never_leaves_a_crash_looping_ollama.sh
# ============================================================================
# A GREEN OLLAMA STEP MUST MEAN *OUR* OLLAMA, NOT ANY LISTENER ON 11434.
#
# WHY THIS EXISTS (CM051 row 1574).
#
# MEASURED on origin/main before the fix, in install.sh:
#
#   the readiness loop      curl -sf 11434 AND (domain_absent OR our agent runs)
#   the health predicate    launchctl print gui/<uid>/com.ostler.ollama
#                           1 call site for gui/, 0 for user/
#   the registration        bootstrap gui/<uid>, and on failure `launchctl load`,
#                           which loads into the CALLER's domain (user/<uid> over ssh)
#   the plist               RunAtLoad true AND KeepAlive true
#   after the loop          ok "$MSG_OK_OLLAMA_RUNNING", and nothing in between
#
# So on a box with no Aqua session the loop is decided by the curl alone, a
# foreign Ollama satisfies it, and the agent this install registered, in a
# domain the health check never inspects, restarts about every 7 seconds for
# ever because it can never bind. Measured: 368 restarts in 40 minutes, behind
# a step that printed OK.
#
# THE PERSON THIS IS ABOUT. Someone who paid for the Hub, watched the installer
# finish, and has a service that is not running and nothing anywhere saying so.
# The most common way in is not exotic: a leftover com.ostler.ollama agent from
# a PREVIOUS install of theirs is still serving the port.
#
# SAME ROOT CAUSE AS ROW 1754, DIFFERENT ENDING. There the loop times out and
# the install aborts; #1995 made that abort name itself. Here the install
# PASSES. Both are a foreign holder of 11434.
#
# THE ARM THAT MATTERS MOST IS ARM 2, NOT ARM 1. Aborting whenever ollama.err
# has ever contained a bind error would break healthy installs: a KeepAlive
# agent that loses one race and then wins is fine, and its first failure stays
# in the log for ever. So the shipped test is not "did it fail" but "IS IT
# STILL FAILING", and arm 2 is the control that proves the fix does not fire
# on a transient that resolved.
#
# Exit 0 pass, 1 fail, 2 cannot-run. bash 3.2 and bash 5 both.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
INSTALL="$REPO/install.sh"

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
cant() { printf '  CANNOT-RUN  %s\n' "$1"; printf 'VERDICT: CANNOT-RUN, nothing was measured\n'; exit 2; }

TMP="$(mktemp -d)" || cant "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

printf 'A GREEN INSTALL NEVER LEAVES A CRASH-LOOPING OLLAMA\n'
printf '===================================================\n'
[ -r "$INSTALL" ] || cant "no install.sh at $INSTALL"

# ---- extract the REAL code under test, never a copy of it -------------------
# A copy rots silently: the test keeps passing against text the installer no
# longer runs. Everything below is lifted out of install.sh at run time, and a
# short extraction REFUSES rather than testing a fragment.
extract_fn() { # $1 = function name
    awk -v fn="$1" '
        $0 ~ "^[[:space:]]*"fn"\\(\\) \\{" { d=1 }
        d { print }
        d && $0 ~ "^[[:space:]]*\\}[[:space:]]*$" { exit }
    ' "$INSTALL"
}
FRESH_SRC="$(extract_fn _ollama_fresh_bind_failures)"
STOP_SRC="$(extract_fn _ollama_stop_doomed_agent)"
n_fresh="$(printf '%s\n' "$FRESH_SRC" | grep -c .)"
n_stop="$(printf '%s\n' "$STOP_SRC" | grep -c .)"
printf 'EXTRACTED: _ollama_fresh_bind_failures %s lines, _ollama_stop_doomed_agent %s lines\n' "$n_fresh" "$n_stop"
[ "${n_fresh:-0}" -ge 6 ] || cant "_ollama_fresh_bind_failures came back ${n_fresh} lines; that is not the function, so nothing below would be measuring it"
[ "${n_stop:-0}"  -ge 5 ] || cant "_ollama_stop_doomed_agent came back ${n_stop} lines; that is not the function"

# The decision block: from the marker comment down to the ok line.
DECIDE_SRC="$(awk '
    /THE LOOP ENDED\. THAT IS NOT THE SAME AS OUR OLLAMA RUNNING/ { d=1 }
    d { print }
    d && /^    ok "\$MSG_OK_OLLAMA_RUNNING"$/ { exit }
' "$INSTALL")"
n_decide="$(printf '%s\n' "$DECIDE_SRC" | grep -c .)"
printf 'EXTRACTED: the post-loop decision block, %s lines\n\n' "$n_decide"
[ "${n_decide:-0}" -ge 15 ] || cant "the post-loop decision block came back ${n_decide} lines, so it was not found: this suite would be asserting about nothing"

# ---- a harness that runs the real block against a fixture -------------------
# Stubs stand in for the installer's reporting and for lsof. They RECORD rather
# than print, so each arm can assert on what the customer would have been told
# and on what was done to their machine.
run_decision() { # $1 = fixture mode: growing | transient | clean | stale
    local mode="$1" out
    out="$TMP/$mode"; rm -rf "$out"; mkdir -p "$out"
    cat > "$out/drive.sh" <<DRIVER
set -uo pipefail
OLLAMA_LOG_DIR="$out"
OLLAMA_PLIST="$out/com.ostler.ollama.plist"
MSG_OK_OLLAMA_RUNNING="Ollama running"
MSG_FAIL_OLLAMA_PORT_IN_USE="port held by %s, see %s"
: > "\$OLLAMA_PLIST"
ok()   { printf 'OK %s\n'   "\$1" >> "$out/said"; }
warn() { printf 'WARN %s\n' "\$1" >> "$out/said"; }
fail_with_code() { printf 'FAIL_WITH_CODE %s %s\n' "\$1" "\$2" >> "$out/said"; exit 9; }
lsof() { printf 'cforeign-ollama\n'; }
launchctl() { printf 'launchctl %s\n' "\$*" >> "$out/launchctl"; return 0; }
sleep() { printf 'slept %s\n' "\$1" >> "$out/slept"; "$out/advance.sh"; }
$FRESH_SRC
$STOP_SRC
$DECIDE_SRC
DRIVER
    # advance.sh is what the fixture does DURING the bounded wait. This is the
    # whole discriminator: a crash loop writes another bind failure, a resolved
    # transient does not.
    case "$mode" in
        growing)   printf '%s\n' '#!/bin/sh' "echo 'listen tcp 127.0.0.1:11434: bind: address already in use' >> $out/ollama.err" > "$out/advance.sh" ;;
        *)         printf '%s\n' '#!/bin/sh' 'exit 0' > "$out/advance.sh" ;;
    esac
    chmod +x "$out/advance.sh"
    case "$mode" in
        stale)
            # written BEFORE the baseline offset: a previous install's failure
            printf 'listen tcp 127.0.0.1:11434: bind: address already in use\n' > "$out/ollama.err"
            printf 'OFFSET=%s\n' "$(wc -c < "$out/ollama.err" | tr -d ' ')" > "$out/offset"
            ;;
        clean)
            printf 'starting up, all slots idle\n' > "$out/ollama.err"
            printf 'OFFSET=0\n' > "$out/offset"
            ;;
        *)
            : > "$out/ollama.err"
            printf 'OFFSET=0\n' > "$out/offset"
            printf 'listen tcp 127.0.0.1:11434: bind: address already in use\n' >> "$out/ollama.err"
            ;;
    esac
    . "$out/offset"
    ( _ollama_err_bytes_before="$OFFSET"; export _ollama_err_bytes_before
      /bin/bash -c ". '$out/drive.sh'" ) >"$out/stdout" 2>"$out/stderr"
    printf '%s' "$?" > "$out/rc"
}
said()      { cat "$TMP/$1/said" 2>/dev/null; }
launchctls(){ cat "$TMP/$1/launchctl" 2>/dev/null; }
rc_of()     { cat "$TMP/$1/rc" 2>/dev/null; }

# ===== ARM 1: a live crash loop must not be reported as a working Ollama ====
run_decision growing
case "$(said growing)" in
    *"FAIL_WITH_CODE ERR-08-OLLAMA-PORT-11434-IN-USE"*)
        ok "arm 1: an agent still failing to bind fails with the curated code, not a green tick" ;;
    *)  bad "arm 1: no ERR-08 on a live crash loop" "the installer said: $(said growing | tr '\n' ';')" ;;
esac
case "$(said growing)" in
    *"OK Ollama running"*) bad "arm 1b: it printed the OK anyway" "a customer is told the thing they paid for is running while it respawns every 7 seconds" ;;
    *) ok "arm 1b: it does NOT print the Ollama-running tick" ;;
esac
# The holder is NAMED. "Something is wrong" is a support ticket; a process name
# is something the customer can act on.
case "$(said growing)" in
    *"foreign-ollama"*) ok "arm 1c: the failure names what is holding the port" ;;
    *) bad "arm 1c: the holder is not named in the failure" "$(said growing | tr '\n' ';')" ;;
esac

# ===== ARM 2: THE CONTROL. A transient that resolved is still a good install =
# This is the arm that stops the fix being worse than the defect. Without it,
# the honest-looking rule "ollama.err mentions a bind failure, therefore abort"
# would break every install whose agent lost one race and then won.
run_decision transient
case "$(said transient)" in
    *"OK Ollama running"*) ok "arm 2: a bind failure that STOPPED still reaches the Ollama-running tick" ;;
    *) bad "arm 2: a resolved transient was failed" "$(said transient | tr '\n' ';')" ;;
esac
case "$(said transient)" in
    *"FAIL_WITH_CODE"*) bad "arm 2b: a resolved transient produced a curated failure" "the fix fires on healthy installs, which is worse than the defect it replaces" ;;
    *) ok "arm 2b: no failure code on a resolved transient" ;;
esac
case "$(launchctls transient)" in
    *bootout*) bad "arm 2c: it booted out the agent on a healthy install" "the customer loses the service the install just set up" ;;
    *) ok "arm 2c: a healthy install keeps its agent (no bootout)" ;;
esac
# And it must not have cost a healthy install anything it did not have to.
if [ -f "$TMP/transient/slept" ]; then
    ok "arm 2d: the bounded wait happens only because there WAS fresh evidence to disambiguate"
else
    bad "arm 2d: no wait was taken, so the two states were never told apart"
fi

# ===== ARM 3: no fresh evidence at all costs nothing =========================
run_decision clean
case "$(said clean)" in
    *"OK Ollama running"*) ok "arm 3: a clean log reaches the tick" ;;
    *) bad "arm 3: a clean log did not reach the tick" "$(said clean | tr '\n' ';')" ;;
esac
if [ -f "$TMP/clean/slept" ]; then
    bad "arm 3b: it waited 8s on an install with nothing to disambiguate" "every healthy install pays for a check that cannot tell it anything"
else
    ok "arm 3b: no fresh bind failure means no wait, so a healthy install pays nothing"
fi

# ===== ARM 4: the OFFSET, and what it is actually load-bearing FOR ==========
# Same bind error, written BEFORE the baseline.
#
# 🔴 THIS ARM USED TO ASSERT ONLY THE VERDICT, AND THAT ASSERTED NOTHING ABOUT
# THE OFFSET. A mutant that ignored the baseline entirely still reached the
# right verdict here, because the growth check saves it independently: old
# failures do not grow, so the second count matches the first and the install
# proceeds. The arm passed while the thing it was named for was switched off.
#
# What the offset is really for is the TWO THINGS the growth check cannot fix:
# a customer told that THIS install's agent has failed to bind when those
# failures belong to a previous one, and 8 seconds spent on every install whose
# log happens to carry an old bind error. Both are visible; both are asserted.
run_decision stale
case "$(said stale)" in
    *"OK Ollama running"*) ok "arm 4: a bind failure from a PREVIOUS install does not fail this one" ;;
    *) bad "arm 4: a stale log line aborted a healthy install" "$(said stale | tr '\n' ';')" ;;
esac
case "$(said stale)" in
    *"failed to bind"*)
        bad "arm 4b: the customer is warned about bind failures that are not this install's" \
            "the baseline offset is not being applied, so a previous install's log condemns this one on screen" ;;
    *) ok "arm 4b: no warning about failures this install did not have" ;;
esac
if [ -f "$TMP/stale/slept" ]; then
    bad "arm 4c: it spent the bounded wait on a previous install's log lines" \
        "the baseline offset is not being applied: every install with an old bind error pays 8 seconds"
else
    ok "arm 4c: no wait is spent on a previous install's log lines"
fi

# ===== ARM 5: no crash loop is left behind on the way out ====================
# An install that stops has already registered RunAtLoad + KeepAlive. Walking
# away means the customer keeps a process respawning for ever on a machine
# where the install FAILED.
g="$(launchctls growing)"
case "$g" in *"bootout gui/"*) ok "arm 5: the doomed agent is booted out of the gui domain" ;;
             *) bad "arm 5: no gui bootout" "$g" ;; esac
case "$g" in *"bootout user/"*) ok "arm 5b: and out of the user domain, where the load fallback puts it" ;;
             *) bad "arm 5b: no user bootout, so an agent registered by the fallback survives" "$g" ;; esac
if [ -f "$TMP/growing/com.ostler.ollama.plist" ]; then
    bad "arm 5c: the plist survives, so a reboot revives the crash loop"
else
    ok "arm 5c: the plist is removed, so a reboot cannot revive it"
fi

# ===== ARM 6: the ABORT path cleans up too, not just the green path =========
# Row 1754's ending names the failure and, before this change, still left the
# agent behind. One root cause, both exits.
abort_block="$(awk '/#1574: #1995 named this failure and still walked away/,/fail_with_code "ERR-08/' "$INSTALL")"
n_abort="$(printf '%s\n' "$abort_block" | grep -c .)"
if [ "${n_abort:-0}" -eq 0 ]; then
    bad "arm 6: the timeout abort does not stop the doomed agent" "same root cause, and only one of the two exits cleans up"
else
    case "$abort_block" in
        *_ollama_stop_doomed_agent*) ok "arm 6: the timeout abort stops the doomed agent before failing ($n_abort lines)" ;;
        *) bad "arm 6: the abort block does not call the cleanup" "$abort_block" ;;
    esac
fi

# ===== ARM 7: REACHABILITY. A check after the tick changes nothing =========
# The same shape #1995's guard used: a named failure placed after the
# catch-all would be invisible to every customer who hits it.
decide_ln="$(grep -n 'THE LOOP ENDED. THAT IS NOT THE SAME AS OUR OLLAMA RUNNING' "$INSTALL" | head -1 | cut -d: -f1)"
ok_ln="$(awk '/^    ok "\$MSG_OK_OLLAMA_RUNNING"$/ {print NR}' "$INSTALL" | tail -1)"
if [ -z "$decide_ln" ] || [ -z "$ok_ln" ]; then
    cant "could not locate the decision block (${decide_ln:-none}) or the tick (${ok_ln:-none}) in install.sh"
fi
if [ "$decide_ln" -lt "$ok_ln" ]; then
    ok "arm 7: the check runs BEFORE the Ollama-running tick (:$decide_ln before :$ok_ln)"
else
    bad "arm 7: the check sits after the tick (:$decide_ln after :$ok_ln)" "a customer would be told it works and then told it does not"
fi

printf '\n===================================================\n'
printf 'RESULT: %s pass / %s fail (of %s assertions)\n' "$pass" "$fail" "$((pass + fail))"
[ "$fail" -eq 0 ] || exit 1
exit 0
