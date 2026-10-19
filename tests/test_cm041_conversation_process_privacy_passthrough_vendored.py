"""The Hub route CM052's wire posts to keeps ``metadata.privacy_level`` intact.

CM052's ``wire.post`` now sends L3 conversations to the Hub instead of
dropping them (Archie ruling, 19 Oct): the L3 rule is "no Qdrant / Oxigraph",
enforced inside CM048, which reads ``privacy_level`` from the
``00_metadata.json`` this server writes. So the one thing this hop must do is
hand the level through untouched. If it dropped or rewrote it, CM048's
``privacy.infer`` would fall back to the channel default (L2 for ``im``) and
an L3 conversation would reach the gist sinks.

Driven end to end through the REAL handler: an HTTP POST to the real
``Handler`` on a loopback port, the real ``api_conversation_process``, the real
``_conversation_process_background`` writing the real ``00_metadata.json``.
Only the final ``subprocess.run`` into CM048 is replaced, by a recorder that
reads the metadata file at the moment CM048 would.

The payload is the shape CM052's ``wire.render_metadata`` emits: participants
are DICTS (``{"id", "display", "role", "handle"}``), not strings. Before this
PR the fallback-id branch called ``str.replace`` on each participant, so every
such POST was a 500 ``'dict' object has no attribute 'replace'``.
"""
from __future__ import annotations

import importlib.util
import json
import socket
import subprocess
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import HTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
# Ported from CM041 assistant_api/tests/test_conversation_process_privacy_passthrough.py at
# 2615d915 (#221), grafted into vendor/cm041/assistant_api for v1.0.111: runs against the VENDORED file.
# VENDORED DIFFERENCE: the vendored server carries the Pro subscription gate (402 when unlicensed),
# which upstream does not; the test puts the box in the subscribed state, as a real paid Hub is.
SERVER_FILE = HERE.parent / "vendor" / "cm041" / "assistant_api" / "ical-server.py"


def _install_ostler_security_stub() -> None:
    # Same stub as tests/test_cm041_deceased_excluded_from_proactive_surfaces.py:
    # the vendored server refuses to import without ostler_security, which a CI
    # runner does not have; the DB layer is not what this test exercises.
    import sys
    import types
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
    database.get_db_connection = lambda path, _key, *a, **k: _sqlite.connect(path)
    sys.modules["ostler_security.database"] = database
    posture = types.ModuleType("ostler_security.posture")
    posture.record_posture = lambda *a, **k: None
    sys.modules["ostler_security.posture"] = posture


_install_ostler_security_stub()


def _load_server_module():
    spec = importlib.util.spec_from_file_location("ical_server_l3", SERVER_FILE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


server = _load_server_module()
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
# Synthetic. The server fails closed without a token, and CM052's wire sends
# ``Authorization: Bearer <token>``, so the test takes the same auth path.
_TOKEN = "test-token-l3-passthrough-not-a-secret"


def _cm052_payload(level: str) -> dict:
    """What CM052 wire.post sends for a Slack thread (synthetic cast)."""
    return {
        "transcript": "**John Smith:** Why did we park feature X?\n\n"
                      "**Jane Doe:** The licence cost.\n",
        "metadata": {
            "conversation_id": "sk-0123456789abcdef",
            "date": "2026-03-02",
            "source": "slack",
            "channel": "im",
            "participant_kind": "human",
            "privacy_level": level,
            "participants": [
                {"id": "john.smith@example.com", "display": "John Smith",
                 "role": "other", "slack_user_id": "U0000000002",
                 "handle": "john.smith@example.com"},
                {"id": "jane.doe@example.com", "display": "Jane Doe",
                 "role": "user", "slack_user_id": "U0000000001",
                 "handle": "jane.doe@example.com"},
            ],
            "provenance": {"source_kind": "channel", "source_subtype": "slack"},
            "extra": {"slack_unit": "thread"},
            "source_app": "slack",
        },
    }


class _Harness:
    def __init__(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        self.port = s.getsockname()[1]
        s.close()
        self.httpd = HTTPServer(("127.0.0.1", self.port), server.Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=2)

    def post(self, path, payload):
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json",
                     "Authorization": f"Bearer {_TOKEN}"},
            method="POST",
        )
        try:
            with _OPENER.open(req, timeout=5) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read() or b"{}")


