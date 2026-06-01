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

if [ ! -d vendor ]; then
    echo "no vendor/ directory; nothing to check"
    exit 0
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
    # Compare every file present in BOTH trees; a difference is the trap.
    while IFS= read -r rel; do
        vfile="$vdir$rel"
        tfile="$twin/$rel"
        if [ -f "$vfile" ] && [ -f "$tfile" ]; then
            if ! diff -q "$vfile" "$tfile" >/dev/null 2>&1; then
                echo "FAIL: divergent twin: vendor/$pkg/$rel differs from ./$twin/$rel" >&2
                echo "      The shipping copy is vendor/. A drifting top-level twin ships stale code." >&2
                divergences=$((divergences + 1))
            fi
        fi
    done < <(cd "$vdir" && find . -type f | sed 's|^\./||')
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
