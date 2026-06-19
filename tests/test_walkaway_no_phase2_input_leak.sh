#!/usr/bin/env bash
#
# tests/test_walkaway_no_phase2_input_leak.sh
#
# #639 (2b): the install must run unattended after Phase 2. The Mail
# history-window "extend?" question used to be a blocking gui_read in the
# Phase-3 EXECUTION region (~L6498), so a customer who walked away after
# answering the questions returned to a stalled install. It is now asked
# upfront in Phase 2 (stored in OSTLER_MAIL_BACKFILL_DAYS, consumed by the
# first FDA extraction with no further prompt).
#
# This test pins the walk-away invariant: NO pure-preference gui_read
# question fires after the Phase-3 boundary. A small ALLOWLIST of
# inherently-interactive / state-dependent Phase-3 prompts is permitted
# (and documented) -- those genuinely need the customer present mid-run
# (iPhone/Watch pairing, an OS-permission acknowledge pre-warn, and the
# save-recovery-key-to-Keychain decision, whose key is generated during
# Phase 3.6 and so cannot be offered earlier). A NEW gui_read tag after
# the boundary trips this test.
#
# Synthetic only. Pure bash + awk.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$INSTALL_SH" ]] || fail "install.sh not found"
bash -n "$INSTALL_SH" || fail "install.sh fails bash -n"
echo "PASS: install.sh parses"

# ── Locate the Phase-3 boundary (unattended-install marker) ───────────
BOUNDARY="$(grep -nE 'PHASE 3: INSTALL EVERYTHING' "$INSTALL_SH" | head -1 | cut -d: -f1)"
[[ -n "$BOUNDARY" ]] || fail "could not locate the Phase-3 boundary marker"
echo "PASS: Phase-3 boundary at line $BOUNDARY"

# ── The Mail extend question must be in Phase 2 (before the boundary) ──
extend_line="$(grep -n '"mail_extend_history")' "$INSTALL_SH" | head -1 | cut -d: -f1)"
[[ -n "$extend_line" ]] || fail "mail_extend_history gui_read not found at all (pre-fill regressed?)"
[[ "$extend_line" -lt "$BOUNDARY" ]] \
    || fail "mail_extend_history gui_read is at line $extend_line, AFTER the Phase-3 boundary ($BOUNDARY) -- it must be collected in Phase 2"
echo "PASS: mail_extend_history question is in Phase 2 (line $extend_line < $BOUNDARY)"

# ── No mail_extend_history gui_read remains in the execution region ───
if awk -v b="$BOUNDARY" 'NR>b && /gui_read/,/\)"/ {print}' "$INSTALL_SH" \
    | grep -q 'mail_extend_history'; then
    fail "a mail_extend_history gui_read still fires after the Phase-3 boundary"
fi
echo "PASS: no mail_extend_history prompt in the Phase-3 execution region"

# ── WALK-1: the Tailscale setup/skip DECISION must be in Phase 2 ───────
# A tailscale_confirm gui_read must exist BEFORE the boundary (the hoist),
# and any tailscale_confirm gui_read AFTER the boundary must be a guarded
# fallback (wrapped in a TAILSCALE_CONFIRM_SHOWN_EARLY check), never an
# unconditional surprise prompt in the unattended middle.
ts_early_line="$(grep -n '"tailscale_confirm")' "$INSTALL_SH" | head -1 | cut -d: -f1)"
[[ -n "$ts_early_line" ]] || fail "tailscale_confirm gui_read not found at all (hoist regressed?)"
[[ "$ts_early_line" -lt "$BOUNDARY" ]] \
    || fail "the FIRST tailscale_confirm gui_read is at line $ts_early_line, AFTER the Phase-3 boundary ($BOUNDARY) -- the setup/skip DECISION must be collected upfront in Phase 2"
echo "PASS: tailscale_confirm DECISION is in Phase 2 (line $ts_early_line < $BOUNDARY)"

# If a tailscale_confirm gui_read remains after the boundary, it must be
# preceded (within 6 lines) by a TAILSCALE_CONFIRM_SHOWN_EARLY guard.
ts_late_line="$(awk -v b="$BOUNDARY" 'NR>b && /"tailscale_confirm")/ {print NR; exit}' "$INSTALL_SH")"
if [[ -n "$ts_late_line" ]]; then
    guard_window_start=$((ts_late_line - 6))
    if ! sed -n "${guard_window_start},${ts_late_line}p" "$INSTALL_SH" \
        | grep -q 'TAILSCALE_CONFIRM_SHOWN_EARLY'; then
        fail "the post-boundary tailscale_confirm gui_read at line $ts_late_line is NOT guarded by TAILSCALE_CONFIRM_SHOWN_EARLY -- it would fire as a surprise prompt mid-install"
    fi
    echo "PASS: post-boundary tailscale_confirm (line $ts_late_line) is a guarded fallback"
else
    echo "NOTE: no tailscale_confirm gui_read after the boundary (decision fully hoisted)"
fi

