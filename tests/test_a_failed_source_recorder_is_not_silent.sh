#!/usr/bin/env bash
# A recorder that DIED must not look like a source that was never asked to run.
#
# 🔴 WHY. install.sh calls _hydrate_record_fda_extract with `|| true`. Keeping
# the install alive when the RECORDER dies is CORRECT -- a bookkeeping failure
# must not abort a customer's install -- but `|| true` also discarded the fact
# that it died. A recorder that failed leaves NO row, and the Doctor's "Where
# your data came from" panel renders a missing row exactly like a source that
# was never asked to run.
#
# Those two states print identically to the customer and only one of them is a
# real absence. Same shape as the walk seed marker: an outcome computed, then
# thrown away on the line that produced it.
#
# WHAT IS ASSERTED: the REAL block, lifted from install.sh by its own marker,
# never a re-typed copy. A copy would prove a copy correct and say nothing
# about what ships.
#
# THREE STATES: 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL="${REPO}/install.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { printf 'VERDICT: CANNOT-RUN -- %s\n' "$1" >&2; exit 2; }

[ -f "${INSTALL}" ] || cant "install.sh is not at ${INSTALL}"

# LIFT THE REAL BLOCK. Anchored on the assignment and the unset that close it,
# so a rename or a move is a clean CANNOT-RUN rather than a silent miss.
BLOCK="$(awk '/^_hydrate_fda_extract_record_rc=0$/,/^unset _hydrate_fda_extract_record_rc$/' "${INSTALL}")"
if [ -z "${BLOCK}" ]; then
    cant "could not lift the recorder block from install.sh by its markers. It has been renamed or removed, so this gate has no subject and is NOT passing."
fi
printf -- '-- lifted %d line(s) of the REAL block from install.sh --\n' "$(printf '%s\n' "${BLOCK}" | wc -l | tr -d ' ')"

run_block() {   # $1 = rc the recorder should return
    local rc="$1"
    /bin/bash -c '
        warn() { printf "WARN: %s\n" "$*"; }
        _hydrate_record_fda_extract() { return '"${rc}"'; }
        '"${BLOCK}"'
        printf "BLOCK_EXIT=%s\n" "$?"
    ' 2>&1
}

# (1) MUST-MISS. A recorder that SUCCEEDS must say nothing.
out_ok="$(run_block 0)"
if printf '%s' "${out_ok}" | grep -q '^WARN:'; then
    bad "a SUCCESSFUL recorder produced a warning, so the warning carries no information"
else
    ok "a successful recorder is silent"
fi

# (2) MUST-HIT. A recorder that DIES must say so.
out_bad="$(run_block 3)"
if printf '%s' "${out_bad}" | grep -q '^WARN:.*recorder exited 3'; then
    ok "a recorder that exits 3 is REPORTED, with its exit code"
else
    bad "a recorder that exited 3 produced no warning naming it. Output was: ${out_bad}"
fi

# (3) THE WARNING MUST NAME THE CONSEQUENCE, not just the failure. "Something
# failed" sends a reader nowhere; naming the panel tells them what to check.
if printf '%s' "${out_bad}" | grep -qi 'missing'; then
    ok "the warning names the CONSEQUENCE, that rows may be missing rather than reporting a state"
else
    bad "the warning does not say what the failure costs the customer"
fi

# (4) THE INSTALL MUST NOT DIE. This is the whole reason the || true was there,
# and a fix that turns a bookkeeping failure into an aborted install would be a
# worse defect than the one it closes.
if printf '%s' "${out_bad}" | grep -q 'BLOCK_EXIT=0'; then
    ok "CONTROL: the block still exits 0 on a recorder failure, so the install is not aborted"
else
    bad "the block exited non-zero on a recorder failure. A bookkeeping failure must never abort a customer's install."
fi

# (5) MUTATION ARM. Pin the PRE-FIX form against the same stub: `|| true`
# swallows the rc and emits nothing. If this ever stops being silent, the arms
# above are passing for a reason unrelated to this fix.
old_out="$(/bin/bash -c '
    warn() { printf "WARN: %s\n" "$*"; }
    _hydrate_record_fda_extract() { return 3; }
    _hydrate_record_fda_extract || true
    printf "BLOCK_EXIT=%s\n" "$?"
' 2>&1)"
if printf '%s' "${old_out}" | grep -q '^WARN:'; then
    bad "MUTATION ARM: the pre-fix form warned, so this fixture no longer reproduces the defect and arms (2) and (3) prove nothing"
else
    ok "MUTATION ARM: the pre-fix '|| true' form is SILENT on the same failure, which is the defect this closes"
fi

echo
echo "== ${pass} pass / ${fail} fail / $((pass+fail)) total =="
[ "${fail}" -eq 0 ]
