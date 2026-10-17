#!/usr/bin/env python3
"""Judge for probes/apple_music_refresh_runs_under_the_grant.sh (CM051 v1.0.108).

THE QUESTION. The scheduled Apple Music refresh runs the signed helper as a
child of the installer app, launched by launchd. Does macOS answer that read
from the grant the customer gave the installer? That is the TCC attribution
question in docs/APPLE_MUSIC_REFRESH_TCC.md, INFERRED until this probe runs on
a console box. The install arms the refresh and bootstraps the agent, and
RunAtLoad makes the agent read once at bootstrap, so a granted box carries a
state.json with last_status "ok" minutes after install.

Pure: facts JSON in, assertion lines and an exit code out. Counts only.

FACTS (assembled by the probe from the box):
    armed         bool       state/music_refresh/armed exists
    plists        dict       {"run": bool, "apply": bool} LaunchAgent files present
    loaded        dict       {"run": bool, "apply": bool} launchd has the label
    state         dict|null  state/music_refresh/state.json (last_status, refusals,
                             last_run, snapshot_size), null when absent

EXIT  0 PASS   1 FAIL   78 CANNOT-RUN ("TCC: ..." when the install never got the grant)
"""
from __future__ import annotations

import json
import sys

PASS, FAIL, CANNOT = 0, 1, 78


def judge(f: dict) -> tuple[int, list[str]]:
    out: list[str] = []

    def line(kind: str, msg: str) -> None:
        out.append(f"  {kind:<6} {msg}")

    if not f.get("armed"):
        pl = f.get("plists") or {}
        if pl.get("run") or pl.get("apply"):
            line("FAIL", "a music-refresh agent is installed but the refresh is not armed: the agent would exit at once every day (the install arms and schedules together)")
            return FAIL, out
        line("CANNOT", "TCC: the install's own Apple Music read did not succeed (Media & Apple Music not granted, or no library), so the refresh was correctly not scheduled; only a console install where the customer clicks Allow can measure this")
        return CANNOT, out
    line("ok", "armed: the install's native read succeeded")

    pl, ld = f.get("plists") or {}, f.get("loaded") or {}
    for key, label in (("run", "com.ostler.music-refresh"), ("apply", "com.ostler.music-refresh-apply")):
        if not pl.get(key):
            line("FAIL", f"{label}.plist is absent although the refresh is armed")
            return FAIL, out
        if ld.get(key) is None:
            line("CANNOT", f"launchd could not be asked about {label} (no GUI session reachable)")
            return CANNOT, out
        if not ld.get(key):
            line("FAIL", f"{label} is not loaded in launchd")
            return FAIL, out
        line("ok", f"{label} is loaded")

    st = f.get("state")
    if not isinstance(st, dict):
        line("FAIL", "armed and loaded but no state.json: the agent has never completed a read (RunAtLoad should have produced one at bootstrap)")
        return FAIL, out
    status = st.get("last_status")
    if status != "ok":
        line("FAIL", f"the scheduled read was refused (last_status {status!r}, {st.get('refusals', '?')} refusal(s) in a row): the grant did NOT carry to the launchd-run app. This is the attribution question; the design must change (docs/APPLE_MUSIC_REFRESH_TCC.md)")
        return FAIL, out
    size = int(st.get("snapshot_size") or 0)
    if size <= 0:
        line("FAIL", "the scheduled read said ok but nothing was recorded (snapshot empty)")
        return FAIL, out
    line("ok", f"the scheduled read succeeded (last_status ok, {size} track(s) recorded, last_run {st.get('last_run')})")
    return PASS, out


_ST_OK = {"last_status": "ok", "refusals": 0, "last_run": "2026-10-15T04:17:00Z", "snapshot_size": 120}
_UP = {"armed": True, "plists": {"run": True, "apply": True}, "loaded": {"run": True, "apply": True}}
_CASES = [
    ("pass", {**_UP, "state": _ST_OK}, PASS, "scheduled read succeeded"),
    ("never armed, nothing installed", {"armed": False, "plists": {}}, CANNOT, "TCC:"),
    ("agent installed but not armed", {"armed": False, "plists": {"run": True}}, FAIL, "not armed"),
    ("armed, run plist missing", {**_UP, "plists": {"run": False, "apply": True}, "state": _ST_OK}, FAIL, "plist is absent"),
    ("armed, agent not loaded", {**_UP, "loaded": {"run": False, "apply": True}, "state": _ST_OK}, FAIL, "not loaded"),
    ("launchd unreachable", {**_UP, "loaded": {"run": None, "apply": None}, "state": _ST_OK}, CANNOT, "could not be asked"),
    ("never ran", {**_UP, "state": None}, FAIL, "never completed a read"),
    ("grant did not carry", {**_UP, "state": {**_ST_OK, "last_status": "unavailable", "refusals": 2}}, FAIL, "did NOT carry"),
    ("ok but recorded nothing", {**_UP, "state": {**_ST_OK, "snapshot_size": 0}}, FAIL, "snapshot empty"),
]


def self_test() -> int:
    """Exit 1 when EVERY case lands on its expected verdict, 0 when any leaked
    (the probe convention: a self-test reports FAIL when its controls behave)."""
    leaked = 0
    for name, facts, want_rc, want_text in _CASES:
        rc, lines = judge(facts)
        text = "\n".join(lines)
        good = rc == want_rc and want_text in text
        print(f"  {'caught' if good else 'LEAKED'}  {name}: rc={rc} want={want_rc}")
        if not good:
            leaked += 1
            print("        | " + text.replace("\n", "\n        | "))
    print(f"self-test: {len(_CASES)} cases, {leaked} leaked")
    return 0 if leaked else 1


def main(argv: list[str]) -> int:
    if argv[:1] == ["--self-test"]:
        return self_test()
    if len(argv) == 2 and argv[0] == "judge":
        with open(argv[1]) as fh:
            facts = json.load(fh)
        rc, lines = judge(facts)
        print("\n".join(lines))
        return rc
    print("usage: apple_music_refresh_probe.py --self-test | judge <facts.json>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
