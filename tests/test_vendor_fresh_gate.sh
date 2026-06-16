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
note ""
note "self-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "vendor-freshness gate self-test: PASS"
