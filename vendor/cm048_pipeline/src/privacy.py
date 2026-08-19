"""Privacy-level inference for the four-artefact bundle.

The L3 privacy contract (CM052 wire 2026-05-08, mirrored here):

    L0  unredacted, reserved for synthetic fixtures or explicit
        operator opt-in
    L1  redacted (PII sanitised); browseable in wiki, embeddable
        in Qdrant
    L2  collapsed by default in wiki; embeddable in Qdrant; the
        usual default for personal-but-not-private content
    L3  body suppressed in wiki; NOT embedded in Qdrant; reachable
        only via the deliberate-fetch MCP path with explicit
        ``request_unredacted=True``

Per the HR015 brief (2026-05-09), each source channel has a
sensible default and a single override hook (``privacy_level`` on
the metadata payload, set by the source-side capture). The
defaults are deliberately simple to start; the operator can tune
via config later.

| Channel | Default | Notable overrides                              |
|---------|---------|------------------------------------------------|
| spoken  | L2      | user-marked at recording time -> L3            |
| im      | L2      | (CM040 PR will add per-contact L3 list)        |
| whatsapp| L2      | (CM047 PR will add group/contact ladders)      |
| email   | L2      | domain/local-part aware L1/L3 ladder via       |
|         |         | ``infer_for_email_addresses`` (CM046 PR)       |
| manual  | L2      | mostly fixtures; metadata override expected    |

A typo / unknown channel falls back to L3 -- defence in depth so
a malformed payload cannot silently downgrade to public.
Mirrors the same fallback in CM052 wire and PWG MCP
get_conversation.

This module is deliberately tiny and side-effect-free; the per-
channel cleverness lives in ``channel_adapter.py``. Splitting
keeps the shipping default ladder readable and the per-channel
overrides reviewable in isolation.
"""
from __future__ import annotations

import logging
from typing import Optional

from .schemas import Classification


logger = logging.getLogger(__name__)


_VALID_LEVELS = ("L0", "L1", "L2", "L3")


_CHANNEL_DEFAULTS: dict[str, str] = {
    "spoken": "L2",
    "im": "L2",
    # ``sms`` (green-bubble texts) is the same class of personal
    # conversation as ``im`` (blue-bubble iMessages) and must
    # share its default. The feed emits ``channel="sms"`` for SMS
    # threads; without this key SMS fell through to the L3
    # defence-in-depth fallback below and was never embedded in
    # Qdrant / surfaced to the wiki or assistant (silent drop).
    "sms": "L2",
    "whatsapp": "L2",
    "email": "L2",
    "manual": "L2",
}


def normalise(value: object) -> str:
    """Coerce ``value`` to one of L0..L3.

    Used both at infer time (above) and in defence-in-depth
    fallbacks. Anything we don't recognise becomes L3 so a
    typo or legacy value cannot silently downgrade to public.
    Mirrors the same pattern in CM052 wire's ``_privacy_level``
    and PWG MCP's ``_frontmatter_privacy_level``.
    """
    if isinstance(value, str) and value.upper() in _VALID_LEVELS:
        return value.upper()
    if value is not None and value != "":
        logger.warning(
            "Unknown privacy_level %r; defaulting to L3", value
        )
    return "L3"


def infer(
    *,
    channel: str,
    classification: Optional[Classification] = None,
    metadata: Optional[dict] = None,
) -> str:
    """Decide the privacy level for a conversation.

    Order of precedence (highest first):

    1. Explicit ``metadata['privacy_level']`` set by the source-
       side capture (e.g. CM042's RemoteCapture lets the user
       mark a meeting as private at recording time; that arrives
       here as ``metadata['privacy_level'] = 'L3'``).
    2. Classification sensitivity escalation. The classifier
       emits ``sensitivity.level`` in {"normal", "high", ...};
       a ``high`` classifier verdict bumps the channel default
       up by one level (L2 -> L3) so the bundle writer's L3
       short-circuit fires.
    3. Channel default from the table above.
    4. Defence-in-depth fallback: L3 for unknown channels.

    Returning a str (not an enum) to match the same shape as
    CM052 wire and PWG MCP. The four sites compare strings.
    """
    metadata = metadata or {}
    explicit = metadata.get("privacy_level")
    if explicit is not None:
        return normalise(explicit)

    if classification is not None:
        sensitivity_level = (
            classification.sensitivity.level
            if classification.sensitivity is not None
            else "normal"
        )
        # CM048's classifier emits sensitivity.level in
        # ``normal | personal | sensitive | highly-sensitive``.
        # ``sensitive`` and ``highly-sensitive`` should escalate
        # the bundle's privacy level upward.
        if sensitivity_level in ("sensitive", "highly-sensitive"):
            base = _CHANNEL_DEFAULTS.get(channel, "L3")
            if sensitivity_level == "highly-sensitive":
                return "L3"
            # "sensitive" -> bump by one tier.
            if base == "L0":
                return "L1"
            if base == "L1":
                return "L2"
            if base == "L2":
                return "L3"
            return base  # already L3

    if channel in _CHANNEL_DEFAULTS:
        return _CHANNEL_DEFAULTS[channel]

    logger.warning(
        "Unknown channel %r; defaulting privacy to L3", channel
    )
    return "L3"


