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
#    So it asserted the GREEN LINE, which only the at-count branch prints.
#
#    AND THAT OVERCORRECTED INTO A THIRD DEFECT, WHICH TOOK MAIN RED.
#
#    Measured: #814 merged at 71910de with a declaration of 294 taken on
#    7cc2a6f. Four PRs landed in between (#813, #812, #817, #816) and added
#    seven occurrences, so the real tree was at 301. The gate did exactly
#    what it is designed to do -- WARN, name both numbers, and exit 0,
#    because it is deliberately ADVISORY while the declared count is above
#    zero. This control turned that designed warning into a hard CI red.
#
#    THE GATE HAS THREE STATES AND THE CONTROL HAD TWO. Same shape as
#    CANNOT-RUN being neither PASS nor FAIL, and the same shape as the
#    original defect, one turn of the screw further on:
#
#        GREEN      at the declared count            -> pass
#        ADVISORY   out of step, declared > 0        -> NOT a failure of
#                                                       this control. It is
#                                                       the ratchet doing its
#                                                       job. Surface it.
#        anything   cannot run, or no verdict at all -> fail
#
#    A ratchet that hard-fails on the exact event it exists to merely warn
#    about is a cliff, and Archie's original call was that a cliff gets
#    routed around or deleted. Making the advisory a red would have re-created
#    that by the back door, from the test side, where nobody would look for it.
#
#    The teeth do not come from this control. They come from the DECLARED
#    NUMBER only moving when a human edits it, and from control 2b, which
#    proves that at zero the advisory is gone and the gate is hard.
# ---------------------------------------------------------------------------
REAL="$(cd "$HERE/../.." && pwd)"
rc="$(run "$REAL")"
n_declared="$(grep -vE '^[[:space:]]*#' "$REAL/scripts/.foreign-ontology-namespace-count" 2>/dev/null | tr -dc '0-9')"

if [ "$rc" = 2 ]; then
    no "the gate CANNOT RUN against the real repository (rc=2)" "$(cat "$TMP/out")"
elif [ "$rc" != 0 ]; then
    no "the real repository FAILED the gate hard (rc=$rc)" "$(cat "$TMP/out")"
elif [ "$(grep -c 'GATE: GREEN' "$TMP/out")" -ge 1 ]; then
    ok "the REAL repository is at its declared count (GREEN, not merely rc=0)"
elif [ "$(grep -c 'ADVISORY while the declared count is above zero' "$TMP/out")" -ge 1 ]; then
    # Deliberately a PASS, and deliberately loud. The drift is printed here
    # rather than swallowed, so it is visible in the CI log of every PR until
    # somebody re-declares, which is the pressure the ratchet is supposed to
    # apply. What it must not do is stop unrelated work from landing.
    ok "the gate is ADVISORY and said so (declared ${n_declared:-?}); ratchet working, tree out of step"
    printf '        | %s\n' "$(grep -E 'occurrences=|went (UP|DOWN)' "$TMP/out" | head -2)"
else
    no "rc=0 but the gate printed NEITHER a GREEN line nor an ADVISORY line -- no verdict at all" "$(cat "$TMP/out")"
fi

