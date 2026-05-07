#!/usr/bin/env bash
#
# tests/test_imessage_tcc_posture.sh
#
# Locks the iMessage TCC posture wiring in Phase 3.18 of install.sh.
#
# Why this test exists:
#
#   macOS Sequoia tightened TCC so that even with Full Disk Access
#   granted, osascript-based iMessage delivery can fail with error
#   -1743 (errAEEventNotPermitted) when AppleEvents permission for
#   Messages.app has not been granted. Customers see broken delivery
#   with no surface explanation.
#
#   Phase 3.18 runs a READ-ONLY probe at install time, classifies
#   the outcome into three buckets (granted-and-working / tcc-denied
#   / check-failed), writes a posture marker at
#   ~/.ostler/imessage-posture/state.md, and (when not
#   granted-and-working) appends a remediation banner to the next-
#   steps section pointing at System Settings > Privacy & Security
#   > Automation.
#
#   This is the install-time SNAPSHOT only; ostler-assistant has
#   its own iMessage TCC probe at daemon startup that tracks
#   ongoing health. The two markers coexist because they describe
#   different facts (install-time outcome vs runtime health).
#
#   This test pins the wiring so a future edit cannot quietly
#   regress any of:
#     1. PWG_IMESSAGE_PROBE_OUTCOME documented in --help.
#     2. Phase 3.18 gated on CHANNEL_IMESSAGE_ENABLED.
#     3. Probe shape: osascript "count of accounts" (NOT
#        "count chats" -- mirrors the daemon for consistency).
#     4. Probe is read-only (no `tell ... to send`).
#     5. Three-bucket classification (granted-and-working /
#        tcc-denied / check-failed) via stderr regex on
#        -1743 / not authorized / errAEEventNotPermitted.
#     6. Marker path: ~/.ostler/imessage-posture/state.md.
#     7. Marker frontmatter declares install-time-snapshot
#        framing + cross-reference to daemon's runtime probe.
#     8. Marker chmod 600.
#     9. Banner conditional gate (silent on granted-and-working,
#        surfaces remediation otherwise).
#    10. Banner copy points at Privacy & Security > Automation,
#        NOT Full Disk Access (-1743 is an Automation issue).
#
# Sister tests:
#   - test_browser_extensions.sh      -- Phase 3.17 wiring
#   - test_total_steps_dynamic.sh     -- progress bar contract
#   - test_doctor_probe_non_fatal.sh  -- daemon doctor wrapper

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

# ── --help documents the test-shim env var ──────────────────────
if ! grep -q '"  PWG_IMESSAGE_PROBE_OUTCOME"' "$INSTALL_SCRIPT"; then
    echo "FAIL [help-missing]: PWG_IMESSAGE_PROBE_OUTCOME is not documented in --help" >&2
    exit 1
fi
echo "PASS: PWG_IMESSAGE_PROBE_OUTCOME documented in --help"

# ── Phase 3.18 exists with the right header ─────────────────────
if ! grep -q '^# ── 3.18 iMessage TCC posture probe' "$INSTALL_SCRIPT"; then
    echo "FAIL [phase-header]: '# ── 3.18 iMessage TCC posture probe' not found" >&2
    exit 1
fi
echo "PASS: Phase 3.18 header present"

# ── Gated on CHANNEL_IMESSAGE_ENABLED ───────────────────────────
if ! grep -qE 'if \[\[ "\$\{CHANNEL_IMESSAGE_ENABLED:-false\}" == "true" \]\]; then' "$INSTALL_SCRIPT"; then
    echo "FAIL [gate]: probe block not gated on CHANNEL_IMESSAGE_ENABLED" >&2
    exit 1
fi
echo "PASS: probe gated on CHANNEL_IMESSAGE_ENABLED"

# ── Probe shape: count of accounts (mirrors daemon) ─────────────
if ! grep -q "tell application \"Messages\" to count of accounts" "$INSTALL_SCRIPT"; then
    echo "FAIL [probe-shape]: probe does not use 'count of accounts' (mirroring daemon)" >&2
    exit 1
fi
echo "PASS: probe uses 'count of accounts' (matches daemon imessage_tcc.rs)"

# ── Probe is READ-ONLY (no send) ────────────────────────────────
# Search for any `to send` AppleScript call against Messages in
# the probe block; the brief explicitly forbids sending a test
# message during install.
if grep -nE 'tell application "Messages" to send' "$INSTALL_SCRIPT" >/dev/null 2>&1; then
    echo "FAIL [probe-send]: install.sh sends an iMessage during install (forbidden)" >&2
    exit 1