# ── WALK-1 (Wave 2.1): the installer FDA grant must be hoisted to Phase 2 ──
# The installer Full Disk Access grant is an osascript MODAL, not a tagged
# gui_read, so the gui_read scan above cannot see it. Pin it structurally:
#   (a) the upfront grant sets INSTALLER_FDA_SHOWN_EARLY=1 BEFORE the boundary;
#   (b) the late fda_extract assist is GUARDED by -z INSTALLER_FDA_SHOWN_EARLY
#       (so the normal walk-away path never re-prompts mid-install);
#   (c) an UNCONDITIONAL final re-probe still runs before the run_all import
#       (a deferred / declined / relaunch-settled grant is always recovered).
fda_early_line="$(grep -n 'INSTALLER_FDA_SHOWN_EARLY=1' "$INSTALL_SH" | head -1 | cut -d: -f1)"
[[ -n "$fda_early_line" ]] || fail "INSTALLER_FDA_SHOWN_EARLY=1 not set anywhere -- the upfront installer-FDA hoist regressed"
[[ "$fda_early_line" -lt "$BOUNDARY" ]] \
    || fail "INSTALLER_FDA_SHOWN_EARLY=1 is at line $fda_early_line, AFTER the Phase-3 boundary ($BOUNDARY) -- the installer FDA grant must be hoisted into Phase 2"
echo "PASS: installer FDA grant is hoisted to Phase 2 (INSTALLER_FDA_SHOWN_EARLY set at line $fda_early_line < $BOUNDARY)"

# (b) the late fda_extract assist gate must carry the guard.
fda_late_gate="$(awk -v b="$BOUNDARY" 'NR>b && /OSTLER_GUI:-0.*== "1" && -z "\${INSTALLER_FDA_SHOWN_EARLY:-}"/ {print NR; exit}' "$INSTALL_SH")"
[[ -n "$fda_late_gate" ]] \
    || fail "the late fda_extract FDA assist gate is not guarded by INSTALLER_FDA_SHOWN_EARLY -- it would re-prompt for FDA mid-install on the walk-away path"
echo "PASS: late fda_extract assist is a guarded fallback (line $fda_late_gate, behind INSTALLER_FDA_SHOWN_EARLY)"

# (c) an unconditional final re-probe must precede the run_all import.
run_all_line="$(grep -n '^from ostler_fda.extract_all import run_all' "$INSTALL_SH" | head -1 | cut -d: -f1)"
reprobe_line="$(grep -n 'FDA_FINAL_REPROBE_TRIED' "$INSTALL_SH" | head -1 | cut -d: -f1)"
[[ -n "$reprobe_line" ]] || fail "the unconditional final FDA re-probe (FDA_FINAL_REPROBE_TRIED) is missing -- a deferred grant would be silently skipped"
[[ -n "$run_all_line" && "$reprobe_line" -lt "$run_all_line" ]] \
    || fail "the unconditional final FDA re-probe (line $reprobe_line) must precede the run_all import (line $run_all_line)"
echo "PASS: unconditional final FDA re-probe (line $reprobe_line) precedes run_all import (line $run_all_line)"

# ── Every gui_read after the boundary must be on the interactive allowlist ──
# These genuinely need the customer present mid-install OR are guarded
# fallbacks that only fire when the Phase-2 prompt did not run (reuse
# install / GUI toggled off then on):
#   imessage_automation_incoming_ack -> acknowledge pre-warn for an OS dialog
#   save_keychain                    -> recovery key is generated in Phase 3.6
#   mail_not_connected               -> guarded fallback (only if the Phase-2
#                                       prompt was not shown); informational
#   tailscale_confirm                -> WALK-1 (Wave 2.1): the setup/skip
#                                       DECISION is now hoisted into Phase 2;
#                                       this remaining gui_read is a GUARDED
#                                       fallback wrapped in
#                                       [[ -z "${TAILSCALE_CONFIRM_SHOWN_EARLY:-}" ]]
#                                       so it can ONLY fire when the upfront
#                                       prompt did not run -- same shape as
#                                       mail_not_connected. The normal
#                                       walk-away path never hits it.
ALLOWLIST=" tailscale_confirm imessage_automation_incoming_ack save_keychain mail_not_connected "

post_tags="$(awk -v b="$BOUNDARY" '
    NR<=b { next }
    /gui_read/ { ing=1 }
    ing {
        line=$0
        while (match(line, /"[A-Za-z0-9_]+"/)) {
            last=substr(line, RSTART+1, RLENGTH-2)
            line=substr(line, RSTART+RLENGTH)
        }
        if ($0 ~ /\)"/) { print last; ing=0 }
    }
' "$INSTALL_SH")"

[[ -n "$post_tags" ]] || { echo "NOTE: no gui_read after the boundary at all"; }

while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    case " $ALLOWLIST " in
        *" $tag "*) : ;;
        *) fail "new non-allowlisted gui_read '$tag' fires after the Phase-3 boundary -- a walk-away install would stall. Move it into Phase 2 (or, if inherently interactive, extend the documented allowlist)." ;;
    esac
done <<< "$post_tags"
echo "PASS: every post-boundary gui_read is on the documented interactive allowlist"
echo "      (post-boundary tags: $(echo $post_tags | tr '\n' ' '))"

echo "ALL PASS: test_walkaway_no_phase2_input_leak.sh"
