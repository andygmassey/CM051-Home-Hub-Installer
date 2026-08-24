#!/bin/bash
# #876 / #800 -- A LAUNCHAGENT SUCCESS LINE MUST BE BACKED BY launchd.
#
# THE DEFECT. On Andy's 2026-08-24 v1.0.44 walk the installer printed
#
#     [ok]    Ostler Doctor running at http://localhost:8089/doctor
#
# while com.ostler.doctor was NOT LOADED and :8089 answered 000. Preferences,
# Governor, Doctor > Channels, People, Timeline and every status header in the
# app were dark behind that one reassuring line, and the install log said the
# run was fine. The wiki in the SAME app was showing 6,932 people, so the data
# was there the whole time -- the only thing broken was what the installer
# claimed.
#
# WHY THE SHAPE CANNOT BE TRUSTED, in two independent ways:
#
#   1. `launchctl bootstrap … || launchctl load … || true` then a bare
#      `ok "$MSG_…"`. The `|| true` terminates the chain, so there is no path
#      through those lines that does NOT print the success message.
#
#   2. Even without the `|| true`, branching on the exit status does not work.
#      Measured on macOS 26.5.2: `launchctl load /path/that/does/not/exist`
#      prints "Load failed: 5: Input/output error" to stderr and EXITS 0.
#      So `if bootstrap || load; then ok; else warn; fi` is ALSO true
#      unconditionally whenever `load` is the fallback arm, and its `else` is
#      unreachable code that has never once run.
#
# The ical-server site was worse than either: `|| warn "…FAILED"` inside the
# chain, then an unconditional `ok "…INSTALLED"` on the next line. A customer
# whose ical-server failed to load was told both, one line apart.
#
# WHAT THIS GATE ASSERTS. Not the wording -- copy gets improved, and a gate
# pinned to a sentence goes green-while-blind the day someone rewrites it. It
# asserts the STRUCTURE: no success announcement may be reachable from a
# `launchctl bootstrap`/`load` without launchd having been asked, via
# `launchctl print`, whether the label is actually registered. In practice
# that means going through _ostler_launchagent_load_verified.
#
# WHY A CLASS GATE AND NOT TWELVE FIXES. My first hand-inventory of this class
# found eleven sites. This predicate found TWELVE -- the ical-server one, the
# worst of the set, was missed by the eye. That is the argument for the gate:
# the thirteenth site is the one nobody counts.
#
# EXIT CODES
#   0  every control passed
#   1  at least one control failed
#   2  CANNOT-RUN. Nothing was checked, which is not a pass.
#
# --self-test  reinstate the exact pre-fix Doctor block in a COPY of install.sh
#              and require the scan to go RED on it. A control that has never
#              been observed failing is not evidence that it can fail.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"
STRINGS="${REPO}/install.sh.strings.en-GB.sh"
HELPER="_ostler_launchagent_load_verified"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
cannot_run() { printf '\nCANNOT-RUN: %s\n' "$1" >&2; exit 2; }

[[ -f "$INSTALL_SH" ]] || cannot_run "no install.sh at ${INSTALL_SH}"
[[ -f "$STRINGS" ]]    || cannot_run "no strings catalogue at ${STRINGS}"
command -v python3 >/dev/null 2>&1 || cannot_run "no python3"

SELF_TEST=0
[[ "${1:-}" == "--self-test" ]] && SELF_TEST=1

