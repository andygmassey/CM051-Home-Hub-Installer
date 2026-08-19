#!/usr/bin/env bash
# Installer version-consistency gate (CM051 #171, v1.0.13).
#
# The failure this refuses:
#   The DMG's OstlerInstaller.app stamps a STALE CFBundleShortVersionString.
#   For v1.0.11 AND v1.0.12 the installer app shipped reading "1.0.10" -- the
#   value was hardcoded and never bumped, because gui/Makefile DERIVES the DMG
#   name + the app version by READING gui/OstlerInstaller/Info.plist, not from
#   the cut tag. A half-bump (project.yml bumped but Info.plist forgotten, or
#   Info.plist bumped but `xcodegen generate` not re-run so the tracked
#   pbxproj lags) ships a version-stale installer while every signing/notarise
#   chain goes green. Same class as the "silent bail" regressions this repo
#   already gates.
#
# This test makes a half-bump impossible to merge: it asserts the installer's
# version is IDENTICAL across the three tracked sources of truth --
#   1. gui/OstlerInstaller/Info.plist        (what the built .app stamps)
#   2. gui/project.yml                        (the xcodegen source)
#   3. gui/OstlerInstaller.xcodeproj/project.pbxproj  (the generated project)
# on BOTH the marketing/short version (CFBundleShortVersionString /
# MARKETING_VERSION) and the build number (CFBundleVersion /
# CURRENT_PROJECT_VERSION). If project.yml is edited but `xcodegen generate`
# was not re-run, the pbxproj lags and this gate goes RED.
#
# Portable by design: runs in GitHub Actions on ubuntu-latest (no PlistBuddy),
# so the Info.plist is parsed with Python's stdlib plistlib, and project.yml /
# pbxproj are parsed with grep. No third-party deps.
#
# NOTE (residual manual step): the marketing version is NOT yet derived from
# the cut tag. Bumping a release still requires a human to edit
# MARKETING_VERSION + CFBundleShortVersionString in gui/project.yml and
# gui/OstlerInstaller/Info.plist, then run `cd gui && xcodegen generate`.
# The BUILD NUMBER is no longer a free-hand field -- see below.
#
# ============================================================================
# WHY AGREEMENT WAS NOT ENOUGH, AND WHAT SHIPPED BECAUSE OF IT (#703)
# ============================================================================
#
# Everything above checks that the four sites AGREE. A gate that checks
# agreement is structurally blind to a value that is uniformly wrong, and that
# is exactly what happened. Measured 2026-08-16 on main 76f9974:
#
#     CFBundleShortVersionString   1.0.32
#     CFBundleVersion              2500      <- four sites, all saying 2500
#
# 2500 is the build number for 1.0.25. The bump stopped after #613 and the
# value has been frozen through v1.0.26, .27, .28, .29, .30, .31 and .32. All
# seven cuts shipped, signed and notarised, with this gate green, because all
# four sites were wrong together.
#
# The only thing that ever compared the build number to an EXPECTED value was a
# per-cut assertion in cut-manifests/v1.0.NN.yaml. v1.0.16 through v1.0.23 each
# carry one. v1.0.24 rewrote the manifest from scratch and carried the
# CFBundleShortVersionString row forward by name while the CFBundleVersion row
# was simply not re-typed. v1.0.24 onward carry ZERO. So check-manifest went
# green on eight consecutive cuts by no longer asking the question.
#
# The gate was dropped at v1.0.24. The value first went wrong at v1.0.26. Two
# clean cuts sat between them, which is why nothing looked broken on the day.
#
# WHY IT IS NOT COSMETIC. CFBundleVersion is the field Sparkle compares. Sparkle
# silently skips any appcast item whose sparkle:version is less than or equal to
# the installed CFBundleVersion. A v1.0.33 stamped 2500 offered to a v1.0.32 box
# stamped 2500 is not a failed update, it is no update and no message. It also
# means every box from v1.0.25 to v1.0.32 is indistinguishable to Sparkle, to
# `mdls`, and to any support diagnostic that reads the build number.
#
# THE FIX IS A DERIVATION, NOT ANOTHER HAND-COPIED ROW. Restoring a per-cut
# manifest row would restore exactly the thing that was forgotten. So the build
# number is now DERIVED from the marketing version and asserted here, on every
# PR and every push to main, where it cannot be left out of a rewrite.
#
#     1.0.P    ->  P * 100          1.0.32   -> 3200
#     1.0.P.H  ->  P * 100 + H      1.0.13.2 -> 1302
#
# That rule reproduces every value shipped since v1.0.13.1. Anything outside the
# 1.0.x line (a future 1.1.0 or 2.0.0) is CANNOT-RUN, exit 2, NOT a pass: a new
# numbering line is a decision somebody has to take deliberately, and a gate
# that quietly passes the first release of a new series is the same failure
# again one series later.
#
# Exit 0 = agree AND the build number is the derived one.
# Exit 1 = drift, or a build number that is not derived from the version.
# Exit 2 = CANNOT-RUN: the version is outside the scheme this gate encodes.

