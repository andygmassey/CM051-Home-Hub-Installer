"""F5 / walk #16: places-ingest printed
    "Done: 979 places (0 written, 979 errors) ... status=ok"
because the status was set before the upsert and never revisited. A step whose
writes ALL fail must report an error, not ok (and a partial failure must not
be ok either). Synthetic data only.

The Qdrant client is stubbed at the HTTP boundary (upsert raises, as the box's
HTTP 500 did); the real upsert_places and ingest_places run on top of it.
Runs against BOTH copies: contact_syncer/ (what install.sh cp -R's into the
pipeline) and vendor/cm041/contact_syncer/.
"""
from __future__ import annotations

import importlib.util
import pathlib
import sys

import pytest

ROOT = pathlib.Path(__file__).resolve().parent.parent
COPIES = [ROOT / "contact_syncer" / "places_ingest.py",
          ROOT / "vendor" / "cm041" / "contact_syncer" / "places_ingest.py"]


def _load(path):
    pkg_root = path.parent.parent
    sys.path.insert(0, str(pkg_root))
    try:
        for m in [m for m in sys.modules if m == "contact_syncer" or m.startswith("contact_syncer.")]:
            del sys.modules[m]
        spec = importlib.util.spec_from_file_location("contact_syncer.places_ingest", path)
        mod = importlib.util.module_from_spec(spec)
        sys.modules["contact_syncer.places_ingest"] = mod
        spec.loader.exec_module(mod)
        return mod
    finally:
        sys.path.remove(str(pkg_root))


class _FailingQdrant:
    def __init__(self, url=None, **kw):
        pass

    def collection_exists(self, name):
        return True

    def get_collection(self, name):
        raise RuntimeError("stub")

    def upsert(self, **kw):
        raise RuntimeError("HTTP 500 Too many open files (os error 24)")


class _OkQdrant(_FailingQdrant):
    def upsert(self, **kw):
        return None


def _rows(mod, n):
    return [{"location": "Room %d, Testtown" % i, "date": "2026-10-0%d" % (1 + i % 9)}
            for i in range(n)]


def _run(mod, monkeypatch, client, n=5):
    import qdrant_client
    monkeypatch.setattr(qdrant_client, "QdrantClient", client)
    monkeypatch.setattr(mod, "read_meeting_locations", lambda url: _rows(mod, n))
    monkeypatch.setattr(mod, "read_photo_places", lambda url: [])
    return mod.ingest_places(oxigraph_url="http://x", qdrant_url="http://y")


@pytest.mark.parametrize("path", COPIES, ids=["contact_syncer", "vendor_cm041"])
def test_all_writes_failing_is_an_error_not_ok(path, monkeypatch):
    mod = _load(path)
    r = _run(mod, monkeypatch, _FailingQdrant)
    assert r["places"] > 0 and r["written"] == 0 and r["errors"] == r["places"], r
    assert r["status"] == "error_write_failed", r


@pytest.mark.parametrize("path", COPIES, ids=["contact_syncer", "vendor_cm041"])
def test_control_clean_writes_are_still_ok(path, monkeypatch):
    mod = _load(path)
    r = _run(mod, monkeypatch, _OkQdrant)
    assert r["written"] == r["places"] > 0 and r["errors"] == 0, r
    assert r["status"] == "ok", r


@pytest.mark.parametrize("path", COPIES, ids=["contact_syncer", "vendor_cm041"])
def test_main_prints_error_status_and_exits_nonzero(path, monkeypatch, capsys):
    mod = _load(path)
    import qdrant_client
    monkeypatch.setattr(qdrant_client, "QdrantClient", _FailingQdrant)
    monkeypatch.setattr(mod, "read_meeting_locations", lambda url: _rows(mod, 5))
    monkeypatch.setattr(mod, "read_photo_places", lambda url: [])
    monkeypatch.setattr(mod.config, "OXIGRAPH_URL", "http://x", raising=False)
    monkeypatch.setattr(mod.config, "QDRANT_URL", "http://y", raising=False)
    monkeypatch.setattr(sys, "argv", ["places_ingest"])
    rc = mod.main()
    out = capsys.readouterr().out
    assert rc == 1
    assert "status=ok" not in out and "status=error_write_failed" in out, out