# ---------------------------------------------------------------------------
# Email-specific privacy inference (CM046)
# ---------------------------------------------------------------------------
#
# Per HR015 2026-05-09: email channel default is L2; L1 for
# newsletters / marketing / transactional senders; L3 for legal /
# medical / financial sender domains. The email channel adapter
# calls ``infer_for_email_addresses`` and uses the result as a
# pre-channel-default override -- if the function returns None,
# the channel default ladder above takes over.
#
# Sensible defaults; the operator will likely refine via a config file
# post-launch (HR015 brief: "Don't over-engineer; ship sensible
# defaults, log the level decision"). Pattern lists are local
# constants here so a follow-up PR can lift them into
# ``settings.yaml`` without changing the API.


# Local-part patterns that indicate marketing / transactional /
# newsletter mail. Match anchored at the start of the local part
# so partial substrings ("info-foo@") still match. Listed in
# canonical lower-case; matching is case-insensitive.
_EMAIL_L1_LOCALPART_PREFIXES: tuple[str, ...] = (
    "noreply",
    "no-reply",
    "donotreply",
    "do-not-reply",
    "newsletter",
    "marketing",
    "promotion",
    "promotions",
    "deals",
    "offers",
    "info",
    "hello",
    "team",
    "news",
    "updates",
    "receipts",
    "receipt",
    "orders",
    "order",
    "shipping",
    "delivery",
    "support",
    "notifications",
    "notify",
    "billing",
    "invoice",
    "invoices",
    "alerts",
    "security-noreply",
    "automated",
    "auto-reply",
    "auto",
    "system",
    "robot",
    "bot",
    "mailer",
    "mailings",
    "campaign",
)


# Domain suffixes that indicate legal / medical / financial mail.
# Suffix match (case-insensitive) so subdomains route correctly
# (``billing.bigbank.bank`` matches ``.bank``). Listed for
# defence-in-depth; an installer can extend via config later.
_EMAIL_L3_DOMAIN_SUFFIXES: tuple[str, ...] = (
    # Legal / law-firm gTLDs
    ".law",
    ".lawyer",
    ".attorney",
    ".legal",
    # Medical / health gTLDs
    ".health",
    ".medical",
    ".dental",
    ".doctor",
    ".clinic",
    ".hospital",
    # Financial gTLDs
    ".bank",
    ".finance",
    ".fund",
    ".credit",
    ".accountant",
    ".accountants",
    ".insurance",
    ".tax",
    # Government -- often carries sensitive correspondence
    ".gov",
    ".gov.uk",
    ".gov.us",
)


def _split_email(address: str) -> tuple[str, str]:
    """Split ``"local@domain"`` into ``(local_part, domain)``,
    both lower-cased and stripped. Returns ``("", "")`` for
    malformed input."""
    if not isinstance(address, str):
        return "", ""
    s = address.strip().strip("<>").lower()
    if "@" not in s:
        return "", ""
    local, _, domain = s.rpartition("@")
    return local.strip(), domain.strip()


def infer_for_email_addresses(
    addresses: list[str] | tuple[str, ...] | None,
) -> Optional[str]:
    """Inspect a list of email addresses (typically the non-user
    participants of a thread) and return a privacy level if any
    matches a known sensitive pattern.

    Returns:
        ``"L3"`` if any address's domain matches a legal /
            medical / financial / government suffix.
        ``"L1"`` if any address's local part matches a
            marketing / transactional prefix AND no L3 match
            was found. (L3 wins if both apply -- the sensitive
            domain is the stronger signal.)
        ``None`` if no rule matched. The caller should fall
            through to the channel default.

    Multiple participants: the highest privacy level wins. If
    ANY address triggers L3, the whole thread is L3 -- a
    conversation between the user and a lawyer where the lawyer
    cc's a paralegal still classifies as legal (L3).
    """
    if not addresses:
        return None
    saw_l1 = False
    for addr in addresses:
        local, domain = _split_email(addr)
        if not domain:
            continue
        # Check L3 domain suffixes first (stronger signal).
        for suffix in _EMAIL_L3_DOMAIN_SUFFIXES:
            if domain == suffix.lstrip(".") or domain.endswith(suffix):
                logger.info(
                    "email privacy: %r matches L3 suffix %r",
                    addr, suffix,
                )
                return "L3"
        # Check L1 local-part prefixes.
        for prefix in _EMAIL_L1_LOCALPART_PREFIXES:
            if local == prefix or local.startswith(prefix + "-") or \
                    local.startswith(prefix + "."):
                saw_l1 = True
                logger.info(
                    "email privacy: %r matches L1 prefix %r",
                    addr, prefix,
                )
                break
    if saw_l1:
        return "L1"
    return None


__all__ = ["infer", "normalise", "infer_for_email_addresses"]
