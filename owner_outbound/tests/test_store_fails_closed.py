"""The record lives in the Hub's SQLCipher DB. RED: owner_outbound.sqlcipher_store does not exist."""
import os

import pytest

from owner_outbound.sqlcipher_store import SqlCipherStore, KeyUnavailable, StoreUnavailable


def _open_or_cannot_run(*a, **k):
    try:
        return SqlCipherStore.open(*a, **k)
    except StoreUnavailable as e:
        pytest.skip(str(e))


def test_no_key_fails_closed_and_writes_nothing(tmp_path):
    path = tmp_path / "owner_outbound.db"
    with pytest.raises(KeyUnavailable):
        SqlCipherStore.open(str(path), key_resolver=lambda: None)
    assert not path.exists()


def test_db_is_unreadable_without_the_resolved_key(tmp_path):
    path = tmp_path / "owner_outbound.db"
    store = _open_or_cannot_run(str(path), key_resolver=lambda: "abcdef0123456789")
    store.close()
    with pytest.raises(Exception):
        _open_or_cannot_run(str(path), key_resolver=lambda: "fedcba9876543210").close()


def test_control_correct_key_reopens(tmp_path):
    path = tmp_path / "owner_outbound.db"
    _open_or_cannot_run(str(path), key_resolver=lambda: "abcdef0123456789").close()
    _open_or_cannot_run(str(path), key_resolver=lambda: "abcdef0123456789").close()


PLANTED = "PLANTED-TOKEN-5519-ZQ"


def test_db_file_on_disk_does_not_contain_planted_token(tmp_path):
    """Plant the token in the message BODY (which must never be stored), run the
    real ingest path, then grep the raw DB bytes. Must find nothing."""
    import sqlite3
    from owner_outbound.record import OwnerOutboundRecord
    from owner_outbound.tests.fakes import FakeGraph, FakeResolver, outbound
    path = tmp_path / "owner_outbound.db"
    store = _open_or_cannot_run(str(path), key_resolver=lambda: "abcdef0123456789")
    rec = OwnerOutboundRecord(store=store, graph=FakeGraph(), owner_aliases=set(),
                              resolver=FakeResolver({"a@x.test": "person:A"}))
    rec.ingest(outbound(channel="email", to=["a@x.test"], body=PLANTED))
    store.close()
    assert PLANTED.encode() not in path.read_bytes()


def test_control_plaintext_sqlite_does_contain_the_token(tmp_path):
    """Control: the grep must be able to find the token. A plain sqlite file with
    the token written in must match, or the negative above proves nothing."""
    import sqlite3
    path = tmp_path / "plain_control.db"
    c = sqlite3.connect(str(path))
    c.execute("CREATE TABLE t (v TEXT)")
    c.execute("INSERT INTO t VALUES (?)", (PLANTED,))
    c.commit()
    c.close()
    assert PLANTED.encode() in path.read_bytes()
