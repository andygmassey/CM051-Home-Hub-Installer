"""Some identifiers belong to a ROLE, not to a person.

WHY THIS EXISTS
===============
``identifier_quality`` decides whether an identifier may be used to key a
person. Its structural test is strong but REACTIVE: it needs to have already
seen two distinct humans behind one address before it will refuse it. That is
one person too late. By the time ``invitations@linkedin.example`` has presented
as a second human, a stranger has already been fused onto somebody's node.

This module is the PRIOR half of that decision -- it recognises the shapes that
cannot belong to one human on FIRST sighting, before any collision exists to
detect.

THE ASYMMETRY THAT SETS THE THRESHOLD
=====================================
Refusing a real person's address splits them across two nodes: annoying,
recoverable, and visible on the duplicates page. Accepting a role address fuses
strangers into one identity and silently corrupts who the customer knows.

So this errs toward refusing. A freelancer who really does use
``hello@their-own-domain.example`` as a personal address gets split, and that is
the cost we choose.

WHAT IS DELIBERATELY *NOT* HERE
===============================
No domain blocklist. "Everything at this provider is bulk" is the over-broad
rule that would refuse the personal addresses of everyone who uses that
provider. The local part is the part that encodes the role, so the local part is
what is tested.

Not English-only: the word list is locale data (OSTLER_ROLE_LOCALPARTS_FILE),
the same pattern as ``relationship_labels`` and ``given_name_variants``. A
locale without a list still gets every structural rule below, because those are
shape-based and language-free.
"""
from __future__ import annotations

import json
import os
import re
from typing import Set

# Local parts that name a FUNCTION rather than a human. Whole-token matches
# only -- see is_role_identifier for why substring matching is refused here.
_DEFAULT_ROLE_LOCALPARTS = {
    # front desk / general contact
    "info", "information", "contact", "hello", "hi", "enquiries", "enquiry",
    "inquiries", "inquiry", "office", "reception", "mail", "email", "general",
    # support / service
    "support", "help", "helpdesk", "service", "customerservice", "customercare",
    "care", "feedback", "complaints",
    # commercial
    "sales", "orders", "order", "billing", "accounts", "accounting", "invoices",
    "invoice", "payments", "finance", "bookings", "booking", "reservations",
    # internal functions
    "admin", "administrator", "hr", "jobs", "careers", "recruitment",
    "legal", "privacy", "security", "abuse", "compliance", "press", "media",
    "marketing", "partners", "community", "events", "team", "staff", "everyone",
    # machinery: these never have an owner at all
    "noreply", "no-reply", "donotreply", "do-not-reply", "notifications",
    "notification", "alerts", "alert", "news", "newsletter", "newsletters",
    "updates", "update", "mailer-daemon", "postmaster", "webmaster", "hostmaster",
    "bounce", "bounces", "automated", "automailer", "robot", "bot", "daemon",
    "system", "root", "nobody", "invitations", "invites", "invite",
    "subscribe", "unsubscribe", "confirm", "verify", "verification",
}


def _load() -> Set[str]:
    path = os.environ.get("OSTLER_ROLE_LOCALPARTS_FILE")
    if not path:
        return set(_DEFAULT_ROLE_LOCALPARTS)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, list):
            return {str(w).strip().lower() for w in data if str(w).strip()}
    except (OSError, ValueError):
        pass
    return set(_DEFAULT_ROLE_LOCALPARTS)


_ROLE_LOCALPARTS = _load()

# Split a local part into tokens so "sales-uk", "info.desk" and "no_reply" all
# reduce to words that can be checked against the list.
_TOKEN_SPLIT = re.compile(r"[.\-_+]+")

# Machinery that appears as a SUBSTRING and is unambiguous even inside a longer
# local part: "marketing-noreply", "buildnoreply". Kept to a short list
# precisely because substring matching is the risky kind.
#
# Written WITHOUT separators and matched against a flattened local part, so
# every spelling collapses to one entry: no-reply / no_reply / no.reply /
# noreply all become "noreply". Tokenising alone cannot do this -- it splits
# "no_reply" into "no" and "reply", neither of which is a role word on its own,
# and the address sails through. (Caught by this module's own tests, 2026-08-10.)
_MACHINE_SUBSTRINGS = (
    "noreply", "donotreply", "mailerdaemon", "postmaster",
)

# VERP / bulk return paths: "bounces-12345-user=host@", "reply+a1b2c3@".
# A long digit-or-hex run inside the local part is a tracking token, not a name.
_VERP = re.compile(r"(^|[.\-_+])(bounce[sd]?|reply|return|notify)([.\-_+]|$)")
_TRACKING_RUN = re.compile(r"[.\-_+][0-9a-f]{8,}(?:[.\-_+]|$)", re.IGNORECASE)

_EMAIL = re.compile(r"^\s*(?P<local>[^@\s]+)@(?P<domain>[^@\s]+\.[A-Za-z]{2,})\s*$")

# A pure-digit identifier this short is an SMS short code, which is a broadcast
# channel by definition. Real numbers, including every international format we
# ingest, are longer than this once punctuation is stripped.
_SHORTCODE_MAX_DIGITS = 6
_DIGITS_ONLY = re.compile(r"^[\d\s().-]+$")


def is_role_identifier(identifier: str) -> bool:
    """True when this identifier names a function or a machine, not a person.

    Whole-token matching for the word list: "sales@" and "sales-uk@" are roles,
    but "salesman@" is left alone, and so is a person whose local part merely
    CONTAINS a role word -- "marioinfo@" is somebody's name plus a suffix, not
    the information desk. Substring matching is reserved for the short
    ``_MACHINE_SUBSTRINGS`` list, where there is no human reading.
    """
    ident = (identifier or "").strip().lower()
    if not ident:
        return False

    m = _EMAIL.match(ident)
    if not m:
        # Not an address. The only non-address role shape we recognise is an
        # SMS short code; anything else is somebody's number and is left alone.
        if _DIGITS_ONLY.match(ident):
            digits = re.sub(r"\D", "", ident)
            return 0 < len(digits) <= _SHORTCODE_MAX_DIGITS
        return False

    local = m.group("local")

    # Flatten separators so no-reply / no_reply / no.reply / noreply are one case.
    if any(s in _TOKEN_SPLIT.sub("", local) for s in _MACHINE_SUBSTRINGS):
        return True
    if _VERP.search(local) and _TRACKING_RUN.search(local):
        return True

    tokens = {t for t in _TOKEN_SPLIT.split(local) if t}
    if tokens & _ROLE_LOCALPARTS:
        return True
    # A local part that is exactly a role word with no separators at all.
    return local in _ROLE_LOCALPARTS


def explain(identifier: str) -> str:
    """Why this identifier was refused, for the install log and Doctor."""
    return (
        f"{identifier}: names a role or a mail system rather than a person, so "
        "it cannot identify one human -- everyone who writes from it would be "
        "merged into a single contact."
    )
