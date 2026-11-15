#!/usr/bin/env python3
"""Do derived preferences ("What you like") reach the digest AND the assistant tool?

smart-prefs probe. Three assertions, graded from yes/no facts and counts only
(no preference label, digest line or reply prose leaves the box):

  route   GET /api/v1/preferences/derived (the route the assistant's
          pwg_derived_preferences tool reads) answers 200, not degraded, with
          at least one item. Nothing derived means the other two are CANNOT-RUN,
          never a pass: there is nothing to look for.
  digest  CONTEXT.md's "Preferences and things to keep in mind" names at least
          one label the route serves.
  tool    asking the assistant what the owner likes, a reply names at least one
          label the route serves.

Modes (stdlib only, python3 3.9+):
  box    runs ON the box (staged by the probe with lib/owner_digest.py).
         Prints one JSON fact object.
  judge  FACTS.json -> prints ok/FAIL/CANNOT lines. Exit 0 all ok, 1 any FAIL,
         78 none failed but one could not be measured.
  --self-test  the judge against a good fixture and one mutant per assertion;
         exit 0 when it behaves (every mutant went red by its own assertion),
         exit 1 when one slipped through (BROKEN), as lib/owner_digest.py.
"""
import json
import os
import re
import sys

DECLARED = [
    "route: /api/v1/preferences/derived serves at least one derived preference, not degraded",
    "digest: the Preferences section names a derived preference",
    "tool: asked what the owner likes, the assistant names a derived preference",
]
ROUTE_URL = os.environ.get("OSTLER_HUB_URL", "http://127.0.0.1:8090") + "/api/v1/preferences/derived?limit=50&min_confidence=0&tier=all"
PREFERENCES = "Preferences and things to keep in mind"
QUESTION = "What kinds of things do I like? Answer from my derived preferences."


def judge(f):
    """-> [(name, state, detail)] with state in ok|FAIL|CANNOT."""
    rows = []
    r = f.get("route") or {}
    measured = r.get("status") is not None
    if not measured:
        why = "route unmeasured: %s" % r.get("error", "no reading")
        return [(n, "CANNOT", why) for n in DECLARED]
    served = r.get("status") == 200 and not r.get("degraded") and (r.get("items") or 0) > 0
    detail = "status=%s degraded=%s items=%s" % (r.get("status"), r.get("degraded"), r.get("items"))
    dv = f.get("derive") or {}
    if not served and r.get("status") == 200 and dv.get("completed_pass") is False:
        # NO DERIVE PASS HAS COMPLETED ON THIS BOX YET, after the wait below: nothing was derived to serve,
        # so this is timing, not the route. Only a route that ANSWERED 200 and an EXPLICIT False read this
        # way; a 404/500 route or a missing reading keeps the FAIL. A product whose engine never completes a pass is red on derived_preferences_runs.
        why = ("no derive pass has completed on this box (outcome %s) after %ss of a %ss budget "
               "(OSTLER_DERIVED_FIRST_PASS_WAIT_S; the product retries every 30 min); %s"
               % (dv.get("outcome"), dv.get("waited_s"), dv.get("budget_s"), detail))
        return [(n, "CANNOT", why) for n in DECLARED]
    rows.append((DECLARED[0], "ok" if served else "FAIL", detail))
    if not served:
        why = "nothing derived is served, so there is nothing to look for"
        return rows + [(DECLARED[1], "CANNOT", why), (DECLARED[2], "CANNOT", why)]
    d = f.get("digest") or {}
    if not d.get("present"):
        rows.append((DECLARED[1], "CANNOT", "CONTEXT.md is missing or empty"))
    else:
        hit = d.get("names_derived") or 0
        rows.append((DECLARED[1], "ok" if hit > 0 else "FAIL",
                     "preferences_lines=%s derived_labels_named=%s of %s served"
                     % (d.get("preferences_lines"), hit, r.get("labels"))))
    c = f.get("chat") or {}
    if not c.get("answered"):
        rows.append((DECLARED[2], "CANNOT", "chat did not answer: %s" % c.get("error", "no reading")))
    else:
        rows.append((DECLARED[2], "ok" if c.get("names_derived") else "FAIL",
                     "reply names a served derived preference: %s" % bool(c.get("names_derived"))))
    return rows


def report(rows):
    for name, state, detail in rows:
        print("  %-6s %s%s" % (state if state != "CANNOT" else "CANNOT", name, " (%s)" % detail if detail else ""))
    if any(s == "FAIL" for _, s, _ in rows):
        return 1
    if any(s == "CANNOT" for _, s, _ in rows):
        return 78
    return 0


def _token():
    try:
        return open(os.path.expanduser("~/.ostler/secrets/service_token")).read().strip()
    except IOError:
        return ""


