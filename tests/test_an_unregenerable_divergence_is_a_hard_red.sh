#!/usr/bin/env bash
# tests/test_an_unregenerable_divergence_is_a_hard_red.sh
# ============================================================================
# CM051 #977. Three vendored trees carry edits that NO DIVERGENCE PATCH
# EXPRESSES, because regeneration was RUN on each and REFUSED for three
# DIFFERENT reasons: one patch failed its own round-trip, one pin is absent from
# the local source checkout, one source has advanced past the pin. All three
# refusals are the tool working correctly and declining to write a patch that
# would be a lie. An agent then recorded them BY HAND, which is honest and is
# not the same as being reconstructible.
#
# THE MEASUREMENT THAT MAKES THIS A DEFECT, taken on origin/main c4d4b5af:
#
#     unrecorded_divergence, readers outside the manifest        0
#     POSITIVE CONTROL, same predicate, same corpus:
#     unverifiable_ack,      readers outside the manifest        1 (the gate)
#
# So the predicate can find a manifest field that IS read, and the zero was real
# absence rather than a blind grep. Three trees declared a debt in a field no
# instrument had ever opened. A record nobody reads is a comment.
#
# And the row names the consequence exactly: "sync_vendor.sh will refuse on
# these trees, and the next person who wants the refusal to go away reaches for
# SYNC_ACCEPT_DIVERGENCE_LOSS=1 and deletes the fixes." Measured: every refusal
# in sync_vendor.sh lives INSIDE `if SYNC_ACCEPT_DIVERGENCE_LOSS != 1`, so that
# variable does not soften the check, it skips it entirely. The file's own prose
# says not to reach for it. Prose is not a guard.
#
# WHAT THIS SUITE PROVES, in four arms that fail in different directions:
#
#   A  the real tree: the field now has a reader, all three declarations are
#      complete, and the real gate names them and counts them.
#   B  the gate, over hermetic fixtures: complete is a counted debt, and four
#      different ways of being incomplete are each RED naming the tree. Plus the
#      guardrail that matters most: a complete record can never silence a
#      CONTENT verdict that was actually reached.
#   C  sync_vendor.sh: the override is REFUSED on a declared tree, with no
#      escape hatch, before the source repo is even resolved. MUST-MISS: an
#      undeclared tree is unaffected.
#   D  mutation of the REAL scripts, each stating a witness first, because a
#      mutant that did not apply looks exactly like one that was caught.
#
# Exit codes: 0 every arm passed / 1 an arm failed / 2 could not run.
# British English throughout. No em dashes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="${REPO_ROOT}/scripts/verify_vendor_fresh.sh"
SYNC="${REPO_ROOT}/scripts/sync_vendor.sh"
LIB="${REPO_ROOT}/scripts/_vendor_lib.sh"
MANIFEST="${REPO_ROOT}/vendor/VENDOR_MANIFEST.toml"

fails=0
arms=0
cannot_run() {
    printf 'CANNOT-RUN: %s\n' "$1" >&2
    printf '            Nothing was examined. This is not a pass.\n' >&2
    exit 2
}
ok()  { arms=$(( arms + 1 )); printf '  PASS  %s\n' "$1"; }
bad() { arms=$(( arms + 1 )); fails=$(( fails + 1 )); printf '  FAIL  %s\n' "$1"; }

for f in "$GATE" "$SYNC" "$LIB" "$MANIFEST"; do
    [ -r "$f" ] || cannot_run "not readable: $f"
done
command -v git >/dev/null 2>&1 || cannot_run "no git on PATH"

WORK="$(mktemp -d)" || cannot_run "could not make a scratch directory"
trap 'rm -rf "$WORK"' EXIT

echo "=== an unregenerable divergence is a hard RED (CM051 #977) ==="
echo "    shell: ${BASH_VERSION}"
echo

# ===========================================================================
# ARM A: THE REAL TREE
# ===========================================================================

