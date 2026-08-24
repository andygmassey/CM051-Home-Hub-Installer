#!/usr/bin/env bash
#
# tests/test_invoked_tests_are_watched_gate.sh
#
# Self-test for scripts/verify_invoked_tests_are_watched.py.
#
# The gate says: a test that a paths-filtered workflow RUNS must also be a path
# that workflow WATCHES, or editing the test does not trigger the only thing
# that checks it.
#
# A gate that never fires and a clean repo are indistinguishable from the
# outside, so every control below pins a DIRECTION. Half of them assert the gate
# stays QUIET, because a checker that flags the innocent is switched off inside
# a week and that is the same outcome as never having written it.
#
# Exit 0 all controls pass / 1 a control failed / 2 could not run.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${REPO_ROOT}/scripts/verify_invoked_tests_are_watched.py"

if [[ ! -f "$GATE" ]]; then
    echo "COULD NOT RUN: gate not found at $GATE (exit 2)" >&2
    exit 2
fi

if ! python3 -c 'import yaml' 2>/dev/null; then
    echo "COULD NOT RUN: PyYAML absent, so the gate cannot be exercised." >&2
    echo "This is a cannot-run (exit 2), not a pass." >&2
    exit 2
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/watched-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

# fixture <name> -- makes $TMP/<name> with tests/ and scripts/ and workflows/
fixture() {
    local d="$TMP/$1"
    mkdir -p "$d/.github/workflows" "$d/tests" "$d/scripts" "$d/vendor/tests"
    : > "$d/tests/test_subject.sh"
    : > "$d/tests/test_other.sh"
    : > "$d/scripts/helper.sh"
    : > "$d/vendor/tests/foo.sh"
    printf '%s\n' "$d"
}

# expect <label> <expected_rc> <dir>
expect() {
    local label="$1" want="$2" dir="$3" out rc
    out="$(python3 "$GATE" "$dir" 2>&1)"
    rc=$?
    if [[ "$rc" -eq "$want" ]]; then
        ok "$label (rc=$rc)"
    else
        bad "$label -- wanted rc=$want, got rc=$rc"
        printf '%s\n' "$out" | sed 's/^/         /' >&2
    fi
}

echo "== the gate must FIRE =="

# (1) The defect itself: the workflow runs the test and does not watch it.
d="$(fixture blind)"
cat > "$d/.github/workflows/w.yml" <<'YML'
name: w
on:
  pull_request:
    paths:
      - 'install.sh'
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/test_subject.sh
YML
expect "(1) a run: with no matching path entry is a violation" 1 "$d"

# (2) The predicate bug this gate was born with. The first version of the
#     extractor missed a leading './' and under-reported by two. If this control
#     ever passes as rc=0 the extractor has regressed to that version.
d="$(fixture dotslash)"
cat > "$d/.github/workflows/w.yml" <<'YML'
name: w
on:
  pull_request:
    paths:
      - 'install.sh'
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: python3 ./tests/test_subject.sh
YML
expect "(2) './tests/x' is the same invocation as 'tests/x'" 1 "$d"

# (3) '*' does not span a slash, so a top-level glob cannot bless tests/.
d="$(fixture starglob)"
cat > "$d/.github/workflows/w.yml" <<'YML'
name: w
on:
  pull_request:
    paths:
      - '*.sh'
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/test_subject.sh
YML
expect "(3) a single-star glob does not match across a directory" 1 "$d"

echo "== the gate must stay QUIET =="

# (4) The fix for (1): add the path entry.
d="$(fixture watched)"
cat > "$d/.github/workflows/w.yml" <<'YML'
name: w
on:
  pull_request:
    paths:
      - 'install.sh'
      - 'tests/test_subject.sh'
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/test_subject.sh
YML
expect "(4) a listed path entry clears the invocation" 0 "$d"

# (5) A workflow with no paths filter fires on everything, so it covers.
d="$(fixture unfiltered)"
cat > "$d/.github/workflows/w.yml" <<'YML'
name: w
on:
  pull_request:
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/test_subject.sh
YML
expect "(5) an unfiltered pull_request workflow covers what it runs" 0 "$d"

# (6) Coverage is per FILE, not per workflow: a second home that watches the
#     test clears it even though the first workflow is blind. Six real files
#     sit in exactly this shape and are not violations.
d="$(fixture secondhome)"
cat > "$d/.github/workflows/a.yml" <<'YML'
name: a
on:
  pull_request:
    paths:
      - 'install.sh'
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/test_subject.sh
YML
cat > "$d/.github/workflows/b.yml" <<'YML'
name: b
on:
  pull_request:
    paths:
      - 'tests/test_subject.sh'
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/test_subject.sh
YML
expect "(6) a second workflow that watches it clears the first" 0 "$d"

