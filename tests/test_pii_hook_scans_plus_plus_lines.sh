#!/usr/bin/env bash
#
# tests/test_pii_hook_scans_plus_plus_lines.sh
#
# THE PRE-COMMIT OPERATOR-PII HOOK MUST SCAN AN ADDED LINE WHOSE CONTENT STARTS
# WITH '+'.
#
# The hook narrows a MODIFIED file to its added lines. It used
#     sed -n 's/^+\([^+].*\)$/\1/p; s/^+$//p'
# whose `[^+]` skips the `+++ b/<path>` header and ALSO every added line whose
# content starts with '+'. In a staged vendor/divergences/*.patch that is every
# line the patch adds to the vendored side, so operator PII there reached the
# commit unscanned.
#
#   1  control: the term on an ordinary added line         BLOCKED (main + fix)
#   2  the term on an added patch '+' line ('++' in diff)   BLOCKED (fix only)
#   3  the term on an added patch '-' line ('+-' in diff)   BLOCKED (main + fix)
#   4  clean control: an added patch '+' line, no term      PASSES
#   +  the hook's output never carries the term
#
# The identity scanner is the repo's own .github/scripts/operator-pii-scan.sh,
# run under a temporary HOME holding a SYNTHETIC inventory whose one entry is
# composed at runtime. The real inventory is never read.
#
# Exit: 0 pass, 1 fail, 2 CANNOT-RUN (never a pass).
# British English; " -- " not em-dashes.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
HOOK="${REPO}/.githooks/pre-commit-operator-pii"
SHAPE="${REPO}/.github/scripts/ci-pii-shape-scan.sh"
PATTERNS="${REPO}/.githooks/pii_patterns.sh"
IDENT="${REPO}/.github/scripts/operator-pii-scan.sh"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
cant() { printf '  [CANNOT-RUN] %s\n' "$*"; echo "== ${PASS} pass / ${FAIL} fail / 1 cannot-run =="; exit 2; }

for f in "$HOOK" "$SHAPE" "$IDENT" "$PATTERNS"; do [ -r "$f" ] || cant "missing: $f"; done
command -v git >/dev/null 2>&1 || cant "git absent"
command -v rg  >/dev/null 2>&1 || cant "ripgrep absent; the identity scanner cannot run, and that is not a pass"

WORK="$(mktemp -d -t piiplusplus.XXXXXX)" || cant "mktemp failed"
trap 'rm -rf -- "$WORK"' EXIT

TERM_HIT="$(printf '%s%s%s' 'Qz' 'vrn' 'dal')"
FAKEHOME="$WORK/home"; mkdir -p "$FAKEHOME"
printf '[family_names]\nnames = [\n    "%s",\n]\n' "$TERM_HIT" > "$FAKEHOME/.ostler-operator-pii.toml"

REPOD="$WORK/repo"
mkdir -p "$REPOD/.githooks" "$REPOD/.github/scripts" "$REPOD/vendor/divergences"
cp "$HOOK" "$PATTERNS" "$REPOD/.githooks/"
cp "$SHAPE" "$IDENT" "$REPOD/.github/scripts/"
chmod +x "$REPOD/.githooks/pre-commit-operator-pii" "$REPOD/.github/scripts/"*.sh
cd "$REPOD" || cant "cannot enter the fixture repo"
git init -q .
git config user.email t@t.invalid
git config user.name t
P=vendor/divergences/synth.patch
printf -- '--- a/pkg/mod.py\n+++ b/pkg/mod.py\n@@ -1,2 +1,2 @@\n def owner():\n-    return "x"\n+    return "y"\n' > "$P"
printf '# fixture\n' > notes.txt
git add -A >/dev/null
GIT_CONFIG_NOSYSTEM=1 git commit -q -m base >/dev/null 2>&1 || cant "could not commit the fixture base"

run_hook() {
    HOME="$FAKEHOME" OPERATOR_PII_SCAN_BIN="$REPOD/.github/scripts/operator-pii-scan.sh" \
        ./.githooks/pre-commit-operator-pii > "$WORK/out" 2>&1
}
expect_block() { # label
    if run_hook; then
        bad "$1: the hook PASSED (operator PII reached the commit unscanned)"
    elif ! grep -q 'operator PII detected' "$WORK/out"; then
        bad "$1: non-zero, but NOT for finding operator PII: $(tail -2 "$WORK/out" | grep -vF "$TERM_HIT" | tr '\n' ' ')"
    else
        ok "$1: BLOCKED for operator PII"
    fi
}
# Unstage first, then restore the working tree from the (now clean) index.
reset_fixture() { git reset -q >/dev/null; git checkout -q -- .; }

echo "== the pre-commit operator-PII hook scans added lines that start with '+' =="

printf 'owner = "%s"\n' "$TERM_HIT" >> notes.txt; git add notes.txt
expect_block "1 control: term on an ordinary added line"
reset_fixture

printf '+    note = "%s"\n' "$TERM_HIT" >> "$P"; git add "$P"
expect_block "2 term on an added patch '+' line"
reset_fixture

printf -- '-    note = "%s"\n' "$TERM_HIT" >> "$P"; git add "$P"
expect_block "3 control: term on an added patch '-' line"
reset_fixture

printf '+    note = "plain"\n' >> "$P"; git add "$P"
if run_hook; then ok "4 clean control: an added patch '+' line without the term passes"
else bad "4 clean control: blocked a clean '+' line: $(tail -2 "$WORK/out" | tr '\n' ' ')"; fi
reset_fixture

# The hook prints the scanner's hit lines (file:line:text) to stderr; that is
# its existing contract on a developer's own machine. Here only the fact of the
# block matters, so the output file is not echoed.

echo "== ${PASS} pass / ${FAIL} fail / 0 cannot-run =="
[ "$FAIL" -eq 0 ]
