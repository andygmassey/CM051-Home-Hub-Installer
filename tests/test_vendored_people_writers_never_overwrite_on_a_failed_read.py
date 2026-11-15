"""Board row 963 (BLOCKING, data loss): in the vendored CM041 people syncer a
failed Qdrant read was swallowed by a bare `pass` and the UNCONDITIONAL upsert
that followed replaced the stored record with a partial one. A failed read now
skips the write, logs it and counts it.

Tests the copy that SHIPS (vendor/cm041). Writers covered: contact_syncer
ContactSyncer._upsert_qdrant (the bare-pass hit) plus the facebook_friends and
linkedin_connections upsert_qdrant (already skipped on a failed read, but read
an undefined name `existing` once a point WAS readable: NameError).
Synthetic data only (example.com, OFCOM drama-range numbers).
"""
from __future__ import annotations

import copy
import json
import pathlib
import sys
from types import SimpleNamespace
from unittest.mock import MagicMock

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm041"))

from contact_syncer import facebook_friends, linkedin_connections  # noqa: E402
from contact_syncer.syncer import ContactSyncer  # noqa: E402
from identity_resolver.models import PersonIdentity  # noqa: E402

COLL = "people"
RICH = {
    "person_id": "p1", "display_name": "rich-record", "organization": "example-org",
    "job_title": "Engineer", "emails": ["sample@example.com"], "phones": ["+447700900123"],
    "source": "icloud_contacts", "last_contact": "2026-03-01",
    "last_contact_ts": 1772323200,
}


class FakeStore:
    """A fake store: one collection, retrieve can be made to fail."""

    def __init__(self, point_id_payloads, fail=None):
        self.points = {k: copy.deepcopy(v) for k, v in point_id_payloads.items()}
        self.fail = fail
        self.upserts = 0

    def retrieve(self, collection_name, ids, with_payload=True):
        if self.fail:
            raise self.fail
        return [SimpleNamespace(id=i, payload=self.points[i]) for i in ids if i in self.points]

    def collection_exists(self, name):
        return True

    def upsert(self, collection_name, points):
        self.upserts += 1
        for p in points:
            self.points[p.id] = copy.deepcopy(p.payload)

    def snapshot(self):
        return json.dumps(self.points, sort_keys=True)


def _syncer(store):
    s = ContactSyncer.__new__(ContactSyncer)
    cfg = MagicMock()
    cfg.DEFAULT_PRIVACY_LEVEL = "L2"
    cfg.QDRANT_COLLECTION = COLL
    s.cfg, s.qdrant = cfg, store
    s.resolver = MagicMock()
    s.resolver.default_country_code = 44
    s._ensure_qdrant_collection = lambda n: None
    return s


def _pid(uri):
    import uuid
    return str(uuid.uuid5(uuid.NAMESPACE_URL, uri))


URI = "https://example.com/person/p1"
PARSED = {"fn": "partial-write", "uid": "u-1", "phones": [], "emails": []}


def _call_syncer(store):
    s = _syncer(store)
    r = s._upsert_qdrant("p1", URI, PARSED, [0.0] * 4)
    return s, r


def test_syncer_failed_read_leaves_record_byte_identical():
    store = FakeStore({_pid(URI): RICH}, fail=ConnectionError("store blip"))
    before = store.snapshot()
    s, r = _call_syncer(store)
    assert store.snapshot() == before
    assert store.upserts == 0
    assert r is False
    assert s.qdrant_writes_skipped_unreadable == 1


def test_syncer_readable_point_is_still_written_and_keeps_last_contact():
    store = FakeStore({_pid(URI): RICH})
    s, r = _call_syncer(store)
    out = store.points[_pid(URI)]
    assert r is True and store.upserts == 1
    assert out["last_contact_ts"] == RICH["last_contact_ts"]
    assert out["display_name"] == "partial-write"
    assert s.qdrant_writes_skipped_unreadable == 0


def test_syncer_missing_collection_is_a_first_run_write_not_a_skip():
    class Missing(Exception):
        status_code = 404

    store = FakeStore({}, fail=Missing("Collection `people` doesn't exist!"))
    s, r = _call_syncer(store)
    store.fail = None
    assert r is True and store.upserts == 1


def _ident():
    return PersonIdentity(display_name="rich-record", given_name="", family_name="",
                          organization="", icloud_uid="", phones=[], emails=[])


def _social(mod, store, uri):
    extra = ({"friended_on": "2026-01-01", "timestamp": 1767225600}
             if mod is facebook_friends else {"connected_on": "2026-01-01"})
    mod.upsert_qdrant(store, COLL, "p1", uri, _ident(), extra, [0.0] * 4, "L2")


def test_social_writers_failed_read_leaves_record_byte_identical():
    for mod in (facebook_friends, linkedin_connections):
        uri = f"https://example.com/person/{mod.__name__}"
        store = FakeStore({_pid(uri): RICH}, fail=ConnectionError("store blip"))
        before = store.snapshot()
        _social(mod, store, uri)
        assert store.snapshot() == before, mod.__name__
        assert store.upserts == 0, mod.__name__


def test_social_writers_readable_point_does_not_raise():
    # Only "does not raise and writes once". Whether the preserved fields
    # reach the stored point is a SEPARATE defect (PointStruct is built
    # before preservation mutates `payload`, and pydantic copies it), not
    # asserted here.
    for mod in (facebook_friends, linkedin_connections):
        uri = f"https://example.com/person/{mod.__name__}"
        store = FakeStore({_pid(uri): RICH})
        _social(mod, store, uri)  # NameError on main
        assert store.upserts == 1, mod.__name__
