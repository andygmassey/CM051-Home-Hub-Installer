#!/usr/bin/env bash
# tests/test_install_enrich_reinstall_default.sh
# ============================================================================
# CB136-WALK-UPGRADE-PATH. On a RE-INSTALL, Enter must keep the recorded answer.
# The cold-install default ("y") must not change. An unreadable prior answer
# fails toward "n".
#
# THE LAYOUT IS THE REAL ONE (Archie, 2026-11-20). When the question is asked,
# OSTLER_DIR is the prelaunch STAGING tree (_ostler_set_paths "$OSTLER_PRELAUNCH_DIR"),
# and the prior answer lives in the FINAL tree, OSTLER_FINAL_DIR="${HOME}/.ostler".
# So this test:
#   1. takes OSTLER_FINAL_DIR and _OSTLER_FINAL_PREEXISTED from the REAL lines of
#      install.sh (extracted by exact match), run with a seeded HOME;
#   2. creates an EMPTY staging dir under the final tree (as mktemp does) and sets
#      OSTLER_DIR to it, the way _ostler_set_paths does;
#   3. extracts the REAL question line and the lines that follow it, through
#      "export OSTLER_CONSENT_ENRICHMENT_DECISION", and runs them.
# gui_read is a stub: Enter returns the offered default, a typed answer returns that.
#
# SCENARIOS
#   R1  prior declined, Enter          -> declined (offered n)
#   R2  prior accepted, Enter          -> accepted (offered y)
#   R3  prior declined, typed y        -> accepted
#   R4  prior accepted, typed n        -> declined
#   C1  cold (no final tree), Enter    -> accepted (offered y, unchanged)
#   C2  cold, typed n                  -> declined
#   U1  prior file present, UNREADABLE, Enter -> declined (offered n: fail toward consent)
#
# MUTANT: INSTALL_SH=<a copy reading the prior answer from ${OSTLER_DIR}> must turn
# R1 and U1 red (the staging tree has no prior answer). A second mutant forcing the
# default to yes must turn R1 red.
# Exit 0 pass, 1 an assertion failed, 2 cannot-run.
# ============================================================================
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${INSTALL_SH:-${REPO}/install.sh}"
[ -r "$SRC" ] || { echo "CANNOT-RUN: cannot read $SRC"; exit 2; }
WORK="$(mktemp -d)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# (1) the REAL layout lines, by exact match, each must occur exactly once
exact_once() {
    local n
    n=$(grep -c -F -x -- "$1" "$SRC")
    [ "$n" = 1 ] || { echo "CANNOT-RUN: expected one '$1' in $SRC, found $n"; exit 2; }
}
LAYOUT="$WORK/layout.sh"
exact_once 'OSTLER_FINAL_DIR="${HOME}/.ostler"'
exact_once '_OSTLER_FINAL_PREEXISTED=false'
exact_once '[[ -d "$OSTLER_FINAL_DIR" ]] && _OSTLER_FINAL_PREEXISTED=true'
{
    grep -F -x -- 'OSTLER_FINAL_DIR="${HOME}/.ostler"' "$SRC"
    grep -F -x -- '_OSTLER_FINAL_PREEXISTED=false' "$SRC"
    grep -F -x -- '[[ -d "$OSTLER_FINAL_DIR" ]] && _OSTLER_FINAL_PREEXISTED=true' "$SRC"
    # install.sh continues after this line; a sourced file's status is its last command's,
    # so without this the test would exit under set -e on a cold box where the dir is absent.
    echo ':'
} > "$LAYOUT"

# (2) the REAL question line and what follows it, through the decision export
QBLOCK="$WORK/question.sh"
awk '/^_ENRICH_DEFAULT=y; _PRIOR_ENRICH_DECISION=/{f=1} f{print} f && /^export OSTLER_CONSENT_ENRICHMENT_DECISION$/{exit}' "$SRC" > "$QBLOCK"
if ! grep -q '^_ENRICH_DEFAULT=y; _PRIOR_ENRICH_DECISION=' "$QBLOCK" || ! grep -q '^export OSTLER_CONSENT_ENRICHMENT_DECISION$' "$QBLOCK"; then
    echo "CANNOT-RUN: the question line was not found in $SRC"; exit 2
fi

