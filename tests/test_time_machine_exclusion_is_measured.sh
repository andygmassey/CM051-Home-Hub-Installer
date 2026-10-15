#!/usr/bin/env bash
#
# tests/test_time_machine_exclusion_is_measured.sh
#
# Status-honesty sweep I1 (walk #28 grading, privacy). install.sh set the Time
# Machine exclusion on ~/.ostler (secrets, .env), ~/Documents/Ostler and
# ~/.colima (the plaintext graph) with `tmutil addexclusion ... 2>/dev/null ||
# true` and then printed, unconditionally, that all three "are excluded from
# Spotlight indexing and Time Machine backups". A refused exclusion went to the
# backup disk under a green line.
#
# This RUNS the real helper and the real call site, extracted from install.sh,
# under `set -Eeuo pipefail` (as install.sh runs), against a FAKE tmutil:
#
#   honours     addexclusion works, isexcluded says [Excluded]   (control)
#   refuses     addexclusion errors, isexcluded says [Included]
#   lies        addexclusion exits 0 and changes nothing          (the key case)
#   one-refused only ~/.colima is refused
#
# and then the Doctor's live rule (check_time_machine_exclusion) against the
# same fake. Synthetic paths only, under a scratch HOME.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"
STRINGS="${REPO}/install.sh.strings.en-GB.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
status=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; status=1; }
cannot() { echo "CANNOT RUN: $*" >&2; exit 2; }

# The helpers: from the first helper definition to the end of
# _ostler_harden_at_rest.
awk '/^_ostler_(tm_excluded|harden_at_rest)\(\) \{/{f=1} f{print} f&&/^}/&&h{exit} /^_ostler_harden_at_rest\(\) \{/{h=1}' \
    "$INSTALL_SH" > "$WORK/helpers.sh"
grep -q '^_ostler_harden_at_rest() {' "$WORK/helpers.sh" || cannot "could not extract _ostler_harden_at_rest"
# The call site: from the "Applying at-rest hardening" line to the TRADEOFF note.
awk '/^info "Applying at-rest hardening/{f=1} /^# TRADEOFF/{exit} f{print}' "$INSTALL_SH" > "$WORK/callsite.sh"
grep -q '_ostler_harden_at_rest' "$WORK/callsite.sh" || cannot "could not extract the at-rest call site"

# Fake tmutil. Exclusion is a marker file the fake keeps beside the path.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmutil" <<'TM'
#!/usr/bin/env bash
cmd="$1"; p="$2"; mark="${p%/}.fake-tm-excluded"
refused() { [[ "${FAKE_TM:-}" == refuses ]] || [[ -n "${FAKE_TM_REFUSE:-}" && "$p" == "$FAKE_TM_REFUSE" ]]; }
case "$cmd" in
  addexclusion)
    if refused; then echo "tmutil: addexclusion requires Full Disk Access privileges." >&2; exit 1; fi
    [[ "${FAKE_TM:-}" == lies ]] && exit 0
    : > "$mark"; exit 0 ;;
  isexcluded)
    if [[ "${FAKE_TM:-}" == unknown ]]; then printf '[UNKNOWN]   %s\n' "$p"; exit 0; fi
    if [[ "${FAKE_TM:-}" == errors ]]; then echo "tmutil: could not read the exclusion list." >&2; exit 1; fi
    if [[ -e "$mark" ]]; then printf '[Excluded]  %s\n' "$p"; else printf '[Included]  %s\n' "$p"; fi
    exit 0 ;;
esac
exit 64
TM
chmod +x "$WORK/bin/tmutil"

# The OK lines of an output file, read once into a variable so each match is a
# here-string and no producer can be SIGPIPEd by `grep -q` under pipefail.
ok_lines() { grep '^OK' "$1" || true; }

run_install() {  # run_install <mode> [refuse-path] -> output in $WORK/out.<mode>
    local mode="$1" h="$WORK/home-$1"
    mkdir -p "$h/.ostler" "$h/Documents/Ostler" "$h/.colima"
    cat > "$WORK/run-$mode.sh" <<RUN
set -Eeuo pipefail
trap 'echo "ABORTED at line \$LINENO" >&2' ERR
ok()   { echo "OK: \$*"; }
warn() { echo "WARN: \$*"; }
info() { echo "INFO: \$*"; }
source "$STRINGS"
source "$WORK/helpers.sh"
HOME="$h"; OSTLER_DIR="$h/.ostler"; USER_FACING_ROOT="$h/Documents/Ostler"
source "$WORK/callsite.sh"
echo "REACHED THE END"
RUN
    PATH="$WORK/bin:$PATH" FAKE_TM="$mode" FAKE_TM_REFUSE="${2:-}" bash "$WORK/run-$mode.sh" > "$WORK/out.$mode" 2>&1
    echo "$h"
}

# control: everything honoured
h="$(run_install honours)"
okl="$(ok_lines "$WORK/out.honours")"
if grep -q "REACHED THE END" "$WORK/out.honours" && ! grep -q '^WARN' "$WORK/out.honours" \
   && grep -q "$h/.ostler" <<< "$okl" \
   && grep -q "$h/.colima" <<< "$okl"; then
    pass "honours: all three excluded, one green line naming them, no warning"
else fail "honours (control): $(cat "$WORK/out.honours")"; fi

