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


def judge(cap, out=sys.stdout):
    m3, m2 = cap["markers"]["l3"], cap["markers"]["l2"]
    seeds = cap.get("seeds", {})
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
    m3, m2 = "ZEPHYR1", "QUARTZ1"
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
    return {"markers": {"l3": m3, "l2": m2},
            "seeds": seeds if seeds is not None else {"l3": good, "l2": good},
            "tools": t}


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
