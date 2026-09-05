#!/usr/bin/env bash
# Divergent non-shipping twin guard
# =================================
#
# The browsing-at-v1.0 disease: gui/project.yml bundles vendor/ostler_fda,
# but a fix landed in a top-level ostler_fda/ copy that never shipped, so
# the customer ran stale code while the source tree looked correct.
#
# This guard fails if any bundled package under vendor/ also exists as a
# top-level directory with the same name AND a shared file diverges. Either
# there is no twin, or the twin is byte-identical.
#
# 🔴 THE ORIGINAL LOOP COULD NEVER FIND A TWIN ON THIS TREE, AND SAID SO AS
# "clean". It iterated `vendor/*/` and took the basename as the package name.
# Measured 2026-09-05: all 21 entries under vendor/ are REPO names -- cm041,
# email_source, ostler_fda -- and never package names. The packages sit one
# level deeper, at vendor/<repo>/<pkg>. `checked=0` was structural, so this
# guard had never compared a single file, and its zero printed identically to
# a real one. The pair it was blind to is
# vendor/cm041/contact_syncer <-> ./contact_syncer, FOURTEEN divergent modules.
#
# Two traps in looking one level deeper, both hit while measuring:
#
#   * A naive descent manufactures 16 spurious pairs, because `vendor/*/tests`
#     and `vendor/*/bin` collide by basename with ./tests and ./bin. Requiring
#     __init__.py on BOTH sides rejects all 16 and keeps the 1 real package.
#   * WHICH COPY SHIPS IS NOT A CONSTANT. This file used to assert "the
#     shipping copy is vendor/". For contact_syncer that is INVERTED:
#     install.sh copies ${SCRIPT_DIR}/contact_syncer, the ROOT copy, into the
#     import pipeline. A guard that names the wrong file as authoritative sends
#     the reader to fix the copy nobody runs, so this one no longer guesses.
#
# The known drift is recorded in tests/VENDOR_TWIN_DRIFT.tsv as debt with a
# number on it, the same idiom as the UNWIRED rows in TEST_WIRING.tsv: green on
# today's tree, red the moment the drift GROWS or a new pair appears.
# Regenerate with --regenerate after a deliberate re-vendor.
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
    done < <(cd "$vdir" && find . -type f \
        -not -path '*/__pycache__/*' -not -name '*.pyc' -not -name '.DS_Store' \
        | sed 's|^\./||')
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
        echo "      These two must be byte-identical. Determine which copy actually" >&2
        echo "      ships before picking a winner -- it is not always vendor/." >&2
        divergences=$((divergences + 1))
    done < <(_compare_twin "${vdir%/}" "$twin" "vendor/$pkg")
done

if [ "$divergences" -gt 0 ]; then
    echo "FAIL: $divergences divergent vendor/top-level twin file(s) found" >&2
    exit 1
fi

if [ "$checked" -eq 0 ]; then
    echo "shallow walk (vendor/<pkg>): 0 twins -- expected on this tree, every vendor/ entry is a REPO name"
else
    echo "shallow walk (vendor/<pkg>): $checked package(s) have a top-level twin; all shared files byte-identical"
fi

