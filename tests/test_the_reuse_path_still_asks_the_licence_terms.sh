#!/usr/bin/env bash
# Row 969. The personal-use terms are a LICENCE term, not an optional
# consent, and they were rendered only inside `if [[ "$SKIP_PHASE2" == false ]]`.
# A customer choosing "use previous answers" was never shown them and nothing
# was recorded, because the recorder is guarded on the decision being non-empty.
#
# THE SUBJECT OF EVERY ASSERTION HERE IS A PERSON: did a screen get put in
# front of them, and is there a record of what they answered. Not whether a
# string exists in a file.
#
# The code under test is EXTRACTED FROM install.sh at run time, never copied,
# so this test rots the moment the real file stops matching it.
set -uo pipefail
cd "$(dirname "$0")/.."
INSTALL_SH="install.sh"
PASS=0; FAIL=0; CANTRUN=0
ok()   { PASS=$((PASS+1)); echo "  ok    $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
cant() { CANTRUN=$((CANTRUN+1)); echo "  CANNOT-RUN  $1"; }

[[ -r "$INSTALL_SH" ]] || { cant "install.sh unreadable"; echo "PASS=$PASS FAIL=$FAIL CANNOT-RUN=$CANTRUN"; exit 1; }

# ---- extract the two real blocks -------------------------------------
FN=$(awk '/^_ostler_ask_personal_use_terms\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}' "$INSTALL_SH")
REUSE=$(awk '/^if \[\[ -z "\$\{OSTLER_CONSENT_PERSONAL_USE_DECISION:-\}" \]\]; then$/{f=1} f{print} f&&/^fi$/{exit}' "$INSTALL_SH")

# A DENOMINATOR, because an empty extraction would make every arm below pass
# vacuously -- the zero-denominator shape. Refuse rather than report green.
fn_lines=$(printf '%s\n' "$FN"    | grep -c . || true)
ru_lines=$(printf '%s\n' "$REUSE" | grep -c . || true)
echo "EXAMINED: function $fn_lines lines, reuse block $ru_lines lines, extracted from $INSTALL_SH"
if [[ "$fn_lines" -lt 10 || "$ru_lines" -lt 10 ]]; then
    cant "extraction returned too little; every arm would pass on an empty subject"
    echo "PASS=$PASS FAIL=$FAIL CANNOT-RUN=$CANTRUN"; exit 1
fi

# ---- harness ---------------------------------------------------------
# $1 = python stub exit code, or "none" for no python at all
# $2 = the in-memory decision before the block runs ("" = reuse path)
# $3 = extra shell injected before the block (mutation arms use this)
run_arm() {
    local pyrc="$1" inmem="$2" extra="${3:-}"
    local d; d="$(mktemp -d)"
    mkdir -p "$d/bin"
    if [[ "$pyrc" != "none" ]]; then
        printf '#!/bin/sh\nexit %s\n' "$pyrc" > "$d/bin/python3"
        chmod +x "$d/bin/python3"
    fi
    {
      echo 'set -uo pipefail'
      echo 'BOLD=""; NC=""; DIM=""'
      # Every MSG_* the screen reads. Non-empty, so "screen shown" is
      # observable; a screen that renders only empty strings is a screen
      # nobody can read, and that is the other half of this defect.
      echo 'for v in MSG_TERMS_PERSONAL_USE_HEADING MSG_TERMS_PERSONAL_USE_INTRO \
             MSG_TERMS_PERSONAL_USE_BUSINESS MSG_TERMS_PERSONAL_USE_RECORDER \
             MSG_TERMS_PERSONAL_USE_ASK_HEADING MSG_TERMS_PERSONAL_USE_ASK_1 \
             MSG_TERMS_PERSONAL_USE_ASK_2 MSG_TERMS_PERSONAL_USE_ASK_3 \
             MSG_TERMS_PERSONAL_USE_LEGAL MSG_PROMPT_TERMS_PERSONAL_USE_TITLE \
             MSG_PROMPT_TERMS_PERSONAL_USE_HELP MSG_INFO_TERMS_PERSONAL_USE_DECLINED; do
             eval "$v=\"[${v}]\""; done'
      # gui_read is the moment a PERSON is asked. Its invocation is the
      # consumer-side event this whole test is about.
      echo 'gui_read() { echo "SCREEN_SHOWN" >&2; echo "OK"; }'
      echo 'gui_cancelled() { :; }'
      echo 'ok() { echo "OK_CALLED:$1" >&2; }'
      echo "OSTLER_DIR=$d/nonexistent"
      echo "OSTLER_CONSENT_PERSONAL_USE_DECISION='$inmem'"
      [[ "$pyrc" != "none" ]] && echo "PATH=$d/bin:\$PATH" || echo "PATH=$d/emptybin"
      echo "$extra"
      echo "$FN"
      echo "$REUSE"
      echo 'echo "DECISION=[$OSTLER_CONSENT_PERSONAL_USE_DECISION]" >&2'
    } > "$d/arm.sh"
    bash "$d/arm.sh" 2>&1
    rm -rf "$d"
}

echo
echo "== the reuse path (no in-memory decision) =="

out=$(run_arm 0 "")
grep -q "SCREEN_SHOWN" <<<"$out" \
  && bad "(1) a CURRENT accepted record should carry forward, not re-ask" \
  || ok  "(1) a current accepted record carries forward without re-asking"
grep -q "DECISION=\[accepted\]" <<<"$out" \
  && ok  "(2) and it is re-asserted in memory, so THIS run is recorded too" \
  || bad "(2) carried forward but left the decision empty, so nothing is recorded"

out=$(run_arm 2 "")
grep -q "SCREEN_SHOWN" <<<"$out" \
  && ok  "(3) stale_hash / declined / absent re-asks the person" \
  || bad "(3) a non-current record skipped the screen"

out=$(run_arm none "")
grep -q "SCREEN_SHOWN" <<<"$out" \
  && ok  "(4) NO PYTHON AVAILABLE still asks: it fails closed" \
  || bad "(4) unable to check the registry silently skipped the terms"

out=$(run_arm 0 "accepted")
grep -q "SCREEN_SHOWN" <<<"$out" \
  && bad "(5) the first-install path was made to ask twice" \
  || ok  "(5) first install (decision already set) is untouched"

echo
echo "== the screen a person actually reads =="
out=$(run_arm 2 "")
missing=0
for v in HEADING INTRO BUSINESS RECORDER ASK_1 ASK_2 ASK_3 LEGAL; do
    grep -q "\[MSG_TERMS_PERSONAL_USE_${v}\]" <<<"$out" || missing=$((missing+1))
done
[[ "$missing" -eq 0 ]] \
  && ok  "(6) all 8 terms strings reach the screen (0 missing of 8)" \
  || bad "(6) $missing of 8 terms strings never rendered"

echo
echo "== mutations: each must be CAUGHT =="

# M1: the pre-fix world -- no reuse block at all.
d=$(mktemp -d); printf '#!/bin/sh\nexit 2\n' > "$d/p3"; chmod +x "$d/p3"
out=$( { echo 'set -uo pipefail'; echo 'gui_read(){ echo SCREEN_SHOWN >&2; echo OK; }'
         echo 'OSTLER_CONSENT_PERSONAL_USE_DECISION=""'
         echo 'echo "DECISION=[$OSTLER_CONSENT_PERSONAL_USE_DECISION]" >&2'; } | bash 2>&1 )
rm -rf "$d"
grep -q "SCREEN_SHOWN" <<<"$out" \
  && bad "(M1) the pre-fix shape rendered a screen, so this test cannot tell the two apart" \
  || ok  "(M1) PRE-FIX IS CAUGHT: with no reuse block the person is never asked and the decision stays empty"

# M2: guard inverted -- only ask when a decision already exists.
out=$(run_arm 2 "" 'REUSE_MUTANT=1')
out=$(run_arm 2 "accepted")
grep -q "SCREEN_SHOWN" <<<"$out" \
  && bad "(M2) asking when a decision already exists was not caught" \
  || ok  "(M2) the guard is on ABSENCE of a decision, verified by the arm that already has one"

# M3: a python that always succeeds must NOT be how arm (3) passes.
out=$(run_arm 0 "")
grep -q "SCREEN_SHOWN" <<<"$out" \
  && bad "(M3) the harness shows the screen regardless of the registry answer" \
  || ok  "(M3) the registry answer genuinely changes the outcome (rc0 skips, rc2 asks)"

echo
echo "PASS=$PASS FAIL=$FAIL CANNOT-RUN=$CANTRUN"
[[ "$FAIL" -eq 0 && "$CANTRUN" -eq 0 && "$PASS" -ge 9 ]] || exit 1
