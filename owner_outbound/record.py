"""Per-person owner-outbound record. Metadata only: counts and timestamps, never content.

Store-agnostic: the store is injected (SqlCipherStore in production, a fake in tests).
Notes-to-self and owner aliases never create a person row. Group sends feed
group_sent_count and never feed the 134 boolean. Only 1:1 sends and email
with the person in To feed owner_sent_count.
"""
from dataclasses import dataclass, field
from typing import Optional

FORGET_COMPLETE = "COMPLETE"
FORGET_INCOMPLETE = "INCOMPLETE"
DIRECT_CHANNELS = ("imessage", "whatsapp", "email")


@dataclass
class OutboundMessage:
    channel: str
    sent_at: int  # epoch seconds, UTC
    to: list = field(default_factory=list)
    cc: list = field(default_factory=list)
    bcc: list = field(default_factory=list)
    is_group: bool = False
    is_note_to_self: bool = False
    body: Optional[str] = None  # accepted for realism, never read or stored


@dataclass
class ForgetResult:
    status: str
    residue: list


def _norm(addr):
    return (addr or "").strip().lower()


class OwnerOutboundRecord:
    def __init__(self, store, graph, owner_aliases, resolver):
        self.store = store
        self.graph = graph
        self.owner_aliases = {_norm(a) for a in owner_aliases}
        self.resolver = resolver

    def _bump(self, person_uri, channel, *, direct, sent_at):
        row = self.store.get_row(person_uri, channel) or {
            "owner_sent_count": 0, "group_sent_count": 0,
            "last_owner_sent_at": None, "source_id": "owner-outbound-v1",
        }
        if direct:
            row["owner_sent_count"] = row["owner_sent_count"] + 1
            prev = row["last_owner_sent_at"]
            row["last_owner_sent_at"] = sent_at if prev is None else max(prev, sent_at)
        else:
            row["group_sent_count"] = row["group_sent_count"] + 1
        row["updated_at"] = sent_at
        self.store.upsert_row(person_uri, channel, row)

    def ingest(self, msg):
        if msg.is_note_to_self:
            return
        direct_addrs = msg.to  # cc/bcc never count as a direct send
        for addr in direct_addrs:
            if _norm(addr) in self.owner_aliases:
                continue
            person = self.resolver.resolve(addr)
            if person is None:  # unresolved: no row, never mint a person
                continue
            self._bump(person, msg.channel,
                       direct=not msg.is_group, sent_at=msg.sent_at)

    def row(self, person_uri, channel):
        return self.store.get_row(person_uri, channel)

    def has_verified_owner_outbound(self, person_uri):
        return any(
            (self.store.get_row(person_uri, ch) or {}).get("owner_sent_count", 0) > 0
            for ch in DIRECT_CHANNELS
        )

    def forget_person(self, person_uri):
        residue = []
        try:
            self.store.delete_rows_for(person_uri)
        except Exception as e:  # noqa: BLE001 - surfaced as residue, never swallowed
            residue.append(f"record delete failed: {e}")
        if self.store.count_rows_for(person_uri) != 0:
            residue.append("record rows remain after delete")
        try:
            self.graph.forget_person(person_uri)
        except Exception as e:  # noqa: BLE001
            residue.append(f"graph forget failed: {e}")
        return ForgetResult(FORGET_INCOMPLETE if residue else FORGET_COMPLETE, residue)
