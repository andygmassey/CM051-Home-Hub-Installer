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
if ! grep -q "set +e" <<< "$BLOCK"; then
    echo "FAIL [case-2]: probe block missing 'set +e' best-effort guard" >&2
    exit 1
fi
if ! grep -q "set -e" <<< "$BLOCK"; then
    echo "FAIL [case-2]: probe block missing 'set -e' restore" >&2
    exit 1
fi
echo "PASS [case-2]: probe block is best-effort (set +e / set -e wrap)"

# ── Case 3: writer invocation passes --imessage-fda-needed ──────
if ! grep -q "imessage-fda-needed" <<< "$BLOCK"; then
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

# ── Case 5: Doctor rule renders the card from synthetic state ───
python3 - <<PY
import sys, types
# Stub httpx (heavy network dep we don't need for the unit-shape test).
httpx_stub = types.ModuleType("httpx")
class _Err(Exception): pass
class _C:
    def __init__(self, *a, **kw): pass
    def get(self, url): raise _Err("stub")
httpx_stub.Client = _C
httpx_stub.RequestError = _Err
sys.modules["httpx"] = httpx_stub

sys.path.insert(0, "${RULES_DIR}")
import diagnostic_rules as dr

# Stay-quiet paths
class _Empty: pipeline_signals = None
assert dr.check_imessage_fda(_Empty()) == []

class _Sig:
    imessage_chat_db_fda_needed = None
class _SnapNone:
    pipeline_signals = _Sig()
assert dr.check_imessage_fda(_SnapNone()) == []

class _SigFalse:
    imessage_chat_db_fda_needed = False
class _SnapFalse:
    pipeline_signals = _SigFalse()
assert dr.check_imessage_fda(_SnapFalse()) == []

# Card rendered when needed=True + live probe fails
class _SigTrue:
    imessage_chat_db_fda_needed = True
class _SnapTrue:
    pipeline_signals = _SigTrue()
dr._imessage_chat_db_readable = lambda: False
findings = dr.check_imessage_fda(_SnapTrue())
assert len(findings) == 1, findings
f = findings[0]
assert f["severity"] == "warning"
assert "Full Disk Access" in f["title"]
assert "x-apple.systempreferences" in f["fix_command"]
assert "launchctl kickstart" in f["detail"]
assert f["category"] == "installation"

# Auto-dismiss when live probe succeeds
dr._imessage_chat_db_readable = lambda: True
assert dr.check_imessage_fda(_SnapTrue()) == []

# Rule registered in ALL_RULES
assert any(r.__name__ == "check_imessage_fda" for r in dr.ALL_RULES)
print("PASS [case-5]: Doctor rule passes all 5 sub-assertions")
PY

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
if ! grep -q 'OSTLER_GUI.*== "1"' <<< "$ASSIST_BLOCK"; then
    echo "FAIL [case-6]: assist block missing OSTLER_GUI gate" >&2
    exit 1
fi
# Block must open System Settings via x-apple URL scheme
if ! grep -q 'x-apple.systempreferences.*Privacy_AllFiles' <<< "$ASSIST_BLOCK"; then
    echo "FAIL [case-6]: assist block missing System Settings deep-link" >&2
    exit 1
fi
# Block must reveal the daemon .app bundle in Finder. The reveal target
# is the OstlerAssistant.app bundle (via $ASSISTANT_APP_BUNDLE) so the
# customer can drag the app itself into the FDA pane; earlier revisions
# revealed the bare ostler-assistant binary path, hence the historical
# grep -- updated to the current .app-bundle reveal.
if ! grep -q 'open -R.*ASSISTANT_APP_BUNDLE' <<< "$ASSIST_BLOCK"; then
    echo "FAIL [case-6]: assist block missing Finder reveal" >&2
    exit 1
fi
# Block must invoke osascript + display dialog (may be split across
# multiple -e args for the System Events activate front-bringer).
if ! grep -q 'osascript' <<< "$ASSIST_BLOCK"; then
    echo "FAIL [case-6]: assist block missing osascript invocation" >&2
    exit 1
