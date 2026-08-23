#!/usr/bin/env python3
"""A dead wiki must announce itself. Nothing used to.

THE DEFECT, MEASURED 2026-08-23
-------------------------------
v1.0.42 upgrade walk, Mac mini. The wiki was down for about a day. No alert,
no Doctor card, no banner, no log line anywhere claiming otherwise. It was
found only because someone was asked to open the URL.

This was not a bug in a step. It was the ABSENCE of any surface that notices:

  - collect_service_health() probed qdrant, oxigraph, redis, ollama and the
    gateway. Not the wiki.
  - The only mention of port 8044 in the entire vendor/doctor tree was a
    COMMENT.
  - check_container_health ignores a container in `Exited (0)`, correctly for
    most services and wrongly for the customer's front door.
  - The "expected container missing" loop in web_ui.run_local_diagnostics is
    gated on `not is_native_deployment()`, which is FALSE on every customer
    install, so it is dead code in production -- and wiki-site was not in
    EXPECTED_OSTLER_SERVICES anyway.
  - wiki-recompile-tick.sh exits 0 when the container runtime is unreachable,
    so a permanently-down runtime produced a green launchd record forever.

WHY THIS FILE IS THE SHAPE IT IS
--------------------------------
Every assertion has a NEGATIVE control beside it: the same rule, on a healthy
snapshot, must stay SILENT. A rule that fires on everything is as useless as
one that fires on nothing, and only the pair distinguishes them.

The fix-command assertions are not cosmetic. The generic unreachable finding
would have told the customer `docker restart ostler-wiki-site`, which cannot
work while the Linux VM is stopped -- the most common cause. A fix command
that cannot work is worse than none.

EXIT CODES   0 all controls pass   1 a control failed   2 CANNOT-RUN
"""
from __future__ import annotations

import os
import sys
import json
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
AGENT = REPO_ROOT / "vendor" / "doctor" / "agent"

EXIT_OK = 0
EXIT_VIOLATION = 1
EXIT_CANNOT_RUN = 2

if not AGENT.is_dir():
    print(f"CANNOT-RUN: {AGENT} not found", file=sys.stderr)
    print("  Nothing was checked. This is not a passing gate.", file=sys.stderr)
    raise SystemExit(EXIT_CANNOT_RUN)

sys.path.insert(0, str(AGENT))

# web_ui is deliberately NOT imported: it pulls fastapi, which is a runtime
# dependency of the Doctor service and not of this gate. The one web_ui
# assertion below reads the file as text, which is enough to see whether the
# duplicate row is suppressed and keeps the gate runnable with only httpx.
try:
    import status_collector  # noqa: E402
    import diagnostic_rules as dr  # noqa: E402
    import diagnostic_copy as dc  # noqa: E402
except Exception as exc:  # noqa: BLE001
    print(f"CANNOT-RUN: could not import the doctor agent modules: {exc}",
          file=sys.stderr)
    print("  Nothing was checked. This is not a passing gate.", file=sys.stderr)
    raise SystemExit(EXIT_CANNOT_RUN)


# ── minimal fixtures matching the real dataclasses' fields ───────────

@dataclass
class Svc:
    name: str
    status: str
    status_code: int | None = None


@dataclass
class Container:
    name: str
    image: str = "ghcr.io/creativemachines-ai/ostler-wiki-site"
    state: str = "running"
    status: str = "Up 2 hours"
    uptime_seconds: int | None = 7200


@dataclass
class Snap:
    services: list = field(default_factory=list)
    docker_containers: list = field(default_factory=list)
    docker_error: str | None = None


def healthy_snapshot() -> Snap:
    return Snap(
        services=[
            Svc("qdrant", "healthy", 200),
            Svc("oxigraph", "healthy", 200),
            Svc("wiki", "healthy", 200),
        ],
        docker_containers=[Container("ostler-wiki-site")],
    )


PASS = 0
FAIL = 0


def ok(msg: str) -> None:
    global PASS
    PASS += 1
    print(f"  [pass] {msg}")


def bad(msg: str) -> None:
    global FAIL
    FAIL += 1
    print(f"  [FAIL] {msg}")


