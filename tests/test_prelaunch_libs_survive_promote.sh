#!/usr/bin/env bash
#
# test_prelaunch_libs_survive_promote.sh
#
# Guards the defect measured on the walk box on 2026-09-23, on an install
# that reported status=ok failed_steps=0 errors=0:
#
#     ~/.ostler/lib/  held TWO files, ostler_store_auth.py and
#     ostler-container-engine.sh. ostler-ingest-slot.sh,
#     ostler-resource-tier.sh and ostler-detect-exports.sh were absent,
#     and ~/.ostler/lib had not been touched since the install finished.
#
# ---------------------------------------------------------------------
# The mechanism
# ---------------------------------------------------------------------
# install.sh does not write into ~/.ostler during Phase 2. It writes into
# a staging tree, /tmp/ostler-prelaunch-<pid>, and promotes that tree to
# ~/.ostler later:
#
#     install.sh  OSTLER_PRELAUNCH_DIR="${OSTLER_PRELAUNCH_DIR:-/tmp/ostler-prelaunch-$$}"
#     install.sh  _ostler_set_paths "$OSTLER_PRELAUNCH_DIR"     <- OSTLER_DIR = staging
#
# The promote walks the staging tree PER TOP-LEVEL ENTRY and, for every
# name that already exists in the final tree, REPLACES it:
#
#     if [[ -e "${OSTLER_FINAL_DIR}/${name}" ]]; then
#         rm -rf "${OSTLER_FINAL_DIR}/${name}"
#     fi
#     mv "$entry" "${OSTLER_FINAL_DIR}/${name}"
#
# `lib` is one of those top-level entries, because ostler_store_auth.py is
# staged into "${OSTLER_DIR}/lib". So anything written STRAIGHT into
# ~/.ostler/lib before the promote is deleted by it, without a word.
#
# Three libs were written that way, with a literal ${HOME}/.ostler/lib
# instead of the staging-aware ${OSTLER_DIR}/lib. They were written, they
# were used during the install (ostler-detect-exports.sh produced the
# archive-scan counts in the transcript), and then the promote removed
# them. The customer-visible consequence is that the wiki summary
# backfill and the conversation feeds find no ostler-ingest-slot.sh and
# fall back to an unbounded mkdir mutex, which is the exact starvation
# lib/ostler-ingest-slot.sh was written to end.
#
# ---------------------------------------------------------------------
# Why tests/test_ingest_slot_fairness.sh did not catch it
# ---------------------------------------------------------------------
# Its Section 7 is called "delivery". It greps install.sh for the heredoc
# delimiter, greps install.sh for the chmod line, and compares the
# embedded text with lib/ostler-ingest-slot.sh. All three assertions are
# about text inside install.sh. None of them runs install.sh, models the
# promote, or looks at an installed tree. Comparing two copies of a file
# says nothing about whether either one reaches a customer.
#
# This test does the thing that was missing: it runs the REAL write
# statements and the REAL promote function, both extracted from
# install.sh, and then asks whether the file is there.
#
# ---------------------------------------------------------------------
# Outcomes
# ---------------------------------------------------------------------
#   0  PASS        every embedded lib survives the promote
#   1  FAIL        at least one does not
#   2  CANNOT-RUN  the harness could not measure. Never reported as PASS.
#
# Run:  bash tests/test_prelaunch_libs_survive_promote.sh
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"

FAILED=0
pass()       { echo "ok: $*"; }
failure()    { echo "FAIL: $*" >&2; FAILED=1; }
cannot_run() { echo "CANNOT-RUN: $*" >&2; exit 2; }

# The embedded libs this test is responsible for, as
# <heredoc delimiter>:<basename it must end up as>.
EMBEDS="
OSTLER_DETECT_EXPORTS_EOF:ostler-detect-exports.sh
OSTLER_RESOURCE_TIER_EOF:ostler-resource-tier.sh
OSTLER_INGEST_SLOT_EOF:ostler-ingest-slot.sh
OSTLER_APP_WARMUP_EOF:ostler-app-warmup.sh
"