set -euo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_DEFAULT="$(cd "$SCRIPT_DIR_TEST/.." && pwd)"

# --repo-root exists so --self-test can drive THIS SCRIPT against synthetic
# trees in a subprocess, rather than re-implementing the checks inside the
# self-test and proving that the copy works. CI passes no arguments.
SELF_TEST=0
REPO_ROOT="$REPO_ROOT_DEFAULT"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --self-test) SELF_TEST=1; shift ;;
        --repo-root) REPO_ROOT="${2:?--repo-root needs a directory}"; shift 2 ;;
        *) echo "usage: $0 [--self-test] [--repo-root DIR]" >&2; exit 2 ;;
    esac
done

INFO_PLIST="$REPO_ROOT/gui/OstlerInstaller/Info.plist"
PROJECT_YML="$REPO_ROOT/gui/project.yml"
PBXPROJ="$REPO_ROOT/gui/OstlerInstaller.xcodeproj/project.pbxproj"

fail() { echo "FAIL: $*" >&2; exit 1; }
cannot_run() { echo "CANNOT-RUN: $*" >&2; exit 2; }

# The derivation. `10#` forces base 10 so a zero-padded component cannot be
# read as octal and abort the arithmetic.
derive_build_number() {
    local short="$1"
    if [[ "$short" =~ ^1\.0\.([0-9]{1,2})$ ]]; then
        printf '%d\n' "$(( 10#${BASH_REMATCH[1]} * 100 ))"
        return 0
    fi
    if [[ "$short" =~ ^1\.0\.([0-9]{1,2})\.([0-9]{1,2})$ ]]; then
        printf '%d\n' "$(( 10#${BASH_REMATCH[1]} * 100 + 10#${BASH_REMATCH[2]} ))"
        return 0
    fi
    return 2
}

