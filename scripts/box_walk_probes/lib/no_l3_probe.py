#!/usr/bin/env python3
# lib/no_l3_probe.py -- the JUDGE for probes/no_l3_in_tool_results.sh.
#
#   judge <capture.json>   exit 0 PASS, 1 FAIL (an L3 marker reached a tool),
#                          78 CANNOT_RUN (seed incomplete, or no L2 control)
#   --self-test            known cases through the SAME judge; exit 0 only if
#                          every case lands on its expected verdict
#
# The L3 marker must be absent from every tool response. The L2 twin marker must
# appear in at least one response, or the probe cannot tell "nothing surfaced"
# from "the reader is broken", and it says CANNOT_RUN rather than PASS.
import json, sys

PASS, FAIL, CANNOT = 0, 1, 78


# The window the ruling needs (ORM, from Archie). Each must be a CAPTURED path,
# never a "not_yet" one: a not-yet path is CANNOT-RUN, not PASS.
PATHS = ("timeline", "brief_catchup", "reply_debt")


def judge(cap, out=sys.stdout):
    if "error" in cap:
        print(f"  CANNOT {cap['error']}", file=out)
        return CANNOT
    m3, m2 = cap["markers"]["l3"], cap["markers"]["l2"]
    m0 = cap["markers"].get("l0")
    paths = cap.get("paths", {})
    for name in PATHS:
        p = paths.get(name)
        if p is None or p.get("status") != "captured":
            print(f"  CANNOT path {name} not captured (status={(p or {}).get('status', 'absent')}); not a pass", file=out)
            return CANNOT
    if m0 is None:
        print("  CANNOT no L0 marker in the capture; the L0 item was not seeded", file=out)
        return CANNOT
    for name in PATHS:
        text = paths[name].get("text", "")
        for lvl, mk in (("L0", m0), ("L3", m3)):
            if mk in text:
                print(f"  FAIL path {name} returned the {lvl} marker", file=out)
                return FAIL
    seeds = cap.get("seeds", {})
    # Teardown first: the seeded rows must be present before the delete (the
    # positive control) and gone after it. Residue is CANNOT, never a pass.
    for name in ("l3", "l2"):
        t = cap.get("teardown", {}).get(name, {})
        if not t.get("parsed"):
            print(f"  CANNOT teardown {name} produced no counts", file=out)
            return CANNOT
        before = t["before_qdrant"] + t["before_graph"]
        after = t["after_qdrant"] + t["after_graph"]
        if before == 0:
            print(f"  CANNOT teardown {name}: no seeded rows before the delete (positive control failed)", file=out)
            return CANNOT
        if after != 0:
            print(f"  CANNOT teardown {name}: residue remains after delete (qdrant={t['after_qdrant']} graph={t['after_graph']})", file=out)
            return CANNOT
        print(f"  ok teardown {name}: before {before} -> after 0", file=out)
    for name in ("l3", "l2"):
        s = seeds.get(name, {})
        if s.get("cli_rc") != 0 or s.get("bundle") != "present":
            print(f"  CANNOT seed {name} did not complete (rc={s.get('cli_rc')}, bundle={s.get('bundle')})", file=out)
            return CANNOT
    tools = cap.get("tools", {})
    examined, leaks, control = [], [], False
    for tool, res in sorted(tools.items()):
        if "error" in res or res.get("status") != 200:
            why = res.get("error") or f"status={res.get('status')}"
            print(f"  CANNOT {tool} not examined: {why}", file=out)
            continue
        text = res.get("text", "")
        examined.append(tool)
        if m3 in text:
            leaks.append(tool)
            print(f"  FAIL {tool} returned the L3 marker", file=out)
        else:
            print(f"  ok {tool} no L3 marker ({len(text)} bytes)", file=out)
        if m2 in text:
            control = True
    if not examined:
        print("  CANNOT no tool response was examined", file=out)
        return CANNOT
    if not control:
        print("  CANNOT the L2 twin marker surfaced nowhere; without the control an L3 result cannot be judged", file=out)
        return CANNOT
    if leaks:
        return FAIL
    print(f"  ok L2 control surfaced; {len(examined)} tool responses examined", file=out)
    return PASS


def _case(seeds, tools, m2_in_tool, m3_in_tool):
    m3, m2 = "ZEPHYR1", "QUARTZ1"  # the L0 marker lives in the markers dict
    ok = {"status": 200, "text": "[]"}
    t = {k: dict(ok) for k in ("pwg_decisions", "pwg_topics", "pwg_commitments",
                               "pwg_preferences", "pwg_overview", "pwg_derived_preferences",
                               "pwg_knowledge_search")}
    if tools is not None:
        t = tools
    if m2_in_tool:  # the L2 control surfaces in topics
        t["pwg_topics"] = {"status": 200, "text": '{"topics":[{"label":"' + m2 + '"}]}'}
    if m3_in_tool:  # the leak is in commitments
        t["pwg_commitments"] = {"status": 200, "text": '{"commitments":[{"action":"' + m3 + '"}]}'}
    good = {"cli_rc": 0, "bundle": "present"}
    ok_td = {"parsed": True, "before_qdrant": 2, "before_graph": 3,
             "after_qdrant": 0, "after_graph": 0}
    clean_path = {"status": "captured", "text": "L2 only"}
    return {"markers": {"l3": m3, "l2": m2, "l0": "ZETA1"},
            "seeds": seeds if seeds is not None else {"l3": good, "l2": good},
            "teardown": {"l3": dict(ok_td), "l2": dict(ok_td)},
            "paths": {k: dict(clean_path) for k in PATHS},
            "tools": t}


