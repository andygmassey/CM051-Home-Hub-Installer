#!/usr/bin/env python3
"""The Homebrew refusal is shown to the customer, not only logged.

Same-shape sweep 2026-11-14, Archie's review of #3508 (a): a refused admin
grant that only logs is not a refusal. This test reads the Swift source (it
cannot run XCTest on this host) and proves the chain:

  1. AuthorizationHelper stores the refusal text it returns (lastRefusal);
  2. InstallerCoordinator copies it into the published adminRefusal;
  3. ContentView's retry gate passes adminRefusal to AdminAccessRequiredView,
     which renders it in retry mode as a Text with an accessibility id;
  4. the text itself names no account and says what to do.
Also checks the XCTest that asserts the same chain exists (for a Mac run).
RED on origin/main: none of these exist. Synthetic only. Run bare.
"""
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GUI = REPO / "gui" / "OstlerInstaller"
FAILS = []


def check(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


auth = (GUI / "Auth" / "AuthorizationHelper.swift").read_text(encoding="utf-8")
coord = (GUI / "InstallerCoordinator.swift").read_text(encoding="utf-8")
content = (GUI / "Views" / "ContentView.swift").read_text(encoding="utf-8")
tests = (REPO / "gui" / "OstlerInstallerTests" / "AdminAuthorizationGateTests.swift").read_text(encoding="utf-8")

check("private(set) var lastRefusal: String?" in auth, "1a helper keeps the refusal text (lastRefusal)")
check(re.search(r"lastRefusal = refusal", auth) is not None, "1b helper stores the refusal it returns")
check("adminRefusal = await AuthorizationHelper.shared.lastRefusal" in coord,
      "2a coordinator copies the refusal into adminRefusal on a refused grant")
check("@Published var adminRefusal: String? = nil" in coord, "2b adminRefusal is published to the views")
check("AdminAccessRequiredView(mode: .retry, refusal: coordinator.adminRefusal)" in content,
      "3a the retry gate passes adminRefusal to the view")
check("if mode == .retry, let refusal {" in content and "Text(refusal)" in content,
      "3b the view renders the refusal text in retry mode")
check('accessibilityIdentifier("adminRefusalText")' in content, "3c the rendered text has an accessibility id")

fn = re.search(r"internal func sharedHomebrewRefusal\(.*?\n\}", auth, re.S)
text = "".join(re.findall(r'"([^"]*)"', fn.group(0))) if fn else ""
check("belongs to another account" in text, "4a the surfaced text says whose it is")
check("Install Ostler from that account" in text and "ask that account" in text,
      "4b the surfaced text says what to do")
check(not re.search(r"\b(502|501|uid)\b", text), "4c the surfaced text prints no uid")

check("func testRefusalReachesTheCoordinatorAndTheScreen" in tests or
      "testForeignOwnedHomebrewIsRefusedWithoutAChown" in tests,
      "5 the XCTest for the refusal exists (runs on a Mac, CANNOT-RUN here)")

if FAILS:
    print(f"\n{len(FAILS)} FAILED")
    sys.exit(1)
print("\nAll refusal-reaches-the-screen checks passed.")
