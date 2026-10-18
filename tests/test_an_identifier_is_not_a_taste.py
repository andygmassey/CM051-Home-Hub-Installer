#!/usr/bin/env python3
"""CM051 #959. THE REFUSAL THAT STOPS NONSENSE REACHING THE FRONT PAGE HAD NO GUARD.

WHAT HAPPENED, recorded in interest_profile.py's own comment at :394. The
0.28 confidence floor was unreachable by every source that ships, so the
front page read "Ostler has spotted 0 interests". Lowering it to 0.10 made
the page render four interest cards on a real v1.0.100 box, and every one was
a contact identifier:

    [interest] c…@icloud.com   "One of the things Ostler reckons you're into."
    [interest] +85 … 77
    [interest] +85 … 67
    [interest] +44 … 07

The file says it plainly: that is worse than the empty page it replaced. It
is nonsense, and it is nonsense built out of the customer's own contacts. The
floor had been masking it.

WHY THE EXISTING SCREENS COULD NOT CATCH IT, and this is the part worth
keeping: subject_privacy() CAPS THE PRIVACY LEVEL of a personal-looking
subject and never rejects the row, so the interest still reached the page
wearing an L2 badge. The noise table applies score PENALTIES, and a penalty
only REORDERS. Neither is a refusal, and a refusal is what an identifier
needs.

WHAT WAS MISSING. subject_is_identifier is defined at :429 and CALLED at
:900, so it is wired and it works. But measured 2026-09-18, NOTHING NAMED IT:
grep over tests/, scripts/ and .github/workflows/ returns 0 files, against a
CONTROL of 7 files naming interest_profile, so the search reaches and the
zero is real absence.

So the call at :900 could be removed, or the regex narrowed, and every gate
in the repo would stay green while the customer's front page filled with
their own phone numbers again. That is the whole reason this file exists.

THE SUBJECTS BELOW ARE SYNTHETIC. The four the box rendered were real contact
identifiers belonging to a real person and they are not reproduced here. The
shapes are what matter, and shapes are all that is asserted.
"""
import importlib.util
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET = os.path.join(ROOT, "vendor", "cm059_editor", "compiler", "interest_profile.py")


def load():
    if not os.path.isfile(TARGET):
        print("CANNOT-RUN: %s is not present, so the refusal cannot be driven."
              % os.path.relpath(TARGET, ROOT))
        sys.exit(2)
    spec = importlib.util.spec_from_file_location("interest_profile", TARGET)
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
    except Exception as exc:
        print("CANNOT-RUN: interest_profile would not import (%s: %s)."
              % (type(exc).__name__, exc))
        sys.exit(2)
    if not hasattr(mod, "subject_is_identifier"):
        print("CANNOT-RUN: subject_is_identifier is gone from interest_profile."
              " If it was renamed, re-point this test; if it was DELETED, that"
              " is the defect this test exists for and it must not be silent.")
        sys.exit(2)
    return mod


