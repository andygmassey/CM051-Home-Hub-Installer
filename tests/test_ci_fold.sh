#!/usr/bin/env bash
# tests/test_ci_fold.sh -- scripts/ci_fold.py must go RED on every way a fold
# can silently lose a gate, and GREEN on a faithful fold.
#
# Hermetic: synthetic workflows in a temp dir, no network, no git ref. The
# checker is the only thing standing between "fewer jobs" and "fewer gates",
# so it is proven by MUTATION, not by reading it: each case below breaks one
# property of a faithful fold and must be refused with a reason naming it.
# A checker that has only ever been seen to pass proves nothing.
#
# Exit 0 all cases behaved / 1 a case did not / 2 could not run.
# British English; " -- " not em-dashes.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/scripts/ci_fold.py"
python3 -c 'import yaml' 2>/dev/null || {
    echo "test_ci_fold: CANNOT RUN -- PyYAML unavailable" >&2; exit 2; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/base/wf"

cat > "$T/base/wf/fam-a.yml" <<'YML'
# fam-a: HEADER COMMENT THAT MUST SURVIVE THE FOLD.
name: fam-a

on:
  push:
    branches: [main]
    paths:
      - 'src/a.py'
      - '.github/workflows/fam-a.yml'
  pull_request:
    paths:
      - 'src/a.py'
      - 'tests/test_a.sh'
      - '.github/workflows/fam-a.yml'

jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    strategy:
      fail-fast: false
      matrix:
        python: ['3.11', '3.12']
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: ${{ matrix.python }}
      - name: Install pytest
        run: python -m pip install --quiet pytest
      # STEP COMMENT THAT MUST SURVIVE THE FOLD.
      - name: a holds
        if: always()
        run: bash tests/test_a.sh
YML

cat > "$T/base/wf/fam-b.yml" <<'YML'
name: fam-b

permissions:
  contents: read

on:
  push:
    branches: [main]
    paths:
      - 'src/b.py'
      - '.github/workflows/fam-b.yml'
  pull_request:
    paths:
      - 'src/b.py'
      - '.github/workflows/fam-b.yml'

jobs:
  b1:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    strategy:
      fail-fast: false
      matrix:
        python: ['3.11', '3.12']
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: ${{ matrix.python }}
      - id: count
        run: echo "n=3" >> "$GITHUB_OUTPUT"
      - name: b1 holds
        run: python3 tests/test_b.py "${{ steps.count.outputs.n }}"

  b2:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
      - run: bash tests/test_b2.sh
YML

cat > "$T/base/wf/other.yml" <<'YML'
name: other
on:
  pull_request:
jobs:
  o:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
      - run: bash tests/test_other.sh
YML

printf 'fx\tfam-a.yml\ta\nfx\tfam-b.yml\tb1\n' > "$T/spec.tsv"

fail=0
pass() { echo "  ok    $1"; }
bad()  { echo "  FAIL  $1" >&2; fail=1; }

cp -R "$T/base" "$T/after"
if ! python3 "$TOOL" generate fx --dir "$T/after/wf" --spec "$T/spec.tsv" \
        > "$T/gen.out" 2>&1; then
    cat "$T/gen.out" >&2
    echo "test_ci_fold: CANNOT RUN -- generate failed on the fixture" >&2
    exit 2
fi

check() {  # check <tree> -> sets RC and OUT
    OUT="$(python3 "$TOOL" check --base-dir "$T/base/wf" --tree "$1/wf" \
            --spec "$T/spec.tsv" 2>&1)"
    RC=$?
}

# ---- the faithful fold is PROVEN ------------------------------------------
check "$T/after"
if [ "$RC" -eq 0 ]; then pass "faithful fold is proven"
else bad "faithful fold refused: $OUT"; fi

F="$T/after/wf/fold-fx.yml"
[ ! -e "$T/after/wf/fam-a.yml" ] && pass "fully folded source is removed" \
    || bad "fam-a.yml should be gone"
python3 - "$T/after/wf/fam-b.yml" <<'PY' && pass "unfolded job b2 kept, b1 removed" || bad "fam-b.yml trim wrong"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
sys.exit(0 if list(d["jobs"]) == ["b2"] else 1)
PY
grep -q 'HEADER COMMENT THAT MUST SURVIVE' "$F" && grep -q 'STEP COMMENT THAT MUST SURVIVE' "$F" \
    && pass "source comments carried into the family" || bad "comments lost"
# The sources set no pipefail, so the family must not either:
# test_pipefail_shortcircuit_inversion.sh counts per FILE, and a generated
# pipefail would make every folded `x | grep -q` read as a new instance.
[ "$(grep -c pipefail "$F")" -eq 0 ] \
    && pass "the generator introduces no pipefail" || bad "generator added pipefail"
grep -q 'steps.b02_count.outputs.n' "$F" \
    && pass "step-id references renamed with their step" || bad "id reference not renamed"
python3 "$ROOT/scripts/verify_ci_steps_are_maskless.py" "$T/after/wf" >/dev/null 2>&1 \
    && pass "folded family passes the maskless gate" || bad "family is maskable"

# ---- every mutation is REFUSED, for the right reason ----------------------
mutate() {  # mutate <label> <expected-substring> <python-edit-on-family-text>
    local label="$1" want="$2" code="$3"
    rm -rf "$T/m"; cp -R "$T/after" "$T/m"
    python3 - "$T/m" <<PY
import os, re, sys
d = os.path.join(sys.argv[1], "wf")
f = os.path.join(d, "fold-fx.yml")
s = open(f).read()
$code
open(f, "w").write(s)
PY
    # A mutation that changes nothing would be "refused" for no reason at all
    # -- or, worse, pass and be blamed on the checker. Prove it bit.
    if diff -rq "$T/after" "$T/m" >/dev/null 2>&1; then
        bad "mutation was a NO-OP, so it tests nothing: $label"
        return
    fi
    check "$T/m"
    if [ "$RC" -eq 1 ] && grep -qF -- "$want" <<< "$OUT"; then
        pass "refused: $label"
    else
        bad "NOT refused ($RC): $label -- wanted '$want', got: $OUT"
    fi
}

mutate "a test step dropped" "step(s) at base" \
'i = s.index("      - id: b01_s02"); j = s.index("      # ====", i); s = s[:i] + s[j:]'
mutate "a test command edited" "not verbatim" \
's = s.replace("bash tests/test_a.sh", "true")'
mutate "a watched path narrowed" "paths narrowed" \
's = s.replace("      - '"'"'tests/test_a.sh'"'"'\n", "")'
mutate "always() weakened to success()" "always() lost" \
's = s.replace("!= \x27false\x27 && (always()) }}", "!= \x27false\x27 && (success()) }}")'
mutate "implicit success() left job-scoped" "not scoped to its block" \
's = re.sub(r"if: \$\{\{ (steps\.select\.outputs\.b02 != .false.) && !cancelled\(\) && steps\.b02_isolate\.conclusion != .failure. && steps\.b02_count\.conclusion != .failure. \}\}", r"if: ${{ \1 && success() }}", s)'
mutate "matrix narrowed" "strategy/matrix changed" \
's = s.replace(", '"'"'3.12'"'"']", "]")'
mutate "runner changed" "runs-on changed" \
's = s.replace("runs-on: ubuntu-latest", "runs-on: macos-latest")'
mutate "a step's timeout widened" "wider than its old bound" \
's = s.replace("timeout-minutes: 10\n        name: a holds", "timeout-minutes: 99\n        name: a holds")'
mutate "isolation step made maskable" "can be skipped" \
's = s.replace("if: ${{ !cancelled() && steps.select", "if: ${{ success() && steps.select", 1)'
mutate "self-watch removed" "does not watch itself" \
's = s.replace("      - '"'"'.github/workflows/fold-fx.yml'"'"'\n", "")'
mutate "push trigger dropped" "push trigger dropped" \
's = re.sub(r"  push:\n    branches: \[main\]\n    paths:\n(      - .*\n)+", "", s)'
mutate "token widened" "not read-only" \
's = s.replace("  pull-requests: read", "  pull-requests: write")'
mutate "a block step ungated from its selection" "not gated on its own selection" \
's = s.replace("steps.select.outputs.b01 != \x27false\x27 && (always())", "(always())")'
mutate "the selector step removed" "no always-run selector" \
'i = s.index("      - id: select"); j = s.index("      # ====", i); s = s[:i] + s[j:]'
mutate "a block's selection row dropped" "no longer selects on" \
'p = os.path.join(os.path.dirname(d), "ci-fold-paths.tsv"); t = open(p).read().replace("fx\tb01\tfam-a.yml::a\ttests/test_a.sh\n", ""); open(p, "w").write(t)'
mutate "unrelated workflow deleted" "vanished" \
'os.remove(os.path.join(d, "other.yml"))'
mutate "unfolded job changed" "unfolded jobs changed" \
'p = os.path.join(d, "fam-b.yml"); t = open(p).read().replace("test_b2.sh", "test_b3.sh"); open(p, "w").write(t)'

# ---- a block cannot leave a process running into the next ---------------
# A fresh machine had no processes from another job; a family must not let
# one block's leftovers serve the next. Run for real: block 1 leaks a
# uniquely named sleep, block 2 asserts it is gone. Then the CONTROL: the
# same family with the kill removed must FAIL, or the first result proves
# nothing.
PYV="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
if ! command -v "python$PYV" >/dev/null 2>&1; then
    echo "test_ci_fold: CANNOT RUN the leak case -- no python$PYV on PATH" >&2
    exit 2
fi
LK="$T/lk"; mkdir -p "$LK/.github/workflows" "$LK/scripts"
cp "$TOOL" "$LK/scripts/ci_fold.py"
for n in a b; do
    if [ "$n" = a ]; then body='nohup sleep 3171 >/dev/null 2>&1 &'
    else body='[ "$(ps -A -o args= | grep -c "^sleep 3171$")" -eq 0 ]'; fi
    cat > "$LK/.github/workflows/lk-$n.yml" <<YML
name: lk-$n
on:
  pull_request:
    paths: ['src/$n.sh', '.github/workflows/lk-$n.yml']
jobs:
  lk$n:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    strategy:
      matrix:
        python: ['$PYV']
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: \${{ matrix.python }}
      - name: step $n
        run: |
          $body
YML
done
git -C "$LK" init -q && git -C "$LK" add -A \
    && git -C "$LK" -c user.email=t@t -c user.name=t commit -qm fixture
printf 'lk\tlk-a.yml\tlka\nlk\tlk-b.yml\tlkb\n' > "$T/lkspec.tsv"
python3 "$TOOL" generate lk --dir "$LK/.github/workflows" --spec "$T/lkspec.tsv" >/dev/null 2>&1
cp "$LK/.github/workflows/fold-lk.yml" "$T/fold-lk.yml"
leak_run() {  # leak_run <family-file> -> rc of run-local
    python3 "$TOOL" run-local "$1" --python "$PYV" --workspace "$LK" >/dev/null 2>&1
}
pkill -f '^sleep 3171$' 2>/dev/null
leak_run "$T/fold-lk.yml"; rc=$?
[ "$rc" -eq 0 ] && pass "a process leaked by block 1 is gone before block 2 runs" \
    || bad "block 2 still saw block 1's leaked process (run-local rc=$rc)"
python3 - "$T/fold-lk.yml" "$T/fold-lk-nokill.yml" <<'PY'
import sys
s = open(sys.argv[1]).read()
s = s.replace('kill -KILL "$pid" 2>/dev/null || true', 'true  # kill removed')
open(sys.argv[2], "w").write(s)
PY
pkill -f '^sleep 3171$' 2>/dev/null
leak_run "$T/fold-lk-nokill.yml"; rc=$?
[ "$rc" -ne 0 ] && pass "CONTROL: without the kill, block 2 DOES see the leak (the case discriminates)" \
    || bad "CONTROL: block 2 passed with the kill removed -- the leak case tests nothing"
pkill -f '^sleep 3171$' 2>/dev/null
# The macOS arm (one `ps eww`, no /proc) is the one CI's macOS legs take, and
# procps reads the same flags, so run it here too with the /proc arm disabled.
python3 - "$T/fold-lk.yml" "$T/fold-lk-ps.yml" "$T/fold-lk-ps-nokill.yml" <<'PY'
import sys
s = open(sys.argv[1]).read()
n = s.count("if [ -d /proc/self ]; then")
s = s.replace("if [ -d /proc/self ]; then", "if false; then")
open(sys.argv[2], "w").write(s if n else "")
open(sys.argv[3], "w").write(s.replace('kill -KILL "$pid" 2>/dev/null || true', 'true  # kill removed') if n else "")
PY
leak_run "$T/fold-lk-ps.yml"; rc=$?
[ "$rc" -eq 0 ] && pass "the ps arm (macOS) also kills block 1's leak before block 2 runs" \
    || bad "the ps arm left block 1's leaked process for block 2 (run-local rc=$rc)"
pkill -f '^sleep 3171$' 2>/dev/null
leak_run "$T/fold-lk-ps-nokill.yml"; rc=$?
[ "$rc" -ne 0 ] && pass "CONTROL: the ps arm without the kill DOES leave the leak" \
    || bad "CONTROL: the ps arm passed with the kill removed -- its case tests nothing"
pkill -f '^sleep 3171$' 2>/dev/null
python3 - "$T/after/wf/fold-fx.yml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
open(p + ".nomark", "w").write(s.replace('echo "CI_FOLD_BLOCK=b01" >> "$GITHUB_ENV"', 'true'))
PY
rm -rf "$T/nm"; cp -R "$T/after" "$T/nm"; mv "$T/nm/wf/fold-fx.yml.nomark" "$T/nm/wf/fold-fx.yml"
OUT="$(python3 "$TOOL" check --base-dir "$T/base/wf" --tree "$T/nm/wf" --spec "$T/spec.tsv" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && grep -qF 'does not mark its block' <<< "$OUT"; then pass "refused: an isolate step that no longer marks its block's processes"
else bad "unmarked isolate step not refused ($RC)"; fi

# ---- the selector: GitHub's glob semantics, and it FAILS OPEN -------------
python3 - "$TOOL" <<'PY' && pass "glob table matches GitHub's filter semantics" || bad "glob table"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ci_fold", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
table = [
    ("install.sh", "install.sh", True), ("install.sh", "x/install.sh", False),
    ("vendor/fda/**", "vendor/fda/a/b.py", True),
    ("vendor/fda/**", "vendor/fdaX/a.py", False),
    ("*.py", "a.py", True), ("*.py", "d/a.py", False),
    ("docs/*", "docs/a.md", True), ("docs/*", "docs/x/a.md", False),
    ("a/**/b.py", "a/b.py", True), ("a/**/b.py", "a/x/y/b.py", True),
    ("**/x.sh", "x.sh", True), ("**/x.sh", "d/e/x.sh", True),
    ("a.b", "aXb", False),                   # a dot is literal
    ("a?b", "anything/at/all", True),        # unmodelled: fails OPEN
]
bad = [(p, f, w) for p, f, w in table if m.matches(p, f) != w]
for b in bad:
    print("   wrong:", b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY

# The executed-script extractor is what the before/after script diff is built
# on. It must see through the two indirections the estate uses, and must not
# invent a path that does not exist.
python3 - "$TOOL" "$ROOT" <<'PY' && pass "script extractor follows \$var and cd, invents nothing" || bad "script extractor"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ci_fold", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
got = m.scripts_in("d=tests\nbash $d/test_ci_fold.sh\nbash ${d}/test_ci_fold.sh")
ok = got == {"tests/test_ci_fold.sh"}
got2 = m.scripts_in("cd scripts\npython3 ci_fold.py check\npython3 no/such/thing.py")
ok = ok and "scripts/ci_fold.py" in got2 and not any("no/such" in g for g in got2)
got3 = m.scripts_in("make -C gui check-pr-age && bash tests/test_ci_fold.sh")
ok = ok and {"make:gui:check-pr-age", "tests/test_ci_fold.sh"} <= got3
print(got, got2, got3, file=sys.stderr) if not ok else None
sys.exit(0 if ok else 1)
PY

sel() {  # sel <files-or-empty> <event> -> prints sorted outputs
    local o="$T/sel.out"; : > "$o"
    if [ -n "$1" ]; then printf '%s\n' $1 > "$T/files.txt"; else : > "$T/files.txt"; fi
    CI_FOLD_FILES="$T/files.txt" EVENT_NAME="$2" GITHUB_OUTPUT="$o" \
        python3 "$TOOL" select fx --paths "$T/after/ci-fold-paths.tsv" >/dev/null 2>&1
    sort "$o" | tr '\n' ' '
}
want() { [ "$2" = "$3" ] && pass "select: $1" || bad "select: $1 -- got '$2', wanted '$3'"; }
want "only the block whose path changed runs" "$(sel src/b.py pull_request)" "b01=false b02=true "
want "a test file selects its own block" "$(sel tests/test_a.sh pull_request)" "b01=true b02=false "
want "a change to the selector runs everything" "$(sel scripts/ci_fold.py pull_request)" "b01=true b02=true "
want "a change to the family runs everything" "$(sel .github/workflows/fold-fx.yml pull_request)" "b01=true b02=true "
want "a push runs everything" "$(sel src/b.py push)" "b01=true b02=true "
want "an EMPTY file list fails open" "$(sel '' pull_request)" "b01=true b02=true "
o="$T/sel.out"; : > "$o"
EVENT_NAME=pull_request GITHUB_OUTPUT="$o" PR_NUMBER= REPO= \
    python3 "$TOOL" select fx --paths "$T/after/ci-fold-paths.tsv" >/dev/null 2>&1
want "no PR number fails open" "$(sort "$o" | tr '\n' ' ')" "b01=true b02=true "
: > "$o"
EVENT_NAME=pull_request GITHUB_OUTPUT="$o" \
    python3 "$TOOL" select fx --paths "$T/nonexistent.tsv" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$o" ] \
    && pass "select: unreadable rows write NO output, so every gate reads != 'false'" \
    || bad "select: unreadable rows gave rc=$rc, output '$(cat "$o")'"

# The selector runs on the bare setup-python interpreter, before any block
# has installed anything, so it must not need PyYAML. -S drops site-packages.
: > "$o"; printf 'src/b.py\n' > "$T/files.txt"
CI_FOLD_FILES="$T/files.txt" EVENT_NAME=pull_request GITHUB_OUTPUT="$o" \
    python3 -S "$TOOL" select fx --paths "$T/after/ci-fold-paths.tsv" >/dev/null 2>&1
want "runs without PyYAML" "$(sort "$o" | tr '\n' ' ')" "b01=false b02=true "

# ---- after the fold merges, later changes are not re-proven ---------------
# The base already carries the rows, so there is nothing new to prove; the
# family file is then an ordinary workflow, graded by the ordinary gates.
OUT="$(python3 "$TOOL" check --base-dir "$T/after/wf" --base-spec "$T/spec.tsv" \
        --tree "$T/after/wf" --spec "$T/spec.tsv" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && grep -qF 'nothing to prove' <<< "$OUT"; then
    pass "rows already at the base are not re-proven"
else bad "already-folded base: $RC $OUT"; fi

# Growing a family after it merged is not modelled: refuse, never guess.
printf 'fx\tfam-a.yml\ta\n' > "$T/spec_old.tsv"
python3 "$TOOL" check --base-dir "$T/base/wf" --base-spec "$T/spec_old.tsv" \
    --tree "$T/after/wf" --spec "$T/spec.tsv" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && pass "extending a merged family is CANNOT-RUN (2)" \
    || bad "extending a family gave $rc"

# ---- an empty scan is CANNOT-RUN, never green -----------------------------
mkdir -p "$T/empty"
python3 "$TOOL" check --base-dir "$T/empty" --tree "$T/after/wf" \
    --spec "$T/spec.tsv" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && pass "empty base is CANNOT-RUN (2)" || bad "empty base gave $rc"

if [ "$fail" -ne 0 ]; then
    echo "test_ci_fold: FAILED" >&2
    exit 1
fi
echo "test_ci_fold: all cases behaved"
