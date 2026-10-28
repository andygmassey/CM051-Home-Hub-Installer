"""l3_not_prefetched: a synthetic L3 person must not surface on the surface the daemon prefetches from (#2435).

WHAT "PREFETCH" MEANS HERE. ostler-assistant #428 (daemon graph prefetch, tool_origin daemon_prefetch) runs pwg_people
BEFORE the model sees a question that names a person. pwg_people makes the identical loopback call the model-driven tool
does: GET /api/v1/people/context?name= (Oxigraph) and, on found:false, GET /api/v1/people/search?q= (Qdrant); see the
route notes in probes/people_seed_and_retrieval.sh:67-71. The person-level L3 drop on that fallback is
vendor/cm041/assistant_api/ical-server.py:2245-2251 (pwg_privacy.parse_privacy_level(...) == "L3" -> continue); the
context-side filters are :6378 and :6790. Anything the search returns is what the prefetch injects into the turn, so
this probe reads that surface: a person withheld there cannot be prefetched into the reply.

SEED. Two synthetic people in the Qdrant `people` collection, identical shape, differing only in privacy_level: an L3
subject and an L1 CONTROL. Three query shapes per person (name, organisation, email). The control must be found on all
three shapes (else the instrument is blind: CANNOT-RUN). The subject must be found on none (else FAIL).
Cleanup is verified. Synthetic only: reserved .example domains, Ofcom drama-range 07700 900xxx numbers.

NOT COVERED, SAID PLAINLY (NOT INSTRUMENTED): (1) the Oxigraph /people/context leg, because the API cannot mint a
person-level L3 node (memory/assert writes facts, not a person tag) and a raw SPARQL write is out of scope; (2) the
chat-level check that a live daemon_prefetch tool_result and the model reply withhold the L3 person, which needs the
loopback model of lib/send_safety.py; the command that would show it is
`grep -c 'FRAME tool_origin pwg_people daemon_prefetch'` over an assistant_grounds_the_opening_turn capture that asks
about the seeded L3 name; (3) any assistant memory (core_*) written from a prefetch block, which is #2436.

  box            drive on the box, print ONE json capture (no secret is read into output)
  judge FILE     judge a capture: exit 0 PASS, 1 FAIL, 78 CANNOT-RUN
  --self-test    canned captures; exits 0 only if every case lands on its expected verdict

Python 3.9, stdlib only. The store credential is presented via the install's own curl -K config, never loaded here.
"""
import json
import os
import subprocess
import sys
import urllib.parse
import uuid

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78
HOME = os.path.expanduser("~")
API = os.environ.get("OSTLER_PROBE_API_BASE", "http://127.0.0.1:8090").rstrip("/")
QDRANT = os.environ.get("OSTLER_PROBE_QDRANT_BASE", "http://127.0.0.1:6333").rstrip("/")
EMBED = os.environ.get("OSTLER_PROBE_EMBED_BASE", "http://127.0.0.1:11434").rstrip("/")
EMBED_MODEL = os.environ.get("OSTLER_PROBE_EMBED_MODEL", "nomic-embed-text")
COLLECTION = os.environ.get("OSTLER_PROBE_COLLECTION", "people")
TOKEN_PATH = os.environ.get("OSTLER_PROBE_TOKEN_PATH", os.path.join(HOME, ".ostler", "secrets", "service_token"))
STORE_CONF = os.environ.get("OSTLER_PROBE_STORE_CURL_CONF", os.path.join(HOME, ".ostler", "secrets", "store-curl.conf"))

SUBJECTS = {
    "l3": {"level": "L3", "name": "Jane Doe", "org": "Globex Corp probe-l3",
           "email": "subject@l3probe.example", "phone": "+44 7700 900871"},
    "l1": {"level": "L1", "name": "John Smith", "org": "Initech Corp probe-l1",
           "email": "control@l1probe.example", "phone": "+44 7700 900872"},
}
for _k, _s in SUBJECTS.items():
    _s["id"] = str(uuid.uuid5(uuid.NAMESPACE_URL, "https://ostler.test/box-walk-probe/l3-prefetch/" + _k))
    _s["uri"] = "https://ostler.test/box-walk-probe/l3-prefetch/person/" + _k
SHAPES = ("name", "org", "email")


