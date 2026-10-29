#!/usr/bin/env bash
# tests/test_ttywalk_lang_leg.sh -- ttywalk.sh --lang <code> (NEW-119 harness).
#
# A non-English walk leg must (1) put OSTLER_LANG=<code> on the remote install
# launch line, the variable the GUI passes; (2) stage a ~/.walk-answers.tsv
# generated from the SAME MSG_ keys in install.sh.strings.<code>.sh, so the
# driver can answer Japanese prompts; (3) refuse an unknown code before any
# ssh; (4) leave today's command line byte-identical with no --lang; (5) remove
# what it staged even when the walk dies.
#
# Everything runs against a FAKE box: a directory used as HOME by a fake `ssh`
# that runs the remote command locally. No real host, no network.
# Arms run through run_arms() so the mutants run the same arms against a
# broken copy of the subject: each mutant must turn at least one arm red.
# 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FX="$REPO/tests/fixtures/lang_leg"
GEN="$REPO/scripts/box_walk_probes/lib/gen_walk_answers_lang.py"
for f in "$REPO/scripts/ttywalk.sh" "$REPO/scripts/lib_walk_lang.sh" "$GEN" "$REPO/scripts/walk_drive.py" "$FX/install.sh.strings.ja.sh" "$FX/install.sh.strings.en-GB.sh"; do
  [ -f "$f" ] || { echo "CANNOT-RUN: missing $f"; exit 2; }
done
T="$(mktemp -d)" || exit 2
trap 'rm -rf "$T"' EXIT
REAL_PY="$(command -v python3)" || { echo "CANNOT-RUN: no python3"; exit 2; }

# ---- the fake box -----------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/ssh" <<'FAKE'
#!/bin/bash
# fake ssh: drop "-o X" pairs and the host, run the rest locally with HOME=$BOXHOME
while [ "${1:-}" = "-o" ]; do shift 2; done
shift
echo "ssh: $*" >> "$SSH_LOG"
cd "$BOXHOME" && HOME="$BOXHOME" PATH="$BOXBIN:$PATH" exec /bin/bash -c "$*"
FAKE
chmod +x "$T/bin/ssh"
mkdir -p "$T/boxbin"; export PATH="$T/bin:$PATH"
cat > "$T/boxbin/python3" <<FAKE
#!/bin/bash
# the install driver is recorded, never run; every other python3 call is real
case "\${1:-}" in
  scripts/walk_drive.py) printf 'OSTLER_LANG=%s\nOSTLER_GUI=%s\n' "\${OSTLER_LANG-<unset>}" "\${OSTLER_GUI-<unset>}" > "\$BOXHOME/driver.env"; exit 0 ;;
esac
exec "$REAL_PY" "\$@"
FAKE
chmod +x "$T/boxbin/python3"

new_box() {  # fresh fake box with the staged tree
  BOXHOME="$T/box.$1"; rm -rf "$BOXHOME"; mkdir -p "$BOXHOME/ostler-ttywalk/scripts"
  cp "$FX/install.sh.strings.en-GB.sh" "$FX/install.sh.strings.ja.sh" "$BOXHOME/ostler-ttywalk/"
  cp "$REPO/scripts/walk_drive.py" "$BOXHOME/ostler-ttywalk/scripts/"
  export BOXHOME BOXBIN="$T/boxbin" SSH_LOG="$T/ssh.$1.log"; : > "$SSH_LOG"
}
ANS() { printf '%s' "$BOXHOME/.walk-answers.tsv"; }

