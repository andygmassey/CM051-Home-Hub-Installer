"""Tests for the POST /api/v1/subscription/receipt endpoint (G1).

The endpoint is the Hub-side counterpart to the iOS Companion's
``SubscriptionReceiptSync`` (CM031 PR companion to this one). It takes a
StoreKit-derived ``{receipt_b64, expires_at}`` payload, persists state
via the G0 ``subscription_gate.refresh_from_companion`` helper, and
returns the resulting status (``active|grace|inactive``).

Synthetic-fixture-only: NEVER touches real Apple receipts. The state
file is redirected via ``OSTLER_SUBSCRIPTION_STATE`` to a per-test temp
path so concurrent test runs cannot collide and nothing is ever written
to the operator's real ``~/.ostler`` tree.

Coverage map:

- Valid body persists state + returns 200 with ``{"status": "active"}``.
- Missing ``receipt_b64`` returns 400 (and no state is written).
- Empty / non-string ``receipt_b64`` returns 400.
- Missing ``expires_at`` returns 400.
- Unparseable ``expires_at`` returns 400.
- Non-dict body returns 400 (defends against ``[]`` / ``"x"`` payloads).
- The do_POST dispatcher routes the endpoint (source-grep regression).
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent
ASSISTANT_API_DIR = THIS_DIR.parent
ICAL_SERVER_PY = ASSISTANT_API_DIR / "ical-server.py"

# Put assistant_api/ on sys.path so ``import subscription_gate`` from the
# api function resolves to the vendored helper rather than (e.g.) a
# stale install.
sys.path.insert(0, str(ASSISTANT_API_DIR))


def _install_stub_ostler_security():
    """Match the wire-shape suite's stub: ical-server hard-fails without it."""
    if "ostler_security" in sys.modules:
        return
    pkg = types.ModuleType("ostler_security")
    pkg.__path__ = []
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
    if "ical_server" in sys.modules:
        return sys.modules["ical_server"]
    _install_stub_ostler_security()
    spec = importlib.util.spec_from_file_location(
        "ical_server", str(ICAL_SERVER_PY)
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["ical_server"] = module
    spec.loader.exec_module(module)
    return module


ical_server = _load_ical_server()


# Synthetic fixtures only. NEVER real Apple data.
SYNTHETIC_RECEIPT = "test-receipt-b64-AAAA"
SYNTHETIC_EXPIRES_AT = "2026-06-27T00:00:00Z"


class SubscriptionReceiptEndpointTests(unittest.TestCase):
    """Direct-call tests against ``api_subscription_receipt``.

    The endpoint is small enough (parse, validate, delegate) that we
    exercise the helper directly rather than spinning up an HTTPServer.
    The do_POST routing is covered by the source-grep regression below.
    """

    def setUp(self):
        # Redirect subscription state to a temp file so we never touch
        # the operator's real ``~/.ostler/state/subscription_state.json``.
        self._tmp_state = tempfile.NamedTemporaryFile(
            prefix="subscription-state-", suffix=".json", delete=False
        )
        self._tmp_state.close()
        # The G0 helper resolves _state_file() lazily from the env var,
        # so just setting it for the test lifetime is enough.
        self._prev = os.environ.get("OSTLER_SUBSCRIPTION_STATE")
        os.environ["OSTLER_SUBSCRIPTION_STATE"] = self._tmp_state.name
        # Tabula rasa: make sure no leftover state from previous runs.
        Path(self._tmp_state.name).unlink(missing_ok=True)

    def tearDown(self):
        if self._prev is None:
            os.environ.pop("OSTLER_SUBSCRIPTION_STATE", None)
        else:
            os.environ["OSTLER_SUBSCRIPTION_STATE"] = self._prev
        Path(self._tmp_state.name).unlink(missing_ok=True)

    def test_valid_body_returns_200_and_persists_state(self):
        """Happy path: valid receipt + expiry -> 200 active + file on disk."""
        result, status = ical_server.api_subscription_receipt(
            {
                "receipt_b64": SYNTHETIC_RECEIPT,
                "expires_at": SYNTHETIC_EXPIRES_AT,
            }
        )
        self.assertEqual(status, 200, msg=f"body={result!r}")
        self.assertEqual(result, {"status": "active"})
        # State file must exist + reflect the synthetic receipt.
        self.assertTrue(Path(self._tmp_state.name).exists())
        on_disk = json.loads(Path(self._tmp_state.name).read_text())
        self.assertEqual(on_disk.get("status"), "active")
        self.assertEqual(on_disk.get("source"), "companion")
        self.assertEqual(on_disk.get("receipt"), SYNTHETIC_RECEIPT)
        self.assertEqual(on_disk.get("expires_at"), SYNTHETIC_EXPIRES_AT)

    def test_missing_receipt_returns_400(self):
        result, status = ical_server.api_subscription_receipt(
            {"expires_at": SYNTHETIC_EXPIRES_AT}
        )
        self.assertEqual(status, 400)
        self.assertIn("error", result)
        # No state file should have been written.
        self.assertFalse(
            Path(self._tmp_state.name).exists(),
            "state file was written despite 400 response",
        )

    def test_empty_receipt_returns_400(self):
        result, status = ical_server.api_subscription_receipt(
            {"receipt_b64": "   ", "expires_at": SYNTHETIC_EXPIRES_AT}
        )
        self.assertEqual(status, 400)
        self.assertIn("error", result)

    def test_non_string_receipt_returns_400(self):
        result, status = ical_server.api_subscription_receipt(
            {"receipt_b64": 12345, "expires_at": SYNTHETIC_EXPIRES_AT}
        )
        self.assertEqual(status, 400)
        self.assertIn("error", result)

    def test_missing_expires_at_returns_400(self):
        result, status = ical_server.api_subscription_receipt(
            {"receipt_b64": SYNTHETIC_RECEIPT}
        )
        self.assertEqual(status, 400)
        self.assertIn("error", result)

    def test_invalid_expires_at_returns_400(self):
        result, status = ical_server.api_subscription_receipt(
            {
                "receipt_b64": SYNTHETIC_RECEIPT,
                "expires_at": "not-a-real-date",
            }
        )
        self.assertEqual(status, 400)
        self.assertIn("error", result)
        self.assertFalse(
            Path(self._tmp_state.name).exists(),
            "state file written for invalid expires_at",
        )

    def test_non_dict_body_returns_400(self):
        for bad_body in (["not", "a", "dict"], "string-body", 42, None):
            with self.subTest(body=bad_body):
                result, status = ical_server.api_subscription_receipt(bad_body)
                self.assertEqual(status, 400)
                self.assertIn("error", result)

    def test_expires_at_with_offset_accepted(self):
        """ISO-8601 with explicit offset (not just Z) must parse."""
        result, status = ical_server.api_subscription_receipt(
            {
                "receipt_b64": SYNTHETIC_RECEIPT,
                "expires_at": "2026-06-27T00:00:00+00:00",
            }
        )
        self.assertEqual(status, 200, msg=f"body={result!r}")
        self.assertEqual(result["status"], "active")


class SubscriptionReceiptRouteRegressionTests(unittest.TestCase):
    """Static-source regression: do_POST must route the new path.

    Mirrors the F-1 timeline regression pattern -- the do_POST
    dispatcher is too entangled with BaseHTTPRequestHandler to exercise
    cleanly in-process, so we source-grep the route block instead. If a
    future refactor drops the route, this test surfaces it.
    """

    def test_do_post_dispatches_subscription_receipt(self):
        source = ICAL_SERVER_PY.read_text(encoding="utf-8")
        # The route must appear inside the do_POST method block.
        do_post_idx = source.find("def do_POST(self):")
        self.assertGreater(do_post_idx, 0, "could not locate do_POST")
        # Take a generous slice; the routing block sits within the next
        # ~5KB. Asserts are independent so we don't slice too tight.
        block = source[do_post_idx : do_post_idx + 8000]
        self.assertIn(
            '"/api/v1/subscription/receipt"', block,
            "G1 regression: do_POST must route "
            "/api/v1/subscription/receipt to api_subscription_receipt",
        )
        self.assertIn(
            "api_subscription_receipt(payload)", block,
            "G1 regression: do_POST must call api_subscription_receipt",
        )


if __name__ == "__main__":
    unittest.main()
