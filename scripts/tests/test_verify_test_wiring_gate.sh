#!/usr/bin/env bash
#
# test_verify_test_wiring_gate.sh -- prove the wiring gate can tell a MENTION
# from an INVOCATION.
#
# This gate had no self-test, and the thing it got wrong is the exact thing it
# exists to decide. It substring-searched whole workflow bodies, comments
# included, so a test scored WIRED if any workflow merely NAMED it.
#
# Found 2026-08-15 the only way this gets found: it bit the commit fixing the
# backlog. A workflow comment listing unwired tests, written to document that
# they do NOT run, marked them WIRED. Four tests in the committed manifest were
# recorded as covered while appearing in no workflow's run steps at all, and two
# of those four were failing.
#
# The controls below are the two that matter and they must both hold:
#   a workflow that only MENTIONS a test in a comment  -> that test stays UNWIRED
#   a workflow that actually RUNS it                   -> that test becomes WIRED
#
# Without the second control the first is satisfiable by a gate that marks
# everything unwired, which is the failure mode of over-correcting.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$HERE/scripts/verify_test_wiring.sh"
[[ -x "$GATE" || -f "$GATE" ]] || { echo "FAIL: gate not found at $GATE"; exit 99; }

PASS=0; FAIL=0
ok()  { printf '  \033[0;32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d -t wiring_gate_XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Minimal fixture repo: two tests, one workflow.
mkdir -p "$TMP/tests" "$TMP/.github/workflows" "$TMP/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/tests/test_only_mentioned.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/tests/test_really_run.sh"
cp "$GATE" "$TMP/scripts/"

cat > "$TMP/.github/workflows/fixture.yml" <<'YML'
name: fixture
# This comment names tests/test_only_mentioned.sh to document that it does NOT
# run. A gate that reads comments will score it WIRED on the strength of this
# sentence alone, which is the defect under test.
on: [push]
jobs:
  fixture:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/test_really_run.sh
YML

out="$(cd "$TMP" && bash scripts/verify_test_wiring.sh --regenerate 2>&1)"
man="$TMP/tests/TEST_WIRING.tsv"

if [[ ! -f "$man" ]]; then
    bad "gate produced no manifest at all"
    echo "$out" | sed 's/^/        /'
    echo; echo "  $PASS passed, $FAIL failed"; exit 1
fi

# CONTROL 1: mentioned in a comment only -> must be UNWIRED.
if grep -qE "^test_only_mentioned\.sh[[:space:]]+UNWIRED" "$man"; then
    ok "a test named only in a COMMENT stays UNWIRED"
else
    bad "a test named only in a comment was scored WIRED -- the gate reads comments"
    grep -E "^test_only_mentioned" "$man" | sed 's/^/        /'
fi

# CONTROL 2: actually invoked in a run step -> must be WIRED. Without this, a
# gate that marks everything unwired would pass control 1 and be useless.
if grep -qE "^test_really_run\.sh[[:space:]]+WIRED" "$man"; then
    ok "a test actually invoked in a run step is WIRED"
else
    bad "a genuinely invoked test was scored UNWIRED -- the gate now under-reports"
    grep -E "^test_really_run" "$man" | sed 's/^/        /'
fi

echo
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
