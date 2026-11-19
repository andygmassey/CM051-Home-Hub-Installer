#!/usr/bin/env bash
# tests/test_install_enrich_reinstall_default.sh
# ============================================================================
# CB136-WALK-UPGRADE-PATH. On a RE-INSTALL, pressing Enter must keep the recorded
# answer. The cold-install default ("y", opt-out) must not change.
#
# WHAT IS RUN: the REAL public-look-ups question line from install.sh, extracted by
# markers (from the "_PRIOR_ENRICH_DECISION=" line down to the
# "export OSTLER_CONSENT_ENRICHMENT_DECISION" line). gui_read is a stub that records
# the default it was offered and returns either that default (Enter) or a typed
# answer. Each scenario runs against a sandbox OSTLER_DIR whose config/.env holds the
# prior answer, the way a real re-install finds it.
#
# RE-INSTALL SCENARIOS (the prior answer is on disk)
#   R1  prior declined, Enter          -> declined  (stays declined)
#   R2  prior accepted, Enter          -> accepted  (stays accepted)
#   R3  prior declined, typed "y"      -> accepted  (an explicit yes is honoured)
#   R4  prior accepted, typed "n"      -> declined  (an explicit no is honoured)
# COLD-INSTALL SCENARIOS (no config/.env at all)
#   C1  no answer on disk, Enter       -> offered default "y", accepted (unchanged)
#   C2  no answer on disk, typed "n"   -> declined
#
# MUTANT: INSTALL_SH=<a copy with the default forced to yes> must turn R1 red.
# Exit 0 pass, 1 an assertion failed, 2 cannot-run.
# ============================================================================
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${INSTALL_SH:-${REPO}/install.sh}"
[ -r "$SRC" ] || { echo "CANNOT-RUN: cannot read $SRC"; exit 2; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BLOCK="$WORK/block.sh"
awk '/^_PRIOR_ENRICH_DECISION=/{f=1} f{print} f && /^export OSTLER_CONSENT_ENRICHMENT_DECISION$/{exit}' "$SRC" > "$BLOCK"
if ! grep -q '^_PRIOR_ENRICH_DECISION=' "$BLOCK" || ! grep -q '^export OSTLER_CONSENT_ENRICHMENT_DECISION$' "$BLOCK"; then
    echo "CANNOT-RUN: the question block was not found in $SRC"; exit 2
fi
fails=0
# run_case NAME PRIOR-LINE-OR-EMPTY TYPED-OR-EMPTY -> prints "choice decision offered"
run_case() {
    local name="$1" prior="$2" typed="$3" dir="$WORK/$1"
    mkdir -p "$dir/config"
    [ -n "$prior" ] && printf '%s\n' "$prior" > "$dir/config/.env"
    local offered_file="$dir/offered"
    local out
    out="$(
        OSTLER_DIR="$dir"; export OSTLER_DIR
        MSG_PROMPT_CONSENT_ENRICHMENT_TITLE=t; MSG_PROMPT_CONSENT_ENRICHMENT_HELP=h
        legal_prevails_note() { :; }
        gui_read() {
            printf '%s' "$3" > "$offered_file"          # the default the question was offered
            if [ -n "$typed" ]; then printf '%s' "$typed"; else printf '%s' "$3"; fi
        }
        # shellcheck disable=SC1090
        source "$BLOCK"
        printf 'choice=%s decision=%s offered=%s\n' "${ENRICH_CHOICE:-}" "${OSTLER_CONSENT_ENRICHMENT_DECISION:-}" "$(cat "$offered_file" 2>/dev/null)"
    )"
    echo "  $name: $out" >&2
    printf '%s\n' "$out"
}
expect() {  # name, want-decision, want-offered (or -), result-line
    local got_dec got_off
    got_dec="$(printf '%s\n' "$4" | sed -n 's/^choice=[a-z]* decision=\([a-z]*\) offered=.*$/\1/p')"
    got_off="$(printf '%s\n' "$4" | sed -n 's/^.* offered=\([a-z]*\)$/\1/p')"
    local ok=1
    [ "$got_dec" = "$2" ] || ok=0
    if [ "$3" != "-" ] && [ "$got_off" != "$3" ]; then ok=0; fi
    if [ "$ok" = 1 ]; then echo "    held (decision=$got_dec offered=$got_off)" >&2
    else echo "    FAILED want decision=$2 offered=$3, got decision=$got_dec offered=$got_off" >&2; fails=$((fails+1)); fi
}
echo "install.sh question line: $SRC" >&2
r=$(run_case R1_declined_enter 'OSTLER_CONSENT_ENRICHMENT_DECISION="declined"' '');        expect R1 declined n "$r"
r=$(run_case R2_accepted_enter 'OSTLER_CONSENT_ENRICHMENT_DECISION="accepted"' '');        expect R2 accepted y "$r"
r=$(run_case R3_declined_typed_y 'OSTLER_CONSENT_ENRICHMENT_DECISION="declined"' 'y');    expect R3 accepted n "$r"
r=$(run_case R4_accepted_typed_n 'OSTLER_CONSENT_ENRICHMENT_DECISION="accepted"' 'n');    expect R4 declined y "$r"
r=$(run_case C1_cold_enter '' '');                                                        expect C1 accepted y "$r"
r=$(run_case C2_cold_typed_n '' 'n');                                                     expect C2 declined y "$r"
if [ "$fails" -eq 0 ]; then echo "PASS: re-install keeps the recorded answer (R1-R4); cold install default unchanged (C1-C2)"; exit 0; fi
echo "FAIL: $fails scenario(s)"; exit 1
