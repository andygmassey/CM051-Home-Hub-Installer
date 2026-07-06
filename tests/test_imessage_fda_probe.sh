#!/usr/bin/env bash
#
# tests/test_imessage_fda_probe.sh
#
# Locks the contract between install.sh's CX-60 iMessage FDA probe
# and:
#   1. The Doctor rule check_imessage_fda (vendor/doctor/agent/
#      diagnostic_rules.py).
#   2. The writer at lib/write_pipeline_signals.py.
#   3. The customer-string catalogue at install.sh.strings.en-GB.sh.
#
# The probe is best-effort (must NOT kill the install). The Doctor
# rule must:
#   - Stay quiet when the install never wrote the flag (legacy).
#   - Stay quiet when the install wrote needed=false.
#   - Render the card when the install wrote needed=true AND a live
#     chat.db re-probe fails.
#   - Auto-dismiss when the live re-probe succeeds.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
STRINGS_FILE="${REPO_ROOT}/install.sh.strings.en-GB.sh"
RULES_DIR="${REPO_ROOT}/vendor/doctor/agent"

# ── Case 1: install.sh has the CX-60 probe block ────────────────
if ! grep -q "3.14e-probe iMessage FDA probe (CX-60)" "$INSTALL_SH"; then
    echo "FAIL [case-1]: CX-60 probe block missing from install.sh" >&2
    exit 1
fi
echo "PASS [case-1]: CX-60 probe block present in install.sh"

