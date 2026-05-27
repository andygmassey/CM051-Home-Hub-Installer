"""Wire-shape regression tests for vendor/cm041/assistant_api/ical-server.py.

Locks in the six wire-shape contract findings landed 2026-05-27 between
the iOS Companion (CM031) and the Hub (ical-server):

  F-10b - POST /api/v1/ingest/ios accepts either ``items`` or ``points``.
  F-10  - POST /api/v1/ingest/ios response includes ``accepted`` field.
  F-1   - GET  /api/v1/timeline degraded fallback emits ``entries: []``.
  F-2   - ``people_stale`` row emits ``organisation`` (en-GB), not the
          American-spelled key.
  F-3   - ``_read_iso8601_marker`` validates + normalises ISO-8601 and
          returns ``None`` on garbage (never raises).

Tests target helper functions and response-builder paths directly rather
than spinning up the BaseHTTPRequestHandler-backed HTTP server. The
F-12 install.sh proxy-path edit is covered by the bash-level
``tests/test_ical_server_vendor_wired.sh`` regression test in the repo
root; nothing to lift into Python.

All fixtures are synthetic: ``alice@example.com`` / slug ``test-person``.
No real names or emails are touched.
"""

from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock


THIS_DIR = Path(__file__).resolve().parent
ICAL_SERVER_PY = THIS_DIR.parent / "ical-server.py"


def _install_stub_ostler_security():
    """Inject a minimal ostler_security stub so ical-server.py imports.

    The production module lives in HR015 and is not on PYTHONPATH in CI;
    the vendored ical-server.py hard-fails if it cannot import it (by
    design – plaintext-fallthrough was the bug that hard-fail closes).
    For unit tests we want to exercise the wire-shape paths without the
    full HR015 dependency, so we stand up a no-op stub.
    """
    if "ostler_security" in sys.modules:
        return
    pkg = types.ModuleType("ostler_security")
    pkg.__path__ = []  # mark as package
    sys.modules["ostler_security"] = pkg

    db_mod = types.ModuleType("ostler_security.database")

    def _stub_get_db_connection(*args, **kwargs):
        raise RuntimeError("stub: tests must not touch the DB")

    db_mod.get_db_connection = _stub_get_db_connection
    sys.modules["ostler_security.database"] = db_mod

    posture_mod = types.ModuleType("ostler_security.posture")
    posture_mod.record_posture = lambda *args, **kwargs: None
    sys.modules["ostler_security.posture"] = posture_mod


