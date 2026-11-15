#!/usr/bin/env python3
"""/api/v1/preferences never RETURNS a GDPR Art. 9 special-category topic
(board row 2471a, v1.0.119).

The interest profile keeps every row; the Assistant API read-out must
withhold any whose topic falls in one of the eight Art. 9(1) classes, using
the SAME list the Front Page uses. This drives the REAL vendored ical-server
as a subprocess over a synthetic interest_profile.json and asserts:
  * no sensitive subject (every class) is in the response;
  * every ordinary control is, including words that merely contain a stem;
  * the server's copy of the list is current with the one list
    (scripts/gen_assistant_api_sensitive_topics.py --check).
Exit 0 pass, 1 fail, 2 CANNOT-RUN.
"""
import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
SERVER = ROOT / "vendor/cm041/assistant_api/ical-server.py"
GEN = ROOT / "scripts/gen_assistant_api_sensitive_topics.py"
TOKEN = "fixture-service-token"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
FAILS = []

# Synthetic subjects, one class per key. None names a real person.
SENSITIVE = {
    "racial_ethnic_origin": ["Ethnic minority networking", "Hispanic heritage events"],
    "political_opinions": ["Election night coverage", "labour party conference"],
    "religious_philosophical_beliefs": ["Sunday church services", "Ramadan iftar recipes"],
    "trade_union_membership": ["Trade union meetings", "Picket line solidarity"],
    "genetic_data": ["Genetic ancestry testing", "23andMe results"],
    "biometric_data": ["Fingerprint unlock enrolment", "Iris scan registration"],
    "health": ["Diabetes support group", "Marathon for diabetes charity"],
    "sex_life_orientation": ["Gay bars", "LGBTQ film nights"],
}
CONTROLS = ["Trail running", "History podcasts", "Magazine design",
            "Archive footage", "Retail therapy weekends"]


def check(name, cond, detail=""):
    print(("  ok    " if cond else "  FAIL  ") + name + (("  -- " + detail) if detail and not cond else ""))
    if not cond:
        FAILS.append(name)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main():
    rows, i = [], 0
    for subjects in list(SENSITIVE.values()) + [CONTROLS]:
        for s in subjects:
            i += 1
            rows.append({"id": "art9-%d" % i, "subject": s, "domain": "Other",
                         "score": 1.0 - i / 100.0, "confidence": 0.9,
                         "polarity": "like", "privacy": "L1",
                         "sources": ["synthetic:test"], "evidence": ["synthetic"]})
    work = pathlib.Path(tempfile.mkdtemp(prefix="art9-api-"))
    prof = work / "interest_profile.json"
    prof.write_text(json.dumps({"schema_version": 1, "generated_at": "2026-10-29T00:00:00Z",
                                "count": len(rows), "interests": rows}))
    dead = "http://127.0.0.1:%d" % free_port()  # no store is needed for this route
    port = free_port()
    env = {k: v for k, v in os.environ.items() if "proxy" not in k.lower()}
    env.pop("OSTLER_DB_KEY", None)
    env.update({
        "OSTLER_API_PORT": str(port), "OXIGRAPH_URL": dead, "QDRANT_URL": dead,
        "EMBED_OLLAMA_URL": dead, "OSTLER_SERVICE_TOKEN": TOKEN,
        "USER_ID": "fixtureowner", "HOME": str(work), "PWG_HOME": str(work / "pwg"),
        "OSTLER_INTEREST_PROFILE": str(prof), "NO_PROXY": "*",
        "PYTHONDONTWRITEBYTECODE": "1", "WIKI_BASE_URL": "http://wiki.example",
        "PYTHONPATH": os.pathsep.join([str(ROOT / "vendor/cm041"), str(ROOT / "vendor")]),
    })
    proc = subprocess.Popen([sys.executable, str(SERVER)], env=env, cwd=str(SERVER.parent),
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    url = "http://127.0.0.1:%d" % port
    try:
        for _ in range(150):
            if proc.poll() is not None:
                print("CANNOT-RUN: ical-server exited: " + proc.stderr.read().decode()[-600:])
                return 2
            try:
                OPENER.open(url + "/health", timeout=1).read()
                break
            except Exception:
                time.sleep(0.1)
        else:
            print("CANNOT-RUN: ical-server did not come up")
            return 2
        req = urllib.request.Request(url + "/api/v1/preferences",
                                     headers={"Authorization": "Bearer " + TOKEN})
        try:
            with OPENER.open(req, timeout=15) as r:
                code, body = r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            code, body = e.code, {}
    finally:
        proc.kill()
        proc.wait(5)

    check("GET /api/v1/preferences answers 200", code == 200, str(code))
    got = {str(it.get("subject") or "").lower() for it in body.get("interests", [])}
    check("the response is not a degraded empty list", not body.get("degraded"),
          str(body.get("reason")))
    for cls, subjects in sorted(SENSITIVE.items()):
        for s in subjects:
            check("{}: {!r} is never returned".format(cls, s), s.lower() not in got)
    for c in CONTROLS:
        check("control {!r} is still returned".format(c), c.lower() in got, repr(sorted(got)))
    check("count matches what is returned", body.get("count") == len(body.get("interests", [])))

    rc = subprocess.call([sys.executable, str(GEN), "--check"])
    check("the server's list is generated from the one list and current", rc == 0)
    print("{} fail".format(len(FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
