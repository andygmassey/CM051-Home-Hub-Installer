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
# The wrapper pipes the stream into ollama_pull_progress (lib/progress_emitter.sh, sourced
# by install.sh in production); a harness without it makes the pipe return 127 and the ERR
# trap fire for a reason the product never meets. Lift the real one.
awk '/^ollama_pull_progress\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$ROOT/lib/progress_emitter.sh" >> "$W/fns.sh"
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
    # install.sh is macOS-only and calls BSD `mktemp -t <prefix>`; GNU mktemp
    # refuses a -t prefix with no XXX, which would make every pull "fail" on a
    # Linux runner for a reason the product never meets. Shim it to the BSD
    # meaning so the arm measures the pull wrapper, not the runner's mktemp.
    cat > "$d/bin/mktemp" <<'M'
#!/bin/sh
if [ "${1:-}" = "-t" ]; then exec /usr/bin/mktemp "${TMPDIR:-/tmp}/${2:-tmp}.XXXXXX"; fi
exec /usr/bin/mktemp "$@"
M
    chmod +x "$d/bin/ollama" "$d/bin/mktemp"
    PATH="$d/bin:/usr/bin:/bin" OLLAMA_APP_BIN="$d/bin/ollama" D="$d" FNS="$W/fns.sh" bash -c '
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

# Arm 3 (16 GB tier, qwen3.5:4b): the CALL SITE. Lift the real `_pull_rc=0; ollama_pull_with_retry
# "$AI_MODEL"` .. `esac` block out of install.sh and run it with the real retry wrapper over an
# always-failing `ollama`. A failed pull must END the install with ERR-13-MODEL-PULL-AI (customer
# sees "Could not pull ... re-run the installer"), never reach the "ready" ok line, never get as far
# as the digest gate. Control: a succeeding pull reaches ok + digest gate and never fail_with_code.
awk '/_pull_rc=0; ollama_pull_with_retry "\$AI_MODEL"/{f=1} f{print} f&&/^        esac$/{exit}' \
    "$ROOT/install.sh" > "$W/callsite.sh"
if [ "$(grep -c 'ERR-13-MODEL-PULL-AI' "$W/callsite.sh")" -ne 1 ]; then
    echo "CANNOT-RUN: could not lift the pull call site out of install.sh"; exit 2
fi
callsite() {   # callsite <fail-count-before-success> -> "ok_calls fail_code digest_calls"
    local n="$1" d="$W/cs$1"; mkdir -p "$d/bin"
    cp "$W/run1/bin/mktemp" "$d/bin/mktemp" 2>/dev/null || cp "$W/run99/bin/mktemp" "$d/bin/mktemp"
    cat > "$d/bin/ollama" <<O
#!/bin/sh
c=\$(cat "$d/calls" 2>/dev/null || echo 0); c=\$((c+1)); echo "\$c" > "$d/calls"
if [ "\$c" -le $n ]; then echo "Error: pull model manifest: connection reset" >&2; exit 1; fi
printf 'pulling 4e30e2665218: 100%%\n'; exit 0
O
    chmod +x "$d/bin/ollama" "$d/bin/mktemp"
    PATH="$d/bin:/usr/bin:/bin" OLLAMA_APP_BIN="$d/bin/ollama" D="$d" FNS="$W/fns.sh" CS="$W/callsite.sh" bash -c '
        set -Eeuo pipefail
        OSTLER_GUI=1
        gui_emit(){ :; }; gui_log(){ :; }; warn(){ :; }; sleep(){ :; }; info(){ :; }
        MSG_WARN_OLLAMA_PULL_FAILED_ATTEMPT_3_RETRYING="%s %s %s"
        MSG_OK_READY="%s"; MSG_FAIL_COULD_NOT_PULL_AFTER_3_ATTEMPTS="%s"
        ok(){ echo ok >> "$D/oks"; }
        ostler_require_model_digest(){ echo dg >> "$D/dg"; }
        fail_with_code(){ echo "$1" > "$D/fail"; return 0; }
        . "$FNS"
        AI_MODEL=qwen3.5:4b
        . "$CS"
        echo "$(wc -l < "$D/oks" 2>/dev/null | tr -d " " || echo 0) $(cat "$D/fail" 2>/dev/null || echo none) $(wc -l < "$D/dg" 2>/dev/null | tr -d " " || echo 0)"
    ' 2>/dev/null
}
read -r oks code dg <<<"$(callsite 99)"
if [ "$code" = ERR-13-MODEL-PULL-AI ] && [ "${oks:-0}" = 0 ] && [ "${dg:-0}" = 0 ]; then
    echo "ok    qwen3.5:4b pull fails 3x: install ends ERR-13-MODEL-PULL-AI, no ready line, no digest gate"
else
    echo "FAIL  qwen3.5:4b pull fails 3x: fail_code=$code oks=$oks digest_calls=$dg (want ERR-13-MODEL-PULL-AI 0 0)"; fails=$((fails+1))
fi
read -r oks code dg <<<"$(callsite 1)"
if [ "$code" = none ] && [ "${oks:-0}" = 1 ] && [ "${dg:-0}" = 1 ]; then
    echo "ok    control, one transient failure: ready + digest gate, no fail code"
else
    echo "FAIL  control, one transient failure: fail_code=$code oks=$oks digest_calls=$dg (want none 1 1)"; fails=$((fails+1))
fi

[ "$fails" -eq 0 ] && { echo "PASS: a retried model pull emits no fatal ERR marker"; exit 0; }
echo "FAIL: $fails arm(s)"; exit 1
