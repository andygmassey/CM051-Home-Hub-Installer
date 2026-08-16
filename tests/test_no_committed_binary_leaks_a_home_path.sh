#!/usr/bin/env bash
#
# test_no_committed_binary_leaks_a_home_path.sh
#
# This repository is PUBLIC. A committed binary can carry an absolute build path
# in its debug metadata, which discloses the machine owner's home directory name
# and the internal layout of their source tree. That is exactly what
# vendor/ostler_security/bin/ostler-passkey-helper did: a 361,920-byte Mach-O
# universal binary, committed 2026-05-22 at 593a9f8, carrying 18 occurrences of
# /Users/<operator>/Documents/Projects/HR015 - ... in Swift build paths.
#
# WHY A GATE AND NOT JUST A DELETE. That binary was found by accident, while
# chasing something else. Deleting it fixes the instance. This retires the class:
# no committed binary may carry a home path, checked on every PR.
#
# THE MEASUREMENT AXIS IS RAW BYTES, AND THAT IS THE WHOLE POINT.
#
#     tracked-file grep, '/Users/[a-z0-9._-]+'   ->  missed it (LOWERCASE-only)
#     strings -a | grep '/users/'                ->  0. A confident zero.
#     grep -aoiE over raw bytes                  ->  18. Correct.
#
# `strings` is a FILTER, not a reader: it extracts printable runs and skips the
# Mach-O sections these paths live in. A zero from `strings` means "nothing in
# the printable-run extraction", never "nothing in the file". Any check that
# authorises publication has to read the bytes. Case-insensitively, too.
#
# EXPECTED VALUE IS ZERO, WHICH IS WHY THE CONTROLS MATTER MORE THAN USUAL.
# A gate that should always report nothing is indistinguishable from a gate that
# looks at nothing. This one plants a binary that MUST be caught and refuses to
# report unless it is, per feedback_check_the_shape_of_a_zero.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

pass=0
fail=0
ok()  { printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }

# THE PLACEHOLDER LIST IS LOCAL, AND DELIBERATELY SO.
#
# The obvious move is to source .githooks/pii_patterns.sh and call
# pii_reserved_placeholder_re. I wrote it that way first and the control caught
# it: in THIS repo that function returns a PHONE-only regex (UK 07700 900xxx and
# 555-01xx test ranges). The home-path and email exemptions live in HR015's copy
# of the same library, which CM051 has not been given yet. Same function name,
# same file name, different contract.
#
# So a home path excused by that helper would have been reported here, and the
# gate would have failed on its own fixtures on day one. Sharing a NAME across
# repos is not sharing a MEANING.
#
# When the seven-pattern library lands in CM051, collapse this into
# pii_reserved_placeholder_re and delete the list. Until then it is local, and
# the reserved-name control below is what proves it is doing its job.
RESERVED='^/[Uu]sers/(you|user|username|example|runner|\$\{?USER\}?|<[a-z]+>)$'

# Case-INSENSITIVE on purpose. A denylist that only matches the casing you
# happened to see is the mistake that published names once already.
HOME_PATH='/[Uu]sers/[A-Za-z0-9._-]+'

# Count home-path hits in a file, reading RAW BYTES, excusing reserved names.
leak_count() {
    grep -aoiE "$HOME_PATH" "$1" 2>/dev/null | grep -vcE "$RESERVED" || true
}

is_binary() { [ "$(file -b --mime-encoding "$1" 2>/dev/null)" = "binary" ]; }

# ---------------------------------------------------------------------------
# CONTROLS FIRST. If these do not behave, no result below is trustworthy.
# ---------------------------------------------------------------------------
CTL_DIR="$(mktemp -d -t binleak.XXXXXX)"
trap 'rm -rf "$CTL_DIR"' EXIT

# A real binary shape: NUL bytes plus an embedded absolute build path.
printf 'HDR\000\001\002payload\000/Users/someoperator/Documents/Projects/Thing\000tail\000' \
    > "$CTL_DIR/positive.bin"
printf 'HDR\000\001\002payload\000/Users/example/Documents/Thing\000tail\000' \
    > "$CTL_DIR/reserved.bin"
printf 'HDR\000\001\002payload\000no paths at all\000tail\000' \
    > "$CTL_DIR/negative.bin"

if is_binary "$CTL_DIR/positive.bin"; then
    ok "control: the binary detector recognises a NUL-bearing file"
else
    bad "control: binary detector did NOT recognise a NUL-bearing file"
fi

n="$(leak_count "$CTL_DIR/positive.bin")"
if [ "$n" -ge 1 ]; then
    ok "POSITIVE CONTROL: a planted home path in a binary is found (${n})"
else
    bad "POSITIVE CONTROL DID NOT FIRE: planted home path not found, gate is blind"
fi

n="$(leak_count "$CTL_DIR/reserved.bin")"
if [ "$n" -eq 0 ]; then
    ok "control: a reserved placeholder name inside a binary is excused"
else
    bad "false positive: reserved placeholder was reported (${n})"
fi

n="$(leak_count "$CTL_DIR/negative.bin")"
if [ "$n" -eq 0 ]; then
    ok "control: a clean binary reports nothing"
else
    bad "false positive: clean binary reported ${n}"
fi

# Refuse to proceed on broken instrumentation. A CANNOT-RUN is not a pass.
if [ "$fail" -ne 0 ]; then
    echo
    echo "CANNOT-RUN: controls failed; refusing to report a verdict on the real tree" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# THE REAL SWEEP
# ---------------------------------------------------------------------------
examined=0
leaking=0
report=""
while IFS= read -r f; do
    [ -f "$f" ] || continue
    is_binary "$f" || continue
    examined=$((examined + 1))
    n="$(leak_count "$f")"
    if [ "$n" -gt 0 ]; then
        leaking=$((leaking + 1))
        report="${report}
    ${n} occurrence(s)  ${f}"
    fi
done < <(git ls-files)

# Zero binaries examined means the walk broke, not that the tree is clean.
if [ "$examined" -eq 0 ]; then
    echo
    echo "CANNOT-RUN: examined 0 committed binaries; the file walk found nothing" >&2
    exit 2
fi
ok "swept ${examined} committed binary/binaries"

if [ "$leaking" -eq 0 ]; then
    ok "no committed binary carries a home path"
else
    bad "${leaking} committed binary/binaries carry a home path:${report}"
fi

echo
echo "== results: ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]
