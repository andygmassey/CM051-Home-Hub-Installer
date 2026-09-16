#!/usr/bin/env bash
# Row #1765. THE MIGRATOR SHIPS AND THE CALLER LOOKED SOMEWHERE ELSE.
#
# THE SUBJECT OF EVERY ASSERTION HERE IS A PERSON: does the customer's graph
# actually get migrated, and when it cannot be, are they told in a way that
# survives the next reboot. Not whether a string exists in a file.
#
# WHAT WAS WRONG, MEASURED ON main BEFORE THE FIX:
#
#   install.sh    _ns_migrate_script="${OSTLER_DIR:-$PWD}/scripts/migrate_graph_namespace.py"
#   ${OSTLER_DIR}/scripts    1 occurrence in install.sh, the read above.
#                            Nothing creates that directory, ever.
#   ${OSTLER_DIR}/bin       61 occurrences. CONTROL: the pattern is not blind
#                            to a real ${OSTLER_DIR} subdirectory.
#   gui/project.yml         DOES copy migrate_graph_namespace.py into the .app,
#                            into Resources/scripts, which install.sh reads
#                            as ${SCRIPT_DIR}/scripts for its sibling
#                            deferred-register-device.sh.
#
# So the file was in the DMG, the guard was false on every box, and the
# migration has never run for any customer. The earlier fix added a caller and
# pointed it at a directory that does not exist, which is the same defect one
# layer along.
#
# THE CODE UNDER TEST IS EXTRACTED FROM install.sh AT RUN TIME, never copied,
# so this test rots the moment the real file stops matching it.
#
# THREE STATES: 0 pass, 1 fail, 2 cannot-run. CANNOT-RUN exits non-zero and is
# never reported as a pass.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PROJECT_YML="${REPO}/gui/project.yml"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

[ -r "$SUBJECT" ]     || cant "install.sh not readable at ${SUBJECT}"
[ -r "$PROJECT_YML" ] || cant "gui/project.yml not readable at ${PROJECT_YML}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ns1765-XXXXXX")" || cant "mktemp"
trap 'rm -rf "$WORK"' EXIT

# ── EXTRACT THE REAL BLOCK ───────────────────────────────────────────────
# From the resolver's first line to the unset that closes it.
# The anchor is deliberately LOOSE (any ^_ns_migrate_script= assignment, not
# the exact post-fix spelling). An anchor that only matches the fixed shape
# turns every regression into a CANNOT-RUN, and "could not look" must not be
# how a gate reports "you broke it".
BLOCK="$(awk '/^_ns_migrate_script=/{f=1} f{print} f&&/^unset _ns_migrate_script/{exit}' "$SUBJECT")"
BLOCK_LINES="$(printf '%s\n' "$BLOCK" | grep -c . || true)"
printf 'EXAMINED: %s lines of the namespace-migration block, extracted from %s\n' \
    "$BLOCK_LINES" "$SUBJECT"
# A DENOMINATOR. An empty extraction would make every arm below pass over
# nothing, which is the zero-denominator shape. Refuse rather than report green.
if [ "${BLOCK_LINES:-0}" -lt 20 ]; then
    cant "extracted only ${BLOCK_LINES} lines; every arm would be measuring an empty subject"
fi

