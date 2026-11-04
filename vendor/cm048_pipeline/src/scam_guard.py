"""Scam guard for extracted todos: a scammer's instruction is never a todo.

Measured 2026-11-04 on a live Hub: the evening brief told the owner
"Contact the Foreign Funds Administrator immediately to arrange payment."
The todo had been extracted from an unsolicited advance-fee fraud email.
Every todo this pipeline writes can reach the daily brief, the wiki todos
wing and Apple Reminders, so the place to stop it is here, before any of
them sees it.

Two rules, both deterministic (no model, so they hold on every tier):

1. Junk, spam or fraud mail produces NO todos at all. A conversation is
   junk when its source says so (a Junk / Spam mailbox or label, an
   ``X-Spam-Flag: YES`` header, a spam verdict in ``X-Spam-Status``) or when
   its subject or any action reads as payment fraud (advance-fee,
   inheritance, prize, gift-card, "funds administrator" wording).

2. A payment or money-transfer todo is dropped when there is no evidence the
   owner has ever written to the other party: an unknown sender asking for
   money is the shape of fraud even when the wording is ordinary. Evidence
   is any of: the owner authored a message in this conversation, the
   counterpart is a saved contact, or the caller says so
   (``owner_has_written``).

Why withhold rather than label "possible scam": a label still delivers the
scammer's instruction, in the assistant's voice, over a channel others can
read, and to Reminders, which has no room for a caveat. Dropping a genuine
payment todo costs little: the source message is untouched in the inbox.

The ostler-assistant brief applies the same fraud wording to every row it
shows (``brief/scam.rs``), as a second line behind this one.
"""
from __future__ import annotations

import re
from typing import Iterable, Optional

from .participants import normalise_participants

# Phrases that on their own mark advance-fee, prize, inheritance or gift-card
# fraud. Kept in step with ostler-assistant crates/zeroclaw-runtime/src/brief/
# scam.rs SCAM_PHRASES.
SCAM_PHRASES: tuple[str, ...] = (
    "foreign fund", "funds administrator", "fund administrator",
    "funds release", "release of funds", "release the funds",
    "release your funds", "unclaimed fund", "unclaimed inheritance",
    "inheritance fund", "next of kin", "compensation fund", "consignment box",
    "diplomatic courier", "atm card", "lottery win", "won the lottery",
    "lottery prize", "claim your prize", "claim the prize", "you have won",
    "you've won", "winning notification", "western union", "moneygram",
    "gift card", "itunes card", "google play card", "steam card",
    "amazon card", "advance fee", "processing fee", "clearance fee",
    "release fee", "transfer fee", "handling fee to release",
    "verify your bank", "confirm your bank details", "bank details to receive",
    "account details to receive", "crypto wallet", "bitcoin wallet",
    "wallet address", "beneficiary of", "million dollars", "million usd",
    "million pounds", "million euros",
)

URGENCY: tuple[str, ...] = (
    "immediately", "urgent", "urgently", "within 24 hours", "within 48 hours",
    "without delay", "asap", "final notice", "last chance", "act now",
)

UNSOLICITED_MONEY: tuple[str, ...] = (
    "arrange payment", "arrange the payment", "arrange a payment",
    "receive payment", "receive the payment", "receive the funds",
    "receive your funds", "your funds", "the funds", "wire transfer",
    "wire the", "wire money", "send money", "pay the fee", "pay a fee",
    "pay the charges", "inheritance", "beneficiary", "payout", "pay out",
    "compensation", "refund of", "tax refund",
)

# A todo that moves money. Word-bounded so "repay" and "payment" match and
# "paypal newsletter" in a subject does not decide anything on its own.
_PAYMENT_RE = re.compile(
    r"\b(?:pay|pays|paid|paying|payment|payments|repay|transfer|transfers|"
    r"wire|remit|remittance|deposit|send (?:the )?money|bank details|"
    r"account details|sort code|iban|swift|fee|fees|gift cards?|"
    r"bitcoin|crypto)\b",
    re.IGNORECASE,
)

_JUNK_MAILBOX_RE = re.compile(r"\b(?:junk|spam|bulk mail|phishing)\b", re.IGNORECASE)


def _norm(text: str) -> str:
    return " ".join((text or "").lower().split())


def looks_like_payment_scam(text: str) -> bool:
    """A characteristic fraud phrase, or urgency together with money arriving
    from or demanded by a stranger."""
    t = _norm(text)
    if not t:
        return False
    if any(p in t for p in SCAM_PHRASES):
        return True
    return any(u in t for u in URGENCY) and any(m in t for m in UNSOLICITED_MONEY)


def is_payment_action(text: str) -> bool:
    """The todo asks for money to move."""
    return bool(_PAYMENT_RE.search(text or ""))


def _header_values(metadata: dict, name: str) -> list[str]:
    """Every value of header ``name`` in the shapes the bulk classifier reads
    (``headers`` / ``email_headers`` / ``email_thread.headers``; dict or a
    list of {name, value})."""
    out: list[str] = []
    containers = [metadata.get("headers"), metadata.get("email_headers")]
    thread = metadata.get("email_thread")
    if isinstance(thread, dict):
        containers.append(thread.get("headers"))
    want = name.lower()
    for c in containers:
        if isinstance(c, dict):
            for k, v in c.items():
                if str(k).lower() == want:
                    out.extend(v if isinstance(v, list) else [v])
        elif isinstance(c, list):
            for e in c:
                if isinstance(e, dict) and str(e.get("name") or e.get("key") or "").lower() == want:
                    out.append(e.get("value"))
    return [str(v) for v in out if v is not None]


