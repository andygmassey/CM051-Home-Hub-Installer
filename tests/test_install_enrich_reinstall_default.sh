#!/usr/bin/env bash
# tests/test_install_enrich_reinstall_default.sh
# ============================================================================
# CB136-WALK-UPGRADE-PATH (R02). A re-install must never flip a recorded DECLINE
# to yes when the owner presses Enter.
#
# WHAT IS RUN: the REAL public-look-ups question block, extracted from install.sh
# by its markers (from the "CB136-WALK-UPGRADE-PATH" comment down to the
# "export OSTLER_CONSENT_ENRICHMENT_DECISION" line). gui_read is stubbed as "Enter
# accepts the default offered": it prints its third argument. Typed answers are
# modelled by a second stub. Every scenario runs against a sandbox OSTLER_DIR that
# holds the prior answer on disk, the way a real re-install finds it.
#
# SCENARIOS
#   D1  prior declined, Enter            -> declined (stays declined)
#   D2  prior accepted, Enter            -> accepted (stays accepted)
#   D3  no prior answer, Enter           -> accepted (opt-out default, unchanged)
#   D4  prior declined, typed "y"        -> accepted (an explicit yes is honoured)
#
# MUTANT: INSTALL_SH=<a copy with the default forced to yes> must turn D1 red.
# Exit 0 pass, 1 an assertion failed, 2 cannot-run.
# ============================================================================
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${INSTALL_SH:-${REPO}/install.sh}"
[ -r "$SRC" ] || { echo "CANNOT-RUN: cannot read $SRC"; exit 2; }
BLOCK="$(mktemp)"
trap 'rm -f "$BLOCK"' EXIT
awk '/^# CB136-WALK-UPGRADE-PATH \(R02/{f=1} f{print} f && /^export OSTLER_CONSENT_ENRICHMENT_DECISION$/{exit}' "$SRC" > "$BLOCK"
if ! grep -q '^_PRIOR_ENRICH_DECISION=' "$BLOCK" || ! grep -q '^export OSTLER_CONSENT_ENRICHMENT_DECISION$' "$BLOCK"; then
    echo "CANNOT-RUN: the question block was not found in $SRC"; exit 2
fi
fails=0
run_case() {   # name, prior-line-or-empty, typed-answer-or-empty
    local name="$1" prior="$2" typed="$3" dir out
    dir="$(mktemp -d)"
    mkdir -p "$dir/config"
    [ -n "$prior" ] && printf '%s\n' "$prior" > "$dir/config/.env"
    out="$(
        OSTLER_DIR="$dir"
        export OSTLER_DIR
        MSG_PROMPT_CONSENT_ENRICHMENT_TITLE=t; MSG_PROMPT_CONSENT_ENRICHMENT_HELP=h
        legal_prevails_note() { :; }
        if [ -n "$typed" ]; then
            gui_read() { printf '%s' "$typed"; }             # the owner types an answer
        else
            gui_read() { printf '%s' "$3"; }                 # the owner presses Enter: the offered default
        fi
        # shellcheck disable=SC1090
        source "$BLOCK"
        printf 'RESULT choice=%s decision=%s\n' "${ENRICH_CHOICE:-}" "${OSTLER_CONSENT_ENRICHMENT_DECISION:-}"
    )"
    rm -rf "$dir"
    echo "  $name: $out" >&2
    printf '%s\n' "$out" | sed -n 's/^RESULT //p'
}
expect() {  # name, want-decision, output
    local got
    got="$(printf '%s\n' "$3" | sed -n 's/^choice=[a-z]* decision=\([a-z]*\)$/\1/p')"
    if [ "$got" = "$2" ]; then echo "    held (decision=$got)"; else echo "    FAILED want decision=$2 got=$got"; fails=$((fails+1)); fi
}
echo "install.sh question block: $SRC"
o=$(run_case D1 'OSTLER_CONSENT_ENRICHMENT_DECISION="declined"' ''); expect D1 declined "$o"
o=$(run_case D2 'OSTLER_CONSENT_ENRICHMENT_DECISION="accepted"' ''); expect D2 accepted "$o"
o=$(run_case D3 '' ''); expect D3 accepted "$o"
o=$(run_case D4 'OSTLER_CONSENT_ENRICHMENT_DECISION="declined"' 'y'); expect D4 accepted "$o"
if [ "$fails" -eq 0 ]; then echo "PASS: re-install keeps a recorded decline and a recorded accept (4 scenarios)"; exit 0; fi
echo "FAIL: $fails scenario(s) flipped the recorded answer"; exit 1
