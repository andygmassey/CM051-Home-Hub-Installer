#!/usr/bin/env bash
# Row #1539. "Use previous answers" did not cover the remote-access question.
#
# THE SUBJECT OF EVERY ASSERTION HERE IS A PERSON: was a screen put in front of
# them, and does the answer they already gave survive to the next install. Not
# whether a string exists in a file.
#
# WHAT WAS WRONG, MEASURED BY EXECUTING THE SHIPPED BLOCK, not by reading
# indentation. On a re-install where the customer chose "use previous answers":
#
#   Phase 2 is skipped, so the early prompt inside the SKIP_PHASE2 guard never
#   runs and TAILSCALE_CONFIRM_SHOWN_EARLY stays unset. The late fallback then
#   runs. Its second branch asks the DISK whether a tailnet exists, which
#   covers only the customer who said YES last time. A customer who said SKIP
#   leaves nothing on disk by definition, so the third branch asked again, and
#   the prompt default replaced their remembered "skip" with "setup":
#
#       ASKED_AGAIN prompt_key=tailscale_confirm
#       FINAL TAILSCALE_CONFIRM=[setup]
#
#   config/.env carried no TAILSCALE_CONFIRM line at all (0 occurrences in the
#   ENVEOF writer; CONTROL: OSTLER_TAILSCALE_IP = 1 in the same range), so there
#   was nothing to remember in the first place.
#
# THE CODE UNDER TEST IS EXTRACTED FROM install.sh AT RUN TIME, never copied,
# so this test rots the moment the real file stops matching it.
#
# THREE STATES: 0 pass, 1 fail, 2 cannot-run. CANNOT-RUN exits non-zero and is
# never reported as a pass.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

[ -r "$SUBJECT" ] || cant "install.sh not readable at ${SUBJECT}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ts1539-XXXXXX")" || cant "mktemp"
trap 'rm -rf "$WORK"' EXIT

# ── EXTRACT THE REAL BLOCKS ──────────────────────────────────────────────
# There are TWO prompt sites with the same opening line. The one that runs on a
# reuse install is the SECOND, the one outside the SKIP_PHASE2 guard. Counting
# occurrences is how this picks it, so a future edit that adds a third site
# changes the count and this comment stops being true out loud.
SITES="$(grep -c '^if \[\[ -n "\${TAILSCALE_CONFIRM_SHOWN_EARLY:-}" \]\]; then$' "$SUBJECT" || true)"
printf 'EXAMINED: %s prompt site(s) with the SHOWN_EARLY opening line\n' "$SITES"
[ "${SITES:-0}" -eq 2 ] || cant "expected 2 prompt sites, found ${SITES:-0}; the extraction below would take the wrong one"

PROMPT="$(awk '
  /^if \[\[ -n "\$\{TAILSCALE_CONFIRM_SHOWN_EARLY:-\}" \]\]; then$/ { n++; if (n==2) f=1 }
  f { print }
  f && /^fi$/ { exit }' "$SUBJECT")"

PERSIST="$(awk '
  /^if \[\[ -n "\$\{TAILSCALE_CONFIRM:-\}" && -f "\$\{CONFIG_DIR\}\/\.env" \]\]; then$/ { f=1 }
  f { print }
  f && /^fi$/ { exit }' "$SUBJECT")"

# The line the reuse path uses to capture what config/.env restored. Taken from
# install.sh so the test cannot pass against a spelling the installer does not use.
RESTORE="$(grep -m1 '^    TAILSCALE_CONFIRM_PREVIOUS=' "$SUBJECT" || true)"

p_lines="$(printf '%s\n' "$PROMPT"  | grep -c . || true)"
x_lines="$(printf '%s\n' "$PERSIST" | grep -c . || true)"
printf 'EXAMINED: prompt block %s lines, persist block %s lines, restore line %s\n' \
    "$p_lines" "$x_lines" "$([ -n "$RESTORE" ] && echo present || echo ABSENT)"
