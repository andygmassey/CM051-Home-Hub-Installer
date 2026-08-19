"""Parse vCard 3.0 text into a structured dict using the vobject library."""
from __future__ import annotations

from typing import Any, Dict, List, Optional

import vobject


def _get_attr(obj: Any, name: str, default: Any = None) -> Any:
    """Safely access an attribute, returning *default* when missing."""
    try:
        return getattr(obj, name, default)
    except Exception:
        return default


def _clean_str(val: Any) -> Optional[str]:
    """Strip whitespace from a string value; return None if empty/None/non-str."""
    if val is None:
        return None
    if not isinstance(val, str):
        try:
            val = str(val)
        except Exception:
            return None
    val = val.strip()
    return val if val else None


def _label_from_params(component: Any) -> str:
    """Extract the TYPE label (e.g. CELL, HOME, WORK) from a vCard component."""
    params = _get_attr(component, "params", {})
    if not params:
        return ""
    type_list = params.get("TYPE", [])
    if isinstance(type_list, list) and type_list:
        return type_list[0].upper()
    if isinstance(type_list, str):
        return type_list.upper()
    return ""


def parse_vcard(vcard_text: str) -> Dict[str, Any]:
    """Parse a single vCard text and return a structured dict.

    Returned keys:
        uid, fn, given_name, family_name, phones, emails,
        org, title, notes, birthday, rev
    """
    card = vobject.readOne(vcard_text)

    # UID
    uid: Optional[str] = None
    if hasattr(card, "uid"):
        uid = _clean_str(card.uid.value if card.uid else None)

    # FN (formatted name)
    fn: Optional[str] = None
    if hasattr(card, "fn"):
        fn = _clean_str(card.fn.value if card.fn else None)

    # N (structured name)
    given_name: Optional[str] = None
    family_name: Optional[str] = None
    if hasattr(card, "n") and card.n:
        n_val = card.n.value
        given_name = _clean_str(_get_attr(n_val, "given", None))
        family_name = _clean_str(_get_attr(n_val, "family", None))

    # TEL (phone numbers)
    phones: List[Dict[str, str]] = []
    if hasattr(card, "tel_list"):
        for tel in card.tel_list:
            value = tel.value if tel else None
            if value:
                phones.append({"value": value.strip(), "label": _label_from_params(tel)})

    # EMAIL
    emails: List[Dict[str, str]] = []
    if hasattr(card, "email_list"):
        for email in card.email_list:
            value = email.value if email else None
            if value:
                emails.append({"value": value.strip(), "label": _label_from_params(email)})

    # ORG
    org: Optional[str] = None
    if hasattr(card, "org") and card.org:
        org_val = card.org.value
        if isinstance(org_val, list):
            org = org_val[0] if org_val else None
        elif isinstance(org_val, str):
            org = org_val
        org = _clean_str(org)

    # TITLE
    title: Optional[str] = None
    if hasattr(card, "title") and card.title:
        title = _clean_str(card.title.value)

    # NOTE
    notes: Optional[str] = None
    if hasattr(card, "note") and card.note:
        notes = _clean_str(card.note.value)

    # BDAY
    birthday: Optional[str] = None
    if hasattr(card, "bday") and card.bday:
        bday_val = card.bday.value
        if isinstance(bday_val, str):
            birthday = _clean_str(bday_val)
        else:
            # datetime or date object
            birthday = _clean_str(str(bday_val))

    # REV
    rev: Optional[str] = None
    if hasattr(card, "rev") and card.rev:
        rev = _clean_str(card.rev.value)

    return {
        "uid": uid,
        "fn": fn,
        "given_name": given_name,
        "family_name": family_name,
        "phones": phones,
        "emails": emails,
        "org": org,
        "title": title,
        "notes": notes,
        "birthday": birthday,
        "rev": rev,
    }
