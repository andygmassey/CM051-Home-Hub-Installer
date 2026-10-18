#!/usr/bin/env python3
"""tests/test_safari_extension_bearer_reaches_doctor.py

CM020 fix, v1.0.107, the OTHER half of the contract.

tests/test_safari_extension_paired_bearer_write.sh proves install.sh now
writes OSTLER_EXTENSION_TOKEN into the extension's App Group plist as
``pairedBearer``. This test proves that value is the ONE the Doctor
(vendor/doctor/agent/proxy.py) actually checks, and that it checks it --
the server-side half the audit called "already built and unused".

CAPTURE_AUDIT_2026-10-07.md, CM020 Send/Receive rows: the Doctor's
``_is_extension_credential`` predicate was reviewed in depth and never
reached in production, because nothing supplied a bearer for it to
compare. Before this PR that was true for two independent reasons (no
writer existed, and no test exercised the predicate with the SAME token a
real install generates). This test closes the second: it imports the real
module (not a reimplementation) and drives the exact predicate that
``proxy_request`` uses to decide between proxying the request and
returning ``401``.

Imports the real file via importlib rather than reimplementing the check,
so a future edit to the predicate is caught here, not just in prose.

Exit codes: 0 pass, 1 a case was wrong, 2 CANNOT-RUN (module import or
environ setup failed -- not a pass).
"""
from __future__ import annotations

import importlib.util
import os
import sys
import unittest
from pathlib import Path


def _load_proxy_module():
    repo_root = Path(__file__).resolve().parent.parent
    proxy_path = repo_root / "vendor" / "doctor" / "agent" / "proxy.py"
    if not proxy_path.is_file():
        print(f"CANNOT-RUN: {proxy_path} not found", file=sys.stderr)
        sys.exit(2)
    spec = importlib.util.spec_from_file_location("ostler_doctor_proxy", proxy_path)
    if spec is None or spec.loader is None:
        print(f"CANNOT-RUN: could not build an import spec for {proxy_path}", file=sys.stderr)
        sys.exit(2)
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception as exc:  # pragma: no cover - defensive
        print(f"CANNOT-RUN: importing proxy.py raised {exc!r}", file=sys.stderr)
        sys.exit(2)
    return module


PROXY = _load_proxy_module()

# The exact value install.sh generates (openssl rand -hex 32) and now writes
# into the extension's App Group plist as pairedBearer. This test does not
# care how the extension got it -- that is the shell test's job -- only
# that THIS value, presented as a client bearer, is the one the Doctor
# admits.
REAL_TOKEN = "a" * 64
WRONG_TOKEN = "b" * 64


class _FakeClient:
    def __init__(self, host: str) -> None:
        self.host = host


class _FakeRequest:
    """Stands in for a starlette Request. _is_extension_credential only
    touches .client.host and .method, both plain attribute reads."""

    def __init__(self, method: str, host: str = "127.0.0.1") -> None:
        self.method = method
        self.client = _FakeClient(host)


class ExtensionCredentialReachesTheRealIngestPath(unittest.TestCase):
    def setUp(self) -> None:
        self._prev = os.environ.get("OSTLER_EXTENSION_TOKEN")
        os.environ["OSTLER_EXTENSION_TOKEN"] = REAL_TOKEN

    def tearDown(self) -> None:
        if self._prev is None:
            os.environ.pop("OSTLER_EXTENSION_TOKEN", None)
        else:
            os.environ["OSTLER_EXTENSION_TOKEN"] = self._prev

    def test_the_bearer_the_extension_now_holds_is_admitted(self) -> None:
        """A send reaches the ingest endpoint with auth."""
        req = _FakeRequest("POST", "127.0.0.1")
        self.assertTrue(
            PROXY._is_extension_credential(req, REAL_TOKEN, "/api/safari/ingest"),
            "the Doctor rejected the exact token install.sh now pairs the "
            "extension with -- the fix would ship and the send would still "
            "401",
        )

    def test_a_wrong_token_is_rejected(self) -> None:
        """A wrong token gets a 401 (this predicate returning False is what
        makes proxy_request return Response(status_code=401) -- see
        proxy.py's dispatch: `if not authorized: return Response(...,
        status_code=401)` after this predicate is the last admitting
        check)."""
        req = _FakeRequest("POST", "127.0.0.1")
        self.assertFalse(
            PROXY._is_extension_credential(req, WRONG_TOKEN, "/api/safari/ingest"),
        )

    def test_an_empty_bearer_is_rejected(self) -> None:
        # The exact pre-fix shape: an unpaired extension sends no bearer.
        req = _FakeRequest("POST", "127.0.0.1")
        self.assertFalse(PROXY._is_extension_credential(req, "", "/api/safari/ingest"))

    def test_scoped_to_post_only(self) -> None:
        req = _FakeRequest("GET", "127.0.0.1")
        self.assertFalse(
            PROXY._is_extension_credential(req, REAL_TOKEN, "/api/safari/ingest"),
            "the extension credential must not open a GET -- it is a write "
            "credential for the customer's own browsing, not a reader",
        )

    def test_scoped_to_the_one_path(self) -> None:
        req = _FakeRequest("POST", "127.0.0.1")
        self.assertFalse(
            PROXY._is_extension_credential(req, REAL_TOKEN, "/api/v1/people"),
            "the extension credential must not widen past /api/safari/ingest",
        )

    def test_scoped_to_loopback(self) -> None:
        req = _FakeRequest("POST", "203.0.113.5")
        self.assertFalse(
            PROXY._is_extension_credential(req, REAL_TOKEN, "/api/safari/ingest"),
            "the extension credential must not be usable off-box",
        )

    def test_no_token_configured_means_nothing_is_admitted(self) -> None:
        # MUTATION: the exact shape of "OSTLER_EXTENSION_TOKEN never got
        # into the Doctor's own environment" -- must not go green on the
        # real token value appearing to validate by accident.
        os.environ.pop("OSTLER_EXTENSION_TOKEN", None)
        req = _FakeRequest("POST", "127.0.0.1")
        self.assertFalse(PROXY._is_extension_credential(req, REAL_TOKEN, "/api/safari/ingest"))


if __name__ == "__main__":
    unittest.main()
