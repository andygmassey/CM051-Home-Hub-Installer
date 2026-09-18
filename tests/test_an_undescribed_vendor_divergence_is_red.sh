#!/usr/bin/env bash
# tests/test_an_undescribed_vendor_divergence_is_red.sh
# ============================================================================
# CM051 #1961. On a CI runner an undescribed vendor divergence cannot be
# caught, and that is a consequence of an opt-out rather than a bug in it.
#
# WHAT WAS RE-MEASURED HERE RATHER THAN INHERITED
#
#   VENDOR_FRESH_STRICT="0" appears exactly ONCE in the tree, in
#   .github/workflows/vendor-integrity.yml, above fourteen lines saying why,
#   and that step prints GATE: DEGRADED and never GREEN. The freshness gate is
#   fail-closed by default and is NOT broken. Arm A below pins all of that, so
#   a future PR that quietly widens the opt-out goes red here.
#
#   The gap is the consequence: the runner has no CM041, CM048 or HR015
#   checkout, so every cross-repo tree degrades to unverifiable and the content
#   limb never executes. Nothing on CI stands between "somebody hand-edited a
#   vendored file" and "the next sync_vendor.sh deletes it".
#
# THE REAL SPECIMENS, AND THEY ARE THE POINT
#
# Two MERGED commits on this repository's own main are driven through the gate
# in arm C. Neither is synthetic and neither was chosen after seeing the result:
#
#   f2fe7eea  CM051 #1956, the db-key and recovery-key PR. Three vendored trees
#             edited. Two carry a regenerated divergence patch. The third,
#             cm048_pipeline, carries NOTHING, and the manifest says so in its
#             own words in a field that same commit added: "UNDESCRIBED DELTA
#             LIVES HERE ... This row is verify = 'skip', so NOTHING WILL GO RED
#             about it." The gate makes that last sentence false.
#
#   fb5c7bcf  CM051 #1974. Two files under vendor/cm041/identity_resolver
#             hand-edited, no divergence patch touched, the record left as prose
#             in the manifest `note`. A prose note is not something any tool
#             reads.
#
# A gate validated only against fixtures its author wrote is a gate validated
# against its author's imagination. These two are the corpus it exists for.
#
# ARMS
#   A  the opt-out is still exactly one call site, and still says DEGRADED
#   B  the four description routes, and the refusal, over synthetic git repos
#   C  the two real merged specimens
#   D  CANNOT-RUN is a third state, with a specific code and a specific reason
#
# Exit codes: 0 every arm passed / 1 an arm failed / 2 could not run.
# British English throughout. No em dashes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE_REL="scripts/verify_vendor_divergence_described.py"
GATE="${REPO_ROOT}/${GATE_REL}"

fails=0
arms=0
cannot_run() {
    printf 'CANNOT-RUN: %s\n' "$1" >&2
    printf '            Nothing was examined. This is not a pass.\n' >&2
    exit 2
}
ok()  { arms=$(( arms + 1 )); printf '  PASS  %s\n' "$1"; }
bad() { arms=$(( arms + 1 )); fails=$(( fails + 1 )); printf '  FAIL  %s\n' "$1"; }

[ -r "$GATE" ] || cannot_run "gate not readable: ${GATE}"
command -v git >/dev/null 2>&1 || cannot_run "no git on PATH"
command -v python3 >/dev/null 2>&1 || cannot_run "no python3 on PATH"
python3 -c 'import tomllib' 2>/dev/null \
    || cannot_run "this python3 has no tomllib, so the gate cannot read the manifest"

WORK="$(mktemp -d)" || cannot_run "could not make a scratch directory"
trap 'rm -rf "$WORK"' EXIT

echo "=== an undescribed vendor divergence is RED (CM051 #1961) ==="
echo "    gate:   ${GATE_REL}"
echo "    python: $(python3 -c 'import sys;print(sys.version.split()[0])')"
echo

# ===========================================================================
# ARM A: THE OPT-OUT IS STILL EXACTLY ONE CALL SITE
# ===========================================================================
#
# #1961's first paragraph is a CORRECTION of an earlier wrong report, and the
# correction is the load-bearing part: the design is deliberate and good. So
# the thing to guard is that it stays deliberate. A second VENDOR_FRESH_STRICT=0
# appearing somewhere, or the DEGRADED wording softening to GREEN, would rebuild
# the false-green this estate already removed once.
n_optout="$(grep -rl 'VENDOR_FRESH_STRICT' "${REPO_ROOT}/.github/workflows" 2>/dev/null | grep -c . )"
n_zero="$(grep -rn 'VENDOR_FRESH_STRICT: *"0"' "${REPO_ROOT}/.github/workflows" 2>/dev/null | grep -c . )"
if [ "${n_zero:-0}" -eq 1 ]; then
    ok "exactly ONE workflow sets VENDOR_FRESH_STRICT=0 (in ${n_optout:-0} workflow file(s) mentioning the variable at all)"
