#!/usr/bin/env python3
"""db_key_reaches_every_service grades only a posture marker written after ITS OWN
launchd kickstart (harness-only; no product code is touched).

v1.0.129 walk: the harness runs pwg-convo over ssh, which cannot read the login
Keychain, so it wrote disabled/keychain_unavailable over the service's true
marker and the probe FAILed a healthy box. The probe now kickstarts the launchd
job, waits (bounded) for the marker mtime to pass the kickstart, grades it at
once. Absent, unchanged-after-the-wait, unparseable, stale or kickstart-failed
= CANNOT-RUN, never PASS, never FAIL.

Arms: A fresh post-kickstart enabled -> PASS; B ssh keychain_unavailable marker
only (mtime predates kickstart) -> CANNOT-RUN; C no marker -> CANNOT-RUN; D stale
-> CANNOT-RUN; E post-kickstart marker saying disabled -> FAIL. H: the box half
with a real temp state dir and a fake clock. S: the probe script kickstarts BEFORE
it reads and passes the epoch. M: mutants. CM051_ROOT grades another tree.
"""
import importlib.util
import json
import os
import re
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(os.environ.get("CM051_ROOT") or Path(__file__).resolve().parent.parent)
LIB = ROOT / "scripts/box_walk_probes/lib/db_key_probe.py"


def load(path, name):
    sp = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(sp)
    sp.loader.exec_module(m)
    return m


dbp = load(LIB, "dbp")
fails = []


def arm(name, ok):
    print("  {}  {}".format("ok  " if ok else "FAIL", name))
    if not ok:
        fails.append(name)


NOW = 1_800_000_000


def ts(age):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW - age))


def marker(age=20, **kw):
    m = {"encryption": "enabled", "backend": "sqlcipher", "key_source": "keychain", "timestamp": ts(age)}
    m.update(kw)
    return m


def facts(cm, **kick):
    k = {"attempted": True, "label": "com.creativemachines.ostler.email-bundle", "written_after_kick": True,
         "waited_s": 9, "prior_marker_age_s": 5, "now": NOW}
    k.update(kick)
    return {"now": NOW, "kick": k, "posture": {"ical-server": marker(), "cm048-ingest": cm}}


def verdict(f, mod=dbp):
    return {n: (ok, d) for n, ok, d in mod.judge(f)}[mod.DECLARED[1]]


ssh_bad = marker(encryption="disabled", backend="plaintext", reason="keychain_unavailable", key_source=None)
arm("A post-kickstart enabled marker -> PASS", verdict(facts(marker()))[0] is True)
arm("B ssh keychain_unavailable marker only (not rewritten after kickstart) -> CANNOT-RUN", verdict(facts(ssh_bad, written_after_kick=False))[0] is None)
arm("B2 ssh marker that says enabled, not rewritten after kickstart -> not graded", verdict(facts(marker(), written_after_kick=False))[0] is None)
arm("C no marker -> CANNOT-RUN", verdict(facts(None, written_after_kick=False, prior_marker_age_s=None))[0] is None)
arm("D stale marker (age 9999s > wait 9s + slack) -> CANNOT-RUN", verdict(facts(marker(age=9999)))[0] is None)
arm("D2 the stale row prints the age", "age 9999s" in verdict(facts(marker(age=9999)))[1])
arm("E post-kickstart marker saying disabled -> FAIL", verdict(facts(marker(encryption="disabled", backend="plaintext", reason="no_key")))[0] is False)
arm("K kickstart not performed -> CANNOT-RUN", verdict(facts(marker(), attempted=False, error="rc=113"))[0] is None)
arm("U unparseable timestamp -> CANNOT-RUN", verdict(facts(marker(timestamp="yesterday")))[0] is None)
arm("U2 future-dated marker -> CANNOT-RUN", verdict(facts(marker(age=-4000)))[0] is None)
arm("U3 marker that is not a JSON object -> CANNOT-RUN", verdict(facts("garbage"))[0] is None)
arm("C2 the unchanged-after-wait row prints the wait and the last marker's age", "within the 9s wait" in verdict(facts(ssh_bad, written_after_kick=False))[1] and "5s old" in verdict(facts(ssh_bad, written_after_kick=False))[1])

