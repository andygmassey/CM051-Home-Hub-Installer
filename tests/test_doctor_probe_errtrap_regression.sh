#!/usr/bin/env bash
# Regression test for CX-122 / #640: the Phase-4 ostler-assistant doctor
# probe must NOT false-fail a successful install when the daemon is still
# warming up (or, on stock macOS, when `timeout` is absent).
#
# ROOT CAUSE (reproduced + verified on Studio .133, bash 3.2.57, no
# timeout, via an ERR-trap ledger):
#   install.sh runs `set -Eeuo pipefail` + an abort-on-error ERR trap
#   (_ostler_on_err -> gui_done fail). `set -E` (errtrace) propagates that
#   ERR trap INTO the $(...) command-substitution subshell. The doctor
#   probe `DOCTOR_OUTPUT=$(timeout 10 "$BIN" doctor 2>&1) || DOCTOR_OUTPUT=...`
#   relies on the OUTER `||` to tolerate failure -- but the `||` only
#   guards the PARENT assignment. The inner command failing (a warming
#   daemon, or -- on stock macOS -- `timeout` being absent => 127) fires
#   the inherited ERR trap FROM INSIDE the subshell, which emits
#   `gui_done fail` to the GUI before the parent's `||` runs. The install
#   then continues to completion, but the GUI has already latched "fail".
#
# WHY a naive test misses it: the subshell's `gui_done fail` writes to the
# subshell's stdout, which is captured into DOCTOR_OUTPUT -- NOT visible to
# the parent. So this test measures via a side-effect LEDGER FILE that
# survives the subshell, and asserts no fail marker was written.
#
# The fix: a gtimeout/timeout/else picker (so the probe actually runs on
# stock macOS) + suppressing the ERR trap for exactly the probe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${SCRIPT_DIR}/../install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[[ -f "$INSTALL_SH" ]] || { printf 'FAIL: install.sh not found\n' >&2; exit 1; }