else
    bad "${n_zero:-0} workflow sites set VENDOR_FRESH_STRICT=0, expected exactly 1. Every extra one is a lenient default inherited somewhere nobody argued for."
fi

if [ "$(grep -c 'STRICT="${VENDOR_FRESH_STRICT:-1}"' "${REPO_ROOT}/scripts/verify_vendor_fresh.sh")" -eq 1 ]; then
    ok "the freshness gate still defaults to STRICT=1, so an unverifiable tree is RED unless a call site opts out in writing"
else
    bad "scripts/verify_vendor_fresh.sh no longer defaults VENDOR_FRESH_STRICT to 1. A lenient default is the exact false green #701 removed, and the cut would inherit it."
fi

if [ "$(grep -c 'GATE: DEGRADED' "${REPO_ROOT}/scripts/verify_vendor_fresh.sh")" -ge 1 ]; then
    ok "the opted-out path still prints DEGRADED, never GREEN"
else
    bad "scripts/verify_vendor_fresh.sh no longer prints 'GATE: DEGRADED' on the opted-out path. 'GREEN with N warnings' is the wording that made a warn read as a pass."
fi

# ===========================================================================
# ARM B: THE FOUR ROUTES AND THE REFUSAL, OVER SYNTHETIC GIT REPOS
# ===========================================================================
#
# Real git, real commits, the real gate. A mocked diff would not exercise the
# merge-base arithmetic, which is where enforce_ledger_write.sh's twin of this
# gate was wrong for weeks.

MANIFEST_BODY='[[tree]]
name             = "demo/alpha"
vendor_path      = "vendor/demo/alpha"
source_repo      = "$DEMO"
source_path      = "alpha"
pinned_sha       = "PINSHA"
divergence_patch = "vendor/divergences/demo_alpha.patch"
exclude          = ["tests/"]
verify           = "full"
note             = "a synthetic tree for tests/test_an_undescribed_vendor_divergence_is_red.sh"
'

mkfix() {   # mkfix <dir>
    local d="$1"
    rm -rf "$d"; mkdir -p "$d/vendor/demo/alpha" "$d/vendor/divergences"
    (
        cd "$d" || exit 1
        git init -q -b main .
        git config user.email t@example.invalid
        git config user.name  Test
        printf '%s' "${MANIFEST_BODY//PINSHA/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" \
            > vendor/VENDOR_MANIFEST.toml
        printf 'print("one")\n' > vendor/demo/alpha/mod.py
        printf 'a patch\n'      > vendor/divergences/demo_alpha.patch
        printf '# path\towning_repo\twhy_no_upstream\n' > vendor/VENDOR_ONLY.tsv
        git add -A
        git commit -q -m base
    ) || return 1
    return 0
}

run_gate() {  # run_gate <dir> -> prints rc, output to $WORK/last.out
    local rc
    python3 "$GATE" --repo "$1" --base main --head HEAD > "${WORK}/last.out" 2>&1
    rc=$?
    printf '%s' "$rc"
}

commit_on_branch() {  # commit_on_branch <dir> <branch> <msg>
    ( cd "$1" && git checkout -q -b "$2" && git add -A && git commit -q -m "$3" )
}

expect_gate() {  # expect_gate <label> <dir> <want-rc> <want-string>
    local label="$1" dir="$2" want_rc="$3" want_str="$4" rc
    rc="$(run_gate "$dir")"
    if [ "$rc" != "$want_rc" ]; then
        bad "${label}: exit ${rc}, expected ${want_rc}. $(grep -e '^GATE' -e '^  FAIL' "${WORK}/last.out" | head -2 | tr '\n' ' ')"
        return
    fi
    if [ "$(grep -c -F -- "$want_str" "${WORK}/last.out")" -lt 1 ]; then
        bad "${label}: exit ${want_rc} was right but the output never says '${want_str}', so the code could be right for the wrong reason."
        return
    fi
    ok "${label}: exit ${want_rc}, naming '${want_str}'"
}

