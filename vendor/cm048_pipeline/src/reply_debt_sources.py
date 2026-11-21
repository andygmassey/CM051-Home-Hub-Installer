"""WhatsApp and email sources for the reply-debt detector.

The iMessage source (``reply_debt_adapters.load_imessage_threads``) reads a
SNAPSHOT that the signed iMessage feed writes, so the process serving
``/api/v1/reply-debt`` (ical-server, a bare python under launchd) never opens
a TCC-protected store. These two sources follow the same design exactly:

  * the WhatsApp feed (``whatsapp_source.pipeline``, which already reads
    ChatStorage.sqlite under the assistant's grant) writes
    ``$OSTLER_DIR/state/reply_debt/whatsapp_threads.json``;
  * the email feed (``email_source.pipeline``, which already reads the Apple
    Mail ``.emlx`` tree) writes ``.../reply_debt/email_threads.json``.

Each snapshot carries, per recent thread, only the LAST message and the few
facts the rules below need. This module turns a snapshot into normalised
``Thread`` objects and applies the per-channel rules BEFORE the shared
detector (``reply_debt.detect``) applies the owed rules every channel shares.

Who is waiting
--------------
Identity comes from Contacts-card evidence only (``handle_identity``):

  * WhatsApp: the handle is the phone number inside the sender's JID
    (``<digits>@s.whatsapp.net`` -> ``+<digits>``). The WhatsApp push name is
    never read into the snapshot and never used: anyone can set it to
    anything. A sender whose number the app hides (``<id>@lid``) is a real
    person no card can match, so it is "someone not in your contacts".
  * Email: the handle is the From ADDRESS. The From display name is never
    used, for the same reason as a push name.

Rules, per channel (each exclusion is COUNTED, never silently dropped)
--------------------------------------------------------------------
WhatsApp:
  * 1:1 chats only, plus a group message that @mentions one of the owner's
    own numbers (it asks the owner personally; its AUTHOR is the person
    waiting). Every other group message is not a debt.
  * Privacy: the operator's explicit level wins, then the CM048 WhatsApp
    label ladder (family / partner / sensitive -> L3; public / work /
    broadcast group -> L1), else L2.
  * Payment fraud wording is never a debt (``scam_guard``).
Email:
  * The owner is in To. Cc only, Bcc or a list delivery is not a personal ask.
  * From a human: no List-Id, List-Unsubscribe, Auto-Submitted (other than
    ``no``), bulk/list/junk Precedence, no-reply mailbox, or marketing /
    transactional sender (the CM048 email ladder's L1 rung), and not junk or
    spam by mailbox or header (``scam_guard.junk_reason``).
  * The new text (quoted reply and signature removed) asks something
    (``reply_debt.owed_verdict`` is ``yes``). An FYI email is not a debt.
  * Privacy: the operator map's level, else the CM048 email ladder (legal,
    medical, financial, government domains -> L3), else L2.
  * Payment fraud wording, or a money request from a sender the owner has
    never written to and has not carded, is never a debt (``scam_guard``).

Connected or not
----------------
A channel the install never set up is ``not_connected`` and simply not read
(the brief heading then does not name it). A channel that IS set up but whose
snapshot is missing, unreadable, malformed, stale or records that the feed
could not read its store raises ``ReplyDebtSourceUnavailable``: "couldn't
check" is never the same answer as "nothing owed".
"""
from __future__ import annotations

import json
import logging
import os
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional

from . import reply_debt as _rd
from . import scam_guard as _scam
from .reply_debt import Message, Thread
from .reply_debt_adapters import (
    ReplyDebtSourceUnavailable,
    _parse_iso,
    _snapshot_max_age_hours,
)

SNAPSHOT_SCHEMA = 1

CHANNELS = ("whatsapp", "email")

