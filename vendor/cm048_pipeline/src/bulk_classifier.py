"""Bulk / marketing / no-reply detector – the non-relational gate.

Problem this solves
--------------------
CM046 feeds email threads into the CM048 pipeline as ``channel="email"``
conversations. A newsletter, a shipping notification, or a marketing
blast is structurally indistinguishable from a genuine person-to-person
email once it reaches the pipeline: it has a sender, one or more
recipients, a subject and a body. So the relationship-graph fan-out
treats it like real correspondence –

  - step 03 writes a ``pwg:RelationshipSignal`` about every non-user
    participant (warmth / trust / reciprocity about a mailing-list
    address or a co-recipient),
  - step 05 fans extracted facts onto ``other:<slug>`` subjects,
  - ``last_contact_updater`` bumps each participant's contact-recency,
  - and the four-artefact bundle attaches the "conversation" to each
    participant's wiki person page.

The visible symptom: a bulk newsletter (say a "28car" digest that
happened to be sent to a distribution list) shows up as an interaction
on the person pages of every co-recipient – two real people who never
actually corresponded with each other or the operator through it.

What this module does
---------------------
Detect bulk / marketing / transactional / automated mail UPSTREAM of
the relationship-graph fan-out, using signals that are cheap and
deterministic (no LLM):

  1. **Headers** – the RFC-standard bulk markers a mailing platform
     stamps: ``List-Unsubscribe`` / ``List-Id`` (RFC 2369/2919),
     ``Precedence: bulk|list|junk`` (RFC 2076), ``Auto-Submitted``
     (RFC 3834), plus common ESP fingerprints
     (``Feedback-ID``, ``X-Campaign*``, ``X-Mailer`` platforms) and an
     empty bounce ``Return-Path: <>``.
  2. **Sender local-part** – ``noreply@`` / ``donotreply@`` /
     ``notifications@`` / ``mailer-daemon@`` / ``newsletter@`` /
     ``marketing@`` and friends. Deliberately TIGHTER than the privacy
     module's L1 marketing list: it excludes ``info@`` / ``hello@`` /
     ``team@`` / ``support@`` / ``sales@`` because those are often the
     mailbox of a small business a human genuinely corresponds with,
     and dropping them from the relationship graph would lose real
     signal. Missing a relationship edge is worse here than a slightly
     collapsed privacy level.
  3. **Subject** – common transactional / campaign phrasing
     (``your order``, ``receipt``, ``unsubscribe``, ``verify your
     email`` …). A supporting signal; on its own it still classifies
     (transactional mail is explicitly in scope) but at lower
     confidence.

The verdict is consumed by ``processor.process`` to skip the
relationship / coaching / fact-extraction / last-contact steps for a
bulk message and to stamp ``non_relational=True`` into the bundle's
``extra_metadata`` so downstream consumers (CM044 wiki) can keep the
message off person pages while still rendering it as browseable content
in the Conversations wing.

Only the ``email`` channel carries these signals; spoken / im / sms /
whatsapp conversations are inherently relational (a real human on the
other end) and are never gated here.

The pattern lists are module-level constants so a follow-up PR can lift
them into ``settings.yaml`` without changing the public API, mirroring
the note on ``privacy._EMAIL_L1_LOCALPART_PREFIXES``.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Optional

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Signal tables
# ---------------------------------------------------------------------------


# Header names whose mere PRESENCE marks a message as bulk / list /
# automated mail. Matched case-insensitively. These are the RFC-standard
# mailing-list and auto-response markers plus the fingerprints the major
# email service providers stamp on campaign sends.
_BULK_HEADER_PRESENCE: tuple[str, ...] = (
    "list-unsubscribe",          # RFC 2369 – one-click unsubscribe
    "list-unsubscribe-post",     # RFC 8058 – one-click POST
    "list-id",                   # RFC 2919 – mailing list identity
    "list-post",                 # RFC 2369
    "list-help",                 # RFC 2369
    "list-subscribe",            # RFC 2369
    "feedback-id",               # ESP campaign / complaint id
    "x-feedback-id",
    "x-campaign",                # generic campaign markers
    "x-campaignid",
    "x-campaign-id",
    "x-mailchimp-id",            # Mailchimp
    "x-mc-user",                 # Mandrill / Mailchimp
    "x-mailgun-sid",             # Mailgun
    "x-sg-eid",                  # SendGrid
    "x-sendgrid-id",
    "x-ses-outgoing",            # Amazon SES
    "x-mailer-recptid",
    "x-marketoid",               # Marketo
    "x-auto-response-suppress",  # automated system (suppresses OOO)
    "x-autoreply",
    "x-autorespond",
)


# ``Precedence`` header values that mark non-personal mail (RFC 2076).
_BULK_PRECEDENCE_VALUES: frozenset[str] = frozenset(
    {"bulk", "list", "junk"}
)


# Sender local-parts (the bit before ``@``) that mark automated /
# no-reply / marketing mail. Matched case-insensitively as an exact
# local-part OR a prefix followed by a separator (``-``, ``.``, ``_``,
# ``+``) or a run of digits, so ``noreply@`` and ``no-reply-2@`` and
# ``newsletter.uk@`` all match while a real person ``noreplyfoo@`` does
# NOT (no separator).
_NON_RELATIONAL_LOCALPARTS: tuple[str, ...] = (
    "noreply",
    "no-reply",
    "no_reply",
    "donotreply",
    "do-not-reply",
    "do_not_reply",
    "dnr",
    "notification",
    "notifications",
    "notify",
    "mailer",
    "mailer-daemon",
    "mailerdaemon",
    "mail-daemon",
    "maildaemon",
    "bounce",
    "bounces",
    "bounced",
    "postmaster",
    "auto",
    "autoreply",
    "auto-reply",
    "autoresponder",
    "auto-confirm",
    "auto-notify",
    "automated",
    "automailer",
    "newsletter",
    "newsletters",
    "marketing",
    "campaign",
    "campaigns",
    "mailings",
    "mailing",
    "broadcast",
    "news",
    "promo",
    "promos",
    "promotion",
    "promotions",
    "alerts",
    "alert",
    "digest",
    "system",
    "sysadmin",
    "robot",
    "bot",
    "webmaster",
)


# Subject-line substrings that indicate transactional / campaign mail.
# Matched case-insensitively as substrings. A supporting signal: on its
# own it still classifies (transactional mail is in scope) but with a
# ``subject:`` reason so the log makes the weaker basis clear.
_TRANSACTIONAL_SUBJECT_PATTERNS: tuple[str, ...] = (
    "unsubscribe",
    "your order",
    "order confirmation",
    "order #",
    "order number",
    "your receipt",
    "receipt for",
    "your invoice",
    "invoice #",
    "payment received",
    "payment confirmation",
    "your statement",
    "statement is ready",
    "has shipped",
    "your shipment",
    "out for delivery",
    "tracking number",
    "verify your email",
    "verify your account",
    "confirm your email",
    "confirm your subscription",
    "reset your password",
    "password reset",
    "your subscription",
    "renew your subscription",
    "weekly digest",
    "daily digest",
    "monthly newsletter",
    "% off",
    "flash sale",
    "sale ends",
    "black friday",
    "cyber monday",
    "new arrivals",
    "back in stock",
    "abandoned cart",
    "left something in your cart",
)


# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------


@dataclass
class BulkVerdict:
    """Result of the non-relational check.

    ``is_non_relational`` is the gate the processor reads. ``reasons``
    is a short, human-readable list of every signal that fired (for the
    log line and the bundle's ``non_relational_reason`` stamp).
    ``confidence`` is ``"high"`` when a header or sender signal fired,
    ``"medium"`` when only a subject pattern matched, ``"none"`` when
    nothing did.
    """

    is_non_relational: bool = False
    reasons: list[str] = field(default_factory=list)
    confidence: str = "none"

    @property
    def reason_text(self) -> str:
        return "; ".join(self.reasons)


# ---------------------------------------------------------------------------
# Header extraction – tolerate several container shapes
# ---------------------------------------------------------------------------


def _iter_header_pairs(metadata: dict):
    """Yield ``(lowercased_name, value_str)`` for every header found in
    the metadata, tolerating the shapes CM046 might hand us.

    Looks in ``metadata['headers']``, ``metadata['email_headers']`` and
    ``metadata['email_thread']['headers']``. Each container may be:

      - a mapping ``{"List-Unsubscribe": "<...>", ...}``
      - a list of ``[name, value]`` pairs
      - a list of ``{"name": ..., "value": ...}`` dicts

    Malformed entries are skipped rather than raised on – a broken
    header block must never fail the pipeline.
    """
    containers = []
    for key in ("headers", "email_headers"):
        containers.append(metadata.get(key))
    thread = metadata.get("email_thread")
    if isinstance(thread, dict):
        containers.append(thread.get("headers"))

    for container in containers:
        if isinstance(container, dict):
            for name, value in container.items():
                if isinstance(name, str):
                    yield name.strip().lower(), _stringify_header_value(value)
        elif isinstance(container, (list, tuple)):
            for entry in container:
                if isinstance(entry, dict):
                    name = entry.get("name") or entry.get("key")
                    value = entry.get("value")
                    if isinstance(name, str):
                        yield name.strip().lower(), _stringify_header_value(value)
                elif isinstance(entry, (list, tuple)) and len(entry) >= 2:
                    name, value = entry[0], entry[1]
                    if isinstance(name, str):
                        yield name.strip().lower(), _stringify_header_value(value)


def _stringify_header_value(value: object) -> str:
    """Best-effort flatten of a header value to a lower-cased string.

    A repeated header may arrive as a list of values; join them so a
    substring/equality check sees all of them.
    """
    if isinstance(value, str):
        return value.strip().lower()
    if isinstance(value, (list, tuple)):
        return " ".join(
            v.strip() for v in value if isinstance(v, str)
        ).lower()
    if value is None:
        return ""
    return str(value).strip().lower()


# ---------------------------------------------------------------------------
# Sender / subject extraction
# ---------------------------------------------------------------------------


def _local_part(address: str) -> str:
    """Lower-cased local part of ``local@domain``; ``""`` if malformed.

    Unwraps RFC-822 angle brackets and a ``Display Name <addr>`` form.
    """
    if not isinstance(address, str):
        return ""
    s = address.strip()
    # Pull the address out of a "Display Name <addr>" form if present.
    if "<" in s and ">" in s:
        s = s[s.rfind("<") + 1 : s.rfind(">")]
    s = s.strip().strip("<>").lower()
    if "@" not in s:
        return ""
    local, _, _domain = s.rpartition("@")
    return local.strip()


def _collect_sender_addresses(metadata: dict) -> list[str]:
    """Collect candidate SENDER addresses from the metadata.

    Prefers explicit ``from`` / ``sender`` fields (a header block or a
    top-level key), then falls back to every non-user participant's
    address. We include all non-user participants because a bulk send's
    ``noreply@`` may land in the participant list rather than a distinct
    ``from`` field depending on how CM046 shaped the thread – and a
    single automated address anywhere is enough to mark the thread.
    """
    out: list[str] = []

    for name, value in _iter_header_pairs(metadata):
        if name in ("from", "sender", "return-path", "reply-to") and value:
            out.append(value)

    for key in ("from", "sender", "from_address"):
        raw = metadata.get(key)
        if isinstance(raw, str) and raw.strip():
            out.append(raw.strip())

    for entry in metadata.get("participants") or []:
        if not isinstance(entry, dict):
            continue
        if entry.get("role") == "user":
            continue
        addr = entry.get("email") or ""
        if not addr and "@" in (entry.get("id") or ""):
            addr = entry["id"]
        if isinstance(addr, str) and addr.strip():
            out.append(addr.strip())

    return out


def _subject_text(metadata: dict) -> str:
    """Lower-cased subject line, from the email_thread sidecar or a
    top-level ``subject`` key, else ``""``."""
    thread = metadata.get("email_thread")
    if isinstance(thread, dict):
        subj = thread.get("subject")
        if isinstance(subj, str) and subj.strip():
            return subj.strip().lower()
    subj = metadata.get("subject")
    if isinstance(subj, str) and subj.strip():
        return subj.strip().lower()
    return ""


def _localpart_matches(local: str) -> bool:
    """True if ``local`` is (or begins, at a separator/digit boundary)
    a non-relational local-part token."""
    if not local:
        return False
    for token in _NON_RELATIONAL_LOCALPARTS:
        if local == token:
            return True
        if local.startswith(token):
            rest = local[len(token):]
            # Continue the match only across an explicit separator or a
            # digit run, so ``no-reply-2`` matches but ``noreplyfoo``
            # (a real person's handle) does not.
            if rest[:1] in ("-", ".", "_", "+") or rest[:1].isdigit():
                return True
    return False


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------


def classify(metadata: Optional[dict]) -> BulkVerdict:
    """Return a :class:`BulkVerdict` for a conversation's metadata.

    Only ``channel == "email"`` metadata is inspected; every other
    channel returns a non-bulk verdict (spoken / im / sms / whatsapp
    conversations always have a real human on the other end).
    """
    verdict = BulkVerdict()
    if not isinstance(metadata, dict):
        return verdict
    channel = (metadata.get("channel") or "spoken").lower()
    if channel != "email":
        return verdict

    reasons: list[str] = []
    high_confidence = False

    # 1. Headers – presence markers.
    for name, value in _iter_header_pairs(metadata):
        if name in _BULK_HEADER_PRESENCE:
            reasons.append(f"header:{name}")
            high_confidence = True
        elif name == "precedence" and value in _BULK_PRECEDENCE_VALUES:
            reasons.append(f"precedence:{value}")
            high_confidence = True
        elif name == "auto-submitted" and value and value != "no":
            # RFC 3834: any value other than "no" marks automated mail.
            reasons.append(f"auto-submitted:{value}")
            high_confidence = True
        elif name == "return-path" and value in ("<>", ""):
            # An empty Return-Path is a bounce / automated envelope.
            if value == "<>":
                reasons.append("return-path:empty")
                high_confidence = True

    # 2. Sender local-part.
    for addr in _collect_sender_addresses(metadata):
        local = _local_part(addr)
        if _localpart_matches(local):
            reasons.append(f"sender:{local}")
            high_confidence = True
            break

    # 3. Subject patterns (supporting signal).
    subject = _subject_text(metadata)
    if subject:
        for pattern in _TRANSACTIONAL_SUBJECT_PATTERNS:
            if pattern in subject:
                reasons.append(f"subject:{pattern}")
                break

    if not reasons:
        return verdict

    # Deduplicate while preserving order.
    seen: set[str] = set()
    deduped: list[str] = []
    for r in reasons:
        if r not in seen:
            seen.add(r)
            deduped.append(r)

    verdict.is_non_relational = True
    verdict.reasons = deduped
    verdict.confidence = "high" if high_confidence else "medium"
    return verdict


def is_non_relational(metadata: Optional[dict]) -> bool:
    """Convenience boolean wrapper around :func:`classify`."""
    return classify(metadata).is_non_relational


__all__ = ["BulkVerdict", "classify", "is_non_relational"]
