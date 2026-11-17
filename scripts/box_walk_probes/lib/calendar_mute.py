#!/usr/bin/env python3
"""calendar_mute -- judge: does an owner's calendar mute hide a listed calendar
on every Hub surface that carries events? (backlog T2, v1.0.134)

Three modes, all stdlib only (this file is staged onto the box and run there):

  pick       stdin: GET /api/v1/calendars body + "\\n" + http code.
             Prints ONE JSON line with the http code, degraded flag, listed
             count and TWO listed calendar UUIDs (muted, control). Names are
             never printed: counts and ids only leave the box.

  observe    stdin: GET body + "\\n" + http code, for one surface.
             --surface NAME --seam graph|feed --marker-muted M --marker-control C
             Prints one JSON line: http, degraded, muted, control. The raw body
             stays on the box; only the booleans leave it.

  judge FILE judge a JSONL capture (one observe/not_instrumented line per
             surface and arm). Prints one "  ok|FAIL|CANNOT <surface>" line per
             surface and returns 0 PASS, 1 FAIL, 78 CANNOT-RUN.
             judge --fixture NAME runs a built-in known-bad capture.

  instr      stdin: POST owner-instructions body + code. Prints created=<bool> id=<n>.
  count      stdin: SPARQL SELECT JSON. Prints the integer in ?n.

  --self-test  every judge case must behave as declared; prints CASES <n>.

Verdict rules, per surface (a FAIL anywhere outranks any CANNOT):
  http not 200, or body degraded           -> CANNOT (that surface)
  muted event present with the rule on    -> FAIL   (a leak is a leak)
  control event absent with the rule on   -> CANNOT (blind: nothing to see)
  muted event absent with the rule off    -> CANNOT (blind: nothing to hide)
  control absent with the rule off        -> CANNOT (blind)
  surface missing or not_instrumented     -> CANNOT (a surface not read is not clean)
  otherwise                               -> ok
"""
import json
import re
import sys

PASS_RC = 0
FAIL_RC = 1
CANNOT_RC = 78

SURFACES = ("calendar", "calendar_today", "meeting_upcoming",
            "timeline", "person_timeline", "meeting_prep")

# seam: "feed" surfaces read the live iCloud/Google feed (ical-query.sh or gws);
# the probe has no way to put a synthetic event into that feed, so they can only
# ever be blind. "graph" surfaces read pwg:Meeting nodes, which the probe seeds.
SEAM = {
    "calendar": "feed",
    "calendar_today": "feed",
    "meeting_upcoming": "feed",
    "timeline": "graph",
    "person_timeline": "graph",
    "meeting_prep": "feed",
}

_UUID = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")


def _split_http(raw):
    """curl -w '\\n%{http_code}': the body, then the code on the last line."""
    body, sep, code = raw.rpartition("\n")
    if not sep:
        return "", 0
    try:
        return body, int(code.strip())
    except ValueError:
        return body, 0


def _parse(body):
    try:
        return json.loads(body) if body.strip() else None
    except ValueError:
        return None


def cmd_pick(raw):
    body, code = _split_http(raw)
    data = _parse(body)
    out = {"http": code, "degraded": False, "listed": 0,
           "muted_uuid": "", "control_uuid": ""}
    if not isinstance(data, dict):
        out["degraded"] = True
        out["reason"] = "unparseable"
    elif data.get("degraded") or code != 200:
        out["degraded"] = True
        out["reason"] = str(data.get("reason") or "")[:80]
    else:
        seen = []
        for c in data.get("calendars") or []:
            u = str((c or {}).get("uuid") or "").strip()
            if _UUID.match(u) and u.lower() not in [s.lower() for s in seen]:
                seen.append(u)
        out["listed"] = len(seen)
        if len(seen) >= 2:
            out["muted_uuid"], out["control_uuid"] = seen[0], seen[1]
    print(json.dumps(out, sort_keys=True))
    return 0