_SNAPSHOT_FILES = {
    "whatsapp": "whatsapp_threads.json",
    "email": "email_threads.json",
}
_SNAPSHOT_ENV = {
    "whatsapp": "OSTLER_REPLY_DEBT_WHATSAPP_SNAPSHOT",
    "email": "OSTLER_REPLY_DEBT_EMAIL_SNAPSHOT",
}
# The feeds' LaunchAgents. install.sh renders each only on the branch that
# installs that feed, and the uninstaller removes it.
FEED_LABELS = {
    "whatsapp": "com.creativemachines.ostler.whatsapp-bundle",
    "email": "com.creativemachines.ostler.email-bundle",
}
# The email feed needs the third-party data consent, exactly as iMessage
# does (install.sh, "Mail conversation feed"). The WhatsApp feed has its own
# opt-in at install (CHANNEL_WHATSAPP_ENABLED + its consent), recorded by the
# feed's LaunchAgent existing at all.
EMAIL_CONSENT_TICKBOX = "third_party_data_personal_records"


def snapshot_path(channel: str) -> Path:
    """Must agree with the producing feed's ``reply_debt_snapshot_path``."""
    explicit = (os.environ.get(_SNAPSHOT_ENV[channel]) or "").strip()
    if explicit:
        return Path(explicit).expanduser()
    root = (os.environ.get("OSTLER_DIR") or "").strip()
    base = Path(root).expanduser() if root else Path.home() / ".ostler"
    return base / "state" / "reply_debt" / _SNAPSHOT_FILES[channel]


def feed_plist_path(channel: str) -> Path:
    return Path.home() / "Library" / "LaunchAgents" / f"{FEED_LABELS[channel]}.plist"


def connection_state(channel: str) -> tuple[str, str]:
    """``("connected" | "not_connected" | "unknown", detail)``, read from what
    the install WROTE, never inferred from a missing snapshot."""
    if channel == "email":
        try:
            from ostler_security import consent as _consent
            record = _consent.read_consent(EMAIL_CONSENT_TICKBOX)
        except Exception as exc:  # noqa: BLE001 -- recorded, never guessed
            return "unknown", f"consent registry unreadable: {type(exc).__name__}"
        if not (isinstance(record, dict) and record.get("decision") == "accepted"):
            return "not_connected", "third-party data consent not accepted"
    if not feed_plist_path(channel).is_file():
        return "not_connected", f"the {channel} feed is not installed on this Mac"
    return "connected", ""


def read_snapshot(
    channel: str,
    *,
    path: Optional[Path] = None,
    now: Optional[datetime] = None,
    max_age_hours: Optional[float] = None,
) -> Optional[dict]:
    """The validated snapshot dict, or ``None`` when the feed found no store
    at all (``status: absent``, a true zero). Raises
    ``ReplyDebtSourceUnavailable`` for everything else that is not ``ok``."""
    path = path or snapshot_path(channel)
    now = now or datetime.now(timezone.utc)
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise ReplyDebtSourceUnavailable(
            f"{channel}_snapshot_missing",
            f"the {channel} feed has not written its reply-debt snapshot yet",
        )
    except OSError as exc:
        raise ReplyDebtSourceUnavailable(f"{channel}_snapshot_unreadable", str(exc)[:200])
    try:
        snap = json.loads(raw)
    except ValueError as exc:
        raise ReplyDebtSourceUnavailable(f"{channel}_snapshot_malformed", str(exc)[:200])
    if not isinstance(snap, dict) or snap.get("schema") != SNAPSHOT_SCHEMA:
        raise ReplyDebtSourceUnavailable(f"{channel}_snapshot_malformed", "unknown snapshot schema")
    status = snap.get("status")
    generated = _parse_iso(snap.get("generated_at"))
    if generated is None:
        raise ReplyDebtSourceUnavailable(f"{channel}_snapshot_malformed", "no generated_at")
    if status == "absent":
        return None
    if status != "ok":
        raise ReplyDebtSourceUnavailable(
            f"{channel}_not_readable", str(snap.get("reason") or status or "unknown")[:200]
        )
    age_h = (now - generated).total_seconds() / 3600.0
    limit_h = max_age_hours if max_age_hours is not None else _snapshot_max_age_hours()
    if age_h > limit_h:
        raise ReplyDebtSourceUnavailable(
            f"{channel}_snapshot_stale", f"snapshot is {age_h:.1f}h old (limit {limit_h:g}h)"
        )
    return snap