fi
if ! grep -q 'display dialog' <<< "$ASSIST_BLOCK"; then
    echo "FAIL [case-6]: assist block missing display dialog AppleScript" >&2
    exit 1
fi
# z-order: the dialog must be surfaced frontmost. BW3-2 (2026-07-23)
# dropped the standalone `activate` (it stole focus back off System
# Settings/Finder); the dialog is now run THROUGH System Events, which
# is app-modal and frontmost on its own. Lock that mechanism.
if ! grep -q 'System Events.*display dialog' <<< "$ASSIST_BLOCK"; then
    echo "FAIL [case-6]: assist block missing System Events frontmost dialog" >&2
    exit 1
fi
# Block must re-probe chat.db after dialog dismissal
if ! grep -q 'sleep 2' <<< "$ASSIST_BLOCK" ; then
    echo "FAIL [case-6]: assist block missing re-probe sleep" >&2
    exit 1
fi
# Block must start the assistant daemon on success. BW3-1 (2026-07-23)
# replaced the inline `launchctl kickstart` with the deferred-start
# helper _ostler_start_assistant_daemon (it bootstraps the LaunchAgent
# on first call now that RunAtLoad is deferred until FDA lands, and
# kickstart -k's it on subsequent calls). Lock the helper call.
if ! grep -q '_ostler_start_assistant_daemon' <<< "$ASSIST_BLOCK"; then
    echo "FAIL [case-6]: assist block missing assistant-daemon start on success" >&2
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
if ! grep -q '\${SCRIPT_DIR}/DialogIcon.icns' <<< "$ASSIST_DIALOG_BLOCK"; then
    echo "FAIL [case-8]: icon resolution missing \${SCRIPT_DIR}/DialogIcon.icns probe (B8b)" >&2
    exit 1
fi
# Must probe /Applications/.../Resources/DialogIcon.icns as the B8b
# tarball-stripped fallback.
if ! grep -q '/Applications/OstlerInstaller.app/Contents/Resources/DialogIcon.icns' <<< "$ASSIST_DIALOG_BLOCK"; then
    echo "FAIL [case-8]: icon resolution missing /Applications DialogIcon fallback probe (B8b)" >&2
    exit 1
fi
# Must retain AppIcon.icns probes as secondary fallback (B8 -> B8b
# transition safety net: in-flight DMG cuts).
if ! grep -q '\${SCRIPT_DIR}/AppIcon.icns' <<< "$ASSIST_DIALOG_BLOCK"; then
    echo "FAIL [case-8]: icon resolution missing \${SCRIPT_DIR}/AppIcon.icns secondary fallback" >&2
    exit 1
fi
if ! grep -q '/Applications/OstlerInstaller.app/Contents/Resources/AppIcon.icns' <<< "$ASSIST_DIALOG_BLOCK"; then
    echo "FAIL [case-8]: icon resolution missing /Applications AppIcon.icns secondary fallback" >&2
    exit 1
fi
# DialogIcon probes must be ORDERED BEFORE AppIcon probes -- the line
# number of the first DialogIcon match must be less than the first
# AppIcon match. This locks the B8b preference order against future
# accidental reshuffles.
DIALOG_LINE=$(grep -n 'DialogIcon.icns' <<< "$ASSIST_DIALOG_BLOCK" | head -1 | cut -d: -f1)
APPICON_LINE=$(grep -n 'AppIcon.icns' <<< "$ASSIST_DIALOG_BLOCK" | head -1 | cut -d: -f1)
if [[ -z "$DIALOG_LINE" || -z "$APPICON_LINE" ]]; then
    echo "FAIL [case-8]: could not measure DialogIcon vs AppIcon ordering" >&2
    exit 1
fi
if (( DIALOG_LINE >= APPICON_LINE )); then
    echo "FAIL [case-8]: DialogIcon.icns probe ($DIALOG_LINE) must precede AppIcon.icns probe ($APPICON_LINE) per B8b preference order" >&2
    exit 1
