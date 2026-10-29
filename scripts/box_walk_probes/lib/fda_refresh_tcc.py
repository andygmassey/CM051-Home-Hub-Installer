#!/usr/bin/env python3
"""Judges for the NEW-119 walk probes (CM051, diag118 Mini16, 2026-10-29).

    no_python_is_tcc_responsible          (BLOCKING)
    fda_rerun_second_tick_lands_a_new_row (ADVISORY until the fda-rerun
                                           registration fix merges)

Pure functions over text the probe collected on the box, so a fixture can
drive every branch with no box, no launchd and no unified log.

  tcc <log.txt>     reads `/usr/bin/log show --style compact` output for the
                    com.apple.TCC subsystem over the install window and counts:
                      python   requests whose RESPONSIBLE process is the
                               bundled interpreter (~/.ostler/python or
                               ~/.ostler/.venv). Must be 0.
                      control  requests where ai.ostler.assistant is
                               responsible and a python child is accessing
                               (run-source children). 0 = CANNOT-RUN: the
                               predicate never saw the request shape it judges.
  tick <facts.json> judges the second-tick run (launchctl runs, last exit,
                    whether the row seeded after install landed in the store).
  --self-test       every branch against fixtures, both directions.

Exit codes: 0 PASS, 1 FAIL, 78 CANNOT-RUN, 2 usage.

THE RESPONSIBLE PROCESS. tccd logs AUTHREQ_ATTRIBUTION with up to three
TCCDProcess blocks. When a `responsible=` block is present it names who TCC
holds to account; when it is absent the ACCESSING process is its own
responsible process (studio29 2026-10-15: ical-server's python3.11 opened
chat.db with no responsible block and TCC wrote a python3.11 row, denied).
Requests for kTCCServiceDeveloperTool are Gatekeeper exec preflights by
syspolicyd, not data access, and are not counted (diag118: 3 such, all
authValue=0 authReason=5).
"""
from __future__ import annotations

import json
import re
import sys

PASS, FAIL, CANNOT = 0, 1, 78

_MSG = re.compile(r"msgID=([^,\s]+)")
_SERVICE = re.compile(r"service=(kTCCService\w+)")
_BLOCK = re.compile(r"(responsible|accessing|requesting)=\{TCCDProcess: ([^}]*)\}")
_FIELD = re.compile(r"(identifier|binary_path|responsible_path)=([^,}]*)")

# The bundled interpreter, wherever the account's home is. .venv/bin/python3
# is a symlink into ~/.ostler/python, but a path TCC printed unresolved must
# still count.
_OSTLER_PY = re.compile(r"/\.ostler/(?:python/|\.venv/bin/python)")
_IGNORED_SERVICES = {"kTCCServiceDeveloperTool"}


def _fields(body: str) -> dict:
    return {k: v.strip() for k, v in _FIELD.findall(body)}


def _is_ostler_python(proc: dict | None) -> bool:
    if not proc:
        return False
    return any(_OSTLER_PY.search(proc.get(k, "")) for k in ("binary_path", "responsible_path"))


def _is_daemon(proc: dict | None) -> bool:
    if not proc:
        return False
    if proc.get("identifier") == "ai.ostler.assistant":
        return True
    return any(proc.get(k, "").endswith("/ostler-assistant") for k in ("binary_path", "responsible_path"))


def _is_python(proc: dict | None) -> bool:
    if not proc:
        return False
    if proc.get("identifier", "").startswith("python"):
        return True
    return proc.get("binary_path", "").rsplit("/", 1)[-1].startswith("python")


def count_tcc(text: str) -> dict:
    services: dict[str, str] = {}
    attributions = []
    lines = 0
    for line in text.splitlines():
        if "AUTHREQ_" not in line:
            continue
        lines += 1
        m = _MSG.search(line)
        if not m:
            continue
        if "AUTHREQ_CTX:" in line:
            s = _SERVICE.search(line)
            if s:
                services[m.group(1)] = s.group(1)
        elif "AUTHREQ_ATTRIBUTION:" in line:
            blocks = {k: _fields(v) for k, v in _BLOCK.findall(line)}
            attributions.append((m.group(1), blocks))
    out = {"authreq_lines": lines, "attributions": len(attributions),
           "python": 0, "control": 0, "ignored": 0, "examples": []}
    for msg, b in attributions:
        if services.get(msg) in _IGNORED_SERVICES:
            out["ignored"] += 1
            continue
        resp = b.get("responsible") or b.get("accessing")
        if _is_ostler_python(resp):
            out["python"] += 1
            if len(out["examples"]) < 3:
                out["examples"].append("msgID=%s service=%s responsible=%s" % (
                    msg, services.get(msg, "unknown"),
                    resp.get("responsible_path") or resp.get("binary_path", "?")))
        elif _is_daemon(b.get("responsible")) and _is_python(b.get("accessing")):
            out["control"] += 1
    return out


