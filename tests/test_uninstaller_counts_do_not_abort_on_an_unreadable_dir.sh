#!/usr/bin/env bash
#
# tests/test_uninstaller_counts_do_not_abort_on_an_unreadable_dir.sh
#
# #563 -- THE SHIPPED UNINSTALLER REMOVES NOTHING AND SAYS NOTHING.
#
# ~/.ostler/bin/ostler-uninstall is written by install.sh from a quoted
# heredoc. Near the top, before ANY removal happens, it counts the files under
# ~/Documents/Ostler/ so the customer can see what is at stake before deciding
# whether to keep it. That count is decoration. It killed the script.
#
#   count_dir() { ... find "$d" -type f 2>/dev/null | wc -l | tr -d ' ' ... }
#   WIKI_COUNT="$(count_dir "$USER_FACING_ROOT/Wiki")"
#
# ~/Documents is TCC-protected and a default Terminal has no Full Disk Access,
# so find exits non-zero. `2>/dev/null` hides the MESSAGE, NOT THE EXIT CODE.
# The script is `set -euo pipefail`: pipefail carries find's status through the
# pipe, the command substitution inherits it, set -e kills the script -- and
# with ZERO trap lines in the whole file, it dies mute. rc=1, nothing on
# stderr, nothing removed.
#
# THE BLAST RADIUS IS EVERYTHING. This block sits ABOVE "Stopping services",
# above the LaunchAgent teardown, above the .app removal, above the ~/.ostler
# removal. A customer runs the uninstaller, sees the banner, sees no error,
# concludes it worked, and keeps ~8 GB, 21 LaunchAgents and two .apps.
#
# THE CODE CONTRADICTS ITS OWN COMMENT, which is why it survived review:
#     # Counts are best-effort:
#     # a permission error or an empty subdir reports 0.
# It does not. A permission error is fatal. A reader who trusts the comment
# never checks the exit status.
#
# WHAT THIS ASSERTS, and why it is shaped this way
# ------------------------------------------------
# The defect is "EXECUTION STOPPED". So the observable must be "did the next
# line run" -- NOT "is stderr empty" and NOT "is the count right".
#   * stderr-empty would pass with the fix absent: bash writes its own
#     diagnostics on some failure shapes, and the original is silent anyway.
#   * the count value cannot distinguish "0 files" from "could not look",
#     which is the whole point of the fix.
# So every arm prints a SENTINEL after the assignment and requires it.
#
#   1  readable dir      -> sentinel printed, count exact          (control)
#   2  unreadable dir    -> sentinel MUST STILL PRINT              (the defect)
#   3  absent dir        -> sentinel printed, count 0              (control:
#                           the else-branch is ALREADY correct; proves the fix
#                           did not "repair" a path that was never broken)
#   4  MUTATION          -> the PINNED pre-fix count_dir must FAIL arm 2
#   5  ERR TRAP SPEAKS   -> the second half of #563. "Removes nothing" was one
#                           defect; "says nothing" was the other, and a count
#                           that no longer aborts does not fix it. Driven with
#                           the PINNED PRE-FIX counter on purpose: the trap is
#                           the backstop, so it is tested against the exact
#                           failure it exists to report.
#   6  TRAP CONTROL      -> the same driver with the trap line REMOVED must be
#                           SILENT. Without this, arm 5 would pass on bash's
#                           own diagnostics and prove nothing about our
#                           handler. MEASURED 2026-08-29 on this shape:
#                           with trap 247 bytes of stderr, without trap ZERO.
#   7  RENDER            -> the surface the CUSTOMER actually reads. count_dir
#                           returning a state is only half the fix; if the
#                           renderer printed it as a quantity the customer
#                           would still be told a number. Asserts BEHAVIOUR
#                           (a non-numeric count is never rendered as a
#                           quantity), never the wording -- a test that pins
#                           prose rots on the first copy edit.
#   8  DIAGNOSTIC ONLY   -> same unreadable dir without pipefail
#
# Arms 4 and 6 are what make this a test rather than an assertion. Arm 7 is
# labelled a diagnostic on purpose: it demonstrates the carrier, and a green
# there is NOT a passing product -- dropping pipefail turns the unreadable
# directory into a confident "0 pages" for a customer with thousands of them,
# which is a silent zero replacing a silent abort.
#
# EXIT CODES -- A HARNESS PROBLEM IS NOT A PRODUCT DEFECT
#   0  every arm held
#   1  the uninstaller misbehaved            (evidence of badness)
#   2  the harness could not run             (absence of evidence)
#
# rc=2 matters here more than usual. Arm 2 needs a directory this process
# genuinely cannot read. `chmod 000` achieves that as an ordinary user and
# needs no TCC -- but it does NOT stop root, and if CI ever runs this as root
# the arm silently becomes vacuous. So the harness PROVES the directory is
# unreadable before trusting any verdict from it, and exits 2 if it is not.
# A permission test that runs as root is a test that cannot fail.
#
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
cannot_run() {
    printf '\n[uninstaller-count-harness] CANNOT-RUN: %s\n' "$1" >&2
    cat >&2 <<'MSG'

  This is a HARNESS failure, not a product defect. Nothing about the
  uninstaller has been measured -- do not read this as the uninstaller being
  correct, and do not go and debug it on the strength of this line.
MSG
    exit 2
}

