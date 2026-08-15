#!/usr/bin/env bash
# test_vendor_fresh_gate.sh -- self-test for the vendor-freshness gate.
# ===================================================================
#
# Proves the gate actually catches drift (the old guard was blind):
#   1. CLEAN  : an unmodified, correctly-pinned tree PASSES (GREEN).
#   2. ROT    : mutating a vendored file (without a matching source change)
#               turns the gate RED, naming the tree.
#   3. STALE  : "source advanced past pinned_sha without a graft" turns the
#               gate RED, naming the ungrafted commit.
#   4. HELD   : a delta EVERY commit of which is in hold_ack_shas, with a
#               reason and shipping_bugfixes_grafted, is GREEN and says HELD.
#   5. PARTIAL: the negative control for 4, and the one that matters. Ack one
#               of two delta commits; the gate must go RED naming ONLY the
#               unacknowledged one. A hold_ack implementation that merely
#               checks "is the field non-empty" passes 4 and fails 5, which is
#               precisely why 4 alone would not have been proof.
#   6. UNSAID : hold_ack without a reason, and hold_ack without the grafted
#               assertion, are each RED. An unexplained hold is an exemption
#               nobody can audit.
#   7. REF    : the advance arm judges the pin against origin/main, NOT the
#               source checkout's incidental HEAD, and SAYS which ref it used.
#   8. UNVERIFIABLE, UNACKNOWLEDGED : a tree whose source repo is not on disk
#               is RED, and is counted in the UNKNOWN column.
#   9. UNVERIFIABLE, ACKNOWLEDGED : the same tree with unverifiable_ack +
#               reason + owner is counted in the acknowledged column, exits 0,
#               and the verdict does NOT read as a plain GREEN.
#  10. ACK CANNOT LAUNDER DRIFT : a tree that is BOTH acked and rotted still
#               FAILS. This is the one that matters. An acknowledgement excuses
#               "we could not look"; it must never excuse "we looked and it was
#               wrong", or it becomes the blanket ignore switch that the
#               fail-closed default was introduced to remove.
#  11. INCOMPLETE ACK : unverifiable_ack = true with no reason, or no owner, is
#               RED. An exemption nobody signed is how a temporary gap becomes
#               permanent.
#
# Scenarios 8-11 are the negative-case tests for the acknowledgement mechanism,
# and they mirror 4-6: both mechanisms let a tree be less than fully verified,
# so both have to prove they still go red on the case they are NOT meant to
# excuse. A gate that only compiles is not a gate.
#
# HERMETIC: every scenario builds its own throwaway synthetic source git repo
# + vendored copy + single-entry manifest. It depends on NOTHING outside this
# checkout, so it runs identically locally and on a bare CI runner (where the
# real upstream source repos are not present). Nothing real is mutated.
#
# British English; " -- " not em-dashes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export VENDOR_OP_TIMEOUT="${VENDOR_OP_TIMEOUT:-30}"

