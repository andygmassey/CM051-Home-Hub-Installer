#!/usr/bin/env bash
#
# scripts/tests/test_patch_writers_refuse_operator_pii.sh
#
# BOTH DIVERGENCE-PATCH WRITERS MUST REFUSE TO WRITE OPERATOR PII, '-' LINES
# INCLUDED.
#
# WHY. The 2026-08-12 scrub (aaddd392 / #592) removed operator-PII values from
# vendored trees, and the patch writers then recorded every removed value on the
# MINUS side of vendor/divergences/*.patch: a divergence patch's '-' lines are
# the SOURCE content, and a scrub is exactly a divergence whose source still
# holds the value. CM051 is PUBLIC. Neither writer consulted the operator
# inventory; regenerate_divergence_patch.sh scanned numeric shapes only, which
# cannot see a name, and sync_vendor.sh scanned nothing.
#
# FIXTURE. A synthetic source repo whose module carries a TERM, and a vendored
# copy with the term scrubbed, so the patch either writer computes carries the
# term on a '-' line only. The term is COMPOSED AT RUNTIME and never appears as
# a literal here. A SYNTHETIC inventory listing it lives in a temporary HOME;
# the real inventory is never read, because HOME is overridden for every
# writer invocation.
#
#   A  regenerate --write, term in inventory       REFUSED rc1, nothing written
#   B  sync_vendor --regen-patch, term in inv.     REFUSED rc1, nothing written
#   C  sync_vendor full sync, term in inventory    REFUSED rc1, tree rolled back,
#                                                  pin and patch untouched
#   D  the same three runs, inventory WITHOUT the  WRITE (the clean control: the
#      term (an unrelated synthetic entry)         check does not refuse everything)
#   E  no inventory at all                         CANNOT-RUN rc2, nothing written
#   +  no writer output ever contains the term
#
# On origin/main before the fix, A, B and C WRITE the patch (rc 0) and E writes
# too: that is the defect. D passes on both, which is what makes it a control.
#
# Exit: 0 pass, 1 fail, 2 CANNOT-RUN (never a pass).
# British English; " -- " not em-dashes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
checks=0
pass() { checks=$((checks + 1)); printf '  PASS  %s\n' "$1"; }
fail() { checks=$((checks + 1)); printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

command -v git >/dev/null 2>&1 || { echo "CANNOT RUN: git unavailable" >&2; exit 2; }
command -v rg  >/dev/null 2>&1 || { echo "CANNOT RUN: ripgrep (rg) unavailable; the operator-PII scan cannot run, and that is not a pass" >&2; exit 2; }
for f in scripts/_vendor_lib.sh scripts/regenerate_divergence_patch.sh scripts/sync_vendor.sh \
         scripts/verify_no_symbol_regression.sh .githooks/pii_patterns.sh \
         .github/scripts/operator-pii-scan.sh; do
    [ -f "$REPO_ROOT/$f" ] || { echo "CANNOT RUN: $f missing" >&2; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Composed, fictional, name-shaped. Never written as one literal.
TERM_HIT="$(printf '%s%s%s' 'Qz' 'vrn' 'dal')"
TERM_OTHER="$(printf '%s%s%s' 'Xq' 'plo' 'tty')"
# Eight lines between the scrubbed line and the line v2 changes, so the v1
# scrub patch's hunk context does not overlap the upstream change and the
# full sync reaches the patch writer instead of stopping at "did not apply".
FILLER="$(printf '# filler line %s\n' 1 2 3 4 5 6 7 8)
"

# make_home <dir> <term|"">  : a temporary HOME holding a synthetic inventory.
# extract_array needs MULTI-LINE arrays (see test_operator_pii_scan_sees_all_text_kinds.sh).
make_home() {
    mkdir -p "$1"
    [ -n "$2" ] || return 0
    printf '[family_names]\nnames = [\n    "%s",\n]\n' "$2" > "$1/.ostler-operator-pii.toml"
}

# make_fixture <root> : source v1 carries the term; the vendored copy has it
# scrubbed. Prints the pinned sha.
make_fixture() {
    local root="$1" src="$1/synthetic-source"
    mkdir -p "$src/pkg"
    (
        cd "$src"
        git init --quiet
        git config user.email selftest@example.com
        git config user.name "patch-writer pii self-test"
        printf 'def owner():\n    return "%s"\n\n%sdef hello():\n    return "v1"\n' "$TERM_HIT" "$FILLER" > pkg/mod.py
        git add pkg/mod.py
        git commit --quiet -m "v1"
    )
    local sha; sha="$(git -C "$src" rev-parse HEAD)"
    mkdir -p "$root/scripts" "$root/vendor/synthtree/pkg" "$root/vendor/divergences" \
             "$root/.githooks" "$root/.github/scripts"
    cp "$REPO_ROOT/scripts/_vendor_lib.sh" "$REPO_ROOT/scripts/regenerate_divergence_patch.sh" \
       "$REPO_ROOT/scripts/sync_vendor.sh" "$REPO_ROOT/scripts/verify_no_symbol_regression.sh" \
       "$root/scripts/"
    cp "$REPO_ROOT/.githooks/pii_patterns.sh" "$root/.githooks/"
    cp "$REPO_ROOT/.github/scripts/operator-pii-scan.sh" "$root/.github/scripts/"
    printf 'def owner():\n    return "REDACTED"\n\n%sdef hello():\n    return "v1"\n' "$FILLER" > "$root/vendor/synthtree/pkg/mod.py"
    cat > "$root/vendor/VENDOR_MANIFEST.toml" <<EOF
[[tree]]
name             = "synthtree"
vendor_path      = "vendor/synthtree"
source_repo      = "$src"
source_path      = "."
pinned_sha       = "$sha"
divergence_patch = "vendor/divergences/synthtree.patch"
exclude          = ["__pycache__/"]
verify           = "full"
EOF
    printf '%s\n' "$sha"
}

# For C and D3: record the scrub patch at v1 the way a past run would have
# (regenerate under an inventory that does not list the term), then advance
# the source to v2 so a full sync has work to do. Prints the v2 sha.
prepare_full_sync() {
    local root="$1" src="$1/synthetic-source"
    ( cd "$root" && HOME="$H_CLEAN" VENDOR_PATCH_REGEN_CONFIRM=synthtree \
        bash scripts/regenerate_divergence_patch.sh synthtree --write >/dev/null 2>&1 ) || return 1
    [ -s "$root/vendor/divergences/synthtree.patch" ] || return 1
    (
        cd "$src"
        printf 'def owner():\n    return "%s"\n\n%sdef hello():\n    return "v2"\n' "$TERM_HIT" "$FILLER" > pkg/mod.py
        git commit --quiet -am "v2"
    )
    git -C "$src" rev-parse HEAD
}

# The pin VALUE, not the line: set_manifest_field rewrites the line's
# indentation when it restores a pin, so a byte compare reads a restored pin as
# moved.
pin_of() { sed -n 's/^[[:space:]]*pinned_sha[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$1/vendor/VENDOR_MANIFEST.toml"; }
vhash() { ( cd "$1/vendor/synthtree" && find . -type f | sort | xargs shasum -a 256 | shasum -a 256 ); }
fhash() { [ -f "$1" ] && shasum -a 256 < "$1" || echo absent; }
leak_check() { # label output
    if printf '%s' "$2" | grep -qF "$TERM_HIT"; then fail "$1: OUTPUT PRINTED THE TERM"; else pass "$1: output carries counts only, not the term"; fi
}

run_regen() { # root home
    ( cd "$1" && HOME="$2" VENDOR_PATCH_REGEN_CONFIRM=synthtree bash scripts/regenerate_divergence_patch.sh synthtree --write 2>&1 )
}
run_sync_regen() { ( cd "$1" && HOME="$2" bash scripts/sync_vendor.sh synthtree --regen-patch 2>&1 ); }
run_sync_full()  { ( cd "$1" && HOME="$3" bash scripts/sync_vendor.sh synthtree --to-sha "$2" 2>&1 ); }

# The probe must be able to see the term at all, or every leak check is blind.
printf 'x %s y' "$TERM_HIT" | grep -qF "$TERM_HIT" || { echo "CANNOT RUN: leak probe cannot match its own term" >&2; exit 2; }

echo "patch writers: refuse operator PII, '-' lines included"

H_HIT="$WORK/home-hit";     make_home "$H_HIT" "$TERM_HIT"
H_CLEAN="$WORK/home-clean"; make_home "$H_CLEAN" "$TERM_OTHER"
H_NONE="$WORK/home-none";   make_home "$H_NONE" ""

# Precondition: the computed patch carries the term on a '-' line and nowhere else.
RP="$WORK/probe"; mkdir -p "$RP"; make_fixture "$RP" >/dev/null
out="$(run_regen "$RP" "$H_CLEAN")"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$RP/vendor/divergences/synthtree.patch" ] \
   && [ "$(grep -c "^-.*$TERM_HIT" "$RP/vendor/divergences/synthtree.patch")" -eq 1 ] \
   && [ "$(grep -c "^+.*$TERM_HIT" "$RP/vendor/divergences/synthtree.patch")" -eq 0 ]; then
    pass "precondition + D1: clean inventory, regenerate WRITES; the term sits on 1 '-' line, 0 '+' lines"
else
    fail "precondition + D1: rc=$rc, the fixture does not put the term on the minus side only"
    printf '%s\n' "$out" | grep -vF "$TERM_HIT" | tail -5 | sed 's/^/        /'
fi

# --- A: regenerate refuses ---------------------------------------------------
RA="$WORK/a"; mkdir -p "$RA"; make_fixture "$RA" >/dev/null
VA="$(vhash "$RA")"
out="$(run_regen "$RA" "$H_HIT")"; rc=$?
[ "$rc" -eq 1 ] && pass "A: regenerate --write REFUSED (rc=1)" || fail "A: regenerate --write rc=$rc, expected 1 (refusal)"
grep -q "on '-' lines: 1" <<< "$out" && pass "A: refusal counts the hit on the '-' line" || fail "A: refusal did not report 1 '-' line hit"
[ -f "$RA/vendor/divergences/synthtree.patch" ] && fail "A: A PATCH WAS WRITTEN" || pass "A: no patch written"
[ "$(vhash "$RA")" = "$VA" ] && pass "A: vendored tree untouched" || fail "A: VENDORED TREE CHANGED"
leak_check "A" "$out"

# --- B: sync_vendor --regen-patch refuses ------------------------------------
RB="$WORK/b"; mkdir -p "$RB"; make_fixture "$RB" >/dev/null
MB="$(fhash "$RB/vendor/VENDOR_MANIFEST.toml")"
out="$(run_sync_regen "$RB" "$H_HIT")"; rc=$?
[ "$rc" -eq 1 ] && pass "B: sync_vendor --regen-patch REFUSED (rc=1)" || fail "B: sync_vendor --regen-patch rc=$rc, expected 1"
[ -f "$RB/vendor/divergences/synthtree.patch" ] && fail "B: A PATCH WAS WRITTEN" || pass "B: no patch written"
[ "$(fhash "$RB/vendor/VENDOR_MANIFEST.toml")" = "$MB" ] && pass "B: manifest byte-identical" || fail "B: MANIFEST CHANGED"
leak_check "B" "$out"

# --- C: sync_vendor full sync refuses and rolls back --------------------------
RC="$WORK/c"; mkdir -p "$RC"; make_fixture "$RC" >/dev/null
SHA2="$(prepare_full_sync "$RC")" || { echo "CANNOT RUN: could not record the v1 scrub patch for C" >&2; exit 2; }
VC="$(vhash "$RC")"; PC="$(fhash "$RC/vendor/divergences/synthtree.patch")"; MC="$(pin_of "$RC")"
out="$(run_sync_full "$RC" "$SHA2" "$H_HIT")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'REFUSED: the patch sync_vendor would write carries operator PII' <<< "$out" && grep -q 'ROLLING BACK' <<< "$out" && pass "C: full sync REFUSED by the operator-PII check (rc=1) and rolled back" || { fail "C: full sync rc=$rc, expected 1"; printf '%s\n' "$out" | grep -vF "$TERM_HIT" | tail -5 | sed 's/^/        /'; }
# Byte identity alone cannot discriminate here: v2 changes a line outside the
# scrub hunk, so a rewritten patch can come out byte-identical. The writer's
# own "wrote divergence patch" line is the discriminator.
if [ "$(fhash "$RC/vendor/divergences/synthtree.patch")" = "$PC" ] && ! grep -q 'wrote divergence patch' <<< "$out"; then
    pass "C: the patch was not (re)written"
else
    fail "C: THE PATCH WAS WRITTEN"
fi
[ "$(vhash "$RC")" = "$VC" ] && pass "C: vendored tree rolled back" || fail "C: VENDORED TREE LEFT SWAPPED"
[ -n "$MC" ] && [ "$(pin_of "$RC")" = "$MC" ] && pass "C: pinned_sha restored to the v1 pin" || fail "C: PIN MOVED"
leak_check "C" "$out"

# --- D: the clean control for the two sync_vendor paths -----------------------
RD="$WORK/d"; mkdir -p "$RD"; make_fixture "$RD" >/dev/null
out="$(run_sync_regen "$RD" "$H_CLEAN")"; rc=$?
[ "$rc" -eq 0 ] && [ -s "$RD/vendor/divergences/synthtree.patch" ] \
    && pass "D2: clean inventory, sync_vendor --regen-patch WRITES" \
    || { fail "D2: clean inventory, --regen-patch rc=$rc or no patch"; printf '%s\n' "$out" | grep -vF "$TERM_HIT" | tail -5 | sed 's/^/        /'; }
RD3="$WORK/d3"; mkdir -p "$RD3"; make_fixture "$RD3" >/dev/null
SHA3="$(prepare_full_sync "$RD3")" || { echo "CANNOT RUN: could not record the v1 scrub patch for D3" >&2; exit 2; }
out="$(run_sync_full "$RD3" "$SHA3" "$H_CLEAN")"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'wrote divergence patch' <<< "$out" && [ "$(pin_of "$RD3")" = "$SHA3" ] \
    && pass "D3: clean inventory, full sync WRITES the regenerated patch and moves the pin" \
    || { fail "D3: clean inventory, full sync rc=$rc, no write, or pin not moved"; printf '%s\n' "$out" | grep -vF "$TERM_HIT" | tail -5 | sed 's/^/        /'; }

# --- E: no inventory -> CANNOT-RUN, nothing written ---------------------------
RE="$WORK/e"; mkdir -p "$RE"; make_fixture "$RE" >/dev/null
out="$(run_regen "$RE" "$H_NONE")"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'CANNOT RUN' <<< "$out" && pass "E1: no inventory, regenerate CANNOT-RUN (rc=2)" || fail "E1: no inventory, regenerate rc=$rc, expected CANNOT-RUN rc=2"
[ -f "$RE/vendor/divergences/synthtree.patch" ] && fail "E1: A PATCH WAS WRITTEN WITHOUT A SCAN" || pass "E1: no patch written"
out="$(run_sync_regen "$RE" "$H_NONE")"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'CANNOT RUN' <<< "$out" && pass "E2: no inventory, sync_vendor CANNOT-RUN (rc=2)" || fail "E2: no inventory, sync_vendor rc=$rc, expected CANNOT-RUN rc=2"
[ -f "$RE/vendor/divergences/synthtree.patch" ] && fail "E2: A PATCH WAS WRITTEN WITHOUT A SCAN" || pass "E2: no patch written"

echo ""
if [ "$fails" -eq 0 ]; then
    echo "patch writers refuse operator PII: GREEN ($checks checks)"
    exit 0
fi
echo "patch writers refuse operator PII: RED ($fails of $checks failing)"
exit 1
