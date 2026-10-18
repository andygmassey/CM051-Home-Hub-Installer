#!/bin/bash
# The customer's forward calendar window must survive the hourly re-run.
# BOARD ROW 997.
#
# extract_all.py reads OSTLER_CALENDAR_FUTURE_DAYS and defaults it to 30. The
# installer's calendar hydrate uses 365, but reaches that value by interpolating
# a DIFFERENTLY NAMED variable (OSTLER_HYDRATE_CALENDAR_FUTURE_DAYS) into its own
# heredoc, so the reader's name was never set anywhere. ${OSTLER_DIR}/bin/ostler-fda
# is driven by the com.ostler.fda-rerun LaunchAgent, inherits nothing, and calls
# run_all(), which rewrites calendar_events.json. So 365 became 30 on the first
# tick after installing and stayed there.
#
# TWO SITES, BOTH ASSERTED, because fixing either alone leaves the other wrong:
#   the Phase 3 extract's env-prefix stack
#   the re-run wrapper, which is what does the hourly damage
#
# The wrapper arm DRIVES the real prologue lifted BY MARKER rather than reading
# it, with a MUTANT that removes the export and must fall back to the library
# default.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${REPO}/install.sh"
READER="${REPO}/vendor/ostler_fda/extract_all.py"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cant(){ printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

[ -r "$INSTALL" ] || cant "install.sh unreadable"
[ -r "$READER" ]  || cant "vendor/ostler_fda/extract_all.py unreadable, so the reader's name cannot be confirmed"

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# --- 0. the reader's name and default, taken from the reader ---
VAR="$(grep -oE '_env_days\("OSTLER_CALENDAR_FUTURE_DAYS", *[0-9]+\)' "$READER" | head -1)"
if [ -z "$VAR" ]; then
    cant "extract_all.py no longer reads OSTLER_CALENDAR_FUTURE_DAYS with a numeric default; this gate is asserting about code that has moved"
fi
LIB_DEFAULT="$(printf '%s' "$VAR" | grep -oE '[0-9]+')"
printf '     EXAMINED: the reader asks for OSTLER_CALENDAR_FUTURE_DAYS, library default %s\n' "$LIB_DEFAULT"
[ "$LIB_DEFAULT" = "30" ] || printf '     [note] library default is %s, not the 30 this row was filed against\n' "$LIB_DEFAULT"

# --- 1. site one: the Phase 3 env-prefix stack ---
if grep -qE '^\s+OSTLER_CALENDAR_FUTURE_DAYS="\$\{OSTLER_HYDRATE_CALENDAR_FUTURE_DAYS:-[0-9]+\}" \\$' "$INSTALL"; then
    ok "site 1: the Phase 3 extract passes the READER's variable name"
else
    bad "site 1: the Phase 3 extract does not pass OSTLER_CALENDAR_FUTURE_DAYS, so the install-time extract uses the library default"
fi
# CONTROL: a sibling that has always worked must match the same shape, or the
# predicate above is simply wrong about how these are passed.
if grep -qE '^\s+OSTLER_MAIL_BACKFILL_DAYS="\$\{OSTLER_MAIL_BACKFILL_DAYS\}" \\$' "$INSTALL"; then
    ok "CONTROL: a working sibling matches the same env-prefix shape, so the test above is looking in the right place"
else
    bad "CONTROL: the sibling env-prefix shape was not found, so site 1's predicate is unanchored and its result means nothing"
fi

# --- 2. site two: DRIVE the re-run wrapper's prologue ---
# LIFTED BETWEEN TWO MARKERS THAT EXIST IN BOTH THE FIXED AND THE UNFIXED FILE,
# so that a MISSING FIX is a FAIL and only a MOVED WRAPPER is a CANNOT-RUN.
# Anchoring the end on the export line itself would make the defect and a
# broken instrument print the same verdict, which is the thing this whole board
# keeps getting wrong.
PROLOGUE="${WORK}/prologue.sh"
awk '/^cat > "\$\{OSTLER_DIR\}\/bin\/ostler-fda" <</{f=1; next}
     f&&/^if \[\[ ! -d "\$FDA_DIR\/ostler_fda" \]\]; then/{exit}
     f{print}' "$INSTALL" > "$PROLOGUE"

if [ ! -s "$PROLOGUE" ] || ! grep -q 'OSTLER_PYTHON=' "$PROLOGUE"; then
    cant "the ostler-fda wrapper prologue could not be lifted between its two structural markers, so this gate read nothing. That is an instrument failure, NOT a verdict about the window."
fi

drive() {  # drive <prologue> -> prints the value the reader would see
    local pro="$1" d="${WORK}/d.$$.$RANDOM"
    mkdir -p "$d"
    { printf 'HOME=%q\n' "$d"; cat "$pro"
      printf '\nprintf "%%s" "${OSTLER_CALENDAR_FUTURE_DAYS:-UNSET}"\n'; } > "${d}/run.sh"
    bash "${d}/run.sh" 2>/dev/null
}

got="$(drive "$PROLOGUE")"
if [ "$got" = "365" ]; then
    ok "site 2: the re-run wrapper exports 365, so the hourly tick keeps the customer's forward window"
else
    bad "site 2: the re-run wrapper leaves the reader seeing '${got}', so the forward window is clawed back to the library default on the first tick"
fi

# an operator override must still win
d2="${WORK}/ovr"; mkdir -p "$d2"
{ printf 'HOME=%q\nexport OSTLER_CALENDAR_FUTURE_DAYS=90\n' "$d2"; cat "$PROLOGUE"
  printf '\nprintf "%%s" "${OSTLER_CALENDAR_FUTURE_DAYS}"\n'; } > "${d2}/run.sh"
ovr="$(bash "${d2}/run.sh" 2>/dev/null)"
[ "$ovr" = "90" ] && ok "an operator's own value still wins, so this pins a default and not a policy" \
                  || bad "an operator's exported value was overwritten (saw '${ovr}'), which removes an affordance the wrapper documents"

# --- 3. MUTANT: remove the export and the window must collapse ---
MUT="${WORK}/mutant.sh"
grep -v '^export OSTLER_CALENDAR_FUTURE_DAYS=' "$PROLOGUE" > "$MUT"
mgot="$(drive "$MUT")"
if [ "$mgot" = "UNSET" ]; then
    ok "MUTANT: without the export the reader sees nothing and falls back to ${LIB_DEFAULT}, so the arm above discriminates"
else
    bad "MUTANT: the value survived removal of the export (saw '${mgot}'), so this test cannot tell the fix from the defect"
fi

echo
printf '== %d pass / %d fail ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