# ---------------------------------------------------------------------------
# THE SCANNER. Emits one line per unverified announcement, plus a DENOMINATOR
# line so a rename or a refactor cannot make this gate vacuously green.
#
# For each `launchctl bootstrap|load` line, walk forward. Blank lines and
# comments are skipped -- they carry no control flow. The walk stops at any
# line that either establishes the evidence (`launchctl print`, a call to the
# helper) or transfers control (`if`/`elif`/`else`/`fi`/`}`). If a success
# announcement (`ok` or `progress`) is reached before any of those, the
# message is being printed without launchd having been consulted.
# ---------------------------------------------------------------------------
_scan() {
    python3 - "$1" "$HELPER" <<'PY'
import re, sys
path, helper = sys.argv[1], sys.argv[2]
src = open(path).read().split('\n')
# A LOAD ATTEMPT. Tolerates a line continuation and an indirected binary
# (`"$LCTL" bootstrap`), both of which previously slipped the pattern AND
# zeroed the denominator -- so the anti-vacuity floor could not notice either.
LC      = re.compile(r'(?:launchctl|\$\{?\w+\}?|"\$\{?\w+\}?")\s*\\?\s*'
                     r'(?:\n\s*)?(bootstrap|load)\s')

# `progress` was noise: it is a narration verb, not a success claim. Dropped.
# A WRAPPER counts: `ok_loaded "$MSG"` announces just as hard as `ok "$MSG"`.
ANNOUNCE= re.compile(r'^\s*(ok|ok_\w+)\s')

# WHAT ENDS THE WALK.
#
# 🔴 `if|elif|else|fi|}` USED TO BE IN HERE AND THAT WAS THE BUG. The walk
# halted at `fi`, so an `ok` sitting AFTER a closed block was never reached --
# and an announcement after `fi` is precisely the shape that fires on the
# branch that just warned. install.sh:15858 was a LIVE instance of #876 that
# this gate scored 0 on, by construction. Archie2 found it by reading, not by
# running the gate, which is the whole lesson: the instrument and the defect
# did not share a surface.
#
# Only real EVIDENCE stops the walk now: a verification call, or the helper.
STOP    = re.compile(r'launchctl\s+print|' + re.escape(helper))
SKIP    = re.compile(r'^\s*#|^\s*$')
sites = 0
# ONE FINDING PER FALSE ANNOUNCEMENT, not per matching launchctl line. The
# shipped shape spans two lines --
#     launchctl bootstrap … || \
#         launchctl load … || true
# -- and both reach the same `ok`. Counting them separately makes one defect
# read as two, which breaks any control that asserts the count moved by one.
# Dedupe on the ANNOUNCEMENT line; that is the thing the customer sees.
seen_announcements = set()
for n, line in enumerate(src):
    if not LC.search(line):
        continue
    sites += 1
    for j in range(n + 1, min(n + 9, len(src))):
        nxt = src[j]
        if SKIP.match(nxt):
            continue
        if STOP.search(nxt):
            break
        if ANNOUNCE.match(nxt):
            if j not in seen_announcements:
                seen_announcements.add(j)
                print(f"UNVERIFIED\t{n+1}\t{line.strip()[:90]}\t{j+1}\t{nxt.strip()[:90]}")
            break
print(f"DENOMINATOR\t{sites}")
PY
}

_run_controls() {
    local target="$1" label="$2"
    local out
    # 🔴 A REFUSAL THAT HAPPENS IN A SUBSHELL CANNOT REFUSE.
    #
    # This line used to read `… || cannot_run "the scanner itself failed"`.
    # _run_controls is invoked as `X="$(_run_controls …)"`, so that exit 2
    # killed the COMMAND SUBSTITUTION and not the script. It is the same trap
    # that left OS003's capability_matrix.sh printing "unknown repo" seven
    # times and exiting 0 -- and the same family as #876 itself: an error is
    # emitted, the process reports success.
    #
    # MEASURED, and it partly acquits this file: stubbing _scan to `return 1`
    # exits 2 anyway, because the anti-vacuity floor below runs in the MAIN
    # shell and catches a zero denominator first. But that is a SIBLING guard
    # catching it, not this one -- and a control satisfied by a sibling is not
    # a control. The residual was real: on the SELF-TEST path the floor has
    # already passed, so a scanner that failed only on the temp tree returned
    # empty, `[[ "" -ge 1 ]]` was false, and CANNOT-RUN was reported as FAIL.
    #
    # So: emit a sentinel on stdout and let the MAIN SHELL refuse.
    if ! out="$(_scan "$target")"; then
        printf 'SCANNER_FAILED'
        return 0
    fi

    local denom
    denom="$(printf '%s\n' "$out" | awk -F'\t' '$1=="DENOMINATOR"{print $2}')"
    local unverified
    unverified="$(printf '%s\n' "$out" | grep -c '^UNVERIFIED' || true)"

    # Diagnostics go to STDERR. Stdout carries the COUNT and nothing else --
    # a caller doing arithmetic on this must not be handed prose. (The first
    # run of this gate did exactly that and died with "REAL: unbound
    # variable", which is the instrument-lies family it was written to catch.)
    {
        printf '\n%s\n' "$label"
        printf '  launchctl bootstrap/load sites scanned : %s\n' "$denom"
        printf '  announcements not backed by launchd    : %s\n' "$unverified"
        printf '%s\n' "$out" | grep '^UNVERIFIED' | while IFS=$'\t' read -r _ ln src_line aln aline; do
            printf '    L%s  %s\n         -> L%s  %s\n' "$ln" "$src_line" "$aln" "$aline"
        done
    } >&2

    printf '%s' "$unverified"
}

