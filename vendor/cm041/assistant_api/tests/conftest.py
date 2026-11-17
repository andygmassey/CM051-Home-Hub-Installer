"""Harness: clear the proxy for the vendored CM041 assistant_api suite.

A developer or CI runner with HTTP(S)_PROXY / ALL_PROXY set sends the tests'
loopback calls (127.0.0.1, the fake Qdrant and the embed stub) through the
proxy. The result is HTTP 401/503 and KeyError failures that look like product
bugs. Clear the proxy variables for the whole session and keep loopback direct.
The autouse fixture pins the same thing per test so a test that sets its own
proxy cannot leak it. Mirrors CM041 assistant_api/tests/conftest.py.
"""
import os as _os

import pytest

_PROXY_VARS = (
    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
    "http_proxy", "https_proxy", "all_proxy",
)
_LOOPBACK_NO_PROXY = "127.0.0.1,localhost,::1"

for _name in _PROXY_VARS:
    _os.environ.pop(_name, None)
_os.environ["NO_PROXY"] = _LOOPBACK_NO_PROXY
_os.environ["no_proxy"] = _LOOPBACK_NO_PROXY


@pytest.fixture(autouse=True)
def _no_proxy_for_loopback(monkeypatch):
    """Every test runs with the proxy variables cleared and loopback direct."""
    for _name in _PROXY_VARS:
        monkeypatch.delenv(_name, raising=False)
    monkeypatch.setenv("NO_PROXY", _LOOPBACK_NO_PROXY)
    monkeypatch.setenv("no_proxy", _LOOPBACK_NO_PROXY)
    yield