# 7b. THE INSTRUMENT STILL DETECTS DRIFT ON THE REAL TREE. This is a property
#     of the GATE, not a red proof for control 7 any more: skewing the
#     declaration now produces the ADVISORY branch, which 7 deliberately
#     accepts. It is still worth asserting, because if the gate stopped
#     noticing drift altogether then 7's advisory pass would be vacuous.
#
#     THIS ARM SKEWS UPWARD, AND THE REASON IS THE MIGRATION. It used to skew
#     to `n_real - 50` and grep for "went UP", which worked only while the
#     real count was large. At the zero floor `n_real - 50` is -50, the gate's
#     own `tr -dc '0-9'` strips the sign and reads it as 50, and the drift
#     flips from UP to DOWN -- so the arm failed while the gate was working
#     perfectly. A control whose direction depends on the size of the baseline
#     is a control that expires. Skewing UPWARD is well-defined at every
#     baseline including zero, so this arm now asserts the PROPERTY (drift is
#     seen, GREEN is withheld) rather than one particular direction of it.
REALDECL="$REAL/scripts/.foreign-ontology-namespace-count"
if [ -r "$REALDECL" ]; then
    n_real="$(grep -vE '^[[:space:]]*#' "$REALDECL" | tr -dc '0-9')"
    printf '# temporary, control 7b\n%s\n' "$(( n_real + 50 ))" > "$TMP/decl.skewed"
    rc="$(OSTLER_NS_COUNT_FILE="$TMP/decl.skewed" bash "$GATE" "$REAL" >"$TMP/out" 2>&1; echo $?)"
    if [ "$(grep -c 'GATE: GREEN' "$TMP/out")" -ge 1 ]; then
        no "a declaration 50 out still printed GREEN -- the gate has stopped seeing drift" "$(cat "$TMP/out")"
    elif [ "$(grep -c 'WARN:' "$TMP/out")" -lt 1 ]; then
        no "a declaration 50 out produced no WARN -- the gate has stopped seeing drift" "$(cat "$TMP/out")"
    else
        ok "a declaration 50 out is still SEEN: WARN, no GREEN (the ratchet notices)"
    fi

    # 7c. A NEGATIVE DECLARATION MUST NOT READ AS ITS OWN ABSOLUTE VALUE.
    #     Found while fixing 7b: `tr -dc '0-9'` deletes the minus sign, so a
    #     declaration of -50 was silently read as 50. Nobody would write a
    #     negative on purpose, but arithmetic in a caller can produce one --
    #     7b itself did -- and a gate that turns a nonsense input into a
    #     plausible number reports a confident verdict about the wrong
    #     question. CANNOT-RUN is the only honest answer to input it cannot
    #     parse.
    printf '# temporary, control 7c\n-50\n' > "$TMP/decl.negative"
    rc="$(OSTLER_NS_COUNT_FILE="$TMP/decl.negative" bash "$GATE" "$REAL" >"$TMP/out" 2>&1; echo $?)"
    if [ "$rc" = "2" ]; then
        ok "a NEGATIVE declaration is CANNOT-RUN (rc=2), not silently its absolute value"
    else
        no "a negative declaration produced rc=$rc -- the sign was eaten and a nonsense input read as a number" "$(cat "$TMP/out")"
    fi
else
    no "cannot read the real declaration at $REALDECL" ""
fi

# 7c. PROVE CONTROL 7 CAN STILL FAIL, ON THE AXIS IT NOW FAILS ON.
#
#     7 used to be proved red by skewing the declaration. It no longer fails
#     for that, so that proof is spent and reusing it would be the shape this
#     whole file exists to stop: a red proof that no longer exercises the
#     branch it claims to. 7 now fails on CANNOT-RUN and on no-verdict, so
#     that is what has to be shown. Delete the declaration and require rc=2.
rc="$(OSTLER_NS_COUNT_FILE="$TMP/definitely-not-here" bash "$GATE" "$REAL" >"$TMP/out" 2>&1; echo $?)"
if [ "$rc" != 2 ]; then
    no "PROVE RED FAILED [control 7]: an absent declaration gave rc=$rc, so 7 has no failing branch" "$(cat "$TMP/out")"
elif [ "$(grep -c 'CANNOT-RUN' "$TMP/out")" -lt 1 ]; then
    no "PROVE RED FAILED [control 7]: rc=2 but no CANNOT-RUN said out loud" "$(cat "$TMP/out")"
else
    ok "PROVED RED [control 7]: an unrunnable gate is rc=2 and control 7 fails on it"
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
# 8c. THE URN AXIS, WHICH IS THE THIRD WIDENING AND WAS THE LARGEST BLIND SPOT.
#
#     Controls 8 and 8b prove the DOMAIN widening. They cannot prove this one,
#     because a URN has no host and no dot: any pattern shaped around
#     `pwg.<tld>` scores a `urn:pwg:` tree at exactly zero, forever, with no
#     error and no warning. Measured 2026-08-20, that blind spot held 365
#     occurrences across the shipping trees -- preference, person, todo,
#     conversation, user and named-graph identifiers -- while the ratchet
#     reported 294 and read as the whole problem.
#
#     Single-axis on purpose: the fixture contains NO dotted pwg host at all,
#     so if the URN arm were dropped from the regex this control goes red on
#     its own rather than being propped up by a sibling.
# ---------------------------------------------------------------------------
mkurnrepo() {
    local d="$1" n="$2" decl="$3" i=0
    rm -rf "$d"; mkdir -p "$d/scripts"
    git -C "$d" init -q 2>/dev/null
    : > "$d/data.ttl"
    while [ "$i" -lt "$n" ]; do printf '<urn:pwg:preference:%s> a <urn:pwg:Preference> .\n' "$i" >> "$d/data.ttl"; i=$((i+1)); done
    printf '# declared\n%s\n' "$decl" > "$d/scripts/.foreign-ontology-namespace-count"
    git -C "$d" add -A 2>/dev/null; git -C "$d" -c user.email=t@t -c user.name=t commit -qm x 2>/dev/null
}
mkurnrepo "$TMP/urn" 4 0
[ "$(grep -cE 'pwg\.(dev|local)' "$TMP/urn/data.ttl")" -eq 0 ] \
    || no "URN fixture is not single-axis: it contains a dotted pwg host" ""
