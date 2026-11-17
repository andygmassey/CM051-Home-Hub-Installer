#!/usr/bin/env python3
"""tool_call log line (ostler-assistant #749): collector (runs ON the box) and judge.

#749 adds one INFO line per tool call on target `tool_call`, message "tool call",
with exactly three fields: tool, outcome (ok | error | denied), duration_ms. No
arguments, results or error text. Sink: ~/.ostler/logs/ostler-assistant.err.

THE DENOMINATOR is a second instrument in the same log: every settled turn logs
`turn_latency: assistant turn settled ... tool_calls=<n>`. The sum of those n is
how many tool calls the daemon says it made. Each needs a tool_call line.

collect  prints KEY=VALUE counts only. It never prints a field VALUE from a
         tool_call line (a leak there is exactly what the probe hunts), only key
         NAMES that are identifiers, and counts.
judge    0 PASS, 1 FAIL, 78 CANNOT-RUN, with one reason line.

Usage: tool_call_log.py collect <log> [since-iso] | judge <capture> | --self-test
"""
import re
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*m")
TS = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z)\s")
TC = re.compile(r"\sINFO\s+tool_call:\s+tool call(?P<rest>.*)$")
TL = re.compile(r"\sINFO\s+turn_latency:\s+assistant turn settled\b(?P<rest>.*)$")
KV = re.compile(r'\s([A-Za-z_][A-Za-z0-9_]*)=("(?:[^"\\]|\\.)*"|\S*)')
ALLOWED = ("tool", "outcome", "duration_ms")
OUTCOMES = ("ok", "error", "denied")
TOOL_OK = re.compile(r"^[A-Za-z0-9_.:-]{1,64}$")


def collect(lines, since=None):
    tl_turns = tl_sum = tl_bad = 0
    tc = bad = 0
    extra = set()
    outcomes = {o: 0 for o in OUTCOMES}
    tools = set()
    for raw in lines:
        line = ANSI.sub("", raw.rstrip("\n"))
        m = TS.match(line)
        if since and (not m or m.group(1) < since):
            continue
        t = TL.search(line)
        if t:
            tl_turns += 1
            kv = dict(KV.findall(" " + t.group("rest")))
            n = kv.get("tool_calls", "")
            if n.isdigit():
                tl_sum += int(n)
            else:
                tl_bad += 1
            continue
        c = TC.search(line)
        if not c:
            continue
        tc += 1
        pairs = KV.findall(" " + c.group("rest"))
        leftover = KV.sub("", " " + c.group("rest")).strip()
        keys = [k for k, _ in pairs]
        kv = {k: v.strip('"') for k, v in pairs}
        ok = sorted(keys) == sorted(ALLOWED) and not leftover
        for k in keys:
            if k not in ALLOWED:
                extra.add(k)
        if kv.get("outcome") in OUTCOMES:
            outcomes[kv["outcome"]] += 1
        else:
            ok = False
        if not kv.get("duration_ms", "").isdigit():
            ok = False
        if TOOL_OK.match(kv.get("tool", "")):
            tools.add(kv["tool"])
        else:
            ok = False
        if not ok:
            bad += 1
    out = ["COLLECTED=1", "TL_TURNS=%d" % tl_turns, "TL_TOOL_CALLS=%d" % tl_sum, "TL_UNPARSED=%d" % tl_bad,
           "TC_LINES=%d" % tc, "TC_MALFORMED=%d" % bad, "TC_EXTRA_KEYS=%s" % ",".join(sorted(extra)),
           "TC_TOOLS_DISTINCT=%d" % len(tools)]
    out += ["TC_OUTCOME_%s=%d" % (o.upper(), outcomes[o]) for o in OUTCOMES]
    return out