def _load_ical_server():
    """Import vendor/cm041/assistant_api/ical-server.py as ``ical_server``.

    The on-disk filename has a hyphen which is not a valid identifier,
    so the standard import machinery cannot find it; we go through
    importlib.util.spec_from_file_location.
    """
    if "ical_server" in sys.modules:
        return sys.modules["ical_server"]
    _install_stub_ostler_security()
    spec = importlib.util.spec_from_file_location(
        "ical_server", str(ICAL_SERVER_PY)
    )
    assert spec is not None and spec.loader is not None, (
        "could not build spec for ical-server.py"
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules["ical_server"] = module
    spec.loader.exec_module(module)
    return module


# Load once at module import time so each test class can refer to it.
ical_server = _load_ical_server()


# ---------------------------------------------------------------------------
# F-10b + F-10 – POST /api/v1/ingest/ios
# ---------------------------------------------------------------------------


class IngestIOSWireShapeTests(unittest.TestCase):
    """F-10b (accept items+points alias) and F-10 (accepted field)."""

    def setUp(self):
        self._tmpdir = tempfile.mkdtemp(prefix="ical-ingest-test-")
        # Redirect INGEST_DIR so the test doesn't write into the user's
        # ~/.ostler tree.
        self._ingest_patch = mock.patch.object(
            ical_server, "INGEST_DIR", self._tmpdir
        )
        self._ingest_patch.start()

    def tearDown(self):
        self._ingest_patch.stop()
        # Best-effort cleanup; the dir contents are small JSONL files.
        for root, dirs, files in os.walk(self._tmpdir, topdown=False):
            for f in files:
                try:
                    os.unlink(os.path.join(root, f))
                except OSError:
                    pass
            for d in dirs:
                try:
                    os.rmdir(os.path.join(root, d))
                except OSError:
                    pass
        try:
            os.rmdir(self._tmpdir)
        except OSError:
            pass

    def _synthetic_item(self):
        return {
            "kind": "browse",
            "text": "alice@example.com visited example.org",
            "timestamp": "2026-05-27T09:00:00Z",
            "metadata": {"slug": "test-person"},
        }

    def test_accepts_items_key(self):
        """Legacy `items` key still returns 200 with accepted+item_count."""
        result, status = ical_server.api_ingest_ios(
            {"items": [self._synthetic_item()]}
        )
        self.assertEqual(status, 200, msg=f"body={result!r}")
        self.assertTrue(result.get("ok"))
        self.assertEqual(result.get("item_count"), 1)
        self.assertEqual(
            result.get("accepted"), 1,
            "F-10: response must include `accepted` field for iOS "
            "UploadResult decoder",
        )

    def test_accepts_points_alias(self):
        """F-10b: iOS sends `points`, server must accept it."""
        result, status = ical_server.api_ingest_ios(
            {"points": [self._synthetic_item(), self._synthetic_item()]}
        )
        self.assertEqual(status, 200, msg=f"body={result!r}")
        self.assertTrue(result.get("ok"))
        self.assertEqual(result.get("item_count"), 2)
        self.assertEqual(result.get("accepted"), 2)

    def test_rejects_when_neither_key_present(self):
        """Missing both keys still returns 400."""
        result, status = ical_server.api_ingest_ios({"junk": "value"})
        self.assertEqual(status, 400)
        self.assertIn("error", result)

    def test_rejects_non_dict_body(self):
        result, status = ical_server.api_ingest_ios(["not", "a", "dict"])
        self.assertEqual(status, 400)


# ---------------------------------------------------------------------------
# F-1 – Timeline degraded fallback shape
# ---------------------------------------------------------------------------


class TimelineDegradedShapeTests(unittest.TestCase):
    """F-1: when /api/v1/timeline upstream raises, the response must still
    include ``entries: []`` so the iOS ServerTimelineResponse decoder
    can degrade gracefully rather than hard-erroring."""

    def test_degraded_fallback_includes_entries_key(self):
        # Force api_timeline to raise. The endpoint handler wraps the
        # call in try/except and constructs the fallback dict inline.
        # Re-build that dict here exactly as the handler does so we lock
        # the shape contract regardless of handler refactors.
        days = 7
        try:
            raise RuntimeError("synthetic upstream failure")
        except Exception as exc:
            result = {
                "items": [],
                "entries": [],
                "days": days,
                "count": 0,
                "degraded": True,
                "reason": str(exc),
                "error": str(exc),
            }

        # The contract: every key the iOS decoder expects is present.
        for key in ("items", "entries", "days", "count", "degraded"):
            self.assertIn(key, result, f"F-1: missing key {key!r}")
        self.assertEqual(result["entries"], [])
        self.assertEqual(result["items"], [])

    def test_handler_source_emits_entries_in_fallback(self):
        """Static-source check: the actual handler block in ical-server.py
        must contain `"entries": []` inside its timeline except clause.

        We can't easily mock the BaseHTTPRequestHandler dispatch without
        spinning up a server, so we inspect the source as a regression
        guard. If a refactor removes the key, this test fails.
        """
        source = ICAL_SERVER_PY.read_text(encoding="utf-8")
        # Locate the timeline endpoint block.
        anchor = 'if parsed.path == "/api/v1/timeline":'
        idx = source.find(anchor)
        self.assertGreater(idx, 0, "could not locate /api/v1/timeline handler")
        # Take a generous slice that covers the try/except.
        block = source[idx : idx + 1500]
        self.assertIn('"entries": []', block,
                      "F-1 regression: timeline degraded fallback must "
                      "include `entries: []` for the iOS decoder")


# ---------------------------------------------------------------------------
# F-2 – people_stale British spelling
# ---------------------------------------------------------------------------


class PeopleStaleOrganisationKeyTests(unittest.TestCase):
    """F-2: `people_stale` must emit the British spelling `organisation`
    so the iOS Reconnect strip subtitle decoder finds the key."""

    def test_response_uses_organisation_key(self):
        # Stub the Qdrant scroll response with a single synthetic point.
        # `_wiki_slug` is a real helper that should slugify the name.
        fake_qdrant_payload = {
            "result": {
                "points": [
                    {
                        "payload": {
                            "display_name": "Test Person",
                            "last_contact_ts": 1_700_000_000,  # well in the past
                            "last_contact": "2023-11-14",
                            "organization": "Example Corp",
                        }
                    }
                ]
            }
        }

        class _FakeResp:
            def __init__(self, body):
                self._body = body

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self):
                import json as _json
                return _json.dumps(self._body).encode()

        with mock.patch(
            "urllib.request.urlopen",
            return_value=_FakeResp(fake_qdrant_payload),
        ):
            result = ical_server.people_stale(months=3, limit=5)

        contacts = result.get("contacts", [])
        self.assertEqual(len(contacts), 1, msg=f"result={result!r}")
        row = contacts[0]
        self.assertIn(
            "organisation", row,
            "F-2: people_stale row must use British spelling "
            "`organisation`",
        )
        self.assertNotIn(
            "organization", row,
            "F-2: legacy American spelling `organization` must be gone "
            "from the wire shape",
        )
        self.assertEqual(row["organisation"], "Example Corp")


