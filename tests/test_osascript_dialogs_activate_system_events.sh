#!/usr/bin/env bash
#
# EVERY osascript `display dialog` MUST BE PRECEDED BY `activate`.
#
# THE DEFECT THIS GUARDS, measured twice on real hardware.
#
# Commit ba94a24 (2026-07-23, "drop focus-steal") removed the standalone
#     -e 'tell application "System Events" to activate'
# line from four of the six osascript dialog sites in install.sh, on the
# stated grounds that "`display dialog` is already app-modal and frontmost".
#
# System Events is a background-only agent. Its dialog is modal WITHIN System
# Events; macOS does not raise it above another application's window. Every one
# of the four stripped sites runs immediately after the script `open`s a System
# Settings pane -- so the dialog opened behind System Settings and the customer
# saw nothing.
#
# Andy, v1.0.37 walk (2026-08-20) and v1.0.38 walk (2026-08-21):
#   "no FDA auth request for Ostler Assistant yet again"
#   "It's sitting then OFF in FDA in System Settings"
# The prompt was not declined. It was never on screen. Full Disk Access has no
# macOS API, so a deep link plus a modal is the entire mechanism available --
# an unseen modal means the feature is dead, silently, on every install.
#
# WHY A STRUCTURAL TEST AND NOT A BEHAVIOURAL ONE
#
# The behavioural check ("did a dialog appear in front") needs a windowserver
# session and a human's eyes. This asserts the one property that made the
# difference, on the surface a future editor will touch: the `activate` line.
# It is deliberately anchored to the osascript INVOCATION, not to a comment or
# a nearby marker, because the previous guard for this area was pinned to a
# stray comment 8,200 lines away (#815).
#
# ANTI-VACUITY. The test refuses to pass if it finds no dialogs at all, and
# limb 3 proves the predicate can still go red by running it against a mutated
# copy with one `activate` deleted. Without limb 3 a rename of `display dialog`
# would turn this green while the product regressed.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
INSTALL_SH="install.sh"

pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }

# The predicate, as a function so limb 3 can run the SAME code on a mutant.
# Returns the number of `display dialog` invocations NOT immediately preceded
# by an `activate` line, and prints their line numbers.
unactivated_dialogs() {
    awk '
        /to display dialog/ {
            if (prev !~ /to activate/) { print NR; n++ }
        }
        { prev = $0 }
        END { exit 0 }
    ' "$1"
}

count_dialogs() { grep -c 'to display dialog' "$1"; }

echo "=== 1. premise: install.sh still drives dialogs through osascript ==="
DIALOGS="$(count_dialogs "$INSTALL_SH")"
if [[ "${DIALOGS:-0}" -ge 4 ]]; then
    ok "premise holds: ${DIALOGS} osascript 'display dialog' invocations found"
else
    bad "PREMISE GONE: only ${DIALOGS} 'display dialog' invocations in ${INSTALL_SH}. Either the dialogs moved to another mechanism (retarget this test at it) or the search string changed. A green result below would prove nothing."
    echo "=== ${pass} PASS  ${fail} FAIL ==="
    exit 1
fi

echo "=== 2. every dialog is preceded by 'activate' ==="
MISSING="$(unactivated_dialogs "$INSTALL_SH")"
if [[ -z "$MISSING" ]]; then
    ok "all ${DIALOGS} dialogs activate System Events first"
else
    bad "$(printf '%s\n' "$MISSING" | wc -l | tr -d ' ') dialog(s) with NO preceding activate -- they will render BEHIND System Settings and the customer will never see them (ba94a24 regression). install.sh lines:"
    while read -r ln; do
        [[ -n "$ln" ]] && printf '          install.sh:%s  %s\n' "$ln" "$(sed -n "${ln}p" "$INSTALL_SH" | cut -c1-90)"
    done <<< "$MISSING"
fi

echo "=== 3. NEGATIVE CONTROL: the predicate must detect a deleted activate ==="
MUTANT="$(mktemp "${TMPDIR:-/tmp}/ostler-dialog-mutant-XXXXXX")"
# Delete ONE activate -- and specifically one that is IMMEDIATELY FOLLOWED by a
# `display dialog`, which is the edit ba94a24 actually made, four times over.
#
# The first version of this control deleted the first `to activate` in the file
# full stop, and it went green: install.sh also activates System Settings and
# Finder, so the line it removed was never guarding a dialog. A mutation that
# does not create the defect cannot prove the predicate detects it -- the
# control was testing nothing, in exactly the way this whole test exists to
# stop. Caught by running it, not by reading it.
#
# One-line lookahead, so "the activate belonging to a dialog" is identified the
# same way the predicate in limb 2 pairs them.
awk '
    BEGIN { done = 0 }
    {
        lines[NR] = $0
    }
    END {
        for (i = 1; i <= NR; i++) {
            if (!done && lines[i] ~ /to activate/ && (i+1) <= NR && lines[i+1] ~ /to display dialog/) {
                done = 1
                continue
            }
            print lines[i]
        }
        if (!done) exit 3
    }
' "$INSTALL_SH" > "$MUTANT"
if [[ "$?" -eq 3 ]]; then
    bad "control could not be built: no 'activate' line is immediately followed by a 'display dialog'. Either limb 2 is passing for a reason other than the one claimed, or the pairing shape changed."
fi

if [[ "$(count_dialogs "$MUTANT")" != "$DIALOGS" ]]; then
    bad "control is unsound: mutating the file changed the dialog count ($(count_dialogs "$MUTANT") vs ${DIALOGS}). The awk deleted more than one line."
elif [[ -n "$(unactivated_dialogs "$MUTANT")" ]]; then
    ok "control fires: removing one activate makes the predicate go RED, so a green above is a real measurement"
else
    bad "CONTROL DEAD: the predicate stayed GREEN against a file with an activate deleted. It cannot detect the regression it exists for -- do not trust limb 2."
fi
rm -f "$MUTANT"

echo
echo "=== ${pass} PASS  ${fail} FAIL ==="
[[ "$fail" -eq 0 ]]
