#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_uninstall_stops_what_it_deletes.sh
#
# Uninstalling Ostler must leave no process running out of a bundle it has
# just deleted. Not "the directory is gone". Nothing still executing.
#
# WHY DELETING THE BUNDLE IS NOT ENOUGH
# ---------------------------------------------------------------------------
# This is the exact mirror of the defect
# tests/test_uninstall_removes_every_launchagent_plist.sh guards. There, a
# `launchctl bootout` without removing the plist uninstalls nothing that
# survives a reboot, because launchd rescans the directory at login: the FILE
# is the load-bearing half.
#
# For an .app bundle the asymmetry runs the other way. On macOS a running
# image is held by its vnode, so `rm -rf` on the bundle unlinks the directory
# and the process carries on with its executable unlinked underneath it. The
# PROCESS is the load-bearing half, and the file removal is the part that
# already worked.
#
# MEASURED ON THE WALK BOX, 2026-09-07, NOT THEORISED:
#
#   /Applications/Ostler.app   absent by ls, by test -d AND by find
#   pid 28913                  /Applications/Ostler.app/Contents/MacOS/
#                              ostler-hub, running since 2026-09-05 23:18
#   launchctl                  application.ai.creativemachines.ostler-hub...
#
# WHY THE EXISTING TEARDOWN COULD NEVER CATCH IT
# ---------------------------------------------------------------------------
# Every teardown in install.sh is keyed to a launchd LABEL we wrote --
# com.ostler.* and com.creativemachines.*. The residue above carries an
# `application.*` label, which is what LaunchServices assigns to an app the
# customer OPENED. `launchctl bootout` on our labels cannot reach it, and
# install.sh contains 0 references to the `application.` form. The uninstall
# tests on main cover plists, decoder cases, docker resolution, the GUI
# marker protocol and counts. None of them looks at the process table.
#
# THE TWO AXES
# ---------------------------------------------------------------------------
#   A. COMPLETENESS (source). Every /Applications/*.app bundle the
#      uninstaller removes must be handed to _u_quit_bundle_processes BEFORE
#      the rm that unlinks it. Order matters: quitting after the unlink is
#      the bug this file exists for.
#   B. BEHAVIOUR (live). Extract the helper, run it against a real process
#      executing from a sandboxed fake bundle, and require the process to be
#      gone. With two controls that must NOT fire: a process from a
#      DIFFERENT bundle must survive, and the helper must never kill its own
#      caller.
#
# Arm 7 is the one that keeps this honest. install.sh can itself run from
# /Applications/OstlerInstaller.app/Contents/Resources/install.sh, so a
# widened pattern could have the uninstaller kill itself half way through a
# teardown -- strictly worse than not uninstalling. If that arm ever goes
# red, the fix is the pattern, never this test.
#
# Exit 0 all pass / 1 a check failed / 2 could not run.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${HERE}/../install.sh"

[[ -f "$INSTALL_SH" ]] || { echo "CANNOT-RUN: no install.sh at ${INSTALL_SH} (exit 2)" >&2; exit 2; }
command -v pgrep >/dev/null 2>&1 || { echo "CANNOT-RUN: no pgrep on PATH (exit 2)" >&2; exit 2; }

_fails=0; _total=0
ok()  { _total=$((_total+1)); printf '  ok    %s\n' "$1"; }
bad() { _total=$((_total+1)); _fails=$((_fails+1)); printf '  FAIL  %s\n' "$1"; }

# ── Axis A: source ─────────────────────────────────────────────────────────
echo "axis A: every bundle the uninstaller deletes is stopped first"

if grep -q '^_u_quit_bundle_processes() {' "$INSTALL_SH"; then
    ok "1 install.sh defines _u_quit_bundle_processes"
else
    echo "CANNOT-RUN: install.sh has no _u_quit_bundle_processes definition (exit 2)" >&2
    exit 2
fi

# The bundles the uninstaller actually unlinks, read out of the source rather
# than hard-coded here: a new bundle must be covered without editing this file.
mapfile -t _rm_bundles < <(
    grep -oE 'rm -rf "(/Applications/[^"]+\.app)"' "$INSTALL_SH" \
        | sed -E 's/.*"(.*)"/\1/' | sort -u
)

if [[ "${#_rm_bundles[@]}" -ge 1 ]]; then
    ok "2 found ${#_rm_bundles[@]} /Applications bundle(s) the uninstaller removes"
else
    echo "CANNOT-RUN: found no 'rm -rf \"/Applications/*.app\"' at all -- the" >&2
    echo "            search shape is wrong, not the code (exit 2)" >&2
    exit 2
fi