# --- self-test ---------------------------------------------------------------
#
# Every control below runs THIS SCRIPT in a subprocess against a synthetic tree.
# None of them re-implements the comparison. That matters: a self-test built on
# a private copy of the predicate prints green while the real code path carries
# the defect, which is a shape we have now hit more than once.
#
# Control (1) is the one that earns the change: it is the exact state of main
# on 2026-08-16, all four sites agreeing on 2500 under version 1.0.32, and it
# must FAIL. Before this commit that tree was a clean pass.
if [[ "$SELF_TEST" == "1" ]]; then
    st_pass=0; st_fail=0
    ok() { printf '  PASS  %s\n' "$1"; st_pass=$((st_pass + 1)); }
    no() { printf '  FAIL  %s\n' "$1"; st_fail=$((st_fail + 1)); }

    ST_DIR="$(mktemp -d -t versionconsistency-XXXXXX)"
    trap 'rm -rf "$ST_DIR"' EXIT
    st_n=0

    # make_tree <plist_short> <plist_build> <yml_short> <yml_build> <pbx_short> <pbx_build>
    # echoes the root it built.
    make_tree() {
        st_n=$((st_n + 1))
        local root="$ST_DIR/t$st_n"
        mkdir -p "$root/gui/OstlerInstaller" "$root/gui/OstlerInstaller.xcodeproj"
        cat > "$root/gui/OstlerInstaller/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleShortVersionString</key>
	<string>$1</string>
	<key>CFBundleVersion</key>
	<string>$2</string>
</dict>
</plist>
PLIST
        cat > "$root/gui/project.yml" <<YML
settings:
  base:
    CURRENT_PROJECT_VERSION: "$4"
    MARKETING_VERSION: "$3"
targets:
  OstlerInstaller:
    info:
      properties:
        CFBundleShortVersionString: "$3"
        CFBundleVersion: "$4"
YML
        cat > "$root/gui/OstlerInstaller.xcodeproj/project.pbxproj" <<PBX
/* Begin XCBuildConfiguration section */
				CURRENT_PROJECT_VERSION = $6;
				MARKETING_VERSION = $5;
				CURRENT_PROJECT_VERSION = $6;
				MARKETING_VERSION = $5;
/* End XCBuildConfiguration section */
PBX
        printf '%s\n' "$root"
    }

    # run <root>  ->  sets ST_RC and ST_OUT. `|| ST_RC=$?` and not `; ST_RC=$?`,
    # because a negative control that fails on purpose would otherwise kill the
    # harness under `set -e` before it could be scored.
    run_gate() {
        ST_RC=0
        ST_OUT="$(bash "$0" --repo-root "$1" 2>&1)" || ST_RC=$?
    }

    echo "test_installer_version_consistency.sh: self-test"

    # (1) THE DEFECT. main as measured 2026-08-16: 1.0.32 everywhere, 2500
    #     everywhere. Perfect agreement, and the build number belongs to 1.0.25.
    run_gate "$(make_tree 1.0.32 2500 1.0.32 2500 1.0.32 2500)"
    if [[ "$ST_RC" == "1" ]] && printf '%s' "$ST_OUT" | grep -q "3200"; then
        ok "(1) 1.0.32 with a uniformly frozen 2500 fails, and names 3200"
    else
        no "(1) the shipped defect passed, or failed without naming the expected value (rc=$ST_RC)"
    fi

    # (2) The same tree, corrected. Must pass, or the gate cannot be satisfied.
    run_gate "$(make_tree 1.0.32 3200 1.0.32 3200 1.0.32 3200)"
    [[ "$ST_RC" == "0" ]] && ok "(2) 1.0.32 / 3200 passes" \
                          || no "(2) the corrected tree did not pass (rc=$ST_RC)"

    # (3)+(4) The hotfix form, which is why the rule is not simply patch*100.
    run_gate "$(make_tree 1.0.13.2 1302 1.0.13.2 1302 1.0.13.2 1302)"
    [[ "$ST_RC" == "0" ]] && ok "(3) hotfix 1.0.13.2 / 1302 passes" \
                          || no "(3) the hotfix numbering was rejected (rc=$ST_RC)"

    run_gate "$(make_tree 1.0.13.2 1300 1.0.13.2 1300 1.0.13.2 1300)"
    [[ "$ST_RC" == "1" ]] && ok "(4) hotfix 1.0.13.2 / 1300 fails, the .2 is load-bearing" \
                          || no "(4) a hotfix build number that drops the hotfix digit passed (rc=$ST_RC)"

    # (5) The ORIGINAL #171 check must still work: a half-bumped marketing
    #     version. Adding a predicate must not quietly retire the one it joins.
    run_gate "$(make_tree 1.0.33 3300 1.0.32 3200 1.0.32 3200)"
    if [[ "$ST_RC" == "1" ]] && printf '%s' "$ST_OUT" | grep -q "marketing version drift"; then
        ok "(5) marketing half-bump still fails as marketing drift, not as derivation"
    else
        no "(5) the #171 half-bump check was lost or its message changed (rc=$ST_RC)"
    fi

    # (6) ...and the build-number AGREEMENT check, likewise. This one must
    #     report drift rather than derivation, or the message sends whoever
    #     reads it to re-derive a number that is already right in one place.
    run_gate "$(make_tree 1.0.32 3200 1.0.32 3300 1.0.32 3300)"
    if [[ "$ST_RC" == "1" ]] && printf '%s' "$ST_OUT" | grep -q "build number drift"; then
        ok "(6) build-number half-bump still fails as drift, before derivation is consulted"
    else
        no "(6) the build-number agreement check was lost or reordered (rc=$ST_RC)"
    fi

    # (7) A version outside the encoded scheme. CANNOT-RUN, exit 2. Never 0.
    #     The first 1.1.0 must stop and be decided, not sail through on a rule
    #     that was only ever true for the 1.0.x line.
    run_gate "$(make_tree 1.1.0 1100 1.1.0 1100 1.1.0 1100)"
    [[ "$ST_RC" == "2" ]] && ok "(7) 1.1.0 is CANNOT-RUN (exit 2), not a silent pass" \
                          || no "(7) a version outside the scheme was adjudicated anyway (rc=$ST_RC)"

    # (8) The derivation, exercised directly across the values this repo has
    #     actually shipped. If any of these disagree, the rule is a guess.
    d_ok=1
    for pair in "1.0.16:1600" "1.0.17:1700" "1.0.19:1900" "1.0.25:2500" "1.0.32:3200" "1.0.13.1:1301" "1.0.13.2:1302"; do
        v="${pair%%:*}"; want="${pair##*:}"
        got="$(derive_build_number "$v")" || got="ERR"
        [[ "$got" == "$want" ]] || { d_ok=0; echo "        $v derived $got, shipped $want"; }
    done
    [[ "$d_ok" == "1" ]] && ok "(8) the rule reproduces every build number shipped since v1.0.13.1" \
                         || no "(8) the derivation contradicts a value that actually shipped"

    echo
    echo "=== $st_pass passed / $st_fail failed ==="
    [[ "$st_fail" -eq 0 ]] || exit 1
    exit 0