def titles(findings) -> list[str]:
    return [f["title"] for f in findings]


# ── 1. the probe exists at all ───────────────────────────────────────

def test_wiki_is_probed():
    src = (AGENT / "status_collector.py").read_text()
    # Comments are not code.
    code = "\n".join(
        line.split("#", 1)[0] for line in src.splitlines()
    )
    if '("wiki"' in code and "WIKI_URL" in code:
        ok("collect_service_health probes the wiki")
    else:
        bad("collect_service_health does not probe the wiki -- nothing measures "
            "the one URL the customer is told to open")

    if getattr(status_collector, "WIKI_URL", "").endswith(":8044"):
        ok(f"WIKI_URL defaults to {status_collector.WIKI_URL}")
    else:
        bad(f"WIKI_URL is {getattr(status_collector, 'WIKI_URL', None)!r}, "
            "not the port the installer tells the customer to open")


# ── 2. the rule is registered ────────────────────────────────────────

def test_rule_is_registered():
    names = [f.__name__ for f in dr.ALL_RULES]
    if "check_wiki_health" in names:
        ok(f"check_wiki_health is in ALL_RULES ({len(names)} rules)")
    else:
        bad("check_wiki_health is not in ALL_RULES, so it never runs")


# ── 3. NEGATIVE CONTROL: a healthy wiki says nothing ─────────────────

def test_healthy_wiki_is_silent():
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["OSTLER_STATE_DIR"] = tmp
        found = dr.check_wiki_health(healthy_snapshot())
    if found:
        bad("NEGATIVE CONTROL FAILED: a healthy wiki produced findings "
            f"{titles(found)}. A rule that fires on everything is noise.")
    else:
        ok("negative control: a healthy wiki produces no finding")


# ── 4. THE MEASURED CASE: wiki unreachable ───────────────────────────

def test_unreachable_wiki_is_critical():
    snap = healthy_snapshot()
    snap.services = [Svc("wiki", "unreachable", None)]
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["OSTLER_STATE_DIR"] = tmp
        found = dr.check_wiki_health(snap)
    if not found:
        bad("THE DEFECT IS BACK: the wiki is unreachable and the rule said "
            "nothing. That is the v1.0.42 state exactly.")
        return
    f = found[0]
    if f["severity"] == "critical":
        ok(f"an unreachable wiki is CRITICAL: {f['title']!r}")
    else:
        bad(f"an unreachable wiki is only {f['severity']!r}")
    for key in ("title", "detail", "fix", "fix_command", "risk", "category"):
        if key not in f:
            bad(f"the finding is missing the required key {key!r}")
            return
    ok("the finding carries every field the renderer requires")


# ── 5. the fix command must name the layer that is broken ────────────

def test_engine_down_gets_the_engine_fix_not_a_container_restart():
    snap = healthy_snapshot()
    snap.services = [Svc("wiki", "unreachable", None)]
    snap.docker_containers = []
    snap.docker_error = "Cannot connect to the Docker daemon."
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["OSTLER_STATE_DIR"] = tmp
        found = dr.check_wiki_health(snap)
    if not found:
        bad("engine down + wiki down produced no finding")
        return
    cmd = found[0]["fix_command"]
    if "colima start" in cmd:
        ok("engine-down names the runtime in its fix command")
    else:
        bad(f"engine-down fix command is {cmd!r} -- restarting a container "
            "inside a stopped VM does nothing")
    if "docker start ostler-wiki-site" in cmd or "docker restart" in cmd:
        bad(f"engine-down fix command {cmd!r} leads with a container action "
            "that cannot work while the runtime is stopped")
    else:
        ok("engine-down fix command does not lead with an impossible container action")


