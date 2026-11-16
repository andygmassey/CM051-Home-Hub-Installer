#!/usr/bin/env python3
# lib/no_l3_paths.py -- per-path report and fixture-teardown gate for
# probes/no_l3_in_tool_results.sh. The JUDGE (no_l3_probe.py) is unchanged and
# returns on the FIRST failing path; this prints ALL THREE paths, each with its
# L2 control state, so one leaking path cannot hide another.
#
#   report <capture.json>   prints one line per path plus the teardown lines.
#                           exit 0 = fixture torn down and measured,
#                           78 = it was not (the caller must not say PASS).
#   --self-test             known captures through the SAME report; exit 0 only
#                           if every case lands where expected.
import json, sys

OK, CANNOT = 0, 78
PATHS = ("timeline", "reply_debt", "brief_catchup")


def path_line(name, cap):
    p = cap.get("paths", {}).get(name) or {}
    m = cap.get("markers", {})
    text = p.get("text", "")
    if p.get("status") != "captured":
        return "  path %-13s CANNOT-RUN status=%s L2 control=%s L3 seed count=%s (%s)" % (
            name, p.get("status", "absent"), "silent" if not p.get("control") else "present",
            p.get("l3_seed_count"), str(p.get("error", ""))[:120])
    l0, l3 = (m.get("l0") or "\0") in text, (m.get("l3") or "\0") in text
    verdict = "FAIL" if (l0 or l3) else "PASS"
    return "  path %-13s %s L2 control=present L3 seed count=%s L0=%s L3=%s" % (
        name, verdict, p.get("l3_seed_count"), "PRESENT" if l0 else "absent", "PRESENT" if l3 else "absent")


def report(cap, out=sys.stdout):
    rc = OK
    for name in PATHS:
        print(path_line(name, cap), file=out)
    fx = cap.get("fixture", {})
    gb, ga = fx.get("graph_before"), fx.get("graph_after")
    sa, ctl = fx.get("stamp_after"), fx.get("control_known_live")
    print("  fixture graph rows: before=%s after=%s; stamp-anywhere after=%s; positive control (live rows) =%s; "
          "store total %s -> %s" % (gb, ga, sa, ctl, fx.get("total_before"), fx.get("total_after")), file=out)
    if fx.get("graph_error") or not gb or ga != 0 or sa != 0 or not ctl:
        print("  CANNOT fixture graph teardown not proven (before>0, after=0, stamp-anywhere=0, live control>0 all required)", file=out)
        rc = CANNOT
    print("  MBP free: %s GB before, %s GB after; L3 seed counts before any capture: %s" % (
        fx.get("free_gb_before"), fx.get("free_gb_after"), json.dumps(fx.get("l3_seed_counts"))), file=out)
    rd = fx.get("reply_debt") or {}
    print("  reply_debt dir: tree before=%s after=%s restored=%s producer_overwrote=%s" % (
        rd.get("before_tree"), rd.get("after_tree"), rd.get("restored"), rd.get("producer_overwrote")), file=out)
    if not (rd.get("restored") or rd.get("producer_overwrote")):
        print("  CANNOT reply_debt directory was not restored byte for byte", file=out)
        rc = CANNOT
    for k in ("l3", "l2"):
        t = cap.get("teardown", {}).get(k, {})
        print("  pwg-convo %s teardown: %s" % (k, json.dumps({x: t.get(x) for x in (
            "before_qdrant", "before_graph", "after_qdrant", "after_graph", "files_before", "files_after", "parsed")})), file=out)
    cron = fx.get("brief_copy") or {}
    print("  brief copy: job=%s delete_http=%s still_listed_after=%s" % (
        "set" if cron.get("job") else None, cron.get("deleted"), cron.get("still_listed")), file=out)
    if cron.get("job") and cron.get("still_listed") not in (0,):
        print("  CANNOT the brief copy may still be on the box", file=out)
        rc = CANNOT
    return rc


def _cap(paths=None, fx=None):
    base = {"markers": {"l0": "ZETA1", "l2": "QUARTZ1", "l3": "ZEPHYR1"},
            "paths": {n: {"status": "captured", "control": True, "text": "QUARTZ1 only"} for n in PATHS},
            "fixture": {"graph_before": 9, "graph_after": 0, "stamp_after": 0, "control_known_live": 50,
                        "reply_debt": {"restored": True, "before_tree": "a", "after_tree": "a"}},
            "teardown": {}}
    for n, v in (paths or {}).items():
        base["paths"][n] = v
    base["fixture"].update(fx or {})
    return base


def self_test():
    import io
    cases = []
    for n in PATHS:
        cases.append(("%s L0 leak prints FAIL for that path" % n,
                      _cap({n: {"status": "captured", "control": True, "text": "QUARTZ1 ZETA1"}}),
                      "path %-13s FAIL" % n, OK))
        cases.append(("%s L3 leak prints FAIL for that path" % n,
                      _cap({n: {"status": "captured", "control": True, "text": "QUARTZ1 ZEPHYR1"}}),
                      "path %-13s FAIL" % n, OK))
        cases.append(("%s control silent prints CANNOT-RUN, not PASS" % n,
                      _cap({n: {"status": "control_silent", "control": False, "text": "nothing"}}),
                      "path %-13s CANNOT-RUN" % n, OK))
        cases.append(("%s clean with control prints PASS" % n, _cap(), "path %-13s PASS" % n, OK))
    for n in PATHS:
        cases.append(("%s absent L3 seed prints CANNOT-RUN, not PASS" % n,
                      _cap({n: {"status": "l3_seed_absent", "control": False, "l3_seed_count": 0, "text": "QUARTZ1 only"}}),
                      "path %-13s CANNOT-RUN" % n, OK))
    cases.append(("graph residue after teardown -> 78", _cap(fx={"graph_after": 2}), "CANNOT fixture graph", CANNOT))
    cases.append(("no live control -> 78", _cap(fx={"control_known_live": 0}), "CANNOT fixture graph", CANNOT))
    cases.append(("reply_debt not restored -> 78", _cap(fx={"reply_debt": {"restored": False}}), "CANNOT reply_debt", CANNOT))
    bad = []
    for name, cap, needle, want_rc in cases:
        buf = io.StringIO()
        rc = report(cap, out=buf)
        if needle not in buf.getvalue() or rc != want_rc:
            bad.append("%s: rc=%s needle-found=%s" % (name, rc, needle in buf.getvalue()))
    for b in bad:
        print("SELF-TEST CASE WRONG: " + b, file=sys.stderr)
    return 0 if not bad else 1


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "--self-test":
        sys.exit(self_test())
    if len(sys.argv) >= 3 and sys.argv[1] == "report":
        with open(sys.argv[2], encoding="utf-8") as fh:
            sys.exit(report(json.load(fh)))
    print("usage: no_l3_paths.py report <capture.json> | --self-test", file=sys.stderr)
    sys.exit(2)