n_read="$(grep -rl 'unrecorded_divergence' "${REPO_ROOT}/scripts" 2>/dev/null | grep -c . )"
n_ctl="$(grep -rl 'unverifiable_ack' "${REPO_ROOT}/scripts" 2>/dev/null | grep -c . )"
if [ "${n_ctl:-0}" -lt 1 ]; then
    bad "POSITIVE CONTROL FAILED: unverifiable_ack has ${n_ctl:-0} readers under scripts/, so a zero for unrecorded_divergence would be a statement about this grep rather than about the tree."
else
    ok "POSITIVE CONTROL: unverifiable_ack is read by ${n_ctl} file(s) under scripts/, so the predicate works"
    if [ "${n_read:-0}" -ge 1 ]; then
        ok "unrecorded_divergence is now READ by ${n_read} file(s) under scripts/ (it was read by 0 on origin/main c4d4b5af)"
    else
        bad "unrecorded_divergence has ${n_read:-0} readers under scripts/. A record nothing reads is a comment, which is the whole of #977."
    fi
fi

# Every declaration in the SHIPPED manifest is complete. Driven through the
# real vlib_field, not a re-implementation, so this and the gate cannot disagree.
declared="$(awk '
    /^[[:space:]]*\[\[tree\]\]/ { name=""; next }
    /^[[:space:]]*name[[:space:]]*=/ {
        line=$0; sub(/^[^=]*=[[:space:]]*"/,"",line); sub(/".*$/,"",line); name=line
    }
    /^[[:space:]]*unrecorded_divergence[[:space:]]*=/ { if (name != "") print name }
' "$MANIFEST")"
n_declared="$(printf '%s\n' "$declared" | grep -c . )"
echo "    trees declaring an unrecorded divergence: ${n_declared:-0}"
if [ "${n_declared:-0}" -lt 1 ]; then
    bad "no tree declares an unrecorded_divergence. Arms A2 and A3 would then be measuring nothing, which is green in the same way as measuring everything."
else
    a2_ok=1
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        r="$( . "$LIB"; vlib_field "$t" unrecorded_divergence_reason )"
        o="$( . "$LIB"; vlib_field "$t" unrecorded_divergence_owner )"
        p="$( . "$LIB"; vlib_field "$t" unrecorded_divergence )"
        [ -n "$r" ] || { bad "A2 ${t}: no unrecorded_divergence_reason. The next person cannot retry a refusal nobody measured."; a2_ok=0; }
        [ -n "$o" ] || { bad "A2 ${t}: no unrecorded_divergence_owner. An exemption with nobody's name on it is how a temporary gap becomes permanent."; a2_ok=0; }
        [ -f "${REPO_ROOT}/${p}" ] || { bad "A2 ${t}: declared file ${p} does not exist. A pointer is not a record."; a2_ok=0; }
        if [ -f "${REPO_ROOT}/${p}" ] && ! grep -Fq -- "$t" "${REPO_ROOT}/${p}"; then
            bad "A2 ${t}: ${p} never names this tree, so it records somebody else's divergence."
            a2_ok=0
        fi
    done <<EOF
$declared
EOF
    [ "$a2_ok" -eq 1 ] && ok "A2 all ${n_declared} declaration(s) are complete: file exists, names the tree, reason and owner both set"
fi

# The real gate, on the real tree. VENDOR_FRESH_STRICT=0 because no runner has
# the sibling source repos; the arm below is about the unrecorded limb, which
# runs for every tree whatever its content verdict.
real_out="${WORK}/real.out"
VENDOR_FRESH_STRICT=0 /bin/bash "$GATE" > "$real_out" 2>&1
real_rc=$?
n_unrec_lines="$(grep -c '^UNREC ' "$real_out")"
if [ "${n_unrec_lines:-0}" -eq "${n_declared:-0}" ] && [ "${n_declared:-0}" -ge 1 ]; then
    ok "A3 the real gate names all ${n_declared} unrecorded-divergence tree(s) on its own output"
else
    bad "A3 the real gate printed ${n_unrec_lines:-0} UNREC line(s) for ${n_declared:-0} declared tree(s) (exit ${real_rc}). A declaration the gate does not print is a declaration nobody sees."
