"""Parse vCard 3.0 text into a structured dict using the vobject library."""
from __future__ import annotations

import base64
import re
from typing import Any, Dict, List, Optional, Tuple

import vobject

# Cap after base64 decode. A malformed vCard (or one with an unexpectedly
# large portrait) should not be able to allocate arbitrary memory or flood
# disk during backfill.
MAX_PHOTO_BYTES = 5 * 1024 * 1024

# TYPE= params on vCard PHOTO are unreliable — iCloud exports routinely
# omit them, and we have seen "JPEG" labels on actual PNG payloads. Sniff
# the decoded bytes instead.
_PHOTO_MAGIC = (
    (b"\x89PNG\r\n\x1a\n", "image/png", "png"),
    (b"\xff\xd8\xff",      "image/jpeg", "jpg"),
    (b"GIF87a",            "image/gif",  "gif"),
    (b"GIF89a",            "image/gif",  "gif"),
)


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


def _sniff_image(data: bytes) -> Optional[Dict[str, str]]:
    """Return {"mime": ..., "ext": ...} for recognised image bytes, else None."""
    for magic, mime, ext in _PHOTO_MAGIC:
        if data.startswith(magic):
            return {"mime": mime, "ext": ext}
    return None


# Match a whole PHOTO property line including any folded continuation lines
# (RFC 6350: continuation lines begin with a space or tab). We extract PHOTO
# from the raw vCard text before handing it to vobject for two reasons:
#   1. vobject's vCard 4.0 parser treats ``data:image/x;base64,...`` as
#      ending at the second colon, silently losing the payload.
#   2. vobject raises ``binascii.Error`` *during readOne* if ENCODING=b data
#      is corrupt, killing the entire card parse instead of just the photo.
_PHOTO_LINE_RE = re.compile(
    r"^PHOTO(?P<params>(?:;[^:\r\n]+)*):(?P<value>[^\r\n]*(?:\r?\n[ \t][^\r\n]*)*)\r?\n?",
    re.MULTILINE | re.IGNORECASE,
)


def _decode_photo_value(params: str, value: str) -> Optional[Dict[str, Any]]:
    """Turn a raw (possibly folded) PHOTO value into {data, mime, ext} or None.

    Handles vCard 3.0 ENCODING=b, vCard 4.0 ``data:`` URIs, and bare base64
    (some exporters drop the ENCODING param). Never raises — any failure
    path returns None.
    """
    # Unfold RFC 6350 continuation lines: strip the leading space/tab.
    unfolded = re.sub(r"\r?\n[ \t]", "", value).strip()
    if not unfolded:
        return None

    try:
        if unfolded.startswith(("http://", "https://")):
            # URL-only PHOTO — out of scope, we do not fetch remote images.
            return None
        if unfolded.startswith("data:"):
            # data:image/jpeg;base64,<b64>
            try:
                _, b64 = unfolded.split(",", 1)
            except ValueError:
                return None
            data = base64.b64decode(b64, validate=False)
        else:
            # ENCODING=b or bare base64. Strip any internal whitespace that
            # survived unfolding (defensive — unfolding should have handled
            # it, but some exporters pad with spaces).
            b64 = re.sub(r"\s+", "", unfolded)
            data = base64.b64decode(b64, validate=False)
    except Exception:
        return None

    if not data or len(data) > MAX_PHOTO_BYTES:
        return None

    sniffed = _sniff_image(data)
    if not sniffed:
        return None
    return {"data": data, "mime": sniffed["mime"], "ext": sniffed["ext"]}


def _extract_and_strip_photo(text: str) -> Tuple[str, Optional[Dict[str, Any]]]:
    """Extract PHOTO from raw vCard text and return (text_without_photo, photo).

    The returned text is safe to feed to vobject — the PHOTO line (plus any
    folded continuations) has been excised.
    """
    match = _PHOTO_LINE_RE.search(text)
    if not match:
        return text, None
    photo = _decode_photo_value(match.group("params") or "", match.group("value"))
    stripped = text[: match.start()] + text[match.end() :]
    return stripped, photo


def parse_vcard(vcard_text: str) -> Dict[str, Any]:
    """Parse a single vCard text and return a structured dict.

    Returned keys:
        uid, fn, given_name, family_name, phones, emails,
        org, title, notes, birthday, rev, photo
    """
    # PHOTO is extracted from the raw text up-front — vobject's PHOTO handling
    # is flaky (see _PHOTO_LINE_RE comment). The stripped text is what vobject
    # sees, so the rest of the card is isolated from any PHOTO corruption.
    vcard_text, photo = _extract_and_strip_photo(vcard_text)

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
        "photo": photo,
    }
