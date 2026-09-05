#!/usr/bin/env bash
# CM051 #1610 -- the pre-commit PII hook must ask CI's question, not a stricter one.
#
# THE DEFECT THIS GUARDS. .githooks/pre-commit-operator-pii staged every file's
# WHOLE blob and handed the paths to ci-pii-shape-scan.sh, which takes its
# path-argument branch and scans each file IN FULL. CI sets BASE_REF and
# narrows MODIFIED files to their ADDED LINES.
#
# MEASURED 2026-09-05: origin/main's own install.sh, unmodified, fails the
# whole-file scan rc=1 on /Users/ and /home/ shapes that have been on main for
# months. The hook was therefore red for EVERY commit touching install.sh.
#
# WHY THAT IS WORSE THAN NOISE. The only way past it is --no-verify, which
# disables every pre-commit hook, including check-rule-09-strings and the
# assistant-name check. A gate you can only satisfy by switching off the other
# gates teaches the habit of switching off the other gates.
#
# tests/test_pii_shape_scan_scope.sh already pins the SCANNER in both modes.
# Nothing pinned the HOOK, which is a separate caller -- which is exactly how
# the scanner got fixed for CI in #587 while this path kept the old behaviour.
#
# NO PII-SHAPED LITERAL IS WRITTEN INTO THIS FILE. Every one is composed from
# parts at runtime, because the repo's own hook scans this file -- and as a
# newly ADDED file it is scanned IN FULL, so a literal here would block the
# very commit that adds the guard. Same convention as the sibling scope test.
#
# THE IDENTITY SCANNER IS STUBBED. This test is about WHICH CONTENT the hook
# stages, not about the identity scan, and CI runners have no HR015 checkout.
# The stub is explicit so nobody reads this file as coverage of that scanner.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
HOOK="${REPO}/.githooks/pre-commit-operator-pii"
SHAPE="${REPO}/.github/scripts/ci-pii-shape-scan.sh"
PATTERNS="${REPO}/.githooks/pii_patterns.sh"

PASS=0; FAIL=0; CANT=0
ok()   { printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
cant() { printf '  [CANNOT-RUN] %s\n' "$*"; CANT=$((CANT+1)); }

for f in "$HOOK" "$SHAPE"; do
    [ -x "$f" ] || { cant "not executable: $f"; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }
done
[ -r "$PATTERNS" ] || { cant "no pattern library at $PATTERNS -- the scanner cannot run without it, and a scan that examined nothing is not a pass"; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }
command -v git >/dev/null 2>&1 || { cant "git absent"; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }

# PII shapes, composed at runtime so this file never contains one.
U_SHAPE="/Us""ers/someone/Documents"
H_SHAPE="/ho""me/someone/data"

WORK="$(mktemp -d -t piihook)" || { cant "mktemp failed"; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT

STUB="$WORK/identity-stub.sh"
printf '#!/bin/sh\nexit 0\n' > "$STUB"; chmod +x "$STUB"

REPOD="$WORK/repo"
mkdir -p "$REPOD/.githooks" "$REPOD/.github/scripts"
cp "$HOOK" "$PATTERNS" "$REPOD/.githooks/"; cp "$SHAPE" "$REPOD/.github/scripts/"
chmod +x "$REPOD/.githooks/pre-commit-operator-pii" "$REPOD/.github/scripts/ci-pii-shape-scan.sh"
cd "$REPOD" || { cant "cannot enter the fixture repo"; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }
git init -q .
git config user.email t@t.invalid
git config user.name  t

# A tracked file that ALREADY carries a PII shape -- install.sh's situation.
{ echo "# fixture"; printf 'legacy: %s\n' "$U_SHAPE"; } > legacy.txt
git add -A >/dev/null
git -c core.hooksPath=/dev/null commit -qm base

run_hook() { OPERATOR_PII_SCAN_BIN="$STUB" ./.githooks/pre-commit-operator-pii >"$WORK/out" 2>&1; }

echo "== #1610: the pre-commit PII hook asks CI's question =="

# CONTROL FIRST. If the fixture's pre-existing shape does not trip a whole-file
# scan, every arm below is measuring nothing.
if "$SHAPE" legacy.txt >/dev/null 2>&1; then
    bad "control: the fixture's pre-existing shape does NOT trip a whole-file scan, so this test proves nothing"
else
    ok "control: the fixture carries a pre-existing shape a whole-file scan does see"
fi

# ARM 1 -- the defect. A clean added line to a file with legacy PII must pass.
printf '# an ordinary added comment\n' >> legacy.txt
git add legacy.txt
if run_hook; then
    ok "a clean added line to a legacy-PII file passes the hook"
else
    bad "the hook still blocks a clean change to a legacy-PII file: $(tail -1 "$WORK/out")"
fi

# ARM 2 -- MUST-MISS. The gate must still bite on a PII-shaped ADDED line.
printf 'home: %s\n' "$H_SHAPE" >> legacy.txt
git add legacy.txt
if run_hook; then
    bad "the hook did NOT block a PII-shaped ADDED line -- the fix has turned the gate off"
elif ! grep -q 'PII-SHAPED content' "$WORK/out"; then
    # A non-zero exit is not proof of a block: CANNOT-RUN is also non-zero, and
    # would let this arm pass while measuring nothing.
    bad "blocked, but NOT for finding PII: $(tail -2 "$WORK/out" | tr '\n' ' ')"
else
    ok "a PII-shaped added line is still blocked, and blocked for finding PII"
fi
git checkout -q -- legacy.txt 2>/dev/null || true
git reset -q >/dev/null

# ARM 3 -- the rename/add hole stays closed: a NEW file is scanned IN FULL,
# even though none of its content shows as an "added line" of a modified file.
printf 'brand new: %s\n' "$U_SHAPE" > newfile.txt
git add newfile.txt
if run_hook; then
    bad "a newly ADDED file containing PII passed -- whole-file scanning for A/C/R is gone"
elif ! grep -q 'PII-SHAPED content' "$WORK/out"; then
    bad "blocked, but NOT for finding PII: $(tail -2 "$WORK/out" | tr '\n' ' ')"
else
    ok "a newly added file is still scanned in full, and blocked for finding PII"
fi
git reset -q >/dev/null; rm -f newfile.txt

echo "== ${PASS} pass / ${FAIL} fail / ${CANT} cannot-run =="
[ "${FAIL}" -gt 0 ] && exit 1
[ "${CANT}" -gt 0 ] && exit 2
exit 0