def _mailbox_names(metadata: dict) -> Iterable[str]:
    for key in ("mailbox", "folder", "mail_folder", "labels", "gmail_labels"):
        v = metadata.get(key)
        if isinstance(v, str):
            yield v
        elif isinstance(v, (list, tuple)):
            yield from (str(x) for x in v)
    thread = metadata.get("email_thread")
    if isinstance(thread, dict):
        for key in ("mailbox", "folder", "labels"):
            v = thread.get(key)
            if isinstance(v, str):
                yield v
            elif isinstance(v, (list, tuple)):
                yield from (str(x) for x in v)


def junk_reason(metadata: Optional[dict]) -> str:
    """Why this conversation is junk, spam or fraud, or "" when it is not.

    Reads only what the source recorded plus the subject; the caller checks
    the extracted actions with :func:`looks_like_payment_scam` as well.
    """
    if not isinstance(metadata, dict):
        return ""
    if metadata.get("is_junk") is True or metadata.get("is_spam") is True:
        return "source_flag"
    for name in _mailbox_names(metadata):
        if _JUNK_MAILBOX_RE.search(name):
            return "junk_mailbox"
    for v in _header_values(metadata, "x-spam-flag"):
        if v.strip().lower().startswith("yes"):
            return "spam_header"
    for v in _header_values(metadata, "x-spam-status"):
        if v.strip().lower().startswith("yes"):
            return "spam_header"
    subject = metadata.get("subject") or ""
    thread = metadata.get("email_thread")
    if isinstance(thread, dict):
        subject = subject or thread.get("subject") or ""
    if looks_like_payment_scam(str(subject)):
        return "scam_subject"
    return ""


_EMAIL_SENT_RE = re.compile(r"^\s*sent\s*:", re.IGNORECASE | re.MULTILINE)


def owner_has_written(metadata: Optional[dict], transcript: str = "") -> bool:
    """Evidence the owner has corresponded with the other party.

    True when the caller says so, when an email transcript carries a
    ``sent:`` block (the owner authored a message in the thread), when a
    participant with the user role is recorded as having sent messages, or
    when every non-user participant is a saved contact. Absence of evidence
    is False: that is the conservative answer for a payment request.
    """
    if not isinstance(metadata, dict):
        return False
    if metadata.get("owner_has_written") is True:
        return True
    if transcript and _EMAIL_SENT_RE.search(transcript):
        return True
    participants = normalise_participants(metadata.get("participants"))
    if transcript:
        # A chat transcript line spoken by the owner: "Me: ...", or the
        # owner's display label, optionally bold, then ":" or "]".
        labels = ["me", "user", "you (owner)"] + [
            str(p.get("display") or "").strip().lower()
            for p in participants
            if (p.get("role") or "other") == "user" and p.get("display")
        ]
        for line in transcript.lower().splitlines():
            head = line.strip().lstrip("*").lstrip("-").strip()
            for lab in labels:
                if lab and head.startswith(lab) and head[len(lab):].lstrip("*").lstrip()[:1] in (":", "]"):
                    return True
    others = []
    for p in participants:
        role = (p.get("role") or "other")
        if role == "user":
            n = p.get("message_count") or p.get("messages_sent") or 0
            try:
                if int(n) > 0:
                    return True
            except (TypeError, ValueError):
                pass
        else:
            others.append(p)
    if others and all(
        p.get("contact_card") is True
        or p.get("person_uri")
        or p.get("contact_id")
        or p.get("resolved") is True
        for p in others
    ):
        return True
    # Only for a source whose labels come from the owner's own Contacts: the
    # Messages stager labels a carded handle by its Contacts name (chat.db
    # plus an AddressBook match) and an uncarded one by the raw handle, so
    # there a name IS a Contacts match. NOT WhatsApp, whose label can be the
    # sender's self-chosen push name ("Sam Example" from a stranger), and not
    # email, whose display name is the sender's own header. There the only
    # evidence is a card (``contact_card``, set by handle_resolver).
    source = str(
        metadata.get("source") or metadata.get("source_subtype") or ""
    ).strip().lower()
    if source in _CONTACTS_LABELLED_SOURCES and others and all(
        _is_contact_name(str(p.get("display") or p.get("id") or "")) for p in others
    ):
        return True
    return False


_CONTACTS_LABELLED_SOURCES = frozenset({"imessage", "sms"})
_NOT_A_PERSON_LABEL = frozenset({"user", "me", "owner", "other", "unknown", ""})


def _is_contact_name(label: str) -> bool:
    """A resolved Contacts name, not a raw handle: no "@", fewer than half
    of its characters digits, and not a placeholder label."""
    t = label.strip()
    if t.lower().startswith("other:"):
        t = t[len("other:"):]
    if t.lower() in _NOT_A_PERSON_LABEL or "@" in t:
        return False
    digits = sum(c.isdigit() for c in t)
    letters = sum(c.isalpha() for c in t)
    return letters > 0 and digits * 2 < len(t.replace(" ", ""))


def todo_withheld_reason(
    action_text: str,
    metadata: Optional[dict],
    *,
    transcript: str = "",
    junk: Optional[str] = None,
) -> str:
    """Why this todo must not be written, or "" to keep it."""
    j = junk_reason(metadata) if junk is None else junk
    if j:
        return j
    if looks_like_payment_scam(action_text):
        return "scam_action"
    if is_payment_action(action_text) and not owner_has_written(metadata, transcript):
        return "payment_to_stranger"
    return ""


__all__ = [
    "SCAM_PHRASES",
    "looks_like_payment_scam",
    "is_payment_action",
    "junk_reason",
    "owner_has_written",
    "todo_withheld_reason",
]
