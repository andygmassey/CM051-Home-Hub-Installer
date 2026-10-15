"""Policy for the exact-identifier merge tier (v1.0.107 #30).

WHY THIS EXISTS. Measured on the Mini16 (2026-10-15, counts only): 70 pairs of
same-name nodes shared an exact email or phone and were never merged. 66 of
them were found by the exact-identifier tier every time and then REFUSED by
RULE 2, because the two nodes carried different ``icloud_contact_uid`` values.
That is the ordinary shape of one person with two Contacts cards (an iCloud
card and an Exchange or Google card): the cards differ, the person does not.
RULE 2 exists to stop two DIFFERENT people who share a household phone or an
office line from being folded together (CM051 #2545), and it is right to hold
for every canonical key. For the card uid alone it was too blunt: it fired even
when the names were identical and the shared identifier was personal.

THE RULE, narrow on purpose. A RULE 2 refusal may be overridden ONLY when the
sole conflicting canonical key is ``icloud_contact_uid`` AND all of:

  1. the two display names are identical once normalised, and are a real
     full name (two or more tokens), so "Mum" and "Dad" never qualify;
  2. the nodes share at least one USABLE key: a normalised email, a canonical
     LinkedIn URL, or an E.164 phone that is not a fixed line;
  3. no shared key is held by THREE OR MORE DISTINCT NAMES anywhere in the
     graph (a switchboard, a family inbox, a shared handset is not a key);
  4. no hard-conflict veto: different LinkedIn profiles on both sides, or
     different mobile numbers on both sides with nothing in common.

A conflict on ``linkedin_url`` or ``whatsapp_lid`` is never overridden.

Pure functions, no I/O, so the whole policy is unit-testable and the dry run
can use the very same code the merge uses.
"""
from __future__ import annotations

from collections import defaultdict
from typing import Dict, Iterable, List, Optional, Set, Tuple

import phonenumbers

#: The only canonical key an exact identifier may override.
OVERRIDABLE_CONFLICT = "icloud_contact_uid"

#: An identifier held by this many distinct names or more is not a merge key.
GUARD_MIN_DISTINCT_NAMES = 3

# phonenumbers.PhoneNumberType members that are personal enough to key on.
_PERSONAL_TYPES = frozenset({
    phonenumbers.PhoneNumberType.MOBILE,
    phonenumbers.PhoneNumberType.FIXED_LINE_OR_MOBILE,
    phonenumbers.PhoneNumberType.PERSONAL_NUMBER,
    phonenumbers.PhoneNumberType.VOIP,
})
_MOBILE_TYPES = frozenset({
    phonenumbers.PhoneNumberType.MOBILE,
    phonenumbers.PhoneNumberType.FIXED_LINE_OR_MOBILE,
})

Key = Tuple[str, str]  # ("email"|"phone"|"linkedin", normalised value)


def name_key(name: Optional[str]) -> str:
    return " ".join((name or "").lower().split())


def is_full_human_name(name: Optional[str]) -> bool:
    """Two or more tokens. A single word is a handle or a kinship label."""
    return len(name_key(name).split()) >= 2


def phone_kind(e164: str) -> str:
    """``mobile`` | ``landline`` | ``other`` | ``unknown`` for an E.164 string."""
    if not e164.startswith("+"):
        return "unknown"
    try:
        num = phonenumbers.parse(e164, None)
    except phonenumbers.NumberParseException:
        return "unknown"
    if not phonenumbers.is_valid_number(num):
        return "unknown"
    t = phonenumbers.number_type(num)
    if t in _MOBILE_TYPES:
        return "mobile"
    if t in _PERSONAL_TYPES:
        return "other"
    if t == phonenumbers.PhoneNumberType.FIXED_LINE:
        return "landline"
    return "unknown"


def is_usable_phone_key(e164: str) -> bool:
    """A phone may key a merge when it is a personal line. Fixed lines are
    household or office lines; unparseable strings prove nothing."""
    return phone_kind(e164) in ("mobile", "other")


def record_keys(rec, normalise_linkedin) -> Set[Key]:
    keys: Set[Key] = set()
    for e in rec.emails:
        if e:
            keys.add(("email", e))
    for p in rec.phones:
        if p:
            keys.add(("phone", p))
    for l in rec.linkedin_urls:
        k = normalise_linkedin(l)
        if k:
            keys.add(("linkedin", k))
    return keys


def build_holder_index(persons: Dict[str, object], normalise_linkedin
                       ) -> Dict[Key, Set[str]]:
    """key -> the set of DISTINCT normalised names that hold it."""
    holders: Dict[Key, Set[str]] = defaultdict(set)
    for rec in persons.values():
        nk = name_key(rec.display_name)
        for k in record_keys(rec, normalise_linkedin):
            holders[k].add(nk)
    return holders


def is_guarded(key: Key, holders: Dict[Key, Set[str]]) -> bool:
    """True when the key is held by 3+ distinct names (never a merge key)."""
    return len(holders.get(key, ())) >= GUARD_MIN_DISTINCT_NAMES


def hard_veto(a, b, normalise_linkedin) -> Optional[str]:
    """``linkedin`` | ``mobile`` | None. Different LinkedIn profile on both
    sides, or different mobile numbers on both sides with none in common."""
    la = {normalise_linkedin(u) for u in a.linkedin_urls} - {""}
    lb = {normalise_linkedin(u) for u in b.linkedin_urls} - {""}
    if la and lb and not (la & lb):
        return "linkedin"
    if a.phones and b.phones and not (set(a.phones) & set(b.phones)):
        if all(phone_kind(p) == "mobile" for p in a.phones) and all(
            phone_kind(p) == "mobile" for p in b.phones
        ):
            return "mobile"
    return None


def usable_shared_keys(a, b, holders, normalise_linkedin
                       ) -> Tuple[List[Key], List[Key]]:
    """(usable, guarded). ``usable`` shared keys may merge; ``guarded`` shared
    keys were rejected by the 3+-names guard (reported for the dry run)."""
    shared = record_keys(a, normalise_linkedin) & record_keys(b, normalise_linkedin)
    usable: List[Key] = []
    guarded: List[Key] = []
    for k in sorted(shared):
        if is_guarded(k, holders):
            guarded.append(k)
            continue
        if k[0] == "phone" and not is_usable_phone_key(k[1]):
            continue
        usable.append(k)
    return usable, guarded


def card_uid_override(a, b, conflicts: Iterable[str], holders,
                      normalise_linkedin) -> Tuple[bool, str]:
    """May an exact shared identifier override the card-uid RULE 2 refusal?

    ``conflicts`` is every canonical id_type on which the nodes conflict.
    Returns (allowed, reason). The reason is a short token for logs and the
    dry run, never a value.
    """
    conflicts = set(conflicts)
    if conflicts != {OVERRIDABLE_CONFLICT}:
        return False, "other_canonical_conflict:" + ",".join(sorted(conflicts))
    if name_key(a.display_name) != name_key(b.display_name):
        return False, "names_differ"
    if not is_full_human_name(a.display_name):
        return False, "name_not_a_full_name"
    veto = hard_veto(a, b, normalise_linkedin)
    if veto:
        return False, f"hard_veto:{veto}"
    usable, guarded = usable_shared_keys(a, b, holders, normalise_linkedin)
    if not usable:
        return False, "shared_identifier_guarded" if guarded else "no_usable_shared_key"
    return True, "exact_identifier:" + "+".join(sorted({k[0] for k in usable}))
