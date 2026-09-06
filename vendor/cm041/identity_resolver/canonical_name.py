"""Canonical display-name selection for person nodes.

A single person node can accumulate several candidate display names as it is
enriched and merged from multiple sources (Contacts/vCard, iMessage handles,
calendar attendee aliases, unix login names, bare email addresses). The graph
must expose exactly ONE ``pwg:displayName`` per person -- the wiki renderer and
every downstream surface read the first (arbitrary) value, so a junk candidate
such as "root" or "Gran Home Assistant" can poison a person's identity.

This module centralises the precedence rule that picks the canonical value and
the guard that rejects clearly-non-human display values. It is pure (no I/O) so
it can be unit-tested in isolation and reused by every write path
(``create_person``, the merge collapse, batch hydrate).

Productisation note: there is NO operator-specific hardcoding here. The rule is
"prefer a real human name (Contacts given+family, then a named candidate),
reject system aliases / bare emails / raw phone numbers". That generalises to
any operator and any locale.
"""

from __future__ import annotations

import json
import os
import re
from typing import Iterable, Optional

# Unix / system / automation login names that must never become a display name.
# Lower-cased exact matches.
_SYSTEM_LOGIN_NAMES = {
    "root",
    "admin",
    "administrator",
    "daemon",
    "nobody",
    "guest",
    "system",
    "postmaster",
    "mailer-daemon",
    "noreply",
    "no-reply",
    "donotreply",
    "do-not-reply",
    "unknown",
    "user",
    "me",
}

# Display-name substrings that mark an automation / appliance / brand alias
# rather than a human. Padded with spaces at the call site so we don't catch
# "bot" inside "Robert". Lower-cased.
_AUTOMATION_NAME_SUBSTRINGS = (
    "home assistant",
    "homekit",
    "no-reply",
    "noreply",
    "do not reply",
    "donotreply",
    "mailer-daemon",
    "automation",
    "notification",
)

_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
# A value that is mostly digits / phone punctuation -- a raw phone number.
_PHONE_RE = re.compile(r"^[+()\-.\s\d]{5,}$")


def _looks_like_email(value: str) -> bool:
    return bool(_EMAIL_RE.match(value.strip()))


def _looks_like_phone(value: str) -> bool:
    v = value.strip()
    if not v:
        return False
    if not _PHONE_RE.match(v):
        return False
    # Require at least 5 actual digits so "3-2-1" style human nicknames don't
    # get swept up, but "+44 7700 900123" does.
    return sum(c.isdigit() for c in v) >= 5


def is_acceptable_display_name(value: Optional[str]) -> bool:
    """Return True if ``value`` is a plausible human display name.

    Rejects: empty/whitespace, unix/system login names ("root", "admin"),
    bare email addresses, raw phone numbers, and automation/appliance aliases
    ("Gran Home Assistant", "...HomeKit...", "noreply").
    """
    if not value:
        return False
    v = value.strip()
    if not v:
        return False

    lowered = v.lower()
    if lowered in _SYSTEM_LOGIN_NAMES:
        return False
    if _looks_like_email(v):
        return False
    if _looks_like_phone(v):
        return False

    padded = f" {lowered} "
    for needle in _AUTOMATION_NAME_SUBSTRINGS:
        if needle in padded:
            return False

    return True


