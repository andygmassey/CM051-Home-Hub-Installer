#!/usr/bin/env bash
#
# tests/test_fda_modal_names_a_path_a_human_can_reach.sh
#
# WALK FINDING #1538 -- the Full Disk Access drag-in asked a human to drag
# an app they could not see. Measured on a human GUI walk (archie2, Mini,
# v1.0.68, 2026-09-05):
#
#   - the register-nudge could not confirm the TCC row (reading TCC.db needs
#     sudo -n, which a fresh install does not have), so the modal fell back
#     to drag-in on every fresh install -- which is every customer, once;
#   - the bundle to drag is ~/.ostler/OstlerAssistant.app, inside a
#     dot-directory the Finder file picker hides;
#   - the modal named no path at all.
#
# The fix is the cheapest shape that works: the modal NAMES the path with ~,
# puts it on the clipboard so ⌘⇧G then ⌘V reaches it, and points at a Finder
# window only when `open -R` actually opened one. Each claim follows an act,
# the #874(a) rule.
#
# THIS TEST LOCKS FOUR PROPERTIES, three of them behaviourally:
#
#   1. THE CATALOGUE CAN SAY IT. The three lines exist, carry the %s the
#      code fills, and the no-Finder line does not point at a Finder window.
#   2. THE PATH IS DERIVED, AND HUMAN. _ostler_fda_bundle_locator renders
#      the bundle path with $HOME as ~ (what ⌘⇧G accepts), leaves a path
#      outside $HOME alone, and refuses -- rc 1, prints nothing -- when
#      there is no bundle path, so nobody renders "The app is at:" alone.
#   3. THE CLIPBOARD CLAIM FOLLOWS THE ACT. _ostler_fda_path_line says the
#      path is on the clipboard ONLY when pbcopy exited 0 and received the
#      path; a failed pbcopy and a Mac with no pbcopy get the path alone.
#   4. THE INSTRUCTION AND THE ARTEFACT SHARE ONE VARIABLE. The path the
#      modal names is derived from ASSISTANT_APP_BUNDLE, and
#      ASSISTANT_APP_BUNDLE is the ditto destination the installer writes
#      the bundle to. They cannot drift apart without one edit reaching
#      both. This is the "names a path that exists in the artefact" proof
#      that is available before a box exists; the box itself is the walk.
#
# And two mutants, each proved LANDED by diff before its verdict:
#   M1  the clipboard claim is printed regardless of pbcopy's rc  -> 3 fails
#   M2  the locator returns a hardcoded path                       -> 2a fails
#       (2a uses a RENAMED bundle so a hardcode cannot coincide)
#
# Exit: 0 all cases passed, 1 a case failed, 2 could not run.
# BASH 3.2 clean: install.sh runs under /bin/bash on the customer's Mac.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
STRINGS_FILE="${REPO_ROOT}/install.sh.strings.en-GB.sh"
RC_FAIL=1
RC_CANNOT_RUN=2

cannot_run() {
    echo "" >&2
    echo "CANNOT-RUN: $1" >&2
    echo "  NOTHING was checked. This is not a pass." >&2
    exit "$RC_CANNOT_RUN"
}
fail() {
    echo "FAIL [$1]: $2" >&2
    exit "$RC_FAIL"
}
count() {   # $1 fixed string, $2 text -> lines containing it
    printf '%s\n' "$2" | grep -cF -- "$1"
}

[[ -f "$INSTALL_SH" ]]   || cannot_run "install.sh not found at $INSTALL_SH"
[[ -f "$STRINGS_FILE" ]] || cannot_run "string catalogue not found at $STRINGS_FILE"
command -v diff >/dev/null 2>&1 || cannot_run "diff not on PATH"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fdapath.XXXXXX")" \
    || cannot_run "could not create a scratch directory"
trap 'rm -rf "$WORK"' EXIT
# The fixture home lives under the scratch dir: the locator only needs a
# prefix to strip, and a literal home path in a test file is a PII-shaped
# string the pre-commit scan rightly refuses.
FAKE_HOME="${WORK}/home"

extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\) \\{" { inf = 1 }
        inf                    { print }
        inf && /^\}$/          { exit }
    ' "$INSTALL_SH"
}

# ═══════════════════════════════════════════════════════════════════
# case-1: the catalogue can say it
# ═══════════════════════════════════════════════════════════════════
for key in MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3_NO_FINDER \
           MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH \
           MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH_ON_CLIPBOARD; do
    if [[ "$(grep -c "^${key}=" "$STRINGS_FILE")" -ne 1 ]]; then
        fail case-1 "catalogue defines ${key} $(grep -c "^${key}=" "$STRINGS_FILE") times, wanted exactly 1"
    fi