# DENOMINATORS. An empty extraction would make every arm below pass over
# nothing, which is the zero-denominator shape. Refuse rather than report green.
# The floor is 12, not 20. The PRE-FIX block is 19 lines, and a floor above it
# would turn the exact regression this file exists to catch into a CANNOT-RUN.
# "Could not look" must not be how a gate reports "you broke it".
[ "${p_lines:-0}" -ge 12 ] || cant "prompt block extracted only ${p_lines} lines"
[ "${x_lines:-0}" -ge 8 ]  || cant "persist block extracted only ${x_lines} lines"
[ -n "$RESTORE" ]          || cant "no TAILSCALE_CONFIRM_PREVIOUS capture found on the reuse path"

# ── THE HARNESS ──────────────────────────────────────────────────────────
# $1 what config/.env carries for TAILSCALE_CONFIRM ("" = the line is absent)
# $2 tailnet state on disk: none | configured | unreadable
# $3 SKIP_PHASE2 (true = the customer chose "use previous answers")
# $4 the prompt block to run (the real one, or a mutant)
#
# gui_read is the moment a PERSON is asked. Its invocation is the consumer-side
# event this whole test is about, so it prints a marker and nothing else does.
run_arm() {
    local stored="$1" tailnet="$2" skip="$3" block="$4"
    local d; d="$(mktemp -d "${WORK}/arm-XXXXXX")"
    mkdir -p "${d}/config"
    {
        printf 'USER_ID="u-1"\n'
        [ -n "$stored" ] && printf 'TAILSCALE_CONFIRM="%s"\n' "$stored"
    } > "${d}/config/.env"
    {
        printf '%s\n' 'set -uo pipefail'
        printf 'CONFIG_DIR=%q\n' "${d}/config"
        printf 'SKIP_PHASE2=%s\n' "$skip"
        printf '%s\n' 'MSG_PROMPT_TAILSCALE_CONFIRM_TITLE="Remote access"'
        printf '%s\n' 'MSG_PROMPT_TAILSCALE_CONFIRM_HELP="help"'
        printf '%s\n' 'MSG_INFO_TAILSCALE_ALREADY_CONFIGURED="[already configured]"'
        printf '%s\n' 'MSG_INFO_TAILSCALE_REUSED_ANSWER_SKIP="[kept your previous answer: skip]"'
        printf '%s\n' 'MSG_INFO_TAILSCALE_REUSED_ANSWER_SETUP="[kept your previous answer: setup]"'
        printf '%s\n' 'MSG_WARN_TAILSCALE_STATE_UNREADABLE="[state unreadable]"'
        printf '%s\n' 'MSG_WARN_TAILSCALE_ANSWER_NOT_REMEMBERED="[could not save your answer]"'
        printf '%s\n' 'info() { printf "INFO %s\n" "$*"; }'
        printf '%s\n' 'warn() { printf "WARN %s\n" "$*"; }'
        printf '%s\n' 'gui_read() { printf "ASKED prompt_key=%s\n" "$6" >&2; printf "setup"; }'
        case "$tailnet" in
          configured) printf '%s\n' '_ts_already_configured() { _TS_CONFIGURED_VERDICT=configured; return 0; }' ;;
          unreadable) printf '%s\n' '_ts_already_configured() { _TS_CONFIGURED_VERDICT=cannot_run; return 2; }' ;;
          *)          printf '%s\n' '_ts_already_configured() { _TS_CONFIGURED_VERDICT=not_configured; return 1; }' ;;
        esac
        # The reuse path, reproduced from install.sh's own lines: source the
        # .env exactly as it does, then take the capture line verbatim.
        printf '%s\n' 'if [[ "$SKIP_PHASE2" == true ]]; then'
        printf '%s\n' '    set -a; source "${CONFIG_DIR}/.env"; set +a'
        printf '%s\n' "$RESTORE"
        printf '%s\n' 'fi'
        printf '%s\n' "$block"
        printf '%s\n' "$PERSIST"
        printf '%s\n' 'printf "FINAL=[%s]\n" "${TAILSCALE_CONFIRM:-}"'
        printf '%s\n' 'printf "ENV=[%s]\n" "$(grep -c "^TAILSCALE_CONFIRM=" "${CONFIG_DIR}/.env" || true)"'
        printf '%s\n' 'printf "ENVVAL=[%s]\n" "$(sed -n "s/^TAILSCALE_CONFIRM=\"\\(.*\\)\"$/\\1/p" "${CONFIG_DIR}/.env" | head -1)"'
    } > "${d}/arm.sh"
    bash "${d}/arm.sh" 2>&1
}

