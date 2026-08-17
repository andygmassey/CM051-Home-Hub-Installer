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

# mkrepo <dir> <occurrences> <declared> [host]
# `host` defaults to the unregistered domain. Pass the mDNS one to build a
# tree the ORIGINAL pwg.dev-only regex was structurally unable to see.
mkrepo() {
    local d="$1" n="$2" decl="$3" host="${4:-pwg.dev}" i
    rm -rf "$d"; mkdir -p "$d/scripts"
    git -C "$d" init -q 2>/dev/null
    : > "$d/data.ttl"
    i=0; while [ "$i" -lt "$n" ]; do printf '@prefix pwg: <https://%s/ontology#> .\n' "$host" >> "$d/data.ttl"; i=$((i+1)); done
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
#
#    THIS CONTROL USED TO ASSERT rc=0 AND NOTHING ELSE, AND THAT WAS A FALSE
#    GREEN. The gate exits 0 in TWO different states: at the declared count,
#    and out of step while the declaration is still above zero (advisory).
#    Setting the real declaration to 244 against an actual 294 -- fifty out --
#    still printed "PASS the REAL repository is at its declared count".
#    A predicate that cannot distinguish the pass state from the failure state
#    is not measuring the thing its own sentence names.
#
#    So it asserts the GREEN LINE, which only the at-count branch prints.
# ---------------------------------------------------------------------------
REAL="$(cd "$HERE/../.." && pwd)"
rc="$(run "$REAL")"
if [ "$rc" != 0 ]; then
    no "the real repository does not match its declaration (rc=$rc)" "$(cat "$TMP/out")"
elif [ "$(grep -c 'GATE: GREEN' "$TMP/out")" -lt 1 ]; then
    no "rc=0 but the gate did not print GREEN -- it is ADVISORY, which is NOT a pass" "$(cat "$TMP/out")"
else
    ok "the REAL repository is at its declared count (GREEN, not merely rc=0)"
fi

# 7b. PROVE THE CONTROL ABOVE CAN FAIL. An assertion about the real tree that
#     has never been shown to go red is indistinguishable from one that always
#     passes, which is exactly the defect 7 just had. Copy the real tree's
#     declaration out of step and require a red.
REALDECL="$REAL/scripts/.foreign-ontology-namespace-count"
if [ -r "$REALDECL" ]; then
    n_real="$(grep -vE '^[[:space:]]*#' "$REALDECL" | tr -dc '0-9')"
    cp "$REALDECL" "$TMP/decl.bak"
    printf '# temporary, control 7b\n%s\n' "$(( n_real - 50 ))" > "$TMP/decl.skewed"
    rc="$(OSTLER_NS_COUNT_FILE="$TMP/decl.skewed" bash "$GATE" "$REAL" >"$TMP/out" 2>&1; echo $?)"
    if [ "$(grep -c 'GATE: GREEN' "$TMP/out")" -ge 1 ]; then
        no "PROVE RED FAILED: a declaration 50 out still printed GREEN" "$(cat "$TMP/out")"
    elif [ "$(grep -c 'went UP' "$TMP/out")" -lt 1 ]; then
        no "PROVE RED FAILED: a declaration 50 out produced no WARN" "$(cat "$TMP/out")"
    else
        ok "PROVED RED: the real-tree control goes red when the declaration is 50 out"
    fi
else
    no "cannot read the real declaration at $REALDECL" ""
fi

# ---------------------------------------------------------------------------
# 8. THE AXIS THIS CHANGE ADDED. The regex was `pwg\.dev` alone and the tree
#    also carries `pwg.local`, which the CM019 enrichment service writes into
#    every enriched preference. A tree containing ONLY the mDNS domain was
#    invisible to the old regex, so retiring pwg.dev would have read as a
#    completed migration with "pwg" still stamped into the customer's graph.
#
#    Proved on its OWN axis: a fixture with no pwg.dev in it at all. If the
#    widening were reverted this control goes red by itself, which is the
#    property a fixture that trips several checks at once cannot give you.
# ---------------------------------------------------------------------------
mkrepo "$TMP/mdns" 4 0 "pwg.local"
[ "$(grep -c 'pwg\.dev' "$TMP/mdns/data.ttl")" -eq 0 ] \
    || no "fixture is not single-axis: it contains pwg.dev" ""
rc="$(run "$TMP/mdns")"
if [ "$rc" != 1 ]; then
    no "a pwg.local-only tree against declared 0 was NOT caught (rc=$rc) -- the regex is still dev-only" "$(cat "$TMP/out")"
else
    ok "PROVED RED on its own axis: pwg.local alone, no pwg.dev present, is caught"
fi

# 8b. and the same fixture is genuinely invisible to the ORIGINAL regex, so
#     control 8 is measuring the widening rather than restating it.
n_old="$(grep -cE 'pwg\.dev' "$TMP/mdns/data.ttl" || true)"
n_new="$(grep -cE 'pwg\.(dev|local)' "$TMP/mdns/data.ttl" || true)"
if [ "$n_old" -eq 0 ] && [ "$n_new" -eq 4 ]; then
    ok "the ORIGINAL regex scores that fixture 0 and the widened one scores 4"
else
    no "the widening is not what makes the difference (old=$n_old new=$n_new)" ""
fi

# ---------------------------------------------------------------------------
# 9. THE EXCLUSION PATHSPECS MUST NAME FILES THAT EXIST.
#
#    `git grep -- ':(exclude)path/that/is/not/there'` exits 0, prints no
#    warning, and excludes nothing. The first draft of the exclusion list said
#    `tests/test_no_foreign_ontology_namespace.sh` when the test lives under
#    `scripts/tests/`, so the gate went on counting an occurrence inside its
#    own test and the line read as though it were doing its job.
#
#    A no-op written as a safeguard is worse than no safeguard, because it is
#    documented.
# ---------------------------------------------------------------------------
missing=""
while IFS= read -r rel; do
    [ -e "$REAL/$rel" ] || missing="${missing}${rel}\n"
done < <(sed -n 's/^  ":(exclude)\(.*\)"$/\1/p' "$GATE")
n_excl="$(sed -n 's/^  ":(exclude)\(.*\)"$/\1/p' "$GATE" | grep -c .)"
if [ "$n_excl" -lt 1 ]; then
    no "parsed 0 exclusion pathspecs out of the gate -- this control is measuring nothing" ""
elif [ -n "$missing" ]; then
    no "$n_excl exclusion pathspec(s), some naming files that do not exist (silently a no-op)" "$(printf "$missing")"
else
    ok "all $n_excl exclusion pathspecs name files that exist"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
echo "ALL NAMESPACE RATCHET CONTROLS PASSED"
