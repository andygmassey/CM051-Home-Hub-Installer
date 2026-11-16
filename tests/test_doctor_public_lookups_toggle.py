#!/usr/bin/env python3
"""The Doctor toggle withdraws public look-ups, and the next wiki run sends nothing.

134, GDPR Art.7(3). Drives the real Doctor FastAPI app (vendor/doctor/agent/
web_ui.py) through TestClient, so the cross-site guard, the route and the
writer all run as shipped. Then runs the same next-compile path as
test_public_lookups_withdraw.py (the shipped tick flag, the CM019 gate, and a
request counted at a local recording proxy).

ARMS
  A  CONTROL: consent accepted in the file -> the next run makes >= 1 request.
  B  POST /api/v1/consent/public-lookups {"decision":"declined"} with a
     same-origin guard -> 200, the file says declined, event logged; the next
     run makes 0 requests.
  C  a cross-site POST (foreign Origin, Sec-Fetch-Site cross-site) is refused
     403 and changes nothing (the guard holds).
  D  POST accepted again -> 200 -> the next run makes >= 1 request.
  E  the page renders the control: GET /config shows the state and the button.
  F  MUTANT: the route's writer is replaced by a no-op that still answers 200.
     The next run must then make >= 1 request, so arm B's zero check goes RED.

Synthetic only. Sandboxed OSTLER_DIR. No real Keychain, no real network.
Exit: 0 pass, 1 real failure, 2 cannot-run.
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
AGENT = ROOT / "vendor" / "doctor" / "agent"

passes = fails = cannots = 0


def ok(msg):
    global passes
    passes += 1
    print(f"  ok    {msg}")


def bad(msg):
    global fails
    fails += 1
    print(f"  FAIL  {msg}")


def cant(msg):
    global cannots
    cannots += 1
    print(f"  CANNOT-RUN  {msg}")


def check(name, want, got):
    if want == got:
        ok(f"{name} -> {got!r}")
    else:
        bad(f"{name}: want {want!r}, got {got!r}")


def load_tp():
    spec = importlib.util.spec_from_file_location("tp_withdraw", HERE / "test_public_lookups_withdraw.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


LOCAL = {"Origin": "http://127.0.0.1:8089", "Sec-Fetch-Site": "same-origin"}
FOREIGN = {"Origin": "https://evil.example", "Sec-Fetch-Site": "cross-site"}


def main() -> int:
    if not (AGENT / "web_ui.py").exists():
        cant("vendor/doctor/agent/web_ui.py is missing from the checkout")
        return 2
    try:
        from fastapi.testclient import TestClient  # noqa: WPS433
    except Exception as exc:  # noqa: BLE001
        cant(f"fastapi TestClient unavailable: {exc}")
        return 2
    sys.path.insert(0, str(AGENT))
    try:
        import web_ui
        import consent_enrichment
        import owner_peer
    except Exception as exc:  # noqa: BLE001
        cant(f"Doctor web_ui did not import: {exc!r}")
        return 2
    # The global owner gate asks the kernel which process holds the client
    # socket. owner_peer._lookup is the documented seam for exactly this
    # ("so tests can stand in for the kernel"); the kernel check itself is
    # covered by test_doctor_credential_routes_owner_only.sh. Stand in an
    # owner-uid peer here, and a different-uid peer for the refusal arm.
    peer_owner = {"uid": owner_peer.owner_uid()}
    owner_peer._lookup = lambda ch, cp, sp: owner_peer.Peer(
        pid=os.getpid(), uid=peer_owner["uid"], command="python3")

    tp = load_tp()
    fn_src = tp.extract_flag_fn()
    try:
        tp._GATE = tp.load_cm019_gate()
    except Exception as exc:  # noqa: BLE001
        cant(f"CM019 gate did not import: {exc}")
        return 2

    sandbox = Path(tempfile.mkdtemp(prefix="doctor-toggle-134-"))
    srv, handler = tp.start_proxy()
    proxy_url = f"http://127.0.0.1:{srv.server_address[1]}"
    old_env = {k: os.environ.get(k) for k in ("OSTLER_DIR", "HOME", "OSTLER_CONSENT_ENRICHMENT_DECISION")}
    try:
        base = sandbox / ".ostler"
        (base / "config").mkdir(parents=True)
        (base / "config" / ".env").write_text('USER_NAME="synthetic-owner"\nOSTLER_CONSENT_ENRICHMENT_DECISION="accepted"\n')
        os.environ["OSTLER_DIR"] = str(base)
        os.environ["HOME"] = str(sandbox)
        client = TestClient(web_ui.app, client=("127.0.0.1", 50000))

        def run(label):
            return tp.one_run(label, base, fn_src, proxy_url, handler)

        def file_says():
            return consent_enrichment.read_decision_from_base(base)

        print("A. control: consent accepted, next run reaches the wire")
        a = run("accepted")
        check("accepted: flag", "agreed", a["flag"])
        if a["requests"] >= 1:
            ok(f"accepted: {a['requests']} request(s) at the proxy (counter is live)")
        else:
            bad("CONTROL dead: accepted but 0 requests reached the proxy")

        print("B. POST declined (same-origin) withdraws, next run sends nothing")
        r = client.post("/api/v1/consent/public-lookups", json={"decision": "declined"}, headers=LOCAL)
        check("POST declined status", 200, r.status_code)
        check("POST declined: file", "declined", file_says())
        check("POST declined: event", "withdrawn", r.json()["event"]["event"])
        events = [json.loads(x) for x in (base / "posture" / "consent-events.jsonl").read_text().splitlines()]
        check("event log last entry", "withdrawn", events[-1]["event"])
        b = run("withdrawn")
        check("withdrawn: flag", "off", b["flag"])
        check("withdrawn: gate", False, b["gate"])
        check("withdrawn: requests at the proxy", 0, b["requests"])

        print("C. a cross-site POST, and a non-owner caller, are refused and change nothing")
        peer_owner["uid"] = owner_peer.owner_uid() + 1
        r = client.post("/api/v1/consent/public-lookups", json={"decision": "accepted"}, headers=LOCAL)
        check("non-owner POST status", 403, r.status_code)
        check("non-owner POST left the file alone", "declined", file_says())
        peer_owner["uid"] = owner_peer.owner_uid()
        r = client.post("/api/v1/consent/public-lookups", json={"decision": "accepted"}, headers=FOREIGN)
        check("cross-site POST status", 403, r.status_code)
        check("cross-site POST left the file alone", "declined", file_says())

        print("D. POST accepted again, next run reaches the wire")
        r = client.post("/api/v1/consent/public-lookups", json={"decision": "accepted"}, headers=LOCAL)
        check("POST accepted status", 200, r.status_code)
        d = run("re-accepted")
        if d["requests"] >= 1:
            ok(f"re-accepted: {d['requests']} request(s) at the proxy")
        else:
            bad("re-accepted: 0 requests after giving consent again")

        print("E. the Configuration page renders the control")
        client.post("/api/v1/consent/public-lookups", json={"decision": "declined"}, headers=LOCAL)
        page = client.get("/config", headers=LOCAL)
        check("GET /config status", 200, page.status_code)
        check("page shows state Off", True, "Off. Ostler sends nothing" in page.text)
        check("page has the toggle button", True, 'id="publicLookupsBtn"' in page.text)
        check("page has the Turn on label", True, "Turn on" in page.text)

        print("F. MUTANT: a writer that answers 200 and writes nothing")
        consent_enrichment.set_decision(base, "accepted")  # the owner had said yes
        check("mutant precondition: file says accepted", "accepted", file_says())
        real_set = consent_enrichment.set_decision
        consent_enrichment.set_decision = lambda base, decision, **kw: {
            "event": "withdrawn", "decision": decision, "previous": "accepted"}
        try:
            # file still says accepted; the mutant route says it withdrew
            client.post("/api/v1/consent/public-lookups", json={"decision": "declined"}, headers=LOCAL)
        finally:
            consent_enrichment.set_decision = real_set
        f = run("mutant")
        red = []
        if f["flag"] != "off":
            red.append(f"flag {f['flag']!r} != 'off'")
        if f["requests"] != 0:
            red.append(f"{f['requests']} request(s) after the mutant said withdrawn")
        if red:
            ok(f"mutant RED as required ({'; '.join(red)})")
        else:
            bad("MUTANT NOT DETECTED: a route that answers withdrawn and writes nothing looked clean")
    finally:
        srv.shutdown()
        for k, v in old_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(sandbox, ignore_errors=True)

    print(f"\n{passes} passed, {fails} failed, {cannots} cannot-run")
    if cannots:
        return 2
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
