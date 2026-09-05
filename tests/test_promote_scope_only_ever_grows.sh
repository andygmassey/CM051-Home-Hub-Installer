#!/usr/bin/env bash
# THE BLOCKING SET IS A ONE-WAY RATCHET. A PROBE MAY NEVER MOVE blocking -> advisory.
#
# WHY THIS EXISTS. scripts/walk_promote_scope.tsv decides which probes can refuse a
# promote. That file is the single point at which the promote gate could be defeated
# without anyone editing a gate: move the failing probe to `advisory` and the release
# ships. This test makes that edit fail CI.
#
# ⚠️ THE DIRECTION IS THE WHOLE POINT.
#   advisory -> blocking   ALLOWED, and is the intended direction of travel. Andy's
#                          2026-09-05 decision was explicit that advisory rows get
#                          CLOSED and promoted, not that advisory is where reds live.
#   blocking -> advisory   REFUSED. Always. Including for a probe that is red today
#                          and inconvenient today, which is exactly when it will be
#                          proposed.
#   a NEW row              ALLOWED in either scope -- it did not previously constrain
#                          anything, and the gate treats an undeclared probe as
#                          blocking anyway.
#   a DELETED row          REFUSED if it was blocking: deleting the row is
#                          indistinguishable in effect from demoting it, except that
#                          the gate's fail-closed arm catches it at promote time
#                          instead of here.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCOPE_REL="scripts/walk_promote_scope.tsv"
BASE_REF="${BASE_REF:-origin/main}"

[ -r "${ROOT}/${SCOPE_REL}" ] || { printf 'CANNOT-RUN: %s is not readable.\n' "$SCOPE_REL" >&2; exit 2; }

_blocking() { awk -F'\t' '!/^#/ && NF==4 && $1!="probe" && $2=="blocking" {print $1}' | sort; }

HEAD_SET="$(_blocking < "${ROOT}/${SCOPE_REL}")"
HEAD_N="$(printf '%s' "$HEAD_SET" | grep -c . || true)"

# A first-introduction commit has no base file. That is not a violation, but it must
# not read as a silent pass either, so it is announced.
if ! git -C "$ROOT" cat-file -e "${BASE_REF}:${SCOPE_REL}" 2>/dev/null; then
    git -C "$ROOT" fetch --depth=1 origin "${BASE_REF#origin/}" >/dev/null 2>&1 || true
fi
if ! BASE_RAW="$(git -C "$ROOT" show "${BASE_REF}:${SCOPE_REL}" 2>/dev/null)"; then
    printf '  %s does not exist on %s -- this is its introduction.\n' "$SCOPE_REL" "$BASE_REF"
    printf '  HEAD blocking set: %s probe(s). Nothing to ratchet against yet.\n' "$HEAD_N"
    printf 'PASS: first introduction, %s blocking.\n' "$HEAD_N"
    exit 0
fi

BASE_SET="$(printf '%s\n' "$BASE_RAW" | _blocking)"
BASE_N="$(printf '%s' "$BASE_SET" | grep -c . || true)"

printf '  base(%s) blocking = %s\n' "$BASE_REF" "$BASE_N"
printf '  HEAD        blocking = %s\n\n' "$HEAD_N"

# A blocking probe that is no longer blocking: demoted, or its row deleted.
LOST="$(comm -23 <(printf '%s\n' "$BASE_SET") <(printf '%s\n' "$HEAD_SET") | grep -v '^$' || true)"

if [ -n "$LOST" ]; then
    printf 'FAIL: %s probe(s) LEFT the blocking set.\n' "$(printf '%s' "$LOST" | grep -c .)" >&2
    printf '%s\n' "$LOST" | sed 's/^/      - /' >&2
    printf '\n' >&2
    printf '      A probe may move advisory -> blocking, never the reverse. Moving one\n' >&2
    printf '      back is how this file becomes a way to ship past the gate that is\n' >&2
    printf '      currently refusing: the probe that is red today is exactly the probe\n' >&2
    printf '      someone will propose demoting.\n' >&2
    printf '      If a probe genuinely does not describe the artefact, say so in the\n' >&2
    printf '      review and get Andy to say so too. Do not do it in a diff.\n' >&2
    exit 1
fi

GAINED="$(comm -13 <(printf '%s\n' "$BASE_SET") <(printf '%s\n' "$HEAD_SET") | grep -v '^$' || true)"
if [ -n "$GAINED" ]; then
    printf 'PASS: blocking set GREW by %s.\n' "$(printf '%s' "$GAINED" | grep -c .)"
    printf '%s\n' "$GAINED" | sed 's/^/      + /'
    exit 0
fi

printf 'PASS: blocking set unchanged at %s (never shrunk).\n' "$HEAD_N"
exit 0
