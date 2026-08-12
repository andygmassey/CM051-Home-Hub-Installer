"""Given-name variants: Andy IS Andrew.

Andy, 2026-08-08: "same surname, and two firstnames where one is a well-known
nickname/shortened version of the other should ALWAYS pass to next merge
condition."

WHY WORD-OVERLAP WAS NOT ENOUGH
===============================
The clustering in identifier_quality only rescued "Andy Quillon" / "Andrew
Quillon" because the SURNAME collided. It still split:

    Andy          vs  Andrew Quillon     -> no shared word -> two people
    Bob Smith     vs  Robert Smith      -> rescued (smith), by luck
    Andy Quillon   vs  Andrew M          -> split

A shortened given name is the single most common way one person appears twice
in a contact graph, so leaving it to a surname coincidence is not good enough.

WHY THIS IS NOT THE ENGLISH-ONLY TRAP
=====================================
I rejected a nickname table earlier on the grounds that it would be English-only
and would fail the productisation rule. That reasoning was half right: a table
as the ONLY defence would be. As a LAYER on top of the language-neutral rules
it is additive -- a locale that ships no table loses nothing and still gets
word-overlap, machine-label filtering and the single-word-alias rule.

The table is data, not code, and is locale-selected the way CM044 does it:
    OSTLER_NAME_VARIANTS_FILE=/path/to/variants.<locale>.json
Each line is one equivalence class. Anything absent simply falls through.

SAFETY
======
This only ever makes the guard MORE willing to treat two records as one
person. It cannot cause a split -- the failure it prevents. Two genuinely
different people called Andrew and Andy with the same surname were already
indistinguishable to every other rule here; that is the dedupe layer's job,
not this one's.
"""
from __future__ import annotations

import json
import os
from typing import Dict, List, Set

# English defaults. Each tuple is ONE person's possible given names.
# Deliberately conservative: only widely-understood short forms, no guesses.
_DEFAULT_CLASSES: List[List[str]] = [
    # ONE FULL NAME PER CLASS, plus only its short forms.
    #
    # A NEAR-IDENTICAL SPELLING IS A DIFFERENT NAME, not a variant of one.
    # This table originally filed eight such pairs as a single name each, one
    # doubled consonant or one vowel apart. The worst of them put a man's name
    # and a woman's name in the same class. This table feeds a MERGE decision,
    # so fusing two full names here merges two humans.
    #
    # A near-identical spelling is a DIFFERENT NAME. Not merging costs almost
    # nothing -- two records for one person still union on their surname -- and
    # wrongly merging corrupts who the customer knows.
    ["andrew", "andy", "drew"],
    ["anthony", "tony"],
    ["benjamin", "benji"],
    ["catherine", "cathy"],
    ["katherine", "katie"],
    ["kathryn"],
    ["kathleen"],
    ["charles", "charlie", "chuck"],
    ["christopher", "chris"],
    ["daniel", "danny"],
    ["david", "dave"],
    ["deborah", "debbie"],
    ["edward", "eddie", "ned"],
    ["theodore", "theo"],
    ["elizabeth", "lizzie", "betty", "libby"],
    ["frederick", "freddie"],
    ["geoffrey", "geoff"],
    ["jeffrey", "jeff"],
    ["gregory", "greg"],
    ["james", "jimmy", "jamie"],
    ["jennifer", "jenny"],
    ["john", "johnny"],
    ["jonathan", "jonny"],
    ["joseph", "joey"],
    ["kenneth", "kenny"],
    ["lawrence", "larry"],
    ["laurence", "laurie"],
    ["margaret", "maggie", "peggy"],
    ["matthew", "matty"],
    ["michael", "mike", "micky"],
    ["nicholas", "nicky"],
    ["patricia", "patty", "tricia", "trish"],
    ["patrick", "paddy"],
    ["peter", "pete"],
    ["philip", "phil"],
    ["phillip"],
    ["rebecca", "becca", "becky"],
    ["richard", "ricky", "richie"],
    ["robert", "bobby", "robbie"],
    ["ronald", "ronnie"],
    ["samuel", "sammy"],
    ["stephen", "steve"],
    ["steven", "stevie"],
    ["susan", "susie"],
    ["thomas", "tommy"],
    ["timothy", "timmy"],
    ["victoria", "vicky", "tori"],
    ["william", "billy", "willie"],
    # ONE VARIANT PAIR REMOVED HERE, and it is a real (small) functional loss.
    #
    # This is a generic English given-name dictionary: the neighbouring rows are
    # ["susan", "susie"], ["thomas", "tommy"]. One row happened to collide with a
    # name in the operator PII inventory, so the shipped-payload guard blocks any
    # commit carrying it -- it cannot tell a dictionary from a leak.
    #
    # Removed rather than bypassed, because "no operator PII in the shipped
    # payload" is non-negotiable and --no-verify is not an option. The cost is
    # that this one short form no longer canonicalises to its full name; the
    # ["allison", "allie"] row below is unaffected, as is every other row.
    #
    # THE ALTERNATIVE IS A SCOPING DECISION, NOT A CODE CHANGE: if the guard
    # learns that a generic name dictionary is not a leak, this row comes
    # straight back. Tracked on HR015 #335. Restoring it is a one-line revert.
    ["allison", "allie"],
    ["alexander", "xander"],
    ["alexandra", "sasha"],
    ["nathaniel"],
    ["nathan", "nate"],
    ["zachary", "zach"],
]

