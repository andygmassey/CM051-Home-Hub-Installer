"""Owner-outbound record: behaviour through the interface, store behind a fake.

RED on purpose: owner_outbound.record does not exist yet. Each test names the
behaviour it pins. Run: python3 -m pytest owner_outbound/tests -q
"""
import pytest

from owner_outbound.record import OwnerOutboundRecord, FORGET_COMPLETE, FORGET_INCOMPLETE
from owner_outbound.tests.fakes import FakeStore, FakeGraph, FakeResolver, outbound

OWNER_ALIAS = "owner@self.test"
A = "person:A"


def make(mapping=None):
    store, graph = FakeStore(), FakeGraph()
    rec = OwnerOutboundRecord(store=store, graph=graph,
                              owner_aliases={OWNER_ALIAS},
                              resolver=FakeResolver(mapping or {"a@x.test": A}))
    return rec, store, graph


def test_note_to_self_creates_no_person_row():
    rec, store, _ = make()
    rec.ingest(outbound(channel="imessage", to=[OWNER_ALIAS], is_note_to_self=True))
    assert store.persons == set()
    assert store.rows == {}


def test_note_to_self_to_a_real_contact_creates_no_row():
    rec, store, _ = make()
    rec.ingest(outbound(channel="email", to=["a@x.test"], is_note_to_self=True))
    assert store.rows == {}


def test_owner_alias_recipient_creates_no_person_row():
    rec, store, _ = make({OWNER_ALIAS: "person:owner"})
    rec.ingest(outbound(channel="email", to=[OWNER_ALIAS]))
    assert store.rows == {}
    assert store.persons == set()


def test_group_send_does_not_feed_boolean():
    rec, store, _ = make()
    rec.ingest(outbound(channel="imessage", to=["a@x.test"], is_group=True))
    row = store.get_row(A, "imessage")
    assert row["group_sent_count"] == 1
    assert row["owner_sent_count"] == 0
    assert rec.has_verified_owner_outbound(A) is False


def test_email_to_counts_boolean():
    rec, _, _ = make()
    rec.ingest(outbound(channel="email", to=["a@x.test"]))
    assert rec.has_verified_owner_outbound(A) is True


def test_email_cc_only_does_not_feed_boolean():
    rec, _, _ = make()
    rec.ingest(outbound(channel="email", cc=["a@x.test"]))
    assert rec.has_verified_owner_outbound(A) is False


def test_email_bcc_only_does_not_feed_boolean():
    rec, _, _ = make()
    rec.ingest(outbound(channel="email", bcc=["a@x.test"]))
    assert rec.has_verified_owner_outbound(A) is False


def test_large_cc_list_is_not_a_direct_send():
    rec, _, _ = make()
    cc = [f"p{i}@x.test" for i in range(60)] + ["a@x.test"]
    rec.ingest(outbound(channel="email", to=[], cc=cc))
    assert rec.has_verified_owner_outbound(A) is False


def test_unresolved_sent_recipient_creates_no_row():
    rec, store, _ = make()
    rec.ingest(outbound(channel="email", to=["stranger@nowhere.test"]))
    assert store.persons == set()
    assert store.rows == {}


def test_resolved_sent_recipient_creates_row_with_epoch_time():
    rec, store, _ = make()
    rec.ingest(outbound(channel="email", to=["a@x.test"], sent_at=1_700_000_000))
    row = store.get_row(A, "email")
    assert row["owner_sent_count"] == 1
    assert row["last_owner_sent_at"] == 1_700_000_000


def test_no_content_fields_are_stored():
    rec, store, _ = make()
    rec.ingest(outbound(channel="email", to=["a@x.test"], body="SENTINEL-BODY-7731"))
    allowed = {"person_uri", "channel", "last_owner_sent_at", "owner_sent_count",
               "group_sent_count", "source_id", "updated_at"}
    for row in store.rows.values():
        assert set(row) <= allowed
    assert "SENTINEL-BODY-7731" not in repr(store.rows)


def test_forget_deletes_rows_and_verifies_zero():
    rec, store, graph = make()
    rec.ingest(outbound(channel="email", to=["a@x.test"]))
    result = rec.forget_person(A)
    assert result.status == FORGET_COMPLETE
    assert store.count_rows_for(A) == 0


def test_forget_reports_incomplete_when_record_delete_fails():
    rec, store, _ = make()
    rec.ingest(outbound(channel="email", to=["a@x.test"]))
    store.fail_delete = True
    result = rec.forget_person(A)
    assert result.status == FORGET_INCOMPLETE
    assert result.residue  # residue marker, never silent


def test_forget_reports_incomplete_when_graph_side_fails():
    rec, store, graph = make()
    rec.ingest(outbound(channel="email", to=["a@x.test"]))
    graph.fail_forget = True
    result = rec.forget_person(A)
    assert result.status == FORGET_INCOMPLETE


def test_mutant_skipping_row_delete_is_caught_by_count_check(monkeypatch):
    """Mutant: delete_rows_for is a no-op. Forget must NOT report COMPLETE."""
    rec, store, _ = make()
    rec.ingest(outbound(channel="email", to=["a@x.test"]))
    monkeypatch.setattr(store, "delete_rows_for", lambda uri: 0)
    result = rec.forget_person(A)
    assert result.status == FORGET_INCOMPLETE