# ---------------------------------------------------------------------------
# A KINSHIP WORD MUST NEVER BECOME A GIVEN NAME.
# ---------------------------------------------------------------------------
# MEASURED 2026-09-06 on Andy's own graph. His WIFE was carried as
# "Mum <Surname>". The string existed in no source: a literal search of the
# graph dump found ZERO occurrences of it. It was MANUFACTURED here.
#
# The chain: a second address book syncs into Contacts (44 cards, registered
# as com.apple.AddressBookSourceSync, and plainly a child's phone book --
# Mum, Dad, Granny <Surname>, Uncle <Name>). One card is first-named "Mum"
# with two phones and two emails that match his wife's real card exactly.
# Identity resolution merges them on those shared identifiers, so ONE node
# ends up holding TWO givenName values, the real one and the kinship word,
# alongside one familyName. Then precedence rule 1 below welds given +
# family and returns it AHEAD of every real candidate.
#
# WHY IT KEPT COMING BACK FOR WEEKS. This function runs LAST, after ingest,
# and install.sh installs a recurring launchd catch-up agent that re-runs the
# resolver. Every fix applied at an ingest site was overwritten on the next
# tick. His own node already shows the endpoint: it holds givenName "Andrew"
# AND givenName "Dad", and there the composed form was PERSISTED.
#
# THE QUESTION ASKED HERE IS NOT "is 'Mum <Surname>' a name?" -- it is
# "should I CONSTRUCT that from givenName='Mum'?". So the test is on the
# given name ALONE, whole-label, which is unambiguous. contact_syncer's
# relationship_labels.py makes exactly this distinction in its docstring and
# deliberately leaves "Mum Zhang" alone, because a false positive there
# erases a real person's name.
#
# WHY THAT MODULE IS NOT IMPORTED, having checked rather than assumed: CM051
# vendors 11 identity_resolver files and does NOT vendor
# relationship_labels.py at all (0 of 27 vendored contact_syncer files). An
# import would raise on every customer box, and a try/except around it would
# delete the guard precisely where it ships. The list is duplicated here
# deliberately and both honour OSTLER_KINSHIP_WORDS_FILE so one file can
# drive both. Unifying them means adding that module to the vendor set, which
# is follow-up work and not a blocker for this defect.
#
# REFUSING THE WELD DOES NOT DROP THE PERSON. It falls through to precedence
# rule 2, the source-provided candidates -- which is a name a source actually
# asserted, and therefore better evidence than one this function assembled.
# Measured: with candidates ['Jane Smith','Jane','jane@example.com'] and
# given='Mum', the weld returns 'Mum Smith'; refusing it returns 'Jane Smith'.
_KINSHIP_GIVEN_NAMES = {
    "mum", "mummy", "mom", "mommy", "mother", "ma", "mam", "mama",
    "dad", "daddy", "father", "pa", "papa", "pop",
    "nan", "nana", "nanny", "gran", "granny", "grandma", "grandmother",
    "grandad", "granddad", "grandpa", "grandfather", "gramps",
    "bro", "brother", "sis", "sister", "auntie", "aunty", "aunt", "uncle",
    "cousin", "nephew", "niece", "godmother", "godfather", "godson",
    "goddaughter", "stepmum", "stepmom", "stepdad", "stepfather",
    "stepmother", "stepbrother", "stepsister",
    "hubby", "husband", "wife", "wifey", "partner", "spouse",
    "missus", "hubbie", "fiance", "fiancee",
    "son", "daughter", "kid", "bairn",
    "home", "house", "work", "office", "landline",
}


def _load_kinship_given_names() -> set:
    """Same override contact_syncer.relationship_labels honours, so one file
    can drive both lists until they are unified."""
    path = os.environ.get("OSTLER_KINSHIP_WORDS_FILE")
    if not path:
        return set(_KINSHIP_GIVEN_NAMES)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, list):
            return {str(w).strip().lower() for w in data if str(w).strip()}
    except (OSError, ValueError):
        pass
    return set(_KINSHIP_GIVEN_NAMES)


_KINSHIP_GIVEN = _load_kinship_given_names()


def is_kinship_given_name(given: Optional[str]) -> bool:
    """True when a GIVEN NAME is really a kinship term, whole-label.

    Deliberately NOT applied to the composed form: "Nan Goldin" is a real
    person and must survive. This asks only whether the given-name FIELD is a
    relationship word, which is the thing that must never be welded into a
    display name.
    """
    if not given:
        return False
    n = " ".join(str(given).strip().lower().split())
    if not n:
        return False
    if n in _KINSHIP_GIVEN:
        return True
    parts = n.split()
    if len(parts) == 2 and parts[0] in {"my", "our", "the", "big", "little", "wee"}:
        return parts[1] in _KINSHIP_GIVEN
    return False


def prefer_real_given_name(givens: Iterable[Optional[str]]) -> Optional[str]:
    """Pick a given name that is a NAME, from the several a merged node holds.

    THE NODE ALREADY CARRIES THE ANSWER AND THE CALLERS THREW IT AWAY. Identity
    resolution merges a card first-named with a kinship word onto a real
    person's node on shared phones and emails, so ONE node ends up holding two
    ``givenName`` values -- the real one and the kinship word. Both callers then
    did ``next(b["given"] for b in bindings if b.get("given"))``, taking the
    FIRST in arbitrary SPARQL result order and discarding the rest. Which name a
    person is shown under was decided by a coin flip.

    So this is not a new guess: it is using evidence that was already on the
    node. A real given name outranks a kinship word; order decides only among
    names of the same kind, so two real given names are never reordered.

    Returns None only when there is no usable given name at all.
    """
    cleaned = [str(g).strip() for g in givens if g and str(g).strip()]
    if not cleaned:
        return None
    for g in cleaned:
        if not is_kinship_given_name(g):
            return g
    # Every one of them is a kinship word. Hand back the first so the caller
    # keeps its existing behaviour and the guard downstream still refuses the
    # weld -- an incomplete name, not a wrong one.
    return cleaned[0]