@dataclass
class SourceRead:
    """Threads from one channel plus what its rules excluded, by reason."""

    channel: str
    threads: list[Thread] = field(default_factory=list)
    excluded: dict[str, int] = field(default_factory=dict)
    # Institution (school) mail: classified before the automated filter, kept
    # out of reply debt, never dropped. The Parent skills read this list.
    school: list[Thread] = field(default_factory=list)
    # Which frequency-rule mode applied: "on" or "off:no_outbound_rows".
    frequency_mode: str = ""

    def drop(self, reason: str) -> None:
        self.excluded[reason] = self.excluded.get(reason, 0) + 1


# ---------------------------------------------------------------------------
# WhatsApp
# ---------------------------------------------------------------------------

_JID_PHONE = re.compile(r"^(\d{7,15})(?::\d+)?@(?:s\.whatsapp\.net|c\.us)$")
_JID_HIDDEN = re.compile(r"^[^@\s]+@lid$")
# A WhatsApp @mention is written into the message text as "@<digits>".
_MENTION = re.compile(r"(?<![\w@])@(\d{7,15})\b")


def whatsapp_handle(jid: Optional[str]) -> str:
    """The Contacts-matchable handle for a WhatsApp JID: ``+<digits>`` for a
    phone JID, the hidden-number marker for an ``@lid`` id, else ``""``."""
    j = (jid or "").strip().lower()
    m = _JID_PHONE.match(j)
    if m:
        return "+" + m.group(1)
    if _JID_HIDDEN.match(j):
        return _rd.WHATSAPP_HIDDEN_NUMBER_PREFIX + "member"
    return ""


def whatsapp_mentions(text: str) -> list[str]:
    """Every ``+<digits>`` handle @mentioned in a message."""
    return ["+" + d for d in _MENTION.findall(text or "")]


def whatsapp_privacy(row: dict) -> str:
    """Operator level, then the CM048 WhatsApp label ladder, else L2."""
    from . import channel_adapter as ca
    from . import privacy as _privacy

    explicit = row.get("privacy_level")
    if isinstance(explicit, str) and explicit.strip():
        return _privacy.normalise(explicit)
    contact = ca._whatsapp_label_normalised(row.get("contact_label"))
    group = ca._whatsapp_label_normalised(row.get("group_label"))
    if contact in ca._WHATSAPP_L3_CONTACT_LABELS or group in ca._WHATSAPP_L3_CONTACT_LABELS:
        return "L3"
    if group in ca._WHATSAPP_L1_GROUP_LABELS:
        return "L1"
    return "L2"


def _is_carded(directory, handle: str) -> bool:
    return bool(directory is not None and handle and directory.name_for(handle))


def whatsapp_threads(
    snap: dict,
    *,
    directory=None,
    now: Optional[datetime] = None,
    lookback_days: int = 90,
) -> SourceRead:
    """Normalise a WhatsApp snapshot into threads, applying the WhatsApp
    rules. ``directory`` (a ``HandleDirectory``) answers "is this the owner"
    and "is this carded"; without it no group message can be shown to name
    the owner, so none is considered (counted)."""
    now = now or datetime.now(timezone.utc)
    out = SourceRead("whatsapp")
    for row in snap.get("threads") or []:
        if not isinstance(row, dict):
            continue
        last = row.get("last") or {}
        ts = _parse_iso(last.get("timestamp"))
        text = (last.get("text") or "").strip()
        if ts is None or not text:
            out.drop("no_text")
            continue
        if (now - ts).days > lookback_days:
            out.drop("older_than_lookback")
            continue
        is_owner = bool(last.get("is_from_me"))
        is_group = bool(row.get("is_group"))
        addresses_owner = False
        if is_group:
            if is_owner:
                author = ""
            else:
                author = whatsapp_handle(last.get("author_jid"))
                mentioned = whatsapp_mentions(text)
                addresses_owner = bool(
                    directory is not None
                    and any(directory.is_owner(h) for h in mentioned)
                )
                if not addresses_owner:
                    out.drop("group_not_addressed_to_owner")
                    continue
        else:
            author = whatsapp_handle(row.get("counterpart_jid"))
            if not author:
                out.drop("no_counterpart")
                continue
        if not is_owner and _scam.looks_like_payment_scam(text):
            out.drop("payment_scam")
            continue
        if (
            not is_owner
            and _scam.is_payment_action(text)
            and not bool(row.get("owner_wrote"))
            and not _is_carded(directory, author)
        ):
            out.drop("payment_ask_from_stranger")
            continue
        out.threads.append(
            Thread(
                thread_id=f"whatsapp:{row.get('chat_id')}",
                channel="whatsapp",
                messages=(
                    Message(
                        sender="me" if is_owner else author,
                        text=text,
                        timestamp=ts,
                        is_from_owner=is_owner,
                    ),
                ),
                privacy_level=whatsapp_privacy(row),
                is_group=is_group,
                # Never a push name, never a group subject: the name comes
                # from the Contacts card in identify_threads, or nowhere.
                counterpart_name="",
                addresses_owner=addresses_owner,
            )
        )
    return out


