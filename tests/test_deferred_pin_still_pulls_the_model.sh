#!/usr/bin/env bash
# A DEFERRED OLLAMA PIN MUST NOT LEAVE THE INSTALL WITH NO CHAT MODEL.
#
# Defect: with the pin deferred (the customer already runs a different Ollama),
# ollama_pull_with_retry returned rc 3 (HELD), the installer warned, continued,
# pulled NO model, and could finish on a "ready" screen with nothing to chat to.
#
# Contract (reviewer option (a)): the tier model is pulled UNPINNED through the
# normal retry, logged loudly, and recorded as "not verified against pin" where
# the Doctor reads it. If the pull fails the install ends in ERR-13.
#
# Runs the SHIPPED functions cut out of install.sh (ollama_pull_with_retry,
# _gui_ollama_pull, ostler_require_model_digest, _ostler_ollama_pin_record) and
# the SHIPPED 3.9 chat-model block, with a stub `ollama` on a private PATH; then
# renders the SHIPPED Doctor over the state file the installer wrote.
#
#   1  deferred + model absent  -> 1 pull, loud log, model_unverified recorded,
#                                  Doctor page says "not checked", REACHED (ready)
#   2  deferred + pull fails    -> ERR-13-MODEL-PULL-AI, 3 attempts, no REACHED
#   3  pin installed            -> 1 pull, digest checked once, no unverified row
#   M1 mutant: restore the hold (return 3, no pull)      -> arm 1 must FAIL
#   M2 mutant: deferred branch removed from the digest gate, verifier says
#      MISMATCH (what a drifted engine produces)         -> arm 1 must FAIL
#
# Synthetic only. THREE OUTCOMES: 0 pass, 1 fail, 2 CANNOT-RUN.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="${REPO}/install.sh"
AGENT="${REPO}/vendor/doctor/agent"
cannot() { echo "CANNOT-RUN: $*" >&2; exit 2; }
[ -f "$INSTALL" ] && [ -d "$AGENT" ] || cannot "missing install.sh or vendor/doctor/agent"
PY="${PYTHON:-python3}"
"$PY" -c 'import fastapi, httpx' 2>/dev/null || cannot "Doctor deps missing (pip install -r vendor/doctor/agent/requirements.txt)"
SITE="$("$PY" -c 'import fastapi, os; print(os.path.dirname(os.path.dirname(fastapi.__file__)))')"  # HOME is faked below; keep the user site
W="$(mktemp -d "${TMPDIR:-/tmp}/deferpin.XXXXXX")" || cannot "no scratch dir"
trap 'rm -rf "$W"' EXIT
fails=0
pass() { echo "PASS: $*"; }
bad()  { echo "FAIL: $*"; fails=$((fails + 1)); }

