#!/usr/bin/env python3
"""A wiki compile killed for lack of memory must be a Doctor RED. It was silent.

THE DEFECT, MEASURED ON THE v1.0.125 WALK (2026-11-06)
------------------------------------------------------
The wiki compiler's python was killed by the kernel inside the container VM
(dmesg global_oom, 883 MB anon-rss in the shipped 4 GiB VM). The compile
exited 137. wiki-recompile-tick.sh logged EVERY 137/143 as "exceeded the
timeout and was killed by the watchdog", skipped the publish, and exited.
Nothing a customer could see said anything: the wiki kept serving old pages
and simply stopped updating. Andy refused 125 for launch over it.

WHAT THIS RUNS, END TO END
--------------------------
The REAL tick script, with a stub `docker` (the compile exit code is the
input) and a stub `colima` (the VM kernel log is the input), writes its
marker; then the REAL Doctor rule, diagnostic_rules.check_wiki_health, reads
it. Nothing is mocked between the two: the file the tick writes is the file
the Doctor reads.

The one edit to the tick copy: its LaunchAgent PATH prepend
(/usr/local/bin:/opt/homebrew/bin) is removed, because on any Mac with Docker
or colima installed the real binaries would shadow the stubs (the reason the
older tick tests skip on a dev box). The premise check below proves the edit
applied, so a changed prepend cannot silently re-arm the real binaries.

Every arm has a control that must stay silent, or must name a different
cause: a rule that fires on everything is as useless as one that fires on
nothing.

EXIT CODES   0 all pass   1 a check failed   2 CANNOT-RUN
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
TICK = Path(os.environ.get(
    "WIKI_RECOMPILE_TICK_SH",
    str(REPO / "wiki-recompile" / "bin" / "wiki-recompile-tick.sh"),
))
AGENT = REPO / "vendor" / "doctor" / "agent"
SLOT_LIB = REPO / "lib" / "ostler-ingest-slot.sh"
PREPEND = 'export PATH="/usr/local/bin:/opt/homebrew/bin:${PATH:-/usr/bin:/bin}"'

if not TICK.is_file() or not AGENT.is_dir():
    print(f"CANNOT-RUN: {TICK} or {AGENT} missing. Nothing was checked.", file=sys.stderr)
    raise SystemExit(2)
if shutil.which("bash") is None:
    print("CANNOT-RUN: no bash. Nothing was checked.", file=sys.stderr)
    raise SystemExit(2)

sys.path.insert(0, str(AGENT))
try:
    import diagnostic_rules as dr  # noqa: E402
except Exception as exc:  # noqa: BLE001
    print(f"CANNOT-RUN: could not import the Doctor rules: {exc}", file=sys.stderr)
    raise SystemExit(2)

PASS = 0
FAIL = 0


def ok(msg: str) -> None:
    global PASS
    PASS += 1
    print(f"  ok   {msg}")


def bad(msg: str) -> None:
    global FAIL
    FAIL += 1
    print(f"  FAIL {msg}")


@dataclass
class Svc:
    name: str
    status: str
    status_code: int | None = 200


@dataclass
class Snap:
    services: list = field(default_factory=lambda: [Svc("wiki", "healthy")])
    docker_containers: list = field(default_factory=list)
    docker_error: str | None = None


# A dmesg line in the shape the 125 walk captured: global_oom, python killed.
OOM_LINES = (
    "[  {t:.6f}] oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null),cpuset=/,"
    "mems_allowed=0,global_oom,task_memcg=/docker/abc,task=python,pid=4242,uid=0\n"
    "[  {t:.6f}] Out of memory: Killed process 4242 (python) total-vm:1200000kB, "
    "anon-rss:883000kB, file-rss:0kB, shmem-rss:0kB, UID:0 pgtables:2000kB oom_score_adj:0\n"
)


def stub_dir(tmp: Path, *, base_rc: int, full_rc: int, base_sleep: int = 0,
             dmesg: str | None) -> Path:
    d = tmp / "stubs"
    d.mkdir()
    docker = d / "docker"
    docker.write_text(f"""#!/bin/bash
