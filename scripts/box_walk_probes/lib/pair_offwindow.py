"""pair_endpoints_refuse_off_window: judge (pure) + self-test.

Security (Archie, #17). From a NON-loopback address on the LAN, with no
pairing window open, POST /api/pair and POST /pair on the companion listener
(:8443) must be refused AT THE ROUTER, 404 or 403, without a code ever being
evaluated. Evidence of a code check, either of which FAILS:
  * the response body carries code-validation text. The daemon's own words,
    ostler-assistant crates/zeroclaw-gateway: "Invalid pairing code" (lib.rs
    handle_pair, 403), "Invalid or expired pairing code" (api_pairing.rs, 400),
    "Too many failed attempts" / "Locked out" (lockout), "Too many auth attempts";
  * the daemon log gained a code-check line during the request window:
    "Pairing attempt with invalid code", "Pairing locked out",
    "Pairing auth rate limit exceeded".
A 403 alone proves nothing: the code-checking path ALSO answers 403.

Capture JSON: {"source": "lan"|"loopback", "endpoints": [{"path", "status",
"body"}], "log_readable": bool, "log_hits": [str], "window": "none-offered"|...}
Exit: 0 pass, 1 fail, 78 cannot-run.
"""
import json
import re
import sys

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78
BODY_CODE_CHECK = re.compile(r"invalid|expired|pairing code|too many|locked out|attempt|try again", re.I)
LOG_CODE_CHECK = re.compile(r"Pairing attempt with invalid code|Pairing locked out|Pairing auth rate limit exceeded|"
                            r"/pair rate limit exceeded", re.I)


def judge(c):
    lines, fail = [], False

    def check(label, ok):
        nonlocal fail
        lines.append(("  ok     " if ok else "  FAIL   ") + label)
        fail |= not ok

    if c.get("source") != "lan":
        return ["  CANNOT the requests did not come from a non-loopback LAN address (source %r); "
                "a loopback request proves nothing about the LAN" % c.get("source")], EX_CANNOT
    eps = c.get("endpoints") or []
    if not eps:
        return ["  CANNOT no request was made"], EX_CANNOT
    for e in eps:
        st = e.get("status")
        if not isinstance(st, int) or st == 0:
            lines.append("  CANNOT POST %s got no HTTP answer (transport), not measured" % e.get("path"))
            return lines, EX_CANNOT
        check("POST %s off-window is refused at the router (HTTP %s, want 404 or 403)" % (e["path"], st), st in (403, 404))
        hit = BODY_CODE_CHECK.search(e.get("body") or "")
        check("POST %s body carries no code-validation text%s" % (e["path"], (" (found %r)" % hit.group(0)) if hit else ""),
              not hit)
    if not c.get("log_readable"):
        lines.append("  CANNOT the daemon log could not be read, so 'no code check ran' is NOT MEASURED")
        return lines, EX_FAIL if fail else EX_CANNOT
    hits = c.get("log_hits") or []
    check("the daemon log shows no code check during the requests%s" % (" (%d line(s))" % len(hits) if hits else ""),
          not hits)
    if c.get("window") in (None, "none-offered"):
        lines.append("  note   no way to open a pairing window is offered on this box; the 6-wrong-codes lockout arm is NOT INSTRUMENTED")
    else:
        lo = c.get("lockout") or {}
        check("with a window open, 6 wrong codes in a row are locked out (last status %s)" % lo.get("last_status"),
              lo.get("locked") is True)
    return lines, EX_FAIL if fail else EX_PASS


def self_test():
    ok = True
    good = {"source": "lan", "log_readable": True, "log_hits": [], "window": "none-offered",
            "endpoints": [{"path": "/api/pair", "status": 404, "body": ""},
                          {"path": "/pair", "status": 404, "body": "Not Found"}]}
    cases = [
        ("clean 404s, no log line", good, EX_PASS),
        ("refused 403 with a neutral body", dict(good, endpoints=[{"path": "/api/pair", "status": 403, "body": "Forbidden"},
                                                                  {"path": "/pair", "status": 403, "body": ""}]), EX_PASS),
        ("canned 400 'Invalid or expired pairing code' (/api/pair today)",
         dict(good, endpoints=[{"path": "/api/pair", "status": 400, "body": "Invalid or expired pairing code"}]), EX_FAIL),
        ("canned 403 {'error': 'Invalid pairing code'} (/pair today: a 403 that DID check the code)",
         dict(good, endpoints=[{"path": "/pair", "status": 403, "body": '{"error":"Invalid pairing code"}'}]), EX_FAIL),
        ("404 body but the daemon logged a code check",
         dict(good, log_hits=["WARN 🔐 Pairing attempt with invalid code"]), EX_FAIL),
        ("200 off-window", dict(good, endpoints=[{"path": "/api/pair", "status": 200, "body": "{}"}]), EX_FAIL),
        ("window open, lockout never triggers", dict(good, window="opened", lockout={"locked": False, "last_status": 403}), EX_FAIL),
        ("from loopback", dict(good, source="loopback"), EX_CANNOT),
        ("no HTTP answer", dict(good, endpoints=[{"path": "/api/pair", "status": 0, "body": ""}]), EX_CANNOT),
    ]
    for name, c, want in cases:
        _, rc = judge(c)
        print("  %s  %s -> %s" % ("ok   " if rc == want else "FAIL ", name, {0: "PASS", 1: "FAIL", 78: "CANNOT"}[rc]))
        ok &= rc == want
    print("every mutant went red" if ok else "SELF-TEST BROKEN")
    return 0 if ok else 1


if __name__ == "__main__":
    if sys.argv[1:2] == ["--self-test"]:
        sys.exit(self_test())
    if sys.argv[1:2] == ["judge"]:
        lines, rc = judge(json.load(open(sys.argv[2])))
        print("\n".join(lines))
        sys.exit(rc)
    print(__doc__)
    sys.exit(2)
