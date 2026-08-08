"""Kinship words are RELATIONSHIPS, not names -- and never the user's own.

WHY (Andy, 2026-08-08)
======================
The name election picked "Alison Massey" as canonical and demoted "Mum" to
pwg:alternateName. Andy:

    "'Mum' for Alison is NOT - she is my WIFE and Connor's MUM, but not MY MUM
     (who was Sylvia Massey)."

That is not a cosmetic error. An alternateName is offered to the assistant as
"another name this person goes by", so with "Mum" on Alison's card Ava can
answer "your mum is Alison Massey". Andy's mother was Sylvia Massey, and she
has died. Getting that wrong out loud, from a contact card he filed for his
son's benefit, is the single worst thing this graph can say to him.

THE RULE
========
A kinship word on a contact card is PERSPECTIVAL -- it encodes a relationship
from SOMEBODY's point of view, and on a shared address book that somebody is
usually not the account owner. "Mum", "Dad", "Granny", "Auntie" are how the
household refers to a person, not what the person is called.

So kinship labels:
  * are NEVER a displayName
  * are NEVER an alternateName
  * are NEVER evidence that two records are different people
  * MAY be kept as a relationship hint, but only with a holder attached, and
    the holder is unknown unless something states it -- so v1 drops them
    rather than guessing whose mum she is.

Dropping loses nothing the customer can see: Alison still renders as "Alison
Massey", and "Mum" was only ever going to make the assistant confidently wrong.

Not English-only: the word list is locale data
(OSTLER_KINSHIP_WORDS_FILE), same pattern as given_name_variants. A locale
without a list still gets every other rule.
"""
from __future__ import annotations

import json
import os
import re
from typing import Set

_DEFAULT_KIN = {
    # parents / grandparents
    "mum", "mummy", "mom", "mommy", "mother", "ma", "mam", "mama",
    "dad", "daddy", "father", "pa", "papa", "pop",
    "nan", "nana", "nanny", "gran", "granny", "grandma", "grandmother",
    "grandad", "granddad", "grandpa", "grandfather", "granny", "gramps",
    # siblings / extended
    "bro", "brother", "sis", "sister", "auntie", "aunty", "aunt", "uncle",
    "cousin", "nephew", "niece", "godmother", "godfather", "godson",
    "goddaughter", "stepmum", "stepmom", "stepdad", "stepfather",
    "stepmother", "stepbrother", "stepsister",
    # partners
    "hubby", "husband", "wife", "wifey", "partner", "spouse", "other half",
    "missus", "hubbie", "fiance", "fiancee",
    # children
    "son", "daughter", "kid", "boy", "girl", "bairn",
    # household labels that are places, not people
    "home", "house", "work", "office", "landline",
}


def _load() -> Set[str]:
    path = os.environ.get("OSTLER_KINSHIP_WORDS_FILE")
    if not path:
        return set(_DEFAULT_KIN)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, list):
            return {str(w).strip().lower() for w in data if str(w).strip()}
    except (OSError, ValueError):
        pass
    return set(_DEFAULT_KIN)


_KIN = _load()
_PUNCT = re.compile(r"[^\w\s]", re.UNICODE)


def is_relationship_label(name: str) -> bool:
    """True when this label is a kinship/household term, not a person's name.

    Matches the WHOLE label only. "Mum" is a relationship; "Mum Zhang" is
    plausibly somebody's actual name and is left alone -- a false positive here
    erases a real person's name, which is worse than keeping an odd alias.
    """
    n = _PUNCT.sub(" ", (name or "").strip().lower())
    n = " ".join(n.split())
    if not n:
        return False
    if n in _KIN:
        return True
    # "my mum", "our nan", "big sis" -- a single qualifier in front.
    parts = n.split()
    if len(parts) == 2 and parts[0] in {"my", "our", "the", "big", "little", "wee"}:
        return parts[1] in _KIN
    return False


def explain(name: str) -> str:
    """Why this label was refused, for the install log and Doctor."""
    return (
        f"{name!r} is a relationship, not a name: it says how SOMEBODY refers "
        "to this person, and on a shared address book that somebody is usually "
        "not the account owner. Storing it as a name lets the assistant answer "
        "'your mum is <wife>'."
    )
