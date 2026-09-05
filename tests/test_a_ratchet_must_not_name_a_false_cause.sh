#!/usr/bin/env bash
# CM051 #1614 -- a ratchet's failure message must name the cause it measured.
#
# THE DEFECT THIS GUARDS. test_pipefail_shortcircuit_inversion.sh classifies
# each baselined row the scan no longer finds into two buckets with two
# different remedies:
#
#   CONSTRUCT FIXED (or now excluded), file still present
#   FILE NO LONGER EXISTS
#
# It chose between them with `[ -e "$row" ]`. A baseline row is
# `path<TAB>count`, so that asks whether a file named "tests/foo.sh<TAB>2"
# exists. It never does. EVERY removed row was therefore reported as
# FILE NO LONGER EXISTS, and the CONSTRUCT FIXED branch was DEAD CODE.
#
# MEASURED on #1609: the gate printed
#   FILE NO LONGER EXISTS: tests/test_wiki_tailnet_gate.sh  2
# about a file present on the branch, on main, and in the merge result. The
# real cause was a count regression. The reviewer had to discard the stated
# cause before finding the actual one.
#
# A gate whose red carries no information gets routed around. A gate whose red
# carries WRONG information is worse: it sends the reader to look for a deleted
# file, and the reader who finds the file present concludes the gate is broken
# and starts looking for a way past it.
#
# THE CLASSIFIER IS LIFTED FROM THE SHIPPED SOURCE rather than restated here,
# so this test cannot pass against a copy while the real one rots.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
SUBJECT="${REPO}/tests/test_pipefail_shortcircuit_inversion.sh"

PASS=0; FAIL=0; CANT=0
ok()   { printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
cant() { printf '  [CANNOT-RUN] %s\n' "$*"; CANT=$((CANT+1)); }

[ -r "$SUBJECT" ] || { cant "subject unreadable: $SUBJECT"; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }

WORK="$(mktemp -d -t ratchetcause.XXXXXX)" || { cant "mktemp failed"; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }
trap 'rm -rf -- "$WORK"' EXIT

# ── Lift the classifier out of the shipped file ───────────────────────────
LIFT="$WORK/classifier.sh"
sed -n '/^        fixed=""; gone=""$/,/^        done <<< "\$REMOVED"$/p' "$SUBJECT" > "$LIFT"
_lifted_lines="$(wc -l < "$LIFT" | tr -d ' ')"
if [ "${_lifted_lines}" -lt 4 ]; then
    # A validator passes on an empty subject. An extraction that captured
    # nothing would make every arm below vacuously green.
    cant "extracted only ${_lifted_lines} line(s) of classifier; the markers have moved and this test is measuring nothing"
    echo "== 0 pass / 0 fail / 1 cannot-run =="
    exit 2
fi
ok "lifted the classifier from the shipped file (${_lifted_lines} lines)"

# ── Fixture: one row whose file EXISTS, one whose file does NOT ───────────
cd "$WORK" || { cant "cannot enter workdir"; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }
mkdir -p tests
printf '# present\n' > tests/present_file.sh
PRESENT_ROW="$(printf 'tests/present_file.sh\t2')"
ABSENT_ROW="$(printf 'tests/deleted_file.sh\t1')"

# CONTROL: the fixture must be what it claims -- one path present, one absent.
if [ -e tests/present_file.sh ] && [ ! -e tests/deleted_file.sh ]; then
    ok "control: the fixture really does hold one present and one absent path"
else
    bad "control: the fixture is not what the arms below assume"
fi

classify() {
    REMOVED="$1"
    fixed=""; gone=""
    # shellcheck source=/dev/null
    . "$LIFT"
    printf 'FIXED:%s\nGONE:%s\n' "${fixed//$'\n'/,}" "${gone//$'\n'/,}"
}

# ── ARM 1: a row whose file is present must be CONSTRUCT FIXED ───────────
OUT="$(classify "$PRESENT_ROW")"
if grep -q '^FIXED:tests/present_file.sh' <<< "$OUT"; then
    ok "a removed row whose file is present is reported as CONSTRUCT FIXED"
else
    bad "a present file was NOT classified as fixed: $OUT"
fi

# ── ARM 2 (MUST-MISS): it must NOT also land in the gone bucket ──────────
if grep -q '^GONE:tests/present_file.sh' <<< "$OUT"; then
    bad "a present file was ALSO reported as FILE NO LONGER EXISTS -- the two messages are not exclusive"
else
    ok "a present file is not reported as missing"
fi

# ── ARM 3: a row whose file is absent must be FILE NO LONGER EXISTS ──────
OUT2="$(classify "$ABSENT_ROW")"
if grep -q '^GONE:tests/deleted_file.sh' <<< "$OUT2"; then
    ok "a removed row whose file is absent is reported as FILE NO LONGER EXISTS"
else
    bad "an absent file was NOT classified as missing: $OUT2"
fi

# ── ARM 4: neither message can be produced by the other's condition ──────
if grep -q '^FIXED:tests/deleted_file.sh' <<< "$OUT2"; then
    bad "an absent file was reported as CONSTRUCT FIXED -- the classifier is inverted"
else
    ok "an absent file is not reported as fixed"
fi

# ── ARM 5: the OLD predicate is demonstrated RED on the same fixture ─────
# Without this the four arms above could pass against a classifier that never
# had the defect, and this file would be guarding nothing.
if [ -e "$PRESENT_ROW" ]; then
    bad "the old predicate [ -e \$row ] succeeded on a row -- the defect cannot be demonstrated, so these arms prove nothing"
else
    ok "control: the OLD predicate misclassifies the present file (row is not a path), which is the defect"
fi

echo "== ${PASS} pass / ${FAIL} fail / ${CANT} cannot-run =="
[ "${FAIL}" -gt 0 ] && exit 1
[ "${CANT}" -gt 0 ] && exit 2
exit 0