def test_stopped_container_is_named():
    snap = healthy_snapshot()
    snap.services = [Svc("wiki", "unreachable", None)]
    # THE CASE NOTHING ELSE CATCHES: check_container_health deliberately
    # ignores `Exited (0)`, so a cleanly stopped wiki left no trace anywhere.
    snap.docker_containers = [
        Container("ostler-wiki-site", state="exited", status="Exited (0) 3 hours ago")
    ]
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["OSTLER_STATE_DIR"] = tmp
        found = dr.check_wiki_health(snap)
    if not found:
        bad("a cleanly-exited wiki container produced no finding -- this is "
            "the case check_container_health deliberately ignores")
        return
    f = found[0]
    if "ostler-wiki-site" in f["fix_command"]:
        ok("a stopped wiki container is named in the fix command")
    else:
        bad(f"stopped-container fix command does not name it: {f['fix_command']!r}")

    # CONTROL on the same predicate: a RUNNING container must not be
    # reported as stopped.
    snap.docker_containers = [Container("ostler-wiki-site", state="running")]
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["OSTLER_STATE_DIR"] = tmp
        found2 = dr.check_wiki_health(snap)
    if found2 and found2[0]["title"] == dc.WIKI_CONTAINER_STOPPED_TITLE:
        bad("a RUNNING wiki container was reported as stopped")
    else:
        ok("control: a running container is not reported as stopped")


def test_unhealthy_wiki_is_a_warning_not_a_critical():
    snap = healthy_snapshot()
    snap.services = [Svc("wiki", "unhealthy", 502)]
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["OSTLER_STATE_DIR"] = tmp
        found = dr.check_wiki_health(snap)
    if not found:
        bad("a wiki returning 502 produced no finding")
        return
    if found[0]["severity"] == "warning" and "502" in found[0]["title"]:
        ok("a wiki that answers with an error is a warning naming the code")
    else:
        bad(f"unexpected finding for a 502: {found[0]['title']!r} "
            f"({found[0]['severity']})")


# ── 6. the refresh-stall streak ──────────────────────────────────────

def _write_stall(tmp: str, consecutive: int, first_seen: str) -> None:
    d = Path(tmp) / "wiki-recompile"
    d.mkdir(parents=True, exist_ok=True)
    (d / "runtime-unready.json").write_text(json.dumps({
        "consecutive": consecutive,
        "first_seen": first_seen,
        "last_seen": first_seen,
    }))


def test_refresh_stall_escalates_and_has_both_controls():
    from datetime import datetime, timedelta, timezone
    long_ago = (datetime.now(tz=timezone.utc) - timedelta(hours=20)).isoformat()
    recent = (datetime.now(tz=timezone.utc) - timedelta(minutes=20)).isoformat()

    # a day-long stall -> critical
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["OSTLER_STATE_DIR"] = tmp
        _write_stall(tmp, 120, long_ago)
        found = dr.check_wiki_health(healthy_snapshot())
    hits = [f for f in found if f["title"] == dc.WIKI_REFRESH_STALLED_TITLE]
    if hits and hits[0]["severity"] == "critical":
        ok("a day-long refresh stall is CRITICAL even while the wiki still serves")
    else:
        bad(f"a 120-tick, 20-hour stall did not produce a critical: {titles(found)}")

    # a single reboot tick -> SILENCE. The other side of the zero.
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["OSTLER_STATE_DIR"] = tmp
        _write_stall(tmp, 1, recent)
        found = dr.check_wiki_health(healthy_snapshot())
    if any(f["title"] == dc.WIKI_REFRESH_STALLED_TITLE for f in found):
        bad("NEGATIVE CONTROL FAILED: one reboot-transient tick raised an "
            "alarm. Every reboot would cry wolf and the card would be ignored.")
    else:
        ok("negative control: a single reboot-transient tick raises nothing")

    # no marker at all -> silence
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["OSTLER_STATE_DIR"] = tmp
        found = dr.check_wiki_health(healthy_snapshot())
    if found:
        bad(f"no stall marker at all still produced findings: {titles(found)}")
    else:
        ok("negative control: no marker means no finding")

    # a corrupt marker must not raise and must not fabricate a verdict
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["OSTLER_STATE_DIR"] = tmp
        d = Path(tmp) / "wiki-recompile"
        d.mkdir(parents=True, exist_ok=True)
        (d / "runtime-unready.json").write_text("{ not json")
        try:
            found = dr.check_wiki_health(healthy_snapshot())
            ok("a corrupt stall marker is survivable and silent"
               if not found else "")
            if found:
                bad(f"a corrupt marker fabricated findings: {titles(found)}")
        except Exception as exc:  # noqa: BLE001
            bad(f"a corrupt stall marker raised {type(exc).__name__}: {exc}")