fi
echo "PASS: probe is read-only (no 'tell Messages to send')"

# ── Stderr regex matches all three -1743 dialects ───────────────
if ! grep -q "grep -qE '\\\\-1743|not authorized|errAEEventNotPermitted'" "$INSTALL_SCRIPT"; then
    echo "FAIL [regex]: stderr regex does not match -1743 / not authorized / errAEEventNotPermitted" >&2
    exit 1
fi
echo "PASS: stderr regex covers -1743 / not authorized / errAEEventNotPermitted"

# ── Three-bucket classification ─────────────────────────────────
for bucket in granted-and-working tcc-denied check-failed; do
    if ! grep -q "IMESSAGE_TCC_STATUS=\"$bucket\"" "$INSTALL_SCRIPT"; then
        echo "FAIL [bucket-$bucket]: status bucket '$bucket' not assigned anywhere" >&2
        exit 1
    fi
done
echo "PASS: three status buckets present (granted-and-working / tcc-denied / check-failed)"

# ── Marker path ──────────────────────────────────────────────────
if ! grep -q 'IMESSAGE_POSTURE_DIR="\${OSTLER_DIR}/imessage-posture"' "$INSTALL_SCRIPT"; then
    echo "FAIL [marker-path]: marker dir is not \${OSTLER_DIR}/imessage-posture" >&2
    exit 1
fi
if ! grep -q 'IMESSAGE_POSTURE_FILE="\${IMESSAGE_POSTURE_DIR}/state.md"' "$INSTALL_SCRIPT"; then
    echo "FAIL [marker-file]: marker file is not state.md" >&2
    exit 1
fi
echo "PASS: marker path is \${OSTLER_DIR}/imessage-posture/state.md"

# ── Marker frontmatter declares install-time-snapshot framing ───
if ! grep -q '"# iMessage TCC posture (install-time snapshot)"' "$INSTALL_SCRIPT"; then
    echo "FAIL [marker-frontmatter]: marker title does not declare install-time-snapshot framing" >&2
    exit 1
fi
if ! grep -q '"Source: install.sh probe at install time"' "$INSTALL_SCRIPT"; then
    echo "FAIL [marker-source]: marker does not declare 'Source: install.sh probe at install time'" >&2
    exit 1
fi
if ! grep -q "Runtime health is tracked separately by ostler-assistant" "$INSTALL_SCRIPT"; then
    echo "FAIL [marker-cross-ref]: marker does not cross-reference daemon's runtime probe" >&2
    exit 1
fi
echo "PASS: marker frontmatter declares install-time-snapshot framing + cross-refs daemon"

# ── chmod 600 on the marker ─────────────────────────────────────
if ! grep -q 'chmod 600 "\$IMESSAGE_POSTURE_FILE"' "$INSTALL_SCRIPT"; then
    echo "FAIL [marker-perms]: marker not chmod 600" >&2
    exit 1
fi
echo "PASS: marker is chmod 600"

# ── Banner conditional gate ─────────────────────────────────────
# Silent on granted-and-working (no banner). Surfaces when not.
# Test: the banner block must reference IMESSAGE_TCC_STATUS and
# explicitly check it != granted-and-working.
if ! grep -qE '"\$\{IMESSAGE_TCC_STATUS\}" != "granted-and-working"' "$INSTALL_SCRIPT"; then
    echo "FAIL [banner-gate]: banner not gated on status != granted-and-working" >&2
    exit 1
fi
echo "PASS: banner gated on IMESSAGE_TCC_STATUS != granted-and-working (silent on success)"

# ── Banner copy points at Automation, NOT FDA ───────────────────
# -1743 is an AppleEvents/Automation TCC error, not Full Disk
# Access. The banner must walk the customer to the right pane.
if ! grep -q "Privacy & Security > Automation" "$INSTALL_SCRIPT"; then
    echo "FAIL [banner-pane]: banner does not point at 'Privacy & Security > Automation'" >&2
    exit 1
fi
# Negative: the banner copy block (between the conditional and the
# next echo "") must NOT direct the user to FDA for the -1743
# remediation. Grep for the iMessage banner block specifically.
BANNER_BLOCK=$(awk '/iMessage delivery posture: NOT YET CONFIRMED/,/^fi$/' "$INSTALL_SCRIPT")
if printf '%s\n' "$BANNER_BLOCK" | grep -q "Full Disk Access"; then
    echo "FAIL [banner-fda-mismatch]: -1743 remediation incorrectly points at FDA (should be Automation)" >&2
    exit 1
fi
echo "PASS: banner points at Privacy & Security > Automation (not FDA)"