def read_route():
    """-> (fact, [labels]). A refused or unreachable read is a reading, not an absence."""
    import urllib.error
    import urllib.request
    req = urllib.request.Request(ROUTE_URL, headers={"Authorization": "Bearer " + _token()} if _token() else {})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=30) as resp:
            status, body = resp.status, json.loads(resp.read().decode() or "null")
    except urllib.error.HTTPError as e:
        return {"status": e.code, "degraded": None, "items": 0, "labels": 0}, []
    except Exception as e:  # transport: could not look
        return {"status": None, "error": type(e).__name__}, []
    items = body.get("items") if isinstance(body, dict) else None
    items = items if isinstance(items, list) else []
    labels = [str(i.get("label", "")).strip() for i in items if isinstance(i, dict) and (i.get("strength") or 0) > 0]
    return {"status": status, "degraded": bool((body or {}).get("degraded")) if isinstance(body, dict) else True,
            "items": len(items), "labels": len(labels)}, [l for l in labels if len(l) >= 3]


def names_any(text, labels):
    low = (text or "").lower()
    return sum(1 for l in labels if re.search(r"(?<!\w)" + re.escape(l.lower()) + r"(?!\w)", low))


STATUS = os.path.join(os.environ.get("OSTLER_DIR") or os.path.expanduser("~/.ostler"), "state",
                      "derived-preferences.json")


def derive_status():
    try:
        return json.load(open(STATUS)) or {}
    except (IOError, ValueError):
        return {}


def wait_for_route(wait_s, first_pass_s, read=None, status=None, clock=None, sleep=None):
    """Poll the route until it serves an item, or (a pass completed and wait_s spent), or first_pass_s spent.
    -> (route fact with "_labels", derive fact)."""
    import time
    read, status = read or read_route, status or derive_status
    clock, sleep = clock or time.time, sleep or time.sleep
    t0 = clock()
    while True:
        route, labels = read()
        st = status()
        completed = bool(st.get("last_completed_at") or st.get("last_run_at"))
        spent = clock() - t0
        # The first-pass extension applies only to a route that ANSWERED 200: an unreachable or refusing route
        # is not waiting on a derive pass, and keeps the 90 s wait (and its own verdict).
        answered = route.get("status") == 200
        budget = max(wait_s, first_pass_s) if (answered and not completed) else wait_s
        if (route.get("items") or 0) > 0 or spent >= budget:
            break
        sleep(5)
    route["_labels"] = labels
    return route, {"completed_pass": completed, "outcome": st.get("outcome"), "waited_s": int(spent),
                   "budget_s": int(budget)}


def box_main(argv):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import owner_digest as od
    facts = {}
    import time
    # The import kicks the derive agent and a pass takes a while: wait for the
    # route to serve something before calling the store empty.
    # Two budgets. OSTLER_DERIVED_WAIT_S (90) is how long an EMPTY route is waited on once a derive pass has
    # completed on the box. While NO pass has completed yet (a first-run box: the v1.0.125 first real pass took
    # 36 min), the wait extends to OSTLER_DERIVED_FIRST_PASS_WAIT_S (2100 = the product's 30 min retry plus 5),
    # and if still none, the judge reads CANNOT-RUN with the waited time, never PASS.
    facts["route"], facts["derive"] = wait_for_route(
        float(os.environ.get("OSTLER_DERIVED_WAIT_S", "90")),
        float(os.environ.get("OSTLER_DERIVED_FIRST_PASS_WAIT_S", "2100")))
    labels = facts["route"].pop("_labels", [])
    try:
        text = open(os.path.expanduser("~/.ostler/assistant-config/workspace/CONTEXT.md")).read()
    except IOError:
        text = ""
    pref = "\n".join(od.sections(text).get(PREFERENCES) or [])
    facts["digest"] = {"present": bool(text), "preferences_lines": len(od.sections(text).get(PREFERENCES) or []),
                       "names_derived": names_any(pref, labels)}
    if labels:
        reply = od.ask_chat_text(QUESTION)
        facts["chat"] = ({"answered": True, "names_derived": names_any(reply["text"], labels) > 0}
                         if reply.get("answered") else {"answered": False, "error": reply.get("error")})
    print(json.dumps(facts))
    return 0


def _good():
    return {"route": {"status": 200, "degraded": False, "items": 6, "labels": 5},
            "digest": {"present": True, "preferences_lines": 4, "names_derived": 2},
            "chat": {"answered": True, "names_derived": True}}