class TestPrivacyLevelReachesCM048(unittest.TestCase):

    def _post_through_real_handler(self, level=None, payloads=None):
        """POST each payload in turn into ONE processing dir; return the
        last (status, body) plus every CM048 invocation recorded."""
        payloads = payloads or [_cm052_payload(level)]
        seen = []

        def _recording_run(argv, **kwargs):
            # VENDORED DIFFERENCE: the vendored server first probes
            # `pwg-convo --help` to tell a missing CM048 from a slow one.
            if list(argv)[-1:] == ["--help"]:
                return subprocess.CompletedProcess(argv, 0, "", "")
            # argv = [python, -m, src.cli, process, transcript, metadata]
            seen.append({
                "argv": list(argv),
                "metadata": json.loads(Path(argv[-1]).read_text()),
                "transcript": Path(argv[-2]).read_text(),
            })
            return subprocess.CompletedProcess(argv, 0, "", "")

        with TemporaryDirectory() as tmp, \
                patch.dict("os.environ", {}, clear=False) as env, \
                patch.object(server, "PROCESSING_DIR", Path(tmp)), \
                patch.object(server, "OSTLER_VENV_PYTHON", "/fake/python"), \
                patch.object(server, "OSTLER_PROJECT_DIR", tmp), \
                patch.object(server.subprocess, "run", _recording_run), \
                patch.object(server, "_subscription_paused", lambda *_a, **_k: None):
            for name in server._SERVICE_TOKEN_ENV_VARS:
                env.pop(name, None)
            env["OSTLER_SERVICE_TOKEN"] = _TOKEN
            with _Harness() as h:
                for i, payload in enumerate(payloads):
                    status, body = h.post("/api/v1/conversation/process", payload)
                    for _ in range(200):
                        if len(seen) > i or status != 202:
                            break
                        time.sleep(0.02)
        return status, body, seen

    def test_l3_arrives_at_cm048_unchanged(self):
        status, body, seen = self._post_through_real_handler("L3")
        self.assertEqual(status, 202, body)
        self.assertEqual(len(seen), 1, "the background hop never reached CM048")
        meta = seen[0]["metadata"]
        self.assertEqual(meta["privacy_level"], "L3")
        self.assertEqual(meta["channel"], "im")
        self.assertEqual(meta["source"], "slack")
        self.assertEqual(meta["source_app"], "slack")
        # Participant dicts (with the identity bridge's ``handle``) intact.
        self.assertEqual(meta["participants"], _cm052_payload("L3")["metadata"]["participants"])
        # VENDORED DIFFERENCE: the vendored server invokes the installed
        # pwg-convo CLI (PWG_CONVO_BIN), not `<venv python> -m src.cli`.
        self.assertEqual(seen[0]["argv"][0], server.PWG_CONVO_BIN)
        self.assertEqual(seen[0]["argv"][1], "process")

    def test_l2_control_also_unchanged(self):
        # A pass-through that hard-coded one level would pass the L3 test alone.
        status, _body, seen = self._post_through_real_handler("L2")
        self.assertEqual(status, 202)
        self.assertEqual(seen[0]["metadata"]["privacy_level"], "L2")

    def test_producer_conversation_id_is_kept_across_changed_reposts(self):
        # CM052 re-posts a conversation whose content changed (a Slack day
        # that grew) under the SAME id; the Hub must hand CM048 that id and
        # the NEW transcript, not a fresh suffixed id beside the old one.
        first = _cm052_payload("L2")
        grown = _cm052_payload("L2")
        grown["transcript"] += "**John Smith:** One more thing.\n"
        status, body, seen = self._post_through_real_handler(payloads=[first, grown])
        self.assertEqual(status, 202, body)
        self.assertEqual(body["job_id"], "sk-0123456789abcdef")
        self.assertEqual([c["metadata"]["conversation_id"] for c in seen],
                         ["sk-0123456789abcdef", "sk-0123456789abcdef"])
        self.assertIn("One more thing.", seen[1]["transcript"])

    def test_unsafe_producer_id_falls_back(self):
        payload = _cm052_payload("L2")
        payload["metadata"]["conversation_id"] = "../../etc"
        self.assertFalse(server._is_safe_meeting_id(payload["metadata"]["conversation_id"]))

    def test_dict_participants_do_not_500(self):
        status, body, _seen = self._post_through_real_handler("L2")
        self.assertNotIn("error", body)
        self.assertEqual(status, 202)


class TestFallbackSlugFromParticipants(unittest.TestCase):

    def test_slug_reads_display_from_dicts_and_strings(self):
        f = server._participant_slug_label
        self.assertEqual(f({"id": "a@example.com", "display": "Jane Doe"}), "jane_doe")
        self.assertEqual(f({"id": "a@example.com"}), "a@example.com")
        self.assertEqual(f("Alice Smith"), "alice_smith")
        self.assertEqual(f({}), "")
        self.assertEqual(f(None), "")
        self.assertEqual(f(42), "")


if __name__ == "__main__":
    unittest.main()