PASS=0
FAIL=0
note() { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  PASS: %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$*" >&2; }

# Build a hermetic fixture under $1:
#   $1/synthetic-source : a git repo with pkg/mod.py committed (returns SHA)
#   $1/scripts/*        : the real gate scripts
#   $1/vendor/synthtree : a vendored copy identical to source@SHA
#   $1/vendor/VENDOR_MANIFEST.toml : a single [[tree]] pinned to SHA
# Prints the pinned SHA on stdout.
make_fixture() {
    local root="$1"
    local src="$root/synthetic-source"
    mkdir -p "$src/pkg"
    (
        cd "$src"
        git init --quiet
        git config user.email selftest@example.com
        git config user.name "vendor self-test"
        printf 'def hello():\n    return "v1"\n' > pkg/mod.py
        git add pkg/mod.py
        git commit --quiet -m "v1: initial"
    )
    local sha
    sha="$(git -C "$src" rev-parse HEAD)"

    mkdir -p "$root/scripts" "$root/vendor/synthtree/pkg" "$root/vendor/divergences"
    cp "$REPO_ROOT"/scripts/_vendor_lib.sh "$REPO_ROOT"/scripts/verify_vendor_fresh.sh \
       "$REPO_ROOT"/scripts/sync_vendor.sh "$root/scripts/"
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

run_gate() {
    # $1 = repo root to run in; prints output, returns gate exit code.
    ( cd "$1" && bash scripts/verify_vendor_fresh.sh 2>&1 )
}

# ---------------------------------------------------------------------------
note "=== Scenario 1: CLEAN tree PASSES ==="
TMP1="$(mktemp -d)"
make_fixture "$TMP1" >/dev/null
out1="$(run_gate "$TMP1")"; rc1=$?
if [ "$rc1" -eq 0 ] && printf '%s' "$out1" | grep -q "GATE: GREEN" \
    && printf '%s' "$out1" | grep -qE "OK    synthtree"; then
    ok "clean tree -> GREEN (exit 0)"
else
    bad "clean tree did not go GREEN (exit $rc1)"; printf '%s\n' "$out1" | tail -5
fi
rm -rf "$TMP1"

# ---------------------------------------------------------------------------
note "=== Scenario 2: ROT (mutated vendored file) -> RED, names the tree ==="
TMP2="$(mktemp -d)"
make_fixture "$TMP2" >/dev/null
# Mutate the vendored file WITHOUT any matching source change.
printf '\n# DELIBERATE ROT injected by self-test -- not in source\n' >> "$TMP2/vendor/synthtree/pkg/mod.py"
out2="$(run_gate "$TMP2")"; rc2=$?
if [ "$rc2" -ne 0 ] \
    && printf '%s' "$out2" | grep -q "GATE: RED" \
    && printf '%s' "$out2" | grep -qE "FAIL  synthtree"; then
    ok "rotted vendored file -> RED, named 'synthtree' (exit $rc2)"
else
    bad "rot was NOT caught (exit $rc2) -- the gate is blind!"
    printf '%s\n' "$out2" | grep -E "GATE|FAIL|synthtree" | head -8
fi
rm -rf "$TMP2"

# ---------------------------------------------------------------------------
note "=== Scenario 3: STALE (source advanced past pin) -> RED, names commits ==="
# Build the hermetic fixture, confirm GREEN at the pin, then advance the
# SOURCE past the pin WITHOUT re-grafting the vendor. The gate must flag the
# ungrafted commit.
TMP3="$(mktemp -d)"
make_fixture "$TMP3" >/dev/null
SRC3="$TMP3/synthetic-source"

# Sanity: at the pin, the gate is GREEN.
out3a="$(run_gate "$TMP3")"; rc3a=$?
if [ "$rc3a" -eq 0 ] && printf '%s' "$out3a" | grep -q "GATE: GREEN"; then
    ok "synthetic tree at pin -> GREEN"
else
    bad "synthetic tree at pin did not go GREEN (exit $rc3a)"
    printf '%s\n' "$out3a" | tail -4
fi

# Now advance the SOURCE past the pin without re-grafting the vendor.
(
    cd "$SRC3"
    printf 'def hello():\n    return "v2 -- fixed but ungrafted"\n' > pkg/mod.py
    git add pkg/mod.py
    git commit --quiet -m "fix: simulated upstream fix (#SELFTEST) not grafted"
)
out3b="$(run_gate "$TMP3")"; rc3b=$?
if [ "$rc3b" -ne 0 ] \
    && printf '%s' "$out3b" | grep -q "GATE: RED" \
    && printf '%s' "$out3b" | grep -qi "UNGRAFTED" \
    && printf '%s' "$out3b" | grep -qE "FAIL  synthtree"; then
    ok "source advanced past pin -> RED, flagged ungrafted commit on 'synthtree' (exit $rc3b)"
else
    bad "stale-source was NOT caught (exit $rc3b)"
    printf '%s\n' "$out3b" | grep -E "GATE|FAIL|UNGRAFTED|synthtree" | head -8
fi
rm -rf "$TMP3"

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Helpers for the hold_ack scenarios.

# Append hold_ack fields to the fixture's single [[tree]] table.
# $1 = fixture root, $2 = shas, $3 = reason, $4 = grafted ("true"/"" to omit)
set_hold_ack() {
    local root="$1" shas="$2" reason="$3" grafted="${4:-}"
    {
        printf 'hold_ack_shas            = "%s"\n' "$shas"
        [ -n "$reason" ] && printf 'hold_ack_reason          = "%s"\n' "$reason"
        [ -n "$grafted" ] && printf 'shipping_bugfixes_grafted = %s\n' "$grafted"
    } >> "$root/vendor/VENDOR_MANIFEST.toml"
}

# Add one commit to the fixture source; prints its full SHA.
advance_source() {
    local src="$1" body="$2" msg="$3"
    (
        cd "$src"
        printf 'def hello():\n    return "%s"\n' "$body" > pkg/mod.py
        git add pkg/mod.py
        git commit --quiet -m "$msg"
    )
    git -C "$src" rev-parse HEAD
}

# ---------------------------------------------------------------------------
note "=== Scenario 4: HELD (whole delta acknowledged) -> GREEN, says HELD ==="
TMP4="$(mktemp -d)"
make_fixture "$TMP4" >/dev/null
SHA4="$(advance_source "$TMP4/synthetic-source" "v2 -- held on purpose" "fix: upstream change the vendor deliberately holds")"
# The vendored copy stays at v1. That is what a hold IS: the pin does not move,
# and the manifest carries the record of why.
set_hold_ack "$TMP4" "$SHA4" "self-test: held deliberately, nothing un-grafted" "true"
out4="$(run_gate "$TMP4")"; rc4=$?
if [ "$rc4" -eq 0 ] \
    && printf '%s' "$out4" | grep -q "GATE: GREEN" \
    && printf '%s' "$out4" | grep -q "HELD by hold_ack"; then
    ok "fully-acknowledged delta -> GREEN, reported as HELD (exit $rc4)"
else
    bad "acknowledged delta did not go GREEN (exit $rc4) -- hold_ack is not being honoured"
    printf '%s\n' "$out4" | grep -E "GATE|OK|FAIL|synthtree" | head -8
fi
rm -rf "$TMP4"

# ---------------------------------------------------------------------------
note "=== Scenario 5: PARTIAL ack -> RED, naming ONLY the unacknowledged commit ==="
# THE control for scenario 4. An implementation that treats a non-empty
# hold_ack_shas as a blanket pass is GREEN here, and would ship a genuinely
# un-grafted upstream fix behind a field that mentions some other commit.
TMP5="$(mktemp -d)"
make_fixture "$TMP5" >/dev/null
SRC5="$TMP5/synthetic-source"
ACKED5="$(advance_source "$SRC5" "v2 -- acknowledged" "fix: first upstream change (ACKNOWLEDGED)")"
UNACKED5="$(advance_source "$SRC5" "v3 -- NOT acknowledged" "fix: second upstream change (NOT acknowledged)")"
set_hold_ack "$TMP5" "$ACKED5" "self-test: only the first commit is acknowledged" "true"
out5="$(run_gate "$TMP5")"; rc5=$?
if [ "$rc5" -ne 0 ] \
    && printf '%s' "$out5" | grep -q "GATE: RED" \
    && printf '%s' "$out5" | grep -q "NOT in hold_ack_shas" \
    && printf '%s' "$out5" | grep -q "${UNACKED5:0:7}" \
    && ! printf '%s' "$out5" | grep -q "${ACKED5:0:7}"; then
    ok "partial ack -> RED naming only the un-acknowledged commit (exit $rc5)"
else
    bad "partial ack was NOT caught precisely (exit $rc5)"
    printf '%s\n' "$out5" | grep -E "GATE|FAIL|hold_ack|${UNACKED5:0:7}|${ACKED5:0:7}" | head -8
fi
rm -rf "$TMP5"

# ---------------------------------------------------------------------------
note "=== Scenario 6: hold_ack without a reason / without the grafted assert -> RED ==="
TMP6="$(mktemp -d)"
make_fixture "$TMP6" >/dev/null
SHA6="$(advance_source "$TMP6/synthetic-source" "v2" "fix: upstream change")"
set_hold_ack "$TMP6" "$SHA6" "" "true"          # reason omitted
out6a="$(run_gate "$TMP6")"; rc6a=$?
if [ "$rc6a" -ne 0 ] && printf '%s' "$out6a" | grep -q "hold_ack_reason is empty"; then
    ok "hold_ack with no reason -> RED"
else
    bad "hold_ack with no reason was accepted (exit $rc6a) -- an unauditable exemption"
    printf '%s\n' "$out6a" | grep -E "GATE|FAIL" | head -4
fi
rm -rf "$TMP6"

TMP6B="$(mktemp -d)"
make_fixture "$TMP6B" >/dev/null
SHA6B="$(advance_source "$TMP6B/synthetic-source" "v2" "fix: upstream change")"
set_hold_ack "$TMP6B" "$SHA6B" "self-test: reason present, assertion missing" ""   # grafted omitted
out6b="$(run_gate "$TMP6B")"; rc6b=$?
if [ "$rc6b" -ne 0 ] && printf '%s' "$out6b" | grep -q "shipping_bugfixes_grafted is not true"; then
    ok "hold_ack without shipping_bugfixes_grafted -> RED"
else
    bad "hold_ack without the grafted assertion was accepted (exit $rc6b)"
    printf '%s\n' "$out6b" | grep -E "GATE|FAIL" | head -4
fi
rm -rf "$TMP6B"

# ---------------------------------------------------------------------------
note "=== Scenario 7: the advance arm judges against origin/main, not HEAD ==="
# Before this, `unshipped_commits` ran `git log ${sha}..HEAD`, so the verdict
# depended on which branch somebody's clone was parked on. Here the source is
# advanced past the pin on HEAD while origin/main is left AT the pin. Judged
# against HEAD the tree is stale; against origin/main it is fresh. The gate must
# use origin/main, must SAY so, and must report the checkout's divergence rather
# than let it silently change the answer.
TMP7="$(mktemp -d)"
PIN7="$(make_fixture "$TMP7")"
SRC7="$TMP7/synthetic-source"
git -C "$SRC7" update-ref refs/remotes/origin/main "$PIN7"
advance_source "$SRC7" "v2 -- on HEAD only, not on origin/main" "feat: unmerged work in progress" >/dev/null
out7="$(run_gate "$TMP7")"; rc7=$?
if [ "$rc7" -eq 0 ] \
    && printf '%s' "$out7" | grep -q "GATE: GREEN" \
    && printf '%s' "$out7" | grep -q "\[vs origin/main\]" \
    && printf '%s' "$out7" | grep -q "1 ahead / 0 behind origin/main"; then
    ok "advance arm used origin/main, named the ref, and reported checkout drift"
else
    bad "advance arm did not resolve the comparison ref explicitly (exit $rc7)"
    printf '%s\n' "$out7" | grep -E "GATE|OK|FAIL|note|synthtree" | head -8
fi
rm -rf "$TMP7"

# ---------------------------------------------------------------------------
# Acknowledged-unverifiable. Scenarios 8-11.
#
# Rewrite the single-tree manifest of an existing fixture so a scenario can
# change source_repo and/or append acknowledgement fields. Everything else about
# the fixture (the synthetic source repo, the vendored copy) is untouched, so
# each scenario differs from the CLEAN baseline in exactly one way.
remanifest() {
    local root="$1" srcrepo="$2" extra="$3" sha
    sha="$(git -C "$root/synthetic-source" rev-parse HEAD)"
    {
        printf '[[tree]]\n'
        printf 'name             = "synthtree"\n'
        printf 'vendor_path      = "vendor/synthtree"\n'
        printf 'source_repo      = "%s"\n' "$srcrepo"
        printf 'source_path      = "."\n'
        printf 'pinned_sha       = "%s"\n' "$sha"
        printf 'divergence_patch = ""\n'
        printf 'exclude          = ["__pycache__/"]\n'
        printf 'verify           = "full"\n'
        if [ -n "$extra" ]; then printf '%s\n' "$extra"; fi
    } > "$root/vendor/VENDOR_MANIFEST.toml"
}

ACK_FULL=$'unverifiable_ack = true\nunverifiable_ack_reason = "synthetic: the source repo is deliberately absent in this fixture"\nunverifiable_ack_owner  = "vendor self-test"'

note "=== Scenario 8: UNVERIFIABLE + no ack -> RED, counted as UNKNOWN ==="
TMP8="$(mktemp -d)"
make_fixture "$TMP8" >/dev/null
remanifest "$TMP8" "$TMP8/there-is-no-repo-here" ""
out8="$(run_gate "$TMP8")"; rc8=$?
if [ "$rc8" -ne 0 ] \
    && printf '%s' "$out8" | grep -q "GATE: RED" \
    && printf '%s' "$out8" | grep -qE "^WARN  synthtree" \
    && printf '%s' "$out8" | grep -qE "1 unverifiable \(UNKNOWN\)"; then
    ok "unverifiable + unacknowledged -> RED and counted UNKNOWN (exit $rc8)"
else
    bad "an unacknowledged unverifiable tree did NOT go RED as UNKNOWN (exit $rc8)"
    printf '%s\n' "$out8" | grep -E "GATE|WARN|ACK|vendor-freshness" | head -6
fi
rm -rf "$TMP8"

note "=== Scenario 9: UNVERIFIABLE + complete ack -> counted ACKNOWLEDGED, not a plain GREEN ==="
TMP9="$(mktemp -d)"
make_fixture "$TMP9" >/dev/null
remanifest "$TMP9" "$TMP9/there-is-no-repo-here" "$ACK_FULL"
out9="$(run_gate "$TMP9")"; rc9=$?
if [ "$rc9" -eq 0 ] \
    && printf '%s' "$out9" | grep -qE "^ACK   synthtree" \
    && printf '%s' "$out9" | grep -qE "1 acknowledged-unverifiable" \
    && printf '%s' "$out9" | grep -q "GATE: GREEN WITH 1 ACKNOWLEDGED-UNVERIFIABLE"; then
    ok "acknowledged unverifiable -> counted separately, exit 0"
else
    bad "a complete acknowledgement was not honoured/counted (exit $rc9)"
    printf '%s\n' "$out9" | grep -E "GATE|WARN|ACK|vendor-freshness" | head -6
fi
# ...and the verdict must NOT be the plain GREEN line. This is the assertion
# that stops the ack becoming the next "GATE: GREEN with N warning(s)".
if printf '%s' "$out9" | grep -q "GATE: GREEN -- every vendored tree"; then
    bad "the verdict read as a PLAIN GREEN while a tree was unverified -- that is the old hole"
else
    ok "the verdict does not read as a plain GREEN while an ack is live"
fi
rm -rf "$TMP9"

note "=== Scenario 10: ack CANNOT launder real drift -> still RED ==="
# The one that matters. An ack excuses "we could not look". It must never
# excuse "we looked and it was wrong". Source is present and healthy here, so
# the gate reaches a real content verdict; the ack must not touch it.
TMP10="$(mktemp -d)"
make_fixture "$TMP10" >/dev/null
remanifest "$TMP10" "$TMP10/synthetic-source" "$ACK_FULL"
printf '\n# DELIBERATE ROT injected by self-test -- not in source\n' >> "$TMP10/vendor/synthtree/pkg/mod.py"
out10="$(run_gate "$TMP10")"; rc10=$?
if [ "$rc10" -ne 0 ] \
    && printf '%s' "$out10" | grep -q "GATE: RED" \
    && printf '%s' "$out10" | grep -qE "^FAIL  synthtree"; then
    ok "acked-but-rotted tree still FAILS -- an ack cannot launder drift (exit $rc10)"
else
    bad "an ack SILENCED real drift -- it has become the blanket ignore switch (exit $rc10)"
    printf '%s\n' "$out10" | grep -E "GATE|FAIL|ACK|vendor-freshness" | head -6
fi
rm -rf "$TMP10"

note "=== Scenario 11: ack without an owner -> RED (reason AND owner are required) ==="
TMP11="$(mktemp -d)"
make_fixture "$TMP11" >/dev/null
remanifest "$TMP11" "$TMP11/there-is-no-repo-here" \
    $'unverifiable_ack = true\nunverifiable_ack_reason = "synthetic: a reason with nobody\'s name on it"'
out11="$(run_gate "$TMP11")"; rc11=$?
if [ "$rc11" -ne 0 ] \
    && printf '%s' "$out11" | grep -q "GATE: RED" \
    && printf '%s' "$out11" | grep -qE "^FAIL  synthtree" \
    && printf '%s' "$out11" | grep -qi "INCOMPLETE"; then
    ok "ack missing an owner -> RED, named as incomplete (exit $rc11)"
else
    bad "an incomplete ack was honoured -- an unsigned exemption became permanent (exit $rc11)"
    printf '%s\n' "$out11" | grep -E "GATE|FAIL|ACK|vendor-freshness" | head -6
fi
rm -rf "$TMP11"

# ---------------------------------------------------------------------------
note ""
note "self-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "vendor-freshness gate self-test: PASS"
