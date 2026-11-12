#!/usr/bin/env python3
"""db_key_reaches_every_service grades only a posture marker written after ITS OWN
throwaway launchd job CLONED from the installed email-bundle plist (harness-only;
no product code is touched).

v1.0.129 walk: the harness runs pwg-convo over ssh, which cannot read the login
Keychain, so it wrote disabled/keychain_unavailable over the service's true
marker and the probe FAILed a healthy box. The probe now kickstarts the launchd
job, waits (bounded) for the marker mtime to pass the bootstrap, grades it at
once. The marker is FORCED (the job imports src.ingest), so no marker after a
successful bootstrap is a FAIL; a failed bootstrap, a stale or unparseable
timestamp is CANNOT-RUN. Never PASS by omission.

Arms: A fresh post-job enabled -> PASS; B ssh keychain_unavailable marker only
(mtime predates the job) -> FAIL (job ran, wrote nothing); C no marker -> FAIL;
D stale timestamp -> CANNOT-RUN; E post-job marker saying disabled -> FAIL;
K bootstrap failed -> CANNOT-RUN; I: `import src.ingest` really writes the
marker with no pending work (CANNOT-RUN if the venv lacks deps). H: the box half
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
arm("B ssh keychain_unavailable marker only (not rewritten by the job) -> FAIL, not PASS", verdict(facts(ssh_bad, written_after_kick=False))[0] is False)
arm("B2 ssh marker that says enabled, not rewritten by the job -> FAIL, never graded as PASS", verdict(facts(marker(), written_after_kick=False))[0] is False)
arm("C no marker after a successful bootstrap -> FAIL", verdict(facts(None, written_after_kick=False, prior_marker_age_s=None))[0] is False)
arm("C3 the FAIL row names the job, its exit and its log", all(x in verdict(facts(None, written_after_kick=False, prior_marker_age_s=None, job_exit="1", job_log="Traceback boom"))[1] for x in ("job_exit=1", "Traceback boom", "never wrote")))
arm("D stale marker (age 9999s > wait 9s + slack) -> CANNOT-RUN", verdict(facts(marker(age=9999)))[0] is None)
arm("D2 the stale row prints the age", "age 9999s" in verdict(facts(marker(age=9999)))[1])
arm("E post-kickstart marker saying disabled -> FAIL", verdict(facts(marker(encryption="disabled", backend="plaintext", reason="no_key")))[0] is False)
arm("K bootstrap failed -> CANNOT-RUN", verdict(facts(marker(), attempted=False, error="rc=113"))[0] is None)
arm("U unparseable timestamp -> CANNOT-RUN", verdict(facts(marker(timestamp="yesterday")))[0] is None)
arm("U2 future-dated marker -> CANNOT-RUN", verdict(facts(marker(age=-4000)))[0] is None)
arm("U3 marker that is not a JSON object -> CANNOT-RUN", verdict(facts("garbage"))[0] is None)
arm("C2 the no-marker row prints the wait and the last marker's age", "within the 9s wait" in verdict(facts(ssh_bad, written_after_kick=False))[1] and "5s old" in verdict(facts(ssh_bad, written_after_kick=False))[1])

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
ki, bi = sh.find("launchctl bootstrap"), sh.find("box --token")
arm("S1 the probe bootstraps the launchd job before it runs the box half", 0 <= ki < bi)
arm("S2 the epoch and wait are passed to the box half", "--kick-epoch" in sh and "--kick-wait" in sh)
arm("S3 the probe declares # WALK_WRITES: so promote_order never moves it", re.search(r"^# WALK_WRITES:", sh, re.M) is not None)
arm("S4 the throwaway job is booted out and its files removed", "launchctl bootout" in sh and "walkprobe-dbkey-posture.plist" in sh)

# I: the premise. Importing src.ingest, with no conversation pending, writes the marker.
import subprocess
with tempfile.TemporaryDirectory() as h:
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": h, "OSTLER_HOME": h,
           "OSTLER_DB_KEY": "ab" * 32, "PYTHONPATH": str(ROOT / "vendor")}
    r = subprocess.run([sys.executable, "-c", "import src.ingest"], cwd=str(ROOT / "vendor/cm048_pipeline"), env=env, capture_output=True, text=True)
    mk = Path(h) / "security-posture" / "cm048-ingest.json"
    if r.returncode != 0 and not mk.exists():
        print("  CANNOT-RUN  I import src.ingest writes the marker (import failed: {})".format(r.stderr.strip().splitlines()[-1][:120] if r.stderr.strip() else "no stderr"))
    else:
        arm("I importing src.ingest with nothing pending writes cm048-ingest.json", mk.exists())

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
    arm("M2 without the written-by-the-job check an ssh keychain_unavailable marker is graded as the service's (arm B detects it)", verdict(facts(ssh_bad, written_after_kick=False), m)[0] is False and verdict(facts(ssh_bad, written_after_kick=False), m)[1].startswith("FAIL") is False)
    arm("M2b ...and a pre-job enabled marker PASSES by omission", verdict(facts(marker(), written_after_kick=False), m)[0] is True)
m = mutant('if not k.get("attempted"):', "if False:", "M3")
if m:
    arm("M3 without the bootstrap-performed check an unstarted job's marker is graded (arm K detects it)", verdict(facts(marker(), attempted=False), m)[0] is True)
m = mutant("if mtime > kick_epoch:", "if True:", "M4")
if m:
    with tempfile.TemporaryDirectory() as h:
        d = Path(h) / "security-posture"; d.mkdir(); (d / "cm048-ingest.json").write_text(json.dumps(ssh_bad))
        os.utime(d / "cm048-ingest.json", (900, 900))
        got, _ = m.wait_for_marker_after(950, 1, home=h, now_fn=lambda: 1000.0, sleep_fn=lambda s: None, poll_s=1)
        arm("M4 without the mtime rule the ssh marker is returned (arm H1 detects it)", got is not None)


# ---- P: the throwaway job's launch context is CLONED from the shipped plist ----
import io
import plistlib
import shutil
import stat
import subprocess
import contextlib

CANARY = "CANARY-VALUE-MUST-NOT-PRINT-7731"
SHIPPED_LABEL = "com.creativemachines.ostler.email-bundle"


def make_home(h, env_extra=None, drop=(), interp=True, write=True):
    home = Path(h)
    venv = home / "cm048" / ".venv" / "bin"; venv.mkdir(parents=True, exist_ok=True)
    py = venv / "python3"
    if interp:
        py.write_text("#!/bin/sh\n"); py.chmod(py.stat().st_mode | stat.S_IXUSR)
    env = {"OSTLER_PYTHON": "/x/email/python3", "PWG_CONVO_CMD": str(venv / "pwg-convo"),
           "OSTLER_SOURCE_DIR": "/x/src", "OSTLER_USER_DISPLAY_NAME": CANARY, "OSTLER_USER_ID": "synthetic-user"}
    env.update(env_extra or {})
    for k in drop:
        env.pop(k, None)
    shipped = {"Label": SHIPPED_LABEL, "ProgramArguments": ["/x/ostler-assistant", "run-source", "email-bundle"],
               "StartInterval": 900, "RunAtLoad": True, "WorkingDirectory": str(home), "ProcessType": "Background", "Nice": 5,
               "UserName": "synthetic", "EnvironmentVariables": env}
    la = home / "Library" / "LaunchAgents"; la.mkdir(parents=True, exist_ok=True)
    if write:
        with open(la / (SHIPPED_LABEL + ".plist"), "wb") as fh:
            plistlib.dump(shipped, fh)
    return home, shipped


def run_clone(mod, home):
    out = home / "clone.plist"
    old = os.environ.get("HOME"); os.environ["HOME"] = str(home)
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            mod.clone_main(["--label", "com.ostler.walkprobe.dbkey-posture", "--out", str(out), "--log", str(home / "x.log")])
    finally:
        os.environ["HOME"] = old
    text = buf.getvalue()
    res = json.loads(text.strip().splitlines()[-1][len("RESULT "):])
    clone = plistlib.load(open(out, "rb")) if out.exists() else None
    return res, clone, text


with tempfile.TemporaryDirectory() as h:
    home, shipped = make_home(h)
    res, clone, text = run_clone(dbp, home)
    arm("P1 the clone is built from the installed plist and parity is identical", res["ok"] is True and clone is not None)
    arm("P1b env, UserName, WorkingDirectory, ProcessType are copied verbatim", clone is not None and all(clone.get(k) == shipped.get(k) for k in ("EnvironmentVariables", "UserName", "WorkingDirectory", "ProcessType", "Nice")))
    arm("P1c ONLY Label, ProgramArguments, schedule, logs differ (python -c 'import src.ingest')",
        clone is not None and clone["Label"] != SHIPPED_LABEL and clone["ProgramArguments"][1:] == ["-c", "import src.ingest"]
        and "StartInterval" not in clone and clone["ProgramArguments"][0].endswith("/.venv/bin/python3"))
    arm("P2 parity prints key names and 8-char hashes, never a value", "env:OSTLER_USER_ID" in text and CANARY not in text and re.search(r"shipped=[0-9a-f]{8} clone=[0-9a-f]{8}", text) is not None)
with tempfile.TemporaryDirectory() as h:
    home, shipped = make_home(h, env_extra={"OSTLER_DB_KEY_FILE": "/synthetic/key"})
    res, clone, text = run_clone(dbp, home)
    arm("P3 a key present only in the SHIPPED plist (OSTLER_DB_KEY_FILE) reaches the clone: the context is read, not templated",
        res["ok"] is True and (clone or {}).get("EnvironmentVariables", {}).get("OSTLER_DB_KEY_FILE") == "/synthetic/key" and "env:OSTLER_DB_KEY_FILE" in text)
    # mutant: a builder that ignores the shipped env and uses the template keys only
    m_src = LIB.read_text()
    old = 'env = dict(shipped.get("EnvironmentVariables") or {})'
    if old not in m_src:
        arm("P3m mutation applied", False)
    else:
        with tempfile.TemporaryDirectory() as mh:
            mp = Path(mh) / "m.py"
            mp.write_text(m_src.replace(old, 'env = {k: (shipped.get("EnvironmentVariables") or {}).get(k, "") for k in TEMPLATE_ENV_KEYS}\n    clone_env_override = True', 1)
                          .replace('clone = {k: shipped[k] for k in CLONED_KEYS if k in shipped}', 'clone = {k: shipped[k] for k in CLONED_KEYS if k in shipped}\n    clone["EnvironmentVariables"] = env', 1))
            mm = load(mp, "mutclone")
            r2, c2, t2 = run_clone(mm, home)
            arm("P3m a builder that rebuilds env from the template instead of the shipped plist is REFUSED by the parity check (extra shipped key missing in clone)",
                r2["ok"] is False and "MISMATCH" in t2)
            # and with the parity gate also removed it would pass: proves the gate is what refuses
            mp2 = Path(mh) / "m2.py"
            mp2.write_text(mp.read_text().replace("same = sp == cp", "same = True", 1))
            mm2 = load(mp2, "mutclone2")
            r3, c3, t3 = run_clone(mm2, home)
            arm("P3n ...and with the parity gate removed too the lossy clone is accepted (so the gate is the detector)", r3["ok"] is True and "OSTLER_DB_KEY_FILE" not in (c3 or {}).get("EnvironmentVariables", {}))
with tempfile.TemporaryDirectory() as h:
    home, _ = make_home(h, drop=("OSTLER_USER_ID",))
    res, clone, text = run_clone(dbp, home)
    arm("P4 a shipped plist lacking a template key (OSTLER_USER_ID) -> refused, names the key, no clone written", res["ok"] is False and "OSTLER_USER_ID" in res.get("reason", "") and clone is None)
with tempfile.TemporaryDirectory() as h:
    home, _ = make_home(h, write=False)
    res, clone, _t = run_clone(dbp, home)
    arm("P5 installed plist absent -> refused (CANNOT-RUN), no clone written", res["ok"] is False and "absent" in res.get("reason", "") and clone is None)
with tempfile.TemporaryDirectory() as h:
    home, _ = make_home(h, interp=False)
    res, clone, _t = run_clone(dbp, home)
    arm("P6 the CM048 interpreter missing -> refused", res["ok"] is False and "not executable" in res.get("reason", ""))
tpl = plistlib.loads(re.sub(rb"<!--.*?-->", b"", (ROOT / "vendor/email_source/launchd/com.creativemachines.ostler.email-bundle.plist").read_bytes(), flags=re.S))
arm("P7 TEMPLATE_ENV_KEYS matches the vendored plist template's EnvironmentVariables (drift guard)", sorted(tpl["EnvironmentVariables"]) == sorted(dbp.TEMPLATE_ENV_KEYS))
sh_text = (ROOT / "scripts/box_walk_probes/probes/db_key_reaches_every_service.sh").read_text()
arm("Q PROBE_QUESTION is exactly the shipped-launch-context question", 'PROBE_QUESTION="a process in the shipped email-bundle launch context resolves the DB key"' in sh_text)

# ---- T: the cleanup trap runs on every exit path ----
STUB = r'''
box_run() {
    printf '%s\n----\n' "$1" >> "$STUB_LOG"
    case "$1" in
        "echo ok") echo ok ;;
        *VP=*) printf %s /fake/python3 ;;
        *service_token*) echo tok ;;
        *base64*) : ;;
        *" clone "*) if [ "$STUB_MODE" = refuse ]; then echo '  parity: env:X shipped=aaaaaaaa clone=-  MISMATCH'; echo 'RESULT {"ok": false, "reason": "parity not identical"}'; else echo 'RESULT {"ok": true}'; fi ;;
        *bootstrap*) echo "KICKRC=0 EPOCH=1700000000" ;;
        *" box --token"*) [ "$STUB_MODE" = term ] && kill -TERM $$; echo 'not json' ;;
        *) : ;;
    esac
}
'''


def run_stubbed(mode, strip_trap=False):
    with tempfile.TemporaryDirectory() as t:
        base = Path(t) / "scripts" / "box_walk_probes"
        shutil.copytree(ROOT / "scripts/box_walk_probes/lib", base / "lib")
        shutil.copytree(ROOT / "scripts/box_walk_probes/probes", base / "probes")
        with open(base / "lib/probe.sh", "a") as fh:
            fh.write(STUB)
        probe = base / "probes/db_key_reaches_every_service.sh"
        if strip_trap:
            probe.write_text(probe.read_text().replace("trap '_dbk_cleanup' EXIT", ":"))
        log = Path(t) / "stub.log"
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "STUB_LOG": str(log), "STUB_MODE": mode, "HOME": t}
        r = subprocess.run(["bash", str(probe)], env=env, capture_output=True, text=True, timeout=60)
        txt = log.read_text() if log.exists() else ""
        return r.returncode, txt


def cleaned_after(txt, marker):
    i = txt.rfind(marker)
    tail = txt[i:] if i >= 0 else ""
    return "launchctl bootout" in tail and "rm -f" in tail and "walkprobe-dbkey-posture.plist" in tail


rc, txt = run_stubbed("refuse")
arm("T1 a clone refusal (CANNOT-RUN exit 78) still boots out and deletes the throwaway job", rc == 78 and cleaned_after(txt, " clone "))
rc, txt = run_stubbed("term")
arm("T2 a TERM mid-probe (during the box half) still boots out and deletes the throwaway job", cleaned_after(txt, " box --token"))
rc, txt = run_stubbed("ok")
arm("T3 the normal path also cleans up, and does not bootout before the bootstrap", cleaned_after(txt, " box --token") and txt.find("launchctl bootstrap") >= 0)
rc, txt = run_stubbed("refuse", strip_trap=True)
arm("T4 mutant without the trap: a clone refusal leaves the job behind (so T1 is a real detector)", not cleaned_after(txt, " clone "))

print("{} arm(s) failed".format(len(fails)))
sys.exit(1 if fails else 0)
