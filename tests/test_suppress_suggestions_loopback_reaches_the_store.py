#!/usr/bin/env python3
"""tests/test_suppress_suggestions_loopback_reaches_the_store.py

CM041 #216 loopback half (v1.0.108). The ical-server (:8090) carries the
owner-settable do-not-suggest handler api_people_suppress_suggestions
(POST /api/v1/people/{slug}/suppress-suggestions, body
{"suppressed": bool, "reason": str}). The wiki person-page "Stop
suggesting" button, the iOS person card and the assistant all POST it to
the DOCTOR (:8089), which is the single client-facing auth boundary. For
the button to PERSIST, the Doctor must forward that POST to the
loopback-bound ical-server with the per-install service token
substituted for the caller's paired bearer -- exactly as it already does
for the sibling POST /api/v1/people/{slug}/forget.

That forwarding is done by vendor/doctor/agent/proxy.py:proxy_request for
every path listed in DOCTOR_PROXY_PATHS (install.sh). This PR adds the
suppress-suggestions template to that list. This test proves the suppress
path flows through the REAL proxy_request and inherits its
validate-then-substitute service-token behaviour:

  * a paired caller's request is forwarded to the ical-server with the
    SERVICE token, not the caller's bearer, and the endpoint's result is
    returned verbatim;
  * an unpaired caller is refused 401 and nothing is forwarded;
  * the service token, when configured, REPLACES the client bearer on the
    wire (the security property; its red is watched in the brief handback
    by unsetting the token so the proxy becomes a transparent pass-through
    and the client bearer reaches the store).

Imports the real proxy.py via importlib rather than reimplementing the
forward, so a future edit to the proxy is caught here, not just in prose.
proxy_request takes injectable gateway_url / validator_url / client, so
no socket is opened: a fake async client answers the validator oracle and
captures the forwarded request.

Exit codes: 0 pass, 1 a case was wrong, 2 CANNOT-RUN (module import or a
missing dependency -- NOT a pass).
"""
from __future__ import annotations

import asyncio
import importlib.util
import json
import os
import sys
import unittest
from pathlib import Path

SLUG = "a-synthetic-person"
SUPPRESS_PATH = "/api/v1/people/%s/suppress-suggestions" % SLUG
GATEWAY_URL = "http://ical.invalid:8090"
VALIDATOR_URL = "http://gateway.invalid:8000"
SERVICE_TOKEN = "s" * 64          # stands in for the per-install PWG_SERVICE_TOKEN
CLIENT_BEARER = "c" * 64          # the caller's paired zeroclaw bearer
# The endpoint's own result shape (api_people_suppress_suggestions), echoed
# back by the fake ical-server so we can prove the proxy returns it verbatim.
ENDPOINT_RESULT = {
    "slug": SLUG,
    "suppressed": True,
    "reason": "deceased",
    "record_written": True,
    "record_uri": "https://schema.ostler.ai/ontology#suppression_" + SLUG,
}


def _load_proxy_module():
    repo_root = Path(__file__).resolve().parent.parent
    proxy_path = repo_root / "vendor" / "doctor" / "agent" / "proxy.py"
    if not proxy_path.is_file():
        print("CANNOT-RUN: %s not found" % proxy_path, file=sys.stderr)
        sys.exit(2)
    spec = importlib.util.spec_from_file_location("ostler_doctor_proxy", proxy_path)
    if spec is None or spec.loader is None:
        print("CANNOT-RUN: could not build an import spec for %s" % proxy_path,
              file=sys.stderr)
        sys.exit(2)
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except ModuleNotFoundError as exc:
        # fastapi / httpx absent (the shipped Doctor venv has them; a bare
        # checkout may not). This is CANNOT-RUN, never a pass. CI installs
        # them: see .github/workflows/*.yml `pip install fastapi httpx`.
        print("CANNOT-RUN: importing proxy.py needs a dependency that is not "
              "installed (%s). Run `python3 -m pip install fastapi httpx`."
              % exc, file=sys.stderr)
        sys.exit(2)
    except Exception as exc:  # pragma: no cover - defensive
        print("CANNOT-RUN: importing proxy.py raised %r" % exc, file=sys.stderr)
        sys.exit(2)
    return module


PROXY = _load_proxy_module()


# --------------------------------------------------------------------------
# Minimal fakes: proxy_request only touches these attributes.
# --------------------------------------------------------------------------

class _FakeURL:
    def __init__(self, path, query=""):
        self.path = path
        self.query = query


class _FakeReqClient:
    def __init__(self, host):
        self.host = host


class _FakeRequest:
    """Stands in for a starlette Request. proxy_request reads .method,
    .url.path, .url.query, .headers (.items()/.get()), .client.host and
    awaits .body()."""

    def __init__(self, method, path, headers, body=b"", host="127.0.0.1"):
        self.method = method
        self.url = _FakeURL(path)
        self.headers = headers
        self._body = body
        self.client = _FakeReqClient(host)

    async def body(self):
        return self._body


class _FakeResponse:
    def __init__(self, status_code, content=b"", headers=None):
        self.status_code = status_code
        self.content = content
        self.headers = headers or {"content-type": "application/json"}


