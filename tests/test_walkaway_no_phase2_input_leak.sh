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

# ── Every gui_read after the boundary must be on the interactive allowlist ──
# These genuinely need the customer present mid-install and cannot be
# pre-answered in Phase 2:
#   tailscale_confirm                -> iPhone/Watch pairing is interactive
#   imessage_automation_incoming_ack -> acknowledge pre-warn for an OS dialog
#   save_keychain                    -> recovery key is generated in Phase 3.6
#   mail_not_connected               -> guarded fallback (only if the Phase-2
#                                       prompt was not shown); informational
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
