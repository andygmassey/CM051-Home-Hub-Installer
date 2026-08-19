#!/usr/bin/env bash
#
# tests/test_appcast_debt_is_collected.sh
#
# THE DEFERRAL THIS COLLECTS
# --------------------------
# Andy's decision, 2026-08-19, settled and not to be re-litigated: a Sparkle
# EdDSA PRIVATE key will not be held as an Actions secret on a PUBLIC repo.
# Signing happens on the box.
#
# So CI cuts with PUBLISH_APPCAST=onbox: the DMG is complete, the appcast is
# NOT published, and the step exits 0 rather than reddening a good cut.
#
# That exit 0 is the whole risk. An unpublished appcast is INVISIBLE from the
# product side: the feed simply does not list the release, Sparkle polls it,
# finds nothing, and reports no update available. Every surface looks healthy.
# Installed Hubs never see the release. That is task #370's exact shape, "the
# publisher exists and NOTHING calls it", and it is why the previous authors
# kept the hard-require even though it reddened every cut.
#
# The hard-require is not softened here. It MOVES. CI stops pretending it
# might publish, and this gate collects the debt on the next cut.
#
# WHY A POSITIVE RECORD, NOT AN "OWED" LIST
# -----------------------------------------
# cuts/appcast-published.txt records versions that HAVE been published. A
# version is considered unpublished when it is ABSENT.
#
# That direction is deliberate. An "owed" list has to be written correctly at
# the moment of deferral, by the process that is deferring, and if that write
# is ever missed the debt vanishes silently and the gate goes green having
# checked nothing. A positive record fails the other way: forget to write it
# and the gate REFUSES. The failure mode of a missing record is a false
# accusation, which someone fixes in a minute, rather than a false clean,
# which nobody ever notices.
#
# EXIT CODES
#   0  every shipped version older than the one being cut has been published
#   1  at least one has not (the versions are named)
#   2  CANNOT-RUN, and it is NOT a pass
#
# macOS bash 3.2.57 + BSD userland. No `grep -P`, no `sed \b`, no `grep -o`
# with GNU-only flags. British English; " -- " not em-dashes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECORD="${APPCAST_PUBLISHED_RECORD:-${REPO_ROOT}/cuts/appcast-published.txt}"
CUTS_DIR="${REPO_ROOT}/cuts"

RC_DEBT=1
RC_CANNOT_RUN=2

cannot_run() {
    echo "CANNOT-RUN: $*" >&2
    echo "  Nothing was checked. This is not a passing gate." >&2
    exit "$RC_CANNOT_RUN"
}

[[ -d "$CUTS_DIR" ]] || cannot_run "no cuts/ directory at ${CUTS_DIR}"

# ── The denominator: which versions have actually shipped ──────────
#
# A shipped version is one with a cuts/<version>/cut.env. That is the cut
# record the pipeline itself writes, so it cannot drift from what was cut.
# Deriving this from git tags instead would be wrong on a fresh clone with
# no tags fetched, which is exactly the CI shape.
SHIPPED=()
for d in "$CUTS_DIR"/v*/; do
    [[ -d "$d" ]] || continue
    [[ -f "${d}cut.env" ]] || continue
    v="$(basename "$d")"
    SHIPPED+=("$v")
done

if [[ "${#SHIPPED[@]}" -eq 0 ]]; then
    cannot_run "found no cuts/v*/cut.env, so there is no shipped version to check.
  Either this is not a CM051 checkout, or the cut records are missing. A gate
  that examined zero versions must not report success."
fi

# CURRENT is the version being cut, if the caller named one. It is exempt:
# its appcast is published AFTER the cut, so demanding it now would refuse
# every cut forever.
CURRENT="${CUT_VERSION:-}"

published_count=0
if [[ -f "$RECORD" ]]; then
    published_count="$(grep -c '^v[0-9]' "$RECORD" 2>/dev/null || echo 0)"
fi

MISSING=()
checked=0
for v in "${SHIPPED[@]+"${SHIPPED[@]}"}"; do
    [[ -n "$CURRENT" && "$v" == "$CURRENT" ]] && continue
    checked=$((checked + 1))
    # Whole-line match. A substring match would let v1.0.3 satisfy v1.0.36,
    # which is the prefix trap that has cost this project real time.
    if ! grep -q -x -F -- "$v" "$RECORD" 2>/dev/null; then
        MISSING+=("$v")
    fi
done

echo "DENOMINATOR"
echo "  cut records found        : ${#SHIPPED[@]}"
echo "  current cut (exempt)     : ${CURRENT:-<none named; CUT_VERSION unset>}"
echo "  versions checked         : ${checked}"
echo "  published-record entries : ${published_count}  (${RECORD})"
echo ""

if [[ "$checked" -eq 0 ]]; then
    cannot_run "every shipped version was exempted, so nothing was compared."
fi

if [[ "${#MISSING[@]}" -gt 0 ]]; then
    echo "FAIL: ${#MISSING[@]} shipped version(s) have NO appcast entry recorded:" >&2
    for v in "${MISSING[@]}"; do echo "    - $v" >&2; done
    echo "" >&2
    echo "  What this means: installed Hubs cannot see those releases. Sparkle" >&2
    echo "  polls the feed, the feed does not list them, and it reports no" >&2
    echo "  update available. Nothing looks broken anywhere." >&2
    echo "" >&2
    echo "  ON THE BOX, for each version above:" >&2
    echo "    export OSTLER_SPARKLE_SIGNING_KEY=/path/sparkle_private.pem  # 0400/0600" >&2
    echo "    make -C gui publish-appcast PUBLISH_APPCAST=1" >&2
    echo "" >&2
    echo "  The publish appends the version to:" >&2
    echo "    ${RECORD}" >&2
    echo "" >&2
    echo "  Do NOT satisfy this gate by editing that file by hand. The record" >&2
    echo "  exists to say a publish HAPPENED. Writing the line without doing" >&2
    echo "  the publish converts a loud debt into a silent one, which is the" >&2
    echo "  entire failure this gate was built to prevent." >&2
    exit "$RC_DEBT"
fi

echo "PASS: all ${checked} previously shipped version(s) have a recorded appcast entry."
exit 0