# How many candidate paths does the shipped block actually search? Printed as
# the denominator for the "every path is named" arm below.
CANDIDATES="$(printf '%s\n' "$BLOCK" | grep -cE '^    "\$\{(SCRIPT_DIR|OSTLER_DIR)[^"]*/scripts/migrate_graph_namespace\.py"' || true)"
printf 'EXAMINED: %s candidate path(s) in the shipped resolver loop\n' "$CANDIDATES"

# ── THE HARNESS ──────────────────────────────────────────────────────────
# $1 dir holding a payload copy under scripts/ ("" = none)   -> becomes SCRIPT_DIR
# $2 dir holding a payload copy under scripts/ ("" = none)   -> becomes OSTLER_DIR
# $3 exit code the stub migrator returns
# $4 the block to run (the real one, or a mutant)
#
# The stub python3 APPENDS the script path it was handed to a witness file.
# That file is the evidence a migration actually happened: an empty witness
# means nothing ran, and it is read as such rather than inferred from prose.
run_arm() {
    local sd_src="$1" od_src="$2" rc="$3" block="$4"
    local d; d="$(mktemp -d "${WORK}/arm-XXXXXX")"
    mkdir -p "${d}/sd" "${d}/od" "${d}/diag" "${d}/bin"
    [ -n "$sd_src" ] && { mkdir -p "${d}/sd/scripts"; printf 'stub\n' > "${d}/sd/scripts/migrate_graph_namespace.py"; }
    [ -n "$od_src" ] && { mkdir -p "${d}/od/scripts"; printf 'stub\n' > "${d}/od/scripts/migrate_graph_namespace.py"; }
    cat > "${d}/bin/python3" <<STUBPY
#!/bin/sh
printf '%s\n' "\$1" >> "${d}/ran.witness"
exit ${rc}
STUBPY
    chmod +x "${d}/bin/python3"
    : > "${d}/ran.witness"
    {
        printf '%s\n' 'set -uo pipefail'
        printf 'SCRIPT_DIR=%q\n' "${d}/sd"
        printf 'OSTLER_DIR=%q\n' "${d}/od"
        printf 'OSTLER_DIAG_DIR=%q\n' "${d}/diag"
        printf 'PATH=%q:$PATH\n' "${d}/bin"
        printf '%s\n' 'info() { printf "INFO %s\n" "$*"; }'
        printf '%s\n' 'ok()   { printf "OK %s\n"   "$*"; }'
        printf '%s\n' 'warn() { printf "WARN %s\n" "$*"; }'
        printf '%s\n' '_ostler_persist_diagnostics() { printf "DIAG_PERSISTED\n"; }'
        printf '%s\n' "$block"
    } > "${d}/arm.sh"
    bash "${d}/arm.sh" 2>&1
    printf 'WITNESS_COUNT=%s\n' "$(grep -c . "${d}/ran.witness" || true)"
    printf 'WITNESS_PATH=%s\n' "$(head -1 "${d}/ran.witness" 2>/dev/null || true)"
}

echo
echo "== the customer's graph actually gets migrated =="

out="$(run_arm payload "" 0 "$BLOCK")"
if printf '%s' "$out" | grep -q '^WITNESS_COUNT=1$'; then
    ok "(1) the migrator SHIPPED in the .app payload was found and RUN (witness count 1 of 1 expected)"
else
    bad "(1) the payload copy was never executed. $(printf '%s' "$out" | grep '^WITNESS_COUNT=')"
fi
if printf '%s' "$out" | grep -q '^WITNESS_PATH=.*/sd/scripts/migrate_graph_namespace\.py$'; then
    ok "(2) and it ran the PAYLOAD copy, not something else"
else
    bad "(2) ran a path that is not the payload copy: $(printf '%s' "$out" | grep '^WITNESS_PATH=')"
fi
printf '%s' "$out" | grep -q 'OK Graph identifiers are current' \
  && ok  "(3) the customer is told their identifiers are current" \
  || bad "(3) a successful migration told the customer nothing"

out="$(run_arm "" payload 0 "$BLOCK")"
printf '%s' "$out" | grep -q '^WITNESS_COUNT=1$' \
  && ok  "(4) the legacy ~/.ostler/scripts location still works, so a hand-repaired box is not broken by this change" \
  || bad "(4) the fallback path was dropped; a box that has the file under ~/.ostler no longer migrates"

echo
echo "== when it genuinely is not there, the customer is told LOUDLY =="

out="$(run_arm "" "" 0 "$BLOCK")"
printf '%s' "$out" | grep -q '^WITNESS_COUNT=0$' \
  && ok  "(5) NEGATIVE CONTROL: with no payload anywhere the witness is empty, so arms 1 and 4 measured a real execution" \
  || bad "(5) the witness recorded a run with nothing to run, so arms 1 and 4 prove nothing"
printf '%s' "$out" | grep -q 'WARN .*DID NOT RUN' \
  && ok  "(6) the miss is stated as DID NOT RUN, not as a skip" \
  || bad "(6) the miss is still quiet or hedged: $(printf '%s' "$out" | grep '^WARN' || echo '<no warn at all>')"
printf '%s' "$out" | grep -q 'DIAG_PERSISTED' \
  && ok  "(7) the diagnostics bundle is KEPT before the path is named, so the log still exists tomorrow" \
  || bad "(7) the warning names a purgeable path it never persisted"

named=0
printf '%s' "$out" | grep -q 'WARN .*/sd/scripts/migrate_graph_namespace\.py' && named=$((named+1))
printf '%s' "$out" | grep -q 'WARN .*/od/scripts/migrate_graph_namespace\.py' && named=$((named+1))
[ "$named" -eq 2 ] \
  && ok  "(8) EVERY candidate path is named in the miss (${named} of ${CANDIDATES} searched)" \
  || bad "(8) only ${named} of ${CANDIDATES} searched paths were named; an operator is sent to the wrong place"

echo
echo "== what a customer is told when the migration goes wrong =="
out="$(run_arm payload "" 1 "$BLOCK")"
printf '%s' "$out" | grep -q 'WARN .*part-migrated' \
  && ok  "(9) rc=1 still warns that the store may be part-migrated" \
  || bad "(9) the rc=1 arm no longer reaches the customer"

echo
echo "== the two halves of \"it ships where the caller looks\" =="
grep -q '"\${SCRIPT_DIR}/scripts/migrate_graph_namespace\.py"' "$SUBJECT" \
  && ok  "(10) install.sh probes the payload directory" \
  || bad "(10) install.sh does not probe \${SCRIPT_DIR}/scripts"
grep -q 'cp "\${SRC_NS}" "\${DEST}/scripts/migrate_graph_namespace\.py"' "$PROJECT_YML" \
  && ok  "(11) gui/project.yml copies it into that directory" \
  || bad "(11) nothing bundles the migrator, so the probe above can never be true on a customer Mac"

echo
echo "== MUTATIONS: each must PROVE IT APPLIED before its assertion is scored =="

# M1: the pre-fix world. Drop the payload candidate and keep only the
# ${OSTLER_DIR} one, the exact line main carried for months.
M1="$(printf '%s\n' "$BLOCK" | grep -v '"\${SCRIPT_DIR}/scripts/migrate_graph_namespace\.py" \\')"
if [ "$M1" = "$BLOCK" ]; then
    bad "(M1) MUTANT DID NOT APPLY. The payload candidate line was not found, so the result below would be meaningless"
else
    ok  "(M1a) mutant applied: the payload candidate is gone ($(printf '%s\n' "$BLOCK" | grep -c . ) lines -> $(printf '%s\n' "$M1" | grep -c . ))"
    out="$(run_arm payload "" 0 "$M1")"
    printf '%s' "$out" | grep -q '^WITNESS_COUNT=0$' \
      && ok  "(M1b) PRE-FIX IS CAUGHT: with only the ~/.ostler candidate, a shipped payload is never run" \
      || bad "(M1b) the pre-fix shape still ran the migrator, so arm (1) cannot tell the two apart"
fi

# M2: silence the miss. Delete the persist call from the else arm and assert
# arm (7) goes red.
M2="$(printf '%s\n' "$BLOCK" | awk '{ if ($0 ~ /^    _ostler_persist_diagnostics$/) next; print }')"
if [ "$M2" = "$BLOCK" ]; then
    bad "(M2) MUTANT DID NOT APPLY. No unindented-by-4 _ostler_persist_diagnostics line was found"
else
    ok  "(M2a) mutant applied: the else-arm persist call is gone"
    out="$(run_arm "" "" 0 "$M2")"
    printf '%s' "$out" | grep -q 'DIAG_PERSISTED' \
      && bad "(M2b) removing the persist call changed nothing, so arm (7) is decoration" \
      || ok  "(M2b) arm (7) goes red without the persist call, so it is measuring it"
fi

# M3: name only one path in the miss, the defect the old wording had.
M3="$(printf '%s\n' "$BLOCK" | sed 's/at any of ${_ns_searched}/at ${_ns_migrate_script}/')"
if [ "$M3" = "$BLOCK" ]; then
    bad "(M3) MUTANT DID NOT APPLY. The searched-paths phrase was not found in the warning"
else
    ok  "(M3a) mutant applied: the warning now names one variable instead of the searched list"
    out="$(run_arm "" "" 0 "$M3")"
    printf '%s' "$out" | grep -q 'WARN .*/od/scripts/migrate_graph_namespace\.py' \
      && bad "(M3b) the single-path wording still named a real path, so arm (8) is decoration" \
      || ok  "(M3b) arm (8) goes red on the single-path wording, so it is measuring the named set"
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
