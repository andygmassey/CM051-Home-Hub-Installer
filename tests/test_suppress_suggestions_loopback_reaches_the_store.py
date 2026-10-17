#!/usr/bin/env python3
"""tests/test_suppress_suggestions_loopback_reaches_the_store.py

CM041 #216 loopback half (v1.0.108). The ical-server (:8090) carries the
owner-settable do-not-suggest handler api_people_suppress_suggestions
(POST /api/v1/people/{slug}/suppress-suggestions, body
{"suppressed": bool, "reason": str}). The wiki person-page "Stop
suggesting" button POSTs it.

THE TRUST MODEL IS THE POINT. That button is an UNPAIRED browser on the
wiki page, exactly like the correction pencil that POSTs
/api/v1/wiki/correct (CM044 correction_overlay.js: POST, Content-Type
application/json, NO Authorization, cross-origin to the Doctor on :8089).
It holds no paired-iOS bearer, so it CANNOT use the DOCTOR_PROXY_PATHS
reverse proxy -- that proxy validates a paired bearer and 401s an
unpaired caller (OSTLER_DOCTOR_ORACLE_FALLBACK=0 on every install). So the
fix is a Doctor-NATIVE handler in vendor/doctor/agent/web_ui.py, the same
trust model as /api/v1/wiki/correct: unauthenticated, browser-reachable,
the loopback bind is its boundary. It forwards to the ical-server WITH the
per-install service token -- the token the browser neither has nor needs.

This test imports the REAL web_ui.py (not a reimplementation) and drives:

  * the native handler -- an unpaired/no-bearer request is ACCEPTED (not
    401) and its body forwarded; a malformed slug or body is rejected 400
    and nothing is forwarded; the handler is registered natively on the
    app, not behind the bearer proxy;
  * the forward helper -- the per-install service token is attached on the
    server-side forward to the ical-server, and a NEGATIVE CONTROL proves
    that with no service token configured no credential is fabricated (the
    exact state the attach defends against; its watched red is dropping the
    attach so the forward goes out with no service token).

Exit codes: 0 pass, 1 a case was wrong, 2 CANNOT-RUN (module import or a
missing dependency -- NOT a pass). CI installs fastapi + httpx; see
.github/workflows/suppress-suggestions-loopback.yml.
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
BAD_SLUG = "Not A Slug!"
GATEWAY_URL = "http://ical.invalid:8090"
SERVICE_TOKEN = "s" * 64          # stands in for the per-install PWG_SERVICE_TOKEN
UPSTREAM_RESULT = {
    "slug": SLUG,
    "suppressed": True,
    "reason": "deceased",
    "record_written": True,
    "record_uri": "https://schema.ostler.ai/ontology#suppression_" + SLUG,
}


def _load_web_ui():
    agent_dir = (Path(__file__).resolve().parent.parent
                 / "vendor" / "doctor" / "agent")
    web_ui_path = agent_dir / "web_ui.py"
    if not web_ui_path.is_file():
        print("CANNOT-RUN: %s not found" % web_ui_path, file=sys.stderr)
        sys.exit(2)
    # proxy.py (imported by web_ui and by the forward helper) sits alongside.
    if str(agent_dir) not in sys.path:
        sys.path.insert(0, str(agent_dir))
    spec = importlib.util.spec_from_file_location("ostler_web_ui", web_ui_path)
    if spec is None or spec.loader is None:
        print("CANNOT-RUN: no import spec for %s" % web_ui_path, file=sys.stderr)
        sys.exit(2)
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except ModuleNotFoundError as exc:
        print("CANNOT-RUN: importing web_ui.py needs a dependency that is not "
              "installed (%s). Run `python3 -m pip install fastapi httpx`."
              % exc, file=sys.stderr)
        sys.exit(2)
    except Exception as exc:  # pragma: no cover - defensive
        print("CANNOT-RUN: importing web_ui.py raised %r" % exc, file=sys.stderr)
        sys.exit(2)
    return module


WEB_UI = _load_web_ui()
SUPPRESS_PATH_TEMPLATE = "/api/v1/people/{slug}/suppress-suggestions"


# --------------------------------------------------------------------------
# Fakes. The native handler reads only request.body(); it does NOT look at
# any Authorization header -- that absence is the whole point.
# --------------------------------------------------------------------------

class _FakeRequest:
    def __init__(self, body: bytes):
        self._body = body

    async def body(self):
        return self._body


class _UpstreamResponse:
    def __init__(self, status_code, content, headers=None):
        self.status_code = status_code
        self.content = content
        self.headers = headers or {"content-type": "application/json"}


class _ForwardRecorder:
    """Replaces the module forward helper so the handler test needs no
    socket. Records (slug, body) and returns a canned upstream result."""

    def __init__(self, status_code=200, result=None):
        self.calls = []
        self._status = status_code
        self._result = UPSTREAM_RESULT if result is None else result

    async def __call__(self, slug, body, gateway_url=None, client=None):
        self.calls.append({"slug": slug, "body": body})
        return _UpstreamResponse(
            self._status, json.dumps(self._result).encode("utf-8"))


class _CapturingClient:
    """An injected async client for the forward-helper test: captures the
    exact POST the helper puts on the wire to the ical-server."""

    def __init__(self):
        self.posts = []

    async def post(self, url, content=None, headers=None, timeout=None):
        self.posts.append({"url": url, "content": content,
                           "headers": dict(headers or {})})
        return _UpstreamResponse(200, json.dumps(UPSTREAM_RESULT).encode("utf-8"))


def _call_handler(slug, body_bytes):
    return asyncio.run(
        WEB_UI.api_people_suppress_suggestions(slug, _FakeRequest(body_bytes)))


class TheRouteIsDoctorNativeNotProxied(unittest.TestCase):
    def test_registered_as_a_native_post_route(self):
        paths = {}
        for r in WEB_UI.app.routes:
            if getattr(r, "path", "") == SUPPRESS_PATH_TEMPLATE:
                paths[r.path] = sorted(getattr(r, "methods", []) or [])
        self.assertIn(SUPPRESS_PATH_TEMPLATE, paths,
                      "the suppress route is not registered on the Doctor app")
        self.assertIn("POST", paths[SUPPRESS_PATH_TEMPLATE])

    def test_not_served_by_the_paired_bearer_proxy(self):
        # The proxy only registers the DOCTOR_PROXY_PATHS templates. The
        # suppress path must NOT be one of them, or it would inherit the
        # paired-bearer gate that 401s the unpaired wiki browser.
        registered = getattr(WEB_UI, "_registered_proxy_paths", [])
        self.assertNotIn(SUPPRESS_PATH_TEMPLATE, registered,
                         "suppress must be a native route, not a proxied one")


class TheUnpairedBrowserRequestIsAccepted(unittest.TestCase):
    def setUp(self):
        self._recorder = _ForwardRecorder()
        self._orig = WEB_UI._forward_suppress_suggestions
        WEB_UI._forward_suppress_suggestions = self._recorder

    def tearDown(self):
        WEB_UI._forward_suppress_suggestions = self._orig

    def test_no_bearer_request_is_accepted_and_forwarded(self):
        # The exact shape the wiki button sends: a JSON body, NO Authorization.
        body = json.dumps({"suppressed": True, "reason": "deceased"}).encode()
        resp = _call_handler(SLUG, body)
        self.assertEqual(resp.status_code, 200,
                         "an unpaired no-bearer request must be accepted, not 401")
        self.assertEqual(len(self._recorder.calls), 1,
                         "the accepted request must be forwarded to the store")
        self.assertEqual(self._recorder.calls[0]["slug"], SLUG)
        self.assertEqual(json.loads(self._recorder.calls[0]["body"]),
                         {"suppressed": True, "reason": "deceased"})
        self.assertEqual(json.loads(bytes(resp.body)), UPSTREAM_RESULT)

    def test_the_undo_body_is_forwarded(self):
        body = json.dumps({"suppressed": False, "reason": "user_request"}).encode()
        _call_handler(SLUG, body)
        self.assertEqual(json.loads(self._recorder.calls[0]["body"]),
                         {"suppressed": False, "reason": "user_request"})

    def test_a_malformed_slug_is_rejected_and_not_forwarded(self):
        resp = _call_handler(BAD_SLUG, b'{"suppressed": true}')
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(len(self._recorder.calls), 0,
                         "a bad slug must never be forwarded to the store")

    def test_a_non_boolean_suppressed_is_rejected(self):
        resp = _call_handler(SLUG, b'{"suppressed": "yes"}')
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(len(self._recorder.calls), 0)


class TheForwardCarriesTheServiceToken(unittest.TestCase):
    def setUp(self):
        self._env = {}
        for k in ("OSTLER_SERVICE_TOKEN", "PWG_SERVICE_TOKEN"):
            self._env[k] = os.environ.pop(k, None)

    def tearDown(self):
        for k, v in self._env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def test_service_token_is_attached_on_the_forward(self):
        os.environ["OSTLER_SERVICE_TOKEN"] = SERVICE_TOKEN
        client = _CapturingClient()
        body = json.dumps({"suppressed": True, "reason": "deceased"}).encode()
        asyncio.run(WEB_UI._forward_suppress_suggestions(
            SLUG, body, gateway_url=GATEWAY_URL, client=client))
        self.assertEqual(len(client.posts), 1)
        post = client.posts[0]
        self.assertEqual(post["url"],
                         GATEWAY_URL + "/api/v1/people/" + SLUG + "/suppress-suggestions")
        self.assertEqual(post["headers"].get("authorization"),
                         "Bearer %s" % SERVICE_TOKEN)
        self.assertEqual(post["content"], body)

    def test_no_service_token_fabricates_no_credential(self):
        # Negative control. The browser's bearer is absent by design; with no
        # service token configured the forward must carry NO Authorization at
        # all, never a fabricated or leaked one. This is the state the attach
        # defends against, so the positive assertion above is not green by
        # construction. Watched red: dropping the attach in
        # _forward_suppress_suggestions leaves this green but fails the
        # positive test, and vice-versa.
        os.environ.pop("OSTLER_SERVICE_TOKEN", None)
        os.environ.pop("PWG_SERVICE_TOKEN", None)
        client = _CapturingClient()
        asyncio.run(WEB_UI._forward_suppress_suggestions(
            SLUG, b'{"suppressed": true}', gateway_url=GATEWAY_URL, client=client))
        self.assertNotIn("authorization", client.posts[0]["headers"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
