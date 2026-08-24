#!/usr/bin/env bash
#
# tests/test_fda_dialog_tells_the_truth.sh
#
# WALK FINDING #874 -- the Full Disk Access modal stated two things that
# were not true. Measured live by Andy on the v1.0.44 upgrade walk,
# 2026-08-24 ~18:13 HKT, at step 26/37:
#
#   (a) The modal opened with "System Settings is open at Full Disk
#       Access." System Settings was NOT open. Andy opened it himself.
#       The copy ASSERTED a state of the world instead of ESTABLISHING
#       it. Same class as #876: an action whose failure is swallowed
#       (`open ... 2>/dev/null || true`) followed by an unconditional
#       success sentence.
#
#   (b) The modal said: Find "Ostler" in the list -- and the helper line
#       added "Ostler is already listed". The row macOS actually shows
#       is OstlerAssistant. A customer scanning for "Ostler" concludes
#       it is absent and goes hunting in Finder, which the same helper
#       text has just told them not to do.
#
# THIS TEST LOCKS TWO PROPERTIES, both behaviourally, not by grepping
# for today's wording:
#
#   1. THE CLAIM FOLLOWS REALITY. The line that says the pane is open is
#      PRODUCED BY the act of opening it, and only when the open both
#      exited 0 AND a System Settings process was observed. `open`
#      exiting 0 is not proof a window appeared; that arm is tested.
#
#   2. THE NAME IS DERIVED. The name quoted in the copy comes from the
#      assistant .app bundle path, so a rename of the bundle moves the
#      copy with it. Proved by MUTATION: point the derivation at a
#      bundle called ZzMutantAssistant.app and require the rendered copy
#      to carry that name and no other. A hardcoded string that happens
#      to match today cannot pass that.
#
# NOT IN SCOPE (limb (c) of the finding): Andy found the FDA switch
# already ON and had to toggle it off/on before Done -- the known
# workaround for a TCC grant that survives by name but no longer
# matches a replaced binary. That needs adjudication on real hardware.
#
# Exit codes:
#   0  every property holds
#   1  a property is broken (FAIL)
#   3  CANNOT-RUN -- something the test depends on was absent, so
#      NOTHING was measured. This is not a pass.

set -uo pipefail

RC_OK=0
RC_FAIL=1
RC_CANNOT_RUN=3

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
STRINGS_FILE="${REPO_ROOT}/install.sh.strings.en-GB.sh"

# The deep link the installer uses to reach the Full Disk Access pane.
FDA_PANE_URL='x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles'

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

[[ -f "$INSTALL_SH" ]]   || cannot_run "install.sh not found at $INSTALL_SH"
[[ -f "$STRINGS_FILE" ]] || cannot_run "string catalogue not found at $STRINGS_FILE"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fdatruth.XXXXXX")" \
    || cannot_run "could not create a scratch directory"
trap 'rm -rf "$WORK"' EXIT

# ── extraction ─────────────────────────────────────────────────────
# Pull a top-level function out of install.sh by name. install.sh's
# helpers are defined at column 0 and closed by a bare `}` at column 0,
# so this is exact rather than heuristic.
extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\) \\{" { inf = 1 }
        inf                    { print }
        inf && /^\}$/          { exit }
    ' "$INSTALL_SH"
}

# ═══════════════════════════════════════════════════════════════════
# Case 1 -- the catalogue carries a line for the case where the pane
#           did NOT open, and that line does not claim it did.
# ═══════════════════════════════════════════════════════════════════
if ! grep -q '^MSG_PROMPT_FDA_PANE_OPEN_FAILED_LINE1=' "$STRINGS_FILE"; then
    fail case-1 "catalogue has no MSG_PROMPT_FDA_PANE_OPEN_FAILED_LINE1.
  When the pane cannot be opened the modal still needs something true to
  say. Without this key the only line available is the one that claims
  System Settings is already open -- which is finding #874(a)."
fi
# shellcheck disable=SC1090
. "$STRINGS_FILE" || cannot_run "could not source $STRINGS_FILE"
if [[ -z "${MSG_PROMPT_FDA_PANE_OPEN_FAILED_LINE1:-}" ]]; then
    fail case-1 "MSG_PROMPT_FDA_PANE_OPEN_FAILED_LINE1 is defined but empty"
fi
# It must ESTABLISH, not ASSERT: it may not tell the customer the pane
# is already open, because on this branch it is not.
if printf '%s' "$MSG_PROMPT_FDA_PANE_OPEN_FAILED_LINE1" | grep -qi 'is open'; then
    fail case-1 "the pane-did-not-open line still claims the pane is open:
  ${MSG_PROMPT_FDA_PANE_OPEN_FAILED_LINE1}"
