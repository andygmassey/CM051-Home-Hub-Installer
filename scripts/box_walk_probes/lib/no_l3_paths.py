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
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import no_l3_probe as J

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
    if name == "timeline":
        va, wa = J.api_arm(p.get("api_text"), m.get("l2"), m.get("l0"), m.get("l3"))
        vb, wb = J.outbound_arm(p.get("reply_text"), m.get("l0"), m.get("l3"))
        word = {J.PASS: "PASS", J.FAIL: "FAIL", J.CANNOT: "CANNOT-RUN"}
        both = "FAIL" if J.FAIL in (va, vb) else "CANNOT-RUN" if J.CANNOT in (va, vb) else "PASS"
        return "  path %-13s %s | API arm %s (%s) | OUTBOUND arm %s (%s) | L3 seed count=%s" % (
            name, both, word[va], wa, word[vb], wb, p.get("l3_seed_count"))
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
    for k in ("free_gb_before", "free_gb_after"):
        if fx.get(k) is None:
            print("  CANNOT %s was not measured (a missing number is never read as 0)" % k, file=out)
            rc = CANNOT
    print("  MBP free: %s GB before, %s GB after; L3 seed counts before any capture: %s" % (
        fx.get("free_gb_before"), fx.get("free_gb_after"), json.dumps(fx.get("l3_seed_counts"))), file=out)
    st = fx.get("stores") or {}
    for k in ("processing", "md", "speaker_feedback", "coach", "bundle_l2", "bundle_l3"):
        v = st.get(k) or {}
        print("  store %-17s before=%s after=%s%s" % (k, v.get("before"), v.get("after"), " (%s)" % v["note"] if v.get("note") else ""), file=out)
        if v.get("after") != 0:
            print("  CANNOT store %s: after-count is not 0" % k, file=out)
            rc = CANNOT
    for k in ("processing", "speaker_feedback", "bundle_l2", "bundle_l3"):
        if not (st.get(k) or {}).get("before"):
            print("  CANNOT store %s: nothing counted before the delete (positive control failed)" % k, file=out)
            rc = CANNOT
    print("  stamp-anywhere on disk: before=%s after=%s %s" % (
        fx.get("disk_before"), fx.get("disk_after"), json.dumps(fx.get("disk_after_paths") or [])[:300]), file=out)
    if fx.get("disk_after") != 0:
        print("  CANNOT this run's stamp is still on disk (or the scan did not run)", file=out)
        rc = CANNOT
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


J_CLEAN_API = json.dumps({"events": [
    {"conversation_id": "ostler-walk-QUARTZ1", "privacy_level": "L2"},
    {"conversation_id": "ostler-walk-ZETA1", "privacy_level": "L0"}]})


def _cap(paths=None, fx=None):
    base = {"markers": {"l0": "ZETA1", "l2": "QUARTZ1", "l3": "ZEPHYR1"},
            "paths": {**{n: {"status": "captured", "control": True, "text": "QUARTZ1 only"} for n in PATHS},
                      "timeline": {"status": "captured", "control": True, "text": "x", "reply_text": "QUARTZ1 only",
                                   "api_text": J_CLEAN_API}},
            "fixture": {"graph_before": 9, "graph_after": 0, "stamp_after": 0, "control_known_live": 50,
                        "free_gb_before": 100.0, "free_gb_after": 100.0, "disk_before": 4, "disk_after": 0,
                        "stores": {"processing": {"before": 2, "after": 0}, "md": {"before": 0, "after": 0, "note": "not written"},
                                   "speaker_feedback": {"before": 1, "after": 0}, "coach": {"before": 0, "after": 0, "note": "db absent"},
                                   "bundle_l2": {"before": 1, "after": 0}, "bundle_l3": {"before": 1, "after": 0}},
                        "reply_debt": {"restored": True, "before_tree": "a", "after_tree": "a"}},
            "teardown": {}}
    for n, v in (paths or {}).items():
        base["paths"][n] = v
    base["fixture"].update(fx or {})
    return base


def _ov(n, **kw):
    """A path override: the timeline carries its two arms, the others carry text."""
    d = {"status": "captured", "control": True, "text": kw.get("text", "QUARTZ1 only")}
    if n == "timeline":
        d["reply_text"] = kw.get("text", "QUARTZ1 only")
        d["api_text"] = J_CLEAN_API
    d.update({k: v for k, v in kw.items() if k != "text"})
    return d


