#!/usr/bin/env bash
# Sanity test for the Phase 4 ostler-assistant doctor probe added in
# piece D of /tmp/tnm_brief_zeroclaw_cron_diagnosis_2026-05-02.md.
#
# Asserts:
#   1. install.sh parses (`bash -n`)
#   2. The doctor-probe block is present
#   3. The block is non-fatal: it does NOT set HEALTHY=false on a
#      doctor invocation failure or on observed errors. (Andy's
#      clarification: install must not fail just because the daemon
#      is still in startup grace -- the operator can re-run
#      `ostler-assistant doctor` after first launch.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${SCRIPT_DIR}/../install.sh"

if [[ ! -f "$INSTALL_SH" ]]; then
    printf 'FAIL: install.sh not found at %s\n' "$INSTALL_SH" >&2
    exit 1
fi

# 1. Parse check
if ! bash -n "$INSTALL_SH"; then
    printf 'FAIL: install.sh fails bash -n parse check\n' >&2
    exit 1
fi
printf 'PASS: install.sh parses\n'

# 2. Doctor probe block present
if ! grep -q 'ostler-assistant doctor probe' "$INSTALL_SH"; then
    printf 'FAIL: doctor probe block not found in install.sh\n' >&2
    exit 1
fi
printf 'PASS: doctor probe block present\n'

# 3. Non-fatal property: the new block must not flip HEALTHY to false.
# Extract the lines of the doctor-probe block and confirm none of
# them contain HEALTHY=false. We bound the block by the comment
# header and the next "──" comment delimiter.
BLOCK=$(awk '
    /ostler-assistant doctor probe/ { in_block=1 }
    in_block && /Show recovery key/ { exit }
    in_block { print }
' "$INSTALL_SH")

if [[ -z "$BLOCK" ]]; then
    printf 'FAIL: could not extract doctor probe block\n' >&2
    exit 1
fi

if printf '%s\n' "$BLOCK" | grep -q 'HEALTHY=false'; then
    printf 'FAIL: doctor probe block sets HEALTHY=false (must be non-fatal)\n' >&2
    printf '%s\n' "$BLOCK" | grep -n 'HEALTHY=false' >&2
    exit 1
fi
printf 'PASS: doctor probe block is non-fatal (does not flip HEALTHY)\n'

# 4. Deferred-on-failure path is wired
if ! printf '%s\n' "$BLOCK" | grep -q 'deferred (daemon may still be'; then
    printf 'FAIL: doctor probe block missing deferred-on-failure log\n' >&2
    exit 1
fi
printf 'PASS: deferred-on-failure log present\n'

# 5. timeout invocation is present (10s upper bound)
if ! printf '%s\n' "$BLOCK" | grep -q 'timeout 10'; then
    printf 'FAIL: doctor probe block missing timeout 10s guard\n' >&2
    exit 1
fi
printf 'PASS: timeout 10s guard present\n'

printf '\nAll doctor-probe sanity assertions passed (5/5)\n'
