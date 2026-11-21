"""Per-person windowed message aggregates, WhatsApp source (CM051 vendor/whatsapp_source).

Same algorithm and contract as CM048 src/person_signals.py (#127); the shared
fixture tests/fixtures/person_windows_contract.json pins both. This module adds
the chat.db read and the snapshot writer. Dry run writes nothing.

One pure job, used by every producer that can supply per-message rows
(iMessage, WhatsApp, email). It never opens a store. The caller supplies rows
as ``Msg``; the caller is responsible for the signed read that produced them.

Output per person (see ``contract_row``):
  sent_30 / recv_30, sent_90 / recv_90, sent_365 / recv_365   counts by window
  reciprocity_365      min/max of sent_365 and recv_365; None if no messages
  active_months_12     calendar months (last 365 days) with an inbound AND an outbound
  median_reply_min_365 median minutes from an unanswered inbound to the owner's reply
  reply_pairs_365      how many replies the median is over
  last_contact_days    days since the latest message of either direction

Rules:
  - timestamps must be timezone-aware (naive export times are local, not UTC)
  - group messages are excluded
  - messages after ``today`` are ignored
  - a reply only counts if it arrives within REPLY_CAP_DAYS of the inbound
  - unknown is not zero: reciprocity and latency are None when there is nothing
    to measure

Privacy: the output carries counts, ratios and timings only. No text, no names.
"""
from __future__ import annotations

import statistics
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Iterable, Optional

SCHEMA = "person_signals.v1"
WINDOWS = (30, 90, 365)
REPLY_CAP_DAYS = 7
LOOKBACK_DAYS = 365


@dataclass(frozen=True)
class Msg:
    person_id: str
    channel: str
    ts: datetime
    from_owner: bool
    group: bool = False


def _days_ago(ts: datetime, today: datetime) -> float:
    return (today - ts).total_seconds() / 86400.0


def _check_aware(ts: datetime) -> None:
    if ts.tzinfo is None or ts.utcoffset() is None:
        raise ValueError("naive datetime: message times must be timezone-aware")


def _row_for(person_id: str, msgs: list, today: datetime) -> dict:
    row = {"person_id": person_id}
    for w in WINDOWS:
        inwin = [x for x in msgs if 0 <= _days_ago(x.ts, today) < w]
        row[f"sent_{w}"] = sum(1 for x in inwin if x.from_owner)
        row[f"recv_{w}"] = sum(1 for x in inwin if not x.from_owner)

    s, r = row["sent_365"], row["recv_365"]
    row["reciprocity_365"] = None if (s + r) == 0 else round(min(s, r) / max(s, r), 4)

    year_msgs = [x for x in msgs if 0 <= _days_ago(x.ts, today) < LOOKBACK_DAYS]
    by_month: dict = {}
    for x in year_msgs:
        key = (x.ts.year, x.ts.month)
        flags = by_month.setdefault(key, [False, False])
        flags[0 if not x.from_owner else 1] = True
    row["active_months_12"] = sum(1 for a, b in by_month.values() if a and b)

    lat, pairs = _reply_latencies(year_msgs)
    row["median_reply_min_365"] = round(statistics.median(lat), 2) if lat else None
    row["reply_pairs_365"] = len(lat)

    row["last_contact_days"] = round(min(_days_ago(x.ts, today) for x in msgs), 4)
    return row


def _reply_latencies(msgs: list) -> tuple:
    lat = []
    pending: Optional[datetime] = None
    for x in sorted(msgs, key=lambda m: m.ts):
        if not x.from_owner:
            if pending is None:
                pending = x.ts
        elif pending is not None:
            gap = x.ts - pending
            if gap <= timedelta(days=REPLY_CAP_DAYS):
                lat.append(gap.total_seconds() / 60.0)
            pending = None
    return lat, len(lat)


def windowed(messages: Iterable[Msg], today: datetime) -> list:
    """One row per person with at least one counted message. Empty input gives []."""
    _check_aware(today)
    by_person: dict = {}
    for x in messages:
        _check_aware(x.ts)
        if x.group:
            continue
        if x.ts > today:
            continue
        by_person.setdefault(x.person_id, []).append(x)
    rows = [_row_for(pid, msgs, today) for pid, msgs in by_person.items()]
    rows.sort(key=lambda r: r["person_id"])
    return rows


def contract_row(row: dict) -> dict:
    """The fixed key set the graph writer and the brief endpoint both read."""
    keys = (
        "person_id", "sent_30", "recv_30", "sent_90", "recv_90", "sent_365", "recv_365",
        "reciprocity_365", "active_months_12", "median_reply_min_365", "reply_pairs_365",
        "last_contact_days",
    )
    return {k: row[k] for k in keys}


def contract_snapshot() -> dict:
    """Synthetic cast, fixed clock. Pinned by the graph writer and the brief side."""
    today = datetime(2026, 11, 15, 12, 0, tzinfo=_utc())

    def m(pid, days_ago, from_owner, hours=0.0, group=False):
        ts = today - timedelta(days=days_ago) + timedelta(hours=hours)
        return Msg(person_id=pid, channel="imessage", ts=ts, from_owner=from_owner, group=group)

    msgs = (
        [m("c01", d, True) for d in (1, 2, 3, 40, 80, 200)]
        + [m("c01", d, False, hours=1) for d in (1, 2, 3, 40, 80, 200)]
        + [m("c02", 5, False), m("c02", 5, True, hours=2)]
        + [m("c03", 20, False)] + [m("c03", 20, True, hours=8 * 24)]
        + [m("c04", 1, True, group=True), m("c04", 1, False, group=True)]
        + [m("c05", 400, True)]
    )
    rows = [contract_row(r) for r in windowed(msgs, today)]
    return {"schema": SCHEMA, "rows": rows}


def _utc():
    from datetime import timezone
    return timezone.utc


# --- WhatsApp: conversations -> windows -------------------------------------

def windows_from_whatsapp(conversations, *, now=None, l3_jids=frozenset()) -> list:
    """One-to-one chats only. The counterparty is the chat's contact JID.

    Skipped, contributing nothing: group chats, tier-2 chats without a contact
    JID, and any contact at L3 (no count, no row, no id).
    """
    now = now or datetime.now(timezone.utc)
    msgs: list = []
    for conv in conversations:
        chat = conv.chat
        if chat.is_group or not chat.contact_jid:
            continue
        person = chat.contact_jid
        if person in l3_jids:
            continue
        for u in conv.utterances:
            if u.timestamp is None:
                continue
            msgs.append(Msg(person_id=person, channel="whatsapp", ts=u.timestamp,
                            from_owner=bool(u.is_from_me), group=False))
    return windowed(msgs, now)