# ---------------------------------------------------------------------------
# Email
# ---------------------------------------------------------------------------

_QUOTE_HEADER = re.compile(
    r"^\s*(?:on .{1,200} wrote:|-{2,}\s*original message\s*-{2,}|"
    r"-{2,}\s*forwarded message\s*-{2,}|begin forwarded message:|"
    r"from:\s.*@.*|sent from my \w+)\s*$",
    re.IGNORECASE,
)
_SIGNATURE = re.compile(r"^\s*--\s*$")
_BULK_PRECEDENCE = frozenset({"bulk", "list", "junk", "auto_reply", "auto-reply"})


def email_new_text(body: str) -> str:
    """The part of an email the sender just wrote: stop at the first quoted
    line, quote header ("On ... wrote:"), forwarded block or signature."""
    kept: list[str] = []
    for line in (body or "").replace("\r\n", "\n").split("\n"):
        if line.lstrip().startswith(">") or _QUOTE_HEADER.match(line) or _SIGNATURE.match(line):
            break
        kept.append(line)
    return " ".join(" ".join(kept).split())


def _header(row: dict, name: str) -> str:
    vals = _scam._header_values(row, name)
    return vals[0].strip() if vals else ""


# A calendar system's own mail: "Invitation: ...", "Updated invitation: ...",
# "Accepted: ...", "Canceled event: ...". Its body asks "Going?" and offers
# Yes/No/Maybe buttons; that is an RSVP the calendar takes, not a reply owed.
_CALENDAR_SUBJECT = re.compile(
    r"^\s*(?:updated\s+invitation|invitation|accepted|declined|tentatively\s+accepted"
    r"|canceled|cancelled|canceled\s+event|cancelled\s+event)\s*:",
    re.IGNORECASE,
)


def is_calendar_invite(row: dict) -> bool:
    """A calendar-system message (iCalendar part, or an invitation subject)."""
    if "text/calendar" in _header(row, "content-type").lower():
        return True
    if _CALENDAR_SUBJECT.match(str(row.get("subject") or "")):
        return True
    return "BEGIN:VCALENDAR" in str((row.get("last") or {}).get("text") or "")


# Dates in a templated subject: month and weekday names, numbers.
_DATE_WORDS = frozenset({
    "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "sept", "oct",
    "nov", "dec", "january", "february", "march", "april", "june", "july",
    "august", "september", "october", "november", "december",
    "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun",
    "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
})


# "22nd", "1st", "3rd", "4th": the suffix is part of the date, not a word.
_ORDINAL = re.compile(r"(\d)(?:st|nd|rd|th)\b")


def _template_key(row: dict) -> Optional[tuple[str, str]]:
    """(sender, subject with dates, numbers and punctuation removed), or None.

    "Your digest 12 Nov" and "Your digest 29 Oct" share a key: a mailing
    platform's dated template is the same message sent again."""
    sender = ((row.get("last") or {}).get("from_address") or "").strip().lower()
    subject = _ORDINAL.sub(r"\1", str(row.get("subject") or "").lower())
    words = re.sub(r"[\W\d_]+", " ", subject).split()
    words = [w for w in words if w not in _DATE_WORDS]
    if not sender or not words:
        return None
    return sender, " ".join(words)


logger = logging.getLogger(__name__)

TEMPLATE_WINDOW_DAYS = 30
TEMPLATE_MIN_COUNT = 3