echo
echo "== a re-install with \"use previous answers\" must not re-ask =="

out="$(run_arm skip none true "$PROMPT")"
printf '%s' "$out" | grep -q 'ASKED prompt_key=tailscale_confirm' \
  && bad "(1) the customer who said SKIP last time was asked AGAIN" \
  || ok  "(1) the customer who said SKIP last time is NOT asked again"
printf '%s' "$out" | grep -q 'FINAL=\[skip\]' \
  && ok  "(2) and their answer is still skip, not overwritten by the prompt default" \
  || bad "(2) the remembered answer did not survive: $(printf '%s' "$out" | grep '^FINAL=')"
printf '%s' "$out" | grep -q 'kept your previous answer: skip' \
  && ok  "(3) they are TOLD it was kept, rather than the step happening in silence" \
  || bad "(3) the answer was reused with nothing said to the customer"

out="$(run_arm setup none true "$PROMPT")"
printf '%s' "$out" | grep -q 'ASKED prompt_key=tailscale_confirm' \
  && bad "(4) the customer who said SETUP last time was asked again" \
  || ok  "(4) the customer who said SETUP last time is not asked again either"
printf '%s' "$out" | grep -q 'FINAL=\[setup\]' \
  && ok  "(5) and remote access is still set up for them" \
  || bad "(5) the remembered setup answer was lost"

echo
echo "== the upgrade path: a box whose .env predates the line =="
out="$(run_arm "" none true "$PROMPT")"
printf '%s' "$out" | grep -q 'ASKED prompt_key=tailscale_confirm' \
  && ok  "(6) with nothing remembered it ASKS, which is right: nothing may be assumed on the customer's behalf" \
  || bad "(6) it skipped the question with no stored answer, which invents one"
printf '%s' "$out" | grep -q 'ENV=\[1\]' \
  && ok  "(7) and the answer is WRITTEN, so the NEXT re-install does not ask" \
  || bad "(7) the answer given here was never persisted, so every future re-install asks again: $(printf '%s' "$out" | grep '^ENV=')"

echo
echo "== the arms that must still ask, because assuming would be worse =="

out="$(run_arm skip none false "$PROMPT")"
printf '%s' "$out" | grep -q 'ASKED prompt_key=tailscale_confirm' \
  && ok  "(8) a customer who DECLINED reuse is still asked, so a stored answer cannot override a fresh walk" \
  || bad "(8) a stored answer overrode a customer who asked to walk the questions again"

out="$(run_arm maybe none true "$PROMPT")"
printf '%s' "$out" | grep -q 'ASKED prompt_key=tailscale_confirm' \
  && ok  "(9) an unrecognised stored value ASKS, so a hand-edited .env cannot enrol anyone in remote access" \
  || bad "(9) a value that is neither setup nor skip was honoured"

out="$(run_arm "" unreadable true "$PROMPT")"
printf '%s' "$out" | grep -q 'state unreadable' \
  && ok  "(10) CANNOT-RUN on the detector is surfaced, then the person is asked" \
  || bad "(10) an unreadable tailnet state was silently treated as absent"

echo
echo "== order: the disk outranks a remembered answer that contradicts it =="
out="$(run_arm skip configured true "$PROMPT")"
printf '%s' "$out" | grep -q 'FINAL=\[setup\]' \
  && ok  "(11) a box demonstrably ON the tailnet re-applies its serve rather than honouring a stale skip" \
  || bad "(11) a remembered skip stopped an already-joined box being re-served, which breaks the iOS app"

echo
echo "== the durable home the reuse path reads =="
env_line="$(awk '/^cat > "\$\{CONFIG_DIR\}\/\.env" <<ENVEOF$/{f=1} f{print} f&&/^ENVEOF$/{exit}' "$SUBJECT" | grep -c '^TAILSCALE_CONFIRM=' || true)"
ctl_line="$(awk '/^cat > "\$\{CONFIG_DIR\}\/\.env" <<ENVEOF$/{f=1} f{print} f&&/^ENVEOF$/{exit}' "$SUBJECT" | grep -c '^OSTLER_CONSENT_PERSONAL_USE_DECISION=' || true)"
[ "${ctl_line:-0}" -eq 1 ] || cant "CONTROL FAILED: the .env writer scan cannot see a line known to be in it; every count below is unmeasured"
[ "${env_line:-0}" -eq 1 ] \
  && ok  "(12) the .env writer carries a TAILSCALE_CONFIRM line (1 of 1 expected; CONTROL line found ${ctl_line})" \
  || bad "(12) the .env writer carries ${env_line} TAILSCALE_CONFIRM line(s); the reuse path would restore nothing"