fi
if [ "$(grep -c 'unrecorded-divergence' "$real_out")" -ge 1 ]; then
    ok "A3b the count reaches the denominator line, so a reader skimming the summary sees it"
else
    bad "A3b the denominator line carries no unrecorded-divergence count. A debt outside the denominator is a debt nobody totals."
fi

# ===========================================================================
# ARM B: THE GATE, OVER HERMETIC FIXTURES
# ===========================================================================
#
# Real git, a real synthetic source repo, and COPIES of the real scripts, which
# is the pattern tests/test_vendor_fresh_gate.sh already uses. A mocked gate
# would not exercise the branch that decides the verdict.
make_fixture() {   # make_fixture <root>; prints the pinned sha
    local root="$1"
    local src sha
    # SPLIT ACROSS STATEMENTS ON PURPOSE. `local a="$1" b="$a/x"` expands every
    # word BEFORE any assignment takes effect, so $a is still unset there and
    # `set -u` kills the run. Caught by this suite on its first execution.
    src="$root/synthetic-source"
    mkdir -p "$src/pkg"
    (
        cd "$src" || exit 1
        git init --quiet -b main .
        git config user.email selftest@example.invalid
        git config user.name  "unrecorded self-test"
        printf 'def hello():\n    return "v1"\n' > pkg/mod.py
        git add pkg/mod.py
        git commit --quiet -m "v1"
    ) || return 1
    sha="$(git -C "$src" rev-parse HEAD)"
    mkdir -p "$root/scripts" "$root/vendor/synthtree/pkg" "$root/vendor/divergences"
    cp "$LIB" "$GATE" "$SYNC" "$root/scripts/"
    cp "$src/pkg/mod.py" "$root/vendor/synthtree/pkg/mod.py"
    cat > "$root/vendor/VENDOR_MANIFEST.toml" <<EOF
[[tree]]
name             = "synthtree"
vendor_path      = "vendor/synthtree"
source_repo      = "$src"
source_path      = "."
pinned_sha       = "$sha"
divergence_patch = ""
exclude          = ["__pycache__/"]
verify           = "full"
EOF
    printf '%s\n' "$sha"
}

declare_record() {  # declare_record <root> <reason-or-empty> <owner-or-empty> <file-or-empty> <name-it: yes|no>
    local root="$1" reason="$2" owner="$3" file="$4" nameit="$5"
    if [ -n "$file" ]; then
        printf '  unrecorded_divergence = "%s"\n' "$file" >> "$root/vendor/VENDOR_MANIFEST.toml"
    fi
    [ -n "$reason" ] && printf '  unrecorded_divergence_reason = "%s"\n' "$reason" >> "$root/vendor/VENDOR_MANIFEST.toml"
    [ -n "$owner" ]  && printf '  unrecorded_divergence_owner  = "%s"\n' "$owner"  >> "$root/vendor/VENDOR_MANIFEST.toml"
    return 0
}

write_record_file() {  # write_record_file <root> <relpath> <name-it: yes|no>
    local root="$1" rel="$2" nameit="$3"
    mkdir -p "$(dirname "$root/$rel")"
    if [ "$nameit" = "yes" ]; then
        printf 'The tree synthtree carries edits no patch expresses. Measured refusal recorded here.\n' > "$root/$rel"
    else
        printf 'This record is about an entirely different subject.\n' > "$root/$rel"
    fi
}

run_fixture_gate() {  # run_fixture_gate <root>; output to $WORK/fx.out, prints rc
    local rc
    ( cd "$1" && VENDOR_FRESH_STRICT=1 bash scripts/verify_vendor_fresh.sh ) > "${WORK}/fx.out" 2>&1
    rc=$?
    printf '%s' "$rc"
}