def owner_written_to(rows: list) -> set[str]:
    """Every address the owner has sent to: the to and cc of each outbound
    message in the snapshot. A sender in this set has a human history with
    the owner, so no bulk heuristic may treat them as a template."""
    out: set[str] = set()
    for row in rows:
        if not isinstance(row, dict):
            continue
        last = row.get("last") or {}
        if not last.get("is_from_me"):
            continue
        for addr in list(last.get("to") or []) + list(last.get("cc") or []):
            if isinstance(addr, str) and addr.strip():
                out.add(addr.strip().lower())
    return out


def repeated_template_rows(rows: list) -> set[int]:
    """Indexes of inbound rows that sit in a 30-day run of three or more
    messages from one sender with the same templated subject."""
    by_key: dict[tuple[str, str], list[tuple[int, datetime]]] = {}
    for i, row in enumerate(rows):
        if not isinstance(row, dict):
            continue
        last = row.get("last") or {}
        if last.get("is_from_me"):
            continue
        key = _template_key(row)
        ts = _parse_iso(last.get("timestamp"))
        if key is None or ts is None:
            continue
        by_key.setdefault(key, []).append((i, ts))
    window = TEMPLATE_WINDOW_DAYS * 86400
    out: set[int] = set()
    for members in by_key.values():
        for i, ts in members:
            near = sum(1 for _, other in members if abs((other - ts).total_seconds()) <= window)
            if near >= TEMPLATE_MIN_COUNT:
                out.add(i)
    return out


def has_outbound_rows(rows: list) -> bool:
    """True when the feed carries at least one message the owner sent.

    Every "has the owner written to this sender?" waiver reads outbound rows.
    With none, the waiver is empty for everybody and a frequency rule would
    treat a real person the owner writes to as a stranger. So frequency rules
    run only when this is true."""
    return any(
        isinstance(r, dict) and bool((r.get("last") or {}).get("is_from_me"))
        for r in rows
    )


# ---- institution (school) mail ----------------------------------------------

# Sender domains: an education label (.edu, .sch, .edu.hk, .sch.uk, .school)
# or a known school platform.
_SCHOOL_DOMAIN = re.compile(
    r"(?:^|\.)(?:edu|sch|school|schools)(?:\.[a-z]{2})?$", re.IGNORECASE
)
_SCHOOL_PLATFORMS = frozenset({
    "parentmail.co.uk", "parentpay.com", "parentsapp.com", "schoolsbuddy.com",
    "seesaw.me", "classdojo.com", "classroom.google.com", "schoology.com",
    "isams.cloud", "bromcom.com", "arbor-education.com", "groupcall.com",
    "weduc.co.uk", "tapestry.info", "showbie.com", "schoolcomms.com",
    "parentscloud.com",
})
# Content cues. One alone proves nothing: two distinct ones are needed, and
# only on mail that already looks automated.
_SCHOOL_CUES = (
    re.compile(r"\bparent communications?\b", re.I),
    re.compile(r"\bschool\b", re.I),
    re.compile(r"\b(?:pupils?|students?)\b", re.I),
    re.compile(r"\b(?:headteacher|head teacher|principal|form tutor|year team)\b", re.I),
    re.compile(r"\b(?:half term|parents'? evening|PTA|school bus)\b", re.I),
    re.compile(r"\b(?:year|grade)\s*\d{1,2}\b", re.I),
)
_AUTOMATED_FOOTER = re.compile(
    r"this is an automated|do not reply|please do not respond|unsubscribe", re.I
)


def _sender_domain(row: dict) -> str:
    sender = ((row.get("last") or {}).get("from_address") or "").strip().lower()
    return sender.rpartition("@")[2]


def school_signal(row: dict) -> str:
    """Why this looks like institution mail: ``platform``, ``domain``,
    ``content`` or ``""``. Content counts only on mail that already carries an
    automated footer or list header, so a friend writing about their child's
    school is never swept in."""
    dom = _sender_domain(row)
    if dom:
        if any(dom == p or dom.endswith("." + p) for p in _SCHOOL_PLATFORMS):
            return "platform"
        if _SCHOOL_DOMAIN.search(dom):
            return "domain"
    text = str((row.get("last") or {}).get("text") or "")
    if (
        _AUTOMATED_FOOTER.search(text)
        or _header(row, "list-unsubscribe")
        or _header(row, "list-id")
    ):
        hay = str(row.get("subject") or "") + "\n" + text
        if sum(1 for c in _SCHOOL_CUES if c.search(hay)) >= 2:
            return "content"
    return ""