# ---------------------------------------------------------------------
# Section 1 -- preconditions. Anything missing here is CANNOT-RUN, not a
# pass. A harness that cannot find its subject has measured nothing, and
# saying so is the whole point of having a third outcome.
# ---------------------------------------------------------------------
echo "== Section 1: preconditions =="

[ -f "$INSTALL_SH" ] || cannot_run "install.sh not found at $INSTALL_SH"

PROMOTE_FN="$(awk '/^_ostler_promote_prelaunch_tree\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}' "$INSTALL_SH")"
PROMOTE_LINES="$(printf '%s\n' "$PROMOTE_FN" | grep -c .)"
if [ "$PROMOTE_LINES" -lt 20 ]; then
    cannot_run "extracted only $PROMOTE_LINES lines of _ostler_promote_prelaunch_tree; the extractor is not matching, so any verdict below would be manufactured"
fi
pass "extracted _ostler_promote_prelaunch_tree ($PROMOTE_LINES lines)"

EMBED_COUNT=0
for pair in $EMBEDS; do
    delim="${pair%%:*}"
    chunk="$(awk -v d="$delim" '$0 ~ ("<<'\''" d "'\''$"){f=1} f{print} f && $0 == d {exit}' "$INSTALL_SH")"
    lines="$(printf '%s\n' "$chunk" | grep -c .)"
    if [ "$lines" -lt 20 ]; then
        cannot_run "extracted only $lines lines for $delim; install.sh no longer embeds it in the shape this test knows how to run"
    fi
    EMBED_COUNT=$((EMBED_COUNT + 1))
done
if [ "$EMBED_COUNT" -ne 4 ]; then
    cannot_run "expected 4 embedded libs, located $EMBED_COUNT"
fi
pass "located all $EMBED_COUNT embedded libs in install.sh"

# ---------------------------------------------------------------------
# A sandbox that mirrors install.sh's own layout: a final tree the
# customer keeps, and a staging tree the promote consumes.
# ---------------------------------------------------------------------
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
FAKE_HOME="$SANDBOX/home"
FINAL="$FAKE_HOME/.ostler"
STAGING="$SANDBOX/ostler-prelaunch-test"

run_promote() {
    # Runs the REAL promote function out of install.sh. Its optional
    # helpers are already guarded by `declare -f`; the unguarded ones are
    # stubbed, because this test is about where files end up and nothing
    # else.
    HOME="$FAKE_HOME" bash -c '
        set -uo pipefail
        OSTLER_FINAL_DIR="$1"
        OSTLER_PRELAUNCH_DIR="$2"
        OSTLER_DIR="$OSTLER_PRELAUNCH_DIR"
        OSTLER_PRELAUNCH_PROMOTED=false
        _ostler_quiesce_interval_agents()   { :; }
        _ostler_set_paths()                 { OSTLER_DIR="$1"; }
        _ostler_repair_venv_after_promote() { :; }
        _ostler_promote_venv_note()         { :; }
        eval "$3"
        _ostler_promote_prelaunch_tree
    ' _ "$FINAL" "$STAGING" "$PROMOTE_FN"
}

# ---------------------------------------------------------------------
# Section 2 -- MECHANISM CONTROL, taken before the subject is measured.
#
# The promote must really destroy a file that was written into the final
# tree ahead of it. If it does not, the hazard this guard exists for is
# gone and every PASS below would be vacuous, so that reads CANNOT-RUN
# rather than a green.
# ---------------------------------------------------------------------
echo
echo "== Section 2: mechanism control =="