# ── Test-shim env var: PWG_IMESSAGE_PROBE_OUTCOME ───────────────
if ! grep -q 'PWG_IMESSAGE_PROBE_OUTCOME:-' "$INSTALL_SCRIPT"; then
    echo "FAIL [shim-var]: test-shim env var PWG_IMESSAGE_PROBE_OUTCOME not wired" >&2
    exit 1
fi
echo "PASS: test-shim env var PWG_IMESSAGE_PROBE_OUTCOME present"

# ── End-to-end shim test: each value produces a coherent marker ─
# We extract the probe block (sed range from the Phase 3.18 header
# to the closing `fi` before the doctor wrapper comment) and
# eval it under each shim value with a sandboxed OSTLER_DIR. This
# exercises the actual marker-writing code, not just its grep
# silhouette.
SHIM_TMPDIR=$(mktemp -d)
trap 'rm -rf "$SHIM_TMPDIR"' EXIT

PROBE_BLOCK="$SHIM_TMPDIR/probe.sh"
awk '
/^# ── 3.18 iMessage TCC posture probe/ {capture=1}
capture {print}
capture && /^# ── ostler-assistant doctor probe/ {exit}
' "$INSTALL_SCRIPT" | sed '$d' > "$PROBE_BLOCK"

# Stub `info`, `ok`, `warn` so the block runs without depending
# on install.sh's helpers being defined.
PROBE_RUNNER="$SHIM_TMPDIR/runner.sh"
cat > "$PROBE_RUNNER" <<'RUNNEREOF'
#!/usr/bin/env bash
set -euo pipefail
info() { :; }
ok()   { :; }
warn() { :; }
CHANNEL_IMESSAGE_ENABLED=true
OSTLER_DIR="$1"
PWG_IMESSAGE_PROBE_OUTCOME="$2"
source "$3"
RUNNEREOF
chmod +x "$PROBE_RUNNER"

for outcome in granted-and-working tcc-denied check-failed; do
    SHIM_OSTLER="$SHIM_TMPDIR/ostler-$outcome"
    mkdir -p "$SHIM_OSTLER"
    if ! "$PROBE_RUNNER" "$SHIM_OSTLER" "$outcome" "$PROBE_BLOCK"; then
        echo "FAIL [shim-run-$outcome]: probe block exited non-zero under shim '$outcome'" >&2
        exit 1
    fi
    MARKER="$SHIM_OSTLER/imessage-posture/state.md"
    if [[ ! -f "$MARKER" ]]; then
        echo "FAIL [shim-marker-$outcome]: marker not written for shim '$outcome'" >&2
        exit 1
    fi
    if ! grep -q "Status: $outcome" "$MARKER"; then
        echo "FAIL [shim-status-$outcome]: marker did not record 'Status: $outcome'" >&2
        cat "$MARKER" >&2
        exit 1
    fi
    if ! grep -q "install-time snapshot" "$MARKER"; then
        echo "FAIL [shim-frontmatter-$outcome]: marker missing install-time-snapshot framing" >&2
        exit 1
    fi
    PERMS=$(stat -f '%Lp' "$MARKER" 2>/dev/null || stat -c '%a' "$MARKER" 2>/dev/null)
    if [[ "$PERMS" != "600" ]]; then
        echo "FAIL [shim-perms-$outcome]: marker permissions are '$PERMS', expected 600" >&2
        exit 1
    fi
    echo "PASS: shim '$outcome' produced coherent marker at $MARKER"
done

# ── Re-run shim test: timestamp updates on second invocation ────
SECOND_OSTLER="$SHIM_TMPDIR/ostler-rerun"
mkdir -p "$SECOND_OSTLER"
"$PROBE_RUNNER" "$SECOND_OSTLER" "granted-and-working" "$PROBE_BLOCK"
TS1=$(grep '^Captured at:' "$SECOND_OSTLER/imessage-posture/state.md")
sleep 1.1
"$PROBE_RUNNER" "$SECOND_OSTLER" "granted-and-working" "$PROBE_BLOCK"
TS2=$(grep '^Captured at:' "$SECOND_OSTLER/imessage-posture/state.md")
if [[ "$TS1" == "$TS2" ]]; then
    echo "FAIL [shim-rerun]: re-running probe did not update 'Captured at' timestamp" >&2
    echo "  first:  $TS1" >&2
    echo "  second: $TS2" >&2
    exit 1
fi
echo "PASS: re-running probe updates 'Captured at' timestamp"

echo ""
echo "ALL IMESSAGE TCC POSTURE TESTS PASSED"
