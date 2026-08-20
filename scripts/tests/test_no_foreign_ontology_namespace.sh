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

# ---------------------------------------------------------------------------
# 8. THE SECOND DOMAIN, WITH A DEMONSTRATED RED.
#
# The regex started as `pwg\.dev` alone. The shipped tree also carries
# `http://pwg.local/ontology#` -- CM019's enrichment service writes every
# enriched preference into it. A pwg.dev-only ratchet cannot see that, so
# retiring pwg.dev would have read as a completed migration while leaving
# "pwg" stamped into the customer's graph forever.
#
# Asserting the new regex alone would prove nothing: it has to be shown that
# the OLD one scored zero on the same tree. So this builds a repo containing
# ONLY the second domain, runs a copy of the gate with the regex reverted, and
# requires 0 -- then runs the shipped gate and requires the occurrences.
# ---------------------------------------------------------------------------
mklocal() {  # like mkrepo but writes the mDNS-reserved domain instead
    local d="$1" n="$2" decl="$3" i
    rm -rf "$d"; mkdir -p "$d/scripts"
    git -C "$d" init -q 2>/dev/null
    : > "$d/data.ttl"
    i=0; while [ "$i" -lt "$n" ]; do printf '@prefix pwg: <http://pwg.local/ontology#> .\n' >> "$d/data.ttl"; i=$((i+1)); done
    printf '# declared\n%s\n' "$decl" > "$d/scripts/.foreign-ontology-namespace-count"
    git -C "$d" add -A 2>/dev/null; git -C "$d" -c user.email=t@t -c user.name=t commit -qm x 2>/dev/null
}

mklocal "$TMP/mdns" 4 4
OLDGATE="$TMP/old_gate.sh"
sed "s/^FOREIGN_RE='pwg\\\\.(dev|local)'/FOREIGN_RE='pwg\\\\.dev'/" "$GATE" > "$OLDGATE"
if [ "$(grep -c "FOREIGN_RE='pwg\\\\.dev'" "$OLDGATE")" -lt 1 ]; then
    no "could not build the pre-fix gate -- the red is UNDEMONSTRATED, so control 8 proves nothing" \
       "$(grep -n 'FOREIGN_RE=' "$GATE")"
else
    bash "$OLDGATE" "$TMP/mdns" >"$TMP/oldout" 2>&1
    old_n="$(sed -n 's/.*occurrences=\([0-9]*\).*/\1/p' "$TMP/oldout" | head -1)"
    rc="$(run "$TMP/mdns")"
    new_n="$(sed -n 's/.*occurrences=\([0-9]*\).*/\1/p' "$TMP/out" | head -1)"
    if [ "${old_n:-x}" != "0" ]; then
        no "the pre-fix regex already saw the second domain (${old_n}) -- nothing was fixed" "$(cat "$TMP/oldout")"
    elif [ "${new_n:-0}" != "4" ]; then
        no "the shipped regex counted ${new_n:-0} of 4 mDNS-reserved occurrences" "$(cat "$TMP/out")"
    elif [ "$rc" != 0 ]; then
        no "at-count on the second domain was not green (rc=$rc)" "$(cat "$TMP/out")"
    else
        ok "second domain: pre-fix regex 0, shipped regex 4 (DEMONSTRATED RED)"
    fi
fi

# ---------------------------------------------------------------------------
# 9. THE INSTRUMENT MUST NOT COUNT ITSELF -- PINNED BY BEHAVIOUR, NOT SPELLING.
#
# This control exists because the first exclusion did not work. The pathspec
# read `tests/test_no_...` while the file is at `scripts/tests/test_no_...`,
# and a pathspec that matches nothing excludes nothing and reports no error.
# The declared count carried the error: 292 against a tree holding 291.
#
# So do not assert the pathspec text. Plant the gate, its declaration and its
# test at their REAL paths inside a fixture, each naming the domains in prose
# exactly as they do in the repo, and require the reading to equal the DATA
# occurrences only. Any future rename that breaks an exclusion turns this red.
# ---------------------------------------------------------------------------
mkrepo "$TMP/selfcount" 5 5
mkdir -p "$TMP/selfcount/scripts/tests"
cp "$GATE" "$TMP/selfcount/scripts/verify_no_foreign_ontology_namespace.sh"
cp "$HERE/../.foreign-ontology-namespace-count" "$TMP/selfcount/scripts/.foreign-ontology-namespace-count"
cp "${BASH_SOURCE[0]}" "$TMP/selfcount/scripts/tests/test_no_foreign_ontology_namespace.sh"
printf '# declared\n5\n' > "$TMP/selfcount/scripts/.foreign-ontology-namespace-count.tmp"
# keep the real prose but restore the fixture's own declared number
{ grep -vE '^[0-9]+$' "$HERE/../.foreign-ontology-namespace-count"; echo 5; } \
    > "$TMP/selfcount/scripts/.foreign-ontology-namespace-count"
rm -f "$TMP/selfcount/scripts/.foreign-ontology-namespace-count.tmp"
git -C "$TMP/selfcount" add -A 2>/dev/null
git -C "$TMP/selfcount" -c user.email=t@t -c user.name=t commit -qm self 2>/dev/null
rc="$(run "$TMP/selfcount")"
self_n="$(sed -n 's/.*occurrences=\([0-9]*\).*/\1/p' "$TMP/out" | head -1)"
if [ "${self_n:-0}" != "5" ]; then
    no "the gate counted its own documentation: read ${self_n:-0} where only 5 are data" "$(cat "$TMP/out")"
elif [ "$rc" != 0 ]; then
    no "a tree at its declared count went non-green once the instrument was present (rc=$rc)" "$(cat "$TMP/out")"
else
    ok "gate + declaration + test present in-tree -> reading unchanged at 5 (SELF-EXCLUSION HOLDS)"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
echo "ALL NAMESPACE RATCHET CONTROLS PASSED"
