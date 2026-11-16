"""Harness: present the service token from the test-side HTTP openers.

The vendored moat L3 test (test_l3_withheld_moat_readers.py) calls the
ical-server over HTTP with urllib openers built at import time. The server
fails closed without a service token (401), so the test needs two things:
a configured token, and an opener that presents it.

This conftest sets the env pair and wraps urllib.request.build_opener, as the
CM041 suite does. It does NOT stub ostler_security: the vendored tree ships the
real package, and a stub would hide the db_key import that ical-server needs.
"""
import os
import urllib.request

_TEST_TOKEN = "test-token"
os.environ.setdefault("OSTLER_SERVICE_TOKEN", _TEST_TOKEN)
os.environ.setdefault("OSTLER_TEST_AUTOAUTH", _TEST_TOKEN)


class _AutoAuthProcessor(urllib.request.BaseHandler):
    def http_request(self, req):
        token = os.environ.get("OSTLER_TEST_AUTOAUTH")
        if (
            token
            and not req.has_header("Authorization")
            and not req.has_header("X-ostler-service")
        ):
            req.add_unredirected_header("X-Ostler-Service", token)
        return req


_orig_build_opener = urllib.request.build_opener


def _build_opener_with_auth(*handlers):
    return _orig_build_opener(*handlers, _AutoAuthProcessor())


urllib.request.build_opener = _build_opener_with_auth