def self_test():
    import io
    cases = []
    for n in PATHS:
        cases.append(("%s L0 leak prints FAIL for that path" % n,
                      _cap({n: _ov(n, text="QUARTZ1 ZETA1")}),
                      "path %-13s FAIL" % n, OK))
        cases.append(("%s L3 leak prints FAIL for that path" % n,
                      _cap({n: _ov(n, text="QUARTZ1 ZEPHYR1")}),
                      "path %-13s FAIL" % n, OK))
        cases.append(("%s control silent prints CANNOT-RUN, not PASS" % n,
                      _cap({n: {"status": "control_silent", "control": False, "text": "nothing"}}),
                      "path %-13s CANNOT-RUN" % n, OK))
        if n != "timeline":
            cases.append(("%s clean with control prints PASS" % n, _cap(), "path %-13s PASS" % n, OK))
        else:
            cases.append(("timeline clean: API arm PASS, outbound arm CANNOT-RUN on box -> CANNOT-RUN",
                          _cap(), "path %-13s CANNOT-RUN | API arm PASS" % n, OK))
    for n in PATHS:
        cases.append(("%s absent L3 seed prints CANNOT-RUN, not PASS" % n,
                      _cap({n: {"status": "l3_seed_absent", "control": False, "l3_seed_count": 0, "text": "QUARTZ1 only"}}),
                      "path %-13s CANNOT-RUN" % n, OK))
    good = {"processing": {"before": 2, "after": 0}, "md": {"before": 0, "after": 0}, "speaker_feedback": {"before": 1, "after": 0},
            "coach": {"before": 0, "after": 0}, "bundle_l2": {"before": 1, "after": 0}, "bundle_l3": {"before": 1, "after": 0}}
    for k in ("bundle_l2", "bundle_l3"):
        cases.append(("a %s bundle left behind -> 78" % k, _cap(fx={"stores": {**good, k: {"before": 1, "after": 1}}}), "CANNOT store %s: after" % k, CANNOT))
        cases.append(("%s bundle never counted -> 78" % k, _cap(fx={"stores": {**good, k: {"before": 0, "after": 0}}}), "CANNOT store %s: nothing counted" % k, CANNOT))
    cases.append(("a store left non-empty (md) -> 78", _cap(fx={"stores": {"processing": {"before": 2, "after": 0}, "md": {"before": 1, "after": 1}, "speaker_feedback": {"before": 1, "after": 0}, "coach": {"before": 0, "after": 0}, "bundle_l2": {"before": 1, "after": 0}, "bundle_l3": {"before": 1, "after": 0}}}), "CANNOT store md", CANNOT))
    cases.append(("processing never counted -> 78", _cap(fx={"stores": {"processing": {"before": 0, "after": 0}, "md": {"before": 0, "after": 0}, "speaker_feedback": {"before": 1, "after": 0}, "coach": {"before": 0, "after": 0}, "bundle_l2": {"before": 1, "after": 0}, "bundle_l3": {"before": 1, "after": 0}}}), "CANNOT store processing", CANNOT))
    cases.append(("a speaker_feedback file left behind -> 78", _cap(fx={"stores": {**good, "speaker_feedback": {"before": 1, "after": 1}}}), "CANNOT store speaker_feedback: after", CANNOT))
    cases.append(("no speaker_feedback file ever counted -> 78", _cap(fx={"stores": {**good, "speaker_feedback": {"before": 0, "after": 0}}}), "CANNOT store speaker_feedback: nothing counted", CANNOT))
    cases.append(("a store with no after key is CANNOT, never 0", _cap(fx={"stores": {**good, "md": {"before": 0}}}), "CANNOT store md: after-count is not 0", CANNOT))
    cases.append(("a None after-count in a store is CANNOT, never 0", _cap(fx={"stores": {**good, "md": {"before": 0, "after": None}}}), "CANNOT store md: after-count is not 0", CANNOT))
    cases.append(("MBP free after missing -> 78, and no 'None' is printed as a number", _cap(fx={"free_gb_after": None}), "CANNOT free_gb_after was not measured", CANNOT))
    cases.append(("stamp still on disk -> 78", _cap(fx={"disk_after": 2}), "CANNOT this run's stamp", CANNOT))
    cases.append(("disk scan never ran -> 78", _cap(fx={"disk_after": None}), "CANNOT this run's stamp", CANNOT))
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
