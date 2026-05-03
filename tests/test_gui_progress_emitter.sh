#!/usr/bin/env bash
#
# tests/test_gui_progress_emitter.sh
#
# Verifies the lib/progress_emitter.sh helper:
#   1. silently no-ops when OSTLER_GUI is unset (curl|bash parity)
#   2. emits well-formed #OSTLER tab-separated markers when set
#   3. gui_read reads from OSTLER_GUI_FD when set
#   4. gui_read falls back to plain `read` when unset
#   5. gui_emit values are tab/newline-stripped (no marker spillage)
#
# Pure bash + standard tools.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${REPO_ROOT}/lib/progress_emitter.sh"

if [[ ! -f "$LIB" ]]; then
    echo "FAIL: lib/progress_emitter.sh not found at $LIB" >&2
    exit 1
fi

# ── Test 1: helpers no-op when OSTLER_GUI is unset ───────────────
unset OSTLER_GUI 2>/dev/null || true
out="$(bash -c "source '$LIB'; gui_emit STEP_BEGIN id=foo title=bar; gui_log info 'hello'; gui_warn 'oops'; gui_phase 1 'Phase one'; gui_done ok")"
if [[ -n "$out" ]]; then
    echo "FAIL [no-op]: helpers produced output when OSTLER_GUI is unset:" >&2
    echo "$out" >&2
    exit 1
fi
echo "PASS: helpers no-op when OSTLER_GUI is unset"

# ── Test 2: emit produces well-formed markers when OSTLER_GUI=1 ──
out="$(OSTLER_GUI=1 bash -c "source '$LIB'; gui_emit STEP_BEGIN 'id=fda_extract' 'title=Extract' 'phase=3' 'idx=7' 'total=11'")"
if ! grep -q $'^#OSTLER\tSTEP_BEGIN\tid=fda_extract\ttitle=Extract\tphase=3\tidx=7\ttotal=11$' <<<"$out"; then
    echo "FAIL [emit]: marker shape mismatch" >&2
    echo "  got: $out" >&2
    exit 1
fi
echo "PASS: emit produces well-formed tab-separated markers"

# ── Test 3: step bookkeeping emits BEGIN+END pair with elapsed ──
out="$(OSTLER_GUI=1 bash -c "source '$LIB'; gui_step_begin foo 'Title bar' 3 1 2; sleep 1; gui_step_end ok")"
if ! grep -q $'^#OSTLER\tSTEP_BEGIN\tid=foo\ttitle=Title bar\tphase=3\tidx=1\ttotal=2$' <<<"$out"; then
    echo "FAIL [step]: STEP_BEGIN missing or malformed" >&2
    echo "  got: $out" >&2
    exit 1
fi
if ! grep -qE $'^#OSTLER\tSTEP_END\tid=foo\tstatus=ok\telapsed_s=[0-9]+$' <<<"$out"; then
    echo "FAIL [step]: STEP_END missing elapsed_s" >&2
    echo "  got: $out" >&2
    exit 1
fi
echo "PASS: gui_step_begin / gui_step_end emit correctly"

# ── Test 4: gui_read TTY fallback returns the typed answer ──────
# Pipe a string in via a here-string. read inside gui_read picks it up.
unset OSTLER_GUI 2>/dev/null || true
unset OSTLER_GUI_FD 2>/dev/null || true
ans="$(bash -c "source '$LIB'; gui_read 'Your name' text 'Default'" <<<"Alex")"
if [[ "$ans" != "Alex" ]]; then
    echo "FAIL [tty-read]: expected 'Alex', got '$ans'" >&2
    exit 1
fi
# Empty answer + default value should yield default.
ans="$(bash -c "source '$LIB'; gui_read 'Your name' text 'Default'" <<<"")"
if [[ "$ans" != "Default" ]]; then
    echo "FAIL [tty-read-default]: expected 'Default', got '$ans'" >&2
    exit 1
fi
echo "PASS: gui_read TTY fallback works"

# ── Test 5: gui_read in GUI mode reads from OSTLER_GUI_FD ──────
# We create a pipe, set OSTLER_GUI_FD to its read end, write the
# answer to its write end, and call gui_read.
TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT
PIPE="${TMPDIR_T}/p"
mkfifo "$PIPE"

