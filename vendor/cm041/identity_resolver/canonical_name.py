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
         display name) -- e.g. "Andrew Massey" beats "root"/"me@..."/aliases
         because the junk values are filtered out.
      3. If nothing is acceptable, fall back to the first non-empty candidate
         (so the node never ends up nameless). The caller may still prefer to
         leave the existing value in place.

    Returns ``None`` only when there is no usable input at all.
    """
    structured = _full_name(given_name, family_name)
    if structured and is_acceptable_display_name(structured):
        return structured

    cleaned = [c.strip() for c in candidates if c and c.strip()]

    for cand in cleaned:
        if is_acceptable_display_name(cand):
            return cand

    # Nothing acceptable -- avoid a nameless node. Prefer the structured name
    # even if it tripped the guard (unlikely), else the first raw candidate.
    if structured:
        return structured
    if cleaned:
        return cleaned[0]
    return None
