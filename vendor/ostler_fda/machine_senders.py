"""Machine senders are not People (DMG #27).

The walk's People list showed calendar notification senders, no-reply senders
and mailing lists as "Unknown contact" People. Measured read-only on the walk
box: ``calendar_fda`` minted People for calendar SYSTEM addresses (the shared
calendar / resource / iCloud invitation addresses Google and Apple put on an
invite as attendees), and ``apple_mail_fda`` minted People for senders on a
bank's notification subdomain. Neither has a human behind it.

TWO KINDS OF EVIDENCE, and which one decides
============================================
1. The ADDRESS: a well-known no-reply local part (no-reply, do-not-reply,
   mailer-daemon, postmaster, bounces, notifications, calendar-notification),
   or a calendar-system / notification domain. ``noreply_reason``.
2. The HEADERS: List-Id, List-Unsubscribe, Auto-Submitted (anything but
   "no") and Precedence bulk/list/junk. ``header_reason`` takes a header
   mapping. The Mail Envelope Index stores the first two as per-message
   columns (``list_id_hash``, ``unsubscribe_type``) and so they are read for
   every message. It does NOT store Auto-Submitted or Precedence: on the
   Envelope Index path those two are NOT INSTRUMENTED (they would need the
   .emlx bodies). ``header_reason`` applies all four wherever a header
   mapping exists.

A HUMAN WHO REPLIED IS KEPT. A real person can write from an "info@" style
address (a sole trader, a small practice). The existing role-address rule
drops every such address. An address is a CORRESPONDENT, and kept, when the
owner has written to it (it is a To/Cc of Sent mail) or when it wrote a
NON-LIST message into a conversation the owner has also written in. A
correspondent is never classed machine by the role-word rule, and never by
list evidence on its other mail. The strict no-reply local parts are the one
exception: nobody reads a reply sent to a no-reply address.

A sender is MACHINE when it is not a correspondent and either its address
says so (``noreply_reason``) or every message it sent carried a list header.
"""
from __future__ import annotations

import json
import logging
import re
import sqlite3
from collections import defaultdict
from pathlib import Path
from typing import Dict, Mapping, Optional, Set

logger = logging.getLogger(__name__)

MACHINE_SENDERS_FILE = "machine_senders.json"

# Strict: an address with one of these local parts never receives a read reply.
_NOREPLY_LOCAL_RE = re.compile(
    r"(^|[._+-])(no[._-]?reply|do[._-]?not[._-]?reply|mailer[._-]?daemon|"
    r"postmaster|bounces?|notifications?|notify|calendar[._-]?notifications?)([._+-]|$)"
)

# Calendar SYSTEM addresses. An invite lists these as attendees; they are a
# calendar or a room, not a person.
_CALENDAR_SYSTEM_DOMAINS = (
    "group.calendar.google.com",
    "resource.calendar.google.com",
    "group.v.calendar.google.com",
    "import.calendar.google.com",
    "calendar.google.com",
    "imip.me.com",
    "calendar.icloud.com",
)

# A domain whose FIRST label names it a sending system.
_NOTIFICATION_FIRST_LABELS = frozenset({
    "notification", "notifications", "notify", "alert", "alerts",
    "bounce", "bounces", "noreply", "no-reply", "mailer",
})

_BULK_PRECEDENCE = frozenset({"bulk", "list", "junk"})


def _norm(addr: Optional[str]) -> str:
    a = (addr or "").strip().lower()
    if "<" in a and ">" in a:
        a = a.split("<", 1)[1].split(">", 1)[0].strip()
    if a.startswith("mailto:"):
        a = a[len("mailto:"):]
    return a if ("@" in a and "." in a.split("@", 1)[1]) else ""


def noreply_reason(addr: Optional[str]) -> Optional[str]:
    """Why this ADDRESS is a machine, or None. Never returns a value from the
    address itself, only a category."""
    a = _norm(addr)
    if not a:
        return None
    local, _, domain = a.partition("@")
    if any(domain == d or domain.endswith("." + d) for d in _CALENDAR_SYSTEM_DOMAINS):
        return "calendar-system"
    if domain.split(".", 1)[0] in _NOTIFICATION_FIRST_LABELS:
        return "notification-domain"
    if _NOREPLY_LOCAL_RE.search(local.split("+", 1)[0]):
        return "no-reply"
    return None