# the pre---lang launch line, copied from origin/main scripts/ttywalk.sh
old_launch() { local REMOTE_DIR="$1" IMESSAGE_SHIM="$2"
  printf '%s' "cd '${REMOTE_DIR}' && \
    unset OSTLER_GUI_FD OSTLER_MARKER_FD && \
    PWG_IMESSAGE_PROBE_OUTCOME='${IMESSAGE_SHIM}' \
    OSTLER_WALK_OWNER_FILE=\"\$HOME/.walk-owner.env\" \
    OSTLER_GUI=1 nohup python3 scripts/walk_drive.py > ttywalk.driver.out 2>&1 &
    echo started"; }

# The REAL launch line: sourced out of ttywalk.sh's marked block, never copied.
launch_cmd() {  # <ttywalk.sh> <lang or empty>
  ( REMOTE_DIR=ostler-ttywalk; IMESSAGE_SHIM=check-failed; WALK_LANG="$2"
    eval "$(awk '/^# >>> launch/,/^# <<< launch/' "$1")" || exit 1
    [ -n "${WALK_LAUNCH_CMD:-}" ] || exit 1
    printf '%s' "$WALK_LAUNCH_CMD" ); }
# the set of NAME= assignments on a launch line, one per line, sorted
launch_env_set() { printf '%s' "$1" | grep -oE "[A-Z][A-Z0-9_]*=" | sort -u; }

PASS=0; FAIL=0
arm() { if [ "$2" -eq 0 ]; then echo "  [PASS] $1"; PASS=$((PASS+1)); else echo "  [FAIL] $1"; FAIL=$((FAIL+1)); fi; }

# run_arms <lib> <ttywalk>   (counts into PASS/FAIL)
run_arms() {
  local LIB="$1" WALK="$2" rc out n

  # A1 the launch line carries OSTLER_LANG, and the child process receives it
  new_box a1
  ( . "$LIB"; SSH=(ssh -o X=1 box); "${SSH[@]}" "$(launch_cmd "$WALK" ja)" >/dev/null 2>&1 )
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$BOXHOME/driver.env" ] && break; sleep 0.3; done
  grep -qx 'OSTLER_LANG=ja' "$BOXHOME/driver.env" 2>/dev/null && grep -qx 'OSTLER_GUI=1' "$BOXHOME/driver.env" 2>/dev/null
  arm "--lang ja: the driver process on the box receives OSTLER_LANG=ja beside OSTLER_GUI=1" $?
  out="$(launch_cmd "$WALK" ja)"
  case "$out" in *"OSTLER_GUI=1 OSTLER_LANG='ja' nohup python3 scripts/walk_drive.py"*) rc=0;; *) rc=1;; esac
  arm "--lang ja: the remote env line reads OSTLER_GUI=1 OSTLER_LANG='ja' nohup ..." $rc

  # A2 CONTROL: no --lang is byte-identical to today, and the child sees no OSTLER_LANG
  out="$(launch_cmd "$WALK" "")"
  [ "$out" = "$(old_launch ostler-ttywalk check-failed)" ]
  arm "CONTROL no --lang: launch line byte-identical to the pre---lang line" $?
  new_box a2
  ( unset OSTLER_LANG; . "$LIB"; SSH=(ssh -o X=1 box); "${SSH[@]}" "$(launch_cmd "$WALK" "")" >/dev/null 2>&1 )
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$BOXHOME/driver.env" ] && break; sleep 0.3; done
  grep -qx 'OSTLER_LANG=<unset>' "$BOXHOME/driver.env" 2>/dev/null
  arm "CONTROL no --lang: the driver sees OSTLER_LANG unset" $?

  # A2b SAFETY PARITY: the --lang line and the default line pass the SAME env
  # variables apart from OSTLER_LANG. A launch-line rewrite once dropped the
  # walk-owner guard and the iMessage shim on exactly this path.
  a="$(launch_cmd "$WALK" ja)"; b="$(launch_cmd "$WALK" "")"
  diff <(launch_env_set "$a" | grep -v '^OSTLER_LANG=$') <(launch_env_set "$b") >/dev/null
  arm "PARITY: --lang and default launch lines carry the same env variables apart from OSTLER_LANG" $?
  launch_env_set "$b" | grep -qx 'OSTLER_WALK_OWNER_FILE=' && launch_env_set "$b" | grep -qx 'PWG_IMESSAGE_PROBE_OUTCOME=' \
    && launch_env_set "$a" | grep -qx 'OSTLER_WALK_OWNER_FILE=' && launch_env_set "$a" | grep -qx 'PWG_IMESSAGE_PROBE_OUTCOME='
  arm "PARITY: both lines carry OSTLER_WALK_OWNER_FILE and PWG_IMESSAGE_PROBE_OUTCOME" $?

  # A3 the real ttywalk.sh refuses an invalid code BEFORE any ssh, as CANNOT-RUN (2)
  new_box a3
  for bad in xx-YY 'ja;touch /tmp/pwned' 'JA' ''; do
    [ -z "$bad" ] && continue
    out="$(PATH="$T/bin:$PATH" bash "$WALK" --host u@box --lang "$bad" 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] && [ ! -s "$SSH_LOG" ] && case "$out" in *"not an installer locale"*) true;; *) false;; esac
    arm "invalid --lang '${bad}': refused rc 2, zero ssh calls, reason stated" $?
  done

  # A4 the answers file: mapped pairs, computed answers from the driver, English pairs left to the built-in table
  new_box a4
  ( . "$LIB"; SSH=(ssh -o X=1 box); walk_lang_stage ostler-ttywalk ja "$GEN" >"$T/stage.out" 2>&1 ); rc=$?
  [ "$rc" -eq 0 ] && [ -s "$(ANS)" ]; arm "stage: answers file written on the box" $?
  n=$(grep -c . "$(ANS)"); [ "$n" -eq 19 ]; arm "stage: 19 rows (16 mapped + 3 computed); got $n" $?
  grep -qx $'続けますか?\ty' "$(ANS)" && grep -qx $'パスフレーズを選択\t@passphrase' "$(ANS)" && grep -qx $'氏名(連絡先に表示されているとおり)\t@owner_name' "$(ANS)"
  arm "stage: ja prompt substrings map to the built-in answers (y / @passphrase / @owner_name)" $?
  TAB=$'\t'; grep -qE "${TAB}UTC\$" "$(ANS)" && [ "$(grep -cE "${TAB}44\$" "$(ANS)")" -eq 2 ]
  arm "stage: computed answers = the driver's defaults (cc 44 x2, tz UTC) with no .walk-locale.tsv" $?
  new_box a4b; printf 'country_code\t81\ntimezone\tAsia/Tokyo\n' > "$BOXHOME/.walk-locale.tsv"
  ( . "$LIB"; SSH=(ssh -o X=1 box); walk_lang_stage ostler-ttywalk ja "$GEN" >/dev/null 2>&1 )
  [ "$(grep -cE "${TAB}81\$" "$(ANS)")" -eq 2 ] && grep -qE "${TAB}Asia/Tokyo\$" "$(ANS)"
  arm "stage: computed answers follow the box's ~/.walk-locale.tsv (81 x2, Asia/Tokyo), not a hard-coded value" $?
  ! grep -qE 'Ready to install|Your decision|Store your login|Look up public|third-party' "$(ANS)"
  arm "stage: the 5 consent/autologin prompts get NO row (they stay on the English built-in table)" $?
  new_box a5   # strings file for the language absent: refuse, do not fall back silently
  rm -f "$BOXHOME/ostler-ttywalk/install.sh.strings.ja.sh"
  ( . "$LIB"; SSH=(ssh -o X=1 box); walk_lang_stage ostler-ttywalk ja "$GEN" >/dev/null 2>&1 ); rc=$?
  [ "$rc" -eq 2 ] && [ ! -e "$(ANS)" ]; arm "stage: staged tree without the strings file is CANNOT-RUN (2), nothing written" $?

  # A6 cleanup removes the file and restores an operator's own override
  new_box a6
  ( . "$LIB"; SSH=(ssh -o X=1 box); walk_lang_stage ostler-ttywalk ja "$GEN" >/dev/null 2>&1; walk_lang_cleanup ostler-ttywalk )
  [ ! -e "$(ANS)" ] && [ ! -e "$BOXHOME/.walk-answers.tsv.lang-staged" ] && [ ! -e "$BOXHOME/ostler-ttywalk/scripts/gen_walk_answers_lang.py" ]
  arm "cleanup: answers file, sentinel and generator all gone" $?
  new_box a7; printf 'operator\tkeep\n' > "$(ANS)"
  ( . "$LIB"; SSH=(ssh -o X=1 box); walk_lang_stage ostler-ttywalk ja "$GEN" >/dev/null 2>&1; walk_lang_cleanup ostler-ttywalk )
  [ "$(cat "$(ANS)" 2>/dev/null)" = $'operator\tkeep' ]; arm "cleanup: an operator's own ~/.walk-answers.tsv is restored byte for byte" $?

  # A8 the REAL ttywalk exit trap runs the cleanup when the walk dies (exit 1 and SIGTERM)
  ex="$T/exit_fn.sh"; awk '/^_ttywalk_on_exit\(\) \{/,/^}/' "$WALK" > "$ex"; grep -E '^trap ' "$WALK" >> "$ex"
  [ "$(grep -c '^_ttywalk_on_exit' "$ex")" -ge 1 ] || { arm "could not extract the real exit trap from ttywalk.sh" 1; return; }
  for how in 'exit 1' 'kill -TERM $(sh -c "echo \$PPID")'; do
    new_box a8
    ( . "$LIB"; SSH=(ssh -o X=1 box); REMOTE_DIR=ostler-ttywalk; DMG_MNT=""; LANG_STAGED=0
      . "$ex"
      walk_lang_stage ostler-ttywalk ja "$GEN" >/dev/null 2>&1
      [ -s "$(ANS)" ] || exit 99
      eval "$how"; sleep 5 ); rc=$?
    [ "$rc" -ne 99 ] && [ ! -e "$(ANS)" ] && [ ! -e "$BOXHOME/.walk-answers.tsv.lang-staged" ]
    arm "walk dies by '${how}' (rc ${rc}): the staged answers file is removed by ttywalk's own trap" $?
  done
  # a failed stage (generator breaks) also cleans
  new_box a9
  ( . "$LIB"; SSH=(ssh -o X=1 box); REMOTE_DIR=ostler-ttywalk; DMG_MNT=""; LANG_STAGED=0; . "$ex"
    printf 'raise SystemExit(3)\n' > "$T/badgen.py"; walk_lang_stage ostler-ttywalk ja "$T/badgen.py" >/dev/null 2>&1; exit 2 ); rc=$?
  [ "$rc" -eq 2 ] && [ ! -e "$(ANS)" ] && [ ! -e "$BOXHOME/ostler-ttywalk/scripts/gen_walk_answers_lang.py" ]
  arm "a generator failure: CANNOT-RUN 2, and nothing is left on the box" $?
}