def _paths(text_by_path=None, status="captured"):
    base = {"timeline": "", "brief_catchup": "", "reply_debt": ""}
    if text_by_path:
        base.update(text_by_path)
    return {k: {"status": status, "text": v} for k, v in base.items()}


def _cap_with_paths(paths, l0="ZETA0"):
    """A full capture: an L2 control in topics, no tool leak, teardown clean."""
    cap = _case(None, None, True, False)
    cap["markers"]["l0"] = l0
    cap["paths"] = paths
    cap["teardown"] = {"l3": {"parsed": True, "before_qdrant": 2, "before_graph": 3, "after_qdrant": 0, "after_graph": 0},
                       "l2": {"parsed": True, "before_qdrant": 2, "before_graph": 3, "after_qdrant": 0, "after_graph": 0}}
    return cap


def _with_td(td):
    cap = _case(None, None, True, False)
    cap["teardown"] = {"l3": dict(td), "l2": dict(td)}
    return cap


def self_test():
    import io
    cases = [
        # (name, capture, expected)
        ("known-bad: L3 marker in commitments", _case(None, None, True, True), FAIL),
        ("clean: L2 surfaces, L3 absent", _case(None, None, True, False), PASS),
        ("no L2 control anywhere", _case(None, None, False, False), CANNOT),
        ("L3 leak but no L2 twin: CANNOT, never FAIL", _case(None, None, False, True), CANNOT),
        ("seed incomplete", _case({"l3": {"cli_rc": 1, "bundle": "absent"},
                                   "l2": {"cli_rc": 0, "bundle": "present"}}, None, True, False), CANNOT),
        ("teardown: no rows before delete (positive control)", _with_td(
            {"parsed": True, "before_qdrant": 0, "before_graph": 0, "after_qdrant": 0, "after_graph": 0}), CANNOT),
        ("teardown: residue after delete", _with_td(
            {"parsed": True, "before_qdrant": 2, "before_graph": 3, "after_qdrant": 1, "after_graph": 0}), CANNOT),
        ("teardown: no counts parsed", _with_td({"parsed": False}), CANNOT),
        ("box refused: owner id unset", {"error": "OSTLER_NO_L3_OWNER_ID is unset"}, CANNOT),
        ("L0/L3 window: paths not yet captured -> CANNOT, never PASS",
         _cap_with_paths(_paths(status="not_yet")), CANNOT),
        ("L0/L3 window: one path not captured -> CANNOT",
         _cap_with_paths({**_paths(), "reply_debt": {"status": "not_yet"}}), CANNOT),
        ("L0/L3 window: clean on all three paths -> PASS",
         _cap_with_paths(_paths({"timeline": "L2 only", "brief_catchup": "L2 only", "reply_debt": "L2 only"})), PASS),
        ("L0 marker in the timeline path -> FAIL",
         _cap_with_paths(_paths({"timeline": "ZETA0 leaked"})), FAIL),
        ("L0 marker in the brief (catchup) path -> FAIL",
         _cap_with_paths(_paths({"brief_catchup": "ZETA0 leaked"})), FAIL),
        ("L0 marker in the reply-debt path -> FAIL",
         _cap_with_paths(_paths({"reply_debt": "ZETA0 leaked"})), FAIL),
        ("L3 seed absent on a path -> CANNOT, never PASS (absent is not withheld)",
         _cap_with_paths({**_paths(), "reply_debt": {"status": "l3_seed_absent", "text": "L2 only"}}), CANNOT),
        ("L3 marker in the timeline path -> FAIL",
         _cap_with_paths(_paths({"timeline": "ZEPHYR1 leaked"})), FAIL),
        ("L3 marker in the brief (catchup) path -> FAIL",
         _cap_with_paths(_paths({"brief_catchup": "ZEPHYR1 leaked"})), FAIL),
        ("L3 marker in the reply-debt path -> FAIL",
         _cap_with_paths(_paths({"reply_debt": "ZEPHYR1 leaked"})), FAIL),
        ("path with a control_silent status -> CANNOT, never PASS",
         _cap_with_paths({**_paths(), "timeline": {"status": "control_silent", "text": "x"}}), CANNOT),
        ("no L0 marker in the capture -> CANNOT (the L0 item was not seeded)",
         {**_cap_with_paths(_paths(), l0=None), "markers": {"l3": "ZEPHYR1", "l2": "QUARTZ1"}}, CANNOT),
        ("every tool errored", _case(None, {k: {"error": "refused"} for k in (
            "pwg_decisions", "pwg_topics", "pwg_commitments", "pwg_preferences",
            "pwg_overview", "pwg_derived_preferences", "pwg_knowledge_search")}, False, False), CANNOT),
    ]
    bad = []
    for name, cap, want in cases:
        got = judge(cap, out=io.StringIO())
        if got != want:
            bad.append(f"{name}: wanted {want}, got {got}")
    for b in bad:
        print("SELF-TEST CASE WRONG: " + b, file=sys.stderr)
    return 0 if not bad else 1


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "--self-test":
        sys.exit(self_test())
    if len(sys.argv) >= 3 and sys.argv[1] == "judge":
        with open(sys.argv[2], encoding="utf-8") as fh:
            sys.exit(judge(json.load(fh)))
    print("usage: no_l3_probe.py judge <capture.json> | --self-test", file=sys.stderr)
    sys.exit(2)
