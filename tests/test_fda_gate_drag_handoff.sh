#!/usr/bin/env bash
#
# tests/test_fda_gate_drag_handoff.sh
#
# macOS 27.3 removes an app's ability to add itself to Full Disk Access
# (READING_TRIAGE_2026-11-11.md). The installer's FDA screen therefore
# hands the user the app itself: a draggable tile, a fallback line, a
# Reveal in Finder button, and an automatic advance once a protected read
# succeeds.
#
# This test checks the wiring the Swift behaviour tests cannot see from
# XCTest:
#   1. Every shipped ViewCopy catalogue carries each new FDA-handoff key,
#      and every translation is a real translation (not the English),
#      with the same {placeholders} as the English.
#   2. The gate view is a real drag source (.onDrag) whose provider is the
#      running app bundle, not a hand-typed path.
#   3. The gate view honours reduce-motion with a static illustration.
#   4. The gate polls a protected read every 2 seconds and advances on grant.
#   5. The Settings deep-link is still Privacy_AllFiles, and Reveal in
#      Finder selects the bundle.
#
# Runs on any host: it reads files only. Exits non-zero on the first
# failing group, after printing every failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RES="${REPO_ROOT}/gui/OstlerInstaller/Resources"
VIEW="${REPO_ROOT}/gui/OstlerInstaller/Views/FullDiskAccessDragGateView.swift"
OLDVIEW="${REPO_ROOT}/gui/OstlerInstaller/Views/FullDiskAccessGateView.swift"
FLOW="${REPO_ROOT}/gui/OstlerInstaller/Auth/FDAFlow.swift"
ASSIST="${REPO_ROOT}/gui/OstlerInstaller/Auth/FDAAssistantProbe.swift"
CONTENT="${REPO_ROOT}/gui/OstlerInstaller/Views/ContentView.swift"
PROBE="${REPO_ROOT}/gui/OstlerInstaller/Auth/FullDiskAccessProbe.swift"
AUTH="${REPO_ROOT}/gui/OstlerInstaller/Auth/AuthorizationHelper.swift"

FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "PASS: $*"; }

# ---------------------------------------------------------------------------
# 1. Catalogues
# ---------------------------------------------------------------------------
NEW_KEYS="heading reveal_button instruction cant_drag manual_steps already_on_link waiting granted anim_drag anim_switch_on anim_done"

CAT_OUT="$(python3 -I - "$RES" $NEW_KEYS <<'PY'
import glob, json, os, sys
res, keys = sys.argv[1], sys.argv[2:]
en = json.load(open(os.path.join(res, "ViewCopy.json"), encoding="utf-8"))["fda_drag"]
problems = []
files = sorted(glob.glob(os.path.join(res, "ViewCopy*.json")))
for path in files:
    name = os.path.basename(path)
    tree = json.load(open(path, encoding="utf-8"))
    gate = tree.get("fda_drag", {})
    for k in keys:
        dotted = "fda_drag." + k
        if k not in gate:
            problems.append(f"{name}: missing {dotted}")
            continue
        if name in ("ViewCopy.json", "ViewCopy.en-US.json"):
            continue
        val, src = gate[k], en.get(k, "")
        if not val.strip():
            problems.append(f"{name}: {dotted} is empty")
        if val == src:
            problems.append(f"{name}: {dotted} is still the English")
        for ph in ("{app}",):
            if (ph in src) != (ph in val):
                problems.append(f"{name}: {dotted} placeholder {ph} mismatch")
print(f"catalogues={len(files)} keys={len(keys)}")
for p in problems:
    print("PROBLEM " + p)
PY
)"
echo "$CAT_OUT" | head -1
if echo "$CAT_OUT" | grep -q '^PROBLEM '; then
    echo "$CAT_OUT" | grep '^PROBLEM ' | sed 's/^PROBLEM /  /' >&2
    fail "catalogues: $(echo "$CAT_OUT" | grep -c '^PROBLEM ') problem(s) across the FDA-handoff keys"
else
    pass "every catalogue carries the FDA-handoff keys with real translations"
fi

# ---------------------------------------------------------------------------
# 2. Drag source is the running app bundle
# ---------------------------------------------------------------------------
if grep -q '\.onDrag' "$VIEW" && grep -q 'FDAHandoff\.dragProvider' "$VIEW" \
   && grep -q 'NSItemProvider' "$PROBE"; then
    pass "gate view is a real drag source (.onDrag -> FDAHandoff.dragProvider -> NSItemProvider)"
else
    fail "gate view has no drag source wired to an NSItemProvider"
fi
if grep -q 'appBundleURL(_ bundle: Bundle = \.main)' "$PROBE" && grep -q 'bundle\.bundleURL' "$PROBE"; then
    pass "drag URL is the main bundle's URL (the binary whose read is probed)"
