#!/usr/bin/env bash
# ===========================================================================
# An install must leave its diagnostics somewhere that still exists tomorrow.
#
# OSTLER_DIAG_DIR is a mktemp directory under ${TMPDIR:-/tmp}. That is correct
# and this test asserts it stays that way: a shared path would let another user
# pre-create our log files. What was missing is DURABILITY -- nothing copied it
# anywhere, nothing deleted it, and on macOS TMPDIR is /var/folders/<per-user>/T
# which the OS purges on its own schedule.
#
# install.sh names that directory in ~80 places, including three of the loudest
# warnings we ship. The half-migrated-store warning exists to make someone STOP
# AND LOOK, and it cited a file they could not find the next day.
# ===========================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ROOT}/install.sh"
[ -r "$SRC" ] || { printf 'CANNOT-RUN: %s is not readable.\n' "$SRC" >&2; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fails=0
chk() { if [ "$2" -eq 0 ]; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); fi; }

printf 'install diagnostics survive the run\n'

# CONTROL: the privacy property must be intact, or this test is guarding the
# wrong thing entirely.
grep -q 'mktemp -d "${TMPDIR:-/tmp}/ostler-diag-XXXXXX"' "$SRC" \
  || { printf 'CANNOT-RUN: OSTLER_DIAG_DIR is no longer a mktemp under TMPDIR; the subject changed.\n' >&2; exit 2; }
chk "CONTROL: the diag dir is still a private mktemp (unchanged)" 0

grep -q '^_ostler_persist_diagnostics() {' "$SRC" && r=0 || r=1
chk "a persister is defined" "$r"

n_calls="$(grep -c '^[[:space:]]*_ostler_persist_diagnostics$' "$SRC" || true)"
[ "$n_calls" -ge 2 ] && r=0 || r=1
chk "it is called at least twice (end of run + a failure path); found $n_calls" "$r"

# The stop-and-look warning must name the durable copy, not the temp dir.
grep -q 'See ${OSTLER_DIAG_KEPT:-$OSTLER_DIAG_DIR}/ns-migration.log' "$SRC" && r=0 || r=1
chk "the half-migrated-store warning names the durable copy" "$r"

# Bounded extraction. Size-checked, run as its own script, never sourced into
# this harness beyond the function itself.
awk '/^_ostler_persist_diagnostics\(\) \{$/,/^\}$/' "$SRC" > "${WORK}/fn.sh"
n="$(wc -l < "${WORK}/fn.sh" | tr -d ' ')"
if [ "$n" -lt 5 ] || [ "$n" -gt 40 ]; then
    printf 'CANNOT-RUN: extracted %s lines for the persister; its anchors moved.\n' "$n" >&2; exit 2
fi
chk "the persister extracts to a sane size ($n lines)" 0

# BEHAVIOUR 1: a populated diag dir is copied, 0700, and the path is reported.
rm -rf "${WORK}/d" "${WORK}/h"; mkdir -p "${WORK}/d" "${WORK}/h"
printf 'rc=137\n' > "${WORK}/d/ns-migration.log"
kept="$(OSTLER_DIAG_DIR="${WORK}/d" OSTLER_DIR="${WORK}/h/.ostler" \
        bash -c ". '${WORK}/fn.sh'; _ostler_persist_diagnostics; printf '%s' \"\${OSTLER_DIAG_KEPT:-}\"")"
[ -n "$kept" ] && r=0 || r=1
chk "a populated diag dir sets OSTLER_DIAG_KEPT" "$r"
[ -f "${WORK}/h/.ostler/diagnostics"/*/ns-migration.log ] 2>/dev/null && r=0 || r=1
chk "the log is copied under \${OSTLER_DIR}/diagnostics/<stamp>/" "$r"
# GNU FIRST, DELIBERATELY. `stat -f` is VALID on GNU coreutils -- it prints
# FILESYSTEM status -- so a BSD-first probe SUCCEEDS on Linux and returns a
# block-size dump where a mode should be, and the `||` fallback never fires.
# Measured: this test went red on ubuntu-latest with "got   File: ... Type:
# ext2/ext3". BSD stat has no -c, so it errors there and the fallback works.
mode="$(stat -c '%a' "${WORK}/h/.ostler/diagnostics" 2>/dev/null || stat -f '%Lp' "${WORK}/h/.ostler/diagnostics" 2>/dev/null)"
[ "$mode" = "700" ] && r=0 || r=1
chk "the copy is 0700, no more readable than the original (got ${mode:-none})" "$r"

# BEHAVIOUR 2: no diag dir is a silent no-op that cannot fail an install.
rm -rf "${WORK}/h2"; mkdir -p "${WORK}/h2"
OSTLER_DIAG_DIR="${WORK}/nonexistent" OSTLER_DIR="${WORK}/h2/.ostler" \
  bash -c ". '${WORK}/fn.sh'; _ostler_persist_diagnostics" >/dev/null 2>&1 && r=0 || r=1
chk "an absent diag dir is a no-op that returns 0" "$r"
[ -d "${WORK}/h2/.ostler/diagnostics" ] && r=1 || r=0
chk "an absent diag dir creates nothing" "$r"

printf '  examined 10 assertions across 2 runtime outcomes\n'
[ "$fails" -eq 0 ] || { printf 'FAIL: %s assertion(s) failed.\n' "$fails" >&2; exit 1; }
printf 'PASS: the diagnostics outlive the run that produced them.\n'