rc="$(run "$TMP/urn")"
if [ "$rc" != 1 ]; then
    no "a urn:pwg:-only tree against declared 0 was NOT caught (rc=$rc) -- the regex is still host-shaped" "$(cat "$TMP/out")"
else
    ok "PROVED RED on its own axis: urn:pwg: alone, no dotted host present, is caught"
fi

# 8d. and that fixture is genuinely invisible to the DOMAIN-ONLY regex, so 8c
#     measures the URN widening rather than restating control 8.
n_host="$(grep -cE 'pwg\.(dev|local)' "$TMP/urn/data.ttl" || true)"
n_full="$(grep -cE 'pwg\.(dev|local)|urn:pwg:' "$TMP/urn/data.ttl" || true)"
if [ "$n_host" -eq 0 ] && [ "$n_full" -eq 4 ]; then
    ok "the DOMAIN-only regex scores the URN fixture 0 and the full one scores 4"
else
    no "the URN widening is not what makes the difference (host=$n_host full=$n_full)" ""
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

# ---------------------------------------------------------------------------
# A DIFF'S SIGN IS ITS MEANING. A `-` line in a patch is evidence the string was
# REMOVED, and counting it as an occurrence reads ABSENCE AS PRESENCE.
#
# Measured 2026-08-28 on CM051 #1219, which regenerated vendor/divergences/
# doctor.patch and recorded that the vendoring strips pwg.dev out of upstream:
#     doctor.patch:5249:-    @prefix pwg: <https://pwg.dev/ontology#> .
#     doctor.patch:5258:-PWG_PREFIX_URL = "https://pwg.dev/ontology#"
#     doctor.patch:5267:-        "PREFIX pwg: <https://pwg.dev/ontology#>\n"
# occurrences=3 declared=0, gate RED -- on the commit that DOCUMENTS compliance.
# Control at the time: `git grep -c pwg.dev -- vendor/doctor/` returned ZERO
# files, with a must-be-present control (ServiceHealthInfo, 10 hits) proving the
# search worked. The shipped tree was clean.
#
# TWO ARMS, because the fix must not become a hiding place. The patch is
# generated as `diff source@pinned_sha -> vendored tree`
# (scripts/regenerate_divergence_patch.sh:298), so a `+` line is a line the
# VENDORED tree carries and MUST still count.
# ---------------------------------------------------------------------------
mkpatchrepo() {
    local d="$1" sign="$2"
    rm -rf "$d"; mkdir -p "$d/scripts" "$d/vendor/divergences"
    git -C "$d" init -q 2>/dev/null
    {
        printf -- '--- a/agent/x.py\n+++ b/agent/x.py\n@@ -1,3 +1,3 @@\n'
        printf -- '%sPWG_PREFIX_URL = "https://pwg.dev/ontology#"\n' "$sign"
        printf -- ' unchanged_line\n'
    } > "$d/vendor/divergences/doctor.patch"
    printf '# declared\n0\n' > "$d/scripts/.foreign-ontology-namespace-count"
    git -C "$d" add -A 2>/dev/null
    git -C "$d" -c user.email=t@t -c user.name=t commit -qm x 2>/dev/null
}

mkpatchrepo "$TMP/patchdel" "-"
rc="$(run "$TMP/patchdel")"
if [ "$rc" != 0 ]; then
    no "a patch containing only a DELETION of pwg.dev was counted as an occurrence (rc=$rc) -- absence read as presence" "$(cat "$TMP/out")"
else
    ok "a '-' line in a divergence patch is a REMOVAL and is not counted"
fi

mkpatchrepo "$TMP/patchadd" "+"
rc="$(run "$TMP/patchadd")"
if [ "$rc" != 1 ]; then
    no "a patch ADDING pwg.dev was NOT caught (rc=$rc) -- the diff-aware count became a hiding place" "$(cat "$TMP/out")"
else
    ok "PROVED RED: a '+' line in a divergence patch still counts"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
echo "ALL NAMESPACE RATCHET CONTROLS PASSED"
