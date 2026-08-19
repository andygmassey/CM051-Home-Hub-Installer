#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cut-deferrals.yaml must not repeat a top-level key.
#
# WHAT THIS CAUGHT, 2026-08-13. The file carried `deferrals:` TWICE. PyYAML
# resolves a duplicate mapping key by letting the LAST one win, so the earlier
# block was parsed away entirely and FIVE deliberate deferrals did not exist as
# far as check-orphans was concerned:
#
#   CM041:fix/one-person-one-name
#   CM041:#109
#   CM051:fix/cut-freshness-selftest-release-mock
#   daemon:#287
#   daemon:#286
#
#   loaded before the fix   557
#   written in the file     562
#
# Nothing warned. Not YAML, not the gate, not a linter. The file READ as five
# recorded decisions and the register held zero, which is the safe-looking
# direction and therefore the harder one to notice.
#
# WHY A DEDICATED TEST AND NOT "JUST BE CAREFUL". This file is append-heavy and
# edited under time pressure at cut time. A second `deferrals:` is exactly the
# thing a human writes when adding a section at the bottom of a 600-line file,
# and exactly the thing YAML forgives silently.
#
# yaml.safe_load CANNOT detect this -- by the time you hold the dict, the
# duplicate is gone. So this parses the TEXT for repeated top-level keys.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$REPO_ROOT/cut-deferrals.yaml"

PASSED=0
FAILED=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; PASSED=$((PASSED+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*" >&2; FAILED=$((FAILED+1)); }

command -v python3 >/dev/null 2>&1 || { echo "CANNOT RUN: no python3" >&2; exit 2; }
[ -f "$TARGET" ] || { echo "CANNOT RUN: $TARGET not found" >&2; exit 2; }

echo "test_cut_deferrals_no_duplicate_keys"

# Prints one line per top-level key that appears more than once: "key count".
dupes() {
    python3 - "$1" <<'PY'
import sys, collections
c = collections.Counter()
for line in open(sys.argv[1]):
    if line[:1] not in (' ', '#', '-', '\n') and line.rstrip().endswith(':'):
        c[line.rstrip()] += 1
for k, n in sorted(c.items()):
    if n > 1:
        print(f"{k} {n}")
PY
}

DUPES="$(dupes "$TARGET")"
if [[ -z "$DUPES" ]]; then
    ok "no repeated top-level key in cut-deferrals.yaml"
else
    bad "REPEATED top-level key -- everything under the earlier one is parsed
       away and its entries silently do not exist:
$DUPES"
fi

# Count what the PARSER sees against what the FILE says. A duplicate key is one
# way to lose entries; this catches any other way too.
python3 - "$TARGET" <<'PY'
import sys, yaml
p = sys.argv[1]
loaded = len((yaml.safe_load(open(p)) or {}).get("deferrals") or [])
written = sum(1 for l in open(p) if l.startswith("  - ref:"))
# pr_exemptions entries share the "  - ref:" shape, so subtract them.
written -= len((yaml.safe_load(open(p)) or {}).get("pr_exemptions") or [])
print(f"LOADED {loaded} WRITTEN {written}")
sys.exit(0 if loaded == written else 1)
PY
rc=$?
COUNTS="$(python3 -c "
import yaml,sys
d=yaml.safe_load(open('$TARGET')) or {}
print(len(d.get('deferrals') or []), len(d.get('pr_exemptions') or []))
")"
if (( rc == 0 )); then
    ok "every written deferral is loaded (deferrals/pr_exemptions: $COUNTS)"
else
    bad "the parser loads FEWER deferrals than the file contains. Entries are
       being dropped silently. See the counts printed above."
fi

# --- NEGATIVE CONTROL ------------------------------------------------------
# Everything above passes against a dupes() that always returns empty. Feed it
# a file with a KNOWN duplicate and require detection. Without this the test is
# guard-shaped and blind -- which is the exact defect it was written to catch.
CTL="$(mktemp -t deferdup-XXXXXX)"
cat > "$CTL" <<'EOF'
deferrals:
  - ref: "A"
pr_exemptions: []
deferrals:
  - ref: "B"
EOF
CTL_OUT="$(dupes "$CTL")"
rm -f "$CTL"
if [[ "$CTL_OUT" == "deferrals: 2" ]]; then
    ok "CONTROL: a file with a duplicate deferrals key is detected"
else
    bad "CONTROL FAILED: known-bad file reported '$CTL_OUT', expected 'deferrals: 2'.
       The detector is broken, so the pass above proves nothing."
fi

echo
if (( FAILED == 0 )); then
    printf '\033[32m%s passed, 0 failed\033[0m\n' "$PASSED"
    exit 0
fi
printf '\033[31m%s passed, %s failed\033[0m\n' "$PASSED" "$FAILED"
exit 1