def cmd_observe(raw, surface, seam, marker_muted, marker_control):
    body, code = _split_http(raw)
    data = _parse(body)
    degraded = code != 200 or not isinstance(data, dict) or data.get("degraded") is True
    print(json.dumps({
        "surface": surface, "seam": seam, "arm": "",
        "http": code, "degraded": bool(degraded),
        "muted": bool(marker_muted) and marker_muted in body,
        "control": bool(marker_control) and marker_control in body,
        "bytes": len(body),
    }, sort_keys=True))
    return 0


def cmd_instr(raw):
    """POST /api/v1/owner-instructions answer -> created=<bool> id=<n>, or an error."""
    body, code = _split_http(raw)
    data = _parse(body)
    if code == 200 and isinstance(data, dict) and data.get("ok") and isinstance(data.get("instruction"), dict):
        print("created=%s id=%s" % ("True" if data.get("created") else "False", data["instruction"].get("id")))
        return 0
    why = ""
    if isinstance(data, dict):
        why = str(data.get("error") or data.get("reason") or "")[:80]
    print("error http=%s %s" % (code, why))
    return 0


def cmd_count(raw):
    data = _parse(raw) or {}
    try:
        print(int(data["results"]["bindings"][0]["n"]["value"]))
        return 0
    except (KeyError, IndexError, TypeError, ValueError):
        print("UNREADABLE")
        return CANNOT_RC


def judge_surface(name, arms):
    """arms: {"off": obs|None, "on": obs|None, "not_instrumented": str|None}.
    Returns (level, text). level is "ok", "FAIL" or "CANNOT"."""
    if arms.get("not_instrumented"):
        return "CANNOT", "%s: NOT INSTRUMENTED -- %s" % (name, arms["not_instrumented"])
    off, on = arms.get("off"), arms.get("on")
    if off is None or on is None:
        return "CANNOT", "%s: surface not read in both arms (missing from the capture)" % name
    seam = SEAM.get(name, "unknown")
    for label, obs in (("rule off", off), ("rule on", on)):
        if obs.get("http") != 200:
            return "CANNOT", "%s: HTTP %s with %s (surface not measured)" % (name, obs.get("http"), label)
        if obs.get("degraded"):
            return "CANNOT", "%s: degraded body with %s (surface not measured)" % (name, label)
    if on.get("muted"):
        return "FAIL", "%s: the muted calendar's event is PRESENT with the rule on" % name
    if not on.get("control"):
        return "CANNOT", ("%s: control event absent with the rule on, so this surface is blind "
                          "(seam: %s)" % (name, seam))
    if not off.get("muted"):
        return "CANNOT", ("%s: muted event absent even with the rule off, so nothing was hidden "
                          "and the mute is unproven here (seam: %s)" % (name, seam))
    if not off.get("control"):
        return "CANNOT", "%s: control event absent with the rule off (blind)" % name
    return "ok", ("%s: muted event absent with the rule on, control present in both arms "
                  "(%d bytes on)" % (name, on.get("bytes", 0)))


def judge_capture(rows):
    """rows: list of dicts from the JSONL capture. Returns (rc, lines)."""
    by = {}
    for r in rows:
        s = r.get("surface")
        if not s:
            continue
        ent = by.setdefault(s, {"off": None, "on": None, "not_instrumented": None})
        if r.get("not_instrumented"):
            ent["not_instrumented"] = str(r["not_instrumented"])
        elif r.get("arm") in ("off", "on"):
            ent[r["arm"]] = r
    lines, worst = [], PASS_RC
    for s in SURFACES:
        level, text = judge_surface(s, by.get(s, {"off": None, "on": None, "not_instrumented": None}))
        if level == "FAIL":
            worst = FAIL_RC
        elif level == "CANNOT" and worst == PASS_RC:
            worst = CANNOT_RC
        lines.append("  %s %s" % ("ok" if level == "ok" else level, text))
    unknown = sorted(set(by) - set(SURFACES))
    for s in unknown:
        lines.append("  CANNOT %s: surface name not in the judge's list, so it was not graded" % s)
        if worst == PASS_RC:
            worst = CANNOT_RC
    return worst, lines


def _row(surface, arm, muted, control, http=200, degraded=False):
    return {"surface": surface, "arm": arm, "http": http, "degraded": degraded,
            "muted": muted, "control": control, "bytes": 100, "seam": SEAM.get(surface, "")}


