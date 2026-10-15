#!/usr/bin/env bash
# The WhatsApp pwg_ingest step must survive a non-zero exit under an armed ERR trap
# =========================================================================
#
# pwg_ingest's CLI now exits 1 when any source reports an error. install.sh
# runs it under `set -Eeuo pipefail` with an ERR trap armed. A bare `set +e`
# does not disarm an ERR trap in bash 3.2, so the trap fired and aborted the
# install. The fix saves the trap, disarms it, and restores it exactly as the
# extract step above it does.
#
# Behavioural: extracts the REAL step from install.sh and runs it with a stub
# python that exits 1, under /bin/bash (3.2 on macOS). Must reach the line
# after the block, record the error, and leave the ERR trap re-armed.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${1:-$REPO_ROOT/install.sh}"
BASH_BIN="${BASH_UNDER_TEST:-/bin/bash}"

start="$(grep -n -- '-m ostler_fda.pwg_ingest' "$INSTALL" | head -1 | cut -d: -f1)"
[ -n "$start" ] || { echo "CANNOT-RUN: pwg_ingest CLI call not found in $INSTALL" >&2; exit 2; }
# Block = the comment-led step: from 12 lines above the call to the first
# `unset _wa_ingest_rc` (or, pre-fix, the call's own line plus 2).
end="$(awk -v s="$start" 'NR>=s && /unset _wa_ingest_rc/ {print NR; exit}' "$INSTALL")"
[ -n "$end" ] || end=$((start + 2))
# One more line when the fix wraps with `set -e; eval` after the unset.
block_start="$(awk -v s="$start" 'NR<=s && /# Step 2: ingest the JSON/ {l=NR} END{print l}' "$INSTALL")"
[ -n "$block_start" ] || { echo "CANNOT-RUN: Step 2 marker not found" >&2; exit 2; }
sed -n "${block_start},$((end + 3))p" "$INSTALL" > "${TMPDIR:-/tmp}/wa_block.$$"
trap 'rm -f "${TMPDIR:-/tmp}/wa_block.$$"' EXIT

# Pre-fix there is no `unset _wa_ingest_rc`; the 3 trailing lines are then the
# call's continuation only, which is exactly the shape to be tested.
cat > "${TMPDIR:-/tmp}/wa_harness.$$" <<HARNESS
set -Eeuo pipefail
trap 'echo ERR_TRAP_FIRED; exit 97' ERR
OSTLER_DIR=/nonexistent
_HYDRATE_WHATSAPP_LOG=/dev/null
_HYDRATE_WHATSAPP_RC=0
warn() { echo "WARN: \$*"; }
MSG_HYDRATE_WHATSAPP_GRAPH_WRITE_FAILED="graph write failed (exit %s) %s"
_stub() { return 1; }
_HYDRATE_WHATSAPP_PY=_stub_py
_stub_py() { return 1; }
# the block starts at the call line; supply the saved/disarmed state install.sh
# has by then (the fix brackets the call itself).
$(cat "${TMPDIR:-/tmp}/wa_block.$$")
echo "REACHED rc=\${_HYDRATE_WHATSAPP_RC}"
trap -p ERR | grep -q ERR_TRAP_FIRED && echo TRAP_REARMED
HARNESS
out="$("$BASH_BIN" "${TMPDIR:-/tmp}/wa_harness.$$" 2>&1)"; rc=$?
rm -f "${TMPDIR:-/tmp}/wa_harness.$$"
echo "$out"
fails=0
grep -q 'ERR_TRAP_FIRED' <<<"$out" && { echo "  FAIL  ERR trap fired: install would abort" >&2; fails=$((fails+1)); }
grep -q 'REACHED rc=1' <<<"$out" || { echo "  FAIL  did not reach the next line with the ingest error recorded (rc=$rc)" >&2; fails=$((fails+1)); }
grep -q 'TRAP_REARMED' <<<"$out" || { echo "  FAIL  ERR trap not restored after the step" >&2; fails=$((fails+1)); }
[ "$fails" -eq 0 ] && echo "  PASS  ingest rc=1 under armed ERR trap: recorded, trap restored ($BASH_BIN)"
exit "$fails"