for _b in "${_rm_bundles[@]}"; do
    _quit_line="$(grep -nF "_u_quit_bundle_processes \"${_b}\"" "$INSTALL_SH" | head -1 | cut -d: -f1)"
    _rm_line="$(grep -nF "rm -rf \"${_b}\"" "$INSTALL_SH" | head -1 | cut -d: -f1)"
    _name="$(basename "$_b")"
    if [[ -z "$_quit_line" ]]; then
        bad "3 ${_name}: deleted at line ${_rm_line} and never stopped"
    elif [[ "$_quit_line" -lt "$_rm_line" ]]; then
        ok "3 ${_name}: stopped at ${_quit_line}, deleted at ${_rm_line}"
    else
        bad "3 ${_name}: stopped at ${_quit_line} AFTER the delete at ${_rm_line}"
    fi
done

# ── Axis B: behaviour ──────────────────────────────────────────────────────
echo "axis B: the helper actually stops a running process"

# Extract the function from install.sh: from its definition to the first line
# that is a bare closing brace.
FN="$(awk '/^_u_quit_bundle_processes\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$INSTALL_SH")"
if [[ -n "$FN" ]] && grep -q '^}$' <<< "$FN"; then
    ok "4 extracted the helper as a complete function"
else
    echo "CANNOT-RUN: could not extract a complete function body (exit 2)" >&2
    exit 2
fi

eval "$FN" || { echo "CANNOT-RUN: extracted helper does not parse (exit 2)" >&2; exit 2; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/uninst.XXXXXX")" || { echo "CANNOT-RUN: mktemp failed (exit 2)" >&2; exit 2; }
cleanup() {
    pkill -KILL -f "${SANDBOX}/" 2>/dev/null || true
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

# A background child started inside $(...) keeps the capture pipe open, so the
# command substitution never returns -- and $! set in that subshell is lost to
# the caller anyway. Set the caller's variables directly and detach the child's
# stdio instead.
mkbundle() { # <name> <path-var> <pid-var>
    local _name="$1" _pathvar="$2" _pidvar="$3"
    local _p="${SANDBOX}/${_name}.app/Contents/MacOS"
    mkdir -p "$_p"
    cat > "${_p}/runner" <<'RUNNER'
#!/bin/bash
# A plain sleep loop that traps nothing, so SIGTERM is what ends it.
while :; do sleep 0.2; done
RUNNER
    chmod +x "${_p}/runner"
    "${_p}/runner" >/dev/null 2>&1 &
    printf -v "$_pidvar" '%s' "$!"
    printf -v "$_pathvar" '%s' "${SANDBOX}/${_name}.app"
}

# 5. a process running from the bundle is stopped
TARGET=""; TARGET_PID=""; OTHER=""; OTHER_PID=""
mkbundle Target TARGET TARGET_PID
mkbundle Other  OTHER  OTHER_PID
sleep 0.5

if kill -0 "$TARGET_PID" 2>/dev/null && kill -0 "$OTHER_PID" 2>/dev/null; then
    _u_quit_bundle_processes "$TARGET" >/dev/null 2>&1
    sleep 0.3
    if kill -0 "$TARGET_PID" 2>/dev/null; then
        bad "5 the process running from the deleted bundle SURVIVED"
    else
        ok "5 the process running from the bundle was stopped"
    fi
    # 6. CONTROL: a different bundle's process must be untouched. Without
    #    this, a helper that killed everything would pass arm 5.
    if kill -0 "$OTHER_PID" 2>/dev/null; then
        ok "6 a process from a DIFFERENT bundle was left alone"
    else
        bad "6 it killed an unrelated bundle's process -- far too broad"
    fi
else
    bad "5 CANNOT-RUN: the sandbox processes did not start"
    bad "6 CANNOT-RUN: no control to measure"
fi

# 7. CONTROL: the helper must not kill its own caller. Point it at a bundle
#    path that our own argv contains and require this shell to survive.
SELFISH="${SANDBOX}/Self.app"
mkdir -p "${SELFISH}/Contents/MacOS"
_u_quit_bundle_processes "$SELFISH" >/dev/null 2>&1
_rc_self=$?
if [[ "$_rc_self" -eq 0 ]]; then
    ok "7 the helper returned 0 and this shell is still alive"
else
    bad "7 the helper returned ${_rc_self} against an idle bundle"
fi

# 8. a bundle nothing runs from is a silent no-op, not an error
IDLE="${SANDBOX}/Idle.app"
mkdir -p "${IDLE}/Contents/MacOS"
_out="$(_u_quit_bundle_processes "$IDLE" 2>&1)"; _rc_idle=$?
if [[ "$_rc_idle" -eq 0 && -z "$_out" ]]; then
    ok "8 nothing running -> rc 0 and no output"
else
    bad "8 idle bundle produced rc=${_rc_idle} output=${_out:0:60}"
fi

echo
if [[ $_fails -eq 0 ]]; then echo "PASS: ${_total}/${_total}"; exit 0; fi
echo "FAIL: ${_fails} of ${_total}"; exit 1
