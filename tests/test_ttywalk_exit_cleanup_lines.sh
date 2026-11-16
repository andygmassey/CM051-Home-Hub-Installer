#!/usr/bin/env bash
# tests/test_ttywalk_exit_cleanup_lines.sh -- the ttywalk.sh exit trap must LOG
# its DMG cleanup and remove the temp mount dir.
#
# WHY: _ttywalk_on_exit detached the --from-dmg mount with `2>/dev/null`,
# printed nothing, and never removed the temp mountpoint. A cleanup that prints
# nothing cannot be told from one that never ran.
#
# The real function text is extracted from scripts/ttywalk.sh and run with a
# FAKE hdiutil on PATH and fake mount dirs under a temp dir. No real disk is
# touched. Arms run through run_arms() so each mutant (a broken copy of the
# subject) must turn at least one arm red.
# 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJ="${TTYWALK_SUBJECT:-$REPO/scripts/ttywalk.sh}"
[ -f "$SUBJ" ] || { echo "CANNOT-RUN: no subject at $SUBJ" >&2; exit 2; }
command -v python3 >/dev/null || { echo "CANNOT-RUN: no python3" >&2; exit 2; }
T="$(mktemp -d)" || { echo "CANNOT-RUN: no temp dir" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin"
cat > "$T/bin/hdiutil" <<'FAKE'
#!/bin/bash
# records argv; FAKE_DETACH = ok | fail-first (force succeeds) | fail-always
echo "hdiutil $*" >> "$FAKE_LOG"
case " $* " in
  *" -force "*) [ "$FAKE_DETACH" = fail-always ] && { echo "force: resource busy" >&2; exit 16; }; exit 0 ;;
  *) [ "$FAKE_DETACH" = ok ] && exit 0; echo "detach: resource busy" >&2; exit 16 ;;
esac
FAKE
chmod +x "$T/bin/hdiutil"
# a fake `say` on PATH: the trap must never reach macOS /usr/bin/say (it speaks aloud)
printf '#!/bin/bash\necho "$*" >> "$SAY_MARKER"\n' > "$T/bin/say"; chmod +x "$T/bin/say"
export SAY_MARKER="$T/say.marker"