done
# shellcheck disable=SC1090
. "$STRINGS_FILE" || cannot_run "could not source $STRINGS_FILE"
for key in MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3_NO_FINDER \
           MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH \
           MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH_ON_CLIPBOARD; do
    val="$(eval "printf '%s' \"\${${key}}\"")"
    [[ -n "$val" ]] || fail case-1 "${key} is defined but empty"
    if [[ "$(count '\n' "$val")" -ne 0 ]]; then
        fail case-1 "${key} carries a literal \\n, which Rule 0.9 forbids in catalogue values"
    fi
    if [[ "$(printf '%s' "$val" | grep -o '%s' | grep -c .)" -ne 1 ]]; then
        fail case-1 "${key} must carry exactly one %s for the code to fill: ${val}"
    fi
done
if [[ "$(count 'on your clipboard' "$MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH_ON_CLIPBOARD")" -ne 1 ]]; then
    fail case-1 "the ON_CLIPBOARD line does not say the path is on the clipboard: ${MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH_ON_CLIPBOARD}"
fi
if [[ "$(count 'clipboard' "$MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH")" -ne 0 ]]; then
    fail case-1 "the plain PATH line claims the clipboard, which is the line used when pbcopy FAILED: ${MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH}"
fi
if [[ "$(count '⌘⇧G' "$MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH_ON_CLIPBOARD")" -ne 1 ]]; then
    fail case-1 "the ON_CLIPBOARD line does not tell the customer the way in (⌘⇧G): ${MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH_ON_CLIPBOARD}"
fi
if [[ "$(count 'from the Finder window' "$MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3_NO_FINDER")" -ne 0 ]]; then
    fail case-1 "the NO_FINDER line points at a Finder window, which is the line used when open -R FAILED: ${MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3_NO_FINDER}"
fi
echo "PASS [case-1]: catalogue carries the path line, the on-clipboard line and an honest no-Finder line"

# ═══════════════════════════════════════════════════════════════════
# case-2: the path is derived, and human
# ═══════════════════════════════════════════════════════════════════
LOC_FN="${WORK}/locator.sh"
extract_fn '_ostler_fda_bundle_locator' > "$LOC_FN"
if ! grep -q '^_ostler_fda_bundle_locator() {' "$LOC_FN"; then
    fail case-2 "install.sh defines no _ostler_fda_bundle_locator helper. #1538 is exactly the absence of one: the modal named no path."
fi
if ! grep -q 'ASSISTANT_APP_BUNDLE' "$LOC_FN"; then
    fail case-2 "_ostler_fda_bundle_locator does not read ASSISTANT_APP_BUNDLE, so the path it names is not the path the installer wrote the bundle to"
fi

arm_2a() {   # inside HOME -> ~ form. A RENAMED bundle, so a hardcoded answer cannot coincide with the derived one.
    local out
    out="$(HOME="$FAKE_HOME" ASSISTANT_APP_BUNDLE="$FAKE_HOME/.ostler/Renamed.app" _ostler_fda_bundle_locator)"
    # shellcheck disable=SC2088  # a literal tilde is exactly what is being asserted
    [[ "$out" == "~/.ostler/Renamed.app" ]]
}
arm_2b() {   # outside HOME -> unchanged
    local out
    out="$(HOME="$FAKE_HOME" ASSISTANT_APP_BUNDLE=/opt/elsewhere/OstlerAssistant.app _ostler_fda_bundle_locator)"
    [[ "$out" == "/opt/elsewhere/OstlerAssistant.app" ]]
}
arm_2c() {   # no bundle path -> rc 1 and nothing printed
    local out rc
    out="$(HOME="$FAKE_HOME" ASSISTANT_APP_BUNDLE='' _ostler_fda_bundle_locator)"; rc=$?
    [[ "$rc" -eq 1 && -z "$out" ]]
}
# shellcheck disable=SC1090
. "$LOC_FN"
arm_2a || fail case-2 "a bundle under \$HOME was not rendered with ~ from its own name: got '$(HOME="$FAKE_HOME" ASSISTANT_APP_BUNDLE="$FAKE_HOME/.ostler/Renamed.app" _ostler_fda_bundle_locator)'"
arm_2b || fail case-2 "a bundle outside \$HOME was rewritten: got '$(HOME="$FAKE_HOME" ASSISTANT_APP_BUNDLE=/opt/elsewhere/OstlerAssistant.app _ostler_fda_bundle_locator)'"
arm_2c || fail case-2 "with no bundle path the locator did not refuse (rc 1, nothing printed); a caller would render 'The app is at:' followed by nothing"
echo "PASS [case-2]: the locator renders \$HOME as ~, leaves other paths alone, and refuses when there is nothing to name"

