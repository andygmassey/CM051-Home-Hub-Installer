#!/usr/bin/env bash
#
# test_sensitive_artefacts_not_world_readable.sh
#
# #912 -- THE INSTALLER WROTE THE OPERATOR'S ADDRESS BOOK TO A DIRECTORY
# EVERY LOCAL ACCOUNT CAN READ, AND NEEDED NO SOCKET TO DO IT.
#
# install.sh used to write two DATA artefacts to fixed paths under /tmp:
#
#     /tmp/ostler-dedupe-report.yaml    every duplicate pair the resolver
#                                       considered -- real names, emails,
#                                       phone numbers, the whole address book
#     /tmp/ostler-aiconv-summary.json   the AI-conversations drain summary
#
# On macOS /tmp is a symlink to /private/tmp, which is drwxrwxrwt. The
# sticky bit protects DELETION, not READING. With umask 022 the files land
# 0644. So any other local account reads them with `cat`.
#
# This is #550's threat model with a SHORTER PATH than #550 itself: no
# socket, no port, no protocol -- one `cat` on a predictable filename.
#
# ── AND THE SECOND ONE FAILED OPEN ───────────────────────────────────
# The AI-conversations site was:
#
#     _AICONV_OUT="$(mktemp -t ostler-aiconv.XXXXXX)" \
#         || _AICONV_OUT=/tmp/ostler-aiconv-summary.json
#
# `mktemp -t` gives a 0600 file under the per-user $TMPDIR, which is fine.
# The FALLBACK was the defect, and it is the worst shape: invisible to
# anyone grepping the file for `mktemp`, and it only fires on boxes where
# something is already wrong. A fallback that is less safe than the thing
# it falls back from is not a fallback, it is a trapdoor.
#
# ── TWO MECHANISMS, AND THE SECOND ONE IS NOT DUPLICATION ────────────
# Two of the three sites are ordinary install.sh shell and call the new
# _ostler_private_artefact helper.
#
# The third is inside `cat > "$wrapper" <<'DCUEOF'` -- a QUOTED heredoc.
# The text in there is written to a standalone LaunchAgent script that
# resolves its variables in its OWN shell, where install.sh's functions do
# not exist. A fix that called the helper from in there would be INERT --
# byte-identical to a working fix and doing nothing. That is the #1207
# blocker-1 shape, and this test asserts the wrapper carries its own copy
# precisely so nobody "tidies up the duplication" and silently reopens it.
#
# ── WHAT THIS TEST DOES NOT DO ───────────────────────────────────────
# It does not execute install.sh and it does not call stat(1). The product
# code uses BSD `stat -f '%Lp'` because install.sh only ever runs on macOS.
# THIS TEST RUNS ON UBUNTU IN CI, where that is GNU stat and the flag means
# something else. Asserting on install.sh's TEXT is portable; asserting by
# running it is not. (#1207 arm-5c was exactly this trap.)
#
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
FAILED=0

failure() { echo "FAIL: $*" >&2; FAILED=1; }
pass()    { echo "ok: $*"; }

# ── WHY EVERY MATCH BELOW GOES THROUGH count_in ──────────────────────
# `printf '%s\n' "$BIG" | grep -q …` under `set -o pipefail` is a FALSE
# NEGATIVE GENERATOR. grep -q exits on the FIRST match; printf still has
# ~600 KB to write; printf takes SIGPIPE and exits 141; pipefail promotes
# 141 to the pipeline; and the `if` goes FALSE on a needle that IS THERE.
#
# I did not deduce that. I wrote this test with `grep -q` and its own
# CONTROL fired -- "_ostler_private_artefact is not defined" -- against a
# helper defined at install.sh:14895. install.sh is 1.3 MB. The pipe
# buffer is 64 KB. The same defect had been found in CM051 #1209 twenty
# minutes earlier and I reproduced it anyway, which is the argument for
# making it structurally impossible rather than remembering not to do it.
#
# `grep -c` MUST read to EOF to produce a count, so it never exits early
# and printf is never signalled. The count is then compared numerically,
# so the pipeline's exit status is not the decider at all. Two
# independent reasons this cannot false-pass.
count_in() {   # count_in <haystack> <grep-flag> <pattern>
    printf '%s\n' "$1" | /usr/bin/grep -c "$2" -- "$3"
}

[ -f "$INSTALL_SH" ] || {
    echo "FAIL: install.sh not found at ${INSTALL_SH} -- CANNOT-RUN, not a pass" >&2
    exit 1
}

