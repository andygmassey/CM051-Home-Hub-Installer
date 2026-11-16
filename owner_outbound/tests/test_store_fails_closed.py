"""The record lives in the Hub's SQLCipher DB. RED: owner_outbound.sqlcipher_store does not exist."""
import os

import pytest

from owner_outbound.sqlcipher_store import SqlCipherStore, KeyUnavailable


def test_no_key_fails_closed_and_writes_nothing(tmp_path):
    path = tmp_path / "owner_outbound.db"
    with pytest.raises(KeyUnavailable):
        SqlCipherStore.open(str(path), key_resolver=lambda: None)
    assert not path.exists()


def test_db_is_unreadable_without_the_resolved_key(tmp_path):
    path = tmp_path / "owner_outbound.db"
    store = SqlCipherStore.open(str(path), key_resolver=lambda: "k-test-only")
    store.close()
    with pytest.raises(Exception):
        SqlCipherStore.open(str(path), key_resolver=lambda: "wrong-test-key").close()


def test_control_correct_key_reopens(tmp_path):
    path = tmp_path / "owner_outbound.db"
    SqlCipherStore.open(str(path), key_resolver=lambda: "k-test-only").close()
    SqlCipherStore.open(str(path), key_resolver=lambda: "k-test-only").close()