class _FakeAsyncClient:
    """One injected client serves BOTH the bearer-validation oracle call
    (.post to /internal/validate-bearer) and the upstream forward
    (.request). It records every forward so the test can inspect the exact
    headers and body that reached the ical-server."""

    def __init__(self, validate_status):
        self._validate_status = validate_status
        self.validate_calls = []
        self.forwarded = []

    async def post(self, url, json=None, timeout=None):
        self.validate_calls.append({"url": url, "json": json})
        return _FakeResponse(self._validate_status, b"")

    async def request(self, method, url, headers, content):
        self.forwarded.append(
            {"method": method, "url": url, "headers": dict(headers),
             "content": content}
        )
        return _FakeResponse(
            200, json.dumps(ENDPOINT_RESULT).encode("utf-8"),
            {"content-type": "application/json"},
        )


def _request_headers():
    # Lowercase key: _extract_bearer_token reads .get("authorization").
    return {
        "authorization": "Bearer %s" % CLIENT_BEARER,
        "content-type": "application/json",
    }


def _body_bytes(suppressed=True, reason="deceased"):
    return json.dumps({"suppressed": suppressed, "reason": reason}).encode("utf-8")


def _run_proxy(client, body=None):
    req = _FakeRequest(
        "POST", SUPPRESS_PATH, _request_headers(),
        body=body if body is not None else _body_bytes(),
    )
    return asyncio.run(
        PROXY.proxy_request(
            req, SUPPRESS_PATH,
            gateway_url=GATEWAY_URL, validator_url=VALIDATOR_URL, client=client,
        )
    )


class SuppressLoopbackReachesTheStore(unittest.TestCase):
    def setUp(self):
        # Service token configured -> upstream is the ical-server and the
        # validate-then-substitute path applies (proxy.py _resolve_service_token).
        self._env = {}
        for k in ("OSTLER_SERVICE_TOKEN", "PWG_SERVICE_TOKEN",
                  "OSTLER_EXTENSION_TOKEN", "OSTLER_ADMIN_TOKEN",
                  "OSTLER_MACHINE_ADMIN_TOKEN"):
            self._env[k] = os.environ.pop(k, None)
        os.environ["OSTLER_SERVICE_TOKEN"] = SERVICE_TOKEN
        # The oracle-absent fallback is a different test's concern; keep it off
        # so an unpaired bearer is a clean 401 here.
        self._env["OSTLER_DOCTOR_ORACLE_FALLBACK"] = \
            os.environ.get("OSTLER_DOCTOR_ORACLE_FALLBACK")
        os.environ["OSTLER_DOCTOR_ORACLE_FALLBACK"] = "0"
        PROXY._ORACLE_STATE["absent"] = False

    def tearDown(self):
        for k, v in self._env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def test_paired_caller_is_forwarded_with_the_service_token(self):
        client = _FakeAsyncClient(validate_status=204)  # gateway says: paired
        resp = _run_proxy(client)

        self.assertEqual(len(client.forwarded), 1,
                         "a paired suppress POST must be forwarded exactly once")
        fwd = client.forwarded[0]
        self.assertEqual(fwd["method"], "POST")
        # The concrete {slug} is substituted into the upstream URL.
        self.assertEqual(fwd["url"], GATEWAY_URL + SUPPRESS_PATH)
        # The service token REPLACES the caller's bearer on the wire.
        self.assertEqual(fwd["headers"].get("authorization"),
                         "Bearer %s" % SERVICE_TOKEN)
        self.assertNotIn(CLIENT_BEARER, fwd["headers"].get("authorization", ""),
                         "the caller's bearer must not reach the ical-server")
        # The owner's choice is preserved end to end.
        self.assertEqual(json.loads(fwd["content"]),
                         {"suppressed": True, "reason": "deceased"})
        # The endpoint's result is returned verbatim (same status + body).
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(json.loads(bytes(resp.body)), ENDPOINT_RESULT)

    def test_the_undo_body_is_forwarded_unchanged(self):
        # suppressed:false is the "resume suggesting" undo; the proxy must not
        # mangle it (it is purely plumbing).
        client = _FakeAsyncClient(validate_status=204)
        _run_proxy(client, body=_body_bytes(suppressed=False, reason="user_request"))
        self.assertEqual(json.loads(client.forwarded[0]["content"]),
                         {"suppressed": False, "reason": "user_request"})

    def test_unpaired_caller_is_refused_and_nothing_is_forwarded(self):
        client = _FakeAsyncClient(validate_status=401)  # gateway says: not paired
        resp = _run_proxy(client)
        self.assertEqual(resp.status_code, 401)
        self.assertEqual(len(client.forwarded), 0,
                         "an unpaired bearer must never reach the ical-server")

    def test_without_a_service_token_the_client_bearer_would_leak(self):
        """The negative control the security property rests on. With NO
        service token configured proxy_request is a transparent pass-through
        (its documented pre-lockdown posture), so the caller's own bearer --
        not a service token -- is what reaches upstream. This is the exact
        state the substitution defends against; asserting it here means the
        'service token replaces the client bearer' assertion above is not
        green by construction."""
        os.environ.pop("OSTLER_SERVICE_TOKEN", None)
        os.environ.pop("PWG_SERVICE_TOKEN", None)
        client = _FakeAsyncClient(validate_status=204)
        _run_proxy(client)
        self.assertEqual(client.forwarded[0]["headers"].get("authorization"),
                         "Bearer %s" % CLIENT_BEARER)


if __name__ == "__main__":
    unittest.main(verbosity=2)
