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

# Every fixture below is CLEAN on the axes it is not testing. A fixture that
# violates two axes cannot tell you which one fired, and the gate returns the
# same rc either way. Measured: when axis 2 was added, controls 1, 2, 3 and 21
# kept reading PASS while two mutants of the gate survived untouched.
echo "== the gate must FIRE =="

# (1) The defect itself: the workflow runs the test and does not watch it.
d="$(fixture blind)"
cat > "$d/.github/workflows/w.yml" <<'YML'
name: w
on:
  pull_request:
    paths:
      - 'install.sh'
      - '.github/workflows/w.yml'
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
      - '.github/workflows/w.yml'
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
      - '.github/workflows/w.yml'
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/test_subject.sh
YML
expect "(3) a single-star glob does not match across a directory" 1 "$d"

# Every fixture below that carries a paths filter also lists its own workflow
# file. Without that, axis 2 fires on the fixture and the control measures the
# wrong axis -- which is exactly what happened when axis 2 was added: five of
# these went red at once, all of them correctly.
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
      - '.github/workflows/w.yml'
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
      - '.github/workflows/a.yml'
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
      - '.github/workflows/b.yml'
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
      - '.github/workflows/w.yml'
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
      - '.github/workflows/w.yml'
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
      - '.github/workflows/w.yml'
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

echo "== axis 2: a filtered workflow must watch ITSELF =="

# (17) The defect: a paths filter that does not name its own file.
d="$(fixture selfblind)"
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
YML
expect "(17) a filtered workflow that does not list itself is a violation" 1 "$d"

# (18) The fix for (17).
d="$(fixture selfwatched)"
cat > "$d/.github/workflows/w.yml" <<'YML'
name: w
on:
  pull_request:
    paths:
      - 'tests/test_subject.sh'
      - '.github/workflows/w.yml'
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/test_subject.sh
YML
expect "(18) listing its own file clears it" 0 "$d"

# (19) A glob covers it too. The rule is "does it FIRE on a change to itself",
#      not "is its literal name present".
d="$(fixture selfglob)"
cat > "$d/.github/workflows/w.yml" <<'YML'
name: w
on:
  pull_request:
    paths:
      - 'tests/test_subject.sh'
      - '.github/workflows/**'
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/test_subject.sh
YML
expect "(19) a glob over .github/workflows covers the self-watch" 0 "$d"

# (20) An UNFILTERED workflow fires on everything, so axis 2 does not apply.
d="$(fixture selfunfiltered)"
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
expect "(20) an unfiltered workflow is not judged on axis 2" 0 "$d"

echo "== axis 3: a named workflow must EXIST =="

# (21) The measured shape: a rename that left the old name in the paths list.
#      The fixture is deliberately CLEAN on axes 1 and 2 -- the test is watched
#      and the workflow watches itself -- so the only thing that can make this
#      rc=1 is the missing workflow. The first version of this control was
#      self-blind as well, which meant axis 2 fired and the axis-3 mutant
#      survived: the control read PASS while proving nothing about the check it
#      was named for.
#      NOT named "ghost": control (10) already owns that fixture directory, and
#      two controls writing one directory is a control testing the other's file.
d="$(fixture renamedaway)"
cat > "$d/.github/workflows/w.yml" <<'YML'
name: w
on:
  pull_request:
    paths:
      - 'tests/test_subject.sh'
      - '.github/workflows/w.yml'
      - '.github/workflows/renamed-away.yml'
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/test_subject.sh
YML
expect "(21) a paths entry naming a workflow that does not exist is a violation" 1 "$d"

# (22) CONTROL: naming a DIFFERENT workflow that DOES exist is legitimate and
#      common -- a gate that flags it would be flagging correct cross-watching.
d="$(fixture cross)"
cat > "$d/.github/workflows/w.yml" <<'YML'
name: w
on:
  pull_request:
    paths:
      - 'tests/test_subject.sh'
      - '.github/workflows/w.yml'
      - '.github/workflows/other.yml'
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/test_subject.sh
YML
cat > "$d/.github/workflows/other.yml" <<'YML'
name: other
on:
  pull_request:
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/test_other.sh
YML
expect "(22) naming another workflow that DOES exist is not a violation" 0 "$d"

# (23) A glob entry under .github/workflows is not resolvable to one file and
#      must not be read as a ghost.
d="$(fixture globentry)"
cat > "$d/.github/workflows/w.yml" <<'YML'
name: w
on:
  pull_request:
    paths:
      - 'tests/test_subject.sh'
      - '.github/workflows/*.yml'
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/test_subject.sh
YML
expect "(23) a glob path entry is not mistaken for a missing workflow" 0 "$d"

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