expect_fx() {  # expect_fx <label> <root> <want-rc> <want-string>
    local label="$1" root="$2" want_rc="$3" want="$4" rc
    rc="$(run_fixture_gate "$root")"
    if [ "$rc" != "$want_rc" ]; then
        bad "${label}: exit ${rc}, expected ${want_rc}. $(grep -e '^GATE' -e '^FAIL' "${WORK}/fx.out" | head -2 | tr '\n' ' ')"
        return
    fi
    if [ "$(grep -c -F -- "$want" "${WORK}/fx.out")" -lt 1 ]; then
        bad "${label}: exit ${want_rc} was right but the output never says '${want}', so it could be right for the wrong reason."
        return
    fi
    ok "${label}: exit ${want_rc}, naming '${want}'"
}

# B0 CONTROL: no declaration at all -> a PLAIN green. If this does not hold,
# B1's distinctive wording proves nothing, because every run would say it.
R="${WORK}/b0"; mkdir -p "$R"; make_fixture "$R" >/dev/null || cannot_run "fixture b0"
expect_fx "B0 CONTROL no declaration" "$R" 0 "GATE: GREEN -- every vendored tree"

# B1 a COMPLETE declaration: a counted debt, and never a plain GREEN.
R="${WORK}/b1"; mkdir -p "$R"; make_fixture "$R" >/dev/null || cannot_run "fixture b1"
write_record_file "$R" "vendor/divergences/SYNTH.UNRECORDED.md" yes
declare_record "$R" "regeneration REFUSED exit 1, round-trip check failed" "ORM" "vendor/divergences/SYNTH.UNRECORDED.md" yes
expect_fx "B1 a complete declaration is a counted debt" "$R" 0 "GREEN WITH 1 UNRECORDED-DIVERGENCE TREE(S)"
if [ "$(grep -c '^UNREC synthtree' "${WORK}/fx.out")" -eq 1 ]; then
    ok "B1b the tree is named on its own line, with its measured reason and owner"
else
    bad "B1b no 'UNREC synthtree' line. The verdict counts it and the body never says which tree."
fi
if [ "$(grep -c 'GATE: GREEN -- every vendored tree' "${WORK}/fx.out")" -eq 0 ]; then
    ok "B1c the plain GREEN wording is GONE while a debt is live, so a reader skimming the last line cannot misread it"
else
    bad "B1c the gate still printed the plain 'GATE: GREEN' line. That is the wording that made 'GREEN with N warnings' so dangerous."
fi

# B2 to B5: four different ways to be incomplete, each RED naming the tree.
R="${WORK}/b2"; mkdir -p "$R"; make_fixture "$R" >/dev/null || cannot_run "fixture b2"
write_record_file "$R" "vendor/divergences/SYNTH.UNRECORDED.md" yes
declare_record "$R" "" "ORM" "vendor/divergences/SYNTH.UNRECORDED.md" yes
expect_fx "B2 declared with NO reason" "$R" 1 "INCOMPLETE"

R="${WORK}/b3"; mkdir -p "$R"; make_fixture "$R" >/dev/null || cannot_run "fixture b3"
write_record_file "$R" "vendor/divergences/SYNTH.UNRECORDED.md" yes
declare_record "$R" "a measured refusal" "" "vendor/divergences/SYNTH.UNRECORDED.md" yes
expect_fx "B3 declared with NO owner" "$R" 1 "INCOMPLETE"

R="${WORK}/b4"; mkdir -p "$R"; make_fixture "$R" >/dev/null || cannot_run "fixture b4"
declare_record "$R" "a measured refusal" "ORM" "vendor/divergences/NOT_THERE.md" yes
expect_fx "B4 declared file does not exist" "$R" 1 "INCOMPLETE"

R="${WORK}/b5"; mkdir -p "$R"; make_fixture "$R" >/dev/null || cannot_run "fixture b5"
write_record_file "$R" "vendor/divergences/OTHER.UNRECORDED.md" no
declare_record "$R" "a measured refusal" "ORM" "vendor/divergences/OTHER.UNRECORDED.md" no
expect_fx "B5 declared file never names the tree" "$R" 1 "INCOMPLETE"

