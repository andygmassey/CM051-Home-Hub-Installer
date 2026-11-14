"""RED/GREEN for the photo sentinel repair, against a REAL SPARQL engine.

pyoxigraph is the engine that backs the production store, so these tests run the
same SPARQL the install runs. Every fixture is synthetic: no real dates, places or
coordinates. Coordinates are placed in the Pacific, the place the -180 sentinel
produced, and in plain test values.
"""
import importlib.util
import os
import sys

import pytest

pyox = pytest.importorskip("pyoxigraph")

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import repair_photo_sentinel_coordinates as rep  # noqa: E402

PWG = rep.PWG
XSD_DOUBLE = "http://www.w3.org/2001/XMLSchema#double"
XSD_DATETIME = "http://www.w3.org/2001/XMLSchema#dateTime"
GRAPH = pyox.NamedNode("https://example.test/graph/side")


class PyStore:
    """Adapter giving the real pyoxigraph store the same surface as HttpStore."""

    def __init__(self, store):
        self.store = store

    def select_int(self, query):
        rows = list(self.store.query(query))
        return int(rows[0]["n"].value) if rows else 0

    def update(self, stmt):
        self.store.update(stmt)


def _lit(value, datatype):
    return pyox.Literal(str(value), datatype=pyox.NamedNode(datatype))


def _event(store, graph, name, date, lat=None, lon=None):
    s = pyox.NamedNode(f"https://example.test/photo/{name}")
    p_date = pyox.NamedNode(PWG + "photoDate")
    quads = [pyox.Quad(s, p_date, _lit(date, XSD_DATETIME), graph)]
    if lat is not None:
        quads.append(pyox.Quad(s, pyox.NamedNode(PWG + "photoLatitude"), _lit(lat, XSD_DOUBLE), graph))
    if lon is not None:
        quads.append(pyox.Quad(s, pyox.NamedNode(PWG + "photoLongitude"), _lit(lon, XSD_DOUBLE), graph))
    for q in quads:
        store.add(q)


def _seed():
    """Five events: a full sentinel, a one-sided sentinel, a boundary value, a named-graph
    sentinel, and two valid events (one default graph, one named graph)."""
    st = pyox.Store()
    d = pyox.DefaultGraph()
    _event(st, d, "E1-both-sentinel", "2024-03-01T10:00:00", lat=-180, lon=-180)
    _event(st, d, "E2-valid", "2024-05-02T09:00:00", lat=35.6, lon=139.7)
    _event(st, d, "E3-lat-only-sentinel", "2024-06-03T08:00:00", lat=-180, lon=51.5)
    _event(st, d, "E4-boundary-minus179", "2024-07-04T07:00:00", lat=-179.0, lon=10.0)
    _event(st, GRAPH, "E5-named-sentinel", "2024-08-05T06:00:00", lat=-179.5, lon=-180)
    _event(st, GRAPH, "E6-named-valid", "2024-09-06T05:00:00", lat=51.5, lon=-0.12)
    return st


def _dates(st):
    q = (rep.PREFIX + "SELECT ?e ?d WHERE { { ?e pwg:photoDate ?d } UNION { GRAPH ?g { ?e pwg:photoDate ?d } } }")
    return sorted((str(r["e"]), str(r["d"])) for r in st.query(q))


def test_red_arm_sentinels_are_present_before_migration():
    st = PyStore(_seed())
    m = rep.measure(st)
    assert m["sentinel_events"] == 4          # E1, E3, E4 (boundary), E5 (named)
    assert m["date_triples"] == 6
    assert m["clean_coord_triples"] == 4      # E2 two, E6 two (clean events only)


def test_migration_leaves_no_sentinel_keeps_dates_and_valid_coords():
    st = PyStore(_seed())
    before_dates = _dates(st.store)
    assert len(before_dates) == 6
    code, report = rep.repair(st, apply=True)
    assert code == 0, report
    assert report["action"] == "deleted_and_verified"
    assert rep.measure(st)["sentinel_events"] == 0
    assert rep.measure(st)["sentinel_coord_triples"] == 0
    assert _dates(st.store) == before_dates              # every event keeps its date
    assert rep.measure(st)["clean_coord_triples"] == 4   # clean events untouched


def test_second_run_changes_nothing_and_issues_no_update():
    st = PyStore(_seed())
    rep.repair(st, apply=True)
    snapshot = sorted(str(q) for q in st.store)

    calls = []
    real_update = st.update
    st.update = lambda stmt: (calls.append(stmt), real_update(stmt))
    code, report = rep.repair(st, apply=True)
    assert code == 0
    assert report["action"] == "nothing_to_do"
    assert calls == []
    assert sorted(str(q) for q in st.store) == snapshot


def test_dry_run_changes_nothing():
    st = PyStore(_seed())
    before = sorted(str(q) for q in st.store)
    code, report = rep.repair(st, apply=False)
    assert code == 0 and report["action"] == "dry_run"
    assert sorted(str(q) for q in st.store) == before


def test_a_residue_fails_verification_and_refuses(monkeypatch):
    st = PyStore(_seed())
    # Sabotage: the update does nothing. Verification must refuse, not report success.
    monkeypatch.setattr(st, "update", lambda stmt: None)
    code, report = rep.repair(st, apply=True)
    assert code == 3
    assert report["action"] == "verify_failed_residue"


def test_marker_is_written_only_on_verified_run(tmp_path, monkeypatch):
    store_obj = _seed()
    monkeypatch.setattr(rep, "HttpStore", lambda *a, **k: PyStore(store_obj))
    marker = tmp_path / "state" / "repair_photo_sentinel_coords_v1.done"
    assert rep.main(["--apply", "--marker", str(marker)]) == 0
    assert marker.exists()
    text = marker.read_text()
    assert "deleted_and_verified" in text or "nothing_to_do" in text
    assert "35.6" not in text and "Pacific" not in text   # counts only


def test_store_unreachable_is_exit_2_not_silence(monkeypatch):
    def boom(*a, **k):
        raise OSError("connection refused")
    monkeypatch.setattr(rep, "HttpStore", boom)
    assert rep.main(["--apply"]) == 2