def self_test():
    import copy
    ok = True

    def expect(label, facts, want):
        nonlocal ok
        got = {n: s for n, s, _ in judge(facts)}
        bad = [(DECLARED[i], w) for i, w in want.items() if got[DECLARED[i]] != w]
        print("  %s %s" % ("ok  " if not bad else "BROKEN", label))
        if bad:
            ok = False
            for n, w in bad:
                print("         wanted %s for '%s', got %s" % (w, n, got[n]))
    expect("a good fixture passes all three", _good(), {0: "ok", 1: "ok", 2: "ok"})
    m = copy.deepcopy(_good()); m["route"]["items"] = 0
    expect("MUTANT empty route fails route, the rest cannot run", m, {0: "FAIL", 1: "CANNOT", 2: "CANNOT"})
    m = copy.deepcopy(_good()); m["route"]["degraded"] = True
    expect("MUTANT degraded route fails route (never a healthy empty)", m, {0: "FAIL", 1: "CANNOT", 2: "CANNOT"})
    m = copy.deepcopy(_good()); m["route"] = {"status": None, "error": "URLError"}
    expect("MUTANT unreachable route is CANNOT, never FAIL or ok", m, {0: "CANNOT", 1: "CANNOT", 2: "CANNOT"})
    m = copy.deepcopy(_good()); m["digest"]["names_derived"] = 0
    expect("MUTANT digest naming none fails digest only", m, {0: "ok", 1: "FAIL", 2: "ok"})
    m = copy.deepcopy(_good()); m["digest"] = {"present": False}
    expect("MUTANT missing CONTEXT.md is CANNOT for digest", m, {0: "ok", 1: "CANNOT", 2: "ok"})
    m = copy.deepcopy(_good()); m["chat"]["names_derived"] = False
    expect("MUTANT chat reply naming none fails tool only", m, {0: "ok", 1: "ok", 2: "FAIL"})
    m = copy.deepcopy(_good()); m["chat"] = {"answered": False, "error": "no done frame"}
    expect("MUTANT unanswered chat is CANNOT for tool", m, {0: "ok", 1: "ok", 2: "CANNOT"})
    m = copy.deepcopy(_good()); m["route"]["items"] = 0
    m["derive"] = {"completed_pass": False, "outcome": "deferred", "waited_s": 2100, "budget_s": 2100}
    expect("no pass completed after the budget: CANNOT for all three, never ok", m, {0: "CANNOT", 1: "CANNOT", 2: "CANNOT"})
    m["derive"]["completed_pass"] = True
    expect("MUTANT a pass completed and the route is still empty: route FAIL", m, {0: "FAIL", 1: "CANNOT", 2: "CANNOT"})
    m = copy.deepcopy(_good()); m["route"] = {"status": 404, "degraded": None, "items": 0, "labels": 0}
    m["derive"] = {"completed_pass": False, "waited_s": 90, "budget_s": 90}
    expect("MUTANT a 404 route with no pass yet still FAILs route (absence of the route is not timing)", m,
           {0: "FAIL", 1: "CANNOT", 2: "CANNOT"})
    m = copy.deepcopy(_good()); m["derive"] = {"completed_pass": False}
    expect("a served route passes even before the status file shows a pass", m, {0: "ok", 1: "ok", 2: "ok"})
    # the wait itself, through the REAL wait_for_route with a stubbed reader and clock
    for label, arrive, done_at, want_items, want_waited in (
            ("route serves on the 4th read, inside the first-pass budget", 4, None, 6, 15),
            ("no pass ever completes: stops at the first-pass budget", 0, None, 0, 2100),
            ("a pass completed at once and the route stays empty: stops at the 90 s floor", 0, 0, 0, 90),
            ("an unreachable route is not waiting on a pass: stops at the 90 s floor", -1, None, 0, 90)):
        now, reads = [0.0], [0]

        def rd(arrive=arrive):
            reads[0] += 1
            if arrive < 0:
                return {"status": None, "error": "URLError"}, []
            n = 6 if arrive and reads[0] >= arrive else 0
            return {"status": 200, "degraded": False, "items": n, "labels": n}, ["x"] * n

        def stt(done_at=done_at):
            return {"last_run_at": "2026-01-01T00:00:00Z"} if done_at is not None and now[0] >= done_at else {}
        r, d = wait_for_route(90, 2100, read=rd, status=stt, clock=lambda: now[0],
                              sleep=lambda s: now.__setitem__(0, now[0] + s))
        good = (r.get("items") or 0) == want_items and d["waited_s"] == want_waited
        print("  %s %s (items %s waited %s)" % ("ok  " if good else "BROKEN", label, r.get("items"), d["waited_s"]))
        ok = ok and good
    expect("names_any counts whole labels only", {"route": {"status": 200, "degraded": False, "items": 1, "labels": 1},
           "digest": {"present": True, "preferences_lines": 1, "names_derived": names_any("Jazzy things", ["jazz"])},
           "chat": {"answered": True, "names_derived": True}}, {1: "FAIL"})
    print("SELF-TEST %s" % ("behaved: every mutant went red by its own assertion" if ok else "BROKEN"))
    return 0 if ok else 1


def main(argv):
    if argv and argv[0] == "--self-test":
        return self_test()
    if argv and argv[0] == "box":
        return box_main(argv[1:])
    if len(argv) == 2 and argv[0] == "judge":
        return report(judge(json.load(open(argv[1]))))
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
