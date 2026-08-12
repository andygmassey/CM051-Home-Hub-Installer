#!/usr/bin/env bash
# ci-pii-shape-scan.sh -- the PII check that CAN actually run in CI.
#
# WHY THIS EXISTS
#
# `operator-pii-scan.sh` is a DENYLIST. It reads Andy's real inventory from
# ${HOME}/.ostler-operator-pii.toml and greps for those exact values. That is
# the right control on a developer machine and the wrong one in CI, because CI
# cannot have that file: the values ARE the PII, and the committed fallback at
# .github/operator-pii-inventory.toml is a blank template by design.
#
# MEASURED 2026-08-12 on CM051 #583: the committed inventory has every scalar
# set to "" and every array empty, so the scanner assembles ZERO patterns and
# exits 2 "inventory empty". After the wrapper fix stopped laundering failures
# into exit 0, that exit 2 became a hard red on EVERY CM051 pull request. The
# red said "PII" and meant "I could not run". A gate whose red carries no
# information gets routed around, which is worse than no gate.
#
# Provisioning the inventory as an Actions secret was proposed and WITHDRAWN.
# It is not coming back. So CI needs a check that needs no inventory.
#
# WHAT THIS DOES INSTEAD
#
# Scans for the SHAPE of PII rather than for known values: UK/US phone
# patterns, SSN, DSID, email addresses, /Users/<name>/ home paths. Those
# patterns live in .githooks/pii_patterns.sh, are already used by the
# pre-commit hook, and already have their own test suite asserting they fire
# on synthetic SSN and UK-phone input and stay quiet on clean input.
#
# Shape-based is strictly stronger for the leak that matters. A denylist can
# only catch values someone already wrote down; it can never catch the first
# leak of a number nobody has enumerated. This catches a phone-shaped literal
# whoever it belongs to.
#
# THE CANARY, AND WHY IT RUNS EVERY TIME
#
# `pii_scan_files` returns 0 unconditionally and reports hits on STDOUT, and
# `pii_load_patterns` yields nothing at all when it finds no patterns. A naive
# wrapper around it reports "clean" when the detector loaded nothing -- the
# exact zero-denominator failure that put the denylist in this state.
#
# So before scanning anything real, this scans a synthetic known-bad file and
# REQUIRES a hit. If the canary does not fire, the detector is broken or empty
# and the run is CANNOT-RUN, never a pass. The gate demonstrates its own RED on
# every single invocation rather than once, in a shell, on the day it was
# written.
#
# Exit codes
#   0  scanned N files, no shape hits  (N is always printed, including 0)
#   1  at least one shape hit          (BLOCK)
#   2  CANNOT-RUN: pattern library missing, no patterns loaded, or the canary
#      failed to fire. Never silently a pass.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LIB="${PII_PATTERNS_LIB:-$REPO_ROOT/.githooks/pii_patterns.sh}"

if [ ! -r "$LIB" ]; then
    echo "ci-pii-shape-scan: CANNOT-RUN -- no pattern library at $LIB" >&2
    echo "  Provision it with bin/install-pii-guards.sh from the HR015 repo." >&2
    exit 2
fi
# shellcheck disable=SC1090
. "$LIB"

CUSTOM="$REPO_ROOT/.pii-patterns"
[ -f "$CUSTOM" ] || CUSTOM=""

PATTERN_COUNT="$(pii_load_patterns "$CUSTOM" | grep -c . || true)"
if [ "${PATTERN_COUNT:-0}" -eq 0 ]; then
    echo "ci-pii-shape-scan: CANNOT-RUN -- the pattern library loaded 0 patterns." >&2
    echo "  Zero patterns would report every file clean. That is not a pass." >&2
    exit 2
fi

# ── Positive control ──────────────────────────────────────────────────────
# Composed from parts on purpose. The phone pattern is SHAPE-based and
# .githooks/test_pii_patterns.sh asserts it fires even on the OFCOM drama
# range, so a phone-shaped literal written directly into this file would be
# blocked by the very hook this script supports. A gate must not carry the
# thing it hunts.
CANARY_DIR="$(mktemp -d -t pii-canary-XXXXXX)"
trap 'rm -rf "$CANARY_DIR"' EXIT
_cc="+44"; _sub="7700900000"
printf 'contact = "%s%s"\n' "$_cc" "$_sub" > "$CANARY_DIR/canary.txt"

CANARY_HIT="$(pii_scan_files "$CANARY_DIR/canary.txt" "$CUSTOM")"
if [ -z "$CANARY_HIT" ]; then
    echo "ci-pii-shape-scan: CANNOT-RUN -- the canary did not fire." >&2
    echo "  $PATTERN_COUNT pattern(s) loaded, yet a known phone-shaped literal" >&2
    echo "  was not detected. The detector is broken; a clean result from it" >&2
    echo "  would be meaningless. Refusing to report a pass." >&2
    exit 2
fi

# ── Resolve what to scan ──────────────────────────────────────────────────
# BASE_REF set   -> the diff against it (pull request)
# args given     -> those paths
# neither        -> tracked files
FILES=""
if [ "$#" -gt 0 ]; then
    FILES="$(printf '%s\n' "$@")"
    SOURCE="$# path argument(s)"
elif [ -n "${BASE_REF:-}" ]; then
    if ! git rev-parse --verify --quiet "$BASE_REF" >/dev/null; then
        echo "ci-pii-shape-scan: CANNOT-RUN -- BASE_REF '$BASE_REF' does not resolve." >&2
        echo "  A shallow checkout cannot see the base. Fetch it before scanning;" >&2
        echo "  scanning nothing must not read as scanning clean." >&2
        exit 2
    fi
    FILES="$(git diff --name-only --diff-filter=ACMR "$BASE_REF"...HEAD)"
    SOURCE="diff vs $BASE_REF"
else
    FILES="$(git ls-files)"
    SOURCE="all tracked files"
fi

# Drop paths that no longer exist and directories.
EXISTING=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    EXISTING="$EXISTING$f
"
done <<< "$FILES"

COUNT="$(printf '%s' "$EXISTING" | grep -c . || true)"

echo "ci-pii-shape-scan: $PATTERN_COUNT pattern(s) loaded, canary fired, examining $COUNT file(s) from $SOURCE"

if [ "${COUNT:-0}" -eq 0 ]; then
    # Honest zero. Printed, not hidden behind a green tick.
    echo "ci-pii-shape-scan: 0 files to examine. Nothing was scanned, and nothing was found."
    exit 0
fi

HITS="$(pii_scan_files "$EXISTING" "$CUSTOM")"

if [ -n "$HITS" ]; then
    echo "ci-pii-shape-scan: PII-shaped content in $COUNT examined file(s):" >&2
    printf '%s\n' "$HITS" >&2
    echo "" >&2
    echo "These patterns match on SHAPE, not on a list of known values, so a" >&2
    echo "synthetic-looking number still trips them. Do not weaken the pattern" >&2
    echo "and do not bypass the hook. Compose the literal from parts at runtime," >&2
    echo "or move the fixture under a path the guard excludes." >&2
    exit 1
fi

echo "ci-pii-shape-scan: clean, $COUNT file(s) examined"
exit 0
