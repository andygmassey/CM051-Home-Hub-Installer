#!/usr/bin/env python3
"""The end-of-install screen must not send a customer to a wiki that is not serving.

WHAT WENT WRONG (#944). `InstallCompleteView` rendered "Open your Wiki" and a
sign-in hint UNCONDITIONALLY. install.sh already knew better: its "Next steps"
banner prints the wiki URL only when WIKI_FIRST_COMPILE_OK is true, and prints
"not yet available" otherwise. The GUI carried neither guard, so on a box where
the first compile had not finished, the terminal went quiet and the GUI sent
the customer to a page that would not load, with a password hint for a server
that was not listening. The richer surface was the more misleading one.

WHY A SOURCE-LEVEL GUARD. The defect is a rendering decision, and the thing
that must be true is a property of the view's structure: the button is gated,
the hint lives only under the serving branch, and the probe does not mistake a
protected wiki for a dead one. A unit test that calls a function would not see
any of those. This is the same shape as the consent-button guard, which is run
by the same job.

WHAT IT DOES NOT CLAIM. This does not prove a customer saw the right thing on a
real box; that is a walk, not a test. It proves the only three ways the fix can
be silently undone in source are refused.
"""
import json
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
VIEW = REPO / "gui/OstlerInstaller/Views/InstallCompleteView.swift"
COPY = REPO / "gui/OstlerInstaller/Resources/ViewCopy.json"

failures = []
checks = 0


def check(name, ok, detail=""):
    global checks
    checks += 1
    if ok:
        print(f"  PASS  {name}")
    else:
        print(f"  FAIL  {name}" + (f"\n        {detail}" if detail else ""))
        failures.append(name)


def arm_disabled(src):
    """The wiki button carries a .disabled() keyed on the reachability state."""
    # Anchor on the button, then look only at what follows it up to the next
    # Button( or the end of the HStack. Searching the whole file would pass on
    # a .disabled() belonging to a different control entirely.
    i = src.find('Button(action: openWiki)')
    if i < 0:
        return False, "no Button(action: openWiki) in the view at all"
    j = src.find('Button(action:', i + 10)
    region = src[i: j if j > 0 else i + 3000]
    m = re.search(r'\.disabled\(\s*wikiReachability\s*!=\s*\.serving\s*\)', region)
    return bool(m), "the wiki button has no .disabled() keyed on wikiReachability"


def arm_three_states(src):
    """The reachability type has three cases. Two would read the first render as a failure."""
    m = re.search(r'private enum WikiReachability\s*\{([^}]*)\}', src)
    if not m:
        return False, "no WikiReachability enum"
    cases = re.findall(r'\bcase\s+([a-zA-Z, ]+)', m.group(1))
    names = {n.strip() for grp in cases for n in grp.split(",") if n.strip()}
    return names == {"checking", "serving", "notServing"}, f"cases found: {sorted(names)}"


def arm_hint_is_gated(src):
    """The sign-in hint appears ONLY under the serving branch."""
    hint = 'install_complete.wiki_signin_hint'
    if src.count(hint) != 1:
        return False, f"expected exactly 1 reference to the hint, found {src.count(hint)}"
    k = src.find(hint)
    sw = src.rfind('switch wikiReachability', 0, k)
    if sw < 0:
        return False, "the sign-in hint is not inside a switch on wikiReachability"
    serving = src.find('case .serving:', sw)
    nxt = src.find('case .', serving + 10)
    return serving < k < nxt, "the hint is not inside the .serving arm"


def arm_probe_accepts_401(src):
    """Any HTTP answer means serving. Requiring 200 would call a protected wiki dead."""
    m = re.search(r'private func probeWikiReachability\(\) async \{(.*?)\n    \}', src, re.S)
    if not m:
        return False, "no probeWikiReachability function"
    body = m.group(1)
    if re.search(r'statusCode\s*==\s*200\b', body) and 'statusCode == 401' not in body:
        return False, ("the probe requires 200, so a wiki correctly behind auth_basic "
                       "reads as dead. That is the #1594 inversion, which suppressed "
                       "the banner carrying the customer's own password.")
    if 'response is HTTPURLResponse' not in body and 'as? HTTPURLResponse' not in body:
        return False, "the probe does not test for an HTTP response at all"
    return True, ""


def arm_copy_keys_exist(src):
    """Every install_complete key the view asks for exists. A missing key renders
    as the raw dotted string to the customer, because ViewCopy.string(for:)
    returns the key itself when the lookup misses."""
    catalogue = json.loads(COPY.read_text())["install_complete"]
    asked = set(re.findall(r'install_complete\.([a-z0-9_]+)', src))
    missing = sorted(asked - set(catalogue))
    return not missing, f"view asks for keys absent from ViewCopy.json: {missing}"


def main():
    if not VIEW.exists():
        print("CANNOT RUN: InstallCompleteView.swift not found. That is NOT a pass.")
        return 2
    if not COPY.exists():
        print("CANNOT RUN: ViewCopy.json not found. That is NOT a pass.")
        return 2
    src = VIEW.read_text()

    # ---------------- SELF-TEST FIRST ----------------
    # Each arm is run against a specimen it MUST reject. An arm that cannot go
    # red would report a clean sheet for a broken view, and there would be no
    # way to tell that from a genuine pass.
    print("self-test: every arm must reject its own specimen")
    specimens = [
        ("arm_disabled", arm_disabled, src.replace('.disabled(wikiReachability != .serving)', '')),
        ("arm_three_states", arm_three_states,
         src.replace('private enum WikiReachability { case checking, serving, notServing }',
                     'private enum WikiReachability { case serving, notServing }')),
        ("arm_hint_is_gated", arm_hint_is_gated,
         src.replace('switch wikiReachability {', 'if true {')),
        ("arm_probe_accepts_401", arm_probe_accepts_401,
         src.replace('if response is HTTPURLResponse {',
                     'if let h = response as? HTTPURLResponse, h.statusCode == 200 {')),
        ("arm_copy_keys_exist", arm_copy_keys_exist,
         src.replace('install_complete.wiki_not_serving_body',
                     'install_complete.wiki_not_serving_body_TYPO')),
    ]
    blind = []
    for name, fn, mutant in specimens:
        ok, _ = fn(mutant)
        if ok:
            blind.append(name)
        print(f"  {'ok  ' if not ok else 'BLIND'} {name} rejects its specimen")
    if blind:
        print(f"\nSELF-TEST FAILED: {blind} passed a specimen they must reject.")
        print("Every PASS below would be meaningless. Refusing.")
        return 1

    # ---------------- THE REAL ARMS ----------------
    print("\nthe view as committed:")
    for name, fn in [("the wiki button is disabled unless the wiki is serving", arm_disabled),
                     ("reachability has three states, not two", arm_three_states),
                     ("the sign-in hint appears only under a serving wiki", arm_hint_is_gated),
                     ("a wiki behind auth_basic counts as serving, not dead", arm_probe_accepts_401),
                     ("every copy key the view asks for exists", arm_copy_keys_exist)]:
        ok, detail = fn(src)
        check(name, ok, detail)

    print(f"\n{checks - len(failures)} passed, {len(failures)} failed, denominator {checks}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
