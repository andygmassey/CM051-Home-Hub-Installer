"""NEW-119: the merge journal names each exact-identifier key as {kind, hash}.

WHY. The walk probe ``no_person_holds_two_contact_cards`` may accept a Person
holding 2+ Contacts cards ONLY when the merge journal proves an exact-
identifier override (v1.0.107 #30). Before this change the journal row carried
``override="exact_identifier:<kinds>"`` and a ``shared_kinds`` list GUESSED by
searching the free-text details and the strategy name for the words "email",
"phone" and "linkedin", and no key at all. These tests pin:

  1. each matched usable key is journalled as {kind, hash}, hash =
     HMAC-SHA256(subkey, "<kind>:<normalised>")[:16] with subkey =
     HMAC-SHA256(per-install secret, "ostler.merge-journal.v1"), never the
     secret itself;
  2. values are normalised with the resolver's own normalisers first, so two
     spellings of one number (or one email, or one LinkedIn URL) hash the same;
  3. the journal FILE bytes contain no raw identifier in any spelling;
  4. shared_kinds comes only from the matched keys;
  5. a missing secret never blocks the merge: kinds with hash null and reason
     "journal_secret_unavailable".

Real BatchResolver (detect -> execute -> converge) against the in-memory
rdflib store from test_exact_identifier_merge. SYNTHETIC DATA ONLY: invented
names, NANP 555-01xx fictional numbers, example.com addresses, an invented
LinkedIn slug, and a secret generated per test.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import secrets
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "vendor", "cm041"))

from test_exact_identifier_merge import FakeStore, make, _no_qdrant  # noqa: E402,F401

from identity_resolver import batch_resolver as br  # noqa: E402
from identity_resolver import merge_journal as mj  # noqa: E402

# NANP fictional range (555-0100..0199). phonenumbers types it
# FIXED_LINE_OR_MOBILE, so it is a usable merge key.
PHONE_E164 = "+12025550123"
PHONE_SPELLINGS = ("+1 (202) 555-0123", "+1 202 555 0123", " +12025550123 ")
PHONE_DIGITS = "2025550123"
EMAIL = "robin.vale@example.com"
EMAIL_SPELLINGS = ("Robin.Vale@Example.COM", "  robin.vale@example.com\n")
LINKEDIN_SPELLINGS = ("https://www.linkedin.com/in/robin-vale-example/?trk=x",
                      "http://LinkedIn.com/in/robin-vale-example")
NAME = "Robin Vale"
LABEL = b"ostler.merge-journal.v1"


@pytest.fixture
def box(tmp_path, monkeypatch):
    """A synthetic install root with a per-install secret where install.sh
    puts it (secrets/service_token, 0600 in a 0700 dir)."""
    root = tmp_path / "ostler"
    (root / "secrets").mkdir(parents=True)
    os.chmod(root / "secrets", 0o700)
    secret = secrets.token_hex(32)
    (root / "secrets" / "service_token").write_text(secret)
    os.chmod(root / "secrets" / "service_token", 0o600)
    monkeypatch.delenv("OSTLER_HOME", raising=False)
    monkeypatch.setenv("OSTLER_DIR", str(root))
    return root, secret.encode()


def expected_hash(secret: bytes, kind: str, normalised: str) -> str:
    sub = hmac.new(secret, LABEL, hashlib.sha256).digest()
    return hmac.new(sub, f"{kind}:{normalised}".encode(), hashlib.sha256).hexdigest()[:16]


def keys(pairs, **kw):
    return mj.journal_identifier_keys(
        pairs, normalise_linkedin=br._normalise_linkedin_url, **kw)


def journal(tmp_path):
    path = tmp_path / "bk" / "merge_journal" / mj.JOURNAL_NAME
    raw = path.read_bytes()
    rows = [json.loads(x) for x in raw.decode().splitlines() if x.strip()]
    return raw, [r for r in rows if r.get("kind") == "merge"]


def two_cards(store, *, phones=(), emails=(), linkedin=()):
    store.person("rv1", NAME, phones=phones, emails=emails, linkedin=linkedin,
                 uids=["uid-card-icloud-1"])
    store.person("rv2", NAME, phones=phones, emails=emails, linkedin=linkedin,
                 uids=["uid-card-exchange-2"])


# --------------------------------------------------------------------------
# Condition 1: the hash is keyed by a SUBKEY of the per-install secret.
# --------------------------------------------------------------------------
def test_hash_uses_the_derived_subkey_never_the_secret_directly(box):
    _, secret = box
    rows, reason = keys([("phone", PHONE_E164)])
    assert reason == ""
    assert rows == [{"kind": "phone", "hash": expected_hash(secret, "phone", PHONE_E164)}]
    direct = hmac.new(secret, f"phone:{PHONE_E164}".encode(),
                      hashlib.sha256).hexdigest()[:16]
    assert rows[0]["hash"] != direct
    assert re.fullmatch(r"[0-9a-f]{16}", rows[0]["hash"])


def test_hash_differs_between_installs(box, tmp_path, monkeypatch):
    rows_a, _ = keys([("email", EMAIL)])
    other = tmp_path / "other" / "secrets"
    other.mkdir(parents=True)
    (other / "service_token").write_text(secrets.token_hex(32))
    monkeypatch.setenv("OSTLER_DIR", str(other.parent))
    rows_b, _ = keys([("email", EMAIL)])
    assert rows_a[0]["hash"] != rows_b[0]["hash"]


# --------------------------------------------------------------------------
# Condition 2: normalise with the resolver's own normalisers before hashing.
# --------------------------------------------------------------------------
def test_two_spellings_of_one_phone_give_one_hash(box):
    hashes = {keys([("phone", s)])[0][0]["hash"] for s in PHONE_SPELLINGS}
    assert len(hashes) == 1
    assert hashes == {keys([("phone", PHONE_E164)])[0][0]["hash"]}


def test_national_spelling_uses_the_configured_country_code(box):
    a = keys([("phone", "(202) 555-0123")], default_country_code=1)[0][0]["hash"]
    assert a == keys([("phone", PHONE_E164)])[0][0]["hash"]


def test_two_spellings_of_one_email_give_one_hash(box):
    hashes = {keys([("email", s)])[0][0]["hash"] for s in EMAIL_SPELLINGS}
    assert len(hashes) == 1
    assert hashes == {keys([("email", EMAIL)])[0][0]["hash"]}


def test_two_spellings_of_one_linkedin_url_give_one_hash(box):
    hashes = {keys([("linkedin", s)])[0][0]["hash"] for s in LINKEDIN_SPELLINGS}
    assert len(hashes) == 1


def test_one_value_under_two_kinds_hashes_differently(box):
    assert keys([("email", EMAIL)])[0][0]["hash"] != keys([("linkedin", EMAIL)])[0][0]["hash"]


# --------------------------------------------------------------------------
# Condition 3: the journal FILE carries no raw identifier, and does carry the
# keyed hashes of exactly the keys that matched.
# --------------------------------------------------------------------------
def test_journal_bytes_carry_hashes_and_no_raw_identifier(box, tmp_path):
    _, secret = box
    s = FakeStore()
    two_cards(s, phones=[PHONE_E164], emails=[EMAIL])
    make(s, tmp_path).converge(backup_dir=str(tmp_path / "bk"))
    assert len(s.live()) == 1

    raw, merges = journal(tmp_path)
    assert len(merges) == 1
    m = merges[0]
    assert m["override"] == "exact_identifier:email+phone"
    assert m["matched_keys"] == sorted([
        {"kind": "email", "hash": expected_hash(secret, "email", EMAIL)},
        {"kind": "phone", "hash": expected_hash(secret, "phone", PHONE_E164)},
    ], key=lambda r: r["kind"])
    assert m["matched_keys_reason"] == ""
    text = raw.decode().lower()
    for needle in (PHONE_E164, PHONE_DIGITS, "555-0123", "555 0123",
                   EMAIL, "robin.vale", secret.decode()):
        assert needle.lower() not in text, "raw value in the journal (masked)"


# --------------------------------------------------------------------------
# Condition 4: shared_kinds comes ONLY from the matched keys.
# --------------------------------------------------------------------------
def test_shared_kinds_names_the_matched_key_not_the_words_in_details(box, tmp_path, monkeypatch):
    real = br.detect_phone_matches

    def phone_matches_whose_details_mention_email(persons, config):
        out = real(persons, config)
        for m in out:
            m.details += " (no email or linkedin in common)"
        return out

    monkeypatch.setattr(br, "detect_phone_matches", phone_matches_whose_details_mention_email)
    s = FakeStore()
    s.person("rv1", NAME, phones=[PHONE_E164], emails=["robin.one@example.com"],
             uids=["uid-card-icloud-1"])
    s.person("rv2", NAME, phones=[PHONE_E164], emails=["robin.two@example.com"],
             uids=["uid-card-exchange-2"])
    make(s, tmp_path).converge(backup_dir=str(tmp_path / "bk"))
    assert len(s.live()) == 1
    _, merges = journal(tmp_path)
    assert len(merges) == 1
    # The planted words live in action.details (the journal's own details
    # field is withheld), which is what the old code searched.
    assert merges[0]["shared_kinds"] == ["phone"]
    assert [k["kind"] for k in merges[0]["matched_keys"]] == ["phone"]


def test_a_merge_with_no_override_journals_no_kinds(box, tmp_path):
    """No RULE 2 conflict (one side has no card), so no override and no
    matched keys: shared_kinds is empty rather than guessed."""
    s = FakeStore()
    s.person("rv1", NAME, phones=[PHONE_E164], uids=["uid-card-icloud-1"])
    s.person("rv2", NAME, phones=[PHONE_E164])
    make(s, tmp_path).converge(backup_dir=str(tmp_path / "bk"))
    assert len(s.live()) == 1
    _, merges = journal(tmp_path)
    assert len(merges) == 1
    assert merges[0]["override"] == ""
    assert merges[0]["shared_kinds"] == []
    assert merges[0]["matched_keys"] == []


# --------------------------------------------------------------------------
# Condition 5: a missing secret never blocks dedupe.
# --------------------------------------------------------------------------
@pytest.mark.parametrize("state", ["absent", "empty"])
def test_missing_secret_still_merges_and_says_why(tmp_path, monkeypatch, state):
    root = tmp_path / "ostler"
    (root / "secrets").mkdir(parents=True)
    if state == "empty":
        (root / "secrets" / "service_token").write_text("")
    monkeypatch.delenv("OSTLER_HOME", raising=False)
    monkeypatch.setenv("OSTLER_DIR", str(root))
    s = FakeStore()
    two_cards(s, phones=[PHONE_E164])
    make(s, tmp_path).converge(backup_dir=str(tmp_path / "bk"))
    assert len(s.live()) == 1                       # the merge still happened
    raw, merges = journal(tmp_path)
    assert len(merges) == 1
    assert merges[0]["override"] == "exact_identifier:phone"
    assert merges[0]["matched_keys"] == [{"kind": "phone", "hash": None}]
    assert merges[0]["matched_keys_reason"] == "journal_secret_unavailable"
    assert merges[0]["shared_kinds"] == ["phone"]
    assert PHONE_DIGITS not in raw.decode()