echo "== real subject"
run_arms "$REPO/scripts/lib_walk_lang.sh" "$REPO/scripts/ttywalk.sh"
P0=$PASS; F0=$FAIL

echo "== static"
[ "$(grep -cE "^[[:space:]]*trap .* EXIT|^trap .*EXIT" "$REPO/scripts/ttywalk.sh")" -eq 1 ]
arm "ttywalk.sh arms exactly ONE EXIT trap (a second would silently replace the cleanup)" $?
[ "$(grep -c 'nohup python3 scripts/walk_drive.py' "$REPO/scripts/ttywalk.sh")" -eq 1 ] && ! grep -q 'python3 scripts/walk_drive.py' "$REPO/scripts/lib_walk_lang.sh"
arm "exactly ONE walk_drive.py launch line, in ttywalk.sh; lib_walk_lang.sh launches nothing" $?
grep -q 'walk_lang_stage "\$REMOTE_DIR"' "$REPO/scripts/ttywalk.sh"; arm "ttywalk.sh calls walk_lang_stage" $?
bad=0; for f in "$REPO"/install.sh.strings.*.sh; do c="$(basename "$f" .sh)"; c="${c#install.sh.strings.}"; ( . "$REPO/scripts/lib_walk_lang.sh"; walk_lang_valid "$c" ) || { echo "    locale '$c' has a strings file but is not in WALK_LANGS"; bad=1; }; done
arm "every install.sh.strings.<code>.sh in the repo is an accepted --lang code" $bad

