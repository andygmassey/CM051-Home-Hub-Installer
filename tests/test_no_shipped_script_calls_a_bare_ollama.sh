#!/usr/bin/env bash
# tests/test_no_shipped_script_calls_a_bare_ollama.sh
#
# NEW-119 guard. The Hub's engine lives only at ~/.ostler/runtime/ollama-<pin>/
# ollama and is never on PATH, so any shipped file that reaches Ollama by NAME
# is rc 127 on a clean Mac (that is how step 12/44 aborted with
# ERR-13-MODEL-PULL-NOMIC). scripts/check_no_bare_ollama.py scans the tracked
# tree; this test proves it can see before believing its clean answer.
#
#   P  positive control: a synthetic tree with one bare call of every shape
#      (shell, `if ... list |`, command -v, python argv, plist argv0, customer
#      copy, run-wrapper argv) and the look-alikes that must NOT hit (pinned
#      variable, absolute path, comment, pgrep pattern, provider-name tuple).
#      Exactly the positive lines must be reported, by line number.
#   S  a stale allowlist row is a failure (the list cannot rot).
#   R  the real tree: rc 0, and a NON-zero file count (a zero denominator is
#      CANNOT-RUN, not clean).
#   M  mutant: install.sh with its pull put back to a bare `ollama pull` must
#      be reported.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHK="$ROOT/scripts/check_no_bare_ollama.py"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fails=0
pass(){ echo "ok    $*"; }
bad(){ echo "FAIL  $*"; fails=$((fails+1)); }

# ── P ────────────────────────────────────────────────────────────────────────
F="$W/fx"; mkdir -p "$F/bin" "$F/agent" "$F/launchd"
cat > "$F/bin/run.sh" <<'SH'
#!/bin/bash
ollama pull nomic-embed-text
if ollama list 2>/dev/null | grep -q qwen; then :; fi
if command -v ollama >/dev/null; then :; fi
hpa_run "unload" ollama stop "$m"
"$OLLAMA_APP_BIN" pull nomic-embed-text
/Users/x/.ostler/runtime/ollama-0.34.0/ollama list
# ollama pull is mentioned in this comment only
pid="$(pgrep -f 'ollama serve' | head -1)"
SH
cat > "$F/agent/copy.py" <<'PY'
import subprocess
subprocess.run(["ollama", "pull", "nomic-embed-text"])
FIX = "Run: ollama pull nomic-embed-text"
CHECKS = [("ollama", OLLAMA_URL, "/")]
PY
cat > "$F/launchd/x.plist" <<'PL'
<array>
    <string>ollama</string>
    <string>serve</string>
</array>
<array>
    <string>/Users/x/.ostler/runtime/ollama-0.34.0/ollama</string>
</array>
PL
printf '%s\n' bin/run.sh agent/copy.py launchd/x.plist > "$W/fx.list"
: > "$W/empty.tsv"
out="$(python3 -I "$CHK" --root "$F" --allowlist "$W/empty.tsv" --files-from "$W/fx.list" 2>&1)"; rc=$?
got="$(sed -nE 's/^FAIL  ([^ ]+:[0-9]+) .*/\1/p' <<<"$out" | sort | tr '\n' ' ')"
want="agent/copy.py:2 agent/copy.py:3 bin/run.sh:2 bin/run.sh:3 bin/run.sh:4 bin/run.sh:5 launchd/x.plist:2 "
if [ "$rc" = 1 ] && [ "$got" = "$want" ] && grep -q '^scanned 3 files; 7 bare-ollama hit' <<<"$out"; then
    pass "P positive control: 7 planted bare calls (shell x3, run-wrapper, python argv, copy, plist argv0) reported; 6 look-alikes not"
else
    bad "P positive control: rc=$rc got [$got] want [$want]  out: $(tr '\n' ' ' <<<"$out" | cut -c1-400)"
fi

# ── S ────────────────────────────────────────────────────────────────────────
printf 'bin/run.sh\tollama pull nothing-like-this\tfixture\n' > "$W/stale.tsv"
printf '%s\n' bin/run.sh > "$W/one.list"
out="$(python3 -I "$CHK" --root "$F" --allowlist "$W/stale.tsv" --files-from "$W/one.list" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q 'stale allowlist row' <<<"$out"; then pass "S a stale allowlist row fails the check"
else bad "S stale allowlist row not reported: rc=$rc $(tr '\n' ' ' <<<"$out" | cut -c1-300)"; fi

# ── R ────────────────────────────────────────────────────────────────────────
out="$(python3 -I "$CHK" --root "$ROOT" 2>&1)"; rc=$?
n="$(sed -nE 's/^scanned ([0-9]+) files.*/\1/p' <<<"$out")"
if [ "$rc" = 0 ] && [ "${n:-0}" -gt 100 ]; then pass "R real tree: $(tail -1 <<<"$out")"
elif [ -z "$n" ]; then bad "R scanner did not run to completion (CANNOT-RUN, not clean): $(tr '\n' ' ' <<<"$out" | cut -c1-400)"
else bad "R real tree has bare ollama calls:"; echo "$out"; fi

# ── M ────────────────────────────────────────────────────────────────────────
mkdir -p "$W/mut"
sed 's/^\([[:space:]]*\)"\$OLLAMA_APP_BIN" pull "\$model"$/\1ollama pull "$model"/' "$ROOT/install.sh" > "$W/mut/install.sh"
if cmp -s "$ROOT/install.sh" "$W/mut/install.sh"; then
    bad "M mutant did not apply (the pinned pull site moved): CANNOT-RUN"
else
    echo install.sh > "$W/mut.list"
    out="$(python3 -I "$CHK" --root "$W/mut" --allowlist "$W/empty.tsv" --files-from "$W/mut.list" 2>&1)"; rc=$?
    if [ "$rc" = 1 ] && grep -q '^FAIL  install.sh:[0-9]* \[shell\] bare ollama: ollama pull "\$model"' <<<"$out"; then
        pass "M bare \`ollama pull\` put back into install.sh is caught: $(grep -m1 '^FAIL' <<<"$out" | cut -c1-90)"
    else bad "M mutant not caught: rc=$rc $(tr '\n' ' ' <<<"$out" | cut -c1-300)"; fi
fi

if [ "$fails" -gt 0 ]; then echo "RED: $fails failure(s)"; exit 1; fi
echo "GREEN"
