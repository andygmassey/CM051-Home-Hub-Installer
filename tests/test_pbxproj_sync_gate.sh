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

# KEEP THE GATE'S OUTPUT. The first version sent it to /dev/null and returned
# only the exit code, and that is precisely what made the CI failure
# unreadable: the gate prints BOTH sha256s and a 40-line `git diff` on failure,
# and every byte of it was discarded. The one run that disagreed with a local
# run was the one run whose evidence was thrown away.
#
# The controls below only care about the CODE, which is right -- they assert
# rc==1 or rc==2 and the text is noise. The BASELINE is different: an
# unexpected rc there is an unexplained disagreement about the repo itself, and
# the explanation is in the output.
GATE_LOG="$(mktemp)"
run_gate() { ( "$GATE" >"$GATE_LOG" 2>&1 ); echo $?; }

echo "test_pbxproj_sync_gate"

# --- baseline -------------------------------------------------------------
rc="$(run_gate)"
BASELINE_RC="$rc"          # the restore check at the end compares against this
if [[ "$rc" == 0 ]]; then ok "baseline: committed tree is in sync (rc=0)"
else
    bad "baseline: expected rc=0, got rc=$rc -- the committed pbxproj is stale"
    # Everything after this is measured against a tree the gate already
    # disagrees with, so say so once, loudly, with the evidence attached.
    {
        echo ""
        echo "  ---- gate output (baseline), which the harness used to discard ----"
        sed 's/^/  | /' "$GATE_LOG"
        echo "  ---- end gate output ----"
        echo ""
        echo "  Environment, because a local run of this same gate on this same"
        echo "  commit returns 0 and the difference has to be here:"
        echo "    xcodegen : $(command -v xcodegen || echo '<not on PATH>')"
        echo "    version  : $(xcodegen --version 2>&1 | head -1)"
        echo "    pinned   : $(grep -v '^[[:space:]]*#' "$REPO_ROOT/gui/.xcodegen-version" 2>/dev/null | grep -v '^[[:space:]]*$' | head -1)"
        echo "    xcodebuild: $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
        echo "    uname    : $(uname -sm)"
        echo ""
    } >&2
fi

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

# --- CONTROL 4+5: the xcodegen version pin --------------------------------
# The gate's comparison is byte-exact, so it is only meaningful against the
# generator that produced the tracked file. A different xcodegen emitting
# different bytes from identical input must present as "could not run", NOT as
# "the project is stale" -- a gate that goes red for a toolchain bump is a gate
# people learn to ignore.
#
# Both cases assert rc==2 specifically and reject rc==1, because the whole
# value of the pin is which of those two answers you get.
PIN_FILE="$REPO_ROOT/gui/.xcodegen-version"
PIN_BACKUP="$(mktemp)"

if [[ -f "$PIN_FILE" ]]; then
    cp "$PIN_FILE" "$PIN_BACKUP"

    printf '0.0.0-not-a-real-version\n' > "$PIN_FILE"
    rc="$(run_gate)"
    cp "$PIN_BACKUP" "$PIN_FILE"
    if [[ "$rc" == 2 ]]; then
        ok "CONTROL: pinned version != installed is UNAVAILABLE (rc=2)"
    elif [[ "$rc" == 1 ]]; then
        bad "CONTROL FAILED: a version mismatch returned rc=1 (STALE, DO NOT SHIP).
       That blames the project for a toolchain difference."
    else
        bad "CONTROL FAILED: version mismatch returned rc=$rc, expected 2"
    fi

    # An absent pin must not silently fall back to "compare anyway": that is
    # the pre-pin behaviour and it is exactly what the pin exists to end.
    mv "$PIN_FILE" "$PIN_FILE.absent"
    rc="$(run_gate)"
    mv "$PIN_FILE.absent" "$PIN_FILE"
    if [[ "$rc" == 2 ]]; then ok "CONTROL: missing version pin is UNAVAILABLE (rc=2), not a pass"
    else bad "CONTROL FAILED: missing pin returned rc=$rc, expected 2"; fi

    # --- CONTROL 6+7: the XCODE pin ---------------------------------------
    # The generator has two inputs, not one. xcodegen injects default build
    # settings it reads from the INSTALLED XCODE, so pinning the generator
    # version alone still lets the toolchain decide the bytes. Measured
    # 2026-08-13: same xcodegen 2.44.1, Xcode 26.6 emits COMBINE_HIDPI_IMAGES /
    # LD_RUNPATH_SEARCH_PATHS / SDKROOT / ASSETCATALOG_COMPILER_APPICON_NAME and
    # Xcode 15.4 omits all four. The hosted runner therefore called a
    # perfectly in-sync project STALE and blocked a launch cut for two runs.
    #
    # Same doctrine as the version pin: a toolchain difference is exit 2, never
    # exit 1. These assert that specifically, and reject rc==1.
    XCODE_PIN="$REPO_ROOT/gui/.xcode-version"
    if [[ -f "$XCODE_PIN" ]]; then
        XPIN_BACKUP="$(mktemp)"
        cp "$XCODE_PIN" "$XPIN_BACKUP"

        printf '0.0-not-a-real-xcode\n' > "$XCODE_PIN"
        rc="$(run_gate)"
        cp "$XPIN_BACKUP" "$XCODE_PIN"
        if [[ "$rc" == 2 ]]; then
            ok "CONTROL: pinned Xcode != installed is UNAVAILABLE (rc=2)"
        elif [[ "$rc" == 1 ]]; then
            bad "CONTROL FAILED: an Xcode mismatch returned rc=1 (STALE, DO NOT SHIP).
       That blames the project for a toolchain difference -- the exact defect
       this pin exists to end."
        else
            bad "CONTROL FAILED: Xcode mismatch returned rc=$rc, expected 2"
        fi

        mv "$XCODE_PIN" "$XCODE_PIN.absent"
        rc="$(run_gate)"
        mv "$XCODE_PIN.absent" "$XCODE_PIN"
        if [[ "$rc" == 2 ]]; then ok "CONTROL: missing Xcode pin is UNAVAILABLE (rc=2), not a pass"
        else bad "CONTROL FAILED: missing Xcode pin returned rc=$rc, expected 2"; fi
        rm -f "$XPIN_BACKUP"
    else
        bad "gui/.xcode-version is missing -- the generator's second input is unpinned"
    fi

    # And the restore must have worked, or every case after this is void.
    #
    # THIS CHECK CANNOT DISTINGUISH TWO DIFFERENT FAULTS, and reporting it as
    # one of them sent a reader after the wrong bug. It re-runs the SAME gate
    # on the SAME tree as the baseline, so if the baseline was already red it
    # returns the same non-zero for the same reason, and the old wording --
    # "the pin was NOT restored" -- asserted a fixture corruption that had not
    # happened. Two FAIL lines, one fault.
    #
    # Compare against the baseline rather than against 0, so this line only
    # ever speaks about the restore.
    BASELINE_RC="${BASELINE_RC:-0}"
    rc="$(run_gate)"
    if [[ "$rc" == "$BASELINE_RC" ]]; then
        ok "pin restored: gate returns the baseline rc again (rc=$rc)"
    else
        bad "the pin was NOT restored -- rc=$rc, baseline was rc=$BASELINE_RC. Later results are unreliable."
    fi
else
    bad "gui/.xcodegen-version is missing. The gate cannot attribute a byte
       difference to drift rather than to the toolchain, and the two controls
       that prove it does are unrunnable. This is not a skip."
fi
rm -f "$PIN_BACKUP"

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
