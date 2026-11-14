"""Owner addresses from Accounts4 (RED first, 2026-11-15).

Arms: no env var still gives owner_wrote true for an owner-sent thread; an alias
address gives owner_wrote true; no accounts gives status "none" (not silence);
the state file is 0600 and its addresses are never logged.
Synthetic data only: reserved example domains.
"""
from __future__ import annotations

import json
import os
import plistlib
import sqlite3
import stat
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

VENDOR = Path(__file__).resolve().parents[2]          # vendor/
REPO = Path(__file__).resolve().parents[3]            # CM051 repo root
sys.path.insert(0, str(VENDOR))
sys.path.insert(0, str(REPO / "lib"))

import owner_addresses as derive_mod                  # installer side
from email_source import owner_addresses as reader    # vendored side
from email_source import pipeline
from email_source.reader import EmailMessage

MAIN = "owner" + "@" + "example" + ".com"
ALIAS = "owner.alias" + "@" + "example" + ".org"
IDENT = "owner" + "@" + "example" + ".net"
FRIEND = "friend" + "@" + "example" + ".com"


def _accounts_db(path: Path, usernames_and_props, *, mail_type="com.apple.account.IMAP"):
    conn = sqlite3.connect(path)
    conn.executescript("""
        CREATE TABLE ZACCOUNTTYPE (Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER TEXT);
        CREATE TABLE ZACCOUNT (Z_PK INTEGER PRIMARY KEY, ZUSERNAME TEXT,
            ZACCOUNTTYPE INTEGER, ZAUTHENTICATIONTYPE TEXT, ZACTIVE INTEGER);
        CREATE TABLE ZACCOUNTPROPERTY (Z_PK INTEGER PRIMARY KEY, ZKEY TEXT,
            ZVALUE BLOB, ZOWNER INTEGER);
    """)
    conn.execute("INSERT INTO ZACCOUNTTYPE VALUES (1, ?)", (mail_type,))
    conn.execute("INSERT INTO ZACCOUNTTYPE VALUES (2, 'com.apple.account.CalDAV')")
    pk = 10
    for username, props in usernames_and_props:
        conn.execute("INSERT INTO ZACCOUNT VALUES (?, ?, 1, NULL, 1)", (pk, username))
        for key, value in props:
            conn.execute("INSERT INTO ZACCOUNTPROPERTY VALUES (NULL, ?, ?, ?)",
                         (key, plistlib.dumps(value, fmt=plistlib.FMT_BINARY), pk))
        pk += 1
    conn.commit()
    conn.close()
    return path


def _msg(mid, sender, to, *, when=0, body="hi"):
    return EmailMessage(
        message_id=mid, in_reply_to=None, references=[], subject="Lunch",
        from_address=sender, to_addresses=[("", to)],
        timestamp=datetime(2026, 11, 1, 9, tzinfo=timezone.utc).replace(minute=when),
        body=body, headers={}, mailbox="Sent" if sender != FRIEND else "INBOX",
    )


@pytest.fixture
def ostler_dir(tmp_path, monkeypatch):
    d = tmp_path / ".ostler"
    (d / "state").mkdir(parents=True)
    monkeypatch.setenv("OSTLER_DIR", str(d))
    monkeypatch.delenv("OSTLER_USER_EMAIL", raising=False)
    return d


def _write_state(ostler_dir, addresses, status="ok"):
    (ostler_dir / "state" / "owner_addresses.json").write_text(
        json.dumps({"schema": 1, "status": status, "addresses": addresses}))


# --- derivation (installer side) ---------------------------------------------

def test_derive_finds_every_account_address_and_alias(tmp_path):
    db = _accounts_db(tmp_path / "Accounts4.sqlite", [
        (MAIN, [("EmailAliases", [ALIAS])]),
        ("second" + "@" + "example" + ".com", []),
        ("Owner <" + IDENT + ">", []),
    ])
    got = derive_mod.derive(str(db))
    assert got["status"] == "ok"
    assert set(got["addresses"]) >= {MAIN, ALIAS, IDENT, "second" + "@" + "example" + ".com"}