else
    fail "drag URL is not derived from the main bundle"
fi

# ---------------------------------------------------------------------------
# 3. reduce-motion
# ---------------------------------------------------------------------------
if grep -q 'accessibilityReduceMotion' "$VIEW"; then
    pass "animation branches on accessibilityReduceMotion"
else
    fail "no accessibilityReduceMotion check in the gate view"
fi

# ---------------------------------------------------------------------------
# 4. Poll every 2 seconds and advance on grant
# ---------------------------------------------------------------------------
if grep -q 'FDATwoGrantWatch' "$ASSIST" && grep -q 'FDATwoGrantWatch' "$VIEW"; then
    pass "grant watcher is defined in the probe and driven by the view"
else
    fail "no FDATwoGrantWatch wiring between FDAAssistantProbe.swift and the gate view"
fi
# Read only the body of watchForGrant: the illustration loop also sleeps, so a
# file-wide grep for "2 seconds" would be satisfied by the wrong function.
POLL_BODY="$(python3 -I - "$VIEW" <<'PY2'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
start = src.index("private func watchForGrant")
end = src.index("private func revealManualContinue")
print(src[start:end])
PY2
)"
if grep -q 'FDATwoGrantWatch' <<< "$POLL_BODY" \
   && grep -q 'assistant:' <<< "$POLL_BODY" \
   && grep -q 'recheckFullDiskAccessAndProceed' <<< "$POLL_BODY" \
   && grep -qE 'nanoseconds: 2_000_000_000' <<< "$POLL_BODY"; then
    pass "watchForGrant polls every 2 seconds and advances on grant"
else
    fail "watchForGrant does not poll every 2 seconds and advance on grant"
fi

# ---------------------------------------------------------------------------
# 4b. Redesign contract (Andy, v1 "a bit primitive looking")
# ---------------------------------------------------------------------------
# The retired v1 strings must be gone from every catalogue and the view.
# (recheck_button is NOT retired: the old gate, kept for macOS before 27.3,
# still uses it.)
RETIRED="$(python3 -I - "$RES" <<'PY3'
import glob, json, os, sys
bad = []
for path in sorted(glob.glob(os.path.join(sys.argv[1], "ViewCopy*.json"))):
    gate = json.load(open(path, encoding="utf-8")).get("fda_gate", {})
    for k in ("drag_hint", "fallback_line"):
        if k in gate:
            bad.append(os.path.basename(path) + ":" + k)
print("\n".join(bad))
PY3
)"
if [ -z "$RETIRED" ]; then
    pass "retired v1 strings (drag_hint, fallback_line) are out of every catalogue"
else
    fail "retired v1 strings still present: $RETIRED"
fi
if grep -q 'fda_gate\.recheck_button\|fda_gate\.fallback_line\|fda_gate\.drag_hint' "$VIEW"; then
    fail "gate view still references a retired v1 string"
else
    pass "gate view references no retired v1 string"
fi
# No raw filesystem path is shown to the customer.
if grep -q 'abbreviatingWithTildeInPath\|"path":' "$VIEW"; then
    fail "gate view still builds a raw path for display"
else
    pass "no raw path text on the gate"
fi
# Exactly one primary button; the manual continue is a text link behind a delay.
PRIMARY_N="$(grep -c 'buttonStyle(\.ostlerPrimary)' "$VIEW" || true)"
if [ "$PRIMARY_N" = "1" ]; then
    pass "exactly one primary button on the gate"
else
    fail "gate has $PRIMARY_N primary buttons, expected 1"
fi
if grep -q 'manualContinueDelay: Double = 20' "$VIEW" && grep -q 'fda_drag\.already_on_link' "$VIEW" \
   && grep -q 'showAlreadyOn' "$VIEW"; then
    pass "manual continue is the 'Already switched it on?' link, behind a 20 second delay"
else
    fail "manual continue link / 20 second delay missing"
fi
# The named app is the customer-facing display name, from the bundle.
if grep -q 'CFBundleDisplayName' "$PROBE"; then
    pass "app is named by CFBundleDisplayName"
else
    fail "app name does not come from CFBundleDisplayName"
fi
# The hero is a miniature of the real pane, driven by the pure timeline.
if grep -q 'struct FDAMiniSettings' "$VIEW" && grep -q 'enum FDAHeroTimeline' "$VIEW" \
   && grep -q 'NSCursor\.arrow' "$VIEW"; then
    pass "hero is the System Settings miniature, driven by FDAHeroTimeline"
else
    fail "hero miniature / timeline missing"
fi
# Debug hooks must be inert in Release.
if python3 -I - "$VIEW" <<'PY4'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
i = src.index("enum FDADebug")
body = src[i:src.index("/// Docks the installer window")]
assert "#if DEBUG" in body and "#else" in body and "static var active: Bool { false }" in body
PY4
then
    pass "FDADebug hooks are DEBUG-only and inert in Release"
