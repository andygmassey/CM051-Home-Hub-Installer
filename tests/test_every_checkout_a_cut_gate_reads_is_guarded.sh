#!/usr/bin/env bash
#
# test_every_checkout_a_cut_gate_reads_is_guarded.sh -- #1550.
#
# PROVED-RED-BY: this file, mutations M1, M2 and M3.
#
# ============================================================================
# WHAT THIS EXISTS FOR
# ============================================================================
#
# During the v1.0.70 cut preflight, 2026-09-05, run_all_cut_gates.sh returned
# "13 green | 2 red" and refused the assembly on that tally. Both reds were
# artefacts of the operator's environment: CM044-PWG-Personal-Wiki was on a
# feature branch seven
# commits behind main, and the content gate compared the shipped image against
# it and returned a CONFIDENT RED on an image that was provably correct.
#
# A branch guard for CM044 landed after that. MEASURED ON origin/main
# 2026-09-16, two halves of the same defect were still open:
#
#   OSTLER_ASSISTANT_DIR in scripts/run_all_cut_gates.sh      0 occurrences
#   CM044_DIR in the same file (POSITIVE CONTROL)            20 occurrences
#
# so the zero was a real absence and not a broken pattern. Three cut gates read
# that checkout -- cut provenance, content provenance, vendor pair drift -- and
# all three were invoked bare. That side fails towards a false GREEN: the
# vendor-pair gate compares a run-source enum in one tree against an array in
# the other, so a feature-branch enum and a main wrapper can agree by accident.
#
#   fetch in scripts/run_all_cut_gates.sh                     0 occurrences
#
# so the comparison was against a cached remote ref of unknown age.
#
# AND THE GUARD THAT DID EXIST HAD NO PROOF IT COULD FIRE:
#
#   _cm044_branch_ok across tests/ and .github/               0 hits
#   _interpreter_died across the same (POSITIVE CONTROL)      2 hits
#
# ============================================================================
# WHAT IT ASSERTS, IN TWO PARTS, BECAUSE THERE ARE TWO WAYS TO GET THIS WRONG
# ============================================================================
#
# PART A -- the verdict is right. Real git repositories are built here and
# driven through `run_all_cut_gates.sh --print-checkout-guard`, which prints the
# very variables the gate calls consume rather than recomputing them.
#
# PART B -- the gates consume it. A correct verdict wired to nothing is the
# failure mode that produced #1550 in the first place, so the three gate
# invocations are checked against a NEGATIVE CONTROL: "cut freshness" reads no
# guarded checkout and must NOT be guarded, which is how this test knows its
# predicate is not simply matching everything.
#
# British English throughout; " -- " not em-dashes.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$HERE/scripts/run_all_cut_gates.sh"
LIB="$HERE/scripts/lib/checkout_guard.sh"
[ -r "$RUNNER" ] || { echo "CANNOT-RUN: no runner at $RUNNER" >&2; exit 2; }
[ -r "$LIB" ]    || { echo "CANNOT-RUN: no guard library at $LIB" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "CANNOT-RUN: no git" >&2; exit 2; }

TMP="$(mktemp -d -t ckguard_XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { printf '  ok    %s\n' "$1"; PASS=$((PASS + 1)); }
no() { printf '  FAIL  %s\n' "$1"; printf '%s\n' "${2:-}" | sed 's/^/        | /'; FAIL=$((FAIL + 1)); }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# ---------------------------------------------------------------------------
# A local origin and clones of it. Local paths only: a test that needs the
# network is a test that reports CANNOT-RUN on a bad day and gets ignored.
# ---------------------------------------------------------------------------
ORIGIN="$TMP/origin.git"
git init -q --bare "$ORIGIN"
SEED="$TMP/seed"
git init -q "$SEED"
git -C "$SEED" symbolic-ref HEAD refs/heads/main
echo one > "$SEED/f"; git -C "$SEED" add -A; git -C "$SEED" commit -qm one
git -C "$SEED" remote add origin "$ORIGIN"; git -C "$SEED" push -q origin main

clone() { git clone -q "$ORIGIN" "$1"; }

# AT THE TIP -- the healthy case, and the positive control for every refusal.
clone "$TMP/atmain"

