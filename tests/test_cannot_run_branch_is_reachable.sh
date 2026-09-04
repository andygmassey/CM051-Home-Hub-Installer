#!/usr/bin/env bash
# The scanner that finds unreachable CANNOT-RUN branches must itself be able
# to go RED, and must not fire on the two correct spellings.
#
# A scanner with a broken regex prints "0 violations" on every tree, which is
# indistinguishable from a clean one. So this file never asserts the real tree
# is clean without FIRST proving, on fixtures, that the predicate discriminates
# in both directions.
#
# ⚠️ THE FIXTURES LIVE IN A TEMP DIR, NEVER IN .github/workflows. A fixture
# workflow on the real path would be a live workflow: GitHub would schedule it,
# and the deliberately-broken one would run. Same rule as never binding a test
# fixture to a real service port.
#
# rc=2 means the harness could not set itself up. That is not a pass.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCANNER="${REPO_ROOT}/scripts/verify_cannot_run_branch_is_reachable.py"

cannot() { echo "CANNOT-RUN [$1]: $2" >&2; exit 2; }
[ -f "$SCANNER" ] || cannot "no-scanner" "$SCANNER not found -- nothing was checked."
python3 -c 'import yaml' 2>/dev/null \
    || cannot "no-pyyaml" "PyYAML is absent, so no workflow can be parsed. Not a pass."

PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf 'FAIL %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t ostler-reach)"
# `mktemp -d -t NAME` with no X's is BSD-only; GNU refuses it and leaves the
# variable EMPTY, which would put every path below at /. Hence the ||.
[ -n "$WORK" ] && [ -d "$WORK" ] || cannot "no-tmpdir" "could not create a work dir."
trap 'rm -rf "$WORK"' EXIT

mkfix() {   # $1 = dir, $2 = filename, $3 = the run block body (indented 10)
    mkdir -p "$1"
    {
        printf 'name: fixture\non:\n  workflow_dispatch:\njobs:\n  j:\n'
        printf '    runs-on: ubuntu-latest\n    steps:\n'
        printf '      - name: the step\n        run: |\n'
        printf '%s\n' "$3"
    } > "$1/$2"
}

scan() { python3 "$SCANNER" "$1" --no-floor 2>&1; }   # floors are for the real tree

# ── A. POSITIVE CONTROL: the defect MUST be caught ──────────────────────────
# Without this arm every other result is worthless: a scanner that matches
# nothing passes the real tree and both negative controls.
D="${WORK}/pos"
mkfix "$D" "bad.yml" '          /bin/bash tests/test_thing.sh
          rc=$?
          if [ "$rc" -eq 2 ]; then
            echo "::error::CANNOT-RUN"
          fi
          exit "$rc"'
OUT="$(scan "$D")"; RC=$?
if [ "$RC" -eq 1 ] && grep -q 'violations       : 1' <<< "$OUT"; then
    ok "CONTROL: the real defect shape is CAUGHT (rc=1, 1 violation)"
else
    bad "CONTROL: the scanner did NOT catch the defect it exists to find \
(rc=$RC). Every clean verdict it gives is meaningless. Output:
$OUT"
fi

# ── B. NEGATIVE CONTROL: `|| rc=$?` must NOT fire ───────────────────────────
D="${WORK}/neg1"
mkfix "$D" "good.yml" '          rc=0
          /bin/bash tests/test_thing.sh || rc=$?
          if [ "$rc" -eq 2 ]; then
            echo "::error::CANNOT-RUN"
          fi
          exit "$rc"'
OUT="$(scan "$D")"; RC=$?
if [ "$RC" -eq 0 ]; then
    ok "CONTROL: the guarded form \`|| rc=\$?\` does NOT fire"
else
    bad "CONTROL: the CORRECT form was reported as a violation (rc=$RC). \
The gate would refuse the fix it demands. Output:
$OUT"
fi

# ── C. NEGATIVE CONTROL: `set +e` must NOT fire ─────────────────────────────
# The other legitimate spelling. A gate that only accepts one of two correct
# forms is a style rule wearing a correctness rule's clothes.
D="${WORK}/neg2"
mkfix "$D" "good2.yml" '          set +e
          /bin/bash tests/test_thing.sh
          rc=$?
          exit "$rc"'
OUT="$(scan "$D")"; RC=$?
if [ "$RC" -eq 0 ]; then
    ok "CONTROL: \`set +e\` before the call does NOT fire"
else
    bad "CONTROL: \`set +e\` was reported as a violation (rc=$RC). That is a \
correct way to write it. Output:
$OUT"
fi

# ── D. NEGATIVE CONTROL: a shell without -e must NOT fire ───────────────────
# The predicate is about errexit, not about the characters `rc=$?`.
D="${WORK}/neg3"
mkdir -p "$D"
cat > "${D}/noerrexit.yml" <<'YAML'
name: fixture
on:
  workflow_dispatch:
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: the step
        shell: bash --noprofile --norc {0}
        run: |
          /bin/bash tests/test_thing.sh
          rc=$?
          exit "$rc"
YAML
OUT="$(scan "$D")"; RC=$?
if [ "$RC" -eq 0 ]; then
    ok "CONTROL: a custom shell WITHOUT -e does not fire (the rc is real there)"
else
    bad "CONTROL: fired on a shell that has no errexit, where the capture \
WORKS. The predicate is keying on the wrong thing. Output:
$OUT"
fi

# ── E. THE REAL TREE, with the anti-vacuity floors ARMED ────────────────────
# Floors on, so a broken glob reports CANNOT-RUN rather than a clean zero.
OUT="$(python3 "$SCANNER" "${REPO_ROOT}/.github/workflows" 2>&1)"; RC=$?
WF="$(sed -n 's/^workflows parsed : //p' <<< "$OUT")"
ST="$(sed -n 's/^run steps scanned: //p' <<< "$OUT")"
case "$RC" in
  0) ok "the real tree is clean (${WF:-?} workflows, ${ST:-?} run steps scanned)" ;;
  2) bad "the scan of the real tree COULD NOT RUN -- that is not a pass:
$OUT" ;;
  *) bad "the real tree has unreachable CANNOT-RUN branches:
$OUT" ;;
esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
printf 'EVERY $? CAPTURE IS REACHABLE UNDER THE SHELL ITS STEP ACTUALLY RUNS\n'
