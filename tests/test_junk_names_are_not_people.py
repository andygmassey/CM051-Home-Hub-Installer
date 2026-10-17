#!/usr/bin/env python3
"""SHAPE 3 (Andy's #30 console walk): a notification SUBJECT and gibberish
strings must not be accepted as a person's name.

Exercises the SHIPPED predicate vendor/cm021/src/cli.py
``looks_like_subject_or_sender_id`` and the ``clean_display_name`` helper --
the same module the email tick and the reclassify-subject-names migration use,
so a pass here is a pass on the code that actually runs.

Measured junk shapes (People nodes seen on the walk box, re-made synthetic):
  * ``~~\"Unusual sign-in on your iCloud.`` -- an Apple security-notification
    SUBJECT that became a Person, with escaping junk (``~~`` and a
    backslash-quote) leaked into the display name. The junk sat before the
    first word and shielded the sentence-opener arm; now the artefact is
    itself a refusal signal and the cleaned name is what the arms see.
  * ``07alex Qzr5531tb``, ``4410293387 Kjv3 Wq7b Acme Corp``,
    ``58mxtb Pvo2217sd``, ``92jone Twkq8806ycm`` -- gibberish: a letter+digit
    mash inside one word is an extraction artefact, never a human-name token.
    These keep the walk's shapes; the walk's own strings are not reproduced.

Synthetic data only (PUBLIC repo).
EXIT  0 all pass   1 a check failed   2 CANNOT-RUN
"""
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PKG = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / "vendor" / "cm021"

sys.path.insert(0, str(PKG))
try:
    from src import cli  # the shipped module
except Exception as exc:  # noqa: BLE001
    print(f"CANNOT-RUN: could not import {PKG}/src/cli.py: {exc}", file=sys.stderr)
    sys.exit(2)

fails = 0


def check(label, ok):
    global fails
    print(("  ok    " if ok else "  FAIL  ") + label)
    if not ok:
        fails += 1


# The exact junk nodes from the walk. Each MUST be refused as not-a-name.
JUNK = [
    '~~\\"Unusual sign-in on your iCloud.',
    "07alex Qzr5531tb",
    "4410293387 Kjv3 Wq7b Acme Corp",
    "58mxtb Pvo2217sd",
    "92jone Twkq8806ycm",
]

# Human-shaped names (incl. accents, hyphens, apostrophes, a three-part name,
# a 2-char surname, a suffix) MUST be kept -- the false-positive control.
# Synthetic, from the approved cast (PUBLIC repo).
REAL = [
    "Samuel John Coe",
    "José García",
    "Raj Patel",
    "Mary-Jane O'Brien",
    "Li Wei",
    "Jane Doe",
    "Robert Smith Jr.",
]

# Pre-existing positives must still fire (no regression of the #2544 behaviour).
STILL_REFUSED = ["Your Account Team", "#OTP2FA", "Jane Doe via ExampleSign"]

print("JUNK must be refused (looks_like_subject_or_sender_id -> True):")
for name in JUNK:
    check(repr(name), cli.looks_like_subject_or_sender_id(name) is True)

print("REAL names must be kept (-> False):")
for name in REAL:
    check(repr(name), cli.looks_like_subject_or_sender_id(name) is False)

print("Pre-existing positives still refused:")
for name in STILL_REFUSED:
    check(repr(name), cli.looks_like_subject_or_sender_id(name) is True)

print("clean_display_name strips escaping artefacts, leaves real names:")
check(
    "strips leading ~~ and backslash-quote",
    cli.clean_display_name('~~\\"Unusual sign-in on your iCloud.')
    == "Unusual sign-in on your iCloud.",
)
check("a clean name is unchanged", cli.clean_display_name("Jane Doe") == "Jane Doe")
check(
    "accented name is unchanged",
    cli.clean_display_name("José García") == "José García",
)

if fails:
    print(f"\nFAIL: {fails} check(s) failed", file=sys.stderr)
    sys.exit(1)
print("\nOK: all checks passed")
sys.exit(0)
