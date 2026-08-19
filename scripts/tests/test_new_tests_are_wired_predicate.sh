#!/usr/bin/env bash
# test_new_tests_are_wired_predicate.sh
#
# PROVED-RED-BY: this file, arms 2 and 3.
#
# Controls for verify_new_tests_are_wired.sh. Each arm builds a REAL throwaway
# git repository with a REAL commit, so the gate is exercised through the same
# `git diff --diff-filter=AR ...` path it uses in CI. Nothing here feeds the
# predicate a hand-made list, because a gate that is only ever tested on
# synthetic input has not been tested on the thing it does.
#
# ARM 3 IS THE POINT OF THE WHOLE FILE. The standing wiring gate scores a test
# WIRED when a workflow merely NAMES it, comments included -- its own source
# admits this. If this gate inherited that behaviour it would be decorative. So
# arm 3 plants a test whose ONLY appearance is inside a YAML comment and
# REQUIRES a FAIL. If arm 3 ever passes, the comment-stripping has regressed and
# the gate is worthless.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/../verify_new_tests_are_wired.sh"
[ -r "$GATE" ] || { echo "FAIL: no gate at $GATE"; exit 99; }

PASS=0; FAIL=0
ok() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
no() { printf '  FAIL  %s\n' "$1"; printf '%s\n' "${2:-}" | sed 's/^/        | /'; FAIL=$((FAIL+1)); }

echo "test_new_tests_are_wired_predicate"
echo

# Build a repo with a main commit, then a branch commit that adds $1 (a test
# path) and writes $2 as .github/workflows/ci.yml content. Echoes the repo dir.
mkrepo() {
    local testpath="$1" wf="$2" d
    d="$(mktemp -d -t newtestwire_XXXXXX)"
    (
        cd "$d" || exit 1
        git init -q -b main .
        git config user.email t@example.com; git config user.name t
        mkdir -p .github/workflows tests scripts
        printf 'jobs:\n  a:\n    steps:\n      - run: bash tests/test_existing.sh\n' > .github/workflows/ci.yml
        printf 'echo existing\n' > tests/test_existing.sh
        git add -A; git commit -qm base
        # A real remote-tracking ref for the gate's default base.
        git update-ref refs/remotes/origin/main HEAD
        git checkout -q -b feature
        [ -n "$testpath" ] && { mkdir -p "$(dirname "$testpath")"; printf 'echo new\n' > "$testpath"; }
        [ -n "$wf" ] && printf '%s' "$wf" > .github/workflows/ci.yml
        git add -A; git commit -qm change
    ) >/dev/null 2>&1
    printf '%s' "$d"
}

run_gate() { ( cd "$1" && bash "$GATE" >"$1/out" 2>"$1/err"; echo $? ); }

WIRED_WF='jobs:
  a:
    steps:
      - run: bash tests/test_existing.sh
      - run: bash tests/test_brand_new.sh
'
COMMENT_WF='jobs:
  a:
    steps:
      # TODO: wire tests/test_brand_new.sh once it stabilises
      # see also tests/test_brand_new.sh in the post-mortem
      - run: bash tests/test_existing.sh
'
BARE_WF='jobs:
  a:
    steps:
      - run: bash tests/test_existing.sh
'

# --- 1. GREEN: a new test that IS invoked passes -----------------------------
d="$(mkrepo tests/test_brand_new.sh "$WIRED_WF")"
rc="$(run_gate "$d")"
if [ "$rc" = 0 ] && grep -q "WIRED  tests/test_brand_new.sh" "$d/out"; then
    ok "1 GREEN: a new test invoked by the same change passes (rc=0)"
else
    no "1 expected rc=0 and a WIRED line, got rc=$rc" "$(cat "$d/out" "$d/err" 2>/dev/null)"
fi
rm -rf "$d"

# --- 2. RED: a new test that NOTHING invokes fails ---------------------------
d="$(mkrepo tests/test_brand_new.sh "$BARE_WF")"
rc="$(run_gate "$d")"
if [ "$rc" = 1 ] && grep -q "DARK" "$d/out"; then
    ok "2 RED: a new test nobody invokes FAILS (rc=1) and is named"
else
    no "2 expected rc=1 and a DARK line, got rc=$rc" "$(cat "$d/out" "$d/err" 2>/dev/null)"
fi
rm -rf "$d"

# --- 3. THE ONE THAT MATTERS: a COMMENT mention must NOT count ---------------
d="$(mkrepo tests/test_brand_new.sh "$COMMENT_WF")"
rc="$(run_gate "$d")"
if [ "$rc" = 1 ]; then
    ok "3 RED: a test named ONLY in comments is DARK -- the #688 defect is not inherited"
else
    no "3 A COMMENT MENTION SATISFIED THE GATE (rc=$rc). Comment-stripping has regressed and this gate is decorative." "$(cat "$d/out" "$d/err" 2>/dev/null)"
fi
rm -rf "$d"

# --- 4. A change with no new tests cannot fail -------------------------------
d="$(mkrepo "" "$BARE_WF")"
rc="$(run_gate "$d")"
[ "$rc" = 0 ] && ok "4 GREEN: a change adding no tests passes trivially" \
              || no "4 expected rc=0, got rc=$rc" "$(cat "$d/out" "$d/err" 2>/dev/null)"
rm -rf "$d"

# --- 5. A RENAMED test is treated as new -------------------------------------
# Its old invocation, if any, now points at a path that no longer exists.
d="$(mktemp -d -t newtestwire_XXXXXX)"
(
  cd "$d" || exit 1
  git init -q -b main .; git config user.email t@example.com; git config user.name t
  mkdir -p .github/workflows tests
  printf 'jobs:\n  a:\n    steps:\n      - run: bash tests/test_old_name.sh\n' > .github/workflows/ci.yml
  printf 'echo x\n' > tests/test_old_name.sh
  git add -A; git commit -qm base; git update-ref refs/remotes/origin/main HEAD
  git checkout -q -b feature
  git mv tests/test_old_name.sh tests/test_new_name.sh
  git add -A; git commit -qm rename
) >/dev/null 2>&1
rc="$(run_gate "$d")"
[ "$rc" = 1 ] && ok "5 RED: a RENAMED test is treated as new; the old invocation no longer reaches it" \
              || no "5 expected rc=1 for a rename, got rc=$rc" "$(cat "$d/out" "$d/err" 2>/dev/null)"
rm -rf "$d"

# --- 6. CANNOT-RUN is distinct from both pass and fail -----------------------
d="$(mkrepo tests/test_brand_new.sh "$BARE_WF")"
rc="$( cd "$d" && OSTLER_WIRING_BASE=refs/heads/does-not-exist bash "$GATE" >/dev/null 2>&1; echo $? )"
[ "$rc" = 3 ] && ok "6 CANNOT-RUN: no merge-base returns rc=3, not 0 and not 1" \
              || no "6 expected rc=3 for an absent base, got rc=$rc"
rm -rf "$d"

# --- 7. The gate states its denominator --------------------------------------
d="$(mkrepo tests/test_brand_new.sh "$WIRED_WF")"
run_gate "$d" >/dev/null
if grep -q "runner files searched" "$d/out"; then
    ok "7 DENOMINATOR: the gate prints how many runner files it searched"
else
    no "7 no denominator printed -- 'nothing found' and 'nothing searched' would read alike" "$(cat "$d/out")"
fi
rm -rf "$d"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
[ "$PASS" -ge 7 ] || { echo "FLOOR: expected at least 7 arms, ran $PASS"; exit 1; }
echo "ALL NEW-TEST-WIRING CONTROLS PASSED"
