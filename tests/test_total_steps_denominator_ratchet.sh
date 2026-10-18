#!/usr/bin/env bash
# THE PROGRESS DENOMINATOR MUST NOT KEEP MOVING MID-RUN (register #627).
#
# ── WHAT WAS MEASURED, ON A LIVE INSTALL ─────────────────────────────────────
#
# ttywalk of v1.0.62 on the Mini 16, 2026-09-03. The `total=` field on the
# STEP_BEGIN markers, in order:
#
#     idx=2  total=40      idx=26 total=37      idx=35 total=36
#     idx=9  total=40      idx=30 total=37      idx=36 total=36
#
# THREE distinct denominators in ONE run: 40 -> 37 -> 36. The customer watches
# a percentage computed against a number that shrinks underneath them, so the
# bar can sit still, jump, or go backwards while nothing is wrong. It ended at
# `idx=36 total=36` -- 100% -- and THEN health_check failed.
#
# ── WHY A RATCHET AND NOT A FIX ──────────────────────────────────────────────
#
# The real fix is to HOIST each late decrement above the first `progress` call,
# so TOTAL_STEPS is final before it is ever published.
#
# ⚠️ ONLY THREE OF THE SIX ARE HOISTABLE. An earlier version of this comment
# said FIVE. That was wrong, and the way it was wrong is worth keeping: I had
# measured WHEN EACH GUARD'S VARIABLE IS ASSIGNED, and every one of them is
# assigned before 10711. But four of the six guards are FILE TESTS, and a
# variable being set early says nothing about whether the PATH IT NAMES exists
# at seed time. Right instrument, wrong question.
#
# Re-measured properly:
#
#   HOISTABLE (3)
#     20995  pure variable test, CHANNEL_WHATSAPP_* assigned 4884/4885
#     21019  ~/Library/Mail        -- USER-owned, install.sh never creates it
#     21092  ~/Library/Messages/chat.db -- USER-owned, same
#
#   NOT HOISTABLE (3) -- each names a path INSTALL.SH ITSELF PRODUCES, so the
#   test genuinely answers differently at seed time than where it sits now
#     21041  ${USER_FACING_ROOT}/Transcripts -- created by install.sh; the dir
#            is in USER_TREE_SUBDIRS at 3344
#     21521  ${OSTLER_DIR}/bin/wiki-recompile-tick.sh -- shipped payload
#     26530  ${_HYDRATE_APPLENOTES_JSON_FILE} -- an FDA extraction OUTPUT, and
#            the variable itself is not assigned until 26508, long after seed
#
#   NOT HOISTABLE (4 as of 2026-09-13, PIN raised 6 -> 7; see below)
#     29909  ${_HYDRATE_REMINDERS_JSON_FILE} -- SAME shape as the
#            apple_notes row directly above: an FDA extraction OUTPUT
#            (reminders.json), variable assigned at install.sh:29909, itself
#            long after seed. Written reason for the raise, as this file's
#            own PIN comment requires: this decrement mirrors an ALREADY
#            NOT-HOISTABLE sibling exactly (same fda_extract dependency,
#            same "-s file exists" test), so hoisting it while its sibling
#            stays un-hoisted would not shrink the true floor, only hide one
#            member of it. The floor is 4 not-hoistable sites now, not 3.
#
# So the floor for this ratchet is FOUR now (was three), and getting below
# four is not a hoist at all -- it needs the condition computed from
# something knowable at seed, or an accepted design decision that the
# denominator moves. Writing a gate that demands zero would be writing a gate
# nobody can satisfy, and an unsatisfiable gate gets bypassed rather than met.
#
# So this is a RATCHET, pinned at the measured 7. It is satisfiable TODAY, it
# refuses an EIGHTH, and -- because it also fails when the count drops without
# the pin being lowered -- it forces the number DOWN over time instead of
# merely freezing it. That second direction is the point: a ratchet that only
# catches increases silently blesses a fix that was never recorded.
#
# ── EXIT CODES ───────────────────────────────────────────────────────────────
#   0  ok        7 or fewer late decrements, pin accurate
#   1  violation an 8th appeared, or the count fell without lowering PIN
#   2  CANNOT-RUN could not read install.sh / parsed nothing. NOT a pass.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