echo "== mutants (each must turn an arm red)"
mutant() {  # name, file-to-break, sed expr
  local name="$1" file="$2" expr="$3" M="$T/mut.$1" before=$FAIL
  mkdir -p "$M/scripts"; cp "$REPO/scripts/ttywalk.sh" "$REPO/scripts/lib_walk_lang.sh" "$M/scripts/"
  cp -R "$REPO/scripts/box_walk_probes" "$M/scripts/" 2>/dev/null
  sed -i.bak "$expr" "$M/scripts/$file" && rm -f "$M/scripts/$file.bak"
  if cmp -s "$M/scripts/$file" "$REPO/scripts/$file"; then echo "CANNOT-RUN: mutant '$name' did not apply"; exit 2; fi
  local sp=$PASS sf=$FAIL; PASS=0; FAIL=0
  run_arms "$M/scripts/lib_walk_lang.sh" "$M/scripts/ttywalk.sh" >/dev/null 2>&1
  local mf=$FAIL; PASS=$sp; FAIL=$sf
  [ "$mf" -gt 0 ]; arm "MUST-FAIL mutant '$name' is caught ($mf arm(s) red)" $?
}
mutant drop-ostler-lang ttywalk.sh "s/LANG_ENV=\"OSTLER_LANG='\${WALK_LANG}' \"/LANG_ENV=\"\"/"
mutant lang-line-drops-owner ttywalk.sh 's/^    OSTLER_WALK_OWNER_FILE=.*/    OSTLER_WALK_OWNER_FILE="" \\/;s/OSTLER_GUI=1 \${LANG_ENV}nohup/OSTLER_GUI=1 ${LANG_ENV}nohup/'
mutant launch-drops-imessage-shim ttywalk.sh '/^    PWG_IMESSAGE_PROBE_OUTCOME=.*\\$/d'
mutant lang-line-renames-shim-var ttywalk.sh 's/^    PWG_IMESSAGE_PROBE_OUTCOME=/    ${WALK_LANG:+X_}PWG_IMESSAGE_PROBE_OUTCOME=/'
mutant skip-cleanup ttywalk.sh 's/^        walk_lang_cleanup "\$REMOTE_DIR"$/        :/'

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