FN="$T/fn.sh"
extract() { sed -n '/^_ttywalk_on_exit() {$/,/^}$/p' "$1" > "$FN"; }
extract "$SUBJ"
[ -s "$FN" ] || { echo "CANNOT-RUN: _ttywalk_on_exit not found in $SUBJ" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
has() { grep -qF -- "$2" <<<"$1"; }

# run <detach-mode> <mountpoint, "" for none> <attached 0|1>; sets OUT
run() {
  export FAKE_DETACH="$1" FAKE_LOG="$T/hdiutil.log"; : > "$FAKE_LOG"; rm -f "$SAY_MARKER"
  OUT="$(PATH="$T/bin:$PATH" /bin/bash -c '
    walk_lang_cleanup() { echo "lang-cleanup-ran $1"; }
    LANG_STAGED=1; REMOTE_DIR=remote-x
    DMG_MNT="$1"; DMG_ATTACHED="$2"
    . "$3"
    _ttywalk_on_exit
  ' _ "$2" "$3" "$FN" 2>&1)"
}

run_arms() {
  local tag="$1" mnt
  mnt="$T/mnt.$tag.ok"; mkdir -p "$mnt"
  run ok "$mnt" 1
  has "$OUT" "ttywalk cleanup: DMG detached $mnt" && ok "[$tag] success: detached line" || bad "[$tag] success: detached line missing"
  has "$OUT" "ttywalk cleanup: removed temp dir $mnt" && ok "[$tag] success: removed-dir line" || bad "[$tag] success: removed-dir line missing"
  [ ! -e "$mnt" ] && ok "[$tag] success: temp dir gone" || bad "[$tag] success: temp dir left behind"
  has "$OUT" "lang-cleanup-ran remote-x" && ok "[$tag] success: lang cleanup still runs" || bad "[$tag] success: lang cleanup dropped"

  mnt="$T/mnt.$tag.fail"; mkdir -p "$mnt"
  run fail-first "$mnt" 1
  has "$OUT" "ttywalk cleanup: FAILED to detach $mnt rc=16: detach: resource busy" && ok "[$tag] fail: failure line with rc and stderr" || bad "[$tag] fail: failure line with rc and stderr missing"
  grep -qF -- "-force" "$FAKE_LOG" && ok "[$tag] fail: -force retry attempted" || bad "[$tag] fail: no -force retry"
  has "$OUT" "(with -force retry)" && ok "[$tag] fail: -force retry logged" || bad "[$tag] fail: -force retry not logged"
  [ "$(grep -c '^hdiutil' "$FAKE_LOG")" = 2 ] && ok "[$tag] fail: exactly one retry" || bad "[$tag] fail: retry count != 1"

  mnt="$T/mnt.$tag.dead"; mkdir -p "$mnt"
  run fail-always "$mnt" 1
  has "$OUT" "FAILED to detach $mnt with -force rc=16: force: resource busy" && ok "[$tag] dead: force failure logged with rc" || bad "[$tag] dead: force failure not logged"

  run ok "" 0
  has "$OUT" "ttywalk cleanup: no DMG mounted" && ok "[$tag] nothing mounted: line printed" || bad "[$tag] nothing mounted: line missing"
  [ ! -s "$FAKE_LOG" ] && ok "[$tag] nothing mounted: hdiutil never called" || bad "[$tag] nothing mounted: hdiutil called"
  has "$OUT" "lang-cleanup-ran remote-x" && ok "[$tag] nothing mounted: lang cleanup still runs" || bad "[$tag] nothing mounted: lang cleanup dropped"

  [ ! -e "$SAY_MARKER" ] && ok "[$tag] the trap never calls say(1)" || bad "[$tag] the trap called say(1): $(cat "$SAY_MARKER")"

  mnt="$T/mnt.$tag.noattach"; mkdir -p "$mnt"
  run ok "$mnt" 0
  [ ! -s "$FAKE_LOG" ] && [ ! -e "$mnt" ] && ok "[$tag] attach never happened: no detach, dir still removed" || bad "[$tag] attach-never-happened arm"
}

echo "== subject =="; run_arms real
REAL_FAIL=$FAIL

MISSED=0
mutate() {  # name, python expression over s
  local name="$1" before="$FAIL"
  MUT="$2" python3 - "$SUBJ" "$T/mut.sh" <<'PY'
import os, sys
s = open(sys.argv[1]).read(); o = s
s = eval(os.environ["MUT"])
if s == o: sys.exit(3)
open(sys.argv[2], "w").write(s)
PY
  [ $? -eq 0 ] || { echo "CANNOT-RUN: mutant $name did not apply" >&2; exit 2; }
  extract "$T/mut.sh"
  echo "== mutant: $name =="
  run_arms "m-$name" > "$T/arms.out"; grep FAIL "$T/arms.out" | head -3
  if [ "$FAIL" -gt "$before" ]; then echo "  mutant $name: CAUGHT"; else echo "  mutant $name: NOT CAUGHT"; MISSED=1; fi
}
if [ "$REAL_FAIL" -eq 0 ]; then
  KEEP=$FAIL
  mutate drop-rmdir "s.replace('rmdir \"\$DMG_MNT\"', 'true \"\$DMG_MNT\"')"
  mutate call-say 's.replace("printf \x27%s\\n\x27 \"ttywalk cleanup: no DMG", "say \"ttywalk cleanup: no DMG")'
  mutate silence-stderr "s.replace('-quiet 2>&1 >/dev/null', '-quiet 2>/dev/null')"
  FAIL=$KEEP   # mutants are meant to fail arms; only the subject decides the verdict
fi
echo "subject: pass-lines=$PASS subject-fail=$REAL_FAIL mutants-missed=$MISSED"
[ "$REAL_FAIL" -eq 0 ] && [ "$MISSED" -eq 0 ] && exit 0 || exit 1