# The measured population, 2026-09-03 at origin/main f237c3a0, raised
# 2026-09-13 (6 -> 7) for the hydrate_reminders decrement -- see the
# NOT-HOISTABLE list above for the written reason. LOWER THIS when you hoist
# one. Raising it further requires a written reason in the PR body.
#
# ── RAISED 2026-09-18, 7 -> 8, DELIBERATELY, FOR merge_consistency_repair ────
#
# This gate's own message offers two ways out: hoist the condition to seed
# time, or, if it is genuinely unknowable that early, SAY SO and raise the pin
# deliberately rather than silently. This is the second, and the claim is
# MEASURED rather than asserted:
#
#     TOTAL_STEPS is seeded at         install.sh:11996
#     identity_resolver is copied in   install.sh:20522
#     the pipeline venv is created     install.sh:20655
#
# The step runs only when that package AND that venv AND the module
# repair_merge_consistency.py all exist under PIPELINE_DIR. On a FRESH install
# none of the three exists at line 11996 -- they are created eight and a half
# thousand lines later. Evaluating the condition at seed would subtract a step
# that IS going to run, on every first install, which is the same wrong
# denominator this ratchet exists to prevent, arrived at from the other side.
#
# THE LATENESS IS THE CORRECTNESS HERE. By the time the decrement fires, the
# question "will this step run" has an answer. At seed it does not, and a guess
# is not a hoist.
#
# WHAT WOULD LOWER IT AGAIN: making the repair unconditional, which means
# shipping the module in a tree that cannot be absent. That is a real option
# and it is not tonight's.
#
# ── RAISED 8 -> 9 AND LOWERED BACK TO 8 ON 2026-09-23, SAME DAY ─────────────
#
# Recorded rather than quietly reverted, because the reasoning is the useful
# part. The Front Page catch-up agent (install.sh 3.14d-editor-bis) first
# arrived as a verbatim mirror of the wiki catch-up: a `progress` call gated on
# `-x ${OSTLER_DIR}/bin/editor-frontpage-tick.sh`, with a decrement when the
# gate is false. That is a ninth late site, and it is genuinely NOT hoistable
# for the reason this file already gives: it is a FILE TEST, and the file it
# tests is rendered a few lines earlier, so nothing at seed time can answer it.
# The pin was raised to 9, out loud, and the raise named its own undo:
#
#     "WHAT WOULD LOWER IT AGAIN: make the catch-up unconditional so the
#      question 'will this step run' has an answer at seed time."
#
# That is what the change now does. The step is announced unconditionally and
# always performs: it either installs the catch-up agent or says why it did
# not. The condition survives as a branch INSIDE the step, where it belongs,
# and stops being a question about the denominator. Nine sites became eight
# again, and the gate went straight to "only 8 late decrements but the pin is
# still 9. Someone hoisted one and did not lower the pin", which is the ratchet
# holding ground in the direction it exists to hold it.
#
# THE GENERAL LESSON, and it outlives this agent: a file test that cannot be
# hoisted is often a gate that should not exist. Ask whether the step has to be
# conditional at all before asking whether its condition can be computed early.
PIN=8

cannot() { echo "CANNOT-RUN [$1]: $2" >&2; exit 2; }
[ -f "$INSTALL_SH" ] || cannot "no-install-sh" "$INSTALL_SH not found -- nothing was examined."
command -v python3 >/dev/null 2>&1 || cannot "no-python3" "python3 absent; the parse cannot run."

PIN="$PIN" INSTALL_SH="$INSTALL_SH" python3 - <<'PY'
import os, re, sys

pin = int(os.environ["PIN"])
path = os.environ["INSTALL_SH"]
try:
    src = open(path, encoding="utf-8", errors="replace").read().split("\n")
except OSError as e:
    print(f"CANNOT-RUN [unreadable]: {path}: {e}", file=sys.stderr); sys.exit(2)

