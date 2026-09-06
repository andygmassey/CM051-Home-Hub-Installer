#!/usr/bin/env bash
# A row gated BLOCKING must actually block a cut (#1673-adjacent, Andy 2026-09-06)
# ============================================================================
# NINE rows carried the word BLOCKING and nothing in the repo read it. This
# drives the gate that now does. A gate that compiles is not a gate that fires.
#
# Every arm STUBS `gh` on PATH so no network and no auth are involved, and so
# the open/closed set is a fixture rather than whatever the repo happens to
# hold today. The subject is driven as a real process and judged on EXIT CODE
# plus the row numbers it names.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$HERE/tests/test_the_cut_checklist_is_complete.py"
PASS=0; FAIL=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*" >&2; FAIL=$((FAIL+1)); }
cant() { echo "  [CANNOT-RUN] $*" >&2; exit 2; }

[[ -f "$SUBJECT" ]] || cant "no subject at ${SUBJECT}"
command -v python3 >/dev/null 2>&1 || cant "python3 unavailable"
python3 -c 'import yaml' 2>/dev/null || cant "PyYAML unavailable; the subject cannot parse a manifest"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ── a fake repo: manifest dir + a gh stub that returns a FIXED open set ──────
# `gh issue list --state open` is the only call the subject makes.
mk_repo() {   # $1 = dir, $2 = manifest yaml body, $3 = space-separated OPEN issue numbers
    local d="$1" body="$2" openlist="$3"
    mkdir -p "$d/cut-manifests" "$d/tests" "$d/bin"
    printf '%s\n' "$body" > "$d/cut-manifests/v9.9.9.yaml"
    cp "$SUBJECT" "$d/tests/"
    {
        echo '#!/usr/bin/env bash'
        echo '# gh stub: only `issue list --state open --json number` is used.'
        echo 'printf "["'
        echo 'first=1'
        for n in $openlist; do
            echo "if [ \$first -eq 1 ]; then first=0; else printf ','; fi; printf '{\"number\":$n}'"
        done
        echo 'printf "]\n"'
    } > "$d/bin/gh"
    chmod +x "$d/bin/gh"
}

run_subject() {   # $1 = repo dir, $2 = cutting (1|0) -> prints output, sets RC
    local d="$1" cutting="$2"
    set +e
    OUT="$(cd "$d" && PATH="$d/bin:$PATH" OSTLER_CUT_IN_PROGRESS="$cutting" \
            python3 tests/test_the_cut_checklist_is_complete.py 2>&1)"
    RC=$?
    set -e
}

MANIFEST_BLOCKING='version: 9.9.9
description: fixture
entries: []
open_issues:
  - issue: 4001
    title: a genuine blocker
    gate: "FIX (BLOCKING): the customer sees the wrong thing"
  - issue: 4002
    title: an ordinary fix
    gate: "FIX: tidy this up"
'

echo "── subject: ${SUBJECT} ──"

# ── arm 1: BLOCKING + open + cutting  => the cut STOPS ───────────────────────
mk_repo "$WORK/a" "$MANIFEST_BLOCKING" "4001 4002"
run_subject "$WORK/a" 1
if [[ $RC -eq 1 ]] && grep -q 'CUT IS BLOCKED' <<< "$OUT" && grep -q '4001' <<< "$OUT"; then
    ok "a BLOCKING row whose issue is OPEN stops a cut, and names the row (rc=$RC)"
else
    bad "expected rc=1 naming #4001; got rc=$RC. Output: $(printf '%s' "$OUT" | tail -6)"
fi

# ── arm 2: same, NOT cutting => advisory, but the row is still NAMED ─────────
run_subject "$WORK/a" 0
if [[ $RC -eq 0 ]] && grep -q '4001' <<< "$OUT"; then
    ok "outside a cut it does not fail, but names the row rather than printing a bare count"
else
    bad "expected rc=0 with #4001 named; got rc=$RC"
fi

