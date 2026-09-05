#!/usr/bin/env bash
# Divergent non-shipping twin guard
# =================================
#
# The browsing-at-v1.0 disease: gui/project.yml bundles vendor/ostler_fda,
# but a fix landed in a top-level ostler_fda/ copy that never shipped, so
# the customer ran stale code while the source tree looked correct.
#
# This guard fails if any bundled package under vendor/ also exists as a
# top-level directory with the same name AND a shared file diverges. The
# shipping copy is vendor/; a top-level twin that drifts from it is the
# exact trap. Either there is no twin, or the twin is byte-identical.
#
# Network-free, dependency-free. Wire into CI on vendor/** changes.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Compare every file present in BOTH trees. Echoes one line per divergence, so
# the caller counts and this function only reports. Lifted out of the loop below
# ONLY so _selftest can drive it against a seeded pair; the loop's behaviour is
# unchanged.
_compare_twin() {
    local vdir="$1" tdir="$2" label="$3" rel
    while IFS= read -r rel; do
        if [ -f "${vdir}/${rel}" ] && [ -f "${tdir}/${rel}" ]; then
            if ! diff -q "${vdir}/${rel}" "${tdir}/${rel}" >/dev/null 2>&1; then
                echo "divergent twin: ${label}/${rel} differs from ./${tdir}/${rel}"
            fi
        fi
    done < <(cd "$vdir" && find . -type f | sed 's|^\./||')
}

# PROVE THE COMPARISON CAN SEE A DIFFERENCE, AND CAN ABSTAIN.
# This guard's PASS is a zero, and on this tree it is a zero reached with
# checked=0 -- no twins exist at all. Nothing else here demonstrates that the
# comparison is capable of reporting anything, so a diff that silently stopped
# working would print PASS for ever and look identical to today.
_selftest() {
    local td rc=0
    td="$(mktemp -d)" || { echo "CANNOT-RUN: mktemp failed in selftest" >&2; return 2; }
    mkdir -p "$td/v/pkg" "$td/t/pkg"

    # MUST-FLAG: the shipping copy and the twin differ.
    printf 'SHIPPING\n' > "$td/v/pkg/mod.py"
    printf 'DRIFTED\n'  > "$td/t/pkg/mod.py"
    if [ -z "$(_compare_twin "$td/v" "$td/t" seeded)" ]; then
        echo "SELFTEST: a seeded DIVERGENT twin was not reported. The comparison is blind, so the verdict below means nothing." >&2
        rc=1
    fi

    # MUST-MISS: identical files must report nothing.
    printf 'SAME\n' > "$td/v/pkg/mod.py"
    printf 'SAME\n' > "$td/t/pkg/mod.py"
    if [ -n "$(_compare_twin "$td/v" "$td/t" seeded)" ]; then
        echo "SELFTEST: an IDENTICAL twin was reported as divergent. The comparison is loud rather than right." >&2
        rc=1
    fi

    rm -rf "$td"
    return "$rc"
}

_selftest || exit 1

# 🔴 COULD NOT LOOK IS NOT A PASS. This used to `exit 0`, so a tree with no
# vendor/ at all returned the same verdict as a fully compared one.
if [ ! -d vendor ]; then
    echo "CANNOT-RUN: no vendor/ directory under ${REPO_ROOT}. Nothing was compared; this is not a pass." >&2
    exit 2
fi

divergences=0
checked=0

for vdir in vendor/*/; do
    pkg="$(basename "$vdir")"
    twin="$pkg"
    # A non-shipping twin is a top-level dir with the same name as the
    # vendored package (vendor/ostler_fda <-> ./ostler_fda).
    if [ ! -d "$twin" ]; then
        continue
    fi
    checked=$((checked + 1))
    echo "twin found: vendor/$pkg <-> ./$twin -- comparing shared files"
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        echo "FAIL: ${hit}" >&2
        echo "      The shipping copy is vendor/. A drifting top-level twin ships stale code." >&2
        divergences=$((divergences + 1))
    done < <(_compare_twin "${vdir%/}" "$twin" "vendor/$pkg")
done

if [ "$divergences" -gt 0 ]; then
    echo "FAIL: $divergences divergent vendor/top-level twin file(s) found" >&2
    exit 1
fi

if [ "$checked" -eq 0 ]; then
    echo "no top-level twins of any vendored package: clean (the disease cannot recur via a drifting twin)"
else
    echo "$checked vendored package(s) have a top-level twin; all shared files byte-identical"
fi
echo "divergent-vendor-twin guard: PASS"