echo
echo "=== #563: the uninstaller's content count must not abort the uninstall ==="
echo

[[ -r "$INSTALL_SCRIPT" ]] || cannot_run "install.sh is not readable at ${INSTALL_SCRIPT}"

# ── LOCATE count_dir BY ANCHOR, NEVER BY LINE NUMBER ────────────────────────
# Line numbers rot on the first unrelated edit above them. Both anchors must
# match EXACTLY ONCE inside the uninstaller heredoc; 0 or 2+ is CANNOT-RUN.
#
# NOTE THE INDENTATION. count_dir is defined INSIDE an `if [[ -d ... ]]` block,
# so it sits at column 8, not column 0. A `^count_dir` anchor returns zero and
# reads as "absent" -- I made exactly that mistake finding it. Anchor on the
# token, not on the margin.
HEREDOC="$(awk '/^cat > "\$\{OSTLER_DIR\}\/bin\/ostler-uninstall" <<.UNINSTALLEOF.$/{f=1;next} f&&/^UNINSTALLEOF$/{f=0} f' "$INSTALL_SCRIPT")"
[[ -n "$HEREDOC" ]] || cannot_run "could not extract the ostler-uninstall heredoc from install.sh"

n_def="$(printf '%s\n' "$HEREDOC" | grep -cE '[[:space:]]*count_dir\(\)[[:space:]]*\{')"
[[ "$n_def" -eq 1 ]] || cannot_run "count_dir() definition matched ${n_def} times inside the heredoc, expected exactly 1"

SHIPPED_COUNT_DIR="$(printf '%s\n' "$HEREDOC" | awk '/[[:space:]]*count_dir\(\)[[:space:]]*\{/{f=1} f{print; if (/^[[:space:]]*\}[[:space:]]*$/) exit}')"
printf '%s\n' "$SHIPPED_COUNT_DIR" | grep -qF 'find' \
    || cannot_run "the extracted count_dir does not reference find; wrong region"
ok "CANNOT-RUN checks: heredoc found, count_dir anchored uniquely, region is the right one"

# ── THE PINNED PRE-FIX IMPLEMENTATION (arm 4) ───────────────────────────────
# PINNED, NOT DERIVED. An anti-vacuity baseline that is computed from the file
# under test moves when the file moves, and then proves nothing. This is the
# shipped text as of the defect, frozen here on purpose. If the fix lands and
# someone later "tidies" this fixture to match, arm 4 stops discriminating and
# the whole file becomes decoration.
read -r -d '' ORIGINAL_COUNT_DIR <<'PINNED' || true
        count_dir() {
            local d="$1"
            if [[ -d "$d" ]]; then
                find "$d" -type f 2>/dev/null | wc -l | tr -d ' '
            else
                echo 0
            fi
        }
PINNED

WORK="$(mktemp -d)"
trap 'chmod 755 "$WORK/blocked" 2>/dev/null || true; rm -rf "$WORK"' EXIT

mkdir -p "$WORK/readable" "$WORK/blocked"
printf 'x\n' > "$WORK/readable/one.txt"
printf 'x\n' > "$WORK/readable/two.txt"
printf 'x\n' > "$WORK/blocked/hidden.txt"
chmod 000 "$WORK/blocked"