# ── CONTROL 0: THE SUBJECT IS THE REAL FILE, NOT A STUB ──────────────
# A truncated or placeholder install.sh would give every "count is zero"
# assertion below a free pass.
BYTES="$(/usr/bin/wc -c < "$INSTALL_SH" | tr -d ' ')"
if [ "$BYTES" -lt 1000000 ]; then
    echo "FAIL: install.sh is ${BYTES} bytes, expected >1000000. The subject" >&2
    echo "      is not the shipping installer, so its zeros mean nothing." >&2
    echo "      CANNOT-RUN." >&2
    exit 1
fi
pass "control: install.sh is the real file (${BYTES} bytes)"

# ── COMMENTS ARE NOT CODE ────────────────────────────────────────────
# This file DOCUMENTS the old /tmp paths in its own header, and install.sh
# documents them in the comments above each fix. A predicate that counts
# comments would score those as live defects -- and, worse, the inverse
# error ships too: a gate that scores a COMMENT as code passes when the
# code is gone but the comment stays.
#
# CODE below is install.sh with WHOLE-LINE comments removed. Trailing
# comments after real code are NOT stripped.
#
# 🔴 An earlier version of this note said "no assertion here depends on
# that". THAT WAS FALSE, and the mutation arm proved it: two assertions
# in the heredoc limb were substring searches that a trailing comment
# satisfied. They are now anchored at line start so the needle must be a
# COMMAND. The stated bound and the actual bound have to be the same
# thing, or the note is worse than no note -- it tells the next reader
# not to look.
CODE="$(/usr/bin/sed -e 's/^[[:space:]]*#.*$//' "$INSTALL_SH")"

RAW_TMP="$(count_in "$CODE" -E "/tmp/ostler-")"

# ── CONTROL 1: THE PREDICATE CAN FIND A /tmp PATH AT ALL ─────────────
# THIS IS THE CONTROL THAT MATTERS. Every assertion below is "X does not
# appear". If the pattern is broken they all pass for free, forever, and
# the report could be silently restored to /tmp.
#
# install.sh legitimately writes ~26 diagnostic LOGS to /tmp. Those are a
# different class (#1207's OSTLER_DIAG_DIR work) and are deliberately out
# of scope here -- but they make a perfect positive control, because they
# prove this pattern matches real /tmp paths in this very file.
if [ "$RAW_TMP" -lt 1 ]; then
    echo "FAIL: the '/tmp/ostler-' pattern matches NOTHING in install.sh." >&2
    echo "      install.sh writes diagnostic logs there, so a zero means the" >&2
    echo "      PATTERN is broken, not that the installer is clean." >&2
    echo "      CANNOT-RUN." >&2
    exit 1
fi
pass "control: the /tmp pattern matches ${RAW_TMP} real paths (the log class, out of scope)"

# ── ASSERTION 1: NO DATA ARTEFACT ON A FIXED /tmp PATH ───────────────
# Shape-based, not name-based, so a THIRD data artefact added later is
# caught without anyone remembering to add it here. Logs are excluded by
# extension because they are the other class.
DATA_HITS="$(printf '%s\n' "$CODE" \
    | /usr/bin/grep -nE '/tmp/[A-Za-z0-9._-]*\.(yaml|yml|json|csv|db|sqlite|txt)' \
    | /usr/bin/grep -v '\.log' || true)"
if [ -n "$DATA_HITS" ]; then
    failure "install.sh writes a DATA artefact to a fixed /tmp path (#912)."
    echo "      /private/tmp is drwxrwxrwt and umask 022 makes these 0644," >&2
    echo "      so any other local account reads them with cat." >&2
    echo "      Offending line(s):" >&2
    printf '%s\n' "$DATA_HITS" | /usr/bin/sed 's/^/        /' >&2
else
    pass "no data artefact is written to a fixed /tmp path"
fi

# ── ASSERTION 2: THE TWO KNOWN NAMES, BY NAME ────────────────────────
# Belt and braces. If assertion 1's extension list ever drifts, these two
# are still named explicitly because they are the ones we KNOW leaked.
for artefact in ostler-dedupe-report.yaml ostler-aiconv-summary.json; do
    if [ "$(count_in "$CODE" -F "/tmp/${artefact}")" -gt 0 ]; then
        failure "/tmp/${artefact} is still written by install.sh (#912)"
    else
        pass "/tmp/${artefact} is gone from the code"
    fi
done