# ── Case 2: probe block is best-effort (set +e / set -e wrap) ───
# Extract the block and verify it both sets +e (probe is best-
# effort) and restores set -e (no leaking into the rest of install).
BLOCK=$(awk '
    /3.14e-probe iMessage FDA probe \(CX-60\)/ { in_block=1 }
    in_block && /end Apple Silicon guard/ { exit }
    in_block { print }
' "$INSTALL_SH")
if [[ -z "$BLOCK" ]]; then
    echo "FAIL [case-2]: could not extract CX-60 probe block" >&2
    exit 1
fi
if ! printf '%s\n' "$BLOCK" | grep -q "set +e"; then
    echo "FAIL [case-2]: probe block missing 'set +e' best-effort guard" >&2
    exit 1
fi
if ! printf '%s\n' "$BLOCK" | grep -q "set -e"; then
    echo "FAIL [case-2]: probe block missing 'set -e' restore" >&2
    exit 1
fi
echo "PASS [case-2]: probe block is best-effort (set +e / set -e wrap)"

# ── Case 3: writer invocation passes --imessage-fda-needed ──────
if ! printf '%s\n' "$BLOCK" | grep -q "imessage-fda-needed"; then
    echo "FAIL [case-3]: probe block does not call writer with --imessage-fda-needed" >&2
    exit 1
fi
echo "PASS [case-3]: probe writes via --imessage-fda-needed flag"

# ── Case 4: catalogue carries the probe strings ─────────────────
for key in MSG_INFO_IMESSAGE_FDA_PROBE_BEGIN \
           MSG_INFO_IMESSAGE_FDA_PROBE_GRANTED \
           MSG_INFO_IMESSAGE_FDA_PROBE_NEEDS_GRANT \
           MSG_INFO_IMESSAGE_FDA_PROBE_SKIPPED_NO_DAEMON \
           MSG_WARN_IMESSAGE_FDA_PROBE_SIGNAL_WRITE_FAILED; do
    if ! grep -q "^${key}=" "$STRINGS_FILE"; then
        echo "FAIL [case-4]: catalogue missing $key" >&2
        exit 1
    fi
done
echo "PASS [case-4]: all 5 CX-60 catalogue strings present"

# ── Case 5: Doctor surfaces iMessage permission state ───────────
#
# UPDATED 2026-07-07. The original case asserted the CX-60 rule
# check_imessage_fda in the vendored diagnostic_rules.py. That rule
# was SUPERSEDED by the v152-walk "native-aware Doctor" work (#323):
# the daemon now writes a richer TCC-posture marker to
# ~/.ostler/imessage-posture/state.md and the vendored Doctor renders
# it via imessage_tcc_posture.render_imessage_tcc_posture() directly
# in web_ui.py, replacing the pipeline_signals-driven card. (The
# P1-3 re-vendor at 87636fc synced the vendored tree to the upstream
# that had already made this move.)
#
# The install.sh writer half (cases 1-4 above) still writes the
# imessage_fda_needed signal for forward compatibility; the Doctor
# READ surface asserted here is the posture panel. Deep behavioural
# coverage of the posture probe lives in the sister test
# tests/test_imessage_tcc_posture.sh.
if [[ ! -f "${RULES_DIR}/imessage_tcc_posture.py" ]]; then
    echo "FAIL [case-5]: vendored Doctor is missing imessage_tcc_posture.py (the iMessage permission surface)" >&2
    exit 1
fi
python3 - <<PY
import sys
sys.path.insert(0, "${RULES_DIR}")
import imessage_tcc_posture as tcc

# The reader entry point the dashboard renderer consumes must exist.
assert callable(getattr(tcc, "read_imessage_tcc_posture", None)), \
    "read_imessage_tcc_posture missing"
print("PASS [case-5a]: posture module exposes read_imessage_tcc_posture")
PY
if ! grep -q 'def render_imessage_tcc_posture' "${RULES_DIR}/dashboard_components.py"; then
    echo "FAIL [case-5b]: vendored dashboard_components.py does not define render_imessage_tcc_posture" >&2
    exit 1
fi
if ! grep -q 'render_imessage_tcc_posture' "${RULES_DIR}/web_ui.py"; then
    echo "FAIL [case-5c]: vendored web_ui.py does not render the iMessage TCC posture section" >&2
    exit 1
fi
echo "PASS [case-5b/c]: vendored Doctor renders the iMessage TCC posture section"

# ── Case 6 (CX-66): assist block is present + gated on OSTLER_GUI ──
if ! grep -q "CX-66.*assisted FDA grant" "$INSTALL_SH"; then
    echo "FAIL [case-6]: CX-66 assist block missing from install.sh" >&2
    exit 1
fi
ASSIST_BLOCK=$(awk '
    /CX-66.*assisted FDA grant/ { in_block=1 }
    in_block && /^        fi$/  { exit }
    in_block { print }
' "$INSTALL_SH")
if [[ -z "$ASSIST_BLOCK" ]]; then
    echo "FAIL [case-6]: could not extract CX-66 assist block" >&2
    exit 1
fi
# Block must be gated on OSTLER_GUI=1 (no AppleScript dialog in headless installs)
if ! printf '%s\n' "$ASSIST_BLOCK" | grep -q 'OSTLER_GUI.*== "1"'; then
    echo "FAIL [case-6]: assist block missing OSTLER_GUI gate" >&2
    exit 1
fi
# Block must open System Settings via x-apple URL scheme
if ! printf '%s\n' "$ASSIST_BLOCK" | grep -q 'x-apple.systempreferences.*Privacy_AllFiles'; then
    echo "FAIL [case-6]: assist block missing System Settings deep-link" >&2
    exit 1
fi
# Block must NOT pop a Finder window during the FDA grant step.
# (auth-glut COMPLETION, WALK-2 2026-06-28) The `open -R
# "$ASSISTANT_APP_BUNDLE"` reveal was removed: it stacked a Finder window
# on top of the still-open System Settings Full Disk Access pane. The
# daemon is bootstrapped + given a grace read BEFORE the modal, so it is
# auto-listed and "Find Ostler in the list and turn it on" is accurate
# with no reveal. A regression that re-adds any `open -R` of the
# assistant bundle (the stray window Andy reported) must fail here.
# (strip comment lines so an explanatory `# ... open -R ...` comment does
# not false-positive -- we only care about an actual reveal command.)
if printf '%s\n' "$ASSIST_BLOCK" | grep -vE '^[[:space:]]*#' | grep -q 'open -R'; then
    echo "FAIL [case-6]: assist block re-introduced a Finder reveal (open -R) -- it stacks a window on System Settings during the FDA grant" >&2
    exit 1
fi
# Block must invoke osascript + display dialog (may be split across
# multiple -e args for the System Events activate front-bringer).
if ! printf '%s\n' "$ASSIST_BLOCK" | grep -q 'osascript'; then
    echo "FAIL [case-6]: assist block missing osascript invocation" >&2
    exit 1
fi
if ! printf '%s\n' "$ASSIST_BLOCK" | grep -q 'display dialog'; then
    echo "FAIL [case-6]: assist block missing display dialog AppleScript" >&2
    exit 1
fi
# z-order fix: must bring dialog to front before/around display
if ! printf '%s\n' "$ASSIST_BLOCK" | grep -q 'System Events.*activate'; then
    echo "FAIL [case-6]: assist block missing z-order activate" >&2
    exit 1
fi
# Block must re-probe chat.db after dialog dismissal
if ! printf '%s\n' "$ASSIST_BLOCK" | grep -q 'sleep 2' ; then
    echo "FAIL [case-6]: assist block missing re-probe sleep" >&2
    exit 1
fi
# Block must launchctl kickstart the assistant LaunchAgent on success
if ! printf '%s\n' "$ASSIST_BLOCK" | grep -q 'launchctl kickstart.*com.creativemachines.ostler.assistant'; then
    echo "FAIL [case-6]: assist block missing LaunchAgent kickstart" >&2
    exit 1
fi
echo "PASS [case-6]: assist block has all 6 required components"

# ── Case 7 (CX-66 + CX-78c + CX-81 B8): all catalogue strings present ──────────
# CX-78c (DMG #45) retired LINE5 (the "denied -- which is what put it
# in the list" apology) and added DAEMON_TCC_GRANTED for the new
# daemon-FDA pre-probe path -- string count was 10.
# CX-81 B8 (DMG #46+) tightened the dialog to 3 lines and retired LINE4
# (the "Click Done when you've toggled the switch on" tail). The retired
# string is folded into LINE3. String count drops to 9.
for key in MSG_INFO_IMESSAGE_FDA_ASSIST_OPENING \
           MSG_INFO_IMESSAGE_FDA_ASSIST_GRANTED \
           MSG_INFO_IMESSAGE_FDA_ASSIST_STILL_NEEDED \
           MSG_INFO_IMESSAGE_FDA_DAEMON_TCC_GRANTED \
           MSG_PROMPT_IMESSAGE_FDA_ASSIST_TITLE \
           MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE1 \
           MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE2 \
           MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3 \
           MSG_PROMPT_IMESSAGE_FDA_ASSIST_BUTTON; do
    if ! grep -q "^${key}=" "$STRINGS_FILE"; then
        echo "FAIL [case-7]: catalogue missing $key" >&2
        exit 1
    fi
done
# Negative: LINE4 must NOT be present (retired in CX-81 B8).
if grep -q "^MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE4=" "$STRINGS_FILE"; then
    echo "FAIL [case-7]: catalogue still carries retired LINE4 key" >&2
    exit 1
fi
echo "PASS [case-7]: all 9 CX-66 + CX-78c + CX-81 B8 catalogue strings present, LINE4 retired"

# ── Case 8 (CX-81 B8 + B8b): assist dialog uses Ostler dialog icon, not generic ──
# The osascript display dialog must NOT hardcode `with icon note` --
# it must resolve an Ostler-branded .icns at runtime with a
# `with icon note` fallback only when no icns file is present.
#
# B8b refinement: the PREFERRED icon is DialogIcon.icns (oxblood circle
# + white "O", edge-to-edge canvas, no internal padding). DialogIcon
# probes come FIRST in the resolution order. AppIcon.icns probes are
# retained as a secondary fallback to keep in-flight DMG cuts that
# shipped pre-B8b from regressing to the generic system note icon.
ASSIST_DIALOG_BLOCK=$(awk '
    /CX-81 B8.*DMG #46/ { in_block=1 }
    in_block && /^                unset _imessage_fda_dialog_msg/ { exit }
    in_block { print }
' "$INSTALL_SH")
if [[ -z "$ASSIST_DIALOG_BLOCK" ]]; then
    echo "FAIL [case-8]: could not extract CX-81 B8 icon-resolution block" >&2
    exit 1
fi
# Must probe SCRIPT_DIR for DialogIcon.icns FIRST (B8b: preferred icon).
if ! printf '%s\n' "$ASSIST_DIALOG_BLOCK" | grep -q '\${SCRIPT_DIR}/DialogIcon.icns'; then
    echo "FAIL [case-8]: icon resolution missing \${SCRIPT_DIR}/DialogIcon.icns probe (B8b)" >&2
    exit 1
fi
# Must probe /Applications/.../Resources/DialogIcon.icns as the B8b
# tarball-stripped fallback.
if ! printf '%s\n' "$ASSIST_DIALOG_BLOCK" | grep -q '/Applications/OstlerInstaller.app/Contents/Resources/DialogIcon.icns'; then
    echo "FAIL [case-8]: icon resolution missing /Applications DialogIcon fallback probe (B8b)" >&2
    exit 1
fi
# Must retain AppIcon.icns probes as secondary fallback (B8 -> B8b
# transition safety net: in-flight DMG cuts).
if ! printf '%s\n' "$ASSIST_DIALOG_BLOCK" | grep -q '\${SCRIPT_DIR}/AppIcon.icns'; then
    echo "FAIL [case-8]: icon resolution missing \${SCRIPT_DIR}/AppIcon.icns secondary fallback" >&2
    exit 1
fi
if ! printf '%s\n' "$ASSIST_DIALOG_BLOCK" | grep -q '/Applications/OstlerInstaller.app/Contents/Resources/AppIcon.icns'; then
    echo "FAIL [case-8]: icon resolution missing /Applications AppIcon.icns secondary fallback" >&2
    exit 1
fi
# DialogIcon probes must be ORDERED BEFORE AppIcon probes -- the line
# number of the first DialogIcon match must be less than the first
# AppIcon match. This locks the B8b preference order against future
# accidental reshuffles.
DIALOG_LINE=$(printf '%s\n' "$ASSIST_DIALOG_BLOCK" | grep -n 'DialogIcon.icns' | head -1 | cut -d: -f1)
APPICON_LINE=$(printf '%s\n' "$ASSIST_DIALOG_BLOCK" | grep -n 'AppIcon.icns' | head -1 | cut -d: -f1)
if [[ -z "$DIALOG_LINE" || -z "$APPICON_LINE" ]]; then
    echo "FAIL [case-8]: could not measure DialogIcon vs AppIcon ordering" >&2
    exit 1
fi
if (( DIALOG_LINE >= APPICON_LINE )); then
    echo "FAIL [case-8]: DialogIcon.icns probe ($DIALOG_LINE) must precede AppIcon.icns probe ($APPICON_LINE) per B8b preference order" >&2
    exit 1
fi
# Must build a `with icon file POSIX file` clause when an icns is found.
if ! printf '%s\n' "$ASSIST_DIALOG_BLOCK" | grep -q 'with icon file POSIX file'; then
    echo "FAIL [case-8]: icon resolution missing POSIX file icon clause" >&2
    exit 1
fi
# Must retain a `with icon note` fallback for dev/CI/headless paths.
if ! printf '%s\n' "$ASSIST_DIALOG_BLOCK" | grep -q 'with icon note'; then
    echo "FAIL [case-8]: icon resolution missing `with icon note` fallback" >&2
    exit 1
fi
# osascript invocation must substitute the resolved icon clause, NOT
# hardcode `with icon note` after the buttons clause.
if grep -q 'default button \\\"\${_imessage_fda_button_esc}\\\" with icon note' "$INSTALL_SH"; then
    echo "FAIL [case-8]: install.sh still hardcodes \`with icon note\` in the osascript dialog" >&2
    exit 1
fi
echo "PASS [case-8]: assist dialog prefers DialogIcon.icns, falls back to AppIcon.icns then 'with icon note'"

# ── Case 9 (CX-81 B8b): DialogIcon.icns asset is bundled ──
# The DialogIcon.icns must exist at gui/OstlerInstaller/Resources/
# so the project.yml resources block bundles it into the .app at
# Contents/Resources/DialogIcon.icns. Without this the install.sh
# probe falls back to AppIcon (the bug B8b is paying down) or
# `with icon note` (worse).
DIALOG_ICNS="${REPO_ROOT}/gui/OstlerInstaller/Resources/DialogIcon.icns"
if [[ ! -f "$DIALOG_ICNS" ]]; then
    echo "FAIL [case-9]: DialogIcon.icns missing at $DIALOG_ICNS" >&2
    exit 1
fi
# Validate the file actually parses as a macOS icon container by
# checking the magic. `file` returns "Mac OS X icon" for a well-formed
# .icns (any rep type).
if ! file "$DIALOG_ICNS" 2>/dev/null | grep -q "Mac OS X icon"; then
    echo "FAIL [case-9]: DialogIcon.icns is not a valid macOS icon container" >&2
    exit 1
fi
echo "PASS [case-9]: DialogIcon.icns asset bundled + parses as valid .icns"

echo ""
echo "ALL CX-60 + CX-66 + CX-81 B8 + B8b IMESSAGE FDA PROBE TESTS PASSED"