def judge(cap):
    if cap.get("COLLECTED") != "1":
        return 78, "the collector printed nothing (log missing, unreadable, or transport failure): %s" % cap.get("ERROR", "no COLLECTED line")
    try:
        turns, tl, tc, bad = (int(cap[k]) for k in ("TL_TURNS", "TL_TOOL_CALLS", "TC_LINES", "TC_MALFORMED"))
    except (KeyError, ValueError):
        return 78, "the capture is missing a count line"
    if bad or cap.get("TC_EXTRA_KEYS"):
        return 1, "%d of %d tool_call lines are not exactly tool/outcome/duration_ms (extra keys: %s); arguments or results may be reaching the log" % (bad, tc, cap.get("TC_EXTRA_KEYS") or "none")
    if turns == 0:
        return 78, "no settled turn (turn_latency) in the window: run the chat probes first; nothing to count against"
    if tl == 0:
        return 78, "%d settled turns, none called a tool: the denominator is 0, so absence of tool_call lines proves nothing" % turns
    if tc == 0:
        return 1, "the daemon made %d tool calls over %d turns and logged 0 tool_call lines (the pre-#749 shape)" % (tl, turns)
    if tc < tl:
        return 1, "the daemon made %d tool calls over %d turns but logged only %d tool_call lines" % (tl, turns, tc)
    return 0, "%d tool_call lines for %d tool calls over %d turns, every line exactly tool/outcome/duration_ms (%s distinct tools)" % (tc, tl, turns, cap.get("TC_TOOLS_DISTINCT"))


def parse(text):
    d = {}
    for line in text.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            d.setdefault(k, v)
    return d


E = "\x1b[2m"; R = "\x1b[0m"; G = "\x1b[32m"
def _tl(ts, n):
    return "%s%s%s %s INFO%s %sturn_latency%s%s:%s assistant turn settled turn_id=t1 outcome=ok total_ms=900 tool_calls=%d tools=pwg_topics:4:ok\n" % (E, ts, R, G, R, E, R, E, R, n)
def _tc(ts, extra=""):
    return "%s%s%s %s INFO%s %stool_call%s%s:%s tool call tool=pwg_topics outcome=\"ok\" duration_ms=4%s\n" % (E, ts, R, G, R, E, R, E, R, extra)

T1, T2 = "2026-11-18T01:00:00.1Z", "2026-11-18T01:00:01.2Z"
LOGS = [
    ("one call, one well-formed line", [_tl(T1, 1), _tc(T2)], 0),
    ("132 shape: calls made, no tool_call line", [_tl(T1, 2), _tl(T2, 1)], 1),
    ("fewer lines than calls", [_tl(T1, 3), _tc(T2)], 1),
    ("an arguments field leaked", [_tl(T1, 1), _tc(T2, " arguments={\"q\":\"x\"}")], 1),
    ("bad outcome value", [_tl(T1, 1), _tc(T2).replace('"ok"', '"maybe"')], 1),
    ("free text after the fields", [_tl(T1, 1), _tc(T2, " and then some")], 1),
    ("no settled turn", [], 78),
    ("turns but no tool use", [_tl(T1, 0)], 78),
]


def self_test():
    bad = 0
    for name, lines, want in LOGS:
        rc, why = judge(parse("\n".join(collect(lines))))
        ok = rc == want
        bad += 0 if ok else 1
        print("  %s %-46s want=%s got=%s" % ("held  " if ok else "FAILED", name, want, rc))
    rc, _ = judge(parse("\n".join(collect([_tl(T1, 1), _tc(T2)], since="2026-11-18T02:00:00Z"))))
    ok = rc == 78
    bad += 0 if ok else 1
    print("  %s %-46s want=78 got=%s" % ("held  " if ok else "FAILED", "since filter excludes older lines", rc))
    rc, _ = judge({})
    ok = rc == 78
    bad += 0 if ok else 1
    print("  %s %-46s want=78 got=%s" % ("held  " if ok else "FAILED", "empty capture", rc))
    total = len(LOGS) + 2
    print("tool_call_log: %d of %d cases held" % (total - bad, total))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["--self-test"]:
        sys.exit(self_test())
    if a[:1] == ["collect"] and len(a) in (2, 3):
        try:
            with open(a[1], errors="replace") as fh:
                print("\n".join(collect(fh, a[2] if len(a) == 3 else None)))
        except OSError as e:
            print("ERROR=%s" % e.__class__.__name__)
        sys.exit(0)
    if a[:1] == ["judge"] and len(a) == 2:
        with open(a[1]) as fh:
            rc, why = judge(parse(fh.read()))
        print(why)
        sys.exit(rc)
    print(__doc__)
    sys.exit(78)
