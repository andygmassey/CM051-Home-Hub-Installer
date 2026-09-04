#!/usr/bin/env bash
# A promote that runs BEFORE the decline arms must be gated on SKIP_PHASE2.
#
# WHY THIS EXISTS. CM051 #1437 made the decline arms safe with an explicit
# guard (_OSTLER_FINAL_PREEXISTED) and proved it BY EXECUTION in
# tests/test_decline_does_not_wipe_an_existing_install.sh. That test is the
# primary defence and this one does not duplicate it.
#
# What #1437 could not test, and said so in its own source comment, is the
# SECOND reason the arms are survivable:
#
#     "the binding is an emergent property of two other decisions that a
#      later change could quietly reverse"
#
# The two decisions are:
#
#   1. _ostler_promote_prelaunch_tree is what rebinds OSTLER_DIR from the
#      prelaunch staging tree onto ~/.ostler.
#   2. The only call site that precedes the decline arms is gated on
#      SKIP_PHASE2 == "true", and the decline arms are only reachable when
#      SKIP_PHASE2 is false.
#
# Opposite values, so at decline time OSTLER_DIR names staging residue and
# not the customer's install. Nothing states that anywhere. Add a sixth
# promote call above the decline arms without a gate and the property is
# gone, silently, with every existing test still green.
#
# THIS IS DEFENCE IN DEPTH, NOT THE DEFENCE. If this test goes red the
# customer is probably still safe, because #1437's guard is independent. Read
# it as "the second lock just came off", not as "data loss has shipped".
#
# SCOPE, MEASURED ON origin/main 8074f26b, NOT ASSUMED: 5 promote call sites
# exist; exactly 1 precedes the first decline arm. Sites AFTER the arms are
# out of scope and this test says nothing about them.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

[ -f "$SUBJECT" ] || cant "no install.sh at ${SUBJECT}"
WORK="$(mktemp -d)" || cant "no working directory"
trap 'rm -rf "$WORK"' EXIT

# ── locators ─────────────────────────────────────────────────────────────
# A call site is the bare function name on its own line. This deliberately
# does NOT match the definition (`name() {`) or a commented-out line.
_promote_sites() {
    grep -nE '^[[:space:]]*_ostler_promote_prelaunch_tree[[:space:]]*$' "$1" | cut -d: -f1
}
# The decline arms are identified by the #1437 guard, which is the only place
# _OSTLER_FINAL_PREEXISTED is read.
_decline_lines() {
    grep -nE '^[[:space:]]*if \[\[ "\$_OSTLER_FINAL_PREEXISTED" != true' "$1" | cut -d: -f1
}

# Walk backwards from a promote call for its enclosing SKIP_PHASE2 gate.
# A `fi` encountered first means the promote sits AFTER a closed block and is
# therefore not gated by it.
_gate_state() {
    local file="$1" L="$2" i n code
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        n=$((L - i)); [ "$n" -lt 1 ] && break
        code="$(sed -n "${n}p" "$file" | sed 's/^[[:space:]]*//')"
        case "$code" in
            ''|'#'*)                      continue ;;
            fi|'fi '*|'fi;'*)             printf 'unfenced'; return ;;
            *SKIP_PHASE2*'=='*true*)      printf 'gated';    return ;;
        esac
    done
    printf 'ungated'
}

# Returns the ungated promote lines that precede the first decline arm.
_audit() {
    local file="$1" first_decline="$2" L out=''
    for L in $(_promote_sites "$file"); do
        [ "$L" -lt "$first_decline" ] || continue
        [ "$(_gate_state "$file" "$L")" = gated ] || out="${out} ${L}"
    done
    printf '%s' "${out# }"
}

echo "── subject: this tree ──"

DECLINE="$(_decline_lines "$SUBJECT")"
N_DECLINE="$(printf '%s\n' "$DECLINE" | grep -c '[0-9]' || true)"
[ "${N_DECLINE:-0}" -ge 1 ] || cant "no decline arm found: the #1437 guard \
_OSTLER_FINAL_PREEXISTED is absent from install.sh, so this test cannot locate its subject"
FIRST_DECLINE="$(printf '%s\n' "$DECLINE" | head -1)"

SITES="$(_promote_sites "$SUBJECT")"
N_SITES="$(printf '%s\n' "$SITES" | grep -c '[0-9]' || true)"
[ "${N_SITES:-0}" -ge 1 ] || cant "no _ostler_promote_prelaunch_tree call site found -- \
the locator is broken or the function was renamed"

N_BEFORE=0
for _l in $SITES; do [ "$_l" -lt "$FIRST_DECLINE" ] && N_BEFORE=$((N_BEFORE+1)); done
echo "  ${N_SITES} promote call site(s); ${N_DECLINE} decline arm(s), first at line ${FIRST_DECLINE}; ${N_BEFORE} promote(s) precede it"