# BEHIND, ON A FEATURE BRANCH -- the 2026-09-05 reading exactly.
clone "$TMP/stale"
git -C "$TMP/stale" checkout -q -b feature/left-here
echo two >> "$SEED/f"; git -C "$SEED" commit -qam two; git -C "$SEED" push -q origin main

# AHEAD -- a local commit nobody reviewed is as unreviewed as a missing one.
clone "$TMP/ahead"
git -C "$TMP/ahead" pull -q --ff-only 2>/dev/null
echo local >> "$TMP/ahead/f"; git -C "$TMP/ahead" commit -qam local

# CACHED-STALE -- HEAD equals the origin/main this clone last fetched, and the
# real origin has moved since. Without a fetch this is indistinguishable from
# healthy, which is the whole of the "no fetch anywhere in the script" finding.
clone "$TMP/cached"
echo three >> "$SEED/f"; git -C "$SEED" commit -qam three; git -C "$SEED" push -q origin main

# Bring the other two up to date so they stay at the tip after those pushes.
git -C "$TMP/atmain" fetch -q origin main && git -C "$TMP/atmain" reset -q --hard origin/main
git -C "$TMP/stale" fetch -q origin main

guard() {   # guard <outfile> [ENV=V ...] -- runs the real runner's guard mode
    local out="$1"; shift
    env CM044_DIR="${CM044_DIR_T:-$TMP/atmain}" "$@" \
        /bin/bash "$RUNNER" --print-checkout-guard > "$out" 2>"${out}.err"
    echo $?
}

blockof() { awk -F'\t' -v g="$2" '$1=="GATEBLOCK" && $2==g {print $3; exit}' "$1"; }
stateof() { awk -F'\t' -v v="$2" '$1=="CHECKOUT" && $2==v {print $4; exit}' "$1"; }

VENDOR_GATES="cut provenance|content provenance|vendor pair drift"

echo "test_every_checkout_a_cut_gate_reads_is_guarded"
echo
echo "  -- part A: the verdict --"

# ---------------------------------------------------------------------------
# 0. CONTROL. The mode must run and emit every row, or each read below is the
#    empty string compared against the empty string.
# ---------------------------------------------------------------------------
rc="$(guard "$TMP/a0" OSTLER_ASSISTANT_DIR="$TMP/atmain")"
n_ck="$(awk -F'\t' '$1=="CHECKOUT"' "$TMP/a0" | grep -c . || true)"
n_gb="$(awk -F'\t' '$1=="GATEBLOCK"' "$TMP/a0" | grep -c . || true)"
if [ "$rc" != 0 ] || [ "${n_ck:-0}" -lt 3 ] || [ "${n_gb:-0}" -lt 4 ]; then
    no "(0) CONTROL FAILED: rc=${rc}, ${n_ck} CHECKOUT row(s), ${n_gb} GATEBLOCK row(s)" "$(cat "$TMP/a0" "$TMP/a0.err" 2>/dev/null)"
    echo; echo "=== ${PASS} passed / ${FAIL} failed ==="; exit 1
fi
ok "(0) CONTROL: the guard mode ran and reported ${n_ck} checkout(s) and ${n_gb} gate(s)"

# ---------------------------------------------------------------------------
# 1. POSITIVE CONTROL for the healthy case. A checkout at the tip must NOT
#    block, or "it blocks" below would just mean it blocks on everything.
# ---------------------------------------------------------------------------
bad=""
for g in cut\ provenance content\ provenance vendor\ pair\ drift; do
    [ "$(blockof "$TMP/a0" "$g")" = "-" ] || bad="${bad} [${g}]"
done
[ -z "$bad" ] \
    && ok "(1) CONTROL: with every checkout at the tip of main, none of the three vendor gates is blocked" \
    || no "(1) CONTROL FAILED: a healthy checkout still blocked${bad}" "$(cat "$TMP/a0")"

# ---------------------------------------------------------------------------
# 2. THE HALF THAT WAS MISSING. A stale ostler-assistant checkout must make
#    ALL THREE gates that read it CANNOT-RUN. This is the false-GREEN side.
# ---------------------------------------------------------------------------
rc="$(guard "$TMP/a2" OSTLER_ASSISTANT_DIR="$TMP/stale")"
missed=""
for g in cut\ provenance content\ provenance vendor\ pair\ drift; do
    w="$(blockof "$TMP/a2" "$g")"
    case "$w" in
        -|"") missed="${missed} [${g}]" ;;
    esac
