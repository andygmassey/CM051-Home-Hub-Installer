#!/usr/bin/env bash
#
# tests/test_verify_ci_steps_are_maskless.sh
#
# Self-test for the CI step-masking gate (#683).
#
# The gate exists because a skipped proof and a passed proof look the same from
# a distance. This suite exists because that is equally true of the gate itself:
# a checker that never fires is indistinguishable from a clean repo. So every
# control below pins a DIRECTION -- what must fire, and just as importantly what
# must NOT, because a gate that flags the innocent gets switched off within a
# week and that is the same outcome as never having written it.
#
# Exit 0 all controls pass / 1 a control failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${REPO_ROOT}/scripts/verify_ci_steps_are_maskless.py"

if [[ ! -f "$GATE" ]]; then
    echo "FAIL: gate not found at $GATE" >&2
    exit 1
fi

if ! python3 -c 'import yaml' 2>/dev/null; then
    echo "COULD NOT RUN: PyYAML absent, so the gate cannot be exercised." >&2
    echo "This is a cannot-run (exit 2), not a pass." >&2
    exit 2
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/maskless-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

# expect <label> <expected_rc> <dir>
expect() {
    local label="$1" want="$2" dir="$3" out rc
    out="$(python3 "$GATE" "$dir" 2>&1)"; rc=$?
    if [[ "$rc" == "$want" ]]; then
        ok "$label (exit $rc)"
    else
        bad "$label -- expected exit $want, got $rc"
        printf '%s\n' "$out" | sed 's/^/        /'
    fi
}

newdir() { rm -rf "$TMP/$1"; mkdir -p "$TMP/$1"; echo "$TMP/$1"; }

printf '== test_verify_ci_steps_are_maskless ==\n'

# ── 1. THE DEFECT: a second test step with no always() ────────────
d="$(newdir wf1)"
cat > "$d/w.yml" <<'YAML'
name: w
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: first test
        run: bash tests/test_alpha.sh
      - name: second test
        run: bash tests/test_beta.sh
YAML
expect "a later test step WITHOUT always() is flagged" 1 "$d"

# and it must NAME the offender, or the report is unactionable
_out="$(python3 "$GATE" "$d" 2>&1)"
if printf '%s\n' "$_out" | grep -q 'second test'; then
    ok "names the maskable step"
else
    bad "the maskable step is not NAMED in the output"
    printf '%s\n' "$_out" | sed 's/^/        /'
fi

# ── 2. the same file, fixed ───────────────────────────────────────
d="$(newdir wf2)"
cat > "$d/w.yml" <<'YAML'
name: w
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: first test
        run: bash tests/test_alpha.sh
      - name: second test
        if: always()
        run: bash tests/test_beta.sh
YAML
expect "always() on the later step clears it" 0 "$d"

# ── 3. the FIRST test step is deliberately exempt ─────────────────
# It sits behind checkout/setup, not behind another test. Forcing it to run
# after a failed checkout prints a file-not-found on top of the real error.
d="$(newdir wf3)"
cat > "$d/w.yml" <<'YAML'
name: w
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Set up Python
        uses: actions/setup-python@v5
      - name: the only test
        run: bash tests/test_alpha.sh
YAML
expect "a lone test step is NOT flagged" 0 "$d"

# ── 4. non-test steps are ignored entirely ────────────────────────
# The gate must not become a general always() policy; it would fire on build
# and deploy steps where stopping early is correct.
d="$(newdir wf4)"
cat > "$d/w.yml" <<'YAML'
name: w
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: first test
        run: bash tests/test_alpha.sh
      - name: build the thing
        run: make all
      - name: deploy the thing
        run: ./deploy.sh
YAML
expect "non-test steps after a test are NOT flagged" 0 "$d"

# ── 5. the other spellings of "runs anyway" ───────────────────────
for spelling in '!cancelled()' 'success() || failure()'; do
    d="$(newdir wf5)"
    cat > "$d/w.yml" <<YAML
name: w
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: first test
        run: bash tests/test_alpha.sh
      - name: second test
        if: \${{ $spelling }}
        run: bash tests/test_beta.sh
YAML
    expect "'$spelling' counts as runs-anyway" 0 "$d"
done

# ── 6. an if: that does NOT survive failure is still a violation ──
# The gate reads the PROPERTY (does this run after an earlier failure), not the
# mere presence of an `if:` key. A conditional that skips on failure masks the
# test just as completely as no conditional at all.
d="$(newdir wf6)"
cat > "$d/w.yml" <<'YAML'
name: w
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: first test
        run: bash tests/test_alpha.sh
      - name: second test
        if: github.ref == 'refs/heads/main'
        run: bash tests/test_beta.sh
YAML
expect "an unrelated if: does NOT satisfy the gate" 1 "$d"

# ── 7. each job gets its own "first" ──────────────────────────────
# Jobs run independently, so job B's first test is not masked by job A.
d="$(newdir wf7)"
cat > "$d/w.yml" <<'YAML'
name: w
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - name: a test
        run: bash tests/test_alpha.sh
  b:
    runs-on: ubuntu-latest
    steps:
      - name: b test
        run: bash tests/test_beta.sh
YAML
expect "one test in each of two jobs is clean" 0 "$d"

# ── 8. the unittest spelling is detected ──────────────────────────
# A grep for 'tests/test_' alone would miss this and score a masked test as
# absent -- the gate would be blind on exactly the steps vendor-integrity uses.
d="$(newdir wf8)"
cat > "$d/w.yml" <<'YAML'
name: w
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: first test
        run: bash tests/test_alpha.sh
      - name: unittest style
        run: python3 -m unittest tests.test_something -v
YAML
expect "python3 -m unittest tests.* counts as a test step" 1 "$d"

# ── 9. CANNOT-RUN is exit 2, never a pass ─────────────────────────
expect "missing directory" 2 "$TMP/does-not-exist"
d="$(newdir wf9empty)"
expect "directory with no workflows (empty scan)" 2 "$d"

d="$(newdir wf10)"
printf 'jobs:\n  j:\n    steps:\n      - name: x\n     bad-indent: [\n' > "$d/w.yml"
expect "unparseable workflow yields NO VERDICT" 2 "$d"

# ── 10. multi-line run blocks are read whole ──────────────────────
# A run: | block that invokes a test on its second line is still a test step.
d="$(newdir wf11)"
cat > "$d/w.yml" <<'YAML'
name: w
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: first test
        run: bash tests/test_alpha.sh
      - name: block form
        run: |
          set -e
          bash tests/test_gamma.sh
YAML
expect "a test inside a run: | block is detected" 1 "$d"

# ── 11. THE LIVE TREE ─────────────────────────────────────────────
# The gate must hold against the repo's own workflows, or it is decoration.
if [[ -d "${REPO_ROOT}/.github/workflows" ]]; then
    expect "this repo's own .github/workflows" 0 "${REPO_ROOT}/.github/workflows"
else
    bad "no .github/workflows in this repo -- cannot check the live tree"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