# ── 7. the tick actually WRITES the streak ───────────────────────────

def test_tick_records_and_clears_the_streak():
    tick = REPO_ROOT / "wiki-recompile" / "bin" / "wiki-recompile-tick.sh"
    if not tick.exists():
        bad(f"{tick} is missing")
        return
    code = "\n".join(l.split("#", 1)[0] for l in tick.read_text().splitlines())
    if "runtime-unready.json" in code:
        ok("the refresh tick writes a runtime-unready marker")
    else:
        bad("the refresh tick does not record its no-ops, so a permanent "
            "outage still looks identical to a reboot transient")
    if "rm -f \"$_wiki_stall_file\"" in code:
        ok("the refresh tick clears the marker on success")
    else:
        bad("nothing clears the marker; a recovered box would alarm forever")
    # The exit code must STAY 0 -- a gate that is red on every reboot stops
    # being read. Assert the decision, not just the marker.
    if "exit 0" in code:
        ok("the tick still exits 0 on a transient, so launchd stays quiet")
    else:
        bad("the tick no longer exits 0 on a runtime transient; every reboot "
            "would record a launchd failure")


# ── 8. no duplicate row with a fix command that cannot work ──────────

def test_generic_unreachable_row_is_not_duplicated_for_the_wiki():
    src = (AGENT / "web_ui.py").read_text()
    code = "\n".join(l.split("#", 1)[0] for l in src.splitlines())
    if 'if svc.name == "wiki":' in code and "continue" in code:
        ok("run_local_diagnostics defers the wiki to check_wiki_health")
    else:
        bad("run_local_diagnostics still emits its generic unreachable row "
            "for the wiki, whose fix command cannot work behind a stopped VM")


# ── 9. Rule 0.9: every string is in the catalogue ────────────────────

def _write_engine_state(tmp: str, **fields) -> None:
    d = Path(tmp) / "engine-supervisor"
    d.mkdir(parents=True, exist_ok=True)
    base = {
        "state": "installed_stopped",
        "detail": "failed to connect to the docker API",
        "last_action": "restarted the daemon; engine still down after 60s",
        "consecutive_failures": 1,
        "last_attempt_epoch": 0,
        "first_seen": "2026-08-23T08:10:00Z",
        "last_seen": "2026-08-23T15:30:00Z",
    }
    base.update(fields)
    (d / "state.json").write_text(json.dumps(base))


def test_engine_stopped_is_reported_with_what_was_tried():
    """THE MEASURED STATE. Engine installed, engine stopped.

    A naive "is a runtime installed" probe reports HEALTHY on this box.
    And a card that reports the outage without saying what was ATTEMPTED
    is a nicer version of the same outage.
    """
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["OSTLER_STATE_DIR"] = tmp
        _write_engine_state(tmp, consecutive_failures=2)
        found = dr.check_wiki_health(healthy_snapshot())
    hits = [f for f in found if f["title"] == dc.ENGINE_STOPPED_TITLE]
    if not hits:
        bad("engine installed-but-stopped produced no finding: "
            f"{titles(found)}. That is the exact walk-box state.")
        return
    f = hits[0]
    if f["severity"] == "critical":
        ok(f"installed-but-stopped is CRITICAL: {f['title']!r}")
    else:
        bad(f"installed-but-stopped is only {f['severity']!r}")
    if "2" in f["detail"] and "restarted" in f["detail"]:
        ok("the finding says how many recoveries were attempted and what the last one was")
    else:
        bad(f"the finding does not report the recovery attempts: {f['detail']!r}")


def test_engine_recovery_exhausted_is_a_distinct_finding():
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["OSTLER_STATE_DIR"] = tmp
        _write_engine_state(tmp, consecutive_failures=9)
        found = dr.check_wiki_health(healthy_snapshot())
    if any(f["title"] == dc.ENGINE_RECOVERY_EXHAUSTED_TITLE for f in found):
        ok("after the attempt budget is spent the finding CHANGES -- 'we tried "
           "and could not' is not the same message as 'we are trying'")
    else:
        bad(f"exhausted recovery did not change the finding: {titles(found)}")