done
if [ -n "$missed" ]; then
    no "(2) #1550's untouched half is still open: a stale OSTLER_ASSISTANT_DIR did not block${missed}" "$(cat "$TMP/a2")"
else
    w="$(blockof "$TMP/a2" "vendor pair drift")"
    case "$w" in
        *OSTLER_ASSISTANT_DIR*feature/left-here*)
            ok "(2) a stale OSTLER_ASSISTANT_DIR blocks all three gates that read it, naming the variable and the branch" ;;
        *)
            no "(2) all three blocked, but the reason does not name OSTLER_ASSISTANT_DIR and the branch, so the operator cannot act on it" "$w" ;;
    esac
fi

# ---------------------------------------------------------------------------
# 3. AHEAD IS OFF THE TIP TOO. `rev-list --count HEAD..origin/main` answers
#    only "behind"; local unreviewed commits are the other direction.
# ---------------------------------------------------------------------------
rc="$(guard "$TMP/a3" OSTLER_ASSISTANT_DIR="$TMP/ahead")"
w="$(blockof "$TMP/a3" "vendor pair drift")"
[ "$w" != "-" ] && [ -n "$w" ] \
    && ok "(3) a checkout AHEAD of origin/main blocks: unreviewed local commits are not the reviewed tree either" \
    || no "(3) a checkout with a local unreviewed commit was accepted as the reviewed tree" "$(cat "$TMP/a3")"

# ---------------------------------------------------------------------------
# 4. THE FETCH IS PART OF THE CHECK, and this is the discriminating pair.
#    The SAME checkout reads healthy against its cached ref and stale once the
#    remote is consulted. If the fetch were not happening, both halves would
#    print "-" and the pair would be vacuous.
# ---------------------------------------------------------------------------
rc="$(guard "$TMP/a4no" OSTLER_ASSISTANT_DIR="$TMP/cached" OSTLER_CUT_GATES_FETCH=0)"
rc="$(guard "$TMP/a4yes" OSTLER_ASSISTANT_DIR="$TMP/cached")"
w_no="$(blockof "$TMP/a4no" "vendor pair drift")"
w_yes="$(blockof "$TMP/a4yes" "vendor pair drift")"
if [ "$w_no" = "-" ] && [ "$w_yes" != "-" ] && [ -n "$w_yes" ]; then
    ok "(4) a checkout matching its CACHED origin/main reads clean with the fetch off and blocks with it on -- the comparison is against the remote, not against a ref of unknown age"
elif [ "$w_no" != "-" ]; then
    no "(4) the no-fetch arm blocked as well, so this pair proves nothing about fetching" "no-fetch: ${w_no}"
else
    no "(4) fetching did not change the verdict: the stale cached ref was accepted" "with fetch: ${w_yes}"
fi

# ---------------------------------------------------------------------------
# 5. REGRESSION on the half that was already fixed: CM044 must still be
#    guarded, and now through the same library.
# ---------------------------------------------------------------------------
rc="$(CM044_DIR_T="$TMP/stale" guard "$TMP/a5" OSTLER_ASSISTANT_DIR="$TMP/atmain")"
w="$(blockof "$TMP/a5" "wiki image CONTENT")"
[ "$w" != "-" ] && [ -n "$w" ] \
    && ok "(5) a stale CM044_DIR still blocks the wiki content gate" \
    || no "(5) the CM044 guard stopped firing" "$(cat "$TMP/a5")"

# ---------------------------------------------------------------------------
# 6. HR015_ROOT is read by the pair registry too, so it is guarded as well.
# ---------------------------------------------------------------------------
rc="$(guard "$TMP/a6" OSTLER_ASSISTANT_DIR="$TMP/atmain" HR015_ROOT="$TMP/stale")"
w="$(blockof "$TMP/a6" "vendor pair drift")"
case "$w" in
    *HR015_ROOT*) ok "(6) a stale HR015_ROOT blocks the gate that reads it, named" ;;
    *)            no "(6) HR015_ROOT is read by the pair registry and is not guarded" "$(cat "$TMP/a6")" ;;
esac

