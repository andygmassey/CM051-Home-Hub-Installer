"""Render a WhatsApp chat into a CM048 transcript + metadata.

Two outputs per in-tier chat (mirrors ``email_source.threader`` and
``spoken_source.renderer``):

  - A cleaned, speaker-labelled markdown transcript. Operator-sent
    messages render as "You"; everyone else resolves through a
    JID -> display-name map the caller supplies (from a contacts.yaml),
    falling back to the bare JID's phone-number local part.

  - A CM048 metadata dict matching the ``_whatsapp_adapter``
    expectations in CM048 ``channel_adapter.py``: ``channel="whatsapp"``,
    participants as ``id`` / ``display`` / ``role`` dicts, the extra
    keys the adapter folds into frontmatter (``chat_jid``, ``chat_type``,
    ``is_group_chat``, ``group_subject``, ``group_label``,
    ``contact_label``), ISO ``started_at`` / ``ended_at``, and an
    optional ``privacy_level`` driving the L1/L2/L3 ladder.

The tier label from the classifier carries through as the privacy
driver: T3 never reaches here (it is skipped in the reader), and a
family / partner / sensitive ``contact_label`` or ``group_label`` (set
by the operator's contacts.yaml) escalates the thread to L3 via CM048's
own ladder. We do not auto-detect partner / family threads from
content; the label is operator-driven, matching CM048's documented
"default-ladder per source with a single override hook" contract.

No real-person data is hard-coded here. Display names + privacy labels
come from the caller's contacts map.
"""
from __future__ import annotations

import hashlib
import re
from typing import Callable, Optional

from .reader import WhatsAppConversation

_SLUG_RE = re.compile(r"[^a-z0-9]+")

# JID suffixes (mirror ostler_fda.whatsapp_history) so the renderer can
# present a readable speaker label from a raw "<number>@s.whatsapp.net".
_JID_PERSON_SUFFIX = "@s.whatsapp.net"
_JID_GROUP_SUFFIX = "@g.us"


def _slug(text: str, max_len: int = 40) -> str:
    cleaned = _SLUG_RE.sub("-", (text or "").lower()).strip("-")
    return cleaned[:max_len].rstrip("-") or "conversation"


def _short_hash(*parts: str) -> str:
    payload = "\x1f".join(parts)
    return hashlib.sha1(payload.encode("utf-8")).hexdigest()[:8]


def _jid_local_part(jid: Optional[str]) -> str:
    """A readable fallback label for a JID with no resolved name.

    ``447700900123@s.whatsapp.net`` -> ``447700900123``. Never the raw
    suffix. Empty / None -> "Unknown"."""
    if not jid:
        return "Unknown"
    for suffix in (_JID_PERSON_SUFFIX, _JID_GROUP_SUFFIX):
        if jid.endswith(suffix):
            return jid[: -len(suffix)] or "Unknown"
    return jid


def _iso(dt) -> str:
    if dt is None:
        return ""
    return dt.isoformat().replace("+00:00", "Z")


def _title_for(
    conv: WhatsAppConversation,
    name_for_jid: Callable[[str], Optional[str]],
) -> str:
    """A human title for the transcript heading + slug.

    Group: the group subject if known, else "Group chat". DM: the
    partner's resolved name, else their number."""
    if conv.is_group:
        return conv.group_subject or "Group chat"
    partner = conv.chat.contact_jid
    resolved = name_for_jid(partner) if partner else None
    return resolved or _jid_local_part(partner)


def conversation_id_for(conv: WhatsAppConversation) -> str:
    """Build a stable ``YYYY-MM-DD_<slug>_<short-hash>`` id.

    Deterministic in the chat id + first-message time so a re-read of
    the same chat produces the same conversation id (and therefore the
    same CM048 state dir + bundle folder), keeping re-processing
    idempotent. The slug uses the chat id (not a name) so the id never
    leaks a resolved person name into a folder path.
    """
    started = conv.started_at
    date_str = started.date().isoformat() if started else "0000-00-00"
    return (
        f"{date_str}_whatsapp_"
        f"{_short_hash(conv.chat_id, _iso(started))}"
    )


