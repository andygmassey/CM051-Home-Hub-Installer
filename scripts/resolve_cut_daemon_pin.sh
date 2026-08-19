#!/usr/bin/env bash
#
# resolve_cut_daemon_pin.sh -- print the DAEMON_COMMIT the cut record declares
# for a given version, and say loudly when a hotfix falls back to its parent.
#
# PROVED-RED-BY: scripts/tests/test_resolve_cut_daemon_pin.sh
#
# ============================================================================
# WHY THIS IS A SCRIPT AND NOT A MAKEFILE RECIPE
# ============================================================================
#
# It was a recipe. #794 put the resolution inline in check-ostler-app, and
# Archie merged it flagging that the new WARN had no control firing it: the
# warning IS the safety mechanism here, and an unfired warn is precisely the
# two-state predicate that reads a warning as a pass.
#
# The reason it had no test is that logic embedded in a make recipe cannot be
# driven by a fixture without a full build. Asserting the recipe TEXT instead
# would test the rendering rather than the behaviour, which is the byte-window
# mistake in another costume.
#
# So it moves out, exactly as COMMIT_PARITY_SH and APP_PROVENANCE_SH already
# did in this same Makefile, and for the same stated reason: a gate delegated
# to a script is a gate a fixture can drive.
#
# ============================================================================
# WHAT IT RESOLVES
# ============================================================================
#
# CUT_MANIFEST_VERSION truncates with `cut -d. -f1-3`, so a four-part version
# resolves its PARENT's cut record. 1.0.13.1 and 1.0.13.2 both shipped as
# CFBundleShortVersionString in this repo, and a hotfix is exactly when the
# daemon gets re-pinned, so the parent's DAEMON_COMMIT can be the wrong operand.
#
# Prefer cuts/v<FULL>/cut.env. Fall back to the truncated path ONLY when the
# full one is absent, because no four-part cuts/ directory has ever existed and
# refusing would block a hotfix on a convention it has never followed. When it
# falls back, name BOTH paths and the consequence.
#
# Prints the pin on stdout (empty if none). Warnings go to stderr so a caller
# can capture the value cleanly.
#
# EXIT
#   0  resolved, or resolved-to-empty (the CALLER decides whether empty blocks;
#      verify_app_provenance.sh treats an unset pin as CANNOT-RUN, which is the
#      fail-closed behaviour this script deliberately does not duplicate)
#   2  could not run (bad usage)
#
# British English throughout; " -- " not em-dashes.
set -uo pipefail

REPO="${1:-}"
VERSION="${2:-}"
[ -n "$REPO" ] && [ -n "$VERSION" ] || {
    echo "usage: resolve_cut_daemon_pin.sh <repo-root> <version>" >&2
    exit 2
}
[ -d "$REPO" ] || { echo "CANNOT-RUN: not a directory: $REPO" >&2; exit 2; }

# The truncation the Makefile macro performs, reproduced here so the fallback
# path is visible in one file rather than split across a macro and a recipe.
PARENT_V="$(printf '%s' "$VERSION" | cut -d. -f1-3)"

EXACT="$REPO/cuts/v${VERSION}/cut.env"
CUT_ENV="$EXACT"

if [ ! -f "$CUT_ENV" ]; then
    PARENT="$REPO/cuts/v${PARENT_V}/cut.env"
    if [ "$PARENT" != "$EXACT" ] && [ -f "$PARENT" ]; then
        # The load-bearing line. If this never prints, a hotfix silently ships
        # against its parent's daemon pin and the cut looks clean.
        printf '[WARN] no cut record for v%s; falling back to v%s\n' "$VERSION" "$PARENT_V" >&2
        printf '[WARN]   wanted: %s\n' "$EXACT" >&2
        printf '[WARN]   using:  %s\n' "$PARENT" >&2
        printf '[WARN] if this hotfix re-pinned the daemon, that pin is NOT the one being read\n' >&2
    fi
    CUT_ENV="$PARENT"
fi

printf '[CHECK] daemon operand from %s\n' "$CUT_ENV" >&2

grep -E '^[[:space:]]*DAEMON_COMMIT=' "$CUT_ENV" 2>/dev/null \
    | tail -1 \
    | sed -E 's/^[[:space:]]*DAEMON_COMMIT=//; s/[[:space:]]*(#.*)?$//'
exit 0