# B6 THE GUARDRAIL THAT MATTERS MOST. A complete record must never silence a
# CONTENT verdict that was actually reached. Same doctrine as unverifiable_ack
# guardrail 1: an acknowledgement applies only where the gate was already going
# to say "I could not tell", never where it could.
R="${WORK}/b6"; mkdir -p "$R"; make_fixture "$R" >/dev/null || cannot_run "fixture b6"
write_record_file "$R" "vendor/divergences/SYNTH.UNRECORDED.md" yes
declare_record "$R" "a measured refusal" "ORM" "vendor/divergences/SYNTH.UNRECORDED.md" yes
printf '\n# rot injected by the self-test, present in no source commit\n' >> "$R/vendor/synthtree/pkg/mod.py"
expect_fx "B6 a complete record does NOT silence real drift" "$R" 1 "DIFFERS from source"

# ===========================================================================
# ARM C: sync_vendor.sh REFUSES THE OVERRIDE
# ===========================================================================
run_sync() {  # run_sync <root> <env-value>; output to $WORK/sy.out, prints rc
    local rc
    ( cd "$1" && SYNC_ACCEPT_DIVERGENCE_LOSS="$2" bash scripts/sync_vendor.sh synthtree ) \
        > "${WORK}/sy.out" 2>&1
    rc=$?
    printf '%s' "$rc"
}

REFUSAL='DOES NOT LIFT THIS'

R="${WORK}/c1"; mkdir -p "$R"; make_fixture "$R" >/dev/null || cannot_run "fixture c1"
write_record_file "$R" "vendor/divergences/SYNTH.UNRECORDED.md" yes
declare_record "$R" "regeneration REFUSED exit 1" "ORM" "vendor/divergences/SYNTH.UNRECORDED.md" yes
rc="$(run_sync "$R" 1)"
if [ "$rc" = "1" ] && [ "$(grep -c -F -- "$REFUSAL" "${WORK}/sy.out")" -ge 1 ]; then
    ok "C1 the override is REFUSED on a declared tree (exit 1, and the message says so in as many words)"
else
    bad "C1 SYNC_ACCEPT_DIVERGENCE_LOSS=1 was honoured on a tree whose loss is unreconstructible (exit ${rc}). That is the wound #977 names, intact."
fi

# C2 FAIL-CLOSED ON A HALF-WRITTEN RECORD. This is the state where the reader
# has least idea what an override would destroy, so treating it as "not
# declared" would put the escape hatch back exactly where it does most harm.
R="${WORK}/c2"; mkdir -p "$R"; make_fixture "$R" >/dev/null || cannot_run "fixture c2"
declare_record "$R" "" "" "vendor/divergences/SYNTH.UNRECORDED.md" yes
rc="$(run_sync "$R" 1)"
if [ "$rc" = "1" ] && [ "$(grep -c -F -- "$REFUSAL" "${WORK}/sy.out")" -ge 1 ]; then
    ok "C2 an INCOMPLETE declaration refuses too, rather than falling back to the escape hatch"
else
    bad "C2 an incomplete declaration let the override through (exit ${rc}). A half-written record is the worst case, not the exempt one."
fi

# C3 MUST-MISS. An undeclared tree must NOT hit this refusal, or the rule is
# just a blanket ban wearing a reason.
R="${WORK}/c3"; mkdir -p "$R"; make_fixture "$R" >/dev/null || cannot_run "fixture c3"
rc="$(run_sync "$R" 1)"
if [ "$(grep -c -F -- "$REFUSAL" "${WORK}/sy.out")" -eq 0 ]; then
    ok "C3 MUST-MISS: an undeclared tree is not caught by this rule (its own outcome was exit ${rc})"
else
    bad "C3 an undeclared tree hit the unrecorded-divergence refusal. The rule would be a blanket ban with a misleading reason attached."
fi