fi

for f in "$INFO_PLIST" "$PROJECT_YML" "$PBXPROJ"; do
    [[ -f "$f" ]] || fail "missing required file: $f"
done

# --- Info.plist (stdlib plistlib -- portable, no PlistBuddy) -----------------
plist_key() {
    python3 - "$INFO_PLIST" "$1" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as fh:
    d = plistlib.load(fh)
key = sys.argv[2]
if key not in d:
    sys.stderr.write(f"FAIL: {key} absent from Info.plist\n")
    sys.exit(1)
print(str(d[key]).strip())
PY
}

# --- project.yml (single-occurrence keys; grep the quoted scalar) ------------
# Keys are unique in project.yml: MARKETING_VERSION + CURRENT_PROJECT_VERSION
# live once under settings.base; CFBundleShortVersionString + CFBundleVersion
# live once under the target's info.properties. Guard against a future
# duplicate by asserting exactly one match.
yml_val() {
    local key="$1" matches
    matches="$(grep -E "^[[:space:]]*${key}:[[:space:]]" "$PROJECT_YML" || true)"
    [[ -n "$matches" ]] || fail "$key not found in project.yml"
    if [[ "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" != "1" ]]; then
        fail "$key appears more than once in project.yml -- ambiguous:
$matches"
    fi
    printf '%s\n' "$matches" | sed -E 's/.*:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/'
}

# --- pbxproj (multiple occurrences: Debug + Release must all agree) ----------
pbx_uniq() {
    local key="$1" vals
    vals="$(grep -E "^[[:space:]]*${key} = " "$PBXPROJ" \
              | sed -E "s/.*${key} = ([^;]*);.*/\1/" | sort -u || true)"
    [[ -n "$vals" ]] || fail "$key not found in pbxproj"
    if [[ "$(printf '%s\n' "$vals" | wc -l | tr -d ' ')" != "1" ]]; then
        fail "$key has inconsistent values across build configs in pbxproj:
$vals"
    fi
    printf '%s\n' "$vals"
}

# ---------------------------------------------------------------------------
# Marketing / short version (e.g. "1.0.13")
# ---------------------------------------------------------------------------
PLIST_SHORT="$(plist_key CFBundleShortVersionString)"
YML_SHORT="$(yml_val CFBundleShortVersionString)"
YML_MARKETING="$(yml_val MARKETING_VERSION)"
PBX_MARKETING="$(pbx_uniq MARKETING_VERSION)"

echo "[version] CFBundleShortVersionString (Info.plist):     $PLIST_SHORT"
echo "[version] CFBundleShortVersionString (project.yml):    $YML_SHORT"
echo "[version] MARKETING_VERSION          (project.yml):    $YML_MARKETING"
echo "[version] MARKETING_VERSION          (pbxproj):        $PBX_MARKETING"