fails=0
# run_case NAME MODE TYPED  -> prints RESULT line
#   MODE: cold | declined | accepted | unreadable
run_case() {
    local name="$1" mode="$2" typed="$3"
    local home="$WORK/$name/home" final
    mkdir -p "$home"
    final="$home/.ostler"
    case "$mode" in
        cold) ;;
        declined)   mkdir -p "$final/config"; printf '%s\n' 'OSTLER_CONSENT_ENRICHMENT_DECISION="declined"' > "$final/config/.env" ;;
        accepted)   mkdir -p "$final/config"; printf '%s\n' 'OSTLER_CONSENT_ENRICHMENT_DECISION="accepted"' > "$final/config/.env" ;;
        unreadable) mkdir -p "$final/config"; printf '%s\n' 'OSTLER_CONSENT_ENRICHMENT_DECISION="accepted"' > "$final/config/.env"
                    chmod 000 "$final/config/.env"
                    if [ -r "$final/config/.env" ]; then echo "CANNOT-RUN: the unreadable file is still readable (running as root?)" >&2; exit 2; fi ;;
    esac
    local out
    out="$(
        export HOME="$home"
        set -Eeuo pipefail   # install.sh runs under this; the question line must survive it
        # (1) the real layout: OSTLER_FINAL_DIR and _OSTLER_FINAL_PREEXISTED as install.sh sets them
        # shellcheck disable=SC1090
        source "$LAYOUT"
        # the real mktemp step: an EMPTY staging dir under the final tree, then _ostler_set_paths
        mkdir -p "$OSTLER_FINAL_DIR"
        OSTLER_PRELAUNCH_DIR="$(mktemp -d "${OSTLER_FINAL_DIR}/.ostler-prelaunch.XXXXXX")"
        OSTLER_DIR="$OSTLER_PRELAUNCH_DIR"
        export OSTLER_DIR
        MSG_PROMPT_CONSENT_ENRICHMENT_TITLE=t; MSG_PROMPT_CONSENT_ENRICHMENT_HELP=h
        offered_file="$WORK/$name/offered"
        gui_read() {
            printf '%s' "$3" > "$offered_file"
            if [ -n "$typed" ]; then printf '%s' "$typed"; else printf '%s' "$3"; fi
        }
        # shellcheck disable=SC1090
        source "$QBLOCK"
        printf 'RESULT choice=%s decision=%s offered=%s prior_preexisted=%s\n' \
            "${ENRICH_CHOICE:-}" "${OSTLER_CONSENT_ENRICHMENT_DECISION:-}" "$(cat "$offered_file" 2>/dev/null)" "$_OSTLER_FINAL_PREEXISTED"
    )"
    chmod -R u+rwx "$home" 2>/dev/null
    echo "  $name: $out" >&2
    printf '%s\n' "$out" | sed -n 's/^RESULT //p'
}
expect() {  # name, want-decision, want-offered, result-line
    local got_dec got_off ok=1
    got_dec="$(printf '%s\n' "$4" | sed -n 's/^choice=[a-z]* decision=\([a-z]*\) offered=.*$/\1/p')"
    got_off="$(printf '%s\n' "$4" | sed -n 's/^.* offered=\([a-z]*\) prior_preexisted=.*$/\1/p')"
    [ "$got_dec" = "$2" ] || ok=0
    [ "$got_off" = "$3" ] || ok=0
    if [ "$ok" = 1 ]; then echo "    held (decision=$got_dec offered=$got_off)" >&2
    else echo "    FAILED want decision=$2 offered=$3, got decision=$got_dec offered=$got_off" >&2; fails=$((fails+1)); fi
}
echo "install.sh: $SRC" >&2
r=$(run_case R1_declined_enter declined '');     expect R1 declined n "$r"
r=$(run_case R2_accepted_enter accepted '');     expect R2 accepted y "$r"
r=$(run_case R3_declined_typed_y declined y);    expect R3 accepted n "$r"
r=$(run_case R4_accepted_typed_n accepted n);    expect R4 declined y "$r"
r=$(run_case C1_cold_enter cold '');             expect C1 accepted y "$r"
r=$(run_case C2_cold_typed_n cold n);            expect C2 declined y "$r"
r=$(run_case U1_unreadable_enter unreadable ''); expect U1 declined n "$r"
if [ "$fails" -eq 0 ]; then echo "PASS: re-install reads the prior answer from the final tree (R1-R4); cold default unchanged (C1-C2); unreadable fails toward n (U1)"; exit 0; fi
echo "FAIL: $fails scenario(s)"; exit 1