# C4 THE REFUSAL FIRES BEFORE resolve_source_repo. A refusal that only works
# once the source resolves never fires on the machines most likely to need it,
# and every one of the three real declarations exists precisely because a source
# was unavailable or unusable.
R="${WORK}/c4"; mkdir -p "$R"; make_fixture "$R" >/dev/null || cannot_run "fixture c4"
write_record_file "$R" "vendor/divergences/SYNTH.UNRECORDED.md" yes
declare_record "$R" "a measured refusal" "ORM" "vendor/divergences/SYNTH.UNRECORDED.md" yes
rm -rf "$R/synthetic-source"
rc="$(run_sync "$R" 1)"
if [ "$rc" = "1" ] && [ "$(grep -c -F -- "$REFUSAL" "${WORK}/sy.out")" -ge 1 ]; then
    ok "C4 the refusal fires with the source repo ABSENT, so it works on the machine that has no checkout"
else
    bad "C4 with the source repo absent the run exited ${rc} without the unrecorded refusal. $(head -2 "${WORK}/sy.out" | tr '\n' ' ')"
fi

# ===========================================================================
# ARM D: MUTATION OF THE REAL SCRIPTS
# ===========================================================================
#
# Every arm states a WITNESS that must hold before its assertion is scored. A
# mutation that silently failed to apply looks exactly like one that was caught.

# D1 the gate stops reading the field.
R="${WORK}/d1"; mkdir -p "$R"; make_fixture "$R" >/dev/null || cannot_run "fixture d1"
write_record_file "$R" "vendor/divergences/SYNTH.UNRECORDED.md" yes
declare_record "$R" "a measured refusal" "ORM" "vendor/divergences/SYNTH.UNRECORDED.md" yes
grep -v '^    report_unrecorded "\$tree"$' "$R/scripts/verify_vendor_fresh.sh" > "$R/g.tmp" \
  && mv "$R/g.tmp" "$R/scripts/verify_vendor_fresh.sh"
if [ "$(grep -c 'report_unrecorded "\$tree"' "$R/scripts/verify_vendor_fresh.sh")" -ne 0 ]; then
    bad "D1: THE MUTATION DID NOT APPLY, so its assertion is not scored."
else
    rc="$(run_fixture_gate "$R")"
    if [ "$(grep -c '^UNREC ' "${WORK}/fx.out")" -eq 0 ]; then
        ok "D1 removing the gate's one call site makes the declaration invisible again, so arm B measures the call and not a coincidence"
    else
        bad "D1 the gate still reported UNREC with its call site deleted. Something else is printing it and arm B is not measuring what it claims."
    fi
fi

# D2 sync_vendor stops refusing.
R="${WORK}/d2"; mkdir -p "$R"; make_fixture "$R" >/dev/null || cannot_run "fixture d2"
write_record_file "$R" "vendor/divergences/SYNTH.UNRECORDED.md" yes
declare_record "$R" "a measured refusal" "ORM" "vendor/divergences/SYNTH.UNRECORDED.md" yes
grep -v -F -- "$REFUSAL" "$R/scripts/sync_vendor.sh" > "$R/s.tmp" \
  && mv "$R/s.tmp" "$R/scripts/sync_vendor.sh"
if [ "$(grep -c -F -- "$REFUSAL" "$R/scripts/sync_vendor.sh")" -ne 0 ]; then
    bad "D2: THE MUTATION DID NOT APPLY, so its assertion is not scored."
else
    rc="$(run_sync "$R" 1)"
    if [ "$(grep -c -F -- "$REFUSAL" "${WORK}/sy.out")" -eq 0 ]; then
        ok "D2 deleting the refusal text removes the refusal, so arm C measures the guard and not the fixture"
    else
        bad "D2 the refusal message survived its own deletion, so arm C is reading something other than the guard."
    fi
fi

# ===========================================================================
echo
echo "arms scored: ${arms}   failed: ${fails}"
if [ "$fails" -gt 0 ]; then
    echo "RESULT: FAIL, ${fails} of ${arms} arms"
    exit 1
fi
if [ "$arms" -lt 16 ]; then
    echo "RESULT: CANNOT-RUN, only ${arms} arms were scored, expected at least 16."
    exit 2
fi
echo "RESULT: PASS, ${arms} of ${arms} arms"
exit 0