else
    fail "FDADebug hooks are not confined to DEBUG"
fi

# ---------------------------------------------------------------------------
# 5. Settings deep-link and Reveal in Finder
# ---------------------------------------------------------------------------
if grep -q 'Privacy_AllFiles' "$AUTH"; then
    pass "Settings deep-link still opens Privacy_AllFiles"
else
    fail "Settings deep-link no longer opens Privacy_AllFiles"
fi
if grep -q 'activateFileViewerSelecting' "$VIEW"; then
    pass "Reveal in Finder selects the bundle"
else
    fail "no Reveal in Finder action in the gate view"
fi

# ---------------------------------------------------------------------------
# 6. Which screen: 27.3+ only; earlier macOS keeps the existing gate
# ---------------------------------------------------------------------------
if grep -q 'FDAFlow\.usesDragScreen()' "$CONTENT" && grep -q 'FullDiskAccessGateView()' "$CONTENT" \
   && grep -q 'FullDiskAccessDragGateView()' "$CONTENT"; then
    pass "ContentView picks the drag screen or the existing gate through FDAFlow"
else
    fail "ContentView does not choose between the two gates through FDAFlow.usesDragScreen()"
fi
THRESH_N="$(grep -rn 'OperatingSystemVersion(majorVersion: 27' "${REPO_ROOT}/gui/OstlerInstaller" | grep -v '^.*://' | wc -l | tr -d ' ')"
if [ "$THRESH_N" = "1" ] && grep -q 'dragScreenMinimum = OperatingSystemVersion(majorVersion: 27, minorVersion: 3' "$FLOW"; then
    pass "the 27.3 threshold is written in exactly one place (FDAFlow.dragScreenMinimum)"
else
    fail "the 27.3 threshold is not a single constant (found $THRESH_N)"
fi
if python3 -I - "$FLOW" <<'PY5'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
i = src.index('environment["OSTLER_DEBUG_MACOS_VERSION"]')
before = src[:i]
assert before.rstrip().endswith("#if DEBUG") or "#if DEBUG" in before[-80:], "override not under #if DEBUG"
assert src.index("#endif", i) < src.index("return real", i)
PY5
then
    pass "the macOS-version override is DEBUG-only"
else
    fail "the macOS-version override is not confined to DEBUG"
fi
# The existing gate must not know about the new screen.
if grep -qE 'FDAFlow|FDAHandoff|FDAHeroTimeline|FDAMiniSettings|FDADebug|FDATwoGrantWatch|fda_drag' "$OLDVIEW"; then
    fail "the existing gate references the new drag screen; it must stay as it was"
else
    pass "the existing gate (macOS before 27.3) references nothing from the drag screen"
fi
if grep -q 'fda_gate\.recheck_button' "$OLDVIEW"; then
    pass "the existing gate still uses its own recheck button string"
else
    fail "the existing gate lost its recheck button string"
fi
RECHECK_MISSING="$(python3 -I - "$RES" <<'PY6'
import glob, json, os, sys
print(" ".join(os.path.basename(p) for p in sorted(glob.glob(os.path.join(sys.argv[1], "ViewCopy*.json")))
      if "recheck_button" not in json.load(open(p, encoding="utf-8")).get("fda_gate", {})))
PY6
)"
if [ -z "$RECHECK_MISSING" ]; then
    pass "fda_gate.recheck_button is in every catalogue (the existing gate needs it)"
else
    fail "fda_gate.recheck_button missing from: $RECHECK_MISSING"
fi

# ---------------------------------------------------------------------------
# 7. Two grants: Ostler (probed AS Ostler) and Ostler Installer
# ---------------------------------------------------------------------------
if grep -q 'assistantTile' "$VIEW" && grep -q 'installerTile' "$VIEW" \
   && grep -q 'FDAHandoff\.assistantBundleURL' "$VIEW" && grep -q 'ostler-payload/assistant-agent/OstlerAssistant\.app' "$PROBE"; then
    pass "the screen has an Ostler tile (the bundled OstlerAssistant.app) and an Ostler Installer tile"
else
    fail "the screen does not carry both the Ostler and the Ostler Installer tiles"
fi
if grep -q '"/usr/bin/open"' "$ASSIST" && grep -q '"--stdout"' "$ASSIST" && grep -q 'run-source", "imessage", "--self-test"' "$ASSIST"; then
    pass "Ostler is probed through LaunchServices (open --stdout) running its own self-test"
else
    fail "Ostler's grant is not probed as Ostler through LaunchServices"
fi
echo
if [ "$FAILS" -gt 0 ]; then
    echo "RESULT: ${FAILS} failing group(s)"
    exit 1
fi
echo "RESULT: all groups pass"
