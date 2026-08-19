#!/usr/bin/env bash
#
# test_no_env_trust_anchors.sh -- prove the cross-language trust-anchor guard
# FIRES, and fires on the right axis.
#
# The guard it covers exists because a single-file Swift assertion could not see
# a sibling construct in install.sh. So the controls that matter here are the
# ones planting the construct in a DIFFERENT language from the last one that had
# it: a guard which only catches Swift would have been useless on 2026-08-17.
#
# Fixtures are real git repos, and the gate is driven through its shipping
# entry point with --repo. An inline copy of the predicate would prove a copy
# correct and say nothing about what runs.
set -uo pipefail

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/verify_no_env_trust_anchors.sh"
[[ -r "$GATE" ]] || { echo "FAIL: gate not readable: $GATE"; exit 99; }

PASS=0; FAIL=0
TMP="$(mktemp -d -t env_anchor_XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# new_repo <name> -- a fixture with one benign shipping file
new_repo() {
    local d="$TMP/$1"; mkdir -p "$d/scripts" "$d/tests"
    git -C "$d" init -q 2>/dev/null
    git -C "$d" config user.email t@t.invalid; git -C "$d" config user.name t
    printf '#!/usr/bin/env bash\necho "benign, reads no keys"\n' > "$d/scripts/benign.sh"
    git -C "$d" add -A; git -C "$d" commit -qm base >/dev/null 2>&1
    echo "$d"
}

run() { bash "$GATE" "$1" >"$TMP/out" 2>&1; echo $?; }

check() { # check <label> <want-rc> <actual-rc>
    if [[ "$3" == "$2" ]]; then
        printf '  PASS  %-56s rc=%s\n' "$1" "$3"; PASS=$((PASS+1))
    else
        printf '  FAIL  %-56s rc=%s want=%s\n' "$1" "$3" "$2"
        sed 's/^/        | /' "$TMP/out"; FAIL=$((FAIL+1))
    fi
}

echo "test_no_env_trust_anchors"
echo

# 1. GREEN CONTROL FIRST. A gate that only ever says no is as useless as one
#    that only ever says yes, and this one is new enough that nobody has seen
#    it pass.
R="$(new_repo clean)"
check "clean tree passes" 0 "$(run "$R")"

# 2. THE SHELL CASE -- install.sh:1081, the one a Swift-only guard missed.
R="$(new_repo shellcase)"
printf '#!/usr/bin/env bash\nkey="$OSTLER_LICENSE_PUBKEY_OVERRIDE"\nverify "$key"\n' > "$R/scripts/gate.sh"
git -C "$R" add -A; git -C "$R" commit -qm shell >/dev/null 2>&1
check "shell env pubkey read -> RED" 1 "$(run "$R")"

# 3. THE SWIFT CASE -- the original 2026-08-16 defect, restated.
R="$(new_repo swiftcase)"
mkdir -p "$R/gui"
printf 'let k = ProcessInfo.processInfo.environment["OSTLER_LICENSE_PUBKEY_OVERRIDE"]\n' > "$R/gui/Verifier.swift"
git -C "$R" add -A; git -C "$R" commit -qm swift >/dev/null 2>&1
check "swift env pubkey read -> RED" 1 "$(run "$R")"

# 4. PYTHON AND RUST. Neither language has had this defect yet. That is exactly
#    why they are here: the guard must already cover the mirror nobody has
#    written, or it will be extended after the next incident rather than before.
R="$(new_repo pycase)"
printf 'import os\nkey = os.environ.get("APP_VERIFY_KEY")\n' > "$R/scripts/verify.py"
git -C "$R" add -A; git -C "$R" commit -qm py >/dev/null 2>&1
check "python env verify_key read -> RED" 1 "$(run "$R")"

R="$(new_repo rustcase)"
printf 'fn main() { let k = std::env::var("TRUST_ANCHOR_HEX").unwrap(); }\n' > "$R/scripts/main.rs"
git -C "$R" add -A; git -C "$R" commit -qm rs >/dev/null 2>&1
check "rust env trust_anchor read -> RED" 1 "$(run "$R")"

# 5. THE NAME IS NOT WHAT MAKES IT DANGEROUS. The Swift guard's own words. A
#    variable called SIGNING_KEY must fail exactly like one called PUBKEY.
R="$(new_repo namecase)"
printf '#!/usr/bin/env bash\nk="${MY_SIGNING_KEY:-}"\n' > "$R/scripts/other.sh"
git -C "$R" add -A; git -C "$R" commit -qm name >/dev/null 2>&1
check "a differently-NAMED anchor still fails" 1 "$(run "$R")"

# 6. TESTS MAY INJECT. This is the load-bearing negative: if the guard flags
#    test files it will be switched off within a week, because injecting a key
#    is how you prove a verifier rejects a forgery. Same construct as (2), under
#    tests/ instead of scripts/.
R="$(new_repo testdir)"
printf '#!/usr/bin/env bash\nOSTLER_LICENSE_PUBKEY_OVERRIDE="$OUR_PUBKEY" run_gate\n' > "$R/tests/test_gate.sh"
git -C "$R" add -A; git -C "$R" commit -qm t >/dev/null 2>&1
check "the SAME construct under tests/ is allowed" 0 "$(run "$R")"

# 7. ...and under a *Tests.swift name, which is not in a tests/ directory.
R="$(new_repo swifttests)"
mkdir -p "$R/gui"
printf 'setenv("OSTLER_LICENSE_PUBKEY_OVERRIDE", attackerHex, 1)\n' > "$R/gui/LicenseVerifierTests.swift"
git -C "$R" add -A; git -C "$R" commit -qm st >/dev/null 2>&1
check "*Tests.swift may inject (that IS the Swift guard)" 0 "$(run "$R")"

# 8. CANNOT-RUN is rc=2 and is never a pass.
R="$TMP/not-a-repo"; mkdir -p "$R"
check "non-git tree -> CANNOT (2), not a pass" 2 "$(run "$R")"

# 9. THE EXEMPTION IS CHECKED, NOT TRUSTED. The real repo carries one row, for
#    install.sh. Run the gate against the REAL tree: it must be GREEN, and the
#    output must NAME the held file and print a reason. An exemption nobody can
#    read is an allowlist entry pretending to be a decision.
REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rc="$(run "$REAL")"
check "the real tree is GREEN with its exemption held" 0 "$rc"
if grep -q 'HELD .*install.sh' "$TMP/out" && grep -q '#733' "$TMP/out"; then
    printf '  PASS  %-56s\n' "and it NAMES the held file and its row"; PASS=$((PASS+1))
else
    printf '  FAIL  %-56s\n' "held file or row reference not printed"; FAIL=$((FAIL+1))
fi

echo
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]] || exit 1
echo "ALL TRUST-ANCHOR GUARD TESTS PASSED"
