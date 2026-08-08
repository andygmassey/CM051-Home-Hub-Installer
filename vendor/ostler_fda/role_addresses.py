"""Which email addresses are a ROLE, not a person.

Split out of pwg_ingest so tools that must NOT pull in an HTTP client (the
repair pass, any offline audit) can import the rule. The rule and the ingest
path must never diverge -- that is how a guard ends up enforced in one place
and not the other.
"""
from __future__ import annotations

import re

# Local parts that are a ROLE or a BULK SENDER, never an identity.
#
# A person's URI is a uuid5 of their identifier, so two people sharing an
# identifier become ONE PERSON. That is correct for a real address and
# catastrophic for a notification sender -- proven on a real box 2026-08-08 by
# computing the uuid5 of each candidate and matching it to the merged node:
#
#   invitations@linkedin.com   -> ONE node carrying 9 different people
#                                 (Anna Bartle, Eric Chan, Jitendra Chamoli,
#                                  Nurun Nahar Ame, Niels van Uden, ...)
#   notifications@github.com   -> ONE node carrying 7 (Max Braun, andygmassey,
#                                  dependabot[bot], github-actions[bot], ...)
#   dan@tldrnewsletter.com     -> ONE node carrying 6 TLDR newsletters
#
# 265 person nodes on that box carry more than one display name; these are the
# worst. The sender address of a notification email was being used as the
# RECIPIENT's identity, so every LinkedIn invitation collapsed onto one person.
#
# This is task #659, filed as "role-address over-merge guard" and never done.
_ROLE_LOCALS = frozenset({
    "invitations", "invitation", "invite", "invites",
    "notifications", "notification", "notify", "alerts", "alert",
    "noreply", "no-reply", "donotreply", "do-not-reply", "reply",
    "news", "newsletter", "newsletters", "digest", "updates", "update",
    "info", "hello", "hi", "contact", "support", "help", "helpdesk",
    "admin", "billing", "accounts", "account", "sales", "marketing",
    "team", "mail", "mailer", "mailer-daemon", "bounce", "bounces",
    "postmaster", "webmaster", "automated", "auto", "system", "robot", "bot",
    "members", "member", "community", "social", "security", "service",
})

# Domains that only ever send machine mail. Any address here is bulk, whatever
# the local part -- `dan@tldrnewsletter.com` is a newsletter, not Dan.
_BULK_DOMAINS = (
    "tldrnewsletter.com",
    "e.linkedin.com",
    "bounce.linkedin.com",
    "email.linkedin.com",
)


def is_role_identifier(identifier: str) -> bool:
    """True when this address is a role/bulk sender, not one human's identity.

    Conservative on purpose. A false positive here SPLITS one real person into
    several nodes, which is annoying; a false negative MERGES several real
    people into one, which is what put nine strangers behind a single name and
    made the graph actively wrong. Splitting is recoverable, merging is not.
    """
    ident = (identifier or "").strip().lower()
    if "@" not in ident:
        return False
    local, _, domain = ident.partition("@")
    if any(domain == d or domain.endswith("." + d) for d in _BULK_DOMAINS):
        return True
    # Strip a plus-tag and any trailing digits: `alerts+uk2` is still `alerts`.
    local = local.split("+", 1)[0]
    local = re.sub(r"[-._]?\d+$", "", local)
    if local in _ROLE_LOCALS:
        return True
    # `messages-noreply@`, `inmail-hit-reply@`: a role word joined by a dash.
    parts = re.split(r"[-._]", local)
    return bool(parts) and any(p in _ROLE_LOCALS for p in parts if p)