# ── PROVE THE UNREADABLE DIRECTORY IS ACTUALLY UNREADABLE ───────────────────
# Without this the whole file is vacuous under root, and vacuous is worse than
# absent because it reports green.
if find "$WORK/blocked" -type f >/dev/null 2>&1; then
    cannot_run "find CAN read a chmod 000 directory here (running as root?). Arm 2 would be vacuous, so no verdict is available."
fi
ok "the blocked fixture is genuinely unreadable by this process (arm 2 can discriminate)"

SENTINEL="__REACHED_THE_NEXT_STATEMENT__"

# drive <impl> <dir> [extra-set-flags]
# Prints the captured stdout; returns the script's own rc.
drive() {
    local impl="$1" dir="$2" flags="${3:-set -euo pipefail}"
    {
        echo '#!/usr/bin/env bash'
        echo "$flags"
        printf '%s\n' "$impl"
        # The assignment under test, then the sentinel. The sentinel is the
        # observable: the defect is that execution never gets here.
        echo "WIKI_COUNT=\"\$(count_dir \"$dir\")\""
        echo "printf 'COUNT=%s\\n' \"\$WIKI_COUNT\""
        echo "printf '%s\\n' '$SENTINEL'"
    } > "$WORK/drive.sh"
    bash "$WORK/drive.sh" 2>/dev/null
}

# ── ARM 1: readable directory (control) ─────────────────────────────────────
out="$(drive "$SHIPPED_COUNT_DIR" "$WORK/readable")" || true
if grep -qF "$SENTINEL" <<<"$out" && grep -qxF 'COUNT=2' <<<"$out"; then
    ok "ARM 1 readable dir -> next statement reached, count exact (2)"
else
    bad "ARM 1 readable dir -> expected sentinel + COUNT=2, got:
$out"
fi

# ── ARM 2: unreadable directory -- THE DEFECT ───────────────────────────────
out="$(drive "$SHIPPED_COUNT_DIR" "$WORK/blocked")" || true
if grep -qF "$SENTINEL" <<<"$out"; then
    ok "ARM 2 unreadable dir -> NEXT STATEMENT STILL REACHED (the uninstall continues)"
    if grep -qxF 'COUNT=0' <<<"$out"; then
        bad "ARM 2 survived but reported COUNT=0 for a directory it could not read.
      That is a silent zero replacing a silent abort: a customer with thousands
      of pages behind TCC is told they have none. The count must render as
      unreadable, never as a number."
    else
        ok "ARM 2 ...and did NOT report a bare 0 for a directory it could not read"
    fi
else
    bad "ARM 2 unreadable dir -> EXECUTION STOPPED. The uninstaller aborts before
      removing anything, silently. This is #563. Output was:
$out"
fi

# ── ARM 3: absent directory (control) ───────────────────────────────────────
# The else-branch was ALREADY correct. This arm exists so a fix cannot quietly
# break the path that never needed fixing.
out="$(drive "$SHIPPED_COUNT_DIR" "$WORK/does-not-exist")" || true
if grep -qF "$SENTINEL" <<<"$out" && grep -qxF 'COUNT=0' <<<"$out"; then
    ok "ARM 3 absent dir -> next statement reached, count 0 (else-branch still correct)"
else
    bad "ARM 3 absent dir -> expected sentinel + COUNT=0, got:
$out"
fi

# ── ARM 4: MUTATION -- the pinned pre-fix code MUST fail arm 2 ──────────────
# This is what makes the file a test. If the pinned original also survives the
# unreadable directory, then arm 2 is not measuring the defect and no green
# from this file means anything.
out="$(drive "$ORIGINAL_COUNT_DIR" "$WORK/blocked")" || true
if grep -qF "$SENTINEL" <<<"$out"; then
    bad "ARM 4 MUTATION -> the PINNED PRE-FIX count_dir SURVIVED the unreadable
      directory. Arm 2 therefore proves nothing. Either the pinned fixture has
      drifted from the real pre-fix code, or this environment cannot reproduce
      the defect. Treat every other result in this file as unproven."
else
    ok "ARM 4 MUTATION -> pinned pre-fix count_dir DIES on the unreadable dir (arm 2 discriminates)"
fi

