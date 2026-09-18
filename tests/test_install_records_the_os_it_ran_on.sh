#!/bin/bash
# The installer must leave a record of the OS it installed onto.
#
# WHY. Measured 2026-09-18 on install.sh: MACOS_VERSION had FOUR uses and not
# one of them wrote it anywhere. The installer detected the OS, gated on it,
# printed it to the terminal, and threw it away. The moment an install
# finished, the box could not say what it had been installed onto.
#
# That matters because three macOS 27 changes fail SILENTLY on a box where
# every step passed: cross-team container reads denied without a prompt, the
# relocated TCC store, and Local Network enforcement moved to Network
# Extension. None raises; each produces an empty result. The first question
# about any such report is what the customer was running.
#
# THIS TEST DRIVES THE REAL BLOCK, extracted from install.sh by its own
# markers so it cannot drift from the shipped code, with a stubbed sw_vers and
# a temp HOME, and locks:
#
#   1  WRITES     the block writes state/os_at_install.tsv with os_version,
#                 os_version_source, os_build and arch.
#   2  MEASURED   os_version_source reads measured(...), which is the walk
#                 record's convention for "observed, not asserted".
#   3  VALUE      the recorded os_version is the one sw_vers returned, not a
#                 constant. Stub two different versions, get two different
#                 files.
#   4  ORDER      the block sits BEFORE the floor check in install.sh. An
#                 install that aborts because the OS is too old is exactly the
#                 case where the OS is the answer, so the record must exist
#                 before the refusal.
#   5  CONTROL    the PRE-FIX state, which is the same extraction with the
#                 write removed, run through the SAME harness -> writes no
#                 file. This is what proves the harness can tell the fix from
#                 the bug rather than passing on anything.
#   6  MUTANT     the block with its source field hard-coded to an assertion
#                 -> arm 2 must fail. Proves arm 2 reads the value rather than
#                 the field's presence.
#   7  SURVIVES   a read-only state dir must not abort the install. Best
#                 effort: failing to record is never worse than not installing.
#
# Exit: 0 all cases passed, 1 a case failed, 2 could not run.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
BEGIN_MARK='# ── RECORD THE OS THE BOX ACTUALLY RAN, BEFORE THE FLOOR CHECK ────────'
END_MARK='unset _OS_STATE_DIR'

pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail+1)); }
cannot(){ echo "CANNOT-RUN: $1" >&2; exit 2; }

[ -f "$INSTALL_SH" ] || cannot "install.sh not found at ${INSTALL_SH}"

# ── extract the real block ───────────────────────────────────────────────────
# By marker, not by line number: a line number drifts the moment anything above
# it changes, and would then silently extract the wrong text.
BLOCK="$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" \
    'index($0,b){f=1} f{print} f&&index($0,e){exit}' "$INSTALL_SH")"
[ -n "$BLOCK" ] || cannot "could not extract the OS-record block from install.sh (markers changed?)"
printf '%s' "$BLOCK" | grep -q 'os_at_install.tsv' \
    || cannot "extracted block does not mention os_at_install.tsv; extraction is wrong"

# ── harness: run a block with a stubbed sw_vers and a temp HOME ──────────────
run_block() {
    local block="$1" ver="$2" home; home="$(mktemp -d)"
    local stub="${home}/stub"; mkdir -p "$stub"
    cat > "${stub}/sw_vers" <<STUB
#!/bin/bash
case "\$1" in
  -productVersion) echo "${ver}" ;;
  -buildVersion)   echo "99A1234" ;;
  *)               echo "${ver}" ;;
esac
STUB
    chmod +x "${stub}/sw_vers"
    (
        export PATH="${stub}:${PATH}"
        export HOME="$home"
        unset OSTLER_DIR
        MACOS_VERSION="$(sw_vers -productVersion)"
        MACOS_MAJOR="${MACOS_VERSION%%.*}"
        ok() { :; }          # install.sh's printer, stubbed silent
        MSG_OK_MACOS_DETECTED='%s'
        eval "$block"
    ) >/dev/null 2>&1
    printf '%s' "$home"
}

# 1 + 2 + 3: writes, measured, and the value is the stubbed one
H1="$(run_block "$BLOCK" "27.0")"
REC="${H1}/.ostler/state/os_at_install.tsv"
if [ -f "$REC" ]; then ok "1 WRITES     state/os_at_install.tsv exists"; else bad "1 WRITES     no file at ${REC}"; fi

