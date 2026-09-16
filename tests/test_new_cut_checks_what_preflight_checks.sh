#!/usr/bin/env bash
# test_new_cut_checks_what_preflight_checks.sh
#
# scripts/new_cut.sh tells the operator "ALL GREEN. Safe to tag" and "there is
# no second round of discovery". On 2026-09-08 that sentence was false: v1.0.76
# was tagged on it and cut run 34201583498 died at preflight in about forty
# seconds, on two hard gates the script did not have.
#
# MEASURED ON THE FILE AS IT WAS: 8 references to cuts/, 1 to cut-manifests,
# and ZERO to plist or CFBundle. The operator ran every gate offered and tagged
# on green, which is the only reasonable thing to do with a tool that says it
# has checked everything.
#
# So this test binds the two files together. It is deliberately NOT a copy of
# the checks: it asserts that for each hard preflight condition in cut.yml,
# new_cut.sh invokes something that can see it. A comment cannot keep two files
# in sync; a failing test can.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

NC="scripts/new_cut.sh"
CY=".github/workflows/cut.yml"
pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

for f in "$NC" "$CY"; do
    [ -r "$f" ] || { printf 'CANNOT-RUN: %s is not readable. Nothing was checked.\n' "$f" >&2; exit 3; }
done

# DENOMINATOR FIRST. A zero-gate read would make every assertion below vacuous:
# "new_cut.sh does not contain the bad thing" is trivially true of an empty file.
gates="$(grep -c '^run_gate ' "$NC")"
case "$gates" in ''|*[!0-9]*) gates=0 ;; esac
if [ "$gates" -lt 4 ]; then
    printf 'CANNOT-RUN: read %s run_gate line(s) in %s, expected at least 4. The parse is wrong, so a pass would be meaningless.\n' "$gates" "$NC" >&2
    exit 3
fi
ok "denominator: ${gates} run_gate line(s) parsed from new_cut.sh"

# 1. THE CUT RECORD. cut.yml refuses with "A tag without a manifest is a cut
#    nobody wrote down"; new_cut.sh must test the same path.
if [ "$(grep -c 'A tag without a manifest' "$CY")" -gt 0 ]; then
    ok "cut.yml still enforces the cut record (the condition is real)"
    if [ "$(grep -cE 'run_gate .*cut-manifests/\$\{VERSION\}\.yaml' "$NC")" -gt 0 ]; then
        ok "new_cut.sh gates on cut-manifests/\${VERSION}.yaml"
    else
        bad "new_cut.sh does NOT gate on cut-manifests/\${VERSION}.yaml, so it can say ALL GREEN while the cut record is missing -- the v1.0.76 failure"
    fi
else
    bad "cut.yml no longer carries the cut-record refusal; this test is keyed to text that moved, which is a stale test, not a pass"
fi

# 2. THE INSTALLER'S OWN VERSION. The v1.0.39 defect: a DMG that cannot say
#    which installer it is.
if [ "$(grep -c 'test_installer_version_matches_the_cut.sh' "$CY")" -gt 0 ]; then
    ok "cut.yml still runs the installer-version test (the condition is real)"
    # ONE check, not two. The first arm here used \n? in an ERE, which grep
    # cannot match because grep is line-based -- so that arm could never fire
    # and the || made it look like belt and braces when it was one belt.
    if [ "$(grep -c 'test_installer_version_matches_the_cut.sh' "$NC")" -gt 0 ]; then
        ok "new_cut.sh invokes test_installer_version_matches_the_cut.sh"
    else
        bad "new_cut.sh does NOT invoke test_installer_version_matches_the_cut.sh, so a stale plist reaches the tag -- the second half of the v1.0.76 failure"
    fi
else
    bad "cut.yml no longer runs the installer-version test; this test is keyed to a name that moved"
fi

# 3. THE PROVENANCE FLAG. Without CUT_VERSION_SOURCE the version test REFUSES
#    rather than running (#171), so invoking it unset would add a gate that
#    reports CANNOT-RUN for ever and reads, in a green list, as fine.
if [ "$(grep -c 'CUT_VERSION_SOURCE' "$NC")" -gt 0 ]; then
    ok "new_cut.sh sets CUT_VERSION_SOURCE, so the version test can actually run"
else
    bad "new_cut.sh invokes the version test without CUT_VERSION_SOURCE; it would refuse rather than measure"
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