# ── ARMS 5 + 6: THE OTHER HALF OF #563 -- AN ABORT MUST SAY SO ──────────────
# "Removes nothing" and "says nothing" were two defects, and fixing the count
# only addresses the first. The uninstaller carried ZERO trap lines (CONTROL:
# install.sh as a whole carries 11), so ANY unhandled non-zero status killed
# it mute -- rc=1, empty stderr, nothing removed, and a customer who concludes
# from the silence that it worked.
#
# The stimulus is the PINNED PRE-FIX counter, deliberately. The fixed counter
# cannot fail, so it cannot exercise a backstop; the trap is tested against
# the exact failure it exists to report.
# Anchors are located with grep and the range cut with sed. An earlier draft
# passed these patterns to `awk -v`, which processes backslash escapes in the
# assigned VALUE before awk ever sees it as a regex -- so `\(` and `\{` were
# eaten, the head never matched, and the block came back empty. It surfaced as
# CANNOT-RUN rather than as a false green only because the region check below
# exists. Keep that check.
HEREDOC_F="$WORK/heredoc.txt"
printf '%s\n' "$HEREDOC" > "$HEREDOC_F"
n_head="$(grep -cF -- '_ostler_uninstall_on_err() {' "$HEREDOC_F")"
n_tail="$(grep -cE -- '^trap .*ERR$' "$HEREDOC_F")"

# THREE-WAY SPLIT, AND IT MATTERS. An ABSENT trap is the DEFECT, not a harness
# problem: on the pre-fix uninstaller both counts are 0, and reporting that as
# CANNOT-RUN would say "I could not look" about the very thing I am looking
# for. Zero is a FAIL. Two or more is genuinely ambiguous and is CANNOT-RUN.
if [[ "$n_head" -eq 0 || "$n_tail" -eq 0 ]]; then
    bad "ARMS 5+6 -> THE UNINSTALLER HAS NO ERR TRAP (handler ${n_head}, trap line ${n_tail}).
      Every abort is therefore mute: rc=1, empty stderr, nothing removed. That
      is the second half of #563, and arms 5 and 6 cannot be driven without it."
    trap_measurable=0
elif [[ "$n_head" -ne 1 || "$n_tail" -ne 1 ]]; then
    cannot_run "the ERR-trap anchors matched head=${n_head} tail=${n_tail} inside the heredoc, expected 1 and 1"
else
    trap_measurable=1
fi

if [[ "$trap_measurable" -eq 1 ]]; then
th="$(grep -nF -- '_ostler_uninstall_on_err() {' "$HEREDOC_F" | cut -d: -f1)"
tt="$(grep -nE -- '^trap .*ERR$' "$HEREDOC_F" | cut -d: -f1)"
[[ "$th" -lt "$tt" ]] || cannot_run "ERR-trap anchors are out of order (head ${th}, tail ${tt})"
TRAP_BLOCK="$(sed -n "${th},${tt}p" "$HEREDOC_F")"
printf '%s\n' "$TRAP_BLOCK" | grep -qF 'BASH_COMMAND' \
    || cannot_run "the extracted trap block does not reference BASH_COMMAND; wrong region"

# drive_trap <with|without> <stderr-file>
# Runs the #563 SHAPE -- pre-fix counter, unreadable dir, top-level command
# substitution -- with and without the trap line. stdout is discarded; the
# whole question is what reaches STDERR.
drive_trap() {
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        [[ "$1" == "with" ]] && printf '%s\n' "$TRAP_BLOCK"
        printf '%s\n' "$ORIGINAL_COUNT_DIR"
        echo "WIKI_COUNT=\"\$(count_dir \"$WORK/blocked\")\""
        echo "printf '%s\\n' '$SENTINEL'"
    } > "$WORK/trapdrive.sh"
    bash "$WORK/trapdrive.sh" >/dev/null 2>"$2" || true
}

drive_trap with "$WORK/with.err"
with_bytes="$(wc -c < "$WORK/with.err" | tr -d ' ')"
if [[ "$with_bytes" -gt 0 ]] && grep -qF 'Uninstall FAILED' "$WORK/with.err"; then
    ok "ARM 5 ERR TRAP -> the abort SPEAKS (${with_bytes} bytes on stderr, naming the failure)"
else
    bad "ARM 5 ERR TRAP -> the uninstaller died with ${with_bytes} bytes on stderr and no
      'Uninstall FAILED' line. This is the second half of #563: it removes
      nothing AND tells the customer nothing."
fi