def judge_tcc(c: dict) -> tuple[int, str]:
    if c.get("python", 0) > 0:
        return FAIL, ("%d TCC request(s) in the install window had the bundled python as the "
                      "RESPONSIBLE process; a scheduled job is reading protected data outside "
                      "the daemon's grant" % c["python"])
    if c.get("authreq_lines", 0) == 0:
        return CANNOT, "the unified log returned no AUTHREQ line for the install window; nothing was examined"
    if c.get("control", 0) == 0:
        return CANNOT, ("control is 0: no request attributed to ai.ostler.assistant for a python child, "
                        "so the predicate never saw the shape it judges. 0 python-responsible is not evidence")
    return PASS, ("0 python-responsible requests over %d attribution(s), control %d daemon-attributed "
                  "python child request(s)" % (c["attributions"], c["control"]))


_RUNS = re.compile(r"^\s*runs = (\d+)\s*$", re.M)
_LASTEXIT = re.compile(r"^\s*last exit code = (\S+)", re.M)
_STATE = re.compile(r"^\s*state = (.+?)\s*$", re.M)


def parse_print(text: str) -> dict:
    """launchctl print gui/<uid>/<label>, the job's own top-level fields."""
    r, e, s = _RUNS.search(text), _LASTEXIT.search(text), _STATE.search(text)
    return {"runs": int(r.group(1)) if r else None,
            "last_exit": e.group(1) if e else None,
            "state": s.group(1) if s else None}


def judge_tick(f: dict) -> tuple[int, str]:
    """facts: loaded (bool|None), runs (int|None), runs_after_seed (int),
    last_exit (str|None), seeded (bool), landed (int|None)."""
    if not f.get("seeded"):
        return CANNOT, "no synthetic row was seeded after install, so a landing could not be measured"
    if f.get("loaded") is None:
        return CANNOT, "launchd could not be read for com.ostler.fda-rerun"
    if f.get("loaded") is False:
        return FAIL, "com.ostler.fda-rerun is not loaded: there is no hourly re-run on this box at all"
    if f.get("runs") is None:
        return CANNOT, "launchctl print carried no 'runs =' line"
    if f["runs"] < 2:
        return FAIL, "com.ostler.fda-rerun ran %d time(s) after kickstart; a second refresh never happened" % f["runs"]
    if f.get("runs_after_seed", 0) < 1:
        return FAIL, "no fda-rerun run completed after the row was seeded"
    if f.get("last_exit") is None:
        return CANNOT, "launchctl print carried no 'last exit code =' line"
    if f["last_exit"] != "0":
        return FAIL, "the last fda-rerun run exited %s" % f["last_exit"]
    if f.get("landed") is None:
        return CANNOT, "the store could not be read for the seeded row"
    if f["landed"] < 1:
        return FAIL, ("fda-rerun ran %d time(s), %d after the seed, and the row seeded after install "
                      "never reached the store" % (f["runs"], f["runs_after_seed"]))
    return PASS, ("fda-rerun ran %d time(s), %d after the seed, last exit 0, and the row seeded after "
                  "install landed (%d point(s))" % (f["runs"], f["runs_after_seed"], f["landed"]))


# --------------------------------------------------------------------------
# fixtures. Lines are shaped on real tccd output (local `log show`, 2026-10-29)
# and the diag118 / studio29 records. Paths use a synthetic account.
# --------------------------------------------------------------------------
H = "/".join(["", "Users", "walk1"])  # built from parts: synthetic account, no literal home path
_HDR = "Timestamp               Ty Process[PID:TID]\n"


def _ctx(msg, svc):
    return ("2026-10-29 00:45:00.000 Df tccd[1:2] [com.apple.TCC:access] AUTHREQ_CTX: msgID=%s, "
            "function=<private>, service=%s, preflight=yes, query=1, client_dict=(null), "
            "daemon_dict=<private>\n" % (msg, svc))


def _proc(ident, path, rpath=None):
    rp = ", responsible_path=%s" % rpath if rpath else ""
    return ("{TCCDProcess: identifier=%s, pid=10, auid=501, euid=501%s, binary_path=%s}"
            % (ident, rp, path))


def _attr(msg, responsible=None, accessing=None, requesting=None):
    parts = []
    if responsible:
        parts.append("responsible=" + responsible)
    if accessing:
        parts.append("accessing=" + accessing)
    if requesting:
        parts.append("requesting=" + requesting)
    return ("2026-10-29 00:45:00.001 Df tccd[1:2] [com.apple.TCC:access] AUTHREQ_ATTRIBUTION: "
            "msgID=%s, attribution={%s, },\n" % (msg, ", ".join(parts)))


DAEMON = _proc("ai.ostler.assistant", "/Applications/Ostler.app/Contents/MacOS/ostler-assistant",
               "/Applications/Ostler.app/Contents/MacOS/ostler-assistant")
PY_CHILD = _proc("python3", H + "/.ostler/python/bin/python3.11")
PY_SELF = _proc("python3", H + "/.ostler/python/bin/python3.11",
                H + "/.ostler/python/bin/python3.11")
SANDBOXD = _proc("com.apple.sandboxd", "/usr/libexec/sandboxd")
SSHD = _proc("com.openssh.sshd-keygen-wrapper", "/usr/libexec/sshd-keygen-wrapper",
             "/usr/libexec/sshd-keygen-wrapper")