# ---------------------------------------------------------------------------
# 7. AN ABSENT CHECKOUT IS NOT THIS GUARD'S REFUSAL TO MAKE. The gates already
#    refuse by name ("OSTLER_ASSISTANT_DIR is not set", quoted approvingly in
#    #1550 as the behaviour to copy). Blocking here would replace a precise
#    message with a vaguer one.
# ---------------------------------------------------------------------------
rc="$(guard "$TMP/a7")"
s="$(stateof "$TMP/a7" OSTLER_ASSISTANT_DIR)"
w="$(blockof "$TMP/a7" "vendor pair drift")"
if [ "$w" = "-" ] && [ "$s" = "not-set" ]; then
    ok "(7) an unset checkout is recorded as not-set and left to the gate's own refusal, not overwritten by this guard"
else
    no "(7) an unset checkout was reported as '${s}' and blocked with '${w}'" "$(cat "$TMP/a7")"
fi

# ===========================================================================
echo
echo "  -- part B: the gates consume it --"
# ===========================================================================
# A right verdict wired to nothing is #1550 again. The three gates that read a
# guarded checkout must be invoked through gate_or_unavailable; a gate that
# reads none of them must not be, which is the negative control that keeps this
# predicate from matching everything.
# ===========================================================================
guarded_labels() {   # $1 = runner path
    /usr/bin/grep -A2 'gate_or_unavailable "\$_vendor_block"' "$1" \
        | /usr/bin/grep -oE '"(cut provenance|content provenance|vendor pair drift|cut freshness)"' \
        | tr -d '"' | sort -u
}

G="$(guarded_labels "$RUNNER")"
n_g="$(printf '%s\n' "$G" | grep -c . || true)"
if [ "${n_g:-0}" -eq 0 ]; then
    no "(B0) CONTROL FAILED: the predicate found no guarded gate at all, so every verdict below would be a broken pattern rather than a finding" "$(printf '%s' "$G")"
else
    ok "(B0) CONTROL: the predicate finds ${n_g} guarded gate invocation(s), so a miss below is a real one"
fi

for g in "cut provenance" "content provenance" "vendor pair drift"; do
    printf '%s\n' "$G" | grep -qxF "$g" \
        && ok "(B) '${g}' reads a guarded checkout and is invoked through the guard" \
        || no "(B) '${g}' reads OSTLER_ASSISTANT_DIR and is invoked BARE -- the #1550 shape" "$(printf '%s' "$G")"
done

# NEGATIVE CONTROL. cut freshness reads no guarded checkout. If it appeared in
# the set above, the predicate would be matching invocations indiscriminately
# and the three passes would mean nothing.
printf '%s\n' "$G" | grep -qxF "cut freshness" \
    && no "(B-control) the predicate also matched 'cut freshness', which reads no guarded checkout -- it is matching everything" "$(printf '%s' "$G")" \
    || ok "(B-control) NEGATIVE CONTROL: 'cut freshness' reads no guarded checkout and is correctly not in the guarded set"

# ===========================================================================
echo
echo "  -- mutation --"
# ===========================================================================

_mutate() {   # _mutate <out> <python-body-file-marker>  -- returns builder rc
    python3 - "$RUNNER" "$LIB" "$1" "$2"
}

# M1: BLIND THE COMPARISON. _checkout_tip_state always reports ok. Assertions
# 2, 3, 4, 5 and 6 must all go red.
python3 - "$LIB" "$TMP/lib-ok.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
needle = '_checkout_tip_state() {\n    local d="$1"'
if needle not in src:
    sys.stderr.write("M1 DID NOT APPLY: _checkout_tip_state is not where this test expects it\n")
    raise SystemExit(3)
open(sys.argv[2], "w").write(src.replace(needle, '_checkout_tip_state() {\n    printf \'ok\\n\'; return 0\n    local d="$1"', 1))
PY
m1=$?

# M2: THE OTHER DIRECTION. Always report off-tip. Assertion 1, the positive
# control, must go red -- a guard that refuses everything blocks every cut and
# gets commented out, which is the same outcome as having no guard.
python3 - "$LIB" "$TMP/lib-offtip.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
needle = '_checkout_tip_state() {\n    local d="$1"'
if needle not in src:
    sys.stderr.write("M2 DID NOT APPLY\n")
    raise SystemExit(3)
open(sys.argv[2], "w").write(src.replace(needle, '_checkout_tip_state() {\n    printf \'off-tip|main|x|1|1\\n\'; return 0\n    local d="$1"', 1))
PY
m2=$?

