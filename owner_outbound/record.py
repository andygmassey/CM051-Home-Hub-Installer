"""Per-person owner-outbound record. Metadata only: counts and timestamps, never content.

Store-agnostic: the store is injected (SqlCipherStore in production, a fake in tests).
Notes-to-self and owner aliases never create a person row. Group sends feed
group_sent_count and never feed the 134 boolean. Only 1:1 sends and email
with the person in To feed owner_sent_count.
"""
import pathlib
import sys
from dataclasses import dataclass, field
from typing import Optional

# The real tombstone reader (stdlib only). Vendored under vendor/cm041.
_VENDOR = pathlib.Path(__file__).resolve().parents[1] / "vendor" / "cm041"
if str(_VENDOR) not in sys.path:
    sys.path.insert(0, str(_VENDOR))
from identity_resolver import forget_tombstone as _tomb  # noqa: E402

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
    """Tombstone-aware: a person erased by forget is never written, read, or kept.

    Every ingest and read purges rows of tombstoned people in the same
    transaction as the write; the constructor purges once at process start."""

    def __init__(self, store, graph, owner_aliases, resolver, tombstone_path=None):
        self.store = store
        self.graph = graph
        self.owner_aliases = {_norm(a) for a in owner_aliases}
        self.resolver = resolver
        self.tombstone_path = tombstone_path
        self._purge_forgotten()
        self.store.commit()

    def _forgotten(self, person_uri, values=()):
        return _tomb.is_forgotten(values=list(values), uri=person_uri,
                                  path=self.tombstone_path)

    def _purge_forgotten(self):
        for uri in self.store.person_uris():
            if self._forgotten(uri):
                self.store.delete_rows_for(uri)

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
        self._purge_forgotten()  # same transaction as the write below
        if msg.is_note_to_self:
            self.store.commit()
            return
        direct_addrs = msg.to  # cc/bcc never count as a direct send
        for addr in direct_addrs:
            if _norm(addr) in self.owner_aliases:
                continue
            person = self.resolver.resolve(addr)
            if person is None:  # unresolved: no row, never mint a person
                continue
            if self._forgotten(person, [addr]):  # erased: never recreated
                continue
            self._bump(person, msg.channel,
                       direct=not msg.is_group, sent_at=msg.sent_at)
        self.store.commit()

    def row(self, person_uri, channel):
        self._purge_forgotten()
        self.store.commit()
        if self._forgotten(person_uri):
            return None
        return self.store.get_row(person_uri, channel)

    def has_verified_owner_outbound(self, person_uri):
        self._purge_forgotten()
        self.store.commit()
        if self._forgotten(person_uri):
            return False
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