echo "$@" >> "{tmp}/docker.log"
[ "$1" = "info" ] && exit 0
if [ "$1" = "compose" ] && [ "$4" = "run" ]; then
    case "$*" in
        *OSTLER_WIKI_SKIP_LLM=1*) [ {base_sleep} -gt 0 ] && exec sleep {base_sleep}; exit {base_rc} ;;
        *) exit {full_rc} ;;
    esac
fi
exit 0
""")
    docker.chmod(0o755)
    if dmesg is not None:
        (tmp / "dmesg.txt").write_text(dmesg)
        colima = d / "colima"
        colima.write_text(f"""#!/bin/bash
echo "$@" >> "{tmp}/colima.log"
[ "$1" = "ssh" ] && cat "{tmp}/dmesg.txt"
exit 0
""")
        colima.chmod(0o755)
    return d


def tick_copy(tmp: Path) -> Path | None:
    src = TICK.read_text()
    if src.count(PREPEND) != 1:
        return None
    p = tmp / "tick.sh"
    p.write_text(src.replace(PREPEND, ": # PATH prepend removed by the test", 1))
    return p


def run_tick(tmp: Path, stubs: Path, *, slot_lib: bool, extra: dict | None = None):
    tick = tick_copy(tmp)
    if tick is None:
        return None
    home = tmp / "home"
    (home / ".ostler").mkdir(parents=True)
    ostler = tmp / "ostler"
    ostler.mkdir()
    (ostler / "docker-compose.yml").write_text("services: {}\n")
    env = {
        "HOME": str(home),
        "PATH": f"{stubs}:/usr/bin:/bin",
        "OSTLER_DIR": str(ostler),
        "OSTLER_STATE_DIR": str(tmp / "state"),
        "OSTLER_LOGS": str(tmp / "logs"),
        "OSTLER_RESOURCE_GOVERNOR": "0",
        "WIKI_RUNTIME_WAIT_TRIES": "1",
        "WIKI_RUNTIME_WAIT_INTERVAL": "0",
        "WIKI_OOM_PROBE_SECS": "5",
    }
    if slot_lib:
        env["OSTLER_INGEST_SLOT_LIB"] = str(SLOT_LIB)
    else:
        env["OSTLER_INGEST_SLOT"] = "0"
    env.update(extra or {})
    return subprocess.run(["bash", str(tick)], env=env, capture_output=True,
                          text=True, timeout=120)


def wait_for(path: Path, secs: float = 20.0) -> bool:
    end = time.monotonic() + secs
    while time.monotonic() < end:
        if path.exists():
            return True
        time.sleep(0.1)
    return path.exists()


def doctor(tmp: Path) -> list[dict]:
    os.environ["OSTLER_STATE_DIR"] = str(tmp / "state")
    try:
        return [f for f in dr.check_wiki_health(Snap())]
    finally:
        os.environ.pop("OSTLER_STATE_DIR", None)


def marker(tmp: Path, phase: str) -> Path:
    return tmp / "state" / "wiki-recompile" / f"compile-killed.{phase}.json"


def reds(found: list[dict]) -> list[str]:
    return [f["title"] for f in found if f.get("severity") == "critical"]


def uptime_dmesg(uptime: float, oom_at: float | None) -> str:
    s = f"{uptime:.2f} {uptime * 3:.2f}\n[    0.000000] kernel boot\n"
    if oom_at is not None:
        s += OOM_LINES.format(t=oom_at)
    return s


# ── 1. THE DEFECT: baseline OOM-killed -> RED naming time and memory ──
def test_baseline_oom_kill_is_a_red_naming_memory():
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        stubs = stub_dir(tmp, base_rc=137, full_rc=0, dmesg=uptime_dmesg(5000.0, 4990.0))
        r = run_tick(tmp, stubs, slot_lib=False)
        if r is None:
            bad("premise: the tick's PATH prepend line changed; the stub would be shadowed. Update PREPEND.")
            return
        if r.returncode != 137:
            bad(f"premise: the tick should exit with the compile's 137, got {r.returncode}")
        m = marker(tmp, "baseline")
        if not m.exists():
            bad("the tick wrote NO marker for an OOM-killed baseline compile (the 125 defect: silent)")
            return
        data = json.loads(m.read_text())
        if data.get("cause") == "oom" and data.get("exit") == 137:
            ok("tick recorded baseline exit 137 with cause=oom from the VM kernel log")
        else:
            bad(f"marker has the wrong cause or exit: {data}")
        if "killed by the watchdog" in r.stdout:
            bad("the tick still calls a kernel OOM kill a watchdog timeout")
        else:
            ok("the tick no longer calls an OOM kill a watchdog timeout")
        found = doctor(tmp)
        at = datetime.fromisoformat(data["at"].replace("Z", "+00:00")).astimezone()
        want = f"Your wiki stopped updating at {at.strftime('%H:%M on %-d %b')}: not enough memory"
        if want in reds(found):
            ok(f"Doctor RED: {want!r}")
        else:
            bad(f"Doctor did not raise the RED {want!r}; got {[(f['severity'], f['title']) for f in found]}")


# ── 2. control: the next successful compile clears it ───────────────
def test_success_is_silent_and_clears_a_previous_kill():
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        stubs = stub_dir(tmp, base_rc=0, full_rc=0, dmesg=uptime_dmesg(5000.0, None))
        m = marker(tmp, "baseline")
        m.parent.mkdir(parents=True)
        m.write_text('{"phase": "baseline", "exit": 137, "cause": "oom", "at": "2026-11-06T01:00:00Z"}\n')
        if not reds(doctor(tmp)):
            bad("premise: a planted kill marker raised no RED, so the clear below proves nothing")
            return
        r = run_tick(tmp, stubs, slot_lib=False)
        if r is None:
            bad("premise: PATH prepend line changed")
            return
        if r.returncode == 0 and not m.exists():
            ok("a finished baseline compile removes the stale marker")
        else:
            bad(f"rc={r.returncode}, marker still present={m.exists()}")
        if not reds(doctor(tmp)):
            ok("control: no RED after a successful compile")
        else:
            bad(f"a successful compile still shows {reds(doctor(tmp))}")


# ── 3. control: an ordinary compile error is not a kill ─────────────
def test_ordinary_failure_writes_no_kill_marker():
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        stubs = stub_dir(tmp, base_rc=1, full_rc=0, dmesg=uptime_dmesg(5000.0, 4990.0))
        r = run_tick(tmp, stubs, slot_lib=False)
        if r is None:
            bad("premise: PATH prepend line changed")
            return
        if r.returncode == 1 and not marker(tmp, "baseline").exists():
            ok("control: exit 1 (the compiler's own error) writes no kill marker")
        else:
            bad(f"exit 1 wrote a kill marker or wrong rc {r.returncode}")


# ── 4. the OOM window discriminates: an OLD oom line is not this kill ─
def test_an_old_oom_line_is_not_blamed():
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        stubs = stub_dir(tmp, base_rc=137, full_rc=0, dmesg=uptime_dmesg(500000.0, 10.0))
        r = run_tick(tmp, stubs, slot_lib=False)
        if r is None:
            bad("premise: PATH prepend line changed")
            return
        m = marker(tmp, "baseline")
        data = json.loads(m.read_text()) if m.exists() else {}
        if data.get("cause") == "killed" and data.get("oom_probe") == "none":
            ok("an OOM line from days before the compile is not blamed: cause=killed, probe=none")
        else:
            bad(f"window check did not discriminate: {data}")
        if any(t.endswith(": the update was stopped before it finished") for t in reds(doctor(tmp))):
            ok("Doctor RED names a stop, not memory, when memory cannot be shown")
        else:
            bad(f"wrong Doctor wording: {reds(doctor(tmp))}")


# ── 5. no colima at all: CANNOT-READ is not "no OOM", and not a crash ─
def test_no_colima_reads_as_unread_not_none():
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        stubs = stub_dir(tmp, base_rc=137, full_rc=0, dmesg=None)
        r = run_tick(tmp, stubs, slot_lib=False)
        if r is None:
            bad("premise: PATH prepend line changed")
            return
        m = marker(tmp, "baseline")
        data = json.loads(m.read_text()) if m.exists() else {}
        if data.get("cause") == "killed" and data.get("oom_probe") == "unread":
            ok("no colima: marker says the VM log was UNREAD, cause=killed, still a RED")
        else:
            bad(f"no-colima case wrong: {data}")


# ── 6. the watchdog's own kill is a timeout ─────────────────────────
def test_watchdog_kill_is_a_timeout():
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        stubs = stub_dir(tmp, base_rc=0, full_rc=0, base_sleep=60,
                         dmesg=uptime_dmesg(5000.0, 4990.0))
        r = run_tick(tmp, stubs, slot_lib=False, extra={"WIKI_COMPILE_TIMEOUT": "2"})
        if r is None:
            bad("premise: PATH prepend line changed")
            return
        m = marker(tmp, "baseline")
        data = json.loads(m.read_text()) if m.exists() else {}
        if r.returncode in (137, 143) and data.get("cause") == "timeout":
            ok(f"watchdog kill (exit {r.returncode}) recorded as cause=timeout, even with an OOM line present")
        else:
            bad(f"watchdog case: rc={r.returncode} marker={data}")
        if any(t.endswith(": the update took too long") for t in reds(doctor(tmp))):
            ok("Doctor RED says the update took too long")
        else:
            bad(f"wrong Doctor wording for a timeout: {reds(doctor(tmp))}")


# ── 7. phase 2 (summaries) OOM, both slot arms ──────────────────────
def test_summaries_oom_is_its_own_red_in_both_slot_arms():
    for slot_lib in (True, False):
        arm = "shared slot lib" if slot_lib else "fallback mkdir slot"
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            stubs = stub_dir(tmp, base_rc=0, full_rc=137, dmesg=uptime_dmesg(5000.0, 4999.0))
            r = run_tick(tmp, stubs, slot_lib=slot_lib)
            if r is None:
                bad("premise: PATH prepend line changed")
                return
            m = marker(tmp, "summaries")
            if not wait_for(m):
                bad(f"[{arm}] the detached summaries compile was killed and wrote no marker")
                continue
            time.sleep(0.2)
            data = json.loads(m.read_text())
            if data.get("cause") == "oom" and not marker(tmp, "baseline").exists():
                ok(f"[{arm}] summaries OOM recorded; the baseline that succeeded has no marker")
            else:
                bad(f"[{arm}] summaries marker wrong: {data}")
            if any(t.startswith("Your wiki's summaries stopped updating at ") and t.endswith("not enough memory")
                   for t in reds(doctor(tmp))):
                ok(f"[{arm}] Doctor RED for the summaries")
            else:
                bad(f"[{arm}] no summaries RED: {reds(doctor(tmp))}")


# ── 8. a corrupt or unknown marker is never silence ─────────────────
def test_corrupt_and_unknown_markers_are_not_silent():
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        m = marker(tmp, "baseline")
        m.parent.mkdir(parents=True)
        m.write_text("{ not json")
        found = doctor(tmp)
        warn = [f for f in found if f["severity"] == "warning"
                and f["title"].startswith("Ostler could not check when your wiki last updated")]
        if warn:
            ok("corrupt marker -> a 'could not check' warning, not silence")
        else:
            bad(f"corrupt marker produced {[(f['severity'], f['title']) for f in found]}")
        m.write_text('{"phase": "baseline", "exit": 137, "cause": "cosmic-ray", "at": "2026-11-06T01:00:00Z"}\n')
        r = reds(doctor(tmp))
        if r and r[0].startswith("Your wiki stopped updating at ") and ":" not in r[0].split(" at ", 1)[1][5:]:
            ok("an unknown cause stays unknown: RED with no invented reason")
        else:
            bad(f"unknown cause rendered as {r}")


def main() -> int:
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            print(name)
            try:
                fn()
            except Exception as exc:  # noqa: BLE001
                bad(f"{name} raised {type(exc).__name__}: {exc}")
    print(f"\n=== {PASS} passed / {FAIL} failed ===")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