# ═══════════════════════════════════════════════════════════════════
# case-3: the clipboard claim follows the act
# ═══════════════════════════════════════════════════════════════════
LINE_FN="${WORK}/pathline.sh"
extract_fn '_ostler_fda_path_line' > "$LINE_FN"
if ! grep -q '^_ostler_fda_path_line() {' "$LINE_FN"; then
    fail case-3 "install.sh defines no _ostler_fda_path_line helper"
fi
STUB_BIN="${WORK}/bin"; mkdir -p "$STUB_BIN" "${WORK}/nobin"
cat > "${STUB_BIN}/pbcopy" <<'STUB'
#!/usr/bin/env bash
cat > "${STUB_PBCOPY_CAPTURE:-/dev/null}"
exit "${STUB_PBCOPY_RC:-0}"
STUB
chmod +x "${STUB_BIN}/pbcopy"
# shellcheck disable=SC2088  # the literal tilde form is what the modal shows
THE_PATH='~/.ostler/OstlerAssistant.app'

arm_3a() {   # pbcopy exits 0 -> path named, clipboard claimed, and the path really reached pbcopy
    local out cap
    cap="${WORK}/cap.a"; : > "$cap"
    out="$(PATH="${STUB_BIN}:${PATH}" STUB_PBCOPY_RC=0 STUB_PBCOPY_CAPTURE="$cap" _ostler_fda_path_line "$THE_PATH")"
    [[ "$(count "$THE_PATH" "$out")" -eq 1 ]] || return 1
    [[ "$(count 'on your clipboard' "$out")" -eq 1 ]] || return 1
    [[ "$(cat "$cap")" == "$THE_PATH" ]] || return 1
    return 0
}
arm_3b() {   # pbcopy exits 1 -> path named, NO clipboard claim
    local out
    out="$(PATH="${STUB_BIN}:${PATH}" STUB_PBCOPY_RC=1 _ostler_fda_path_line "$THE_PATH")"
    [[ "$(count "$THE_PATH" "$out")" -eq 1 ]] || return 1
    [[ "$(count 'clipboard' "$out")" -eq 0 ]] || return 1
    return 0
}
arm_3c() {   # no pbcopy on PATH at all -> path named, NO clipboard claim
    local out
    out="$(PATH="${WORK}/nobin" _ostler_fda_path_line "$THE_PATH")"
    [[ "$(count "$THE_PATH" "$out")" -eq 1 ]] || return 1
    [[ "$(count 'clipboard' "$out")" -eq 0 ]] || return 1
    return 0
}
# shellcheck disable=SC1090
. "$LINE_FN"
arm_3a || fail case-3 "with pbcopy succeeding, the line did not name the path, or did not claim the clipboard, or the path never reached pbcopy"
arm_3b || fail case-3 "with pbcopy FAILING, the line still claimed the clipboard -- a claim that precedes its act, the #874(a) shape"
arm_3c || fail case-3 "with NO pbcopy on PATH, the line still claimed the clipboard"
echo "PASS [case-3]: the clipboard sentence is printed only when pbcopy exited 0 and received the path"

# ═══════════════════════════════════════════════════════════════════
# case-4: the instruction and the artefact share one variable
# ═══════════════════════════════════════════════════════════════════
# shellcheck disable=SC2016  # the literal $ASSISTANT_APP_BUNDLE text is the subject
WRITE_SITES="$(grep -cE '^[[:space:]]*ditto[[:space:]].*"\$ASSISTANT_APP_BUNDLE"[[:space:]]*$' "$INSTALL_SH")"
ALL_DITTO="$(grep -cE '^[[:space:]]*ditto[[:space:]]' "$INSTALL_SH")"
if [[ "$ALL_DITTO" -eq 0 ]]; then
    cannot_run "install.sh has no ditto lines at all, so the write-site predicate cannot be exercised"
fi
if [[ "$WRITE_SITES" -lt 1 ]]; then
    fail case-4 "install.sh no longer writes the bundle with ditto to \"\$ASSISTANT_APP_BUNDLE\" (found 0 of ${ALL_DITTO} ditto lines). The path the modal names is derived from that variable; if the write moved, the instruction now names a path the artefact is not at."