# ── arm 3: CONTROL -- the SAME row with its issue CLOSED must NOT block ──────
# Drift, not an outstanding blocker. Without this the gate would fire forever
# on rows whose work is finished, and be switched off.
mk_repo "$WORK/b" "$MANIFEST_BLOCKING" "4002"      # 4001 absent => closed
run_subject "$WORK/b" 1
if [[ $RC -eq 0 ]]; then
    ok "CONTROL: a BLOCKING row naming a CLOSED issue does not block a cut"
else
    bad "a closed BLOCKING row still blocked the cut (rc=$RC). Output: $(printf '%s' "$OUT" | tail -6)"
fi

# ── arm 4: CONTROL -- 'NOT BLOCKING' must not match ──────────────────────────
# This value really exists in the register. A bare substring test inverts it,
# and would fail a cut on a row that explicitly says it is not a blocker.
MANIFEST_NOTBLOCKING='version: 9.9.9
description: fixture
entries: []
open_issues:
  - issue: 4003
    title: explicitly not a blocker
    gate: "NOT BLOCKING (reporting accuracy, not a shipped defect)"
'
mk_repo "$WORK/c" "$MANIFEST_NOTBLOCKING" "4003"
run_subject "$WORK/c" 1
if [[ $RC -eq 0 ]]; then
    ok "CONTROL: 'NOT BLOCKING' does not match, so the gate does not invert its own meaning"
else
    bad "'NOT BLOCKING' was treated as BLOCKING (rc=$RC)"
fi

# ── arm 4b: THE REGRESSION. Prose that MENTIONS blocking must not match. ────
# This gate caught its own tail within the hour of shipping. A DEFER row was
# registered whose REASONING read "NOT gated BLOCKING on purpose, and #1680
# makes that word cost something" -- and the whole-string predicate read that
# explanation as a self-declared blocker. A register CITES its own findings, so
# the word a gate hunts for arrives inside the rows it reads. The disposition
# is the head, before the first colon; the reasoning must never reach it.
MANIFEST_PROSE='version: 9.9.9
description: fixture
entries: []
open_issues:
  - issue: 4004
    title: a deferral whose reasoning discusses blocking
    gate: "DEFER: not gated BLOCKING on purpose -- the capability exists and
      the customer is not stuck, so calling this BLOCKING would stop a cut
      over a convenience."
'
mk_repo "$WORK/e" "$MANIFEST_PROSE" "4004"
run_subject "$WORK/e" 1
if [[ $RC -eq 0 ]]; then
    ok "REGRESSION: a DEFER whose REASONING says BLOCKING does not stop a cut"
else
    bad "prose mentioning BLOCKING was read as a disposition (rc=$RC). The predicate is matching the whole string again."
fi

# ── arm 4c: and the head must still be read when it DOES say it ─────────────
# Without this, arm 4b could be satisfied by a predicate that matches nothing.
MANIFEST_HEAD='version: 9.9.9
description: fixture
entries: []
open_issues:
  - issue: 4005
    title: a real blocker whose reasoning mentions nothing special
    gate: "FIX (BLOCKING apparatus): the customer sees the wrong thing"
'
mk_repo "$WORK/f" "$MANIFEST_HEAD" "4005"
run_subject "$WORK/f" 1
if [[ $RC -eq 1 ]] && grep -q '4005' <<< "$OUT"; then
    ok "CONTROL: BLOCKING in the DISPOSITION head still stops the cut"
else
    bad "a genuine BLOCKING head no longer fires (rc=$RC) -- the fix went too far"
fi

# ── arm 5: CONTROL -- an unreadable open-issue list is CANNOT-RUN, not a pass ─
mk_repo "$WORK/d" "$MANIFEST_BLOCKING" "4001 4002"
printf '#!/usr/bin/env bash\nexit 7\n' > "$WORK/d/bin/gh"; chmod +x "$WORK/d/bin/gh"
run_subject "$WORK/d" 1
if [[ $RC -eq 2 ]] && grep -q 'CANNOT-RUN' <<< "$OUT"; then
    ok "CONTROL: an unreadable open-issue list refuses (rc=2), it does not pass"
else
    bad "expected rc=2 CANNOT-RUN when gh fails; got rc=$RC"
fi

echo
echo "== ${PASS} pass / ${FAIL} fail =="
[[ $FAIL -eq 0 ]]