if [[ "$PLIST_SHORT" != "$YML_SHORT" || "$PLIST_SHORT" != "$YML_MARKETING" || "$PLIST_SHORT" != "$PBX_MARKETING" ]]; then
    fail "installer marketing version drift -- the three sources disagree.
  Info.plist CFBundleShortVersionString = $PLIST_SHORT
  project.yml CFBundleShortVersionString = $YML_SHORT
  project.yml MARKETING_VERSION          = $YML_MARKETING
  pbxproj     MARKETING_VERSION          = $PBX_MARKETING
  This is the #171 stale-version shape. If you bumped project.yml, run
  'cd gui && xcodegen generate' to refresh the pbxproj and edit Info.plist
  to match. All four must be the same string."
fi

# ---------------------------------------------------------------------------
# Build number (e.g. "13")
# ---------------------------------------------------------------------------
PLIST_BUILD="$(plist_key CFBundleVersion)"
YML_BUILD="$(yml_val CFBundleVersion)"
YML_CURRENT="$(yml_val CURRENT_PROJECT_VERSION)"
PBX_CURRENT="$(pbx_uniq CURRENT_PROJECT_VERSION)"

echo "[build]   CFBundleVersion        (Info.plist):    $PLIST_BUILD"
echo "[build]   CFBundleVersion        (project.yml):   $YML_BUILD"
echo "[build]   CURRENT_PROJECT_VERSION (project.yml):  $YML_CURRENT"
echo "[build]   CURRENT_PROJECT_VERSION (pbxproj):      $PBX_CURRENT"

if [[ "$PLIST_BUILD" != "$YML_BUILD" || "$PLIST_BUILD" != "$YML_CURRENT" || "$PLIST_BUILD" != "$PBX_CURRENT" ]]; then
    fail "installer build number drift -- the four sources disagree.
  Info.plist CFBundleVersion         = $PLIST_BUILD
  project.yml CFBundleVersion         = $YML_BUILD
  project.yml CURRENT_PROJECT_VERSION = $YML_CURRENT
  pbxproj     CURRENT_PROJECT_VERSION = $PBX_CURRENT
  Re-run 'cd gui && xcodegen generate' after editing project.yml, and keep
  Info.plist in lockstep."
fi

# ---------------------------------------------------------------------------
# The build number must be DERIVED from the marketing version (#703).
# ---------------------------------------------------------------------------
# Everything above this line proves the four sites agree. Agreement is blind to
# a value that is uniformly wrong, and v1.0.26 through v1.0.32 shipped exactly
# that: 2500 in all four places, under versions it had not belonged to since
# v1.0.25. See the header for the mechanism.
if ! EXPECTED_BUILD="$(derive_build_number "$PLIST_SHORT")"; then
    cannot_run "version '$PLIST_SHORT' is outside the numbering scheme this gate encodes.
  The rule below reproduces every build number shipped since v1.0.13.1:
      1.0.P     ->  P * 100
      1.0.P.H   ->  P * 100 + H
  A version outside the 1.0.x line means the scheme itself needs a decision,
  and this gate refuses rather than guessing. That refusal is deliberate: the
  alternative is a new release series whose first build number nobody checked.
  Extend derive_build_number() in this file, in the same commit that
  introduces the new version, and say what the new rule is."
fi

echo "[build]   derived from $PLIST_SHORT:                  $EXPECTED_BUILD"

if [[ "$PLIST_BUILD" != "$EXPECTED_BUILD" ]]; then
    fail "installer build number is not derived from the version.
  CFBundleShortVersionString = $PLIST_SHORT
  CFBundleVersion            = $PLIST_BUILD
  expected                   = $EXPECTED_BUILD

  All four sites agree, which is why the check above passed. They agree on the
  WRONG value. This is the #703 shape: the build number was last bumped for
  v1.0.25 and then carried unchanged through seven signed and notarised cuts.

  CFBundleVersion is the field Sparkle compares. An update whose build number
  is less than or equal to the installed one is skipped silently -- no error,
  no prompt, no log line the customer will ever see.

  Set CFBundleVersion to $EXPECTED_BUILD in gui/OstlerInstaller/Info.plist and
  gui/project.yml (both CFBundleVersion and CURRENT_PROJECT_VERSION), then run
  'cd gui && xcodegen generate' to refresh the pbxproj."
fi

echo "PASS: installer version consistent across Info.plist, project.yml, pbxproj, and the build number is derived (v$PLIST_SHORT build $PLIST_BUILD)"
exit 0