def main():
    mod = load()
    src = open(TARGET, encoding="utf-8").read()
    print("EXAMINED: %s, %d lines" % (os.path.relpath(TARGET, ROOT),
                                      src.count("\n") + 1))

    passed = failed = 0

    def check(desc, got, want):
        nonlocal passed, failed
        if got == want:
            passed += 1
            print("  ok    %s" % desc)
        else:
            failed += 1
            print("  FAIL  %s (got %r, expected %r)" % (desc, got, want))

    # ARM 1. The shapes that appeared on the box. Synthetic values, real shapes.
    #
    # 🔴 THE NUMBERS ARE COMPOSED FROM PARTS AT RUNTIME, AND THAT IS NOT
    # DECORATION. bin/operator-pii-scan.sh matches on SHAPE rather than on a
    # list of known values, so a wholly synthetic number written as a literal
    # trips it exactly as a real one would, and it blocked this commit. Its own
    # printed remedy is to compose the literal from parts, which is what the
    # joins below do. The alternative it offers, moving the fixture under an
    # excluded path, would put the cases somewhere the guard cannot see them,
    # and a fixture the PII scanner cannot read is how a real number gets in.
    #
    # Weakening the pattern was never an option and neither was --no-verify.
    def _num(*parts):
        return "".join(parts)

    for subject in ("someone@example.com",
                    _num("+", "85", " ", "1234", " ", "5677"),
                    _num("+", "44", " ", "7700", " ", "900107"),
                    _num("+", "1", " (", "555", ") ", "010", "-", "9999"),
                    _num("077", "00", "900107")):
        check("refused: %r" % subject, mod.subject_is_identifier(subject), True)

    # ARM 2. MUST-MISS. A refusal that refuses everything is not a refusal, and
    # it would empty the page a second way.
    print("\nARM 2: MUST-MISS, real interests are NOT refused")
    for subject in ("woodworking",
                    "espresso",
                    "Japanese joinery",
                    "thoughts on someone@example.com",
                    "call me on 7"):  # one digit, so the no-letters rule must not fire
        check("kept: %r" % subject, mod.subject_is_identifier(subject), False)

    # ARM 3. Empty input belongs to the emptiness checks, not here. The
    # docstring says so, so it is asserted rather than assumed.
    print("\nARM 3: empty input is left to the existing emptiness checks")
    for subject in ("", "   ", None):
        check("not refused: %r" % subject, mod.subject_is_identifier(subject), False)

    # ARM 3b. THE TWO PATHS MUST BE PINNED SEPARATELY, and my first version of
    # this test could not tell them apart.
    #
    # subject_is_identifier has TWO independent refusals: the full-identifier
    # regex, and "a taste has letters in it" for the MASKED form. The masked
    # form is what actually reaches the page: the writer upstream stores the
    # subject ALREADY REDACTED, so the box rendered '+85 … 77', a country code,
    # a U+2026 ellipsis and two digits. The regex needs 8+ digits and matched
    # none of them, so the FIRST version of that screen removed the one email
    # address and left every phone number on the page.
    #
    # I found this by MUTATING the regex and watching the test stay green:
    # every phone case I had chosen was also caught by the no-letters rule, so
    # either path alone kept the suite passing and a removal of either would
    # have shipped silently. These two cases discriminate.
    print("\nARM 3b: each refusal path is pinned by a case only it can catch")
    check("regex-only: an email HAS letters, so only the regex can refuse it",
          mod.subject_is_identifier("someone@example.com"), True)
    masked = "".join(("+", "85", " \u2026 ", "77"))
    check("letters-only: a MASKED number the regex cannot match, refused by"
          " the no-alphabetic rule",
          mod.subject_is_identifier(masked), True)
    check("CONTROL: the masked form really is invisible to the regex",
          bool(mod._IDENTIFIER_SUBJECT_RE.match(masked)), False)
    check("CONTROL: the email really does have letters, so the no-alphabetic"
          " rule cannot be what catches it",
          any(c.isalpha() for c in "someone@example.com"), True)

    # ARM 4. THE REFUSAL MUST BE CALLED. A correct predicate nobody invokes is
    # the failure mode this repo keeps hitting, and it is the one that put the
    # identifiers on the page in the first place.
    print("\nARM 4: the refusal is REACHED, not merely defined")
    calls = len(re.findall(r"^\s*if\s+subject_is_identifier\(", src, re.M))
    check("subject_is_identifier is called from at least one guard site",
          calls >= 1, True)
    defs = len(re.findall(r"^def\s+subject_is_identifier\(", src, re.M))
    check("CONTROL: it is defined exactly once, so the count above is not"
          " matching the definition", defs, 1)

    # ARM 5. A PENALTY IS NOT A REFUSAL. The file's own comment says the noise
    # table only reorders and subject_privacy only caps the level. If either
    # were the guard, an identifier would still reach the page.
    print("\nARM 5: the guard is a REFUSAL, not a penalty or a privacy cap")
    check("subject_is_identifier returns a bool, not a score",
          isinstance(mod.subject_is_identifier("someone@example.com"), bool), True)

    print("\n=== %d passed / %d failed ===" % (passed, failed))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
