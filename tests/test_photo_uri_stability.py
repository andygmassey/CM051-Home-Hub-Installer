"""A photo's graph node must survive the sentinel fix: re-ingest must not mint a second.

The URI is a hash of the date and a coordinate key. The old extractor wrote the
sentinel as a real coordinate, so a no-location photo's key was "-180.0,-180.0".
The fixed extractor clears the coordinate to None; if the key were derived from the
cleaned value, re-ingest would mint a second PhotoEvent beside each migrated one.

Synthetic events and a real pyoxigraph store only. No real date, place or photo.
"""
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

import pyoxigraph as pyox  # hard import: a missing engine is a collection error, never a skip
import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "vendor"))
sys.path.insert(0, str(REPO / "scripts"))

from ostler_fda import pwg_ingest as m  # noqa: E402
import repair_photo_sentinel_coordinates as rep  # noqa: E402

DATE = "2024-03-01 10:00:00+00:00"
PREFIX = "PREFIX pwg: <https://schema.ostler.ai/ontology#>\n"


class _Store:
    def __init__(self):
        self.store = pyox.Store()

    def update(self, q):
        self.store.update(q)

    def select_int(self, q):
        rows = list(self.store.query(q))
        return int(rows[0]["n"].value) if rows else 0


def _event_nodes(store):
    q = PREFIX + "SELECT DISTINCT ?e WHERE { ?e a pwg:PhotoEvent }"
    return sorted(str(r["e"].value) for r in store.store.query(q))


def _ingest(store, events):
    d = Path(tempfile.mkdtemp())
    (d / "photos_events.json").write_text(json.dumps(events))
    with _patched(store):
        return m.ingest_photo_events(d)


class _patched:
    def __init__(self, store):
        self.store, self.ctx = store, None

    def __enter__(self):
        import unittest.mock as um
        self.ctx = um.patch.object(m, "_sparql_update", side_effect=lambda q: self.store.update(q))
        self.ctx.start()
        return self

    def __exit__(self, *a):
        self.ctx.stop()


def _old_style_event(lat, lon):
    # What the pre-fix extractor wrote: the raw store value, sentinel included.
    return {"date": DATE, "latitude": lat, "longitude": lon, "location": None, "people": []}


def _fixed_style_event(uri_key):
    # What the fixed extractor writes: cleaned coordinates, and the key from the raw values.
    return {"date": DATE, "latitude": None, "longitude": None, "location": None,
            "people": [], "uri_key": uri_key}


def test_red_arm_migrate_then_reingest_gives_one_node_not_two():
    store = _Store()
    _ingest(store, [_old_style_event(-180.0, -180.0)])            # the graph as it is today
    before = _event_nodes(store)
    assert len(before) == 1

    code, report = rep.repair(store, apply=True)                   # the sentinel migration
    assert code == 0, report

    _ingest(store, [_fixed_style_event("-180.0,-180.0")])          # the next ingest, same asset
    after = _event_nodes(store)
    assert after == before, f"re-ingest minted a second PhotoEvent: {before} -> {after}"
    assert len(after) == 1


def test_control_a_located_photo_keeps_its_uri_through_the_fix():
    store = _Store()
    _ingest(store, [_old_style_event(35.612345, 139.712345)])
    before = _event_nodes(store)
    _ingest(store, [{"date": DATE, "latitude": 35.612345, "longitude": 139.712345,
                     "location": None, "people": [], "uri_key": "35.612345,139.712345"}])
    assert _event_nodes(store) == before


def test_without_uri_key_the_legacy_formula_still_reuses_a_located_node():
    store = _Store()
    _ingest(store, [_old_style_event(35.612345, 139.712345)])
    before = _event_nodes(store)
    _ingest(store, [_old_style_event(35.612345, 139.712345)])     # an old-format file
    assert _event_nodes(store) == before