def email_automated_reason(row: dict, *, owner_wrote_to: bool = False) -> str:
    """Why this message is not from a human writing personally, or ``""``.

    ``owner_wrote_to`` is accepted for the caller's signature only: every
    automated signal here applies whether or not the owner has written to the
    sender. The repeated-template rule is the one that is waived for them."""
    junk = _scam.junk_reason(row)
    if junk:
        return f"junk:{junk}"
    if is_calendar_invite(row):
        return "calendar_invite"
    if _header(row, "list-id"):
        return "mailing_list"
    if _header(row, "list-unsubscribe"):
        return "bulk"
    auto = _header(row, "auto-submitted").lower()
    if auto and auto != "no":
        return "automated"
    if _header(row, "precedence").lower() in _BULK_PRECEDENCE:
        return "bulk"
    sender = ((row.get("last") or {}).get("from_address") or "").strip().lower()
    from . import handle_identity as hi
    from . import privacy as _privacy

    if hi.classify_handle(sender) == hi.KIND_NO_REPLY:
        return "no_reply"
    if _privacy.infer_for_email_addresses([sender]) == "L1":
        return "marketing"
    return ""


def email_privacy(row: dict) -> str:
    """Operator level, then the CM048 email ladder over every address on the
    message (L3 for legal / medical / financial / government), else L2."""
    from . import privacy as _privacy

    explicit = row.get("privacy_level")
    if isinstance(explicit, str) and explicit.strip():
        return _privacy.normalise(explicit)
    last = row.get("last") or {}
    addrs = [last.get("from_address") or ""] + list(last.get("to") or []) + list(last.get("cc") or [])
    if _privacy.infer_for_email_addresses([a for a in addrs if a]) == "L3":
        return "L3"
    return "L2"