# ORGANISATION MAILBOXES (v1.0.107 walk, candidate #28). Two organisations
# reached the People list: one wrote from `<brand>@<brand's domain>`, the
# other from an address on its own brand domain under a one-word name. Neither
# local part is a no-reply word. The shared SHAPE is a sender named after its
# own domain, so this reads the address and never a list of companies. Same
# rule as CM044 compiler/pwg_data.py is_organisation_mailbox and CM041
# people_rules._address_is_automated; kept local because ostler_fda must not
# import either.
_BULK_SUBDOMAIN_LABELS = frozenset({
    "e", "em", "email", "emails", "news", "newsletter", "newsletters",
    "notification", "notifications", "notify", "alerts", "mailer", "mailing",
    "bounce", "bounces", "marketing", "campaign", "campaigns", "updates",
    "reply", "noreply", "no-reply", "donotreply", "info", "communications",
    "comms", "go", "click", "events",
})
_BRAND_LABEL_AFFIXES = frozenset({
    "mail", "email", "news", "notify", "notifications", "events", "app",
    "hq", "team", "updates", "alerts", "invites", "calendar",
})
_COMMON_SECOND_LEVEL = frozenset({"com", "co", "org", "net", "gov", "edu", "ac", "or", "ne"})
_AUTOMATION_LOCAL_RE = re.compile(
    r"(^|[._+-])(alerts?|newsletters?|digest|invitations?|unsubscribe)([._+-]|$)"
)