fi
# Must build a `with icon file POSIX file` clause when an icns is found.
if ! grep -q 'with icon file POSIX file' <<< "$ASSIST_DIALOG_BLOCK"; then
    echo "FAIL [case-8]: icon resolution missing POSIX file icon clause" >&2
    exit 1
fi
# Must retain a `with icon note` fallback for dev/CI/headless paths.
if ! grep -q 'with icon note' <<< "$ASSIST_DIALOG_BLOCK"; then
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

# ── Case 10 (BW6, supersedes BW4-A): bulletproof register-nudge ──
# Box-walk (.184): OstlerAssistant did not auto-list in the FDA pane
# because no read had ever been attributed to ai.ostler.assistant. The
# nudge launches the daemon .app via LaunchServices with the one-shot
# `run-source imessage --self-test` probe BEFORE opening the pane, so
# macOS registers the daemon as a toggleable row.
#
# BW6 (window-glut fix): the nudge is now COMPLETION-DETECTION based, not
# timing based. The old code armed `sleep 15; kill -TERM "$_fda_probe_pid"`
# on the `( open ... ) &` *waiter* subshell, NOT the launched app -- so a
# vendored binary that failed to self-exit ran as the full daemon pre-FDA
# and raised the Documents + Automation prompts (the glut). BW6 replaces
# that with (1) a capability gate that proves the binary honours the
# one-shot before ever launching the app, and (2) a hard-kill by the app's
# own argv. Lock the new shape and forbid regression to the timing killer.
#
# The nudge lives inside the CX-66 assist block; reuse ASSIST_BLOCK
# extracted in case-6.
# Must launch the assistant .app bundle via LaunchServices (`open`),
# NOT a bare fork/exec (which TCC attributes to the installer ancestor).
# `-W` is deliberately gone. It is the flag that created the waiter
# subshell the old timing killer mis-targeted, and the anti-regression
# assertion further down forbids that killer's return -- so an assertion
# that still REQUIRED -gjnW would contradict it and no tree could satisfy
# both. Accept -gjn.
if ! grep -q 'open -gjn -a "\$ASSISTANT_APP_BUNDLE"' <<< "$ASSIST_BLOCK"; then
    echo "FAIL [case-10]: register nudge missing LaunchServices open of the assistant .app" >&2
    exit 1
fi
# Must hand it the one-shot self-test probe (attributes a chat.db read
# to ai.ostler.assistant; exits immediately; never touches ~/Documents).
if ! grep -q 'run-source imessage --self-test' <<< "$ASSIST_BLOCK"; then
    echo "FAIL [case-10]: register nudge missing 'run-source imessage --self-test' probe" >&2
    exit 1
fi
# BW6 (1): CAPABILITY GATE. The nudge must first run the binary DIRECTLY
# and gate the app-launch on a `SELF-TEST:` marker, so a binary that does
# not honour the one-shot can never be `open`ed into the full daemon.
if ! grep -q '"\$ASSISTANT_BINARY" \$_fda_selftest_argv' <<< "$ASSIST_BLOCK"; then
    echo "FAIL [case-10]: register nudge missing the direct-exec capability probe" >&2
    exit 1
fi
if ! grep -q "grep -q 'SELF-TEST:'" <<< "$ASSIST_BLOCK"; then
    echo "FAIL [case-10]: register nudge must gate on the SELF-TEST marker" >&2
    exit 1
fi
# BW6 (2): HARD-KILL BY PROCESS IDENTITY. The launched instance must be
# killed by its own argv (pkill -f anchored on the self-test command line),
# NOT by TERMing the `open` waiter.
if ! grep -q 'pkill -f "OstlerAssistant.app/Contents/MacOS/ostler-assistant' <<< "$ASSIST_BLOCK"; then
    echo "FAIL [case-10]: register nudge missing hard-kill by the launched app's argv" >&2
    exit 1