echo "CM051 LaunchAgent success-verification gate"

# --- ANTI-VACUITY. A gate that scans nothing passes everything. ------------
DENOM="$(_scan "$INSTALL_SH" | awk -F'\t' '$1=="DENOMINATOR"{print $2}')"
if [[ -z "$DENOM" || "$DENOM" -lt 20 ]]; then
    cannot_run "only ${DENOM:-0} launchctl bootstrap/load sites found in install.sh. \
The installer has ~33. Either the file moved or the pattern was renamed -- \
either way nothing meaningful was measured, and that is not a pass."
fi

# --- CONTROL 1: no unverified announcements on the real file. --------------
UNVERIFIED="$(_run_controls "$INSTALL_SH" "REAL CHECK -- install.sh as it ships")"
# THE REFUSAL HAPPENS HERE, IN THE MAIN SHELL, WHERE EXIT 2 MEANS SOMETHING.
[[ "$UNVERIFIED" == "SCANNER_FAILED" ]] && cannot_run \
    "the scanner failed on ${INSTALL_SH}. Nothing was measured, which is not a pass."
if [[ "$UNVERIFIED" -eq 0 ]]; then
    pass "every LaunchAgent success line is gated on launchd (${DENOM} sites scanned)"
else
    bad "${UNVERIFIED} success announcement(s) print without asking launchd -- this is #876"
fi

# --- CONTROL 2: the helper exists and its verdict IS launchctl print. ------
# Without this, someone can satisfy control 1 by gutting the helper into a
# function that returns 0 unconditionally, and the whole gate goes green over
# the original defect wearing a new name.
if ! grep -q "^${HELPER}() {" "$INSTALL_SH"; then
    bad "${HELPER} is not defined in install.sh"