echo
echo "== MUTATIONS: each must PROVE IT APPLIED before its assertion is scored =="

# M1: the pre-fix world. Remove the reuse arm and nothing else.
M1="$(printf '%s\n' "$PROMPT" | awk '
  /^elif \[\[ "\$\{SKIP_PHASE2:-false\}" == true \]\] \\$/ { drop=1 }
  drop && /^else$/ { drop=0 }
  !drop { print }')"
if [ "$M1" = "$PROMPT" ]; then
    bad "(M1) MUTANT DID NOT APPLY. The reuse arm was not found, so the result below would be meaningless"
else
    ok "(M1a) mutant applied: the reuse arm is gone ($(printf '%s\n' "$PROMPT" | grep -c .) lines to $(printf '%s\n' "$M1" | grep -c .))"
    out="$(run_arm skip none true "$M1")"
    printf '%s' "$out" | grep -q 'ASKED prompt_key=tailscale_confirm' \
      && ok  "(M1b) PRE-FIX IS CAUGHT: without the reuse arm the remembered skip is asked again" \
      || bad "(M1b) the pre-fix shape did not re-ask, so arm (1) cannot tell the two apart"
    printf '%s' "$out" | grep -q 'FINAL=\[setup\]' \
      && ok  "(M1c) and the pre-fix shape overwrote skip with the prompt default, which is the reported harm" \
      || bad "(M1c) the pre-fix shape did not overwrite the answer, so arm (2) is measuring something else"
fi

# M2: honour ANY stored value, dropping the setup/skip whitelist.
M2="$(printf '%s\n' "$PROMPT" | sed \
    -e 's|     && { \[\[ "${TAILSCALE_CONFIRM_PREVIOUS:-}" == "setup" \]\] \\|     \&\& { [[ -n "${TAILSCALE_CONFIRM_PREVIOUS:-}" ]] \\|' \
    -e 's|          \|\| \[\[ "${TAILSCALE_CONFIRM_PREVIOUS:-}" == "skip" \]\]; }; then|          \|\| false; }; then|')"
if [ "$M2" = "$PROMPT" ]; then
    bad "(M2) MUTANT DID NOT APPLY. The setup/skip whitelist was not found in the guard"
else
    ok "(M2a) mutant applied: the guard now accepts any non-empty stored value"
    out="$(run_arm maybe none true "$M2")"
    printf '%s' "$out" | grep -q 'ASKED prompt_key=tailscale_confirm' \
      && bad "(M2b) widening the guard changed nothing, so arm (9) is decoration" \
      || ok  "(M2b) arm (9) goes red without the whitelist, so it is measuring it"
fi

# M3: drop the persist-with-read-back, the upgrade path's only durable home.
M3_PERSIST="$PERSIST"
PERSIST="$(printf '%s\n' "$PERSIST" | sed 's|^    if grep -q .\^TAILSCALE_CONFIRM=. "\$_ts_env_file"; then|    if true; then|')"
if [ "$PERSIST" = "$M3_PERSIST" ]; then
    PERSIST="$M3_PERSIST"
    bad "(M3) MUTANT DID NOT APPLY. The persist block's replace-or-append test was not found"
else
    ok "(M3a) mutant applied: the persist block always takes its rewrite arm"
    # With a .env that has NO existing line, the rewrite arm is a no-op, so the
    # answer is never written. That is the upgrade path arm (7) is about.
    out="$(run_arm "" none true "$PROMPT")"
    PERSIST="$M3_PERSIST"
    printf '%s' "$out" | grep -q 'ENV=\[1\]' \
      && bad "(M3b) the answer was still written, so arm (7) is not measuring the append" \
      || ok  "(M3b) arm (7) goes red when the append arm is unreachable, so it is measuring it"
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
