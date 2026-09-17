#!/usr/bin/env python3
"""Customer copy says the Ostler app on your iPhone, never "Companion".

PROVED-RED-BY: this file, mutation 1 and mutation 2.

THE RULE IS LOCKED and it is not a style preference. "Companion" is an internal
project word (CM031 was named "PWG iOS Companion"); to a customer it describes a
thing they cannot buy, cannot find in the App Store under that name, and did not
ask for. The rule is that customer copy names the app, not the repository.

MEASURED ON origin/main 2026-09-18, CM051 #1008 limb 3: the strings file the
installer prints carried the word TEN times, and NINE of them were live customer
strings rather than comments:

    :114 Subscribe via the iOS Companion app.
    :155 iOS Companion endpoints will be limited.
    :169 iOS Companion will only work on your home Wi-Fi
    :332 Your iOS Companion will work on your home Wi-Fi
    :490 Subscribe via the iOS Companion app to extend
    :581 iOS Companion will use it on first launch.
    :751 Open the iOS Companion app onc[e]
    :772 iOS Companion endpoints will be limited until
    :905 iOS Companion may not pick it up

Two of those are on the subscription path, which is copy a person reads while
deciding to pay.

AND NOTHING WAS CHECKING IT. A search for a guard over this word found tests
about other subjects. Fixed-and-ungated is the state that lets a rule come back
quietly, and a locked rule with no gate is a preference.

WHAT THIS ASSERTS, and the scope is deliberate:

  * VALUES ONLY. A comment may say "iOS Companion" -- it is history, it names a
    repo, and no customer reads it. Asserting over whole lines would fail on
    provenance notes and get the gate switched off.
  * The strings file is the subject because it IS customer copy by construction:
    every value in it is printed to a person.

British English throughout; " -- " not em-dashes.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
STRINGS = ROOT / "install.sh.strings.en-GB.sh"

BANNED = "companion"
PASS = FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"  ok    {msg}")


def bad(msg, detail=""):
    global FAIL
    FAIL += 1
    print(f"  FAIL  {msg}")
    if detail:
        for line in str(detail).splitlines():
            print(f"        | {line}")


_ASSIGN = re.compile(r'^(?P<name>MSG_[A-Z0-9_]+)="(?P<value>(?:[^"\\]|\\.)*)"')


def offenders(text):
    """Every MSG_* whose VALUE carries the banned word. Comments are not values."""
    out = []
    for i, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        m = _ASSIGN.match(line.strip())
        if not m:
            continue
        if BANNED in m.group("value").lower():
            out.append(f"{i}: {m.group('name')}")
    return out


def values(text):
    return [m.group("value") for m in
            (_ASSIGN.match(l.strip()) for l in text.splitlines()
             if not l.lstrip().startswith("#")) if m]


def main():
    print("test_customer_copy_says_ios_app_not_companion")
    if not STRINGS.is_file():
        print(f"CANNOT-RUN: no strings file at {STRINGS}", file=sys.stderr)
        return 2
    src = STRINGS.read_text(encoding="utf-8")

    # ── 0. DENOMINATOR. A reader that parses no values reports a clean zero
    #       for a file it never understood, which is the exact shape of a
    #       vacuous pass.
    vals = values(src)
    if len(vals) > 200:
        ok(f"(0) DENOMINATOR: {len(vals)} customer strings parsed, so a clean "
           "result below is about the copy and not about a failed parse")
    else:
        bad(f"(0) only {len(vals)} strings parsed from the file. The reader is "
            "broken and every assertion below would be vacuous")
        return 1

    found = offenders(src)
    if not found:
        ok("(1) no customer string names the app 'Companion'")
    else:
        bad(f"(1) {len(found)} customer string(s) still say 'Companion'", "\n".join(found))

    # ── 2. COMMENTS ARE OUT OF SCOPE AND THAT IS DELIBERATE, so prove the
    #       reader really does ignore them rather than there happening to be
    #       none. Without this, assertion (1) could be passing because the
    #       parser silently drops everything.
    probe = src + '\n# a comment mentioning the iOS Companion should not fail this\n'
    if not offenders(probe):
        ok("(2) a COMMENT naming it does not fail the gate, so history and repo "
           "names stay writable")
    else:
        bad("(2) a comment tripped the gate. It will be switched off the first "
            "time someone writes a provenance note")

    # ===================================================================
    # MUTATION. The gate must catch both the obvious and the sneaky form.
    # ===================================================================
    print()
    print("  -- mutation --")

    m1 = src.replace('MSG_INFO_TAILSCALE_SKIPPED="Tailscale skipped',
                     'MSG_INFO_TAILSCALE_SKIPPED="Your iOS Companion. Tailscale skipped', 1)
    if m1 == src:
        bad("(M1) the mutant could not be built", "re-point this test at a real MSG_ line")
    else:
        if offenders(m1):
            ok("(M1) RED ON A REINTRODUCTION: putting the word back into a real "
               "customer string is caught")
        else:
            bad("(M1) MUTANT SURVIVED: the word was reintroduced and the gate stayed silent")

    m2 = src.replace('MSG_OK_TAILSCALE_ENV_PERSISTED="Tailscale IP saved',
                     'MSG_OK_TAILSCALE_ENV_PERSISTED="companion app: Tailscale IP saved', 1)
    if m2 == src:
        bad("(M2) the mutant could not be built", "re-point this test at a real MSG_ line")
    else:
        if offenders(m2):
            ok("(M2) RED ON THE LOWERCASE FORM TOO: the match is case-insensitive, "
               "so 'companion' does not slip past a capital-C check")
        else:
            bad("(M2) MUTANT SURVIVED: a lowercase 'companion' was not caught")

    print()
    print(f"=== {PASS} passed / {FAIL} failed ===")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