else
    # HERESTRINGS, NOT PIPES. `printf | grep -q` under `set -o pipefail`
    # inverts its own verdict: grep -q exits the moment it matches, printf
    # gets SIGPIPE, and pipefail reports the pipeline as FAILED on a needle
    # that IS present. Guarded estate-wide by the pipefail-short-circuit
    # ratchet, which caught this file on its first CI run.
    _body="$(awk "/^${HELPER}\\(\\) \\{/,/^\\}/" "$INSTALL_SH")"
    if grep -q 'launchctl print' <<< "$_body"; then
        pass "${HELPER} asks launchd via launchctl print"
    else
        bad "${HELPER} does not call launchctl print -- its verdict is not evidence"
    fi
    # 🔴 THIS ASSERTION USED TO PIN A RENDERING AND IT WENT RED-WHILE-FIXED.
    #
    # It required `launchctl print` to be the LAST command, on the reasoning
    # that the last command is the return value. That was true of the first
    # version of the helper and stopped being true the moment the helper had
    # to do something MORE than pass the exit code along -- namely capture
    # print's stdout and refuse on `last exit code = 78: EX_CONFIG`, because
    # print returns rc=0 for a merely-REGISTERED job (measured, macOS 26.5.2).
    #
    # The stronger helper ends `return 0`, and the old assertion called that a
    # failure. A predicate pinned to a rendering goes RED WHILE THE BEHAVIOUR
    # IS CORRECT -- the twin of green-while-blind, and the same root cause.
    #
    # So assert the PROPERTY: the helper's verdict must be DERIVED FROM the
    # print, and nothing may re-open the door afterwards. This is strictly
    # stronger than the old form, which would have passed a helper whose last
    # line was `launchctl print` but which ignored EX_CONFIG entirely -- i.e.
    # it would have passed the version Archie2 rejected.
    _derives=0
    # (a) the print's own failure must refuse, not fall through
    grep -qE 'launchctl print[^|]*\|\|[[:space:]]*return 1|_print="\$\(launchctl print.*\)"[[:space:]]*\|\|[[:space:]]*return 1' \
        <<< "$_body" && _derives=1
    # (b) ...or the print IS the final command, the original shape. Still fine.
    _last="$(grep -v '^\s*#' <<< "$_body" | grep -v '^\s*$' | tail -2 | head -1)"
    grep -q 'launchctl print' <<< "$_last" && _derives=1

    # (c) REGARDLESS of shape, the function must never end by swallowing.
    if grep -qE '\|\|[[:space:]]*true[[:space:]]*$' <<< "$(tail -3 <<< "$_body")"; then
        _derives=0
    fi

    if [[ "$_derives" == "1" ]]; then
        pass "${HELPER}'s verdict is DERIVED from launchctl print (property, not line position)"
    else
        bad "${HELPER}'s return value is not derived from launchctl print: ${_last}"
    fi
fi

# --- CONTROL 3: ordering. The helper must be defined before it is called. --
# install.sh is one 24k-line script executed top to bottom; a helper defined
# after its first call is a command-not-found at runtime and nowhere else.
# This is the #772 class and it has bitten this file before.
_def_line="$(grep -n "^${HELPER}() {" "$INSTALL_SH" | head -1 | cut -d: -f1)"
_first_call="$(grep -n "${HELPER} \"" "$INSTALL_SH" | head -1 | cut -d: -f1)"
if [[ -n "$_def_line" && -n "$_first_call" ]]; then
    if [[ "$_def_line" -lt "$_first_call" ]]; then
        pass "definition (L${_def_line}) precedes first call (L${_first_call})"
    else
        bad "definition (L${_def_line}) comes AFTER first call (L${_first_call}) -- command not found at runtime"
    fi
else
    bad "could not locate both the definition and a call site for ${HELPER}"
fi

# --- CONTROL 4: the failure branches say something. ------------------------
# A verified `if` whose `else` is empty is the same silence in a better shape.
# Every MSG_WARN_* key the new branches reference must exist in the catalogue,
# or the customer gets a blank warn line -- the defect Andy saw as the literal
# characters `$MSG_OK_ENRICH_AGENT_LOADED` on his 2026-08-20 install.
_missing_keys=0
for _k in MSG_WARN_OSTLER_DOCTOR_NOT_LOADED \
          MSG_WARN_STAY_AWAKE_AGENT_NOT_LOADED \
          MSG_WARN_FDA_RE_RUN_NOT_SCHEDULED \
          MSG_WARN_MEETING_BRIEF_SENDER_NOT_LOADED \
          MSG_WARN_DEFERRED_DEVICE_REGISTRATION_NOT_LOADED; do
    if ! grep -q "^${_k}=" "$STRINGS"; then
        bad "install.sh references ${_k} but the catalogue does not define it"
        _missing_keys=$((_missing_keys + 1))
    fi
    if ! grep -q "\$${_k}" "$INSTALL_SH" && ! grep -q "\${${_k}}" "$INSTALL_SH"; then
        bad "${_k} is defined in the catalogue but nothing in install.sh uses it"
        _missing_keys=$((_missing_keys + 1))
    fi
