"""Every client call Lane 11 repaired, run through the contract checker.

Each call is built from the CALLER's own source, cited by file:line (CM031 =
PWG-Companion, CM042 = PWG-Remote-Conversations). Before Lane 11 each of the
first four was red against the Lane 10 contract (PORT_MISMATCH where the route
existed only on the Doctor, ROUTE_MISSING where it existed nowhere); the test
pins that they are green now. Fixture values are synthetic.

Not a call, so not listed: the phone's `updateSpeakers`
(CM031 Sources/Services/APIClient.swift:225-228) is an intentionally empty
function. Speaker names stay on the device with the local voiceprint, so there
is no request to check; the server side (POST /api/v1/speakers/correct) exists
for the Mac and the wiki, not the phone.
"""
import importlib.util
import json
import os
import sys
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTRACT = os.path.join(REPO, "vendor/cm041/assistant_api/hub_contract.yaml")


def _load():
    spec = importlib.util.spec_from_file_location("hub_contract_check", os.path.join(REPO, "scripts/hub_contract_check.py"))
    m = importlib.util.module_from_spec(spec)
    sys.modules["hub_contract_check"] = m
    spec.loader.exec_module(m)
    return m


chk = _load()
HUB = "https://hub.example.invalid:8443"
BEARER = {"Authorization": "Bearer synthetic-device-token"}

CALLS = [
    {   # CM031 ForgetPersonService.swift:142-147 (request), :76-87 (response keys read)
        "id": "cm031.forget_person", "method": "POST", "url": HUB + "/api/v1/people/jane-doe/forget",
        "headers": BEARER, "token_source": "device_token", "body_bytes": 0,
        "reads": ["forgotten", "already_forgotten", "wiki_recompile_queued", "stores_purged"],
    },
    {   # CM031 SafariCaptureRelay.swift:150 (ingest URL), :183-206 (POST), body = queued extension payload
        "id": "cm031.safari_ingest", "method": "POST", "url": HUB + "/api/safari/ingest",
        "headers": BEARER, "token_source": "device_token", "body_bytes": 40_000, "body_keys": ["url", "title"],
    },
    {   # CM031 SafariCaptureRelay.swift:151-162 (kind == "save" routes to the sibling path)
        "id": "cm031.safari_save", "method": "POST", "url": HUB + "/api/safari/save",
        "headers": BEARER, "token_source": "device_token", "body_bytes": 40_000, "body_keys": ["url", "title"],
    },
    {   # CM042 SpeakersIdentifyService.swift buildIdentifyRequest (URL on gatewayURL, default
        # http://localhost:8000 per AppConfiguration.swift:86; Authorization: Bearer <service token>
        # from AppConfiguration.serviceToken, Lane 18), body keys; SpeakerResolution.swift:35 (reads `speakers`)
        "id": "cm042.speakers_identify", "method": "POST", "url": "http://localhost:8000/api/v1/speakers/identify",
        "headers": {"Authorization": "Bearer synthetic-service-token"}, "token_source": "service_token", "body_bytes": 30_000,
        "body_keys": ["transcript", "attendees", "timestamp", "duration", "source"], "reads": ["speakers"],
    },
]


class ClientCallsPassTheContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(CONTRACT, encoding="utf-8") as f:
            cls.hub = chk.HubContract(json.load(f))

    def test_each_repaired_call_is_green(self):
        for call in CALLS:
            with self.subTest(call["id"]):
                violations, _ = self.hub.check_call(call)
                self.assertEqual(violations, [], call["id"])

    def test_the_checker_can_still_see_these_go_red(self):
        """A control: break each call one way and it must turn red."""
        wrong_port = dict(CALLS[0], url=HUB.replace(":8443", ":8090") + "/api/v1/people/jane-doe/forget")
        self.assertTrue(self.hub.check_call(wrong_port)[0])
        no_bearer = dict(CALLS[1], headers={}, token_source="none")
        self.assertEqual([v[0] for v in self.hub.check_call(no_bearer)[0]], ["AUTH_MISSING"])
        # No loopback exemption any more: no credential is AUTH_MISSING on any host.
        for host in ("http://localhost:8000", "http://192.168.1.5:8443"):
            bare = dict(CALLS[3], url=host + "/api/v1/speakers/identify", headers={}, token_source="none")
            self.assertEqual([v[0] for v in self.hub.check_call(bare)[0]], ["AUTH_MISSING"], host)
        oversized = dict(CALLS[1], body_bytes=2_000_000)
        self.assertEqual([v[0] for v in self.hub.check_call(oversized)[0]], ["BODY_TOO_LARGE"])

    def test_unbounded_bodies_are_reported_not_hidden(self):
        """Gap 4: the phone, RemoteCapture and CM052 send unbounded bodies. Until
        they chunk (spec in the PR), the checker must keep saying so."""
        process = {"method": "POST", "url": HUB + "/api/v1/conversation/process", "headers": BEARER,
                   "token_source": "device_token", "body_bytes": None, "body_keys": ["transcript", "metadata"]}
        self.assertEqual([v[0] for v in self.hub.check_call(process)[0]], ["BODY_UNBOUNDED"])
        part = {"method": "POST", "url": HUB + "/api/v1/conversation/upload-part", "headers": BEARER,
                "token_source": "device_token", "body_bytes": 900_000,
                "body_keys": ["meeting_id", "part_index", "part_total", "transcript"]}
        self.assertEqual(self.hub.check_call(part)[0], [])


if __name__ == "__main__":
    unittest.main()