def test_engine_absent_is_a_distinct_finding():
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["OSTLER_STATE_DIR"] = tmp
        _write_engine_state(tmp, state="absent", detail="nothing installed")
        found = dr.check_wiki_health(healthy_snapshot())
    hits = [f for f in found if f["title"] == dc.ENGINE_ABSENT_TITLE]
    if not hits:
        bad(f"engine absent produced no finding: {titles(found)}")
        return
    ok("engine ABSENT is its own finding, separate from engine STOPPED")
    if "restart" not in hits[0]["fix"].lower():
        ok("the absent fix does not offer a restart -- there is nothing to restart")
    else:
        bad(f"the absent fix offers a restart: {hits[0]['fix']!r}")


def test_engine_supervisor_negative_controls():
    # No state file at all -> the supervisor has nothing to report. Silence.
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["OSTLER_STATE_DIR"] = tmp
        found = dr._engine_supervisor_findings()
    if found:
        bad(f"no supervisor state file still produced findings: {titles(found)}")
    else:
        ok("negative control: no supervisor state file means no engine finding")

    # A corrupt file must not raise and must not fabricate a verdict.
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["OSTLER_STATE_DIR"] = tmp
        d = Path(tmp) / "engine-supervisor"
        d.mkdir(parents=True, exist_ok=True)
        (d / "state.json").write_text("{ not json")
        try:
            found = dr._engine_supervisor_findings()
            if found:
                bad(f"a corrupt supervisor state file fabricated {titles(found)}")
            else:
                ok("negative control: a corrupt supervisor state file is silent, "
                   "not an alarm and not a claim of health")
        except Exception as exc:  # noqa: BLE001
            bad(f"a corrupt supervisor state file raised {type(exc).__name__}: {exc}")


def test_supervisor_presence_check_treats_unknown_as_unknown():
    """launchctl unavailable must NOT read as 'not installed'.

    None is not False. A check that cannot ask must not report the answer
    it would have liked.
    """
    if "check_engine_supervisor_present" not in [f.__name__ for f in dr.ALL_RULES]:
        bad("check_engine_supervisor_present is not registered, so nothing "
            "notices when the supervisor itself is missing")
        return
    ok("check_engine_supervisor_present is registered in ALL_RULES")

    real = dr._engine_supervisor_is_scheduled
    try:
        dr._engine_supervisor_is_scheduled = lambda: None
        if dr.check_engine_supervisor_present(healthy_snapshot()):
            bad("an UNKNOWN launchctl answer produced a finding; 'could not "
                "check' must not render as 'not installed'")
        else:
            ok("negative control: an unknown launchctl answer stays silent")
        dr._engine_supervisor_is_scheduled = lambda: False
        if any(f["title"] == dc.ENGINE_SUPERVISOR_MISSING_TITLE
               for f in dr.check_engine_supervisor_present(healthy_snapshot())):
            ok("a genuinely absent supervisor IS reported -- raised while things "
               "still work, which is the only useful time to raise it")
        else:
            bad("an absent supervisor produced no finding")
        dr._engine_supervisor_is_scheduled = lambda: True
        if dr.check_engine_supervisor_present(healthy_snapshot()):
            bad("a PRESENT supervisor was still reported missing")
        else:
            ok("negative control: a present supervisor is silent")
    finally:
        dr._engine_supervisor_is_scheduled = real