# We open the fifo's write end in the parent, the gui_read reads
# from a different fd attached to the same fifo. Use 'exec' to
# bind explicit fds.
(
    set -e
    exec 7<>"$PIPE"
    # Send the answer first, then have gui_read consume it.
    printf 'GuiAnswer\n' >&7
    OSTLER_GUI=1 OSTLER_GUI_FD=7 bash -c "source '$LIB'; gui_read 'X' text '' '' '' 'tid'" > "${TMPDIR_T}/out" 2>"${TMPDIR_T}/err"
)
got="$(cat "${TMPDIR_T}/out")"
if [[ "$got" != *"GuiAnswer"* ]]; then
    echo "FAIL [gui-read]: expected 'GuiAnswer' in stdout, got '$got'" >&2
    cat "${TMPDIR_T}/err" >&2 || true
    exit 1
fi
# stderr should also contain the PROMPT marker.
if ! grep -q $'^#OSTLER\tPROMPT\t' "${TMPDIR_T}/out"; then
    # In GUI mode, gui_read emits the marker on stdout too. But the
    # final answer is the last printf; both interleave. Validate the
    # marker is present *somewhere* in the captured output.
    if ! grep -q $'#OSTLER\tPROMPT\t' "${TMPDIR_T}/out"; then
        echo "FAIL [gui-read]: PROMPT marker missing from output" >&2
        cat "${TMPDIR_T}/out" >&2
        exit 1
    fi
fi
echo "PASS: gui_read reads from OSTLER_GUI_FD when GUI mode is active"

# ── Test 6: gui_emit strips tab/newline from values ─────────────
out="$(OSTLER_GUI=1 bash -c "source '$LIB'; gui_emit LOG 'level=info' 'msg=line1
line2	with	tabs'")"
# Should not contain literal newline or tab in the msg= field (tabs
# would break the marker shape; newlines would split the line).
# Re-extract everything after the LOG marker:
msg_field="$(grep '^#OSTLER' <<<"$out" | head -1)"
if [[ "$msg_field" == *$'\n'* ]]; then
    echo "FAIL [strip]: marker contains a newline" >&2
    exit 1
fi
# Tabs split fields – count them. STEP_BEGIN with k=v args = 2 + nargs tabs.
# Here: "#OSTLER<TAB>LOG<TAB>level=info<TAB>msg=..."
nfields="$(awk -F'\t' '{print NF}' <<<"$msg_field")"
if [[ "$nfields" != "4" ]]; then
    echo "FAIL [strip]: expected 4 tab-separated fields, got $nfields ($msg_field)" >&2
    exit 1
fi
echo "PASS: gui_emit strips tab/newline from values"

# ── Test 7: install.sh sources lib/progress_emitter.sh ──────────
if ! grep -q 'lib/progress_emitter.sh' "${REPO_ROOT}/install.sh"; then
    echo "FAIL [wiring]: install.sh does not reference lib/progress_emitter.sh" >&2
    exit 1
fi
echo "PASS: install.sh wires up lib/progress_emitter.sh"

# ── Test 8: install.sh stub fallback covers the no-op helpers ───
# The early-stub block (defined before SCRIPT_DIR resolution) keeps
# any `info`/`warn`/`err` call that fires before lib sourcing safe.
# gui_read isn't a true no-op (it must always return a value), so
# it lives in the lib + the missing-lib `else` branch only.
for helper in gui_emit gui_step_begin gui_step_end gui_log gui_warn gui_phase gui_done gui_active gui_needs_sudo gui_needs_fda; do
    if ! grep -q "^${helper}()" "${REPO_ROOT}/install.sh"; then
        echo "FAIL [stub]: install.sh missing inline stub for $helper" >&2
        exit 1
    fi
done
# gui_read must be defined either by the sourced lib OR by the
# missing-lib else-branch. Confirm the fallback function body is
# present in install.sh.
if ! grep -qE '^[[:space:]]+gui_read\(\)' "${REPO_ROOT}/install.sh"; then
    echo "FAIL [stub]: install.sh missing inline gui_read fallback in else branch" >&2
    exit 1
fi
echo "PASS: install.sh declares inline stubs for every GUI helper"

echo ""
echo "All gui_progress_emitter tests passed."
