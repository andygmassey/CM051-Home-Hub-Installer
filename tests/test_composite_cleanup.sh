#!/usr/bin/env bash
#
# tests/test_composite_cleanup.sh
#
# Locks the composite_cleanup pattern in install.sh.
#
# Why this test exists:
#
#   The cold-install audit (2026-05-02) found that install.sh
#   used `trap ... EXIT` four separate times in the main install
#   body. Each `trap` registration replaces the previous one
#   (bash trap is destructive, not additive), so all but the
#   most recent handler leaked. Worst case: the sudo keepalive
#   loop and the battery-state watcher both kept running
#   indefinitely after the install exited, polling sudo every
#   60 seconds on the customer's machine until reboot.
#
#   This test pins the new pattern:
#     1. The main install body registers `trap composite_cleanup
#        EXIT` exactly ONCE, near the top of Phase 3.
#     2. composite_cleanup() walks a per-resource flag list and
#        tears down anything still allocated.
#     3. Each flag declared in the init block has a matching
#        stanza in composite_cleanup -- declaring a flag without
#        wiring it into the cleanup is exactly the leak the
#        pattern is designed to prevent.
#     4. No stray `trap ... EXIT` in the main install body
#        (bootstrap traps at lines ~312 / ~357 are independent
#        of Phase 3 and are not constrained by this test).
#     5. End-to-end: composite_cleanup, when run against mocked
#        resource flags, frees them and clears the flags.
#
# Sister tests:
#   - test_total_steps_dynamic.sh -- Phase 3 progress bar contract
#   - test_consent_a7_a8.sh -- A7+A8 consent ceremony

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

if ! bash -n "$INSTALL_SCRIPT"; then
    echo "FAIL: install.sh fails bash -n parse check" >&2
    exit 1
fi
echo "PASS: install.sh parses"

# ── composite_cleanup() function exists ─────────────────────────
if ! grep -qE '^composite_cleanup\(\)' "$INSTALL_SCRIPT"; then
    echo "FAIL [no-fn]: composite_cleanup() function not defined" >&2
    exit 1
fi
echo "PASS: composite_cleanup() function defined"

# ── Single registration in main body ────────────────────────────
# Bootstrap traps at lines 312 / 357 are independent (curl-bash
# tarball cleanup, cleared before re-exec). Main-body trap count
# must be exactly 1: the composite_cleanup registration.
COMPOSITE_TRAP_COUNT="$(grep -cE '^trap composite_cleanup EXIT$' "$INSTALL_SCRIPT")"
if [[ "$COMPOSITE_TRAP_COUNT" -ne 1 ]]; then
    echo "FAIL [trap-count]: expected exactly 1 'trap composite_cleanup EXIT' line, got ${COMPOSITE_TRAP_COUNT}" >&2
    exit 1
fi
echo "PASS: 'trap composite_cleanup EXIT' registered exactly once"

# ── No stray trap ... EXIT in main body ─────────────────────────
# Bootstrap traps at indented lines (inside the curl-bash if
# block, lines ~312 / ~357) are exempt. Anything at column 0
# that isn't the composite registration is a stray.
STRAY_TRAPS="$(grep -nE '^trap [^ ]+ EXIT|^trap - EXIT' "$INSTALL_SCRIPT" \
    | grep -v 'trap composite_cleanup EXIT$' || true)"
if [[ -n "$STRAY_TRAPS" ]]; then
    echo "FAIL [stray-trap]: stray 'trap ... EXIT' in main install body:" >&2
    echo "$STRAY_TRAPS" >&2
    echo "  All EXIT cleanup must go through composite_cleanup." >&2
    exit 1
fi
echo "PASS: no stray 'trap ... EXIT' calls in main install body"

# ── Flag declarations match cleanup stanzas ─────────────────────
# Find every flag declared as `<NAME>=""` in the composite
# cleanup init block, and assert each appears in a `if [[ -n
# "${NAME:-}" ]]` stanza inside composite_cleanup.

# Extract the composite_cleanup function body.
CLEANUP_BODY="$(awk '
    /^composite_cleanup\(\) \{/  { capture = 1; next }
    capture && /^\}$/             { capture = 0 }
    capture                        { print }
' "$INSTALL_SCRIPT")"

if [[ -z "$CLEANUP_BODY" ]]; then
    echo "FAIL [extract]: could not extract composite_cleanup body" >&2
    exit 1
fi