def test_copy_constants_exist():
    required = [
        "WIKI_UNREACHABLE_TITLE", "WIKI_UNREACHABLE_DETAIL_FMT",
        "WIKI_UNREACHABLE_FIX", "WIKI_UNREACHABLE_FIX_COMMAND",
        "WIKI_ENGINE_DOWN_TITLE", "WIKI_ENGINE_DOWN_DETAIL",
        "WIKI_ENGINE_DOWN_FIX", "WIKI_ENGINE_DOWN_FIX_COMMAND",
        "WIKI_CONTAINER_STOPPED_TITLE", "WIKI_CONTAINER_STOPPED_DETAIL_FMT",
        "WIKI_CONTAINER_STOPPED_FIX", "WIKI_CONTAINER_STOPPED_FIX_COMMAND_FMT",
        "WIKI_UNHEALTHY_TITLE_FMT", "WIKI_UNHEALTHY_DETAIL_FMT",
        "WIKI_UNHEALTHY_FIX", "WIKI_UNHEALTHY_FIX_COMMAND_FMT",
        "WIKI_REFRESH_STALLED_TITLE", "WIKI_REFRESH_STALLED_DETAIL_FMT",
        "WIKI_REFRESH_STALLED_FIX", "WIKI_REFRESH_STALLED_FIX_COMMAND",
        "ENGINE_STOPPED_TITLE", "ENGINE_STOPPED_DETAIL_FMT",
        "ENGINE_STOPPED_FIX", "ENGINE_STOPPED_FIX_COMMAND",
        "ENGINE_RECOVERY_EXHAUSTED_TITLE", "ENGINE_RECOVERY_EXHAUSTED_DETAIL_FMT",
        "ENGINE_RECOVERY_EXHAUSTED_FIX", "ENGINE_RECOVERY_EXHAUSTED_FIX_COMMAND",
        "ENGINE_ABSENT_TITLE", "ENGINE_ABSENT_DETAIL_FMT",
        "ENGINE_ABSENT_FIX", "ENGINE_ABSENT_FIX_COMMAND",
        "ENGINE_SUPERVISOR_MISSING_TITLE", "ENGINE_SUPERVISOR_MISSING_DETAIL",
        "ENGINE_SUPERVISOR_MISSING_FIX", "ENGINE_SUPERVISOR_MISSING_FIX_COMMAND",
    ]
    missing = [n for n in required if not hasattr(dc, n)]
    if missing:
        bad(f"diagnostic_copy is missing {missing}")
        # No constants means the em-dash check below would pass vacuously.
        # A style check over an empty set is not a style check.
        bad("em-dash check skipped: there are no constants to check, so a "
            "pass here would measure nothing")
        return
    ok(f"all {len(required)} wiki copy constants are in diagnostic_copy")
    # House style, enforced by the catalogue headers.
    for n in required:
        v = getattr(dc, n, "")
        if isinstance(v, str) and "—" in v:
            bad(f"{n} contains an em-dash; the catalogue forbids them")
            return
    ok("no em-dashes in the new catalogue entries")


# ── 10. the rule survives the whole-suite fixture ────────────────────

def test_rule_runs_inside_run_all_rules():
    """The rule must not blow up the engine it is registered in.

    run_all_rules wraps each rule in try/except and turns a crash into a
    warning finding, so a broken rule is SURVIVABLE but not silent. This
    asserts it does not take that path.
    """
    snap = healthy_snapshot()
    snap.services = [Svc("wiki", "unreachable", None)]
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["OSTLER_STATE_DIR"] = tmp
        try:
            found = dr.check_wiki_health(snap)
        except Exception as exc:  # noqa: BLE001
            bad(f"check_wiki_health raised {type(exc).__name__}: {exc}")
            return
    if any(f["title"] == dc.WIKI_UNREACHABLE_TITLE for f in found):
        ok("check_wiki_health emits its finding without raising")
    else:
        bad(f"check_wiki_health produced {titles(found)}")


def main() -> int:
    prev_state = os.environ.get("OSTLER_STATE_DIR")
    try:
        for name, fn in sorted(globals().items()):
            if not (name.startswith("test_") and callable(fn)):
                continue
            # REPORT, do not raise. A traceback out of one check hides every
            # check after it, and the reader gets a stack trace instead of a
            # verdict list -- which is how a partly-red gate reads as a
            # crashed one.
            try:
                fn()
            except Exception as exc:  # noqa: BLE001
                bad(f"{name} raised {type(exc).__name__}: {exc}")
    finally:
        if prev_state is None:
            os.environ.pop("OSTLER_STATE_DIR", None)
        else:
            os.environ["OSTLER_STATE_DIR"] = prev_state
    print()
    print(f"=== {PASS} passed / {FAIL} failed ===")
    return EXIT_VIOLATION if FAIL else EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