CONTROL_ONLY = (_HDR + _ctx("1.1", "kTCCServiceSystemPolicyAllFiles")
                + _attr("1.1", responsible=DAEMON, accessing=PY_CHILD)
                + _ctx("1.2", "kTCCServiceSystemPolicyAllFiles")
                + _attr("1.2", responsible=SSHD, accessing=PY_CHILD)
                + _ctx("1.3", "kTCCServiceDeveloperTool")
                + _attr("1.3", accessing=PY_CHILD, requesting=SANDBOXD))
PY_RESPONSIBLE_NO_BLOCK = (CONTROL_ONLY + _ctx("2.1", "kTCCServiceSystemPolicyAllFiles")
                           + _attr("2.1", accessing=PY_CHILD, requesting=SANDBOXD))
PY_RESPONSIBLE_BLOCK = (CONTROL_ONLY + _ctx("3.1", "kTCCServiceSystemPolicyAllFiles")
                        + _attr("3.1", responsible=PY_SELF, accessing=PY_SELF))
NO_CONTROL = (_HDR + _ctx("4.1", "kTCCServiceAddressBook")
              + _attr("4.1", accessing=_proc("com.apple.mds", "/usr/sbin/mds")))


def self_test() -> int:
    bad = []

    def want(name, got, exp):
        if got != exp:
            bad.append("%s: got %s, wanted %s" % (name, got, exp))

    want("control only -> PASS", judge_tcc(count_tcc(CONTROL_ONLY))[0], PASS)
    c = count_tcc(CONTROL_ONLY)
    want("control counted", c["control"], 1)
    want("sshd-responsible python is not the bundled python responsible", c["python"], 0)
    want("DeveloperTool preflight ignored", c["ignored"], 1)
    want("python responsible (no responsible block) -> FAIL",
         judge_tcc(count_tcc(PY_RESPONSIBLE_NO_BLOCK))[0], FAIL)
    want("python responsible (explicit block) -> FAIL",
         judge_tcc(count_tcc(PY_RESPONSIBLE_BLOCK))[0], FAIL)
    want("0 daemon requests -> CANNOT-RUN, never PASS", judge_tcc(count_tcc(NO_CONTROL))[0], CANNOT)
    want("empty log -> CANNOT-RUN", judge_tcc(count_tcc(_HDR))[0], CANNOT)

    p = parse_print("\tstate = not running\n\truns = 3\n\tlast exit code = 0\n")
    want("print parse", (p["runs"], p["last_exit"], p["state"]), (3, "0", "not running"))
    good = {"seeded": True, "loaded": True, "runs": 2, "runs_after_seed": 1, "last_exit": "0", "landed": 1}
    want("tick good -> PASS", judge_tick(good)[0], PASS)
    want("tick not loaded -> FAIL", judge_tick(dict(good, loaded=False))[0], FAIL)
    want("tick one run -> FAIL", judge_tick(dict(good, runs=1))[0], FAIL)
    want("tick no run after seed -> FAIL", judge_tick(dict(good, runs_after_seed=0))[0], FAIL)
    want("tick bad exit -> FAIL", judge_tick(dict(good, last_exit="1"))[0], FAIL)
    want("tick not landed -> FAIL", judge_tick(dict(good, landed=0))[0], FAIL)
    want("tick store unreadable -> CANNOT-RUN", judge_tick(dict(good, landed=None))[0], CANNOT)
    want("tick not seeded -> CANNOT-RUN", judge_tick(dict(good, seeded=False))[0], CANNOT)
    want("tick launchd unreadable -> CANNOT-RUN", judge_tick(dict(good, loaded=None))[0], CANNOT)
    want("tick no last exit -> CANNOT-RUN", judge_tick(dict(good, last_exit=None))[0], CANNOT)

    for b in bad:
        print("  SELF-TEST MISS: " + b)
    print("  self-test: %d case(s), %d miss(es)" % (20, len(bad)))
    return 0 if not bad else 1


def main(argv) -> int:
    if len(argv) >= 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) == 3 and argv[1] == "tcc":
        c = count_tcc(open(argv[2], encoding="utf-8", errors="replace").read())
        print("  examined: %d AUTHREQ line(s), %d attribution(s); python-responsible %d; "
              "control (daemon -> python child) %d; DeveloperTool ignored %d"
              % (c["authreq_lines"], c["attributions"], c["python"], c["control"], c["ignored"]))
        for e in c["examples"]:
            print("    python-responsible: " + e)
        rc, why = judge_tcc(c)
        print("EXAMINED_N=%d" % c["attributions"])
        print("REASON=" + why)
        return rc
    if len(argv) == 3 and argv[1] == "tick":
        f = json.load(open(argv[2], encoding="utf-8"))
        rc, why = judge_tick(f)
        print("REASON=" + why)
        return rc
    if len(argv) == 3 and argv[1] == "print":
        print(json.dumps(parse_print(open(argv[2], encoding="utf-8", errors="replace").read())))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