# ANTI-VACUITY. A regex that matches nothing prints the same clean zero as a
# genuinely hoisted tree. Both of these must be non-zero or we have measured
# nothing and must say so.
if len(src) < 1000:
    print(f"CANNOT-RUN [short-read]: only {len(src)} lines parsed from install.sh; "
          f"that is not the real file. Not a pass.", file=sys.stderr); sys.exit(2)

prog = [i for i, l in enumerate(src, 1) if re.search(r'^\s*progress\s+"', l)]
if not prog:
    print("CANNOT-RUN [no-progress-calls]: found 0 `progress \"` calls. The seed "
          "is what TOTAL_STEPS counts, so a zero here means the predicate is "
          "broken, NOT that the installer has no steps.", file=sys.stderr); sys.exit(2)
first_progress = prog[0]

DEC = re.compile(r'TOTAL_STEPS\s*=\s*\$?\(?\(?\s*\$?\{?TOTAL_STEPS\}?\s*-|TOTAL_STEPS\s*-=')

# ⚠️ A COMMENTED-OUT DECREMENT IS NOT A DECREMENT. Found by this file's own
# arm C: it simulated a hoist by commenting the line out, and the ratchet
# stayed GREEN because the regex matched the text inside the comment. Without
# this skip, hoisting a site by commenting it never tightens the pin, so the
# ratchet silently blesses ground that was won and never recorded.
#
# HONEST BOUND ON WHAT THIS BUYS, because the first version of this comment
# over-claimed and arm E refuted it: a SWAP (comment one out, add one live)
# still reads 6 and still passes -- correctly. Six live sites is six live
# sites; a swap is net zero, not a concealed increase. This skip fixes the
# tighten-on-hoist direction ONLY. It is not a defence against churn.
#
# Only a line whose FIRST non-space character is `#` is skipped -- a trailing
# `# note` after a live command must still count.
def _is_comment(line: str) -> bool:
    s = line.lstrip()
    return s.startswith("#")

dec = [(i, l.strip()) for i, l in enumerate(src, 1)
       if DEC.search(l) and not _is_comment(l)]
if not dec:
    print("CANNOT-RUN [no-decrements-at-all]: 0 TOTAL_STEPS decrement sites found "
          "anywhere. install.sh has always had at least one, so this is a broken "
          "pattern, not a clean tree.", file=sys.stderr); sys.exit(2)

late = [d for d in dec if d[0] > first_progress]
early = [d for d in dec if d[0] < first_progress]

print(f"progress \" calls (the seed) : {len(prog)}")
print(f"first progress call at line : {first_progress}")
print(f"TOTAL_STEPS decrement sites : {len(dec)}")
print(f"  before first progress     : {len(early)}  (settle at seed, harmless)")
print(f"  AFTER  first progress     : {len(late)}   (pin = {pin})")
for i, l in late:
    print(f"    line {i}: {l[:76]}")

if len(late) > pin:
    print(f"\nFAIL: {len(late)} late decrements, pin is {pin}. A NEW site now moves the\n"
          f"denominator after it has been published to the customer. Hoist it above\n"
          f"line {first_progress} (compute the condition at seed time), or if it is\n"
          f"genuinely unknowable that early, say so IN THE PR and raise the pin\n"
          f"deliberately. Do not raise it silently -- the whole point of this file is\n"
          f"that the number only ever goes down.", file=sys.stderr)
    sys.exit(1)

if len(late) < pin:
    print(f"\nFAIL (GOOD NEWS, STILL A FAIL): only {len(late)} late decrements but the\n"
          f"pin is still {pin}. Someone hoisted one and did not lower the pin. Set\n"
          f"PIN={len(late)} in this file so the ratchet actually holds the ground that\n"
          f"was won. A ratchet that tolerates slack is a ratchet that never tightens.",
          file=sys.stderr)
    sys.exit(1)

print(f"\nOK: {len(late)} late decrement(s), exactly the pinned {pin}. The denominator\n"
      f"still moves mid-run -- this gate does not claim otherwise. It claims the\n"
      f"population has not GROWN, and names every member so the next hoist is obvious.")
PY
rc=$?
exit "$rc"