# B0 THE CONTROL: a diff that touches no vendored content must be GREEN, or
# every red below could be the gate simply refusing everything.
D="${WORK}/b0"; mkfix "$D" || cannot_run "could not build fixture b0"
printf 'notes\n' > "$D/README.md"
commit_on_branch "$D" work "docs only"
expect_gate "B0 CONTROL a diff with no vendored content" "$D" 0 "nothing to describe"

# B1 THE DEFECT: a vendored file edited, nothing else.
D="${WORK}/b1"; mkfix "$D" || cannot_run "could not build fixture b1"
printf 'print("two")\n' > "$D/vendor/demo/alpha/mod.py"
commit_on_branch "$D" work "hand edit"
expect_gate "B1 a vendored file edited with no record" "$D" 1 "demo/alpha"

# B2 ROUTE (a): the divergence patch changed in the same diff.
D="${WORK}/b2"; mkfix "$D" || cannot_run "could not build fixture b2"
printf 'print("two")\n' > "$D/vendor/demo/alpha/mod.py"
printf 'a patch, regenerated\n' > "$D/vendor/divergences/demo_alpha.patch"
commit_on_branch "$D" work "edit plus patch"
expect_gate "B2 route (a) the divergence patch changed" "$D" 0 "divergence patch"

# B3 ROUTE (b): the pin moved, so this is a re-vendor.
D="${WORK}/b3"; mkfix "$D" || cannot_run "could not build fixture b3"
printf 'print("two")\n' > "$D/vendor/demo/alpha/mod.py"
sed -i.bak 's/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/' \
    "$D/vendor/VENDOR_MANIFEST.toml" && rm -f "$D/vendor/VENDOR_MANIFEST.toml.bak"
commit_on_branch "$D" work "re-vendor"
expect_gate "B3 route (b) pinned_sha moved" "$D" 0 "re-vendor"

# B4 ROUTE (c): an unrecorded_divergence record written in the same diff.
D="${WORK}/b4"; mkfix "$D" || cannot_run "could not build fixture b4"
printf 'print("two")\n' > "$D/vendor/demo/alpha/mod.py"
printf 'This file records the divergence in demo/alpha and why it could not be regenerated.\n' \
    > "$D/vendor/divergences/DEMO.UNRECORDED.md"
printf '  unrecorded_divergence = "vendor/divergences/DEMO.UNRECORDED.md"\n' \
    >> "$D/vendor/VENDOR_MANIFEST.toml"
commit_on_branch "$D" work "recorded by hand"
expect_gate "B4 route (c) an unrecorded_divergence record was written" "$D" 0 "unrecorded_divergence record"

# B5 ROUTE (c) MUST-MISS: the declaration points at a file that is not there.
# A pointer is not a record, and this is the cheapest way to fake one.
D="${WORK}/b5"; mkfix "$D" || cannot_run "could not build fixture b5"
printf 'print("two")\n' > "$D/vendor/demo/alpha/mod.py"
printf '  unrecorded_divergence = "vendor/divergences/NOT_THERE.md"\n' \
    >> "$D/vendor/VENDOR_MANIFEST.toml"
commit_on_branch "$D" work "dangling record"
expect_gate "B5 MUST-MISS a dangling unrecorded_divergence pointer" "$D" 1 "does not exist at head"

# B5b ROUTE (c) EXTENDED IN PLACE: the pointer VALUE does not move and the file
# it names is edited in the same diff. This is what the shared record's own
# header instructs later PRs to do, and the gate used to refuse it while naming
# none of that. A gate that rejects its own documented practice sends the
# reader to argue with it.
D="$(mkdir_repo)"
printf '  unrecorded_divergence = "vendor/divergences/DEMO.UNRECORDED.md"\n' \
    >> "$D/vendor/VENDOR_MANIFEST.toml"
mkdir -p "$D/vendor/divergences"
printf 'demo tree: first refusal recorded here.\n' > "$D/vendor/divergences/DEMO.UNRECORDED.md"
git -C "$D" add -A >/dev/null 2>&1
git -C "$D" commit -qm "base: pointer and record already present" >/dev/null 2>&1
printf 'x\n' >> "$D/vendor/demo/file.txt"
printf 'demo tree: SECOND refusal appended by this PR.\n' >> "$D/vendor/divergences/DEMO.UNRECORDED.md"
git -C "$D" add -A >/dev/null 2>&1
git -C "$D" commit -qm "head: extend the record in place" >/dev/null 2>&1
expect_gate "B5b route (c) a record EXTENDED IN PLACE is accepted" "$D" 0 "unrecorded_divergence record"