# 🔴 A MUTANT THAT DID NOT APPLY LOOKS EXACTLY LIKE ONE THAT WAS NOT CAUGHT.
# Both builders exit 3 rather than writing an unchanged copy, and that is
# checked before any verdict is read.
run_with_lib() {   # run_with_lib <lib> <outfile> <env...>
    local lib="$1" out="$2"; shift 2
    local mutant="$TMP/runner.$$.sh"
    sed "s#^\. \"\$HERE/scripts/lib/checkout_guard.sh\"#. \"${lib}\"#" "$RUNNER" > "$mutant"
    if ! /usr/bin/grep -qF "$lib" "$mutant"; then
        echo "MUTANT-NOT-APPLIED" > "$out"
        return 3
    fi
    env CM044_DIR="$TMP/stale" "$@" /bin/bash "$mutant" --print-checkout-guard > "$out" 2>"${out}.err"
}

if [ "$m1" != 0 ]; then
    no "(M1) the blinded-library mutant could not be built, so nothing was mutation-tested" "re-point this test at _checkout_tip_state"
elif ! run_with_lib "$TMP/lib-ok.sh" "$TMP/m1" OSTLER_ASSISTANT_DIR="$TMP/stale"; then
    no "(M1) the mutant runner did not run" "$(cat "$TMP/m1" "$TMP/m1.err" 2>/dev/null)"
else
    a="$(blockof "$TMP/m1" "vendor pair drift")"
    b="$(blockof "$TMP/m1" "wiki image CONTENT")"
    if [ "$a" = "-" ] && [ "$b" = "-" ]; then
        ok "(M1) RED ON THE DEFECT: a guard that always says ok lets a stale ostler-assistant AND a stale CM044 through -- assertions (2), (5) and (6) are load-bearing"
    else
        no "(M1) MUTANT SURVIVED: blinding _checkout_tip_state still blocked, so the assertions above are not testing the guard" "$(cat "$TMP/m1")"
    fi
fi

if [ "$m2" != 0 ]; then
    no "(M2) the always-refuse mutant could not be built, so the over-refusal direction was not tested" "re-point this test at _checkout_tip_state"
elif ! run_with_lib "$TMP/lib-offtip.sh" "$TMP/m2" OSTLER_ASSISTANT_DIR="$TMP/atmain"; then
    no "(M2) the mutant runner did not run" "$(cat "$TMP/m2" "$TMP/m2.err" 2>/dev/null)"
else
    a="$(blockof "$TMP/m2" "vendor pair drift")"
    [ "$a" != "-" ] && [ -n "$a" ] \
        && ok "(M2) REFUSES WHEN BLINDED: a guard that reports every checkout off-tip blocks a healthy one, and assertion (1) catches it" \
        || no "(M2) MUTANT SURVIVED: an always-off-tip guard did not block a healthy checkout, so assertion (1) proves nothing" "$(cat "$TMP/m2")"
fi

# M3: UNWIRE ONE GATE. Part B must notice that a gate reading a guarded
# checkout was invoked bare -- the exact state main was in before this PR.
python3 - "$RUNNER" "$TMP/runner-bare.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
needle = 'gate_or_unavailable "$_vendor_block" \\\n    "vendor pair drift"'
if needle not in src:
    sys.stderr.write("M3 DID NOT APPLY: the vendor pair drift invocation is not where this test expects it\n")
    raise SystemExit(3)
open(sys.argv[2], "w").write(src.replace(needle, 'run \\\n    "vendor pair drift"', 1))
PY
m3=$?

if [ "$m3" != 0 ]; then
    no "(M3) the unwired mutant could not be built, so part B was not mutation-tested" "re-point this test at the gate invocations"
else
    GM="$(guarded_labels "$TMP/runner-bare.sh")"
    printf '%s\n' "$GM" | grep -qxF "vendor pair drift" \
        && no "(M3) MUTANT SURVIVED: the gate was invoked bare and part B still reported it guarded" "$(printf '%s' "$GM")" \
        || ok "(M3) RED ON THE UNWIRING: invoking 'vendor pair drift' bare drops it out of the guarded set, so part B is load-bearing"
fi

echo
echo "EXAMINED: 3 checkouts, 4 gate labels, 4 repository states (at-tip, behind on a feature branch, ahead, cached-stale), 3 mutants."
echo "=== ${PASS} passed / ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
