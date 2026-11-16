"""Shared pytest configuration for the Assistant API test suite.

v1.0.10 lockdown: ical-server now gates every non-public endpoint behind
the #200 localhost service token and FAILS CLOSED when none is configured.
There is deliberately no OSTLER_API_AUTH_OPTIONAL escape hatch any more --
it was a production footgun (any co-resident process able to rewrite this
service's LaunchAgent plist could set the env var and defeat the auth).

The pre-existing endpoint tests exercise *business logic*, not auth, and
their harnesses issue token-less requests. Instead of the deleted escape
hatch we now do exactly what test_service_auth.py does: configure a REAL
service token (server side) AND present it on the request (client side).

To avoid threading a bearer header through ~20 bespoke harnesses, the
client-side injection is centralised here: we wrap urllib's build_opener so
every opener a harness constructs carries a small request processor that
adds the token header. The processor only fires when OSTLER_TEST_AUTOAUTH is
set and the request does not already carry an auth header, so
test_service_auth.py -- which drives absent / wrong / valid tokens and the
fail-closed default explicitly -- clears OSTLER_TEST_AUTOAUTH per-test and
sees pristine, un-injected requests.
"""
import os
import sys
import types
import urllib.request

# ---------------------------------------------------------------------------
# ostler_security stub -- installed HERE so it is unconditional.
#
# ical-server.py imports ostler_security at module scope and RAISES if it is
# absent (deliberately: no silent fallback to an unencrypted DB). CI does not
# install it -- it lives in HR015, a separate private repo -- so every test
# file that loads the server needs a sys.modules stub in place FIRST.
#
# 13 of the 22 files that load the server installed that stub themselves. The
# other 9 did not, and passed only because an earlier-collected file had left
# one behind. Run one of them on its own and it fails at COLLECTION:
#
#     pytest assistant_api/tests/test_timeline_historic.py
#     -> RuntimeError: ostler_security is required but not installed
#
# conftest is imported before any test module in this directory, so putting it
# here removes the ordering dependency for every file, present and future. The
# per-file copies still work and are harmless -- the guard below no-ops when a
# stub or the real package is already present.
# ---------------------------------------------------------------------------


def _install_ostler_security_stub() -> None:
    """No-op if the real package (or an earlier stub) is already importable."""
    try:
        import ostler_security  # noqa: F401
        return
    except Exception:
        pass

    import sqlite3 as _sqlite

    pkg = types.ModuleType("ostler_security")
    pkg.__path__ = []
    sys.modules["ostler_security"] = pkg

    database = types.ModuleType("ostler_security.database")

    def _stub_get_db_connection(path, _key, *_args, **_kwargs):
        return _sqlite.connect(path)

    database.get_db_connection = _stub_get_db_connection
    sys.modules["ostler_security.database"] = database

    posture = types.ModuleType("ostler_security.posture")

    def _stub_record_posture(*_args, **_kwargs):
        return None

    posture.record_posture = _stub_record_posture
    sys.modules["ostler_security.posture"] = posture


_install_ostler_security_stub()

_TEST_TOKEN = "test-token"

# Server side: a real token is configured for the suite. With the escape
# hatch gone, this is what keeps the legacy business-logic endpoints
# reachable (a token-less install now fails closed with 401).
os.environ.setdefault("OSTLER_SERVICE_TOKEN", _TEST_TOKEN)

# Client side opt-in: harness openers auto-present this token. Kept separate
# from OSTLER_SERVICE_TOKEN so test_service_auth.py can null the server token
# (fail-closed tests) while still disabling injection independently.
os.environ.setdefault("OSTLER_TEST_AUTOAUTH", _TEST_TOKEN)


class _AutoAuthProcessor(urllib.request.BaseHandler):
    """Inject the service token into outgoing test-harness requests.

    Fires only when OSTLER_TEST_AUTOAUTH is set (the legacy business-logic
    suite) and the request does not already present an auth header, so
    test_service_auth.py can still send absent / wrong / valid tokens.
    """

    def http_request(self, req):
        token = os.environ.get("OSTLER_TEST_AUTOAUTH")
        # urllib stores header keys .capitalize()'d: "X-Ostler-Service"
        # becomes "X-ostler-service"; "Authorization" stays "Authorization".
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


# Lane 18: the forget handler writes, and every resolver reads, a tombstone
# file under ~/.ostler/state. Give each test its own so a run never writes to,
# or reads from, a developer's real one.
import pytest as _pytest_forget_tombstone  # noqa: E402


@_pytest_forget_tombstone.fixture(autouse=True)
def _isolated_forget_tombstone(tmp_path, monkeypatch):
    monkeypatch.setenv(
        "OSTLER_FORGET_TOMBSTONE_FILE", str(tmp_path / "forgotten_people.json")
    )


# ---------------------------------------------------------------------------
# Proxy harness fix. A developer or CI runner with HTTP(S)_PROXY / ALL_PROXY
# set sends the tests' loopback calls (127.0.0.1, the fake Qdrant and the
# embed stub) through the proxy. The result is HTTP 401/503 and KeyError
# failures that look like product bugs. Clear the proxy variables for the
# whole session, and keep loopback direct. Also pinned per test by the
# autouse fixture below so a test that sets its own proxy cannot leak it.
# ---------------------------------------------------------------------------
import os as _os  # noqa: E402
import pytest  # noqa: E402

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
