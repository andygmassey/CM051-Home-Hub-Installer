"""Owner-outbound store as a TOMBSTONE CONSUMER (CM051 equivalent of
test_forget_tombstone_every_syncer). Uses the REAL tombstone writer (record) and
REAL reader (is_forgotten). No stub. Not wired: flag-off component, no caller."""
import pytest

from identity_resolver import forget_tombstone as tomb
from owner_outbound.people_rule import keep_service_sender
from owner_outbound.record import OwnerOutboundRecord
from owner_outbound.tests.fakes import FakeGraph, FakeResolver, FakeStore, outbound

A = "person:A"
ADDR = "a@x.test"


def _world(tmp_path):
    tpath = tmp_path / "forgotten_people.json"
    store = FakeStore()
    rec = OwnerOutboundRecord(store=store, graph=FakeGraph(), owner_aliases=set(),
                              resolver=FakeResolver({ADDR: A}), tombstone_path=tpath)
    return rec, store, tpath


def _forget(tpath):
    assert tomb.record(A, [ADDR], display_name=None, path=tpath) is True


def test_forget_then_ingest_creates_no_row(tmp_path):
    rec, store, tpath = _world(tmp_path)
    _forget(tpath)
    rec.ingest(outbound(channel="email", to=[ADDR]))
    assert store.count_rows_for(A) == 0
    assert rec.row(A, "email") is None


def test_existing_row_is_purged_when_tombstoned_then_read_is_absent(tmp_path):
    rec, store, tpath = _world(tmp_path)
    rec.ingest(outbound(channel="email", to=[ADDR]))
    assert store.count_rows_for(A) == 1  # control: row exists before forget
    _forget(tpath)
    assert rec.row(A, "email") is None
    assert store.count_rows_for(A) == 0


def test_control_without_tombstone_keeps_the_row(tmp_path):
    rec, store, tpath = _world(tmp_path)
    rec.ingest(outbound(channel="email", to=[ADDR]))
    assert rec.row(A, "email")["owner_sent_count"] == 1
    assert store.count_rows_for(A) == 1


def test_process_start_purges_tombstoned_rows(tmp_path):
    rec, store, tpath = _world(tmp_path)
    rec.ingest(outbound(channel="email", to=[ADDR]))
    _forget(tpath)
    # a new process: constructor purges once at start
    OwnerOutboundRecord(store=store, graph=FakeGraph(), owner_aliases=set(),
                        resolver=FakeResolver({ADDR: A}), tombstone_path=tpath)
    assert store.count_rows_for(A) == 0


def test_reader_never_returns_a_tombstoned_person(tmp_path):
    rec, store, tpath = _world(tmp_path)
    rec.ingest(outbound(channel="email", to=[ADDR]))
    _forget(tpath)
    assert rec.has_verified_owner_outbound(A) is False
    assert keep_service_sender(A, has_contact_card=False, record=rec) is False


def test_unreadable_tombstone_fails_closed_and_refuses_writes(tmp_path):
    rec, store, tpath = _world(tmp_path)
    tpath.write_text("not json")  # unreadable: is_forgotten answers True
    rec.ingest(outbound(channel="email", to=[ADDR]))
    assert store.count_rows_for(A) == 0


def test_ingest_purges_other_tombstoned_rows_in_the_same_write(tmp_path):
    rec, store, tpath = _world(tmp_path)
    rec.ingest(outbound(channel="email", to=[ADDR]))
    _forget(tpath)  # tombstone A, no read yet
    rec.ingest(outbound(channel="email", to=["b@x.test"]))  # unrelated write
    assert store.count_rows_for(A) == 0


def test_reader_guard_holds_even_when_the_purge_cannot_delete(tmp_path, monkeypatch):
    rec, store, tpath = _world(tmp_path)
    rec.ingest(outbound(channel="email", to=[ADDR]))
    _forget(tpath)
    monkeypatch.setattr(store, "delete_rows_for", lambda uri: 0)  # purge fails
    assert rec.row(A, "email") is None
    assert rec.has_verified_owner_outbound(A) is False