done
[[ "$_missing_keys" -eq 0 ]] && pass "all 5 new failure messages are both defined and used"

# --- CONTROL 5: the helper is actually load-bearing. ----------------------
# Count call sites. If a refactor quietly routes agents around it, control 1
# still passes (no announcements near a raw launchctl) while the verification
# disappears. Floor is 11, the number converted when #876 was closed.
_calls="$(grep -c "${HELPER} \"" "$INSTALL_SH" || true)"
if [[ "$_calls" -ge 11 ]]; then
    pass "${_calls} LaunchAgent sites route through the verified loader (floor 11)"
else
    bad "only ${_calls} sites call ${HELPER}; 11 were converted when #876 was closed. \
Agents have been routed around the verification."
fi

# ---------------------------------------------------------------------------
# SELF-TEST. Reinstate the pre-fix Doctor block verbatim in a copy and require
# the scan to catch it. Green-on-the-fix alone proves nothing: a scanner with
# a broken regex is green on everything.
# ---------------------------------------------------------------------------
if [[ "$SELF_TEST" -eq 1 ]]; then
    echo
    echo "SELF-TEST: the pre-fix v1.0.44 Doctor block must go RED"
    _tmp="$(mktemp -t launchagent_selftest)" || cannot_run "mktemp failed"
    trap 'rm -f "$_tmp"' EXIT

    python3 - "$INSTALL_SH" "$_tmp" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
fixed = '''    if _ostler_launchagent_load_verified "$DOCTOR_PLIST"; then
        ok "$MSG_OK_OSTLER_DOCTOR_RUNNING_HTTP_LOCALHOST_8089"
    else
        warn "$MSG_WARN_OSTLER_DOCTOR_NOT_LOADED"
        HEALTHY=false
    fi'''
# The exact text shipped in v1.0.44, pin 2fb63f73.
prefix = '''    launchctl bootstrap "gui/$(id -u)" "$DOCTOR_PLIST" 2>/dev/null || \\
        launchctl load "$DOCTOR_PLIST" 2>/dev/null || true
    ok "$MSG_OK_OSTLER_DOCTOR_RUNNING_HTTP_LOCALHOST_8089"'''
if fixed not in text:
    sys.exit("SELF-TEST SETUP FAILED: the fixed Doctor block is not in install.sh "
             "in the form this test knows how to revert. The test is stale, not the code.")
open(dst, 'w').write(text.replace(fixed, prefix, 1))
PY
    _rc=$?
    [[ $_rc -eq 0 ]] || cannot_run "self-test could not construct the pre-fix tree (rc=${_rc})"

    _st_unverified="$(_run_controls "$_tmp" "SELF-TEST -- Doctor block reverted to v1.0.44")"
    # Same again: on this path the anti-vacuity floor has ALREADY passed, so
    # nothing else would catch a scanner that failed only on the temp tree.
    # Without this line a CANNOT-RUN was reported as a FAIL (#765's family).
    [[ "$_st_unverified" == "SCANNER_FAILED" ]] && cannot_run \
        "the scanner failed on the self-test tree. The self-test did not run."
    if [[ "$_st_unverified" -ge 1 ]]; then
        pass "the scanner CAUGHT the reinstated defect (${_st_unverified} finding(s))"
    else
        bad "the scanner did NOT catch the reinstated v1.0.44 Doctor block. \
It is green on the fix and green on the defect, which means it measures nothing."
    fi

    # Control on the control: reverting ONE block must move the count by
    # exactly one. If it moved by more, the revert touched something else and
    # the RED is not attributable to the defect under test.
    if [[ "$_st_unverified" -eq $((UNVERIFIED + 1)) ]]; then
        pass "the count moved by exactly 1 (${UNVERIFIED} -> ${_st_unverified}), so the RED is attributable"
    else
        bad "count moved ${UNVERIFIED} -> ${_st_unverified}; expected exactly one more. \
The self-test edit is not isolated to the Doctor block."
    fi
fi

echo
printf 'PASS %d / FAIL %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