# (7) '**' spans slashes.
d="$(fixture doubleglob)"
cat > "$d/.github/workflows/w.yml" <<'YML'
name: w
on:
  pull_request:
    paths:
      - 'tests/**'
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/test_subject.sh
YML
expect "(7) a double-star glob covers the directory" 0 "$d"

# (8) A path that looks like ours but is not: vendor/tests/foo.sh must not be
#     read as tests/foo.sh, which would be a violation against a file the
#     workflow never named.
d="$(fixture suffix)"
cat > "$d/.github/workflows/w.yml" <<'YML'
name: w
on:
  pull_request:
    paths:
      - 'vendor/**'
      - 'tests/test_subject.sh'
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash vendor/tests/foo.sh
      # A real, watched invocation so the run has a non-zero denominator. Without
      # it the zero-denominator arm fires and control (15)'s verdict masks this
      # one -- which is how this control failed the first time it was written.
      - run: bash tests/test_subject.sh
YML
expect "(8) vendor/tests/foo.sh is not read as tests/foo.sh" 0 "$d"

# (9) A non-pull_request workflow has no PR event to be blind on.
d="$(fixture pushonly)"
cat > "$d/.github/workflows/w.yml" <<'YML'
name: w
on:
  push:
    branches: [main]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/test_subject.sh
YML
cat > "$d/.github/workflows/x.yml" <<'YML'
name: x
on:
  pull_request:
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/test_other.sh
YML
expect "(9) a push-only workflow is not judged on a PR filter" 0 "$d"

# (10) A run: naming a file that does not exist is a typo or a generated path,
#      not a wiring claim. It must not manufacture a violation.
d="$(fixture ghost)"
cat > "$d/.github/workflows/w.yml" <<'YML'
name: w
on:
  pull_request:
    paths:
      - 'tests/test_subject.sh'
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/test_subject.sh
      - run: bash tests/test_does_not_exist.sh
YML
expect "(10) a run: naming a file not on disk is not a violation" 0 "$d"

echo "== the gate must say CANNOT-RUN, not pass =="

# (11) paths-ignore is not modelled. Treating it as unfiltered would bless an
#      explicitly ignored test.
d="$(fixture ignore)"
cat > "$d/.github/workflows/w.yml" <<'YML'
name: w
on:
  pull_request:
    paths-ignore:
      - 'docs/**'
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/test_subject.sh
YML
expect "(11) paths-ignore is cannot-run, not a silent pass" 2 "$d"

# (12) No workflow directory at all.
d="$(fixture noworkflows)"
rm -rf "$d/.github"
expect "(12) a tree with no .github/workflows cannot be cleared" 2 "$d"

# (13) A workflow directory with no workflows in it: zero denominator.
d="$(fixture emptydir)"
expect "(13) an empty workflow directory is a zero denominator" 2 "$d"

# (14) Unparseable YAML must not read as "this workflow has no violations".
d="$(fixture broken)"
cat > "$d/.github/workflows/w.yml" <<'YML'
name: w
on:
  pull_request:
    paths:
      - 'tests/test_subject.sh'
   bad indentation here: [
YML
expect "(14) a workflow that will not parse is cannot-run" 2 "$d"

# (15) Workflows exist and take pull_request, but none invokes a file that is
#      on disk. Nothing was examined, so "no violations" is not a finding.
d="$(fixture nonumerator)"
cat > "$d/.github/workflows/w.yml" <<'YML'
name: w
on:
  pull_request:
    paths:
      - 'install.sh'
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: echo nothing to see
YML
expect "(15) zero files examined is not zero violations" 2 "$d"

echo
echo "== the gate on this repo =="
# (16) The whole point: run it where it will run. This asserts only that it
#      reaches a verdict of 0 or 1 -- a cannot-run here means the gate is
#      broken, and that is the state this control exists to catch.
out="$(python3 "$GATE" "$REPO_ROOT" 2>&1)"; rc=$?
if [[ "$rc" -eq 2 ]]; then
    bad "(16) the gate cannot run against this repo -- rc=2"
    printf '%s\n' "$out" | sed 's/^/         /' >&2
elif ! grep -q 'EXAMINED:' <<< "$out"; then
    bad "(16) the gate printed no denominator against this repo"
else
    ok "(16) the gate reaches a verdict against this repo (rc=$rc, $(grep -o 'invoking [0-9]* script/test file' <<< "$out"))"
fi

echo
printf 'controls: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
exit 0