fn() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{"{f=1} f{print} f && /^}$/{f=0; exit}' "$INSTALL"; }
FNS="$W/fns.sh"; : > "$FNS"
for f in _gui_ollama_pull ollama_pull_with_retry ostler_require_model_digest _ostler_ollama_pin_record; do
    fn "$f" >> "$FNS"; grep -q "^${f}() {" "$FNS" || cannot "install.sh has no ${f}()"
done
BLOCK="$W/block.sh"
awk '/^if \[\[ "\$\{PULL_MODEL\}" != "n" && "\$\{PULL_MODEL\}" != "N" \]\]; then$/{f=1} f{print} f && /^fi$/{exit}' "$INSTALL" > "$BLOCK"
grep -q 'ollama_pull_with_retry "\$AI_MODEL"' "$BLOCK" || cannot "could not lift the 3.9 chat-model block"

mkdir -p "$W/bin"
cat > "$W/bin/ollama" <<'OL'
#!/bin/sh
case "$1" in
  list) exit 0 ;;
  pull) echo "$2" >> "${PULL_LOG:?}"; [ "${PULL_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
esac
exit 0
OL
chmod +x "$W/bin/ollama"
MODEL="qwen3.5:4b"

run() {  # run <name> <outcome> <pull_fail> <verify_rc> <fns_file> ; dir $W/<name>
    local d="$W/$1"; rm -rf "$d"; mkdir -p "$d"; : > "$d/pulls"; : > "$d/verify"; : > "$d/install.log"
    OLLAMA_APP_BIN="$W/bin/ollama" PULL_LOG="$d/pulls" PULL_FAIL="$3" VERIFY_RC="$4" \
    OLLAMA_PIN_OUTCOME="$2" OLLAMA_PIN_VERSION=9.9.9 OLLAMA_PIN_STATE_FILE="$d/ollama-pin" \
    INSTALL_LOG="$d/install.log" VF="$d/verify" PULL_MODEL=y AI_MODEL="$MODEL" AI_MODEL_SIZE=3GB OSTLER_DIR="$d" \
    STRINGS="${REPO}/install.sh.strings.en-GB.sh" \
    bash -c 'set -Eeuo pipefail; . "$STRINGS"; ok(){ :; }; info(){ :; }; warn(){ echo "WARN $*"; }
             fail_with_code(){ echo "CODE $1"; exit 1; }; gui_emit(){ :; }; gui_log(){ :; }; sleep(){ :; }
             ostler_verify_model_digest(){ echo "$1" >> "$VF"; OSTLER_MODEL_DIGEST_GOT=x; OSTLER_MODEL_DIGEST_WANT=y; OSTLER_MODEL_DIGEST_DETAIL=d; return "$VERIFY_RC"; }
             ostler_note_existing_model(){ :; }
             PATH="$(dirname "$OLLAMA_APP_BIN"):$PATH"
             . "$1"
             if [ "$OLLAMA_PIN_OUTCOME" = deferred ]; then _ostler_ollama_pin_record deferred pin_install_rc=11; else _ostler_ollama_pin_record installed ""; fi
             . "$2"; echo REACHED' _ "$5" "$BLOCK" > "$d/out" 2>&1
    # pulls|reached|code|loudlog|verifier-calls|unverified-rows|warn
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$(grep -c . "$d/pulls")" "$(grep -c '^REACHED$' "$d/out")" \
        "$(sed -n 's/^CODE //p' "$d/out")" \
        "$(grep -c "^model_pull=unpinned_engine model=${MODEL} reason=ollama_unpinned$" "$d/install.log" 2>/dev/null)" \
        "$(grep -c . "$d/verify")" "$(grep -c "^model_unverified=${MODEL}$" "$d/ollama-pin" 2>/dev/null)" \
        "$(grep -c '^WARN Downloading' "$d/out")"
}

render() {  # the shipped Doctor page over the state file the installer wrote
    PYTHONPATH="$SITE" HOME="$W/h" OSTLER_DIR="$W/h/.ostler" "$PY" - "$AGENT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import web_ui
from diagnostic_rules import run_all_rules
snap = web_ui._degraded_snapshot()
print(web_ui.render_dashboard(snap, run_all_rules(snap)))
PY
}

# arm 1
r1="$(run a1 deferred 0 0 "$FNS")"
mkdir -p "$W/h/.ostler/state"; cp "$W/a1/ollama-pin" "$W/h/.ostler/state/ollama-pin"
html="$(render)" || cannot "the Doctor dashboard did not render"
if [ "$r1" = "1|1||1|0|1|1" ] && grep -qF "were not checked against" <<<"$html" && grep -qF "$MODEL" <<<"$html"; then
    pass "1: deferred pin + model absent -> pulled unpinned, loud log, Doctor shows it as not checked, ready allowed [$r1]"
else bad "1: [pulls|reached|code|log|verifier|unverified|warn]=$r1 want 1|1||1|0|1|1; Doctor mentions it: $(grep -cF 'were not checked against' <<<"$html")"; fi
# arm 2
r2="$(run a2 deferred 1 0 "$FNS")"
if [ "$r2" = "3|0|ERR-13-MODEL-PULL-AI|1|0|0|1" ]; then
    pass "2: deferred pin + pull fails -> 3 attempts, ERR-13-MODEL-PULL-AI, never reached ready [$r2]"
else bad "2: [$r2] want 3|0|ERR-13-MODEL-PULL-AI|1|0|0|1"; fi
# arm 3
r3="$(run a3 installed 0 0 "$FNS")"
if [ "$r3" = "1|1||0|1|0|0" ] && ! grep -q '^model_unverified' "$W/a3/ollama-pin"; then
    pass "3: pin installed -> unchanged: 1 pull, digest checked once, no unverified row, no warn [$r3]"
else bad "3: [$r3] want 1|1||0|1|0|0"; fi

# mutants: each must APPLY (file differs) and then make arm 1 FAIL
mutant() {  # mutant <name> <sed-script> <verify_rc>
    local f="$W/$1.sh"; sed "$2" "$FNS" > "$f"
    if cmp -s "$f" "$FNS"; then bad "$1: mutant did not apply (not a test of anything)"; return; fi
    local r; r="$(run "m_$1" deferred 0 "$3" "$f")"
    if [ "$r" = "1|1||1|0|1|1" ]; then bad "$1: mutant SURVIVED, arm 1 still passes [$r]"; else pass "$1: mutant caught, arm 1 FAILS [$r]"; fi
}
mutant M1 's|^    while (( attempt <= 3 )); do$|    [[ "${OLLAMA_PIN_OUTCOME:-}" == "deferred" ]] \&\& return 3\
    while (( attempt <= 3 )); do|' 0
mutant M2 's|^    if \[\[ "\${OLLAMA_PIN_OUTCOME:-}" == "deferred" \]\]; then  # pulled by.*$|    if false; then|' 1

echo "VERDICT: $([ "$fails" = 0 ] && echo PASS || echo "FAIL ($fails)")"
[ "$fails" = 0 ]