def _full(on_muted=None, on_control=True, off_muted=True, off_control=True, **over):
    """A capture where every surface behaves as the mute should, unless overridden.
    over: {surface: {"on": {...}, "off": {...}}} or {surface: {"not_instrumented": str}}."""
    rows = []
    for s in SURFACES:
        if s in over and over[s].get("not_instrumented"):
            rows.append({"surface": s, "not_instrumented": over[s]["not_instrumented"]})
            continue
        cells = {"off": dict(muted=off_muted, control=off_control),
                 "on": dict(muted=False if on_muted is None else on_muted, control=on_control)}
        for arm in ("off", "on"):
            cell = dict(cells[arm])
            cell.update((over.get(s) or {}).get(arm, {}))
            rows.append(_row(s, arm, cell["muted"], cell["control"],
                             cell.get("http", 200), cell.get("degraded", False)))
    return rows


def _case_list():
    cases = []
    cases.append(("all surfaces hide the mute, control kept", _full(), 0))
    for s in SURFACES:
        if s == "meeting_prep":
            continue
        cases.append(("leak on %s with rule on is FAIL" % s,
                      _full(**{s: {"on": {"muted": True}}}), 1))
    cases.append(("control absent on timeline with rule on is CANNOT",
                  _full(timeline={"on": {"control": False}}), 78))
    cases.append(("HTTP 503 on person_timeline is CANNOT for that surface",
                  _full(person_timeline={"on": {"http": 503}, "off": {"http": 503}}), 78))
    cases.append(("degraded body on calendar is CANNOT",
                  _full(calendar={"on": {"degraded": True}}), 78))
    cases.append(("muted absent with rule off is CANNOT (nothing was hidden)",
                  _full(off_muted=False), 78))
    cases.append(("surface missing from capture is CANNOT, never PASS",
                  [r for r in _full() if r.get("surface") != "calendar"], 78))
    cases.append(("meeting_prep not instrumented is CANNOT, never PASS",
                  _full(meeting_prep={"not_instrumented": "no HTTP route"}), 78))
    cases.append(("a leak outranks a blind surface: FAIL",
                  _full(timeline={"on": {"muted": True}},
                        calendar={"on": {"control": False}}), 1))
    return cases


FIXTURES = {
    # known-bad: the muted meeting shows on the timeline with the rule on
    "leak_timeline": lambda: _full(timeline={"on": {"muted": True}}),
}


def self_test():
    failures = []
    cases = _case_list()
    for name, rows, want in cases:
        got, _ = judge_capture(rows)
        if got != want:
            failures.append("%s: want rc %d got rc %d" % (name, want, got))
    # A judge that skips a surface would pass a leak on it; the per-surface
    # leak cases above are what catch that (see the scratch mutant run).
    if failures:
        for f in failures:
            print("SELF-TEST FAIL: " + f)
        return FAIL_RC
    print("CASES %d" % len(cases))
    print("SELF-TEST OK: %d judge cases behave as declared" % len(cases))
    return PASS_RC


def main(argv):
    if not argv:
        print("usage: calendar_mute.py pick|observe|judge|count|--self-test", file=sys.stderr)
        return CANNOT_RC
    mode = argv[0]
    if mode == "--self-test":
        return self_test()
    if mode == "pick":
        return cmd_pick(sys.stdin.read())
    if mode == "instr":
        return cmd_instr(sys.stdin.read())
    if mode == "count":
        return cmd_count(sys.stdin.read())
    if mode == "observe":
        opts = dict(zip(argv[1::2], argv[2::2]))
        return cmd_observe(sys.stdin.read(), opts.get("--surface", ""), opts.get("--seam", ""),
                           opts.get("--marker-muted", ""), opts.get("--marker-control", ""))
    if mode == "judge":
        if len(argv) >= 3 and argv[1] == "--fixture":
            rows = FIXTURES[argv[2]]()
        else:
            with open(argv[1], encoding="utf-8") as fh:
                rows = [json.loads(line) for line in fh if line.strip()]
        rc, lines = judge_capture(rows)
        print("\n".join(lines))
        return rc
    print("unknown mode " + mode, file=sys.stderr)
    return CANNOT_RC


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