rm -rf "$SANDBOX"/*; mkdir -p "$FINAL/lib" "$STAGING/lib"
echo "written straight into the final tree" > "$FINAL/lib/control-clobbered.txt"
echo "staged, so it is carried by the promote" > "$STAGING/lib/control-staged.txt"
run_promote >/dev/null 2>&1

if [ -e "$FINAL/lib/control-clobbered.txt" ]; then
    cannot_run "the promote did NOT remove a file written into ${FINAL}/lib ahead of it. The clobber this test guards no longer happens, so a pass in Section 3 would prove nothing. Re-read _ostler_promote_prelaunch_tree before trusting this file again."
fi
pass "control: a file written into the final lib/ before the promote IS destroyed by it"

# The other half of the control. If the harness cannot observe a SUCCESS
# either, then every result it produces is the same result, and a FAIL
# below would be as meaningless as a PASS.
if [ ! -e "$FINAL/lib/control-staged.txt" ]; then
    cannot_run "a file staged in ${STAGING}/lib did not arrive in ${FINAL}/lib. The harness cannot observe a success, so it cannot distinguish one from a failure."
fi
pass "control: a file staged through the staging tree DOES arrive (harness can see a success)"

# ---------------------------------------------------------------------
# Section 3 -- the subject. Run the real write statements, then the real
# promote, then ask the question a customer's Mac asks: is the file
# there?
# ---------------------------------------------------------------------
echo
echo "== Section 3: every embedded lib survives the promote =="

rm -rf "$SANDBOX"/*; mkdir -p "$FINAL/lib" "$STAGING/lib"

# ostler_store_auth.py is staged via ${OSTLER_DIR}/lib by install.sh, and
# it is the reason lib/ is a top-level entry in the staging tree at all.
# Without it there is no staging lib/ to promote and the clobber never
# fires, so the sandbox would be unrepresentative of a real install.
echo "# stand-in for the store-auth shim install.sh stages via \${OSTLER_DIR}/lib" \
    > "$STAGING/lib/ostler_store_auth.py"

WROTE=0
for pair in $EMBEDS; do
    delim="${pair%%:*}"
    chunk="$(awk -v d="$delim" '$0 ~ ("<<'\''" d "'\''$"){f=1} f{print} f && $0 == d {exit}' "$INSTALL_SH")"
    # The real statement, run verbatim, with the two variables install.sh
    # has in scope at that point in Phase 2.
    if HOME="$FAKE_HOME" OSTLER_DIR="$STAGING" bash -c "$chunk" 2>/dev/null; then
        WROTE=$((WROTE + 1))
    else
        failure "the write statement for $delim did not run"
    fi
done
if [ "$WROTE" -ne 4 ]; then
    cannot_run "only $WROTE of 4 write statements ran; nothing below would be measuring the shipped behaviour"
fi
pass "ran all 4 embedded write statements as install.sh runs them"

run_promote >/dev/null 2>&1

CHECKED=0
for pair in $EMBEDS; do
    name="${pair##*:}"
    CHECKED=$((CHECKED + 1))
    if [ -f "$FINAL/lib/$name" ]; then
        pass "$name is present in the installed lib/ after the promote"
    else
        failure "$name is NOT in the installed lib/ after the promote. install.sh writes it to a literal \${HOME}/.ostler/lib, which the promote deletes before moving the staging lib/ over it. Write it to \${OSTLER_DIR}/lib instead, as ostler_store_auth.py already is."
    fi
done
echo "examined $CHECKED embedded libs"
if [ "$CHECKED" -ne 4 ]; then
    cannot_run "examined $CHECKED libs, expected 4"
fi

# ---------------------------------------------------------------------
# Section 4 -- the class, not just the three instances. Any NEW write of
# this shape is the same defect, so name them all rather than only the
# ones already known to be broken.
# ---------------------------------------------------------------------
echo
echo "== Section 4: no install-time write targets the final tree directly =="

OFFENDERS="$(grep -n -E '^[[:space:]]*(cat|cp|tee|mv|chmod|mkdir)[^|]*"\$\{HOME\}/\.ostler/lib' "$INSTALL_SH" || true)"
if [ -n "$OFFENDERS" ]; then
    echo "$OFFENDERS" | while IFS= read -r line; do
        echo "  $line"
    done
    failure "$(printf '%s\n' "$OFFENDERS" | grep -c .) install.sh line(s) write into \${HOME}/.ostler/lib during Phase 2. That path is the FINAL tree; the promote replaces lib/ wholesale, so these writes are discarded. Use \${OSTLER_DIR}/lib, which _ostler_set_paths keeps correct on both sides of the promote."
else
    pass "no install.sh line writes into a literal \${HOME}/.ostler/lib"
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "PASS: every embedded lib reaches the installed tree"
    exit 0
fi
echo "FAILED" >&2
exit 1