# ── arm 1: the property ──────────────────────────────────────────────────
UNGATED="$(_audit "$SUBJECT" "$FIRST_DECLINE")"
if [ -z "$UNGATED" ]; then
    ok "arm 1: every promote before the decline arms (${N_BEFORE} of ${N_SITES}) is gated on SKIP_PHASE2"
else
    bad "arm 1: promote call(s) at line(s)${UNGATED} run BEFORE the decline arm at ${FIRST_DECLINE} \
without a SKIP_PHASE2 gate. That rebinds OSTLER_DIR onto ~/.ostler while the arm is reachable. \
#1437's _OSTLER_FINAL_PREEXISTED guard is the remaining defence -- check it is still intact."
fi

# ── arm 2: MUTATION. The property must be falsifiable. ───────────────────
MUT="${WORK}/mutant.sh"
/usr/bin/awk -v ins="$FIRST_DECLINE" \
    'NR==ins { print "    _ostler_promote_prelaunch_tree" } { print }' \
    "$SUBJECT" > "$MUT"
MUT_DECLINE="$(_decline_lines "$MUT" | head -1)"
if [ "$(_promote_sites "$MUT" | grep -c '[0-9]')" -le "$N_SITES" ]; then
    bad "arm 2: the mutation did not add a call site, so it tests nothing"
elif [ -n "$(_audit "$MUT" "$MUT_DECLINE")" ]; then
    ok "arm 2: an ungated promote inserted above the decline arm IS caught"
else
    bad "arm 2: an ungated promote inserted directly above the decline arm was NOT caught. \
Arm 1 cannot fail and its pass means nothing."
fi

# ── arm 3: MUST-MISS. A commented-out call is not a call site. ───────────
MISS="${WORK}/commented.sh"
/usr/bin/awk -v ins="$FIRST_DECLINE" \
    'NR==ins { print "    # _ostler_promote_prelaunch_tree" } { print }' \
    "$SUBJECT" > "$MISS"
if [ "$(_promote_sites "$MISS" | grep -c '[0-9]')" -eq "$N_SITES" ]; then
    ok "arm 3: a commented-out promote is not counted as a call site"
else
    bad "arm 3: a commented-out promote was counted. The locator scores comments and \
arm 1 would fail on a source comment."
fi

# ── arm 4: MUST-MISS on the gate walker. A closed block does not gate. ───
FENCE="${WORK}/fenced.sh"
/usr/bin/awk -v ins="$FIRST_DECLINE" '
    NR==ins {
        print "if [[ \"$SKIP_PHASE2\" == \"true\" ]]; then"
        print "    :"
        print "fi"
        print "    _ostler_promote_prelaunch_tree"
    } { print }' "$SUBJECT" > "$FENCE"
if [ -n "$(_audit "$FENCE" "$(_decline_lines "$FENCE" | head -1)")" ]; then
    ok "arm 4: a promote AFTER a closed SKIP_PHASE2 block is not treated as gated"
else
    bad "arm 4: a promote sitting after a closed 'fi' was read as gated. The walker \
matches any nearby gate regardless of scope, so arm 1 can be satisfied by an unrelated block."
fi

# ── arm 5: the call sites are real code, not heredoc payload ─────────────
# Without the non-zero control below this arm would pass on a broken detector.
HD_TOTAL="$(/usr/bin/awk '
    /<<-?"?'"'"'?[A-Z_]+"?'"'"'?$/ && !/<<[[:space:]]*\$/ {
        if (!inhd) { inhd=1; sub(/.*<<-?["'"'"']?/,""); sub(/["'"'"'].*/,""); d=$0; next } }
    inhd && $0 ~ ("^[[:space:]]*" d "[[:space:]]*$") { inhd=0; next }
    { if (inhd) c++ }
    END { print c+0 }' "$SUBJECT")"
HD_HITS="$(/usr/bin/awk '
    /<<-?"?'"'"'?[A-Z_]+"?'"'"'?$/ && !/<<[[:space:]]*\$/ {
        if (!inhd) { inhd=1; sub(/.*<<-?["'"'"']?/,""); sub(/["'"'"'].*/,""); d=$0; next } }
    inhd && $0 ~ ("^[[:space:]]*" d "[[:space:]]*$") { inhd=0; next }
    inhd && /^[[:space:]]*_ostler_promote_prelaunch_tree[[:space:]]*$/ { c++ }
    END { print c+0 }' "$SUBJECT")"
if [ "$HD_TOTAL" -eq 0 ]; then
    bad "arm 5: the heredoc detector found 0 heredoc lines in a file that has many. \
It is broken, so 'no promote is inside a heredoc' is an empty claim."
elif [ "$HD_HITS" -eq 0 ]; then
    ok "arm 5: no promote call site is heredoc payload (detector saw ${HD_TOTAL} heredoc lines, so it works)"
else
    bad "arm 5: ${HD_HITS} promote 'call site(s)' are inside a heredoc and are not code. \
The line numbers arm 1 reasons about are wrong."
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