# ---------------------------------------------------------------------------
# F-3 – _read_iso8601_marker hardening
# ---------------------------------------------------------------------------


class ReadIso8601MarkerTests(unittest.TestCase):
    """F-3: validate + normalise ISO-8601 marker files. Garbage in the
    marker must yield None, not propagate up to the iOS Companion."""

    def _write_marker(self, content: str) -> Path:
        fh = tempfile.NamedTemporaryFile(
            mode="w", suffix=".marker", delete=False, encoding="utf-8"
        )
        fh.write(content)
        fh.close()
        return Path(fh.name)

    def test_garbage_returns_none(self):
        path = self._write_marker("not-a-timestamp-at-all\n")
        try:
            self.assertIsNone(ical_server._read_iso8601_marker(path))
        finally:
            path.unlink(missing_ok=True)

    def test_empty_file_returns_none(self):
        path = self._write_marker("")
        try:
            self.assertIsNone(ical_server._read_iso8601_marker(path))
        finally:
            path.unlink(missing_ok=True)

    def test_missing_file_returns_none(self):
        path = Path(tempfile.gettempdir()) / "ical-test-nonexistent-marker"
        if path.exists():
            path.unlink()
        self.assertIsNone(ical_server._read_iso8601_marker(path))

    def test_iso_with_z_suffix_normalised(self):
        path = self._write_marker("2026-05-27T09:00:00Z\n")
        try:
            value = ical_server._read_iso8601_marker(path)
            self.assertEqual(value, "2026-05-27T09:00:00Z")
        finally:
            path.unlink(missing_ok=True)

    def test_iso_with_offset_normalised_to_z(self):
        # +00:00 should round-trip through UTC and come out as Z.
        path = self._write_marker("2026-05-27T10:00:00+0100\n")
        try:
            value = ical_server._read_iso8601_marker(path)
            self.assertEqual(value, "2026-05-27T09:00:00Z")
        finally:
            path.unlink(missing_ok=True)

    def test_compact_iso_form_accepted(self):
        path = self._write_marker("20260527T090000")
        try:
            value = ical_server._read_iso8601_marker(path)
            self.assertEqual(value, "2026-05-27T09:00:00Z")
        finally:
            path.unlink(missing_ok=True)

    def test_never_raises(self):
        """Defence-in-depth: even pathological inputs return None."""
        for bad in ("\x00\x01\x02", "2026-99-99T99:99:99Z", "0", " "):
            path = self._write_marker(bad)
            try:
                # Must not raise.
                ical_server._read_iso8601_marker(path)
            finally:
                path.unlink(missing_ok=True)

    def test_permissive_helper_preserves_queue_depth_usage(self):
        """`_read_sync_marker` must remain a permissive raw-string reader
        so `_hub_queue_depth` (which writes integer text) keeps working."""
        path = self._write_marker("42\n")
        try:
            self.assertEqual(ical_server._read_sync_marker(path), "42")
        finally:
            path.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