# ---------------------------------------------------------------------------
# DEEP WALK: vendor/<repo>/<pkg> <-> ./<pkg>
#
# THE RECORDED NUMBER MUST MEAN THE SAME THING ON EVERY HOST. It did not:
# this workstation counted 32 shared files and 23 divergent, and a clean runner
# counted 24 and 15. The eight extra were __pycache__/*.pyc that MY OWN test
# runs had created by importing both copies of contact_syncer minutes earlier.
# The instrument was measuring its own footprint, and it did it in the direction
# that inflates the debt. _compare_twin now prunes build artefacts, so the count
# is a property of the tracked source and not of what has been run in the tree.
#
# A candidate is a PACKAGE twin only if __init__.py is present on BOTH sides.
# Without that discriminator this walk reports vendor/cm041/tests <-> ./tests
# and fourteen other basename collisions that are not packages at all.
# ---------------------------------------------------------------------------
# WHICH SIDE SHIPS IS DERIVABLE, NOT A JUDGEMENT CALL.
#
# install.sh is the only authority, and it answers by copying: a package it
# copies from ${SCRIPT_DIR}/<pkg> has the REPO ROOT as its authoritative copy.
# Measured 2026-09-05: install.sh makes SIX such copies (ostler_security,
# ostler_fda, contact_syncer, meeting_syncer, identity_resolver, ostler_hygiene)
# and ZERO copies out of vendor/. So this file's old global claim that "the
# shipping copy is vendor/" was not merely wrong for one pair -- it was wrong
# for every package the installer copies.
#
# It matters because the obvious remediation is the dangerous one: re-vendoring
# CM041 to "fix the drift" would overwrite the SHIPPING contact_syncer with the
# older vendored tree and silently regress every module that has moved on.
_shipping_side() {
    local pkg="$1" n
    [ -f install.sh ] || { echo "unknown"; return; }
    n="$(/usr/bin/grep -cE 'cp -R "\$\{SCRIPT_DIR\}/'"${pkg}"'"' install.sh || :)"
    if [ "${n:-0}" -gt 0 ]; then echo "root"; return; fi
    n="$(/usr/bin/grep -cE 'cp -R "\$\{SCRIPT_DIR\}/vendor/[^"]*/'"${pkg}"'"' install.sh || :)"
    if [ "${n:-0}" -gt 0 ]; then echo "vendor"; return; fi
    echo "unknown"
}

LEDGER="tests/VENDOR_TWIN_DRIFT.tsv"
computed="$(mktemp)" || { echo "CANNOT-RUN: mktemp failed for the drift ledger" >&2; exit 2; }
trap 'rm -f "$computed"' EXIT

deep_candidates=0
deep_pairs=0
deep_files=0

for vdir in vendor/*/*/; do
    pkg="$(basename "${vdir%/}")"
    [ -d "$pkg" ] || continue
    deep_candidates=$((deep_candidates + 1))
    # THE DISCRIMINATOR. Both sides must be importable packages.
    [ -f "${vdir}__init__.py" ] || continue
    [ -f "${pkg}/__init__.py" ] || continue
    deep_pairs=$((deep_pairs + 1))
    while IFS= read -r rel; do
        if [ -f "${vdir}${rel}" ] && [ -f "${pkg}/${rel}" ]; then
            deep_files=$((deep_files + 1))
        fi
    done < <(cd "$vdir" && find . -type f \
        -not -path '*/__pycache__/*' -not -name '*.pyc' -not -name '.DS_Store' \
        | sed 's|^\./||')
    # A SECOND, INDEPENDENT ENUMERATION, AND THEY MUST AGREE.
    # The prune above is what keeps this count a property of the tracked source
    # rather than of what has been run in the tree, and removing it only turns
    # this file red on a host that HAPPENS to carry build artefacts -- a clean
    # runner would not notice. git tracking is the independent answer to the
    # same question, so a disagreement means untracked files reached the
    # comparison and the count means something different here than elsewhere.
    # That is CANNOT-RUN, not a verdict.
    tracked_shared=0
    if git rev-parse --git-dir >/dev/null 2>&1; then
        va="$(mktemp)"; ra="$(mktemp)"
        git ls-files -- "${vdir%/}" | sed "s|^${vdir}||" | LC_ALL=C sort > "$va"
        git ls-files -- "$pkg"     | sed "s|^${pkg}/||"  | LC_ALL=C sort > "$ra"
        tracked_shared="$(comm -12 "$va" "$ra" | /usr/bin/grep -c . || :)"
        rm -f "$va" "$ra"
        if [ "$tracked_shared" -ne "$deep_files" ]; then
            echo "CANNOT-RUN: ${vdir%/} <-> ./$pkg compared $deep_files shared file(s)" >&2
            echo "            but git tracks $tracked_shared shared. Untracked files reached" >&2
            echo "            the comparison, so the recorded count does not mean the same" >&2
            echo "            thing here as on a clean checkout." >&2
            exit 2
        fi
    fi

    # THE SELFTESTED COMPARATOR, NOT A SECOND COPY OF IT. _selftest above
    # proves _compare_twin can both flag a seeded divergence and stay silent on
    # an identical pair. A private diff here would be an uncontrolled second
    # implementation of the one thing this file is for.
    n="$(_compare_twin "${vdir%/}" "$pkg" "vendor-deep" | /usr/bin/grep -c . || :)"
    n="${n:-0}"
    printf '%s\t%s\t%s\n' "${vdir%/}" "./$pkg" "$n" >> "$computed"
done

# PIN THE ORDER. A glob pins none, and LC_COLLATE decides what `sort` means, so
# a diff against the ledger would flap between hosts without LC_ALL=C.
sorted="$(mktemp)" || { echo "CANNOT-RUN: mktemp failed for the sorted ledger" >&2; exit 2; }
trap 'rm -f "$computed" "$sorted"' EXIT
LC_ALL=C sort "$computed" > "$sorted"

if [ "${1:-}" = "--regenerate" ]; then
    {
        echo "# VENDOR_TWIN_DRIFT.tsv -- package twins that exist, and how far apart they are."
        echo "#"
        echo "# Generated by tests/test_no_divergent_vendor_twin.sh --regenerate."
        echo "#"
        echo "# A row here is DEBT, not a blessing. The guard fails the moment a count"
        echo "# GROWS, a new pair appears, or a pair disappears without this file being"
        echo "# regenerated -- so the number cannot become wallpaper."
        echo "#"
        echo "# Zero rows is the goal. Reaching it means deciding which copy ships and"
        echo "# re-vendoring the other, which is a decision and not a diff."
        echo "#"
        echo "# columns: vendored_path<TAB>root_twin<TAB>divergent_shared_files"
        cat "$sorted"
    } > "$LEDGER"
    echo "wrote $LEDGER"
    echo "  $deep_pairs package twin(s), $deep_files shared file(s) compared"
    exit 0
fi

if [ ! -f "$LEDGER" ]; then
    echo "CANNOT-RUN: $LEDGER is missing. The deep walk found $deep_pairs package twin(s)" >&2
    echo "            and has nothing to compare them against. Run --regenerate." >&2
    exit 2
fi

recorded="$(mktemp)" || { echo "CANNOT-RUN: mktemp failed for the recorded ledger" >&2; exit 2; }
trap 'rm -f "$computed" "$sorted" "$recorded"' EXIT
/usr/bin/grep -v '^#' "$LEDGER" | /usr/bin/grep -v '^[[:space:]]*$' | LC_ALL=C sort > "$recorded" || :

echo "deep walk (vendor/<repo>/<pkg>): $deep_candidates basename candidate(s), $deep_pairs of them real packages, $deep_files shared file(s) compared"

if ! diff -u "$recorded" "$sorted" > /dev/null 2>&1; then
    echo "FAIL: the package-twin drift does not match $LEDGER." >&2
    echo "      -- is the recorded debt, ++ is what the tree has now:" >&2
    # 🔴 `diff` EXITS 1 WHEN THE FILES DIFFER, WHICH IS THE ONLY CASE THIS BLOCK
    # RUNS IN. Under `set -e` with `pipefail` that non-zero killed the script on
    # this very line, so every line of guidance below -- the GREW/SHRANK advice
    # and the per-pair shipping side -- had NEVER PRINTED. The reader saw two
    # ledger lines and no instruction. `|| :` because the difference is the
    # point, not an error.
    { diff -u "$recorded" "$sorted" || :; } | sed -n '4,$p' | sed 's/^/      /' >&2
    echo "      A count that GREW is new drift: fix it, do not re-record it." >&2
    echo "      A count that SHRANK or a pair that vanished is good news that still" >&2
    echo "      needs --regenerate, so the recorded number stays honest." >&2
    echo "" >&2
    echo "      WHICH SIDE SHIPS, per pair, derived from install.sh:" >&2
    while IFS="$(printf '\t')" read -r _vp _rp _c; do
        [ -n "${_vp:-}" ] || continue
        _pkg="$(basename "$_vp")"
        case "$(_shipping_side "$_pkg")" in
            root)   echo "        ${_pkg}: install.sh copies \${SCRIPT_DIR}/${_pkg}, so ./${_pkg} is AUTHORITATIVE." >&2
                    echo "                 DO NOT re-vendor this pair -- it would overwrite the shipping" >&2
                    echo "                 copy with the older vendored tree." >&2 ;;
            vendor) echo "        ${_pkg}: install.sh copies it out of vendor/, so the vendored copy is AUTHORITATIVE." >&2 ;;
            *)      echo "        ${_pkg}: install.sh copies neither side by name. Find what ships BEFORE picking a winner." >&2 ;;
        esac
    done < "$sorted"
    exit 1
fi

if [ "$deep_pairs" -gt 0 ]; then
    echo "deep walk: $deep_pairs package twin(s), drift matches $LEDGER exactly"
    while IFS="$(printf '\t')" read -r vp rp cnt; do
        [ -n "${vp:-}" ] || continue
        [ "$cnt" -gt 0 ] && echo "  RECORDED DEBT: $vp <-> $rp, $cnt divergent shared file(s); install.sh ships the $(_shipping_side "$(basename "$vp")") side"
    done < "$recorded"
fi

echo "divergent-vendor-twin guard: PASS"