for mode in refuses lies; do
    h="$(run_install "$mode")"
    out="$WORK/out.$mode"
    if ! grep -q "REACHED THE END" "$out"; then
        fail "$mode: the install aborted instead of reporting: $(tail -3 "$out")"; continue; fi
    okl="$(ok_lines "$out")"
    if grep -qE 'excluded|Time Machine' <<< "$okl"; then
        fail "$mode: a green line claims an exclusion Time Machine does not have: $(grep '^OK' "$out")"
    else pass "$mode: no green line claims an exclusion"; fi
    n="$(grep -c "^WARN: .*NOT excluded" "$out" || true)"
    if [[ "$n" -eq 3 ]] && grep -q "WARN: $h/.ostler is NOT excluded" "$out"; then
        pass "$mode: each of the 3 folders is named in a NOT excluded warning"
    else fail "$mode: expected 3 named warnings, got $n: $(grep '^WARN' "$out")"; fi
done

h="$WORK/home-one-refused"
h="$(run_install one-refused "$h/.colima")"
out="$WORK/out.one-refused"
okl="$(ok_lines "$out")"
if grep -q "$h/.ostler" <<< "$okl" && ! grep -q "$h/.colima" <<< "$okl" \
   && grep -q "WARN: $h/.colima is NOT excluded" "$out" && [[ "$(grep -c '^WARN' "$out")" -eq 1 ]]; then
    pass "one-refused: the green line names the two that held, the warning names the one that did not"
else fail "one-refused: $(cat "$out")"; fi

# tmutil that cannot answer (an [UNKNOWN] reply, or an error): the text must say
# "could not be checked", never the measurement "still includes it".
for mode in unknown errors; do
    h="$(run_install "$mode")"
    out="$WORK/out.$mode"
    if ! grep -q "REACHED THE END" "$out"; then
        fail "$mode: the install aborted instead of reporting: $(tail -3 "$out")"; continue; fi
    n="$(grep -c "^WARN: .*could not be checked" "$out" || true)"
    if [[ "$n" -eq 3 ]] && ! grep -q "still includes it" "$out" \
       && ! grep -qE 'excluded|Time Machine' <<< "$(ok_lines "$out")"; then
        pass "$mode: three 'could not be checked' warnings, no 'still includes it', no green claim"
    else fail "$mode: expected 3 'could not be checked' and no 'still includes it', got $n: $(grep -E '^(WARN|OK)' "$out")"; fi
done

# ── Doctor: the live rule ─────────────────────────────────────────────────
PY="${PYTHON:-python3}"
dh="$WORK/doctor-home"; mkdir -p "$dh/.ostler" "$dh/Documents/Ostler"
doctor() {  # doctor <FAKE_TM mode> <pre-exclude 0|1>
    rm -f "$dh"/.ostler.fake-tm-excluded "$dh"/Documents/Ostler.fake-tm-excluded
    if [[ "$2" == 1 ]]; then : > "$dh/.ostler.fake-tm-excluded"; : > "$dh/Documents/Ostler.fake-tm-excluded"; fi
    HOME="$dh" PATH="$WORK/bin:$PATH" FAKE_TM="$1" "$PY" - "$REPO/vendor/doctor/agent" <<'PYEOF'
import json, sys
sys.path.insert(0, sys.argv[1])
try:
    import diagnostic_rules as r
except Exception as exc:
    print("IMPORT-FAILED %s" % exc); sys.exit(0)
fn = getattr(r, "check_time_machine_exclusion", None)
if fn is None:
    print("NO-RULE"); sys.exit(0)
print(json.dumps([(f["severity"], f["title"]) for f in fn(None)]))
print("REGISTERED" if fn in r.ALL_RULES else "NOT-REGISTERED")
PYEOF
}
out="$(doctor honours 0)"
case "$out" in IMPORT-FAILED*) cannot "the Doctor rules module does not import: $out";; esac
if grep -q "Ostler's secrets folder is NOT excluded from Time Machine" <<< "$out" \
   && grep -q "Documents/Ostler is NOT excluded" <<< "$out" && grep -q '^REGISTERED' <<< "$out"; then
    pass "Doctor: both included folders are named, the secrets folder in its own words, and the rule is registered"
else fail "Doctor, included: $out"; fi
out="$(doctor honours 1)"
first="$(head -n 1 <<< "$out")"
if [[ "$first" == "[]" ]]; then pass "Doctor control: excluded folders give no finding"
else fail "Doctor control: $out"; fi
printf '#!/usr/bin/env bash\necho "garbled" ; exit 0\n' > "$WORK/bin/tmutil.garbled"
mv "$WORK/bin/tmutil" "$WORK/bin/tmutil.real"; cp "$WORK/bin/tmutil.garbled" "$WORK/bin/tmutil"; chmod +x "$WORK/bin/tmutil"
out="$(doctor honours 0)"
mv "$WORK/bin/tmutil.real" "$WORK/bin/tmutil"
if grep -q "Could not check" <<< "$out" && ! grep -q "NOT excluded" <<< "$out" \
   && grep -q '"warning", "Could not check' <<< "$out" && ! grep -q '"info"' <<< "$out"; then
    pass "Doctor: an unreadable tmutil answer is 'could not check', never a pass"
else fail "Doctor, garbled tmutil: $out"; fi

echo "denominator: 6 install runs x 3 folders + 3 Doctor runs"
exit "$status"
