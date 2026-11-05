#!/usr/bin/env python3
"""F&F tester 2026-11-05, item 5: recovery key screen felt frozen.

Root cause 1: Continue is `.disabled(!savedConfirmed)` but its ButtonStyle never
read isEnabled, so it drew fully live while doing nothing.
Root cause 2: the confirm checkbox sat at the bottom of an unbounded VStack in a
fixed 880x620 window; any growth (localised copy) pushed it out of view.

Asserts SOURCE STRUCTURE (same shape as the consent-button test):
  a. the checkbox Toggle and the Continue button are OUTSIDE the ScrollView;
  b. the primary style reads isEnabled and dims.
Usage: test_...py [repo_root]
"""
import pathlib, re, sys
REPO = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1]
rk = REPO / "gui/OstlerInstaller/Views/RecoveryKeyView.swift"
th = REPO / "gui/OstlerInstaller/Theme/OstlerTheme.swift"
for f in (rk, th):
    if not f.is_file():
        print(f"CANNOT-RUN: {f} missing"); sys.exit(2)
fail = 0
def bad(m):
    global fail; fail += 1; print("  [FAIL]", m)
def ok(m): print("  [PASS]", m)

src = rk.read_text()
i = src.find("ScrollView {")
if i < 0:
    bad("RecoveryKeyView has no ScrollView")
else:
    depth, j = 0, src.index("{", i)
    k = j
    while True:
        c = src[k]
        depth += c == "{"; depth -= c == "}"
        if depth == 0: break
        k += 1
    inside, after = src[j:k], src[k:]
    for needle, name in (("Toggle(isOn: $savedConfirmed)", "checkbox"), ("continue_button", "Continue")):
        if needle in inside: bad(f"{name} is INSIDE the ScrollView")
        elif needle in after: ok(f"{name} is pinned outside the ScrollView")
        else: bad(f"{name} not found")

t = th.read_text()
m = re.search(r"struct OstlerPrimaryButtonStyle.*?(?=/// Ghost)", t, re.S)
blk = m.group(0) if m else ""
if "isEnabled" in blk and "opacity" in blk: ok("primary button style reads isEnabled and dims")
else: bad("primary button style ignores isEnabled")
print(f"fail={fail}"); sys.exit(1 if fail else 0)