def test_derive_missing_store_is_unreadable_not_none(tmp_path):
    got = derive_mod.derive(str(tmp_path / "absent.sqlite"))
    assert got == {"status": "unreadable", "addresses": []}


def test_derive_no_mail_accounts_is_none(tmp_path):
    db = _accounts_db(tmp_path / "Accounts4.sqlite", [], mail_type="com.apple.account.CalDAV")
    assert derive_mod.derive(str(db)) == {"status": "none", "addresses": []}


def test_state_file_is_0600_and_never_logged(tmp_path, capsys, caplog):
    out = tmp_path / "state" / "owner_addresses.json"
    derive_mod.write_state(str(out), {"status": "ok", "addresses": [MAIN]})
    assert stat.S_IMODE(os.stat(out).st_mode) == 0o600
    assert json.loads(out.read_text())["addresses"] == [MAIN]
    derive_mod.main(["--db", str(tmp_path / "absent.sqlite"), "--out", str(out)])
    captured = capsys.readouterr()
    assert MAIN not in captured.out and MAIN not in captured.err
    assert MAIN not in caplog.text


# --- reader (vendored side) --------------------------------------------------

def test_reader_uses_state_file_when_no_env(ostler_dir):
    _write_state(ostler_dir, [MAIN, ALIAS])
    assert reader.owner_set("") == frozenset({MAIN, ALIAS})


def test_reader_falls_back_to_env_when_no_file(ostler_dir):
    assert reader.owner_set(MAIN) == frozenset({MAIN})


def test_reader_lowercases_and_drops_junk(ostler_dir):
    _write_state(ostler_dir, ["Owner" + "@" + "Example.COM", "not-an-address", ""])
    assert reader.owner_set("") == frozenset({"owner" + "@" + "example" + ".com"})


# --- the owner_wrote arms (the consumer) -------------------------------------

def _owner_wrote(messages, *, user_address=""):
    snap = pipeline.build_reply_debt_snapshot(messages, user_address=user_address)
    return [t["owner_wrote"] for t in snap["threads"]]


def test_arm1_no_env_owner_sent_thread_is_owner_wrote_true(ostler_dir):
    _write_state(ostler_dir, [MAIN])
    msgs = [_msg("a1", MAIN, FRIEND, when=1)]
    assert _owner_wrote(msgs) == [True]


def test_arm2_alias_address_counts_as_owner(ostler_dir):
    _write_state(ostler_dir, [MAIN, ALIAS])
    msgs = [_msg("a2", ALIAS, FRIEND, when=2)]
    assert _owner_wrote(msgs) == [True]


def test_arm3_control_no_owner_known_means_owner_wrote_false(ostler_dir):
    # With no file and no env the owner is unknown: nothing is claimed as owner's.
    msgs = [_msg("a3", MAIN, FRIEND, when=3)]
    assert _owner_wrote(msgs) == [False]


def test_arm4_friend_message_is_not_owner_wrote(ostler_dir):
    _write_state(ostler_dir, [MAIN])
    msgs = [_msg("a4", FRIEND, MAIN, when=4)]
    assert _owner_wrote(msgs) == [False]


def test_arm5_snapshot_lists_owner_addresses(ostler_dir):
    _write_state(ostler_dir, [MAIN, ALIAS])
    snap = pipeline.build_reply_debt_snapshot([_msg("a5", MAIN, FRIEND, when=5)], user_address="")
    assert set(snap["owner_addresses"]) == {MAIN, ALIAS}


def test_arm6_main_address_counts_when_an_alias_sorts_first(ostler_dir):
    # 'owner.alias@...' sorts before 'owner@...': a first-address-only consumer misses MAIN.
    _write_state(ostler_dir, [MAIN, ALIAS])
    assert _owner_wrote([_msg("a6", MAIN, FRIEND, when=6)]) == [True]