# B6 ROUTE (c) MUST-MISS: the record exists but never mentions this tree, so it
# is somebody else's divergence borrowed as cover.
D="${WORK}/b6"; mkfix "$D" || cannot_run "could not build fixture b6"
printf 'print("two")\n' > "$D/vendor/demo/alpha/mod.py"
printf 'This file is about an entirely different subject.\n' \
    > "$D/vendor/divergences/OTHER.UNRECORDED.md"
printf '  unrecorded_divergence = "vendor/divergences/OTHER.UNRECORDED.md"\n' \
    >> "$D/vendor/VENDOR_MANIFEST.toml"
commit_on_branch "$D" work "borrowed record"
expect_gate "B6 MUST-MISS a record that never names this tree" "$D" 1 "never mentions"

# B7 MUST-MISS: a prose edit to the manifest is NOT a description. This is the
# alternative design that was rejected, asserted so nobody re-adopts it by
# accident, and it is exactly the shape of the fb5c7bcf specimen in arm C.
D="${WORK}/b7"; mkfix "$D" || cannot_run "could not build fixture b7"
printf 'print("two")\n' > "$D/vendor/demo/alpha/mod.py"
sed -i.bak 's/^note .*/note             = "some new prose about the graft, captured in the patch"/' \
    "$D/vendor/VENDOR_MANIFEST.toml" && rm -f "$D/vendor/VENDOR_MANIFEST.toml.bak"
commit_on_branch "$D" work "prose only"
expect_gate "B7 MUST-MISS a prose note is not a description" "$D" 1 "no divergence patch change"

# B8 ROUTE (d): a vendor-only file. gen_patch strips vendor-only hunks, so
# demanding a patch change here would demand something the tooling refuses to
# produce, and a gate that asks the impossible gets routed around.
D="${WORK}/b8"; mkfix "$D" || cannot_run "could not build fixture b8"
printf 'demo/alpha/local_only.py\tDEMO\tno upstream exists for this file\n' \
    >> "$D/vendor/VENDOR_ONLY.tsv"
printf 'print("local")\n' > "$D/vendor/demo/alpha/local_only.py"
commit_on_branch "$D" work "vendor-only file"
expect_gate "B8 route (d) a declared vendor-only file" "$D" 0 "VENDOR_ONLY.tsv"

# B9 ROUTE (d) MUST-MISS: an UNDECLARED new file in the tree is still RED.
D="${WORK}/b9"; mkfix "$D" || cannot_run "could not build fixture b9"
printf 'print("local")\n' > "$D/vendor/demo/alpha/sneaked_in.py"
commit_on_branch "$D" work "new file, no row"
expect_gate "B9 MUST-MISS a new vendored file with no VENDOR_ONLY row" "$D" 1 "sneaked_in.py"

# ===========================================================================
# ARM C: THE TWO REAL MERGED SPECIMENS
# ===========================================================================
#
# These need real history. A shallow clone cannot answer, and saying so is the
# honest outcome: the arm reports CANNOT-RUN by name rather than quietly
# scoring nothing, because a ladder that silently lost its two best arms is
# green in the same way as one that ran them.
specimen() {  # specimen <label> <sha> <want-rc> <want-string>
    local label="$1" sha="$2" want_rc="$3" want_str="$4" rc
    if ! git -C "$REPO_ROOT" rev-parse --verify --quiet "${sha}^{commit}" >/dev/null 2>&1; then
        bad "${label}: CANNOT-RUN, ${sha} is not in this checkout. fetch-depth must be 0; the gate's two real specimens were not exercised."
        return
    fi
    python3 "$GATE" --repo "$REPO_ROOT" --base "${sha}^" --head "$sha" > "${WORK}/spec.out" 2>&1
    rc=$?
    if [ "$rc" != "$want_rc" ]; then
        bad "${label}: exit ${rc}, expected ${want_rc}. $(grep -e '^GATE' "${WORK}/spec.out" | head -1)"
        return
    fi
    if [ "$(grep -c -F -- "$want_str" "${WORK}/spec.out")" -lt 1 ]; then
        bad "${label}: exit ${want_rc} was right but the output never names '${want_str}'."
        return
    fi
    ok "${label}: exit ${want_rc}, naming '${want_str}'"
}

specimen "C1 #1956 (f2fe7eea) reds on the tree its own manifest calls undescribed" \
         f2fe7eea 1 "cm048_pipeline"
