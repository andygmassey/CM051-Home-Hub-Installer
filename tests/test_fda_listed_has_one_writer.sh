#!/usr/bin/env bash
#
# _fda_listed must have exactly ONE writer: the probe that actually reads TCC.
#
# ── WHY THIS FILE EXISTS ─────────────────────────────────────────────────
#
# MEASURED on the live fresh-account walk of v1.0.50, 2026-08-29/30. install.sh
# contained a block that set _fda_listed="listed" whenever the FDA register-nudge
# had merely RUN. It never confirmed a TCC row. Its own comment argued "if the
# nudge ran the row exists" -- and the walk refuted that: the nudge ran, logged
# success, and OstlerAssistant was absent from the Full Disk Access list.
#
# ONE INVENTED BOOLEAN DROVE THREE CUSTOMER-FACING BRANCHES, all the wrong way:
#   * suppressed `open -R`, so the Finder drag-in route was never offered
#   * printed "already listed" at a customer looking at a list without it
#   * dropped the drag instruction line from the modal
# The single route that might have worked was withheld BECAUSE the code had
# convinced itself the customer did not need it.
#
# The real probe reads TCC.db via sudo, and `sudo -n` is unavailable on a genuine
# fresh install -- the exact case the synthesis fired in. So verification is
# structurally CANNOT-VERIFY there, and the code answered CANNOT-VERIFY with a
# PASS. Three states collapsed into two. Same class as #558 and #574.
#
# ── WHAT THIS ASSERTS ───────────────────────────────────────────────────
#
# _fda_listed is assigned in exactly ONE place, and that place is a command
# substitution calling the probe. Any other writer is a synthesis by definition:
# there is no other legitimate source of truth for whether macOS granted FDA.
#
# ── WHY COMMENTS ARE STRIPPED FIRST ─────────────────────────────────────
#
# The fix commit describes the removed code in prose. If this test counted
# comment text it would fail on the very commit that repairs the defect, and the
# obvious "fix" would be to weaken the predicate. Control (3) proves the stripping
# did not blind it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="${OSTLER_INSTALL_SH:-${HERE}/../install.sh}"

CHECKS=0
FAILURES=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*" >&2; FAILURES=$((FAILURES + 1)); }

[[ -f "$INSTALL" ]] || { echo "CANNOT-RUN: install.sh not found at $INSTALL" >&2; exit 2; }

echo "test_fda_listed_has_one_writer.sh"

# Code only: drop whole-line comments. Not a general shell parser -- the
# assignments we care about are never inside a heredoc, and control (3) below
# proves the predicate still fires after stripping.
CODE="$(mktemp)"
trap 'rm -f "$CODE"' EXIT
grep -v '^[[:space:]]*#' "$INSTALL" > "$CODE"

# --- (0) ANTI-VACUITY: the stripped file must still be substantial ----------
CHECKS=$((CHECKS + 1))
_code_lines=$(wc -l < "$CODE" | tr -d ' ')
if [[ "$_code_lines" -gt 10000 ]]; then
    pass "(0) stripped file still has ${_code_lines} code lines, so a zero below is not an empty-input artefact"
else
    fail "(0) CANNOT-RUN: stripped file has only ${_code_lines} lines; the strip ate the file and every count below is meaningless"
    echo; echo "=== $((CHECKS - FAILURES)) passed / $FAILURES failed ==="; exit 2
fi

# --- (1) exactly one writer ------------------------------------------------
CHECKS=$((CHECKS + 1))
_writers=$(grep -cE '(^|[^A-Za-z_])_fda_listed=' "$CODE" || true)
if [[ "$_writers" -eq 1 ]]; then
    pass "(1) _fda_listed has exactly 1 writer"
else
    fail "(1) _fda_listed has ${_writers} writers, expected exactly 1. Any writer beyond the probe SYNTHESISES a permission state macOS never granted."
    grep -nE '(^|[^A-Za-z_])_fda_listed=' "$CODE" | sed 's/^/        /' >&2
fi

# --- (2) and that writer is the probe, not a literal ------------------------
CHECKS=$((CHECKS + 1))
if grep -qE '_fda_listed="\$\(_imessage_daemon_fda_listed\)"' "$CODE"; then
    pass "(2) the sole writer is a command substitution calling _imessage_daemon_fda_listed"
else
    fail "(2) the writer is NOT the probe call. A literal assignment cannot know what macOS granted."
fi

# --- (3) CONTROL: the predicate can still SEE an assignment -----------------
#     Without this, "comments are stripped" and "nothing is detectable" print
#     identically, and only one of them is a working test.
CHECKS=$((CHECKS + 1))
_CTRL="$(mktemp)"
{
    printf '# a comment mentioning _fda_listed= must NOT count\n'
    printf '    _fda_listed="listed"\n'
} > "$_CTRL"
_ctrl_code="$(mktemp)"
grep -v '^[[:space:]]*#' "$_CTRL" > "$_ctrl_code"
_ctrl_hits=$(grep -cE '(^|[^A-Za-z_])_fda_listed=' "$_ctrl_code" || true)
rm -f "$_CTRL" "$_ctrl_code"
if [[ "$_ctrl_hits" -eq 1 ]]; then
    pass "(3) the predicate finds a real assignment and ignores a comment naming one"
else
    fail "(3) THE PREDICATE IS BLIND: fixture has exactly 1 real assignment and 1 comment, got ${_ctrl_hits}. (1) above proves nothing."
fi

# --- (4) DELIBERATELY ABSENT, and this note is the record of why -----------
#
# I first wrote a rule here that counted lines where _fda_nudge_registered and
# _fda_listed CO-OCCUR, on the theory that coupling them signals the synthesis
# returning. It fired on the repaired tree, flagging two innocent lines:
#   * the surviving log-only `if` -- which is the whole point of the fix, since
#     the nudge outcome is still worth RECORDING, just not obeying
#   * the `unset` cleanup line naming both variables
#
# That rule was a MENTION-COUNT, not a behaviour check. It could not distinguish
# "these two names appear together" from "one of them assigns the other", which
# is the only thing that matters. Raising its threshold to accept today's two
# lines would have been worse: it would encode the current tree rather than the
# property, so a THIRD co-occurrence that genuinely did set state would slip
# under a limit tuned to look green today.
#
# Checks (1) and (2) already close the defect completely and by construction:
# exactly one writer, and that writer is the probe. A synthesis cannot exist
# without a second writer. The mutation battery confirms it -- re-injecting the
# real defect turns (1) red on its own.
#
# Recorded rather than silently dropped, so the next person does not helpfully
# re-add it. Same class as #517, where I filed a mention-count as a finding.

echo
echo "=== $((CHECKS - FAILURES)) passed / $FAILURES failed ==="
[[ "$FAILURES" -eq 0 ]]
