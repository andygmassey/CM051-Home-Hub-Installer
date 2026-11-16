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
