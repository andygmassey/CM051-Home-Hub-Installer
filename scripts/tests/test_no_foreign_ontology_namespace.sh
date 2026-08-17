#!/usr/bin/env bash
#
# test_no_foreign_ontology_namespace.sh -- prove the ratchet fires in BOTH
# directions against a REAL git tree, not a hand-authored reading.
#
# The gate is ADVISORY while the declared count is above zero and HARD at zero,
# so the controls have to prove BOTH states or the advisory one could be
# permanent and nobody would know:
#   2   an INCREASE warns, exits 0, and SAYS it is not a pass
#   2b  THE PROMOTION: the same shape at declared 0 exits 1
#   3   a DECREASE that did not lower the declaration also warns. A floor
#       nobody lowers after a migration silently stops being evidence.
#
# 2b is the one that matters most. Without it this could warn forever.
#
# Fixtures are real repositories built in a temp dir, because the gate reads
# `git grep` and a predicate driven by fake input would be testing the harness.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/../verify_no_foreign_ontology_namespace.sh"
[ -r "$GATE" ] || { echo "FAIL: no gate at $GATE"; exit 99; }

PASS=0; FAIL=0
TMP="$(mktemp -d -t nsratchet_XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
ok() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
no() { printf '  FAIL  %s\n' "$1"; printf '%s\n' "${2:-}" | sed 's/^/        | /'; FAIL=$((FAIL+1)); }

# mkrepo <dir> <occurrences> <declared>
mkrepo() {
    local d="$1" n="$2" decl="$3" i
    rm -rf "$d"; mkdir -p "$d/scripts"
    git -C "$d" init -q 2>/dev/null
    : > "$d/data.ttl"
    i=0; while [ "$i" -lt "$n" ]; do printf '@prefix pwg: <https://pwg.dev/ontology#> .\n' >> "$d/data.ttl"; i=$((i+1)); done
    printf '# declared\n%s\n' "$decl" > "$d/scripts/.foreign-ontology-namespace-count"
    git -C "$d" add -A 2>/dev/null; git -C "$d" -c user.email=t@t -c user.name=t commit -qm x 2>/dev/null
}

run() { bash "$GATE" "$1" >"$TMP/out" 2>&1; echo $?; }

echo "test_no_foreign_ontology_namespace"
echo

# 1. At the declared count -> GREEN.
mkrepo "$TMP/at" 5 5
rc="$(run "$TMP/at")"
[ "$rc" = 0 ] && ok "5 occurrences, declared 5 -> GREEN" || no "at-count was not green (rc=$rc)" "$(cat "$TMP/out")"

# ---------------------------------------------------------------------------
# 2. LOAD-BEARING: an INCREASE must WARN. This is the whole point.
# ---------------------------------------------------------------------------
mkrepo "$TMP/up" 6 5
rc="$(run "$TMP/up")"
if [ "$(grep -c 'went UP' "$TMP/out")" -lt 1 ]; then no "an INCREASE 5 -> 6 produced no WARN -- the ratchet is decoration" "$(cat "$TMP/out")"
elif [ "$rc" != 0 ]; then no "advisory mode should not fail a PR (rc=$rc)" "$(cat "$TMP/out")"
elif [ "$(grep -c 'NOT a pass' "$TMP/out")" -lt 1 ]; then no "warned, but did not say it is NOT a pass -- a warn read as green" "$(cat "$TMP/out")"
else ok "INCREASE while declared>0 -> WARN, rc=0, and says NOT a pass (ADVISORY)"; fi

# 2b. THE PROMOTION. The same shape at declared ZERO must be HARD. Without this
#     the gate could be advisory forever and nobody would notice.
mkrepo "$TMP/upzero" 1 0
rc="$(run "$TMP/upzero")"
if [ "$rc" != 1 ]; then no "an occurrence against declared 0 was NOT hard (rc=$rc) -- the gate never promotes" "$(cat "$TMP/out")"
else ok "1 occurrence against declared 0 -> rc=1 (SELF-PROMOTED TO HARD)"; fi

# ---------------------------------------------------------------------------
# 3. LOAD-BEARING: a DECREASE that did not lower the declaration ALSO warns.
# ---------------------------------------------------------------------------
mkrepo "$TMP/down" 3 5
rc="$(run "$TMP/down")"
if [ "$(grep -c 'went DOWN' "$TMP/out")" -lt 1 ]; then no "a DECREASE with a stale declaration produced no WARN -- the floor rots silently" "$(cat "$TMP/out")"
elif [ "$rc" != 0 ]; then no "advisory mode should not fail a PR (rc=$rc)" "$(cat "$TMP/out")"
else ok "3 against declared 5 -> WARN (a floor nobody lowers is not evidence)"; fi

# 4. Zero is green and says so distinctly, because that is the goal state.
mkrepo "$TMP/zero" 0 0
rc="$(run "$TMP/zero")"
if [ "$rc" != 0 ]; then no "a fully migrated tree was not green (rc=$rc)" "$(cat "$TMP/out")"
elif [ "$(grep -c 'fully migrated' "$TMP/out")" -lt 1 ]; then no "green but does not announce the goal state" "$(cat "$TMP/out")"
else ok "0 occurrences, declared 0 -> GREEN and named as fully migrated"; fi

# 5. A missing declaration is CANNOT-RUN, never a pass. Deleting the file must
#    not be a way to make the gate agreeable.
mkrepo "$TMP/nodecl" 5 5
rm -f "$TMP/nodecl/scripts/.foreign-ontology-namespace-count"
rc="$(run "$TMP/nodecl")"
[ "$rc" = 2 ] && ok "absent declaration -> CANNOT-RUN (rc=2), not a pass" \
              || no "deleting the declaration gave rc=$rc" "$(cat "$TMP/out")"

# 6. Not a git repo -> CANNOT-RUN.
mkdir -p "$TMP/plain"
rc="$(run "$TMP/plain")"
[ "$rc" = 2 ] && ok "non-repo -> CANNOT-RUN (rc=2)" || no "non-repo gave rc=$rc" "$(cat "$TMP/out")"

# ---------------------------------------------------------------------------
# 7. THE REAL TREE. The shipped declaration must equal what is actually there,
#    or this gate is guarding a number nobody checked.
# ---------------------------------------------------------------------------
REAL="$(cd "$HERE/../.." && pwd)"
rc="$(run "$REAL")"
if [ "$rc" = 0 ]; then ok "the REAL repository is at its declared count"
else no "the real repository does not match its declaration (rc=$rc)" "$(cat "$TMP/out")"; fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
echo "ALL NAMESPACE RATCHET CONTROLS PASSED"
