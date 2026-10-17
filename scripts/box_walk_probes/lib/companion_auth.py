"""companion_listener_refuses_unauthenticated: judge (pure) + self-test.

Security (red team DMG #27 F4-4, walk #27 item 6c). The companion listener
binds 0.0.0.0:8443, reachable from the whole LAN. From a NON-loopback address:
  * GET /health answers 200 (the listener is up, so a 401 below means auth,
    not a dead port);
  * GET /api/sessions (a data route mounted on :8443, zeroclaw-gateway
    companion_route_table) with NO bearer answers 401;
  * the same with a made-up bearer answers 401;
  * the shipped config states require_pairing = true and a pair rate limit
    above zero in [gateway] (install.sh writes both; the binary's defaults
    are not the shipped config).
Capture JSON: {"source": "lan"|"loopback", "health": int, "unauth": int,
"bogus": int, "config_readable": bool, "require_pairing": str|null,
"pair_rate_limit_per_minute": str|null}
Exit: 0 pass, 1 fail, 78 cannot-run.
"""
import json
import sys

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78


def judge(c):
    lines, fail = [], False

    def check(label, ok):
        nonlocal fail
        lines.append(("  ok     " if ok else "  FAIL   ") + label)
        fail |= not ok

    if c.get("source") != "lan":
        return ["  CANNOT the requests did not come from a non-loopback address (source %r)" % c.get("source")], EX_CANNOT
    if not c.get("health"):
        return ["  CANNOT no HTTP answer from the companion listener"], EX_CANNOT
    if c.get("health") != 200:
        return ["  CANNOT GET /health answered %s, so a refusal below could be a dead listener, not auth" % c.get("health")], EX_CANNOT
    check("an unauthenticated GET /api/sessions on :8443 is refused with 401 (got %s)" % c.get("unauth"), c.get("unauth") == 401)
    check("a made-up bearer on GET /api/sessions is refused with 401 (got %s)" % c.get("bogus"), c.get("bogus") == 401)
    if not c.get("config_readable"):
        lines.append("  CANNOT the shipped assistant config could not be read, so the explicit settings are not measured")
        return lines, EX_FAIL if fail else EX_CANNOT
    check("the shipped config states require_pairing = true (found %r)" % c.get("require_pairing"),
          str(c.get("require_pairing")).strip().lower() == "true")
    rl = str(c.get("pair_rate_limit_per_minute") or "")
    check("the shipped config states a pair rate limit above zero (found %r)" % (rl or None), rl.isdigit() and int(rl) > 0)
    return lines, EX_FAIL if fail else EX_PASS


def self_test():
    ok = True
    good = {"source": "lan", "health": 200, "unauth": 401, "bogus": 401, "config_readable": True,
            "require_pairing": "true", "pair_rate_limit_per_minute": "10"}
    cases = [
        ("401 twice, both settings explicit", good, EX_PASS),
        ("an unauthenticated 200", dict(good, unauth=200), EX_FAIL),
        ("a made-up bearer accepted", dict(good, bogus=200), EX_FAIL),
        ("a 404 is not an auth refusal", dict(good, unauth=404), EX_FAIL),
        ("require_pairing absent from the config", dict(good, require_pairing=None), EX_FAIL),
        ("require_pairing = false", dict(good, require_pairing="false"), EX_FAIL),
        ("pair rate limit 0", dict(good, pair_rate_limit_per_minute="0"), EX_FAIL),
        ("pair rate limit absent", dict(good, pair_rate_limit_per_minute=None), EX_FAIL),
        ("from loopback", dict(good, source="loopback"), EX_CANNOT),
        ("listener down", dict(good, health=0), EX_CANNOT),
        ("config unreadable, auth fine", dict(good, config_readable=False), EX_CANNOT),
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