fi
MODAL_BLOCK="$(awk '/_fda_finder_revealed=false/{on=1} on{print} /_imessage_fda_dialog_msg_esc=/{if(on) exit}' "$INSTALL_SH")"
[[ -n "$MODAL_BLOCK" ]] || cannot_run "could not isolate the drag-in modal block (from _fda_finder_revealed=false to _imessage_fda_dialog_msg_esc=)"
[[ "$(count '_ostler_fda_path_line' "$MODAL_BLOCK")" -ge 1 ]] \
    || fail case-4 "the drag-in modal body never calls _ostler_fda_path_line, so the path is derived and then not shown"
[[ "$(count 'MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3_NO_FINDER' "$MODAL_BLOCK")" -ge 1 ]] \
    || fail case-4 "the drag-in modal body never uses the no-Finder line, so a failed open -R is still followed by 'from the Finder window'"
# shellcheck disable=SC2016
[[ "$(count 'if open -R "$ASSISTANT_APP_BUNDLE"' "$MODAL_BLOCK")" -ge 1 ]] \
    || fail case-4 "open -R's exit status is not kept (no 'if open -R' in the modal block), so LINE3 cannot follow it"
[[ "$(count '&& _fda_finder_revealed=true || true' "$MODAL_BLOCK")" -eq 0 ]] \
    || fail case-4 "the fire-and-forget 'open -R ... && _fda_finder_revealed=true || true' form is back; its failure is swallowed"
echo "PASS [case-4]: the modal derives the path from the same variable the installer ditto's the bundle to (${WRITE_SITES} write site(s) of ${ALL_DITTO} ditto lines), shows it, and lets LINE3 follow open -R"

# ═══════════════════════════════════════════════════════════════════
# case-5: bash 3.2 parses the helpers (install.sh runs under /bin/bash)
# ═══════════════════════════════════════════════════════════════════
if [[ -x /bin/bash ]]; then
    /bin/bash -n "$LOC_FN"  || fail case-5 "the locator does not parse under /bin/bash ($(/bin/bash --version | head -1))"
    /bin/bash -n "$LINE_FN" || fail case-5 "the path line does not parse under /bin/bash ($(/bin/bash --version | head -1))"
    echo "PASS [case-5]: both helpers parse under /bin/bash ($(/bin/bash --version | head -1 | sed 's/GNU bash, version //'))"
else
    echo "NOTE [case-5]: no /bin/bash here; the 3.2 parse arm was NOT measured"
fi

# ═══════════════════════════════════════════════════════════════════
# case-6: mutants -- each arm above must be load-bearing
# ═══════════════════════════════════════════════════════════════════
mutate() {   # $1 source fn file, $2 sed expr, $3 out file -> rc 2 if it did not land
    local changed
    sed -e "$2" "$1" > "$3"
    changed="$(diff "$1" "$3" | grep -c '^>')"
    [[ "$changed" -eq 1 ]] || { echo "  mutant did not land: ${changed} changed line(s), wanted 1" >&2; return 2; }
}
# M1: the clipboard claim no longer follows pbcopy's rc.
# shellcheck disable=SC2016
mutate "$LINE_FN" 's/if \[\[ "\$_clip_rc" -eq 0 \]\]; then/if true; then/' "${WORK}/m1.sh" \
    || cannot_run "mutant M1 did not land in the extracted _ostler_fda_path_line"
# shellcheck disable=SC1091
if ( . "${WORK}/m1.sh"; arm_3b ); then
    fail case-6 "mutant M1 SURVIVED: with the clipboard claim unconditional, arm 3b still passed, so arm 3b is decoration"
fi
# M2: the locator returns a hardcoded path.
# shellcheck disable=SC2016
mutate "$LOC_FN" 's|printf '"'"'~%s'"'"' "\${_bundle#"\${HOME}"}"|printf '"'"'~/.ostler/OstlerAssistant.app'"'"'|' "${WORK}/m2.sh" \
    || cannot_run "mutant M2 did not land in the extracted _ostler_fda_bundle_locator"
# shellcheck disable=SC1091
if ( . "${WORK}/m2.sh"; arm_2a ); then
    fail case-6 "mutant M2 SURVIVED: with a hardcoded path, arm 2a still passed, so the derivation is not what it measures"
fi
echo "PASS [case-6]: both mutants killed (M1 by arm 3b, M2 by arm 2a)"

echo ""
echo "ALL #1538 FDA-MODAL-PATH TESTS PASSED"
exit 0