fi
echo "PASS [case-1]: catalogue carries an honest pane-did-not-open line"

# ═══════════════════════════════════════════════════════════════════
# Case 2 -- BEHAVIOURAL: the claim follows reality.
#
# Extract the two helpers, source them against the real catalogue, and
# drive them with a stubbed `open` and a stubbed `pgrep`. Three arms:
#
#   A  open fails                        -> must NOT claim
#   B  open exits 0, no process appears  -> must NOT claim   <-- #874(a)
#   C  open exits 0, process appears     -> MUST claim       <-- control
#
# Arm C is the control: it proves the predicate can still say yes, so a
# green A and B cannot be the result of a helper that always refuses.
# ═══════════════════════════════════════════════════════════════════
OPEN_FN="${WORK}/open_fn.sh"
extract_fn '_ostler_open_fda_pane' > "$OPEN_FN"
extract_fn '_ostler_fda_pane_line1' >> "$OPEN_FN"
if ! grep -q '_ostler_open_fda_pane() {' "$OPEN_FN"; then
    fail case-2 "install.sh defines no _ostler_open_fda_pane helper.
  #874(a) is exactly the absence of one: the pane open is fire-and-forget
  (\`open ... 2>/dev/null || true\`) and the success sentence is printed
  unconditionally afterwards."
fi
if ! grep -q '_ostler_fda_pane_line1() {' "$OPEN_FN"; then
    fail case-2 "install.sh defines no _ostler_fda_pane_line1 helper.
  The line that claims the pane is open must be PRODUCED BY the act of
  opening it, so that no call site can print the claim without having
  tried -- and verified -- the open first."
fi

# Stub PATH. `open` and `pgrep` are resolved by name inside the helper,
# so a directory in front of PATH replaces both.
STUB_BIN="${WORK}/bin"
mkdir -p "$STUB_BIN"
cat > "${STUB_BIN}/open" <<'STUB'
#!/bin/sh
if [ "${STUB_OPEN_RC:-0}" -ne 0 ]; then
    echo "stub open: refusing to open $*" >&2
fi
exit "${STUB_OPEN_RC:-0}"
STUB
cat > "${STUB_BIN}/pgrep" <<'STUB'
#!/bin/sh
if [ "${STUB_PGREP_RC:-1}" -eq 0 ]; then
    echo 4242
fi
exit "${STUB_PGREP_RC:-1}"
STUB
chmod +x "${STUB_BIN}/open" "${STUB_BIN}/pgrep"

# Drive one arm. Prints the rendered line-1 on stdout; the helper's log
# output lands in $2 so we can prove a failure was RECORDED, not
# swallowed.
run_arm() {
    local _open_rc="$1" _pgrep_rc="$2" _logfile="$3"
    : > "$_logfile"
    STUB_OPEN_RC="$_open_rc" STUB_PGREP_RC="$_pgrep_rc" \
    OSTLER_FDA_TEST_LOG="$_logfile" \
    PATH="${STUB_BIN}:${PATH}" \
    bash -c '
        set -uo pipefail
        # shellcheck disable=SC1090
        . "$1"          # catalogue
        gui_log() { printf "%s\n" "$*" >> "$OSTLER_FDA_TEST_LOG"; }
        # shellcheck disable=SC1090
        . "$2"          # extracted helpers
        _ostler_fda_pane_line1 "$3" "$4"
    ' _ "$STRINGS_FILE" "$OPEN_FN" "$FDA_PANE_URL" \
      "${MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE1:-}"
}

CLAIM="${MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE1:-}"
if [[ -z "$CLAIM" ]]; then
    cannot_run "MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE1 is not in the catalogue; there is no claim to test"
fi

# Arm A -- open fails outright.
ARM_A_LOG="${WORK}/arm_a.log"
ARM_A="$(run_arm 1 1 "$ARM_A_LOG")"
if [[ "$ARM_A" == "$CLAIM" ]]; then
    fail case-2A "\`open\` failed and the modal still claimed the pane is open.
  rendered: ${ARM_A}"
fi
if [[ "$ARM_A" != "$MSG_PROMPT_FDA_PANE_OPEN_FAILED_LINE1" ]]; then
    fail case-2A "\`open\` failed but the modal did not fall back to the
  pane-did-not-open line.
  rendered: ${ARM_A}
  expected: ${MSG_PROMPT_FDA_PANE_OPEN_FAILED_LINE1}"
fi
if [[ ! -s "$ARM_A_LOG" ]]; then
    fail case-2A "the failed \`open\` was not logged. A swallowed failure is
  how #874(a) survived a walk: read stderr, record it."
fi
echo "PASS [case-2A]: open fails -> no claim, and the failure is logged"

# Arm B -- open exits 0 but System Settings never appears. This is the
# arm that matches what Andy saw: a command that returned success and a
# window that was not there.
ARM_B_LOG="${WORK}/arm_b.log"
ARM_B="$(run_arm 0 1 "$ARM_B_LOG")"
if [[ "$ARM_B" == "$CLAIM" ]]; then
    fail case-2B "\`open\` exited 0 but no System Settings process ever
  appeared, and the modal claimed the pane is open anyway.
  Exit 0 from \`open\` means LaunchServices accepted the URL. It is not
  proof a window exists -- that is finding #874(a).
  rendered: ${ARM_B}"
fi
if [[ ! -s "$ARM_B_LOG" ]]; then
    fail case-2B "\`open\` exited 0 with no window and nothing was logged"
fi
echo "PASS [case-2B]: open exits 0 with no window -> no claim, and it is logged"

# Arm C -- CONTROL. The predicate must still be able to say yes.
ARM_C_LOG="${WORK}/arm_c.log"
ARM_C="$(run_arm 0 0 "$ARM_C_LOG")"
if [[ "$ARM_C" != "$CLAIM" ]]; then
    fail case-2C "CONTROL BROKEN: the pane opened and a System Settings
  process was observed, yet the modal still refused to say so.
  A helper that never claims would pass arms A and B for the wrong
  reason, so this arm must be green for those two to mean anything.
  rendered: ${ARM_C}
  expected: ${CLAIM}"
fi
echo "PASS [case-2C]: control -- open succeeds and the process is seen -> the claim is made"

# ═══════════════════════════════════════════════════════════════════
# Case 3 -- ORDERING, at every call site.
#
# The claim may only be reached THROUGH the opener. Assert that every
# reference to a "System Settings is open" catalogue key in install.sh
# sits on a _ostler_fda_pane_line1 invocation, and that the invocation
# carries the FDA deep link. That is the ordering invariant expressed
# structurally: you cannot render the sentence without having run the
# open first.
# ═══════════════════════════════════════════════════════════════════
# The key set is DERIVED FROM THE CATALOGUE BY SHAPE, not hand-listed.
# Hand-listing is how the third one survived: the same assertion was
# buried mid-sentence in MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE1 --
# "in System Settings (now open at Full Disk Access)" -- and a key list
# built from the two obvious LINE1 keys walked straight past it.
CLAIM_KEYS="$(grep -oiE '^MSG_[A-Z0-9_]+=.*open at Full Disk Access' "$STRINGS_FILE" \
              | cut -d= -f1 | sort -u | paste -sd'|' - )"
if [[ -z "$CLAIM_KEYS" ]]; then
    cannot_run "no catalogue string asserts the pane is open, so the ordering
  check has nothing to measure. Either the wording changed shape (widen the
  predicate) or the keys were deleted rather than made honest."
fi
# Measure LOGICAL lines, not physical ones. These invocations are
# written across three physical lines with backslash continuations, so a
# per-physical-line predicate reports the argument and the call as
# unrelated and fails a correct tree -- a green-while-blind /
# red-while-fixed predicate pinned to formatting.
LOGICAL="${WORK}/install.logical"
awk '
    { line = $0; sub(/[[:space:]]+$/, "", line) }
    buf == ""            { start = NR }
    line ~ /\\$/         { sub(/\\$/, "", line); buf = buf line; next }
                         { print start ":" buf line; buf = "" }
    END                  { if (buf != "") print start ":" buf }
' "$INSTALL_SH" > "$LOGICAL"
[[ -s "$LOGICAL" ]] || cannot_run "could not build a logical-line view of install.sh"
CLAIM_REFS="$(grep -nE "\\\$\{?(${CLAIM_KEYS})\}?" "$LOGICAL" | cut -d: -f2- || true)"
CLAIM_REF_N="$(printf '%s' "$CLAIM_REFS" | grep -c . )"
if [[ "${CLAIM_REF_N:-0}" -eq 0 ]]; then
    cannot_run "no reference to either pane-is-open catalogue key was found in install.sh;
  the ordering check had nothing to measure (renamed keys?)"
fi
UNGUARDED=""
while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    if ! printf '%s' "$ref" | grep -q '_ostler_fda_pane_line1'; then
        UNGUARDED="${UNGUARDED}    ${ref}
"
    fi
done <<EOF
$CLAIM_REFS
EOF
if [[ -n "$UNGUARDED" ]]; then
    echo "FAIL [case-3]: ${CLAIM_REF_N} reference(s) to the pane-is-open copy; these are not produced by the opener:" >&2
    printf '%s' "$UNGUARDED" >&2
    echo "  Every such line must be an argument to _ostler_fda_pane_line1, which" >&2
    echo "  opens the pane, verifies it, and only then returns this sentence." >&2
    exit "$RC_FAIL"
fi
# ...and each of those invocations must actually pass the FDA deep link,
# not some other URL.
PANE_CALLS="$(grep -c '_ostler_fda_pane_line1 ' "$INSTALL_SH" || true)"
if [[ "${PANE_CALLS:-0}" -lt 1 ]]; then
    fail case-3 "no _ostler_fda_pane_line1 call sites found"
fi
if ! grep -q "_ostler_fda_pane_line1 .*Privacy_AllFiles" "$INSTALL_SH" \
   && ! grep -A2 '_ostler_fda_pane_line1' "$INSTALL_SH" | grep -q 'Privacy_AllFiles'; then
    fail case-3 "the _ostler_fda_pane_line1 call sites do not pass the Full Disk Access deep link"
fi
echo "PASS [case-3]: all ${CLAIM_REF_N} pane-is-open reference(s) are produced by the opener (${PANE_CALLS} call site(s))"

# ── Case 3b -- the mechanism, not just today's wording ─────────────
# Copy can be reworded; the mechanism must not be reintroduced. No call
# site may open the Full Disk Access pane with a bare fire-and-forget
# `open`. Every pane open goes through the verifying helper, so a future
# edit cannot get back to "opened it, ignored the result, claimed
# success" without deleting this test.
BARE_OPENS="$(grep -nE '^[[:space:]]*open[[:space:]]+"x-apple\.systempreferences.*Privacy_AllFiles' "$INSTALL_SH" || true)"
if [[ -n "$BARE_OPENS" ]]; then
    echo "FAIL [case-3b]: the Full Disk Access pane is opened fire-and-forget here:" >&2
    printf '%s\n' "$BARE_OPENS" >&2
    echo "  Route it through _ostler_open_fda_pane / _ostler_fda_pane_line1 so the" >&2
    echo "  exit status is read, stderr is logged, and the copy matches the result." >&2
    exit "$RC_FAIL"
fi
echo "PASS [case-3b]: no fire-and-forget pane opens remain in install.sh"

# ═══════════════════════════════════════════════════════════════════
# Case 4 -- BEHAVIOURAL: the quoted name is DERIVED from the bundle.
#
# MUTATION. Point the derivation at a bundle called ZzMutantAssistant.app
# and require every naming string to carry that name and nothing else.
# A copy that hardcodes any product name fails this by construction.
# ═══════════════════════════════════════════════════════════════════
NAME_FN="${WORK}/name_fn.sh"
extract_fn '_ostler_fda_entry_name' > "$NAME_FN"
if ! grep -q '_ostler_fda_entry_name() {' "$NAME_FN"; then
    fail case-4 "install.sh defines no _ostler_fda_entry_name helper.
  #874(b) is the absence of one: the row name is typed into the copy as
  \"Ostler\" while the row macOS shows is OstlerAssistant."
fi

# The three strings that name the row for the customer.
NAMING_KEYS="MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE2 MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3 MSG_INFO_IMESSAGE_FDA_ALREADY_LISTED"

render_naming() {
    # $1 = bundle path to derive from. Emits every naming string,
    # rendered exactly as install.sh renders them.
    local _bundle="$1"
    OSTLER_FDA_TEST_LOG="${WORK}/name.log" \
    ASSISTANT_APP_BUNDLE="$_bundle" \
    bash -c '
        set -uo pipefail
        # shellcheck disable=SC1090
        . "$1"
        gui_log() { printf "%s\n" "$*" >> "$OSTLER_FDA_TEST_LOG"; }
        # shellcheck disable=SC1090
        . "$2"
        _n="$(_ostler_fda_entry_name)" || exit 9
        shift 2
        for _k in "$@"; do
            eval "_v=\${${_k}:-}"
            [ -n "$_v" ] || { echo "MISSING-KEY:${_k}"; continue; }
            # Exactly ONE argument: printf reuses the format string when
            # given more, which would silently render the line 3x and
            # mask a key that carries no placeholder at all.
            # shellcheck disable=SC2059
            printf "$_v" "$_n"
            printf "\n"
        done
    ' _ "$STRINGS_FILE" "$NAME_FN" $NAMING_KEYS
}

MUTANT_BUNDLE="${WORK}/fake-ostler-dir/ZzMutantAssistant.app"
mkdir -p "$MUTANT_BUNDLE"
MUTANT_RENDER="$(render_naming "$MUTANT_BUNDLE")" \
    || cannot_run "could not render the naming strings against the mutated bundle"
if printf '%s' "$MUTANT_RENDER" | grep -q 'MISSING-KEY:'; then
    fail case-4 "catalogue is missing a naming key:
$(printf '%s' "$MUTANT_RENDER" | grep 'MISSING-KEY:')"
fi
MUTANT_LINES="$(printf '%s' "$MUTANT_RENDER" | grep -c . )"
if [[ "${MUTANT_LINES:-0}" -lt 3 ]]; then
    cannot_run "expected 3 rendered naming strings, got ${MUTANT_LINES}; nothing meaningful was measured"
fi
while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if ! printf '%s' "$line" | grep -q 'ZzMutantAssistant'; then
        fail case-4 "the bundle was renamed to ZzMutantAssistant.app and this
  customer-facing line did not follow it:
    ${line}
  The name must be derived from the bundle, not typed into the catalogue.
  A hardcoded string that happens to match today is not a fix."
    fi
    if printf '%s' "$line" | grep -q 'Ostler'; then
        fail case-4 "the bundle was renamed to ZzMutantAssistant.app but this
  line still names an Ostler bundle:
    ${line}"
    fi
done <<EOF
$MUTANT_RENDER
EOF
echo "PASS [case-4]: all ${MUTANT_LINES} naming strings follow a renamed bundle (mutation: ZzMutantAssistant.app)"

# ═══════════════════════════════════════════════════════════════════
# Case 5 -- the derivation reproduces what the walk actually saw.
#
# Andy's pane read "OstlerAssistant". The shipped bundle is
# OstlerAssistant.app. Deriving from the bundle file name must yield
# exactly that -- otherwise case-4 would be satisfiable by a derivation
# that is consistent but wrong.
# ═══════════════════════════════════════════════════════════════════
REAL_BUNDLE="${WORK}/fake-ostler-dir/OstlerAssistant.app"
mkdir -p "$REAL_BUNDLE"
REAL_RENDER="$(render_naming "$REAL_BUNDLE")" \
    || cannot_run "could not render the naming strings against the shipped bundle name"
while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if ! printf '%s' "$line" | grep -q 'OstlerAssistant'; then
        fail case-5 "with the shipped bundle (OstlerAssistant.app) this line
  does not name the row the customer is looking at:
    ${line}
  Andy's Full Disk Access pane read OstlerAssistant on 2026-08-24."
    fi
done <<EOF
$REAL_RENDER
EOF
echo "PASS [case-5]: the shipped bundle derives the name Andy actually saw (OstlerAssistant)"

# ═══════════════════════════════════════════════════════════════════
# Case 6 -- the derivation has an input. _ostler_set_paths must assign
#           ASSISTANT_APP_BUNDLE, or the name has nothing to come from.
# ═══════════════════════════════════════════════════════════════════
if ! extract_fn '_ostler_set_paths' | grep -q '^[[:space:]]*ASSISTANT_APP_BUNDLE='; then
    fail case-6 "_ostler_set_paths no longer assigns ASSISTANT_APP_BUNDLE;
  the Full Disk Access row name is derived from it and would be empty."
fi
echo "PASS [case-6]: _ostler_set_paths assigns ASSISTANT_APP_BUNDLE"

# ═══════════════════════════════════════════════════════════════════
# Case 7 -- install.sh stays syntax-clean, on the bash that ships it.
#
# Customer Macs run /bin/bash 3.2. Checking only the bash on PATH would
# pass a bash-4 construct straight onto the launch path.
# ═══════════════════════════════════════════════════════════════════
if ! bash -n "$INSTALL_SH"; then
    fail case-7 "bash -n install.sh reported a syntax error"
fi
if [[ -x /bin/bash ]]; then
    if ! /bin/bash -n "$INSTALL_SH"; then
        fail case-7 "/bin/bash -n install.sh reported a syntax error (this is the bash that runs on a customer Mac)"
    fi
    echo "PASS [case-7]: install.sh parses under both $(bash --version | head -1 | awk '{print $4}') and /bin/bash $(/bin/bash --version | head -1 | awk '{print $4}')"
else
    echo "PASS [case-7]: install.sh parses under $(bash --version | head -1 | awk '{print $4}') (no /bin/bash on this host)"
fi

echo ""
echo "ALL WALK #874 FDA-DIALOG-HONESTY TESTS PASSED"
exit "$RC_OK"