# Box half, real files, fake clock: the mtime rule is what keeps an ssh marker out.
with tempfile.TemporaryDirectory() as h:
    d = Path(h) / "security-posture"; d.mkdir()
    f = d / "cm048-ingest.json"
    f.write_text(json.dumps(ssh_bad))
    clock = [1000.0]
    os.utime(f, (900, 900))
    m, info = dbp.wait_for_marker_after(950, 10, home=h, now_fn=lambda: clock[0], sleep_fn=lambda s: clock.__setitem__(0, clock[0] + s), poll_s=3)
    arm("H1 a marker whose mtime predates the kickstart is never returned; the wait is bounded", m is None and info["written_after_kick"] is False and info["waited_s"] == 10)
    arm("H2 the unchanged marker's age is reported", info["prior_marker_age_s"] is not None)
    # now the 'launchd job' rewrites it mid-wait
    clock[0] = 1000.0
    calls = []

    def sleeper(s):
        clock[0] += s
        calls.append(s)
        if len(calls) == 2:
            f.write_text(json.dumps(marker()))
            os.utime(f, (clock[0], clock[0]))
    m, info = dbp.wait_for_marker_after(950, 30, home=h, now_fn=lambda: clock[0], sleep_fn=sleeper, poll_s=3)
    arm("H3 a marker rewritten after the kickstart is returned immediately, read once it moves", m is not None and m.get("encryption") == "enabled" and info["written_after_kick"] and len(calls) == 2)
    m2, i2 = dbp.wait_for_marker_after(950, 5, home=str(Path(h) / "nope"), now_fn=lambda: clock[0], sleep_fn=lambda s: clock.__setitem__(0, clock[0] + s), poll_s=3)
    arm("H4 no marker dir at all -> None, bounded", m2 is None and i2["prior_marker_age_s"] is None)

# Probe script ordering: kickstart is issued, then its epoch is handed to the box half.
sh = (ROOT / "scripts/box_walk_probes/probes/db_key_reaches_every_service.sh").read_text()
ki, bi = sh.find("launchctl kickstart -k"), sh.find("box --token")
arm("S1 the probe kickstarts the launchd job before it runs the box half", 0 <= ki < bi)
arm("S2 the kickstart epoch and wait are passed to the box half", "--kick-epoch" in sh and "--kick-wait" in sh)

# Mutants: each removed check must let a bad marker through, proving the arm above detects it.
src = LIB.read_text()


def mutant(old, new, name):
    if old not in src:
        arm(name + " (mutation applied)", False)
        return None
    with tempfile.TemporaryDirectory() as h:
        p = Path(h) / "m.py"; p.write_text(src.replace(old, new, 1))
        return load(p, "mut_" + str(abs(hash(name))))


m = mutant("if age > limit:", "if False:", "M1")
if m:
    arm("M1 without the freshness check a stale marker PASSES (arm D detects it)", verdict(facts(marker(age=99999)), m)[0] is True)
m = mutant('if marker is None or not k.get("written_after_kick"):', "if marker is None:", "M2")
if m:
    arm("M2 without the written-after-kickstart check an ssh marker is graded (arm B detects it)", verdict(facts(ssh_bad, written_after_kick=False), m)[0] is False)
    arm("M2b ...and a pre-kickstart enabled marker PASSES by omission", verdict(facts(marker(), written_after_kick=False), m)[0] is True)
m = mutant('if not k.get("attempted"):', "if False:", "M3")
if m:
    arm("M3 without the kickstart-performed check an unkicked read is graded (arm K detects it)", verdict(facts(marker(), attempted=False), m)[0] is True)
m = mutant("if mtime > kick_epoch:", "if True:", "M4")
if m:
    with tempfile.TemporaryDirectory() as h:
        d = Path(h) / "security-posture"; d.mkdir(); (d / "cm048-ingest.json").write_text(json.dumps(ssh_bad))
        os.utime(d / "cm048-ingest.json", (900, 900))
        got, _ = m.wait_for_marker_after(950, 1, home=h, now_fn=lambda: 1000.0, sleep_fn=lambda s: None, poll_s=1)
        arm("M4 without the mtime rule the ssh marker is returned (arm H1 detects it)", got is not None)

print("{} arm(s) failed".format(len(fails)))
sys.exit(1 if fails else 0)
