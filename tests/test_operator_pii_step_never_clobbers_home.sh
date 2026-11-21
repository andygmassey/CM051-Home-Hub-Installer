#!/usr/bin/env bash
# The "Materialise PII inventory" step of operator-pii-scan.yml writes
# $HOME/.ostler-operator-pii.toml. Replayed locally it overwrote an operator's real
# inventory twice (2026-10-22). It must write only on a GitHub runner
# (GITHUB_ACTIONS == true) and never over an existing file. The step's run block is
# extracted from the workflow and executed, under a temp HOME only.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
WF=.github/workflows/operator-pii-scan.yml
pass=0; fail=0
ok(){ echo "  ok   $1"; pass=$((pass+1)); }; no(){ echo "  FAIL $1"; fail=$((fail+1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 -I - "$WF" "$T/step.sh" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
i = next(n for n, l in enumerate(lines) if "name: Materialise PII inventory" in l)
j = next(n for n in range(i, len(lines)) if lines[n].strip() == "run: |")
out = []
for l in lines[j + 1:]:
    if l.strip() and not l.startswith(" " * 10):
        break
    out.append(l[10:])
open(sys.argv[2], "w").write("\n".join(out) + "\n")
PY
[ -s "$T/step.sh" ] && ok "extracted the step script from $WF" || { no "could not extract the step"; echo "$pass passed, $fail failed"; exit 1; }
step(){ # $1 = HOME dir, rest = extra env assignments; secret always set
  env -i PATH="$PATH" HOME="$1" OPERATOR_PII_INVENTORY="from-secret" "${@:2}" bash "$T/step.sh" 2>&1; }
mkhome(){ rm -rf "$T/h"; mkdir -p "$T/h"; [ "${1:-}" = existing ] && printf 'DUMMY-REAL-INVENTORY\n' > "$T/h/.ostler-operator-pii.toml"; cp "$T/h/.ostler-operator-pii.toml" "$T/before" 2>/dev/null; return 0; }
F="$T/h/.ostler-operator-pii.toml"
mkhome existing; out=$(step "$T/h"); rc=$?
[ $rc -eq 0 ] && cmp -s "$F" "$T/before" && grep -q 'SKIP: GITHUB_ACTIONS' <<<"$out" && ok "GITHUB_ACTIONS unset + existing file: file byte-identical, skip reason printed" || { no "unset GITHUB_ACTIONS clobbered or stayed silent"; echo "$out"; }
mkhome existing; out=$(step "$T/h" GITHUB_ACTIONS=false); rc=$?
[ $rc -eq 0 ] && cmp -s "$F" "$T/before" && ok "GITHUB_ACTIONS=false + existing file: byte-identical" || no "GITHUB_ACTIONS=false clobbered"
mkhome existing; out=$(step "$T/h" GITHUB_ACTIONS=true); rc=$?
[ $rc -eq 0 ] && cmp -s "$F" "$T/before" && grep -q 'SKIP: .*already exists' <<<"$out" && ok "on a runner with an existing file: byte-identical, reason printed" || { no "runner overwrote an existing file"; echo "$out"; }
mkhome; out=$(step "$T/h"); rc=$?
[ $rc -eq 0 ] && [ ! -e "$F" ] && ok "GITHUB_ACTIONS unset + no file: nothing is created" || no "wrote outside a runner"
mkhome; out=$(step "$T/h" GITHUB_ACTIONS=true); rc=$?
[ $rc -eq 0 ] && [ "$(cat "$F" 2>/dev/null)" = "from-secret" ] && ok "CONTROL: on a runner with no file the secret IS written (the guard is not a blanket skip)" || { no "control: runner write did not happen"; echo "$out"; }
# Sweep: any workflow line that writes under $HOME must live in this guarded step.
n=$(/usr/bin/grep -nE '(>|>>|tee|cp|mv|mkdir|touch|ln -s)[^|#]*(\$HOME|\$\{HOME\}|~/)' .github/workflows/*.yml | /usr/bin/grep -v 'operator-pii-scan.yml' | /usr/bin/grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | wc -l | tr -d ' ')
[ "$n" -eq 0 ] && ok "no other workflow step writes under \$HOME" || no "$n other workflow line(s) write under \$HOME"
echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
