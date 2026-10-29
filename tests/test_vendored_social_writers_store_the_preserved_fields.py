"""NEW-119 (same data-loss class as board row 963): in the vendored CM041
social writers (facebook_friends, linkedin_connections, instagram_social) the
qdrant PointStruct was built BEFORE the preservation block ran. pydantic
validates `payload` into its own dict, so every field the preservation block
then wrote into `payload` never reached the store: a richer stored record
(newer last_contact, a better source, organisation, emails, phones, a
close_friend hint) was overwritten with the importer's poorer values.

Tests the copy that SHIPS (vendor/cm041), end to end through each writer's
real upsert_qdrant and the real qdrant_client PointStruct, against a fake
store that keeps what upsert received. Synthetic data only (example.com,
OFCOM drama-range numbers).
"""
from __future__ import annotations

import copy
import pathlib
import sys
import uuid
from types import SimpleNamespace

import pytest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm041"))

from contact_syncer import (  # noqa: E402
    facebook_friends,
    instagram_social,
    linkedin_connections,
)
from identity_resolver.models import PersonIdentity  # noqa: E402

COLL = "people"
URI = "https://example.com/person/p1"
OLD_TS = 1433116800  # 2015-06-01, older than the stored record
RICH = {
    "person_id": "p1",
    "person_uri": URI,
    "display_name": "Jane Doe",
    "given_name": "Jane",
    "family_name": "Doe",
    "organization": "Acme",
    "job_title": "Engineer",
    "emails": ["sample@example.com"],
    "phones": ["+447700900123"],
    "source": "icloud_contacts",
    "last_contact": "2026-03-01",
    "last_contact_ts": 1772323200,
    "relationship_hint": "close_friend",
}


class FakeStore:
    def __init__(self, points):
        self.points = {k: copy.deepcopy(v) for k, v in points.items()}
        self.upserts = 0

    def retrieve(self, collection_name, ids, with_payload=True):
        return [SimpleNamespace(id=i, payload=copy.deepcopy(self.points[i]))
                for i in ids if i in self.points]

    def collection_exists(self, name):
        return True

    def upsert(self, collection_name, points):
        self.upserts += 1
        for p in points:
            self.points[p.id] = copy.deepcopy(p.payload)


PID = str(uuid.uuid5(uuid.NAMESPACE_URL, URI))


def _identity():
    return PersonIdentity(display_name="sample", given_name="", family_name="")


def _fb(store):
    facebook_friends.upsert_qdrant(
        store, COLL, "p1", URI, _identity(),
        {"friended_on": "2015-06-01", "timestamp": OLD_TS}, [0.1, 0.2], "L2")


def _li(store):
    linkedin_connections.upsert_qdrant(
        store, COLL, "p1", URI, _identity(),
        {"connected_on": "01 Jun 2015"}, [0.1, 0.2], "L2")


def _ig(store):
    instagram_social.upsert_qdrant(
        store, COLL, "p1", URI, _identity(), "sample_handle",
        "https://example.com/sample_handle", [0.1, 0.2], "L2",
        "follower", False, OLD_TS)


# writer, its own source label, the fields its preservation block keeps
WRITERS = [
    ("facebook_friends", _fb, ("last_contact", "last_contact_ts", "source")),
    ("linkedin_connections", _li, ("last_contact", "last_contact_ts", "source")),
    ("instagram_social", _ig, (
        "last_contact", "last_contact_ts", "source", "relationship_hint",
        "organization", "job_title", "given_name", "family_name",
        "emails", "phones",
    )),
]


@pytest.mark.parametrize("label,write,preserved", WRITERS, ids=[w[0] for w in WRITERS])
def test_every_preserved_field_is_still_stored_after_a_write(label, write, preserved):
    store = FakeStore({PID: RICH})
    write(store)
    assert store.upserts == 1, "the writer did not write at all"
    stored = store.points[PID]
    lost = {f: (RICH[f], stored.get(f)) for f in preserved if stored.get(f) != RICH[f]}
    assert not lost, "%s overwrote preserved field(s) {field: (was, now)}: %r" % (label, lost)


@pytest.mark.parametrize("label,write,preserved", WRITERS, ids=[w[0] for w in WRITERS])
def test_control_a_new_point_carries_the_importers_own_values(label, write, preserved):
    # Proves the store sees what the writer built: with nothing to preserve,
    # the importer's own source and older date are what get stored.
    store = FakeStore({})
    write(store)
    stored = store.points[PID]
    assert stored["source"] == label
    assert stored["last_contact_ts"] != RICH["last_contact_ts"]