def _curl(method, url, store=False, bearer=None, body=None, tmo=20):
    cmd = ["/usr/bin/curl", "-sS", "--noproxy", "*", "--max-time", str(tmo), "-w", "\n%{http_code}", "-X", method]
    if store:
        cmd += ["-K", STORE_CONF]
    if bearer:
        cmd += ["-H", "Authorization: Bearer " + bearer]
    if body is not None:
        cmd += ["-H", "Content-Type: application/json", "--data-binary", "@-"]
    p = subprocess.run(cmd + [url], input=(json.dumps(body).encode() if body is not None else None),
                       capture_output=True)
    raw = p.stdout.decode("utf-8", "replace")
    text, _, code = raw.rpartition("\n")
    try:
        data = json.loads(text) if text.strip() else None
    except ValueError:
        data = None
    return code.strip() or "000", data


def _vec_spec(coll):
    try:
        v = coll["result"]["config"]["params"]["vectors"]
    except (TypeError, KeyError):
        return None
    if isinstance(v, dict) and "size" in v:
        return ("-", int(v["size"]))
    if isinstance(v, dict) and v:
        k = sorted(v)[0]
        return (k, int(v[k]["size"]))
    return None


def _query_for(subj, shape):
    return {"name": subj["name"], "org": subj["org"], "email": subj["email"]}[shape]


def box():
    cap = {"stage": "start", "cannot": None, "seeded": [], "queries": [], "cleanup": None}
    try:
        token = os.environ.get("OSTLER_SERVICE_TOKEN") or open(TOKEN_PATH).read().strip()
    except OSError as e:
        cap["cannot"] = "no service token (%s): the API fails closed with 401" % e.strerror
        return cap
    if not os.path.exists(STORE_CONF):
        cap["cannot"] = "no store curl config at %s: the people collection cannot be written" % STORE_CONF
        return cap
    code, coll = _curl("GET", "%s/collections/%s" % (QDRANT, COLLECTION), store=True)
    spec = _vec_spec(coll)
    if code != "200" or not spec:
        cap["cannot"] = "qdrant collection %s unreadable (HTTP %s)" % (COLLECTION, code)
        return cap
    ids = [s["id"] for s in SUBJECTS.values()]
    try:
        _curl("POST", "%s/collections/%s/points/delete?wait=true" % (QDRANT, COLLECTION), store=True,
              body={"points": ids})
        for k, s in SUBJECTS.items():
            ecode, emb = _curl("POST", EMBED + "/api/embed", body={
                "model": EMBED_MODEL, "input": ["%s %s %s" % (s["name"], s["org"], s["email"])]}, tmo=40)
            try:
                vec = emb["embeddings"][0]
            except (TypeError, KeyError, IndexError):
                vec = None
            if ecode != "200" or not vec or len(vec) != spec[1]:
                cap["cannot"] = "embedder gave HTTP %s / width mismatch for the %s fixture" % (ecode, k)
                return cap
            point = {"id": s["id"], "payload": {
                "display_name": s["name"], "organization": s["org"], "job_title": "Probe Fixture",
                "relationship": "test fixture", "emails": [s["email"]], "phones": [s["phone"]],
                "contact_type": "person", "person_uri": s["uri"], "privacy_level": s["level"],
                "box_walk_probe": True}}
            point["vector"] = vec if spec[0] == "-" else {spec[0]: vec}
            ucode, _ = _curl("PUT", "%s/collections/%s/points?wait=true" % (QDRANT, COLLECTION), store=True,
                             body={"points": [point]})
            if ucode != "200":
                cap["cannot"] = "qdrant refused the %s seed (HTTP %s)" % (k, ucode)
                return cap
            cap["seeded"].append(k)
        for k, s in SUBJECTS.items():
            for shape in SHAPES:
                qcode, d = _curl("GET", "%s/api/v1/people/search?q=%s" % (API, urllib.parse.quote(_query_for(s, shape))),
                                 bearer=token)
                res = d.get("results") if isinstance(d, dict) else None
                cap["queries"].append({
                    "subject": k, "shape": shape, "http": qcode,
                    "degraded": bool(isinstance(d, dict) and d.get("degraded")),
                    "results": len(res) if isinstance(res, list) else None,
                    "returned_uris": sorted({r.get("person_uri") for r in (res or []) if r.get("person_uri")
                                             and "/l3-prefetch/" in r.get("person_uri")})})
    finally:
        dcode, _ = _curl("POST", "%s/collections/%s/points/delete?wait=true" % (QDRANT, COLLECTION), store=True,
                         body={"points": ids})
        rcode, back = _curl("POST", "%s/collections/%s/points" % (QDRANT, COLLECTION), store=True,
                            body={"ids": ids, "with_payload": False})
        left = len(back.get("result", [])) if isinstance(back, dict) else None
        cap["cleanup"] = {"delete_http": dcode, "points_left": left}
    cap["stage"] = "done"
    return cap