# THE CONTROL. Without this, arm 5 could be passing on bash's own diagnostics
# and would prove nothing about our handler.
drive_trap without "$WORK/without.err"
without_bytes="$(wc -c < "$WORK/without.err" | tr -d ' ')"
if [[ "$without_bytes" -eq 0 ]]; then
    ok "ARM 6 TRAP CONTROL -> with the trap line removed the same failure is SILENT (0 bytes)"
else
    bad "ARM 6 TRAP CONTROL -> the trap-less driver still wrote ${without_bytes} bytes to
      stderr. Bash is diagnosing this failure by itself, so arm 5 does not
      measure our handler and its green means nothing."
fi
fi

# ── ARM 7: THE RENDERER -- WHAT THE CUSTOMER ACTUALLY READS ─────────────────
# count_dir returning "unreadable" is only half the fix. The customer never
# sees count_dir's output; they see render_count's. A renderer that printed
# the state as a quantity would put "unreadable pages" -- or worse, a number
# -- in front of someone deciding whether to delete their wiki.
#
# This asserts BEHAVIOUR, not wording: digits render as "<n> <noun>", and
# anything that is not all digits never renders as a quantity. The exact
# sentence is deliberately NOT pinned; a test that asserts prose fails on the
# first copy edit and teaches people to update tests to match the code.
n_render="$(grep -cE '[[:space:]]*render_count\(\)[[:space:]]*\{' "$HEREDOC_F")"
if [[ "$n_render" -ne 1 ]]; then
    cannot_run "render_count() definition matched ${n_render} times inside the heredoc, expected exactly 1"
fi
RENDER="$(awk '/[[:space:]]*render_count\(\)[[:space:]]*\{/{f=1} f{print; if (/^[[:space:]]*\}[[:space:]]*$/) exit}' "$HEREDOC_F")"
printf '%s\n' "$RENDER" | grep -qF 'case' \
    || cannot_run "the extracted render_count does not contain a case statement; wrong region"

render() { # render <value> <noun>
    { echo '#!/usr/bin/env bash'
      echo 'set -euo pipefail'
      printf '%s\n' "$RENDER"
      echo "render_count \"\$1\" \"\$2\""
    } > "$WORK/render.sh"
    bash "$WORK/render.sh" "$1" "$2" 2>/dev/null
}

render_ok=1
for pair in '42:42 pages' '0:0 pages'; do
    got="$(render "${pair%%:*}" pages)" || true
    if [[ "$got" != "${pair#*:}" ]]; then
        bad "ARM 7 RENDER -> a plain count '${pair%%:*}' rendered as '${got}', expected '${pair#*:}'"
        render_ok=0
    fi
done
# The load-bearing half: a state must never come out looking like a quantity.
for state in 'unreadable' ''; do
    got="$(render "$state" pages)" || true
    label="${state:-<empty>}"
    if [[ -z "$got" ]]; then
        bad "ARM 7 RENDER -> the non-numeric count '${label}' rendered as NOTHING; the customer is shown a blank where a state belongs"
        render_ok=0
    elif [[ "$got" =~ ^[0-9] ]]; then
        bad "ARM 7 RENDER -> the non-numeric count '${label}' rendered as '${got}', which STARTS WITH A DIGIT.
      A directory we could not read is being presented to the customer as a
      quantity. That is the silent zero arriving one layer later."
        render_ok=0
    fi
done
[[ "$render_ok" -eq 1 ]] && ok "ARM 7 RENDER -> digits render as a quantity; a state never does (4 inputs)"

# ── ARM 8: DIAGNOSTIC ONLY -- not a product assertion ───────────────────────
# Demonstrates that pipefail is the carrier: same directory, same permission,
# one flag different. A green here is NOT a passing product -- it is the
# failure mode we are refusing to ship.
out="$(drive "$ORIGINAL_COUNT_DIR" "$WORK/blocked" 'set -eu')" || true
if grep -qF "$SENTINEL" <<<"$out"; then
    printf '  note  DIAGNOSTIC: without pipefail the same pre-fix code survives and reports\n'
    printf '        %s -- this is the silent zero, shown to explain why\n' "$(grep -E '^COUNT=' <<<"$out" || echo 'COUNT=?')"
    printf '        `|| true` is NOT the fix. Not counted as a pass.\n'
else
    printf '  note  DIAGNOSTIC: pre-fix code died even without pipefail -- unexpected,\n'
    printf '        the carrier may not be what we think. Not counted as a failure.\n'
fi

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