def _squash(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", (value or "").lower())


def domain_brand_names(domain: str) -> Set[str]:
    """Every way a domain spells its owner's name: each label above the TLD
    (and a co.uk-style second level) except bulk sub-domain labels, a brand
    with a mail-ish affix (`glimmer-mail`, `lanternhq`), and a short domain
    read as one word (`gl.immer` -> "glimmer")."""
    labels = [l for l in (domain or "").lower().strip(".").split(".") if l]
    if len(labels) < 2:
        return set()
    body = labels[:-1]
    if len(body) >= 2 and body[-1] in _COMMON_SECOND_LEVEL:
        body = body[:-1]
    names: Set[str] = set()
    for label in body:
        if label in _BULK_SUBDOMAIN_LABELS or label in ("www", "mail"):
            continue
        names.add(_squash(label))
        toks = [t for t in label.split("-") if t]
        if len(toks) > 1 and all(t in _BRAND_LABEL_AFFIXES for t in toks[1:]):
            names.add(_squash(toks[0]))
        for affix in _BRAND_LABEL_AFFIXES:
            if label.endswith(affix) and len(label) - len(affix) >= 3:
                names.add(_squash(label[: -len(affix)]))
    names.add(_squash("".join(labels)))
    return {n for n in names if len(n) >= 3}


def organisation_reason(addr: Optional[str]) -> Optional[str]:
    """Why this ADDRESS is an organisation's mailbox, or None.

    NOT strict: a correspondent (the owner wrote to it, or it wrote into a
    thread the owner wrote in) is a human and is kept by every caller, the
    same as the role-word rule. a first.last local part at the brand matches nothing.
    """
    a = _norm(addr)
    if not a:
        return None
    local, _, domain = a.rpartition("@")
    local = local.split("+", 1)[0]
    if _AUTOMATION_LOCAL_RE.search(local):
        return "automation-local"
    bare = _squash(re.sub(r"[-._]?\d+$", "", local))
    if bare and bare in domain_brand_names(domain):
        return "brand-mailbox"
    labels = domain.split(".")
    sub = labels[:-2]
    if len(labels) > 2 and labels[-2] in _COMMON_SECOND_LEVEL:
        sub = labels[:-3]
    if any(l in _BULK_SUBDOMAIN_LABELS for l in sub):
        return "bulk-subdomain"
    return None


def header_reason(headers: Mapping[str, str]) -> Optional[str]:
    """Why a message with these headers is machine mail, or None."""
    h = {str(k).lower(): (v or "").strip() for k, v in (headers or {}).items()}
    if h.get("list-id"):
        return "list-id"
    if h.get("list-unsubscribe"):
        return "list-unsubscribe"
    auto = h.get("auto-submitted", "").lower()
    if auto and auto != "no":
        return "auto-submitted"
    if h.get("precedence", "").lower() in _BULK_PRECEDENCE:
        return "precedence"
    return None


def _is_sent(url: Optional[str]) -> bool:
    from urllib.parse import unquote
    leaf = unquote((url or "").rstrip("/").rsplit("/", 1)[-1]).strip().lower()
    return leaf in {"sent", "sent messages", "sent items", "sent mail"}


def mail_evidence(envelope_index: Path):
    """(per_sender, correspondents). ``per_sender[addr] = [messages, list_flagged]``
    for mail NOT in a Sent mailbox. ``correspondents`` is every address the
    owner wrote to, plus every address that wrote a non-list message into a
    conversation holding an owner Sent message."""
    con = sqlite3.connect(f"file:{envelope_index}?immutable=1", uri=True)
    try:
        mailboxes = {r[0]: r[1] for r in con.execute("SELECT ROWID, url FROM mailboxes")}
        cols = {r[1] for r in con.execute("PRAGMA table_info(messages)")}
        lst = ("COALESCE(m.list_id_hash, 0) <> 0" if "list_id_hash" in cols else "0") + " OR " + (
            "COALESCE(m.unsubscribe_type, 0) <> 0" if "unsubscribe_type" in cols else "0")
        conv = "m.conversation_id" if "conversation_id" in cols else "NULL"
        msgs = con.execute(
            f"SELECT m.ROWID, a.address, m.mailbox, ({lst}), {conv} "
            "FROM messages m LEFT JOIN addresses a ON m.sender = a.ROWID"
        ).fetchall()
        rcpt = con.execute(
            "SELECT r.message, a.address FROM recipients r JOIN addresses a ON r.address = a.ROWID"
        ).fetchall()
    finally:
        con.close()
    sent_ids = {mid for mid, _s, mb, _l, _c in msgs if _is_sent(mailboxes.get(mb))}
    owner_convs = {c for mid, _s, _mb, _l, c in msgs if mid in sent_ids and c}
    correspondents: Set[str] = {_norm(a) for mid, a in rcpt if mid in sent_ids and _norm(a)}
    per_sender: Dict[str, list] = defaultdict(lambda: [0, 0])
    for mid, sender, _mb, is_list, c in msgs:
        s = _norm(sender)
        if not s or mid in sent_ids:
            continue
        per_sender[s][0] += 1
        per_sender[s][1] += 1 if is_list else 0
        if c and c in owner_convs and not is_list:
            correspondents.add(s)
    return dict(per_sender), correspondents


def classify(per_sender: Mapping[str, list], correspondents: Set[str]) -> Dict[str, str]:
    """sender -> machine reason, for machine senders only."""
    out: Dict[str, str] = {}
    for s, (n, flagged) in per_sender.items():
        why = noreply_reason(s)
        if why == "no-reply" or why == "calendar-system":
            out[s] = why                       # strict: kept even if replied to
            continue
        if s in correspondents:
            continue
        why = why or organisation_reason(s)
        if why:
            out[s] = why
        elif n and flagged == n:
            out[s] = "list-mail"
    return out


def collect(output_dir: Path, *, envelope_index: Optional[Path] = None) -> dict:
    """Write ``machine_senders.json`` (machine senders and correspondents).
    Returns counts only; never raises."""
    try:
        if envelope_index is None:
            from .apple_mail import _find_envelope_index
            envelope_index = _find_envelope_index()
        per_sender, correspondents = mail_evidence(envelope_index)
    except Exception as exc:  # noqa: BLE001 -- reported, never raised
        return {"status": f"unreadable:{type(exc).__name__}"}
    machine = classify(per_sender, correspondents)
    (Path(output_dir) / MACHINE_SENDERS_FILE).write_text(json.dumps(
        {"machine": machine, "correspondents": sorted(correspondents)}, indent=2, sort_keys=True))
    reasons: Dict[str, int] = defaultdict(int)
    for r in machine.values():
        reasons[r] += 1
    counts = {"status": "ok", "senders": len(per_sender), "machine": len(machine),
              "correspondents": len(correspondents), "by_reason": dict(reasons)}
    logger.info("[ok] Machine senders: %s", json.dumps(counts, sort_keys=True))
    return counts


def load(fda_dir: Path):
    """(machine_set, correspondent_set) as written by ``collect``; empty sets
    when absent, so nothing is suppressed without evidence."""
    try:
        data = json.loads((Path(fda_dir) / MACHINE_SENDERS_FILE).read_text())
    except (OSError, ValueError):
        return set(), set()
    return ({_norm(a) for a in (data.get("machine") or {}) if _norm(a)},
            {_norm(a) for a in (data.get("correspondents") or []) if _norm(a)})