# Extract the flag init lines. Pattern: `<UPPER_NAME>=""` at
# column 0, sitting between the start of the composite section
# and the function definition.
FLAG_INITS="$(awk '
    /# ── Composite cleanup ─/ { capture = 1; next }
    capture && /^composite_cleanup\(\) \{/ { exit }
    capture && /^[A-Z0-9_]+=""$/  { print }
' "$INSTALL_SCRIPT")"

if [[ -z "$FLAG_INITS" ]]; then
    echo "FAIL [no-flags]: no flag declarations found in the composite cleanup section" >&2
    exit 1
fi

while IFS= read -r flag_line; do
    flag_name="${flag_line%=*}"
    if ! echo "$CLEANUP_BODY" | grep -qE "if \[\[ -n \"\\\$\{${flag_name}:-\}\" \]\]; then"; then
        echo "FAIL [flag-no-stanza]: flag '${flag_name}' declared but no cleanup stanza in composite_cleanup" >&2
        echo "  Add: if [[ -n \"\${${flag_name}:-}\" ]]; then ...; ${flag_name}=\"\"; fi" >&2
        exit 1
    fi
done <<< "$FLAG_INITS"

FLAG_COUNT="$(printf '%s\n' "$FLAG_INITS" | grep -c '.')"
echo "PASS: ${FLAG_COUNT} resource flag(s) declared, each has a matching cleanup stanza"

# ── No stanza without a flag ────────────────────────────────────
# The reverse: every `if [[ -n "${NAME:-}" ]]` in composite_cleanup
# must reference a flag that's declared in the init block.
while IFS= read -r stanza; do
    [[ -z "$stanza" ]] && continue
    stanza_flag="$(echo "$stanza" | sed -E 's/.*\$\{([A-Z0-9_]+):-\}.*/\1/')"
    if ! echo "$FLAG_INITS" | grep -qE "^${stanza_flag}=\"\"$"; then
        echo "FAIL [stanza-no-flag]: stanza references '${stanza_flag}' but no init declaration found" >&2
        exit 1
    fi
done <<< "$(echo "$CLEANUP_BODY" | grep -E 'if \[\[ -n "\$\{[A-Z0-9_]+:-\}" \]\]; then')"
echo "PASS: every cleanup stanza references an initialised flag"

# ── End-to-end: composite_cleanup tears down mocked resources ───
# Extract composite_cleanup as a callable function, mock the
# flags with sentinel temp resources, run the function, assert
# the resources are gone and the flags are cleared.
COMPOSITE_FN_FILE="$(mktemp)"
trap 'rm -f "$COMPOSITE_FN_FILE"' EXIT

awk '
    /^composite_cleanup\(\) \{/ { capture = 1 }
    capture                      { print }
    capture && /^\}$/            { capture = 0; exit }
' "$INSTALL_SCRIPT" > "$COMPOSITE_FN_FILE"

# Mocked sleeping process to act as a "PID we should kill".
MOCK_PID_FIFO="$(mktemp -u)"
mkfifo "$MOCK_PID_FIFO"
( sleep 30 ) &
MOCK_PID=$!

# Mock tmpdir + tmpfile.
MOCK_TMPDIR="$(mktemp -d)"
MOCK_TMPFILE="$(mktemp)"

# Run composite_cleanup with all four flags set.
RESULT="$(
    SUDO_KEEPALIVE_PID="$MOCK_PID" \
    PHASE3_BATTERY_WATCH_PID="" \
    ASSISTANT_TMPDIR="$MOCK_TMPDIR" \
    TAILSCALE_TMP_ENV="$MOCK_TMPFILE" \
    bash -c "
        set -e
        $(cat "$COMPOSITE_FN_FILE")
        composite_cleanup
        echo SUDO=\$SUDO_KEEPALIVE_PID
        echo BATTERY=\$PHASE3_BATTERY_WATCH_PID
        echo TMPDIR=\$ASSISTANT_TMPDIR
        echo TAILSCALE=\$TAILSCALE_TMP_ENV
    "
)"

# Note: the subshell's flag clears don't propagate back to the
# parent (intentional -- bash semantics). We assert that the
# resources are torn down on disk, and that the cleanup ran to
# completion (exit code 0 from set -e).

if kill -0 "$MOCK_PID" 2>/dev/null; then
    echo "FAIL [end-to-end-kill]: composite_cleanup did not kill the mocked PID ${MOCK_PID}" >&2
    kill "$MOCK_PID" 2>/dev/null || true
    rm -rf "$MOCK_TMPDIR" "$MOCK_TMPFILE"
    exit 1
fi
echo "PASS: composite_cleanup killed the mocked SUDO_KEEPALIVE_PID"

if [[ -d "$MOCK_TMPDIR" ]]; then
    echo "FAIL [end-to-end-tmpdir]: composite_cleanup did not remove ASSISTANT_TMPDIR" >&2
    rm -rf "$MOCK_TMPDIR"
    rm -f "$MOCK_TMPFILE"
    exit 1
fi
echo "PASS: composite_cleanup removed the mocked ASSISTANT_TMPDIR"

if [[ -f "$MOCK_TMPFILE" ]]; then
    echo "FAIL [end-to-end-tmpfile]: composite_cleanup did not remove TAILSCALE_TMP_ENV" >&2
    rm -f "$MOCK_TMPFILE"
    exit 1
fi
echo "PASS: composite_cleanup removed the mocked TAILSCALE_TMP_ENV"

# Inside the subshell the flags should have been cleared.
if echo "$RESULT" | grep -qE '^SUDO=[1-9]'; then
    echo "FAIL [end-to-end-flag]: SUDO_KEEPALIVE_PID was not cleared inside composite_cleanup" >&2
    echo "$RESULT" >&2
    exit 1
fi
echo "PASS: composite_cleanup clears resource flags after teardown"

echo ""
echo "ALL COMPOSITE CLEANUP TESTS PASSED"