def email_threads(
    snap: dict,
    *,
    directory=None,
    now: Optional[datetime] = None,
    lookback_days: int = 90,
) -> SourceRead:
    """Normalise an email snapshot into threads, applying the email rules.

    The owner's addresses are the directory's owner handles plus the
    addresses the feed was configured with (``owner_addresses``)."""
    now = now or datetime.now(timezone.utc)
    out = SourceRead("email")
    configured = {
        a.strip().lower() for a in (snap.get("owner_addresses") or []) if isinstance(a, str) and a.strip()
    }

    def is_owner(addr: str) -> bool:
        a = (addr or "").strip().lower()
        if not a:
            return False
        return a in configured or bool(directory is not None and directory.is_owner(a))

    all_rows = snap.get("threads") or []
    # The frequency rule (repeated template) waives senders the owner has
    # written to. With no outbound rows that waiver is empty for everyone, so
    # the rule could drop a real person: it runs only when the feed has them.
    frequency_on = has_outbound_rows(all_rows)
    out.frequency_mode = "on" if frequency_on else "off:no_outbound_rows"
    logger.info("reply_debt email: frequency rules %s", out.frequency_mode)
    repeated = repeated_template_rows(all_rows) if frequency_on else set()
    written_to = owner_written_to(all_rows)
    for idx, row in enumerate(all_rows):
        if not isinstance(row, dict):
            continue
        last = row.get("last") or {}
        ts = _parse_iso(last.get("timestamp"))
        if ts is None:
            out.drop("no_timestamp")
            continue
        if (now - ts).days > lookback_days:
            out.drop("older_than_lookback")
            continue
        sender = (last.get("from_address") or "").strip().lower()
        from_owner = bool(last.get("is_from_me")) or is_owner(sender)
        text = email_new_text(last.get("text") or "")
        if not from_owner:
            # Institution mail is classified BEFORE every filter that could
            # drop it unseen: the owner-address test (school mail is often
            # BCC'd) and the automated filter (its footer test drops 68% of
            # it). It goes to its own list. A school person asking something
            # (no robot signal, a request) still reaches reply debt, as does
            # anyone the owner has written to. Mail in a junk mailbox is junk.
            wrote_to = sender in written_to
            if not wrote_to and not _scam.junk_reason(row) and school_signal(row):
                robotic = bool(email_automated_reason(row) or _AUTOMATED_FOOTER.search(text))
                asks = _rd.owed_verdict(Thread(
                    thread_id="probe", channel="email",
                    messages=(Message(sender=sender, text=text, timestamp=ts, is_from_owner=False),),
                ))[0] == "yes"
                if robotic or not asks:
                    out.school.append(Thread(
                        thread_id=f"email:{row.get('thread_id')}",
                        channel="email",
                        messages=(Message(sender=sender, text=text, timestamp=ts, is_from_owner=False),),
                        privacy_level=email_privacy(row),
                        is_group=False,
                        counterpart_name="",
                    ))
                    out.drop("school_comms")
                    continue
            if not configured and directory is None:
                # Nobody can say which address is the owner's, so "addressed
                # to the owner" cannot be decided. Counted, never guessed.
                out.drop("owner_address_unknown")
                continue
            if not any(is_owner(a) for a in (last.get("to") or [])):
                out.drop("not_to_owner")
                continue
            wrote_to = sender in written_to
            why = email_automated_reason(row, owner_wrote_to=wrote_to)
            if why:
                out.drop(why)
                continue
            if idx in repeated and not wrote_to:
                out.drop("repeated_template")
                continue
            if not text:
                out.drop("no_text")
                continue
            if _scam.looks_like_payment_scam(text) or _scam.looks_like_payment_scam(
                str(row.get("subject") or "")
            ):
                out.drop("payment_scam")
                continue
            if (
                _scam.is_payment_action(text)
                and not bool(row.get("owner_wrote"))
                and not _is_carded(directory, sender)
            ):
                out.drop("payment_ask_from_stranger")
                continue
            probe = Thread(
                thread_id="probe", channel="email",
                messages=(Message(sender=sender, text=text, timestamp=ts, is_from_owner=False),),
            )
            if _rd.owed_verdict(probe)[0] != "yes":
                out.drop("no_question_or_request")
                continue
        out.threads.append(
            Thread(
                thread_id=f"email:{row.get('thread_id')}",
                channel="email",
                messages=(
                    Message(
                        sender="me" if from_owner else sender,
                        text=text,
                        timestamp=ts,
                        is_from_owner=from_owner,
                    ),
                ),
                privacy_level=email_privacy(row),
                is_group=False,
                # Never the From display name: the name comes from the
                # Contacts card for this address, or the thread is unnamed.
                counterpart_name="",
            )
        )
    return out


Loader = Callable[..., SourceRead]


def load_channel(
    channel: str,
    *,
    directory=None,
    snapshot: Optional[Path] = None,
    now: Optional[datetime] = None,
    lookback_days: int = 90,
    max_age_hours: Optional[float] = None,
) -> SourceRead:
    """Read one channel end to end: connection, snapshot, rules. Raises
    ``ReplyDebtSourceUnavailable`` (``<channel>_not_connected`` when the
    install never set it up)."""
    state, why = connection_state(channel)
    if state == "not_connected":
        raise ReplyDebtSourceUnavailable(f"{channel}_not_connected", why)
    if state == "unknown":
        raise ReplyDebtSourceUnavailable(f"{channel}_connection_unknown", why)
    snap = read_snapshot(channel, path=snapshot, now=now, max_age_hours=max_age_hours)
    if snap is None:
        return SourceRead(channel)
    rules = whatsapp_threads if channel == "whatsapp" else email_threads
    return rules(snap, directory=directory, now=now, lookback_days=lookback_days)


__all__ = [
    "CHANNELS",
    "FEED_LABELS",
    "SNAPSHOT_SCHEMA",
    "SourceRead",
    "connection_state",
    "email_automated_reason",
    "email_new_text",
    "email_privacy",
    "email_threads",
    "load_channel",
    "read_snapshot",
    "snapshot_path",
    "whatsapp_handle",
    "whatsapp_mentions",
    "whatsapp_privacy",
    "whatsapp_threads",
]