def _is_manufactured_kinship_candidate(
    value: str, given: Optional[str], family: Optional[str]
) -> bool:
    """True for a candidate that IS the weld this module refuses to build.

    Guarding the given-name FIELD is not enough. The offending card contributes
    its own display name to ``candidates``, and once a composed form has been
    written to the graph it comes back as a candidate on the next pass, so
    precedence rule 2 hands the defect straight back unexamined. Measured on the
    shipped code: candidates ``['Mum Smith', 'Jane Smith']`` with given ``Mum``
    returned ``'Mum Smith'``.

    DELIBERATELY NARROW, because a false positive here erases a real person:

    * the candidate is exactly a kinship word (``Mum``) -- never a display name
    * OR the candidate is EXACTLY this node's own kinship given name followed by
      EXACTLY this node's own family name, which is the string ``_full_name``
      would have assembled and the guard above just refused to return

    "Nan Goldin" survives unless the node itself carries given ``Nan`` AND family
    ``Goldin``, in which case a source did assert that pair and rule 1 is where
    that belongs, not here.
    """
    v = " ".join(value.strip().split())
    if not v:
        return False
    if is_kinship_given_name(v):
        return True
    if not given or not is_kinship_given_name(given):
        return False
    welded = _full_name(given, family)
    return bool(welded) and v.casefold() == welded.casefold()


def _full_name(given: Optional[str], family: Optional[str]) -> Optional[str]:
    parts = [p.strip() for p in (given, family) if p and p.strip()]
    if not parts:
        return None
    return " ".join(parts)


def choose_canonical_display_name(
    candidates: Iterable[str],
    *,
    given_name: Optional[str] = None,
    family_name: Optional[str] = None,
) -> Optional[str]:
    """Pick the single canonical display name from a set of candidates.

    Precedence:
      1. A real human name assembled from Contacts/vCard ``givenName`` +
         ``familyName`` (the strongest, structured signal). Used only if the
         assembled name itself passes the acceptability guard.
      2. The first acceptable candidate from ``candidates`` (named-source
         display name) -- e.g. "Jane Doe" beats "root"/"me@..."/aliases
         because the junk values are filtered out.
      3. If nothing is acceptable, fall back to the first non-empty candidate
         (so the node never ends up nameless). The caller may still prefer to
         leave the existing value in place.

    Returns ``None`` only when there is no usable input at all.
    """
    structured = _full_name(given_name, family_name)
    if structured and is_acceptable_display_name(structured) and not is_kinship_given_name(given_name):
        return structured

    cleaned = [c.strip() for c in candidates if c and c.strip()]

    # Among the acceptable candidates, DEMOTE a run-together social handle
    # (e.g. "delganycolm") below a real name. A bare username passes
    # is_acceptable_display_name -- it is not junk -- so without this the FIRST
    # acceptable candidate wins by ingest order, and a handle that arrived first
    # became the name a person is shown under (Andy's .231 walk: a person shown
    # as "delganycolm" not "Colm O'Neill"). A handle is recognised narrowly, by
    # the exact shape the social sources leave: instagram_social sets
    # display_name = username, and _username_to_display_name keeps a
    # separator-less username lowercase and un-title-cased -- one all-lowercase
    # alphabetic token. This deliberately does NOT touch an all-caps brand
    # ("TLDR"), a spaced name ("Colm O'Neill", "TLDR AI"), or a capitalised
    # mononym. Stable, so order still decides among same-shape values and two
    # real names are never reordered. Display selection only; identity matching
    # is untouched. #659 RULE 2 / handle-over-name.
    def _looks_like_social_handle(v):
        return v.isalpha() and v == v.lower() and " " not in v

    acceptable = [
        c for c in cleaned
        if is_acceptable_display_name(c)
        and not _is_manufactured_kinship_candidate(c, given_name, family_name)
    ]
    if acceptable:
        acceptable.sort(key=lambda v: 1 if _looks_like_social_handle(v) else 0)
        return acceptable[0]

    # Nothing acceptable -- avoid a nameless node. Prefer the structured name
    # even if it tripped the guard (unlikely), else the first raw candidate.
    if structured:
        # LAST RESORT, AND THE GUARD STILL APPLIES. With no acceptable
        # candidate the only inputs are given+family, so refusing outright
        # would leave the node nameless -- which this branch exists to avoid.
        # But welding a kinship given name here reinstates the exact defect,
        # so drop the kinship half and keep the family name. Incomplete beats
        # wrong: "<Surname>" is not a name anyone objects to, "Mum <Surname>"
        # is the thing that put a man's WIFE in his graph as his mother.
        if is_kinship_given_name(given_name):
            fam = (family_name or "").strip()
            return fam or None
        return structured
    # NOT guarded here, and that is measured rather than assumed. This limb is
    # reachable only when `structured` is falsy AND nothing was acceptable, and
    # 0 of the 67 kinship words are rejected by is_acceptable_display_name (with
    # root / a bare email / a phone number rejected in the same run as the
    # control), so no kinship candidate can ever arrive here. A guard on this
    # line survived its own mutation test because it is unreachable, which is
    # protection that only looks like protection.
    if cleaned:
        return cleaned[0]
    return None
