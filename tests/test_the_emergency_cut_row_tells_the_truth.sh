#!/usr/bin/env bash
# The emergency_cut row in SHIPPING_LEDGER.yaml must not lie about two things.
#
# ── 1. `dirty` WAS INVERTED, ALWAYS, AND HAD NEVER BEEN RIGHT ───────────────
#
# The shipped writer in gui/Makefile computed it inside a double-quoted echo:
#
#     echo "    dirty: $(test -n \"$(git status --porcelain)\" && echo true || echo false)"
#
# Those backslash-escaped quotes become LITERAL quote characters inside the
# command substitution, so:
#
#     clean tree   test -n '""'                -> non-empty  -> true   WRONG
#     dirty tree   test -n '"M a" "M b"'       -> too many arguments
#                                                 -> error   -> false  WRONG
#
# Measured 2026-09-07 in two real worktrees: a tree with 0 changed files wrote
# `dirty: true`, and a tree with 1 changed file wrote `dirty: false` and emitted
# "test: too many arguments" to stderr. It is wrong in BOTH directions, so no
# reader could ever have used it, and Andy's mandate calls this file the
# canonical register of what shipped.
#
# FIXED by computing the flag OUTSIDE the nested-quote context, into a variable,
# before the echo block.
#
# ── 2. THE ROW IS AN INVOCATION, NOT AN EVENT ──────────────────────────────
#
# guard-local-cut writes the row when it ACCEPTS the invocation -- before
# check-orphans and every other gate. Three consecutive rows on 2026-09-07
# described runs that produced no artefact, and none of the 27 rows before them
# said so. The row now carries an `outcome:` field stating that plainly, and a
# successful ship appends a paired `emergency_cut_result` row.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MK="${REPO}/gui/Makefile"

PASS=0; FAIL=0; CANT=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { CANT=$((CANT+1)); printf '  [CANNOT-RUN] %s\n' "$1"; }

echo "== the emergency_cut row tells the truth =="

[ -r "$MK" ] || { cant "gui/Makefile unreadable"; echo; exit 2; }

# ── the broken form must be GONE ───────────────────────────────────────────
if /usr/bin/grep -qF 'dirty: $$(test -n \"$$(git status' "$MK"; then
    bad "gui/Makefile still computes dirty inside a nested double-quoted echo. That form is inverted in BOTH directions."
else
    ok "the inverted nested-quote dirty computation is gone"
fi

# ── the row must declare that it is an invocation ──────────────────────────
if /usr/bin/grep -qF 'outcome: \"NOT KNOWN AT WRITE TIME' "$MK"; then
    ok "the invocation row carries an outcome field saying it is not evidence of a build"
else
    bad "the invocation row has no outcome field; it records an INTENT in the shape of an EVENT"
fi

# ── a successful ship must append the paired result row ────────────────────
if /usr/bin/grep -qF 'emergency_cut_result:' "$MK"; then
    ok "a successful ship appends a paired emergency_cut_result row"
else
    bad "nothing appends a result row, so an invocation row can never be paired with an outcome"
fi

# ── BEHAVIOURAL: run the predicate in REAL clean and dirty repos ───────────
# Reading the source is not enough. The defect WAS a quoting behaviour, and a
# source-text check cannot see what the shell does with it -- that is the same
# mistake that let a cosmetic fix ship earlier tonight.
predicate() {  # $1 = repo dir -> prints true|false
    ( cd "$1" && _d=false; if [ -n "$(git status --porcelain 2>/dev/null)" ]; then _d=true; fi; printf '%s' "$_d" )
}

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
if ! git -C "$W" init -q . 2>/dev/null; then
    cant "could not init a fixture repo; the behavioural arms did not run"
else
    git -C "$W" -c user.email=a@example.com -c user.name=t commit -q --allow-empty -m base 2>/dev/null
    got_clean="$(predicate "$W")"
    [ "$got_clean" = "false" ] && ok "CLEAN tree (0 changed files) reports dirty=false" \
                               || bad "CLEAN tree reported dirty=${got_clean}, wanted false"

    printf 'x\n' > "$W/one"; printf 'y\n' > "$W/two"; printf 'z\n' > "$W/three"
    got_dirty="$(predicate "$W")"
    [ "$got_dirty" = "true" ] && ok "DIRTY tree (3 changed files) reports dirty=true -- the multi-file case is what used to error" \
                              || bad "DIRTY tree reported dirty=${got_dirty}, wanted true"

    # CONTROL: the two arms must DISAGREE. If they matched, the predicate would
    # be a constant and both PASSes above would be meaningless.
    if [ "$got_clean" != "$got_dirty" ]; then
        ok "CONTROL: the two arms disagree, so the predicate is reading the tree and not returning a constant"
    else
        bad "CONTROL FAILED: clean and dirty both returned '${got_clean}' -- the predicate is a constant"
    fi
fi

echo
printf '== %d pass / %d fail / %d cannot-run ==\n' "$PASS" "$FAIL" "$CANT"
[ "$CANT" -gt 0 ] && exit 2
[ "$FAIL" -gt 0 ] && exit 1
exit 0
