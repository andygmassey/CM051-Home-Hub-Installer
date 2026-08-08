#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Tests scripts/verify_pbxproj_in_sync.sh.
#
# A gate that has never failed has never been tested. The v1.0.17 cut found a
# gate reporting "Xcode tracks every copy (no stale files)" against a project
# it never read; the whole point of this file is that the SAME thing cannot
# quietly happen to the gate that replaced it.
#
# Every case asserts an EXIT CODE, and the codes are distinct on purpose:
#   0 = in sync   1 = out of sync (cut fault)   2 = could not run (tool fault)
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$REPO_ROOT/scripts/verify_pbxproj_in_sync.sh"

SPEC="$REPO_ROOT/gui/project.yml"
PROJ_DIR="$REPO_ROOT/gui/OstlerInstaller.xcodeproj"
PBXPROJ="$PROJ_DIR/project.pbxproj"

PASSED=0
FAILED=0

ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; PASSED=$((PASSED+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*" >&2; FAILED=$((FAILED+1)); }

[[ -x "$GATE" ]] || { echo "gate not executable: $GATE" >&2; exit 2; }

# Refuse to run against a dirty project -- the cases below mutate and restore
# tracked files, and we will not gamble with someone's uncommitted work.
if ! git -C "$REPO_ROOT" diff --quiet -- "$PROJ_DIR" "$SPEC" 2>/dev/null; then
    echo "SKIP-AS-ERROR: gui/project.yml or the .xcodeproj has uncommitted changes." >&2
    echo "               Commit or stash first. A skip is not a pass." >&2
    exit 2
fi

restore_all() {
    git -C "$REPO_ROOT" checkout -- "$SPEC" "$PROJ_DIR" 2>/dev/null || true
}
trap restore_all EXIT INT TERM

run_gate() { ( "$GATE" >/dev/null 2>&1 ); echo $?; }

echo "test_pbxproj_sync_gate"

# --- baseline -------------------------------------------------------------
rc="$(run_gate)"
if [[ "$rc" == 0 ]]; then ok "baseline: committed tree is in sync (rc=0)"
else bad "baseline: expected rc=0, got rc=$rc -- the committed pbxproj is stale"; fi

# --- CONTROL 1: spec changed, project not regenerated ---------------------
python3 - "$SPEC" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
probe = ("  ControlProbeTarget:\n"
         "    type: bundle.unit-test\n"
         "    platform: macOS\n"
         "    sources: [OstlerInstallerTests]\n\n")
assert "  OstlerInstallerTests:" in s, "anchor target missing from project.yml"
open(p, "w").write(s.replace("  OstlerInstallerTests:", probe + "  OstlerInstallerTests:", 1))
PY
rc="$(run_gate)"
if [[ "$rc" == 1 ]]; then ok "CONTROL: spec change without regen is RED (rc=1)"
else bad "CONTROL FAILED: a stale pbxproj returned rc=$rc, expected 1. The gate is BLIND."; fi
git -C "$REPO_ROOT" checkout -- "$SPEC"

# --- CONTROL 2: already-dirty project must be UNAVAILABLE, never a pass ---
printf '\n// control probe\n' >> "$PBXPROJ"
rc="$(run_gate)"
if [[ "$rc" == 2 ]]; then ok "CONTROL: dirty pbxproj is UNAVAILABLE (rc=2), not a pass"
else bad "CONTROL FAILED: dirty pbxproj returned rc=$rc, expected 2"; fi
git -C "$REPO_ROOT" checkout -- "$PROJ_DIR"

# --- CONTROL 3: missing xcodegen must be UNAVAILABLE, never a pass --------
rc="$( ( PATH=/usr/bin:/bin "$GATE" >/dev/null 2>&1 ); echo $? )"
if [[ "$rc" == 2 ]]; then ok "CONTROL: xcodegen absent is UNAVAILABLE (rc=2), not a pass"
else bad "CONTROL FAILED: missing xcodegen returned rc=$rc, expected 2"; fi

# --- the gate must leave the tree exactly as it found it ------------------
run_gate >/dev/null
if git -C "$REPO_ROOT" diff --quiet -- "$PROJ_DIR" "$SPEC" 2>/dev/null; then
    ok "gate restores the tree (no residue after a run)"
else
    bad "the gate left the tree DIRTY -- it regenerates in place and must restore"
fi

echo
if (( FAILED == 0 )); then
    printf '\033[32m%s passed, 0 failed\033[0m\n' "$PASSED"; exit 0
else
    printf '\033[31m%s passed, %s FAILED\033[0m\n' "$PASSED" "$FAILED" >&2; exit 1
fi