def render_transcript(
    conv: WhatsAppConversation,
    *,
    name_for_jid: Callable[[str], Optional[str]],
    user_display_name: str = "You",
) -> str:
    """Render a cleaned, speaker-labelled markdown transcript.

    Opens with a ``# <title>`` heading, then one block per message:

        **<Speaker>** (ISO-ts):
        <text>

    Operator-sent messages render as ``user_display_name`` ("You").
    """
    lines: list[str] = []
    lines.append(f"# {_title_for(conv, name_for_jid)}")
    lines.append("")
    for utt in conv.utterances:
        if utt.is_from_me:
            speaker = user_display_name
        else:
            speaker = (
                (name_for_jid(utt.author_jid) if utt.author_jid else None)
                or _jid_local_part(utt.author_jid)
            )
        ts = _iso(utt.timestamp)
        text = utt.text.strip() or "[no text]"
        header = f"**{speaker}** ({ts})" if ts else f"**{speaker}**"
        lines.append(f"{header}:")
        lines.append(text)
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _participants_metadata(
    conv: WhatsAppConversation,
    name_for_jid: Callable[[str], Optional[str]],
    user_display_name: str,
) -> list[dict]:
    """Build the CM048 participants list (id / display / role dicts).

    The operator is role ``"user"`` with id ``"user"``. Every other
    participant JID (the DM partner for T1, the active member list for
    T2) becomes role ``"other"`` with a slugged id, carrying the
    resolved display name. The participant JIDs come from the
    classifier's verdict, not re-derived here.
    """
    participants: list[dict] = [
        {"id": "user", "display": user_display_name, "role": "user"}
    ]
    seen: set[str] = set()
    # The classifier populates `participants` (T2 members) and
    # `contact_jid` (T1 partner). Union them.
    jids: list[str] = list(conv.chat.participants)
    if conv.chat.contact_jid and conv.chat.contact_jid not in jids:
        jids.insert(0, conv.chat.contact_jid)
    for jid in jids:
        if not jid or jid in seen:
            continue
        seen.add(jid)
        display = name_for_jid(jid) or _jid_local_part(jid)
        participants.append(
            {
                "id": _slug(display) or _jid_local_part(jid),
                "display": display,
                "role": "other",
                "jid": jid,
            }
        )
    return participants


def build_metadata(
    conv: WhatsAppConversation,
    *,
    name_for_jid: Callable[[str], Optional[str]],
    user_display_name: str = "You",
    privacy_level: Optional[str] = None,
    contact_label: Optional[str] = None,
    group_label: Optional[str] = None,
) -> dict:
    """Assemble the CM048 metadata dict for a WhatsApp chat.

    Shape matches the CM048 ``_whatsapp_adapter`` (``channel="whatsapp"``,
    ``chat_jid`` / ``chat_type`` / ``is_group_chat`` / ``group_subject``
    extra keys, participants as ``id`` / ``display`` / ``role`` dicts).

    Privacy precedence (highest first, mirrors the other feeds):
      1. ``privacy_level`` argument (operator privacy map in pipeline,
         or a test override).
      2. The operator-applied ``contact_label`` / ``group_label`` -- a
         family / partner / sensitive label escalates the thread to L3
         via CM048's own ladder (we pass the label through; CM048's
         ``_whatsapp_resolve_privacy`` does the L3/L1 decision).
      3. Unset, leaving CM048's classifier inference (L2 baseline +
         sensitive escalation).
    """
    chat_jid = (
        conv.chat.contact_jid
        if not conv.is_group
        else f"group:{conv.chat_id}"
    )
    started = conv.started_at
    ended = conv.ended_at
    date_str = started.date().isoformat() if started else "0000-00-00"

    metadata: dict = {
        "conversation_id": conversation_id_for(conv),
        "date": date_str,
        "source": "whatsapp",
        "channel": "whatsapp",
        "source_app": "whatsapp",
        "source_session_id": conv.chat_id,
        "capture_source": "hr015_whatsapp_source",
        "chat_jid": chat_jid,
        "chat_type": "group" if conv.is_group else "private",
        "is_group_chat": conv.is_group,
        "contact_source_tier": conv.tier,
        "participants": _participants_metadata(
            conv, name_for_jid, user_display_name
        ),
    }
    if conv.is_group and conv.group_subject:
        metadata["group_subject"] = conv.group_subject
    if _iso(started):
        metadata["started_at"] = _iso(started)
        metadata["ended_at"] = _iso(ended) or _iso(started)

    # Operator-applied labels ride through so CM048's ladder can
    # escalate (family/partner -> L3) or relax (public/work group -> L1).
    if contact_label:
        metadata["contact_label"] = contact_label
    if group_label:
        metadata["group_label"] = group_label

    # Explicit privacy override always wins.
    if privacy_level:
        metadata["privacy_level"] = str(privacy_level).strip().upper()

    return metadata
