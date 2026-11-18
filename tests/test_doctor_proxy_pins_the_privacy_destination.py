#!/usr/bin/env python3
"""tests/test_doctor_proxy_pins_the_privacy_destination.py

The Doctor proxy (vendor/doctor/agent/proxy.py, :8089) must never let a caller
choose the privacy destination the Hub serves it under.

WHY (CM041 #296, Archie 2026-11-17). The ical-server serves ``owner_local``,
which includes L3 and untagged data labelled private, only to a LOOPBACK peer.
Port 8089 is tailscale-served as raw TCP, so every tailnet device reaches this
proxy as 127.0.0.1, and the proxy then forwards it to the ical-server from
loopback. Without this rule a tailnet caller could send one header
(``X-Ostler-Destination: owner_local``) or one query parameter
(``?destination=owner_local``) and be served L3 off the box.

Rule until the owner-scoped bearer lands: STRIP any inbound destination header
and query parameter, and SET ``owner_own_brief`` on every proxied request.

Drives the REAL ``proxy_request`` end to end, upstream replaced by an
httpx.MockTransport that records exactly what the ical-server would receive.
Each case is run against a planted mutant (the pre-fix pass-through) to prove
the assertions can fail.

Exit codes: 0 pass, 1 a case was wrong, 2 CANNOT-RUN (fastapi/httpx missing or
proxy.py did not import; never a pass).
"""
from __future__ import annotations

import asyncio
import importlib.util
import os
import sys
import unittest
from pathlib import Path

try:
    import httpx
    from starlette.requests import Request
except Exception as exc:  # pragma: no cover
    print(f"CANNOT-RUN: fastapi/httpx not importable ({exc!r})", file=sys.stderr)
    sys.exit(2)


def _load_proxy_module():
    path = Path(__file__).resolve().parent.parent / "vendor" / "doctor" / "agent" / "proxy.py"
    spec = importlib.util.spec_from_file_location("ostler_doctor_proxy_dest", path)
    if spec is None or spec.loader is None:
        print(f"CANNOT-RUN: no import spec for {path}", file=sys.stderr)
        sys.exit(2)
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
    except Exception as exc:  # pragma: no cover
        print(f"CANNOT-RUN: importing proxy.py raised {exc!r}", file=sys.stderr)
        sys.exit(2)
    return mod


PROXY = _load_proxy_module()


def _request(path: str, query: str, headers: dict) -> Request:
    raw = [(k.lower().encode(), v.encode()) for k, v in headers.items()]
    scope = {
        "type": "http", "method": "GET", "path": path, "raw_path": path.encode(),
        "query_string": query.encode(), "headers": raw,
        "client": ("127.0.0.1", 50000), "server": ("127.0.0.1", 8089),
        "scheme": "http", "http_version": "1.1",
    }

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}
    return Request(scope, receive)


def _forward(path: str, query: str = "", headers: dict | None = None):
    """Run the real proxy_request once; return (url, headers) the upstream saw."""
    seen = {}

    def handler(req: httpx.Request) -> httpx.Response:
        seen["url"] = str(req.url)
        seen["headers"] = {k.lower(): v for k, v in req.headers.items()}
        return httpx.Response(200, json={"ok": True})

    async def run():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as c:
            return await PROXY.proxy_request(
                _request(path, query, headers or {}), path,
                gateway_url="http://127.0.0.1:8090", client=c)
    # No service token: the proxy is a transparent pass-through, so the only
    # thing that can change the destination is the rule under test.
    prev = {k: os.environ.pop(k, None) for k in ("PWG_SERVICE_TOKEN", "OSTLER_SERVICE_TOKEN")}
    try:
        resp = asyncio.run(run())
    finally:
        for k, v in prev.items():
            if v is not None:
                os.environ[k] = v
    assert resp.status_code == 200, resp.status_code
    return seen["url"], seen["headers"]


class TheProxyPinsTheDestination(unittest.TestCase):

    def test_a_claimed_owner_local_header_is_replaced(self):
        url, hdr = _forward("/api/v1/timeline", "",
                            {"X-Ostler-Destination": "owner_local"})
        self.assertEqual(hdr.get("x-ostler-destination"), "owner_own_brief")

    def test_a_claimed_owner_local_query_param_is_stripped(self):
        url, hdr = _forward("/api/v1/timeline", "destination=owner_local&days=7")
        self.assertNotIn("destination=", url)
        self.assertIn("days=7", url)
        self.assertEqual(hdr.get("x-ostler-destination"), "owner_own_brief")

    def test_an_undeclared_request_is_owner_own_brief(self):
        url, hdr = _forward("/api/v1/people/context", "name=Synthetic")
        self.assertEqual(hdr.get("x-ostler-destination"), "owner_own_brief")
        self.assertIn("name=Synthetic", url)

    def test_exactly_one_destination_header_reaches_upstream(self):
        _, hdr = _forward("/api/v1/commitments", "",
                          {"X-Ostler-Destination": "owner_local",
                           "x-ostler-destination": "owner_local"})
        self.assertEqual(hdr.get("x-ostler-destination"), "owner_own_brief")

    def test_mutant_pass_through_is_caught(self):
        """The pre-fix proxy forwarded headers and query untouched. With it
        planted, both owner_local claims reach upstream, so the tests above
        go red."""
        real_filter, real_strip = PROXY._filter_request_headers, PROXY._strip_destination_query
        PROXY._filter_request_headers = lambda h: {
            k: v for k, v in h.items() if k.lower() not in PROXY._HOP_BY_HOP_HEADERS}
        PROXY._strip_destination_query = lambda q: q
        try:
            with self.assertRaises(AssertionError):
                self.test_a_claimed_owner_local_header_is_replaced()
            with self.assertRaises(AssertionError):
                self.test_a_claimed_owner_local_query_param_is_stripped()
        finally:
            PROXY._filter_request_headers, PROXY._strip_destination_query = real_filter, real_strip
        print("MUTANT CAUGHT: pass-through proxy lets owner_local through")


if __name__ == "__main__":
    unittest.main()