# Extract the REAL _ostler_on_err function + ERR trap line (no copy-paste,
# so the test tracks the shipped trap).
TRAP_SRC=$(awk '
    /^_ostler_on_err\(\) \{/ { in_fn=1 }
    in_fn { print }
    in_fn && /^trap .*ERR$/ { exit }
' "$INSTALL_SH")
printf '%s\n' "$TRAP_SRC" | grep -q "trap '_ostler_on_err" \
    || { printf 'FAIL: could not extract _ostler_on_err + ERR trap\n' >&2; exit 1; }

# ── THE RED CONTROL NEEDS THE PRE-FIX HANDLER (#642, 2026-09-04) ──────
#
# The handler now refuses to emit a TERMINAL marker from a subshell:
#
#     if [[ "${BASH_SUBSHELL:-0}" -gt 0 ]]; then gui_log error ...; return; fi
#
# That is the same defect this file documents -- "`set -E` propagates that ERR
# trap INTO the $(...) subshell ... which emits `gui_done fail` to the GUI" --
# fixed one layer lower, at the handler instead of per-probe. Good news for the
# product, fatal for the RED control below: with the shipped handler the bug
# CANNOT be reproduced, so the control reported "did not reproduce the bug" and
# the whole file went red.
#
# Deleting the control would delete the only thing proving the ledger method
# can see the bug at all. So the RED arm gets a handler with that guard
# stripped, and the GREEN arm keeps the real one. RED then proves the ledger
# detects the historical defect; GREEN proves the shipped probe is clean.
# a752275d is the v1.0.66 cut -- the artefact that SHIPPED with this defect.
# Pinned to a fixed sha, never a branch: a control reading origin/main inverts
# the moment this fix merges. Same rationale as the 7b2130ac pin in
# tests/test_config_reader_absence_does_not_abort_the_install.sh.
#
# CI CLONES SHALLOW (111 of 124 workflows take the depth-1 default), so fetch
# the single object rather than demanding fetch-depth:0 everywhere. If it is
# STILL unreachable, mutate the live handler instead: the pre-fix handler is
# exactly the current one minus the guard, so it rebuilds with no network. An
# anti-vacuity limb that silently does not run is the hole it exists to close.
_PREFIX_SHA=a752275d
_PRE_SRC="pinned blob ${_PREFIX_SHA} (v1.0.66)"
_REPO_D="$(cd "$(dirname "$INSTALL_SH")" && pwd)"
if ! git -C "$_REPO_D" cat-file -e "${_PREFIX_SHA}:install.sh" 2>/dev/null; then
    git -C "$_REPO_D" fetch --quiet --depth=1 origin "${_PREFIX_SHA}" 2>/dev/null || true
fi
# TO A FILE FIRST, NEVER STRAIGHT INTO awk. This awk `exit`s the moment it
# sees the trap line, which closes the pipe and SIGPIPEs `git show`: under
# this file's `set -euo pipefail` the assignment then fails at 141 and `set
# -e` kills the script with NO OUTPUT AT ALL. I wrote it as a pipe and spent
# three runs on rc=141 before tracing it. The ORIGINAL extraction above reads
# a FILE for exactly this reason -- a file has no producer to signal.
_pre_blob="${WORK}/prefix_install.sh"
git -C "$_REPO_D" show "${_PREFIX_SHA}:install.sh" > "$_pre_blob" 2>/dev/null || : > "$_pre_blob"
TRAP_SRC_PREFIX=$(awk '
    /^_ostler_on_err\(\) \{/ { in_fn=1 }
    in_fn { print }
    in_fn && /^trap .*ERR$/ { exit }
' "$_pre_blob")
# `printf ... | grep -q` under `set -euo pipefail` is the short-circuiting
# consumer inversion: grep -q exits on first match and SIGPIPEs the producer,
# so the pipeline returns 141 and `set -e` kills the script. I wrote it that
# way here and it died rc=141 with no output. `grep -c` must read to EOF.
if [ "$(printf '%s\n' "$TRAP_SRC_PREFIX" | grep -c "trap '_ostler_on_err")" -eq 0 ]; then
    _PRE_SRC="mutation of the live handler (blob unreachable)"
    TRAP_SRC_PREFIX=$(printf '%s\n' "$TRAP_SRC" | awk '
        /BASH_SUBSHELL:-0/ { skip = 1 }
        skip && /^    fi$/ { skip = 0; next }
        !skip              { print }
    ')
fi
printf 'pre-fix trap source: %s\n' "$_PRE_SRC"
# THE INVARIANT, and it must hold whichever source produced it: the RED
# handler must carry the ERR trap and must NOT carry the guard. Otherwise RED
# silently runs the FIXED handler and its failure to reproduce reads as a
# broken host rather than a stripped guard. CANNOT-RUN, never a pass.
#
# NOT a line-count comparison. That was my first version and it is meaningless
# once the source can be a DIFFERENT REVISION -- the v1.0.66 handler is 66
# lines against today's 103, so "shorter" says nothing about the guard.
#
# `grep -c`, never `| grep -q`: under this file's `set -euo pipefail` the -q
# form exits on first match, SIGPIPEs the producer, and the pipeline returns
# 141. I wrote it that way and the script died rc=141 with NO OUTPUT AT ALL,
# which is a considerably worse failure than the one it was checking for.
# `|| true` because GREP -C EXITS 1 ON A ZERO COUNT while still printing 0,
# and under `set -e` that kills the assignment. A guard count of 0 is the
# EXPECTED, PASSING case here, so without this the success path aborts the
# script -- silently, since the trap output goes nowhere. This repo already
# carries tests/test_grep_c_arith_safety.sh for the same edge.
_pre_has_trap="$(printf '%s\n' "$TRAP_SRC_PREFIX" | grep -c "trap '_ostler_on_err" || true)"
_pre_has_guard="$(printf '%s\n' "$TRAP_SRC_PREFIX" | grep -c 'BASH_SUBSHELL:-0' || true)"
if [ "$_pre_has_trap" -eq 0 ] || [ "$_pre_has_guard" -gt 0 ]; then
    printf 'CANNOT-RUN: the pre-fix handler is not usable as a RED control.\n' >&2
    printf '            ERR-trap lines=%s (need >=1), guard lines=%s (need 0)\n' \
        "$_pre_has_trap" "$_pre_has_guard" >&2
    printf '            source was: %s\n' "$_PRE_SRC" >&2
    printf '            RED would run the FIXED handler and its silence would\n' >&2
    printf '            say nothing about the ledger method. Not a pass.\n' >&2
    exit 2
fi

# Extract the REAL (fixed) doctor-probe block.
PROBE_SRC=$(awk '
    /ostler-assistant doctor probe/ { in_block=1 }
    in_block && /Show recovery key/ { exit }
    in_block { print }
' "$INSTALL_SH")
[[ -n "$PROBE_SRC" ]] || { printf 'FAIL: could not extract doctor-probe block\n' >&2; exit 1; }

LEDGER="$WORK/fail_ledger"

# Prelude: stubs whose gui_done writes the DONE marker to the LEDGER FILE
# (survives the $(...) subshell, unlike stdout which the comsub captures).
write_prelude() {
    cat > "$1" <<PRELUDE
set -Eeuo pipefail
gui_log()  { :; }
info()     { printf 'INFO:%s\n' "\$*"; }
warn()     { printf 'WARN:%s\n' "\$*"; }
ok()       { printf 'OK:%s\n' "\$*"; }
# The observation point: a gui_done fail emitted from ANY context
# (including the comsub subshell) lands in the ledger file.
gui_done() { printf 'DONE:%s\n' "\$1" >> "$LEDGER"; OSTLER_DONE_EMITTED=1; }
OSTLER_DONE_EMITTED=""
OSTLER_LAST_ERROR_CODE=""
__OSTLER_STEP_ID="health_check"
MSG_INFO_LAUNCH_VERIFY_CRON_DELIVERY_IMESSAGE_TCC="launch-verify"
MSG_INFO_OSTLER_ASSISTANT_BINARY_NOT_INSTALLED_SKIPPING="not-installed"
MSG_INFO_OSTLER_ASSISTANT_DOCTOR_DEFERRED_DAEMON_MAY="doctor-deferred"
MSG_INFO_STARTING_RUN_OSTLER_ASSISTANT_DOCTOR_AFTER="run-after"
MSG_OK_OSTLER_ASSISTANT_DOCTOR_NO_ERRORS_DETECTED="no-errors"
MSG_WARN_EARLY_MARKERS_CHANNELS_STILL_CONNECTING_APPLE="early-markers"
MSG_WARN_EVENTS_PERMISSION_MESSAGES_APP="events-permission"
MSG_WARN_OSTLER_ASSISTANT_DOCTOR_REPORTED_ERROR_S="reported-errors"
MSG_WARN_RUN_DOCTOR_AFTER_FIRST_LAUNCH="run-doctor"
MSG_WARN_TO_INSPECT_CRON_DELIVERY_IMESSAGE_TCC="to-inspect"
PRELUDE
}

# PATH that has grep/printf (/usr/bin,/bin) but NOT brew's gtimeout/timeout
# -- deterministically reproducing the stock-macOS "no timeout" condition
# regardless of whether the test host has coreutils installed.
NO_TIMEOUT_PATH="/usr/bin:/bin"

# A stub daemon binary: prints to stdout and exits with the code we pass.
make_stub() {
    cat > "$WORK/doctor_stub" <<STUB
#!/usr/bin/env bash
echo "warming up, channels still connecting"
exit ${1:-1}
STUB
    chmod +x "$WORK/doctor_stub"
}

# ── RED proof: the PRE-FIX bare probe DOES fire the subshell trap ──────
# Confirms the ledger method actually detects the bug. Uses the bare
# `timeout 10 ...` shape that shipped before #640, with timeout absent.
make_stub 1
: > "$LEDGER"
write_prelude "$WORK/red.sh"
printf '%s\n' "$TRAP_SRC_PREFIX" >> "$WORK/red.sh"
cat >> "$WORK/red.sh" <<RED
ASSISTANT_BINARY="$WORK/doctor_stub"
if [[ -x "\${ASSISTANT_BINARY:-}" ]]; then
    DOCTOR_OUTPUT=\$(timeout 10 "\${ASSISTANT_BINARY}" doctor 2>&1) || DOCTOR_OUTPUT="__DOCTOR_INVOCATION_FAILED__"
fi
printf 'REACHED_END\n'
RED
PATH="$NO_TIMEOUT_PATH" bash "$WORK/red.sh" >/dev/null 2>&1 || true
if ! grep -q '^DONE:fail' "$LEDGER" 2>/dev/null; then
    printf 'FAIL: RED control did not reproduce the bug -- test cannot detect regressions on this host\n' >&2
    exit 1
fi
printf 'PASS[red-control]: pre-fix bare probe fires gui_done fail from the subshell (bug reproduced)\n'

# ── GREEN: the REAL fixed block from install.sh ───────────────────────
run_fixed() {
    local exitcode="$1"
    make_stub "$exitcode"
    : > "$LEDGER"
    write_prelude "$WORK/green.sh"
    printf '%s\n' "$TRAP_SRC"  >> "$WORK/green.sh"
    printf 'ASSISTANT_BINARY=%q\n' "$WORK/doctor_stub" >> "$WORK/green.sh"
    printf '%s\n' "$PROBE_SRC" >> "$WORK/green.sh"
    printf "printf 'REACHED_END\\\\n'\n" >> "$WORK/green.sh"
    PATH="$NO_TIMEOUT_PATH" bash "$WORK/green.sh" 2>&1
}

OUT=$(run_fixed 1)
if grep -q '^DONE:fail' "$LEDGER" 2>/dev/null; then
    printf 'FAIL[warming-daemon]: fixed probe still emitted gui_done fail\n' >&2
    cat "$LEDGER" >&2; exit 1
fi
printf '%s\n' "$OUT" | grep -q '^REACHED_END$' \
    || { printf 'FAIL[warming-daemon]: probe aborted before completing\n%s\n' "$OUT" >&2; exit 1; }
printf '%s\n' "$OUT" | grep -q 'INFO:doctor-deferred' \
    || { printf 'FAIL[warming-daemon]: deferred info did not print\n%s\n' "$OUT" >&2; exit 1; }
printf 'PASS[warming-daemon]: no false fail; deferred path printed\n'

# ── GREEN: success path still reports OK ──────────────────────────────
OUT=$(run_fixed 0)
if grep -q '^DONE:fail' "$LEDGER" 2>/dev/null; then
    printf 'FAIL[healthy]: clean doctor run emitted gui_done fail\n' >&2; cat "$LEDGER" >&2; exit 1
fi
printf '%s\n' "$OUT" | grep -q 'OK:no-errors' \
    || { printf 'FAIL[healthy]: clean run did not report the no-errors OK\n%s\n' "$OUT" >&2; exit 1; }
printf 'PASS[healthy]: clean doctor run reports OK, no false fail\n'

printf '\nAll #640 doctor-probe ERR-trap regression assertions passed\n'