# ── CONTROL 2: THE HELPER EXISTS ─────────────────────────────────────
# Without this, every "the call sites use the helper" assertion below
# could be satisfied by a file that has no helper and no call sites.
if [ "$(count_in "$CODE" -F "_ostler_private_artefact() {")" -lt 1 ]; then
    echo "FAIL: _ostler_private_artefact is not defined in install.sh." >&2
    echo "      The subject of this test is absent. CANNOT-RUN." >&2
    exit 1
fi
pass "control: _ostler_private_artefact is defined"

# ── ASSERTION 3: THE HELPER REFUSES RATHER THAN FALLING BACK ─────────
# The whole point is that there is NO second-choice path. Any /tmp inside
# the helper body would be a fallback, and every fallback is a
# world-readable one.
# 🔴 EVERY copy, not the first. This used to `exit` at the end of the
# first body, which was safe only while exactly one helper existed. #568
# added a SECOND copy in the main body (the heredoc copy resolves only in
# the generated script's shell), and because the new one sorts EARLIER in
# the file the old range stopped there -- leaving the original,
# heredoc-resident helper completely uninspected. A clean first copy
# SATISFIED this assertion on behalf of a defective second one.
#
# Proved, not reasoned: with the old range, the mutation arm that adds a
# /tmp fallback to the HEREDOC copy passed the guard. A guard that reads
# "there exists a good helper" cannot answer "are all helpers good".
#
# The terminator also has to tolerate both brace indentations -- the
# heredoc copy closes on '    }' and the main-body copy on '}'.
HELPER_DEFS="$(count_in "$CODE" -F "_ostler_private_artefact() {")"
HELPER_SCAN="$(printf '%s\n' "$CODE" | /usr/bin/awk '
    /^_ostler_private_artefact\(\) \{/    { inb = 1; bodies++ }
    inb                                   { print }
    inb && /^[[:space:]]*\}[[:space:]]*$/ { inb = 0 }
    END                                   { printf "###BODIES=%d\n", bodies + 0 }
')"
HELPER_BODIES="$(printf '%s\n' "$HELPER_SCAN" | /usr/bin/sed -n 's/^###BODIES=//p')"
HELPER_BODY="$(printf '%s\n' "$HELPER_SCAN" | /usr/bin/grep -vF '###BODIES=')"
if [ -z "$HELPER_BODY" ]; then
    echo "FAIL: the helper body extracted EMPTY -- the awk range is wrong, so" >&2
    echo "      the assertions below would be vacuous. CANNOT-RUN." >&2
    exit 1
fi
# CONTROL: one extracted body per definition. If a future copy lands
# somewhere this range cannot close, the counts diverge and we refuse
# rather than silently inspecting a subset.
if [ "${HELPER_BODIES:-0}" != "${HELPER_DEFS}" ]; then
    echo "FAIL: ${HELPER_DEFS} helper definitions but ${HELPER_BODIES:-0} bodies" >&2
    echo "      extracted. The range missed one, so any verdict below would" >&2
    echo "      cover a SUBSET of the helpers. CANNOT-RUN, not a pass." >&2
    exit 1
fi
pass "control: ${HELPER_BODIES} helper body/bodies extracted, one per definition"

if [ "$(count_in "$HELPER_BODY" -F "/tmp")" -gt 0 ]; then
    failure "_ostler_private_artefact mentions /tmp in its body -- it has a fallback"
else
    pass "the helper has no /tmp fallback"
fi
# ANCHORED AT LINE START, so the needle has to be a COMMAND and not a
# mention. See the note above assertion 5 -- a substring search for
# 'chmod 700' is satisfied by a line that only TALKS about chmod 700.
if [ "$(count_in "$HELPER_BODY" -E '^[[:space:]]*chmod 700 ')" -lt 1 ]; then
    failure "_ostler_private_artefact does not RUN chmod 700 (a mention is not a call)"
fi
if [ "$(count_in "$HELPER_BODY" -E '^[[:space:]]*\[ "\$\{?_mode' )" -lt 1 ]; then
    failure "_ostler_private_artefact does not verify the resulting mode"
fi
pass "the helper creates its directory 0700 and verifies the mode"

# ── ASSERTION 4: THE TWO REACHABLE SITES CALL THE HELPER ─────────────
CALLS="$(printf '%s\n' "$CODE" | /usr/bin/grep -cF '$(_ostler_private_artefact ')"
if [ "$CALLS" -lt 2 ]; then
    failure "only ${CALLS} call site(s) use _ostler_private_artefact, expected >= 2"
    echo "      The dedupe report and the AI-conversations summary are both" >&2
    echo "      reachable from ordinary install.sh shell and must both use it." >&2
else
    pass "${CALLS} call sites use the helper"
fi

# ── THE HEREDOC LIMB ─────────────────────────────────────────────────
# Compute the QUOTED heredoc's real bounds rather than trusting a line
# number, which rots on the next edit above it.
HD_START="$(/usr/bin/grep -n "cat > \"\$wrapper\" <<'DCUEOF'" "$INSTALL_SH" | /usr/bin/head -1 | /usr/bin/cut -d: -f1)"
if [ -z "${HD_START:-}" ]; then
    echo "FAIL: the dedupe-catchup quoted heredoc opener was not found." >&2
    echo "      Either the wrapper was restructured or it is no longer a" >&2
    echo "      quoted heredoc. Both change what this limb must assert." >&2
    echo "      CANNOT-RUN -- fix this arm, do not delete it." >&2
    exit 1
fi
HD_END="$(/usr/bin/awk -v s="$HD_START" 'NR > s && $0 == "DCUEOF" { print NR; exit }' "$INSTALL_SH")"
if [ -z "${HD_END:-}" ]; then
    echo "FAIL: the DCUEOF terminator was not found after line ${HD_START}." >&2
    echo "      CANNOT-RUN." >&2
    exit 1
fi
pass "control: the quoted heredoc spans ${HD_START}..${HD_END}"

# Comment-stripped, for the same reason CODE is. The wrapper's own header
# DOCUMENTS the old /tmp path and DOCUMENTS why calling the helper here
# would be inert -- naming both of the things the two assertions below
# look for. Slicing the raw file scores those comments as code and fails
# on a correct tree, which is precisely how it failed when I first ran it.
HD_BODY="$(/usr/bin/awk -v s="$HD_START" -v e="$HD_END" 'NR > s && NR < e' "$INSTALL_SH" \
    | /usr/bin/sed -e 's/^[[:space:]]*#.*$//')"
if [ -z "$(printf '%s' "$HD_BODY" | tr -d '[:space:]')" ]; then
    echo "FAIL: the heredoc body is empty after comment-stripping -- the slice" >&2
    echo "      or the strip is wrong, so both assertions below would be" >&2
    echo "      vacuous. CANNOT-RUN." >&2
    exit 1
fi
pass "control: the heredoc body is non-empty after comment-stripping"

# ── ASSERTION 5: THE WRAPPER CARRIES ITS OWN 0700 LOGIC ──────────────
# It CANNOT call the helper -- the helper does not exist in the generated
# script's shell. So it must do the work itself, and it must refuse.
if [ "$(count_in "$HD_BODY" -F "_ostler_private_artefact")" -gt 0 ]; then
    failure "the DCUEOF wrapper calls _ostler_private_artefact -- INERT (#1207 blocker-1)"
    echo "      A quoted heredoc resolves in the generated script's OWN" >&2
    echo "      shell, where install.sh's functions do not exist. That call" >&2
    echo "      is byte-identical to a working fix and does nothing." >&2
else
    pass "the wrapper does not call the helper (which would be inert there)"
fi
# 🔴 ANCHORED AT LINE START, AND THE REASON IS A HOLE THIS TEST HAD.
#
# These were substring searches. The mutation arm that replaces
#
#     chmod 700 "$PRIVATE_DIR"
# with
#     :  # chmod 700 "$PRIVATE_DIR"
#
# left the guard GREEN: the comment-strip above removes WHOLE-LINE
# comments only, so the needle survived as a TRAILING comment on a line
# that does nothing. The wrapper would have shipped with no 0700
# enforcement at all and this file would have said it was fine.
#
# It was caught by tests/test_sensitive_artefacts_guard_fires.sh arm 5,
# which is the entire argument for having a mutation arm per defect
# rather than one that only exercises the assertion you were thinking
# about when you wrote it.
#
# Anchoring makes the needle a COMMAND rather than a mention. That is
# the general repair for this class: do not ask whether the text is
# present, ask whether it is in a position where the shell would run it.
if [ "$(count_in "$HD_BODY" -E '^[[:space:]]*chmod 700 ')" -lt 1 ]; then
    failure "the DCUEOF wrapper does not RUN chmod 700 (a mention is not a call)"
fi
if [ "$(count_in "$HD_BODY" -E '^[[:space:]]*log "REFUSING')" -lt 1 ]; then
    failure "the DCUEOF wrapper does not refuse when its directory is not 0700"
fi
if [ "$(count_in "$HD_BODY" -E '/tmp/[A-Za-z0-9._-]*\.(yaml|yml|json)')" -gt 0 ]; then
    failure "the DCUEOF wrapper still writes a data artefact under /tmp (#912)"
else
    pass "the wrapper writes its report outside /tmp, with its own 0700 guard"
fi

# ── ASSERTION 6: THE FAIL-OPEN FALLBACK IS GONE ──────────────────────
# The specific shape: mktemp on the left, a bare /tmp path on the right.
if [ "$(count_in "$CODE" -E 'mktemp.*\|\|.*=/tmp/')" -gt 0 ]; then
    failure "a mktemp fallback still lands on a fixed /tmp path -- FAILS OPEN (#912)"
else
    pass "no mktemp site falls back to a fixed /tmp path"
fi

if [ "$FAILED" -ne 0 ]; then
    echo "" >&2
    echo "private-artefact exposure guard: FAIL" >&2
    exit 1
fi
echo ""
echo "private-artefact exposure guard: PASS"
