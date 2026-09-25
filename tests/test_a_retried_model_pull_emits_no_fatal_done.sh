#!/usr/bin/env bash
# tests/test_a_retried_model_pull_emits_no_fatal_done.sh
#
# v1.0.102 third candidate walk: `ollama pull gemma4:e2b` failed on attempt 1
# of 3, the retry pulled it, and the install finished DONE status=ok. But the
# GUI wire ALSO carried `STEP_END id=ai_models status=error` and a terminal
# `DONE status=fail code=ERR-99-INSTALL-ABORT-L1878`, emitted from inside the
# pull wrapper's process substitution. A customer's installer reads the first
# DONE it sees.
#
# Cause: _gui_ollama_pull runs `{ ollama pull; echo $? > rc; } | tr` inside
# `< <( ... )`. That shell sits outside the caller's `if`, so `set -Eeuo
# pipefail` and the ERR trap are live there: the failed pull exits the group
# before the status is written, pipefail fails the pipeline, and the ERR trap
# fires.
#
# This lifts the REAL _gui_ollama_pull and ollama_pull_with_retry out of
# install.sh, runs them under install.sh's own `set -Eeuo pipefail` with an
# ERR trap that records every firing, and a stub `ollama` that fails its first
# pull and succeeds on the second. Asserts: the retry returns 0, the stub was
# called twice, and the ERR trap fired ZERO times. Control: the same harness
# with a pull that always fails must still return non-zero (the wrapper did
# not start swallowing failures).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fails=0

awk '/^_gui_ollama_pull\(\) \{/{f=1} f{print} f&&/^}$/{f=0}
     /^ollama_pull_with_retry\(\) \{/{g=1} g{print} g&&/^}$/{g=0}' \
    "$ROOT/install.sh" > "$W/fns.sh"
[ "$(grep -c '^_gui_ollama_pull() {' "$W/fns.sh")" -eq 1 ] \
  && [ "$(grep -c '^ollama_pull_with_retry() {' "$W/fns.sh")" -eq 1 ] \
  || { echo "CANNOT-RUN: could not lift the pull functions out of install.sh"; exit 2; }

run() {   # run <fail-count-before-success: 1 or 99>  -> prints "rc calls errs"
    local n="$1" d="$W/run$1"; mkdir -p "$d/bin"
    cat > "$d/bin/ollama" <<O
#!/bin/sh
c=\$(cat "$d/calls" 2>/dev/null || echo 0); c=\$((c+1)); echo "\$c" > "$d/calls"
if [ "\$c" -le $n ]; then echo "Error: pull model manifest: connection reset" >&2; exit 1; fi
printf 'pulling 4e30e2665218:  50%%\r'; printf 'pulling 4e30e2665218: 100%%\n'; exit 0
O
    chmod +x "$d/bin/ollama"
    PATH="$d/bin:/usr/bin:/bin" D="$d" FNS="$W/fns.sh" bash -c '
        set -Eeuo pipefail
        trap '\''echo x >> "$D/errs"'\'' ERR
        OSTLER_GUI=1
        gui_emit(){ :; }; gui_log(){ :; }; warn(){ :; }; sleep(){ :; }
        MSG_WARN_OLLAMA_PULL_FAILED_ATTEMPT_3_RETRYING="%s %s %s"
        . "$FNS"
        rc=0; ollama_pull_with_retry gemma4:e2b || rc=$?
        echo "$rc $(cat "$D/calls" 2>/dev/null || echo 0) $(wc -l < "$D/errs" 2>/dev/null | tr -d " " || echo 0)"
    ' 2>/dev/null
}

read -r rc calls errs <<<"$(run 1)"
errs="${errs:-0}"
if [ "$rc" = 0 ] && [ "$calls" = 2 ] && [ "$errs" = 0 ]; then
    echo "ok    one transient failure, then success: rc=0, 2 pulls, ERR trap fired 0 times"
else
    echo "FAIL  one transient failure, then success: rc=$rc pulls=$calls ERR-trap firings=$errs (want 0 2 0)"; fails=$((fails+1))
fi

read -r rc calls errs <<<"$(run 99)"
if [ "$rc" != 0 ] && [ "$calls" = 3 ]; then
    echo "ok    control, every pull fails: rc=$rc after 3 pulls (failure still reported)"
else
    echo "FAIL  control, every pull fails: rc=$rc pulls=$calls (want non-zero after 3)"; fails=$((fails+1))
fi

[ "$fails" -eq 0 ] && { echo "PASS: a retried model pull emits no fatal ERR marker"; exit 0; }
echo "FAIL: $fails arm(s)"; exit 1
