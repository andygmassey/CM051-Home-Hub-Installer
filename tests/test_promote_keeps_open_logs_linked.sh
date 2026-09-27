#!/usr/bin/env bash
# #2434: promoting the staging tree must MERGE logs/ into ~/.ostler/logs, never
# rm -rf it, or a service started before the promote (Ollama, install step 5)
# keeps writing to an unlinked file with no path. Lifts _ostler_promote_entry
# from install.sh and holds a file open across the promote.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOLD=""; W="$(mktemp -d)"; trap 'kill $HOLD 2>/dev/null; rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $*"; }
# Lift the promote's per-entry body (the logs/ merge branch plus the replace
# branch) out of _ostler_promote_prelaunch_tree and wrap it as a function, so
# the test runs the exact bytes the installer runs.
awk '/^_ostler_promote_prelaunch_tree\(\) \{/{f=1} f&&/name="\$\(basename "\$entry"\)"/{g=1;next} g&&/^    done$/{exit} g{print}' "$ROOT/install.sh" > "$W/body.sh"
grep -q 'name" == "logs"' "$W/body.sh" || { bad "the promote has no logs/ merge branch"; echo "$PASS passed, $FAIL failed"; exit 1; }
{ echo '_ostler_promote_entry() {'; echo '  local entry="$1" OSTLER_FINAL_DIR="$2" name f; name="$(basename "$entry")"'; echo '  for _once in 1; do'; cat "$W/body.sh"; echo '  done'; echo '}'; } > "$W/fn.sh"
. "$W/fn.sh"
F="$W/final"; S="$W/stage"
mkdir -p "$F/logs" "$S/logs" "$S/bin" "$F/bin"
echo old > "$F/bin/tool"; echo new > "$S/bin/tool"
printf 'install line\n' > "$S/logs/install.log"
# a "service" holds ~/.ostler/logs/ollama.err open, as Ollama does
: > "$F/logs/ollama.err"
( exec 3>>"$F/logs/ollama.err"; while :; do echo tick >&3; sleep 0.2; done ) & HOLD=$!
sleep 0.5
ino_before=$(stat -f %i "$F/logs/ollama.err")
for e in "$S"/*; do _ostler_promote_entry "$e" "$F"; done
sleep 0.5
[ -e "$F/logs/ollama.err" ] && ok "ollama.err still has a path after the promote" || bad "ollama.err was unlinked by the promote"
[ "$(stat -f %i "$F/logs/ollama.err" 2>/dev/null)" = "$ino_before" ] && ok "same inode: the open file and the path agree" || bad "ollama.err is a different file now"
s1=$(stat -f %z "$F/logs/ollama.err" 2>/dev/null || echo 0); sleep 0.6; s2=$(stat -f %z "$F/logs/ollama.err" 2>/dev/null || echo 0)
[ "$s2" -gt "$s1" ] && ok "the running writer's output is visible at the path ($s1 -> $s2 bytes)" || bad "writer output not visible at the path"
[ -f "$F/logs/install.log" ] && ok "staging logs/ contents merged in (install.log)" || bad "install.log not merged"
[ ! -e "$S/logs" ] && ok "staging logs/ removed after the merge" || bad "staging logs/ left behind"
[ "$(cat "$F/bin/tool")" = new ] && ok "control: other entries keep replace semantics (bin/ replaced)" || bad "bin/ was not replaced"
# MUTATION ARM: the pre-fix semantics (rm -rf the final entry, then mv) must
# unlink the open file, or this test could not have caught the defect.
mut() { local entry="$1" final="$2" name; name="$(basename "$entry")"; [[ -e "${final}/${name}" ]] && rm -rf "${final}/${name}"; mv "$entry" "${final}/${name}"; }
F2="$W/final2"; S2="$W/stage2"; mkdir -p "$F2/logs" "$S2/logs"; printf 'x\n' > "$S2/logs/install.log"; : > "$F2/logs/ollama.err"
( exec 4>>"$F2/logs/ollama.err"; while :; do echo tick >&4; sleep 0.2; done ) & HOLD2=$!
sleep 0.4; i2=$(stat -f %i "$F2/logs/ollama.err")
for e in "$S2"/*; do mut "$e" "$F2"; done
kill $HOLD2 2>/dev/null
[ "$(stat -f %i "$F2/logs/ollama.err" 2>/dev/null || echo gone)" != "$i2" ] && ok "MUST-FAIL mutant (old rm -rf + mv) unlinks the open log, so the arms above are real" || bad "the old semantics did NOT unlink the open log: this test proves nothing"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