specimen "C2 #1974 (fb5c7bcf) reds on a hand edit recorded only as prose" \
         fb5c7bcf 1 "cm041/identity_resolver"

# C3 THE CONTROL FOR ARM C. If the gate simply reds on every historical commit,
# C1 and C2 prove nothing. The SAME specimen must report its other two trees OK,
# and #1956 is the ideal control because it carries both states at once.
if git -C "$REPO_ROOT" rev-parse --verify --quiet 'f2fe7eea^{commit}' >/dev/null 2>&1; then
    python3 "$GATE" --repo "$REPO_ROOT" --base f2fe7eea^ --head f2fe7eea > "${WORK}/spec.out" 2>&1
    n_ok="$(grep -c '^  OK    ostler_security' "${WORK}/spec.out")"
    n_ok2="$(grep -c '^  OK    cm041/assistant_api' "${WORK}/spec.out")"
    if [ "${n_ok:-0}" -ge 1 ] && [ "${n_ok2:-0}" -ge 1 ]; then
        ok "C3 CONTROL: the same run reports ostler_security and cm041/assistant_api OK, so the gate discriminates rather than refusing everything"
    else
        bad "C3 CONTROL FAILED: the described trees in that commit were not reported OK (ostler_security=${n_ok:-0}, cm041/assistant_api=${n_ok2:-0}). A gate that reds on everything is not evidence about anything."
    fi
else
    bad "C3 CONTROL: CANNOT-RUN, f2fe7eea is not in this checkout."
fi

# ===========================================================================
# ARM D: CANNOT-RUN IS A THIRD STATE
# ===========================================================================
d_expect() {  # d_expect <label> <want-string> <args...>
    local label="$1" want="$2"; shift 2
    local rc
    python3 "$GATE" "$@" > "${WORK}/last.out" 2>&1
    rc=$?
    if [ "$rc" != "2" ]; then
        bad "${label}: exit ${rc}, expected 2. RED and 'I could not look' sharing a code is how one gets acted on as the other."
        return
    fi
    if [ "$(grep -c -F -- "$want" "${WORK}/last.out")" -lt 1 ]; then
        bad "${label}: exit 2 was right but the reason never says '${want}'."
        return
    fi
    ok "${label}: exit 2, naming '${want}'"
}

D="${WORK}/d1"; mkfix "$D" || cannot_run "could not build fixture d1"
d_expect "D1 a ref that is not in the checkout" "ref not present" \
         --repo "$D" --base main --head deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

# D2 a manifest that declares the same tree twice. No count comparison can see
# this: every reader in the repo resolves a name to the first block, so the
# second is adjudicated zero times while still looking examined.
D="${WORK}/d2"; mkfix "$D" || cannot_run "could not build fixture d2"
printf '%s' "${MANIFEST_BODY//PINSHA/cccccccccccccccccccccccccccccccccccccccc}" \
    >> "$D/vendor/VENDOR_MANIFEST.toml"
printf 'print("two")\n' > "$D/vendor/demo/alpha/mod.py"
commit_on_branch "$D" work "duplicate tree name"
d_expect "D2 a duplicate tree name in the manifest" "twice" --repo "$D" --base main --head HEAD

# D3 a manifest with no trees at all. Every set below starts empty, so a GREEN
# here would have examined nothing on the gate that decides whether unrecorded
# vendored edits ship.
D="${WORK}/d3"; mkfix "$D" || cannot_run "could not build fixture d3"
printf '# no trees declared\n' > "$D/vendor/VENDOR_MANIFEST.toml"
printf 'print("two")\n' > "$D/vendor/demo/alpha/mod.py"
commit_on_branch "$D" work "empty manifest"
d_expect "D3 a manifest declaring zero trees" "0 trees" --repo "$D" --base main --head HEAD

# D4 not a git repository.
mkdir -p "${WORK}/d4"
d_expect "D4 a directory that is not a git repository" "not a git repository" \
         --repo "${WORK}/d4" --base main --head HEAD

# ===========================================================================
echo
echo "arms scored: ${arms}   failed: ${fails}"
if [ "$fails" -gt 0 ]; then
    echo "RESULT: FAIL, ${fails} of ${arms} arms"
    exit 1
fi
if [ "$arms" -lt 18 ]; then
    echo "RESULT: CANNOT-RUN, only ${arms} arms were scored, expected at least 18."
    exit 2
fi
echo "RESULT: PASS, ${arms} of ${arms} arms"
exit 0