got_ver="$(awk -F'\t' '$1=="os_version"{print $2}' "$REC" 2>/dev/null)"
got_src="$(awk -F'\t' '$1=="os_version_source"{print $2}' "$REC" 2>/dev/null)"
got_bld="$(awk -F'\t' '$1=="os_build"{print $2}' "$REC" 2>/dev/null)"
got_arch="$(awk -F'\t' '$1=="arch"{print $2}' "$REC" 2>/dev/null)"

case "$got_src" in
    measured\(*) ok "2 MEASURED   os_version_source=${got_src}" ;;
    *)           bad "2 MEASURED   os_version_source=${got_src:-<absent>}, wanted measured(...)" ;;
esac

H2="$(run_block "$BLOCK" "26.5.2")"
got2="$(awk -F'\t' '$1=="os_version"{print $2}' "${H2}/.ostler/state/os_at_install.tsv" 2>/dev/null)"
if [ "$got_ver" = "27.0" ] && [ "$got2" = "26.5.2" ]; then
    ok "3 VALUE      two stubs gave two values (27.0 / 26.5.2), not a constant"
else
    bad "3 VALUE      got '${got_ver:-<none>}' and '${got2:-<none>}', wanted 27.0 and 26.5.2"
fi
[ -n "$got_bld" ] && [ -n "$got_arch" ] \
    && ok "3b FIELDS    os_build=${got_bld} arch=${got_arch} both recorded" \
    || bad "3b FIELDS    os_build or arch missing"

# 4: ORDER. The record must be written before the floor check refuses.
rec_line="$(grep -n "$BEGIN_MARK" "$INSTALL_SH" | head -1 | cut -d: -f1)"
floor_line="$(grep -n 'ERR-02-PREREQ-MACOS-OLD' "$INSTALL_SH" | head -1 | cut -d: -f1)"
if [ -n "$rec_line" ] && [ -n "$floor_line" ] && [ "$rec_line" -lt "$floor_line" ]; then
    ok "4 ORDER      record at line ${rec_line} precedes the floor refusal at ${floor_line}"
else
    bad "4 ORDER      record ${rec_line:-?} does not precede floor refusal ${floor_line:-?}"
fi

# 5: CONTROL. The pre-fix state wrote nothing. Same harness, write removed.
CONTROL_BLOCK="$(printf '%s' "$BLOCK" | grep -v 'os_at_install.tsv')"
H3="$(run_block "$CONTROL_BLOCK" "27.0")"
if [ -f "${H3}/.ostler/state/os_at_install.tsv" ]; then
    bad "5 CONTROL    the pre-fix block wrote a record; the harness cannot tell fix from bug"
else
    ok "5 CONTROL    the pre-fix block writes nothing, so arm 1 is attributable"
fi

# 6: MUTANT. Hard-code the source to an assertion; arm 2 must stop passing.
MUTANT="$(printf '%s' "$BLOCK" | sed "s/'measured(sw_vers -productVersion)'/'asserted(hard-coded)'/")"
H4="$(run_block "$MUTANT" "27.0")"
mut_src="$(awk -F'\t' '$1=="os_version_source"{print $2}' "${H4}/.ostler/state/os_at_install.tsv" 2>/dev/null)"
case "$mut_src" in
    measured\(*) bad "6 MUTANT     mutant still reads measured(); arm 2 is not reading the value" ;;
    "")          bad "6 MUTANT     mutant produced no source field; mutation did not apply" ;;
    *)           ok  "6 MUTANT     mutant reads ${mut_src}, so arm 2 discriminates" ;;
esac

# 7: SURVIVES. A read-only state dir must not abort.
H5="$(mktemp -d)"; mkdir -p "${H5}/.ostler"; chmod 500 "${H5}/.ostler"
(
    export HOME="$H5"; unset OSTLER_DIR
    MACOS_VERSION="27.0"; MACOS_MAJOR="27"
    eval "$BLOCK"
) >/dev/null 2>&1
rc=$?
chmod 700 "${H5}/.ostler" 2>/dev/null
[ "$rc" -eq 0 ] && ok "7 SURVIVES   a read-only state dir returns 0, the install is not aborted" \
                || bad "7 SURVIVES   returned ${rc}; failing to record must never be worse than not installing"

rm -rf "$H1" "$H2" "$H3" "$H4" "$H5" 2>/dev/null

echo
echo "EXAMINED: $((pass+fail)) cases, ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
