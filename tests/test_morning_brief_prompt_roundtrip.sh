#!/usr/bin/env bash
# tests/test_morning_brief_prompt_roundtrip.sh
# ============================================================================
# The morning brief's cron block is written by install.sh with bash string
# escaping (_morning_prompt_esc) and echoed into config.toml. The prompt has
# quotes in it, so a broken escape makes the TOML invalid or changes the
# prompt the assistant reads. This test runs the REAL lines from install.sh
# (the prompt assignment, the escape, the echo) and parses the output with a
# real TOML parser (python tomllib), then requires the prompt read back to be
# byte-equal to what bash produced.
#
# It also pins the preferences rules added for walk 132 (dislike_respected_in_
# brief): at most two likes, never a dislike, say nothing when the tool returns
# nothing.
#
# CONTROL: a mutant that drops the escape must make tomllib refuse or the
# round-trip differ (checked below, in a scratch copy).
# ============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="${REPO}/install.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/brief-prompt.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS  $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $*"; }

# Pull the three real lines out of install.sh by pattern.
extract() {  # $1 = install.sh path, $2 = output snippet
    awk '
        /^        _morning_prompt="You are the user/ { print; next }
        /^        _morning_prompt_esc=/ { print; next }
        /^        echo "prompt = \\"\$\{_morning_prompt_esc\}\\""$/ { print; next }
    ' "$1" > "$2"
}

SNIP="$WORK/snippet.sh"
extract "$INSTALL" "$SNIP"
if [[ "$(wc -l < "$SNIP" | tr -d ' ')" == 3 ]]; then
    ok "extracted the three real install.sh lines (assignment, escape, echo)"
else
    bad "expected 3 lines from install.sh, got $(wc -l < "$SNIP" | tr -d ' ')"
    echo "RESULT: $PASS passed, $FAIL failed"; exit 1
fi

# Evaluate the three real lines in order, exactly as install.sh runs them.
OUT="$WORK/cron.toml"; EXP="$WORK/expected.txt"
bash -c '
    set -u
    eval "$(sed -n "1p" "$1")"          # _morning_prompt="..."  (real line 1)
    eval "$(sed -n "2p" "$1")"          # _morning_prompt_esc=...  (real line 2)
    { echo "[[cron.jobs]]"; eval "$(sed -n "3p" "$1")"; } > "$2"
    printf "%s" "$_morning_prompt" > "$3"
' _ "$SNIP" "$OUT" "$EXP" && ok "bash produced the cron block and the expected prompt" || bad "bash could not produce the block"

# 1. real TOML parser accepts the block, and the prompt reads back byte-equal.
RT="$WORK/roundtrip.txt"
if python3 - "$OUT" "$EXP" "$RT" <<'PY'
import sys, tomllib
out, exp, rt = sys.argv[1], sys.argv[2], sys.argv[3]
with open(out, "rb") as f:
    d = tomllib.load(f)
job = d["cron"]["jobs"][0]
with open(rt, "w", encoding="utf-8", newline="") as f:
    f.write(job["prompt"])
with open(exp, "rb") as f:
    want = f.read()
got = job["prompt"].encode("utf-8")
sys.exit(0 if got == want else 1)
PY
then ok "tomllib parses the block and the prompt round-trips byte-equal"
else bad "tomllib refused the block or the prompt differs after the round-trip"; fi

# 2. the rules are in the prompt the assistant will read.
for needle in "call the pwg_derived_preferences tool once" "AT MOST two" "NEVER mention a dislike" "say nothing about tastes" "never invent one"; do
    if grep -q -F "$needle" "$RT"; then ok "rule present: $needle"; else bad "rule missing: $needle"; fi
done

# 3. CONTROL: a mutant without the escape must be caught by the round-trip.
MUT="$WORK/mut_snippet.sh"
sed 's/prompt = \\"\${_morning_prompt_esc}\\"/prompt = \\"${_morning_prompt}\\"/' "$SNIP" > "$MUT"
MOUT="$WORK/mut.toml"; MEXP="$WORK/mut_expected.txt"
bash -c '
    set -u
    eval "$(sed -n "1p" "$1")"
    eval "$(sed -n "2p" "$1")"
    { echo "[[cron.jobs]]"; eval "$(sed -n "3p" "$1")"; } > "$2"
    printf "%s" "$_morning_prompt" > "$3"
' _ "$MUT" "$MOUT" "$MEXP" 2>/dev/null
if python3 - "$MOUT" "$MEXP" <<'PY' 2>/dev/null
import sys, tomllib
out, exp = sys.argv[1], sys.argv[2]
with open(out, "rb") as f:
    d = tomllib.load(f)
with open(exp, "rb") as f:
    want = f.read()
sys.exit(0 if d["cron"]["jobs"][0]["prompt"].encode("utf-8") == want else 1)
PY
then bad "CONTROL: the no-escape mutant passed, so the round-trip cannot see the defect"
else ok "CONTROL: the no-escape mutant is caught (tomllib refuses or the prompt differs)"; fi

echo "RESULT: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