# Short forms claimed by MORE THAN ONE full name are AMBIGUOUS and must not
# canonicalise: "Alex" could be Alexander or Alexandra, "Pat" either Patricia
# or Patrick, "Ted" Edward or Theodore, "Sam" Samuel or Samantha. Forcing a
# canonical would pick one at random and merge on a coin flip. Left alone, they
# still union on a shared surname, which is the safe path.
_AMBIGUOUS = {
    "alex", "pat", "ted", "sam", "chris", "jo", "joe", "nat", "bob", "rob",
    "kat", "kate", "cath", "kathy", "cathy", "liz", "beth", "eliza", "vicki",
    "will", "bill", "dan", "matt", "nick", "rick", "rich", "dick", "tom",
    "tim", "steve", "phil", "ron", "ken", "jen", "jim", "ben", "fred", "ed",
    "sandy", "lex", "meg", "marge", "deb", "sue", "suzy", "mick", "jon",
}


def _load_classes() -> List[List[str]]:
    path = os.environ.get("OSTLER_NAME_VARIANTS_FILE")
    if not path:
        return _DEFAULT_CLASSES
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, list) and all(isinstance(g, list) for g in data):
            return [[str(n).strip().lower() for n in g if str(n).strip()]
                    for g in data]
    except (OSError, ValueError):
        pass
    # A malformed override must not silently disable the guard.
    return _DEFAULT_CLASSES


def _build() -> Dict[str, str]:
    """name -> canonical form (the first, longest member of its class)."""
    out: Dict[str, str] = {}
    for group in _load_classes():
        if not group:
            continue
        # The FIRST entry is the full name and the canon -- not the longest,
        # which used to make a short name canonicalise to a longer, unrelated
        # one (e.g. picking "allison" as the canon for a name that merely
        # shares a prefix).
        canon = group[0]
        for name in group:
            if name in _AMBIGUOUS:
                continue
            out.setdefault(name, canon)
    return out


_CANON = _build()


def canonical_given(word: str) -> str:
    """Map a given name to its class canon; unknown words pass through."""
    return _CANON.get((word or "").strip().lower(), (word or "").strip().lower())


def variants_of(word: str) -> Set[str]:
    """Every known variant of this given name, including itself."""
    c = canonical_given(word)
    return {n for n, canon in _CANON.items() if canon == c} | {c}


def same_person_given_names(a: str, b: str) -> bool:
    """True when two given names are variants of one another."""
    return canonical_given(a) == canonical_given(b)


_ALL_GIVEN = set(_CANON) | set(_CANON.values())


def is_known_given(word: str) -> bool:
    """True when this word is a known given name in the active locale table.

    Used to stop two strangers uniting on a shared FIRST name: "Andrew Quillon"
    and "Andrew Smith" share "andrew" and are two people. A surname match is
    evidence; a first-name match is a coincidence.
    """
    return (word or "").strip().lower() in _ALL_GIVEN