fi
# BW6 anti-regression: the timing killer that TERMed the open-waiter (the
# root cause of the glut, fixed ~two dozen times before) must be GONE.
if grep -Eq 'kill -TERM "\$_fda_probe_(pid|killer)"' <<< "$ASSIST_BLOCK"; then
    echo "FAIL [case-10]: timing-based open-waiter killer reintroduced (must be completion-detection, not a timer)" >&2
    exit 1
fi
# The nudge must run BEFORE the System Settings pane is opened, so the
# row is already registered when the customer looks. Assert ordering:
# the open-assistant line precedes the x-apple deep-link line.
NUDGE_LINE=$(grep -n 'open -gjn -a "\$ASSISTANT_APP_BUNDLE"' <<< "$ASSIST_BLOCK" | head -1 | cut -d: -f1)
PANE_LINE=$(grep -n 'x-apple.systempreferences.*Privacy_AllFiles' <<< "$ASSIST_BLOCK" | head -1 | cut -d: -f1)
if [[ -z "$NUDGE_LINE" || -z "$PANE_LINE" ]]; then
    echo "FAIL [case-10]: could not measure nudge vs pane ordering" >&2
    exit 1
fi
if (( NUDGE_LINE >= PANE_LINE )); then
    echo "FAIL [case-10]: register nudge ($NUDGE_LINE) must precede opening the FDA pane ($PANE_LINE)" >&2
    exit 1