def judge(cap):
    """-> (rc, lines)."""
    if cap.get("cannot"):
        return EX_CANNOT, ["CANNOT " + cap["cannot"]]
    qs = cap.get("queries") or []
    if len(qs) != 2 * len(SHAPES):
        return EX_CANNOT, ["CANNOT only %d of %d queries ran (stage=%s)" % (len(qs), 2 * len(SHAPES), cap.get("stage"))]
    lines, rc = [], EX_PASS
    bad_http = [q for q in qs if q["http"] != "200" or q["degraded"] or q["results"] is None]
    if bad_http:
        return EX_CANNOT, ["CANNOT %d query(ies) were not a clean 200 (HTTP %s, degraded=%s): inconclusive, not absence"
                           % (len(bad_http), bad_http[0]["http"], bad_http[0]["degraded"])]
    l1_uri, l3_uri = SUBJECTS["l1"]["uri"], SUBJECTS["l3"]["uri"]
    blind = [q["shape"] for q in qs if q["subject"] == "l1" and l1_uri not in q["returned_uris"]]
    if blind:
        return EX_CANNOT, ["CANNOT control L1 person not found on shape(s) %s: the instrument cannot see a person "
                           "it should, so a missing L3 person proves nothing" % ",".join(blind)]
    leaks = [q["shape"] for q in qs if q["subject"] == "l3" and l3_uri in q["returned_uris"]]
    lines.append("controls_found=%d/%d l3_queries=%d l3_leaks=%d"
                 % (len(SHAPES), len(SHAPES), len(SHAPES), len(leaks)))
    if leaks:
        rc = EX_FAIL
        lines.append("FAIL the L3 person was returned by people/search on shape(s) %s: a daemon prefetch would inject them"
                     % ",".join(leaks))
    cl = cap.get("cleanup") or {}
    if cl.get("points_left") != 0:
        rc = EX_FAIL
        lines.append("FAIL cleanup left %s synthetic point(s) in %s (delete HTTP %s)"
                     % (cl.get("points_left"), COLLECTION, cl.get("delete_http")))
    return rc, lines


def _canned(l3_shapes=(), l1_shapes=SHAPES, http="200", degraded=False, left=0, cannot=None):
    qs = []
    for k, found in (("l3", l3_shapes), ("l1", l1_shapes)):
        for sh in SHAPES:
            qs.append({"subject": k, "shape": sh, "http": http, "degraded": degraded, "results": 1,
                       "returned_uris": [SUBJECTS[k]["uri"]] if sh in found else []})
    return {"stage": "done", "cannot": cannot, "seeded": ["l3", "l1"], "queries": qs,
            "cleanup": {"delete_http": "200", "points_left": left}}


def self_test():
    cases = [
        ("clean: L3 absent, control seen", _canned(), EX_PASS),
        ("RED: L3 returned on the name shape", _canned(l3_shapes=("name",)), EX_FAIL),
        ("RED: L3 returned on every shape", _canned(l3_shapes=SHAPES), EX_FAIL),
        ("blind: control not found on one shape", _canned(l1_shapes=("name", "org")), EX_CANNOT),
        ("blind: nothing found at all (a filter that drops everything)", _canned(l1_shapes=()), EX_CANNOT),
        ("degraded store is inconclusive", _canned(degraded=True), EX_CANNOT),
        ("401 is a token fault, not absence", _canned(http="401"), EX_CANNOT),
        ("cleanup left a point", _canned(left=1), EX_FAIL),
        ("box said cannot", _canned(cannot="no service token"), EX_CANNOT),
    ]
    bad = 0
    for label, cap, want in cases:
        got, _ = judge(cap)
        print("  %s %-62s want=%d got=%d" % ("ok  " if got == want else "WRONG", label, want, got))
        bad += got != want
    return EX_PASS if not bad else EX_FAIL


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["box"]:
        print(json.dumps(box()))
    elif a[:1] == ["judge"]:
        rc, lines = judge(json.load(open(a[1])))
        print("\n".join(lines))
        sys.exit(rc)
    elif a[:1] == ["--self-test"]:
        sys.exit(self_test())
    else:
        sys.exit("usage: box | judge FILE | --self-test")
