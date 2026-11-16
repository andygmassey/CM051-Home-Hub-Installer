"""Store-agnostic fakes. The real store is the Hub's SQLCipher DB (ostler_security.resolve_db_key)."""
from contextlib import contextmanager


class FakeStore:
    def __init__(self):
        self.persons = set()
        self.rows = {}  # (person_uri, channel) -> dict
        self.fail_delete = False  # simulate a failed delete on the record side

    def ensure_person(self, uri):
        self.persons.add(uri)

    def upsert_row(self, person_uri, channel, row):
        self.rows[(person_uri, channel)] = dict(row)

    def get_row(self, person_uri, channel):
        r = self.rows.get((person_uri, channel))
        return dict(r) if r else None

    def delete_rows_for(self, person_uri):
        if self.fail_delete:
            raise RuntimeError("simulated record-side delete failure")
        keys = [k for k in self.rows if k[0] == person_uri]
        for k in keys:
            del self.rows[k]
        return len(keys)

    def count_rows_for(self, person_uri):
        return sum(1 for k in self.rows if k[0] == person_uri)


class FakeGraph:
    """Stands in for the people graph side of forget-person (a separate store)."""

    def __init__(self):
        self.persons = set()
        self.fail_forget = False

    def forget_person(self, person_uri):
        if self.fail_forget:
            raise RuntimeError("simulated graph-side forget failure")
        self.persons.discard(person_uri)


class FakeResolver:
    """Address -> person_uri. Never creates persons (the record must not mint them)."""

    def __init__(self, mapping):
        self.mapping = dict(mapping)

    def resolve(self, address):
        return self.mapping.get(address)


def outbound(channel="email", sent_at=1_700_000_000, to=(), cc=(), bcc=(),
             is_group=False, is_note_to_self=False, body="SENTINEL-BODY-7731"):
    from owner_outbound.record import OutboundMessage
    return OutboundMessage(channel=channel, sent_at=sent_at, to=list(to), cc=list(cc),
                           bcc=list(bcc), is_group=is_group,
                           is_note_to_self=is_note_to_self, body=body)