fi
# Must NOT bootstrap/load the persistent LaunchAgent as part of the nudge
# (that would reintroduce the #428 pre-FDA crash-loop). The only
# launchctl start of the assistant stays in _ostler_start_assistant_daemon,
# which is gated behind FDA-confirmed -- assert the nudge block itself
# carries no launchctl bootstrap/load of the assistant label.
NUDGE_BLOCK=$(awk '
    /BW6 .2026-07-26, G-1\/window-glut.: register-nudge/ { in_block=1 }
    in_block && /FDA_PANE_REFRESH/ { exit }
    in_block { print }
' "$INSTALL_SH")
if [[ -z "$NUDGE_BLOCK" ]]; then
    echo "FAIL [case-10]: could not extract BW6 nudge block" >&2
    exit 1
fi
if grep -Eq 'launchctl (bootstrap|load|kickstart)' <<< "$NUDGE_BLOCK"; then
    echo "FAIL [case-10]: nudge block must not bootstrap the persistent daemon (would risk #428 crash-loop)" >&2
    exit 1
fi
# Catalogue must carry the nudge log string.
if ! grep -q "^MSG_INFO_IMESSAGE_FDA_REGISTER_NUDGE=" "$STRINGS_FILE"; then
    echo "FAIL [case-10]: catalogue missing MSG_INFO_IMESSAGE_FDA_REGISTER_NUDGE" >&2
    exit 1
fi
echo "PASS [case-10]: BW6 register nudge present, capability-gated, hard-kills by argv, ordered before the pane, crash-loop-safe, no timing killer"

# ── Case 11 (BW6): assist-window close is bulletproof under load ──
# Root cause of Andy's stacked glut: at load ~91% the old close fired a
# SINGLE killall then watched with a 10s ceiling; System Settings lingered
# past 10s and the end-of-install daemon prompt stacked on it. Lock the
# hardened close: killall RE-ISSUED inside the wait loop (not once), a
# generous ceiling (>= 60, not 10), and the Finder reveal window closed.
# Extract the close loop from the assist block (reuse ASSIST_BLOCK).
# 1. The close must be a loop that re-issues killall on every iteration:
#    assert a `while` precedes a `killall "System Settings"` that is itself
#    followed by the loop's `sleep`/ceiling -- i.e. killall is inside the loop.
CLOSE_BLOCK=$(awk '
    /BW6 .2026-07-26, window-glut.: close EVERY window/ { in_block=1 }
    in_block { print }
    in_block && /unset _fda_listed _ss_close_wait/ { exit }
' "$INSTALL_SH")
if [[ -z "$CLOSE_BLOCK" ]]; then
    echo "FAIL [case-11]: could not extract BW6 assist-window close block" >&2
    exit 1
fi
if ! grep -q 'while :; do' <<< "$CLOSE_BLOCK"; then
    echo "FAIL [case-11]: close must be a repeated loop (while), not a one-shot killall + watch" >&2
    exit 1
fi
# killall must be INSIDE the loop (after `while`, before the `done`).
_while_ln=$(grep -n '^[[:space:]]*while :; do' <<< "$CLOSE_BLOCK" | head -1 | cut -d: -f1)
# Anchor on the actual command (line-start), not a comment mentioning killall.
_killall_ln=$(grep -n '^[[:space:]]*killall "System Settings"' <<< "$CLOSE_BLOCK" | head -1 | cut -d: -f1)
_done_ln=$(grep -n '^[[:space:]]*done$' <<< "$CLOSE_BLOCK" | head -1 | cut -d: -f1)
if [[ -z "$_while_ln" || -z "$_killall_ln" || -z "$_done_ln" ]] \
   || (( _killall_ln <= _while_ln )) || (( _killall_ln >= _done_ln )); then
    echo "FAIL [case-11]: killall must be re-issued INSIDE the close loop (while < killall < done)" >&2
    exit 1
fi
# 2. Ceiling must be generous (>= 60), never the old 10s.
if ! grep -Eq '_ss_close_wait" -ge (6[0-9]|[7-9][0-9]|[1-9][0-9]{2,})' <<< "$CLOSE_BLOCK"; then
    echo "FAIL [case-11]: close-poll ceiling must be >= 60s (was 10s -- too tight under load)" >&2
    exit 1
fi
# 3. THE FINDER CLOSE MUST BE ABSENT. INVERTED 2026-09-02 (WALK-361).
#
# ⚠️ THIS ASSERTION USED TO REQUIRE THE DEFECT. It read:
#
#     if ! grep -q 'Finder" to close windows' ... FAIL "missing the Finder close"
#
# i.e. the suite went RED unless install.sh sent an Apple Event to Finder.
# Andy hit the consequence on the v1.0.57 launch walk, having reported it
# before: macOS raises "OstlerInstaller wants access to control Finder.
# Allowing control will provide access to documents and data in Finder",
# stamped with our single NSAppleEventsUsageDescription, which talks about the
# administrator password. A documents-and-data prompt explained by a sentence
# about passwords, in order to close a window.
#
# The fixture had encoded the FLAG (a window gets tidied) rather than the
# PROPERTY (the customer is not shown a frightening consent dialog for a
# cosmetic action), so it locked the defect in and would have refused its own
# removal. Now it asserts the opposite. Guarded end-to-end by
# tests/test_no_finder_appleevent.sh, which is mutation-tested against the
# pre-fix tree.
#
# `open -R` is untouched and still required elsewhere: LaunchServices, not an
# Apple Event, so it raises no prompt.
if grep -q 'Finder" to close windows' <<< "$CLOSE_BLOCK"; then
    echo "FAIL [case-11]: the close block sends an Apple Event to Finder again. \
This raises the 'control Finder / documents and data' consent dialog on every \
walk (WALK-361). Do not reword the usage string -- macOS allows exactly one \
NSAppleEventsUsageDescription per app, so it cannot be worded per target. \
Remove the event instead." >&2
    exit 1
fi
# POSITIVE CONTROL for the zero above: an unextracted or truncated block would
# also contain no Finder event, and that must not read as the fix being in
# place. The killall line was already proved present above, so assert the
# block still carries the loop's own terminator too -- if this fails the
# absence result is CANNOT-RUN, not a pass.
if ! grep -q 'System Settings' <<< "$CLOSE_BLOCK"; then
    echo "FAIL [case-11]: CANNOT-RUN -- close block does not contain 'System Settings', \
so it was not really extracted and the Finder-absence result above is vacuous." >&2
    exit 1
fi
echo "PASS [case-11]: BW6 assist-window close is loop-repeated killall + >=60s ceiling + NO Finder Apple Event (control: block extracted)"

echo ""
echo "ALL CX-60 + CX-66 + CX-81 B8 + B8b + BW4-A + BW6 IMESSAGE FDA PROBE TESTS PASSED"
