"""Tests for the wiki-recompile LaunchAgent wrapper script.

Drives ``wiki-recompile-tick.sh`` end-to-end with a stubbed
``docker`` binary so we can exercise the success / failure paths
without a live Docker daemon. Asserts:

- Phase 1: runs a FAST BASELINE compile with
  ``-e OSTLER_WIKI_SKIP_LLM=1`` (skips the multi-hour LLM summary
  pass so people appear in seconds).
- Then publishes via a plain ``docker compose up -d wiki-site`` (no
  --force-recreate): the wiki-site container now runs a static server that
  picks up the finished compile by polling the .compile-complete marker, so
  no container restart is needed. The old force-recreate (#598) was the
  recompile-window 000 and has been removed.
- Phase 2: AFTER publishing, launches a DETACHED full compile
  (``nohup`` + ``disown``, NO ``OSTLER_WIKI_SKIP_LLM``) so the
  summaries backfill -- and does NOT wait on it (the tick returns
  once the baseline is published and the background full is
  launched).
- Surfaces baseline compile failures with a clear message and skips
  both the wiki-site refresh and the background full compile.
- Surfaces ``docker compose up`` failures with a clear message and
  does NOT launch the background full compile.
- Refuses to run silently if the compose file is absent.
- Refuses to run silently if ``docker`` is not on PATH.
- Plist parses as well-formed XML and references the placeholders
  the installer substitutes.
- INSTALL_SNIPPET stages the wrapper, renders the plist, and
  substitutes every placeholder.
"""
from __future__ import annotations

import os
import shutil
import signal
import stat
import subprocess
import time
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[2]
# Overridable so CI can point a single, targeted run at a MUTANT copy of the
# script (e.g. the stall-watchdog disarm stripped back out) without touching
# every other test in this file, which all want the real, shipped script.
# See test_full_compile_survives_past_the_stall_window and the dedicated
# "mutant" CI step in .github/workflows/ingest-slot.yml that proves this
# regression test can actually fail.
WRAPPER = Path(os.environ.get(
    "WIKI_RECOMPILE_TICK_SH",
    str(REPO_ROOT / "wiki-recompile" / "bin" / "wiki-recompile-tick.sh"),
))


def _real_docker_shadows_stub() -> bool:
    """The wrapper hard-prepends ``/usr/local/bin:/opt/homebrew/bin``
    to PATH (LaunchAgent PATH hygiene), so on a developer box with
    Docker Desktop installed a *real* ``docker`` at one of those
    locations is resolved ahead of our test stub -- the stub never
    runs and the assertions can't be exercised. CI has no Docker, so
    the stub wins there. Detect the shadowing case and skip rather
    than fail spuriously on a dev box."""
    for d in ("/usr/local/bin", "/opt/homebrew/bin"):
        if (Path(d) / "docker").exists():
            return True
    return False


def _minimal_path_without_docker(target_dir: Path) -> str:
    """Build ``target_dir`` with symlinks to exactly the binaries the script
    needs before it reaches its own ``command -v docker`` check (bash itself,
    so subprocess can even find the interpreter, plus ``date`` for the
    ``log()`` helper) -- and nothing else -- then return it as a PATH.

    A hardcoded directory list ("/usr/bin:/bin") used to stand in for "no
    docker reachable": true on a Mac, where Docker Desktop's CLI lives at
    /usr/local/bin/docker, but false on ubuntu-latest, which ships Docker
    Engine at /usr/bin/docker. FILTERING directories by "does this one carry
    docker" does not fix that either: Ubuntu's usr-merge makes /bin a symlink
    to /usr/bin, so bash and docker live in the literal same directory --
    excluding the one that carries docker excludes bash with it
    (measured: ``FileNotFoundError: ... 'bash'`` the first time this was
    tried). Cherry-picking exactly the named binaries into a fresh directory
    sidesteps the question of how the host's real directories happen to be
    laid out, on any platform.
    """
    target_dir.mkdir(parents=True, exist_ok=True)
    for name in ("bash", "date"):
        real = shutil.which(name)
        assert real, f"'{name}' not found on the real PATH -- cannot build a sterile one without it"
        (target_dir / name).symlink_to(real)
    assert not (target_dir / "docker").exists()
    return str(target_dir)


# Applied to the three stub-driven behaviour tests below. The
# missing-docker / missing-compose / plist / snippet tests do not
# depend on the stub being reachable and run everywhere.
_skip_if_real_docker = pytest.mark.skipif(
    _real_docker_shadows_stub(),
    reason="real docker on /usr/local/bin or /opt/homebrew/bin shadows the "
           "test stub (wrapper hard-prepends those dirs); runs on Docker-free CI",
)


def _make_fake_docker(stub_dir: Path, *, run_exit: int = 0,
                      up_exit: int = 0,
                      info_exit: int = 0,
                      log_path: Path | None = None) -> Path:
    """Build a docker stub that records every invocation and
    returns configurable exit codes for ``compose run``, ``compose
    up`` and ``docker info`` (the runtime-readiness probe -- #196)."""
    stub = stub_dir / "docker"
    log = log_path or (stub_dir / "docker.log")
    body = f"""#!/usr/bin/env bash
echo "$@" >> "{log}"
# `docker info` -- runtime-readiness probe (#196). A non-zero exit models a
# container runtime (Colima/Docker Desktop) that is not up yet.
if [ "$1" = "info" ]; then
    exit {info_exit}
fi
# `docker compose --profile compile run --rm -T wiki-compiler`
if [ "$1" = "compose" ] && [ "$2" = "--profile" ] && [ "$3" = "compile" ] && [ "$4" = "run" ]; then
    exit {run_exit}
fi
# `docker compose up -d wiki-site`
if [ "$1" = "compose" ] && [ "$2" = "up" ]; then
    exit {up_exit}
fi
# Anything else: succeed silently.
exit 0
"""
    stub.write_text(body)
    stub.chmod(stub.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return stub


def _stage_compose_file(ostler_dir: Path) -> None:
    """Create a minimal docker-compose.yml so the wrapper's sanity
    check passes. Content doesn't matter; the stub takes over."""
    (ostler_dir).mkdir(parents=True, exist_ok=True)
    (ostler_dir / "docker-compose.yml").write_text("services: {}\n")


def _run_wrapper(env: dict[str, str], stub_dir: Path) -> subprocess.CompletedProcess:
    full_env = os.environ.copy()
    full_env.update(env)
    full_env["PATH"] = f"{stub_dir}:{full_env.get('PATH', '')}"
    return subprocess.run(
        ["bash", str(WRAPPER)],
        env=full_env,
        capture_output=True,
        text=True,
    )


@pytest.fixture
def stub_env(tmp_path):
    ostler_dir = tmp_path / "ostler"
    ostler_dir.mkdir()
    _stage_compose_file(ostler_dir)
    stub_dir = tmp_path / "stubs"
    stub_dir.mkdir()
    return {
        "tmp_path": tmp_path,
        "ostler_dir": ostler_dir,
        "stub_dir": stub_dir,
    }


# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------


def _wait_for_line(log: Path, needle: str, timeout: float = 10.0) -> list[str]:
    """Poll the docker stub log until a line containing ``needle``
    appears. The Phase-2 full compile is launched detached (nohup +
    disown), so the wrapper returns before that invocation is
    guaranteed to have been recorded -- poll instead of racing."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if log.exists():
            lines = log.read_text().splitlines()
            if any(needle in line for line in lines):
                return lines
        time.sleep(0.05)
    return log.read_text().splitlines() if log.exists() else []


@_skip_if_real_docker
def test_wrapper_runs_baseline_then_up_then_detached_full(stub_env):
    log = stub_env["tmp_path"] / "docker.log"
    _make_fake_docker(stub_env["stub_dir"], log_path=log)

    result = _run_wrapper(
        {"OSTLER_DIR": str(stub_env["ostler_dir"])},
        stub_env["stub_dir"],
    )
    assert result.returncode == 0, (
        f"wrapper failed: stdout={result.stdout!r} stderr={result.stderr!r}"
    )

    # Phase 1 (baseline) and the publish step are synchronous -- they
    # must be recorded by the time the wrapper returns.
    invocations = log.read_text().splitlines()

    # Phase 1: a SKIP_LLM baseline compile.
    assert any(
        "compose --profile compile run --rm -T -e OSTLER_WIKI_SKIP_LLM=1 wiki-compiler" in line
        for line in invocations
    ), f"no SKIP_LLM baseline compile recorded: {invocations}"

    # Publish: wiki-site brought up with a PLAIN `up -d` -- no force-recreate
    # (the static server picks up the compile via its marker poll).
    assert any(
        "compose up -d wiki-site" in line for line in invocations
    ), invocations
    assert not any(
        "--force-recreate wiki-site" in line for line in invocations
    ), f"publish must not force-recreate any more: {invocations}"

    # Order: baseline before publish.
    baseline_idx = next(
        i for i, line in enumerate(invocations)
        if "run --rm -T -e OSTLER_WIKI_SKIP_LLM=1 wiki-compiler" in line
    )
    up_idx = next(i for i, line in enumerate(invocations)
                  if "compose up -d wiki-site" in line)
    assert baseline_idx < up_idx

    # Phase 2: a DETACHED full compile (no SKIP_LLM) launched AFTER
    # publishing. It is detached (nohup + disown), so the wrapper has
    # already returned -- poll for the line.
    all_lines = _wait_for_line(
        log, "run --rm -T wiki-compiler", timeout=10.0
    )
    full_lines = [
        line for line in all_lines
        if "run --rm -T wiki-compiler" in line
        and "OSTLER_WIKI_SKIP_LLM" not in line
    ]
    assert full_lines, (
        f"no detached full compile (without SKIP_LLM) recorded: {all_lines}"
    )

    # The tick must announce that it returned without waiting on the
    # summary pass.
    assert "summaries backfilling" in result.stdout, result.stdout
    assert "summary backfill launched in background" in result.stdout, result.stdout


# ---------------------------------------------------------------------------
# Failure surfaces
# ---------------------------------------------------------------------------


@_skip_if_real_docker
def test_baseline_failure_skips_up_and_surfaces_exit(stub_env):
    """When the baseline wiki-compiler fails, wrapper must NOT
    proceed to bring up wiki-site, nor launch the background full
    compile; the compile-failure exit code propagates."""
    log = stub_env["tmp_path"] / "docker.log"
    _make_fake_docker(stub_env["stub_dir"], run_exit=42, log_path=log)

    result = _run_wrapper(
        {"OSTLER_DIR": str(stub_env["ostler_dir"])},
        stub_env["stub_dir"],
    )
    assert result.returncode == 42
    assert "wiki-compiler baseline failed" in result.stdout
    assert "Manual retry" in result.stdout

    # No publish, and -- give a detached full compile a beat to
    # appear if it (wrongly) launched -- no background full compile.
    time.sleep(0.3)
    invocations = log.read_text().splitlines()
    # No publish at all on a failed baseline.
    assert not any("compose up -d wiki-site" in line for line in invocations)
    # The single run invocation we DID make is the baseline (carries
    # SKIP_LLM); there must be no second, summary-pass run.
    run_lines = [line for line in invocations if "run --rm -T" in line]
    assert len(run_lines) == 1, run_lines
    assert "OSTLER_WIKI_SKIP_LLM=1" in run_lines[0]


@_skip_if_real_docker
def test_up_failure_surfaces_exit(stub_env):
    """When the up step fails, wrapper exits non-zero with a
    surface that distinguishes the "compile worked, server didn't"
    case from the "compile failed" case."""
    log = stub_env["tmp_path"] / "docker.log"
    _make_fake_docker(stub_env["stub_dir"], up_exit=99, log_path=log)

    result = _run_wrapper(
        {"OSTLER_DIR": str(stub_env["ostler_dir"])},
        stub_env["stub_dir"],
    )
    assert result.returncode == 99
    assert "wiki-site failed to start" in result.stdout

    # The baseline ran and the publish was attempted, but because the
    # publish failed we must NOT launch the background full compile
    # (give it a beat to appear if it wrongly did).
    time.sleep(0.3)
    invocations = log.read_text().splitlines()
    assert any(
        "run --rm -T -e OSTLER_WIKI_SKIP_LLM=1 wiki-compiler" in line
        for line in invocations
    )
    assert any("up -d wiki-site" in line for line in invocations)
    full_lines = [
        line for line in invocations
        if "run --rm -T wiki-compiler" in line
        and "OSTLER_WIKI_SKIP_LLM" not in line
    ]
    assert not full_lines, f"background full compile should not have launched: {full_lines}"


# ---------------------------------------------------------------------------
# Container-runtime readiness gate (#196) -- reboot self-heal, no launchd fail
# ---------------------------------------------------------------------------
#
# On a reboot the LaunchAgent (RunAtLoad) can fire before Colima's VM is up:
# the docker CLI resolves but the daemon is unreachable. The old script ran
# the compile blind, it failed, and the tick exited non-zero -- launchd logged
# a hard failure even though the next tick recovers. The gate waits, bounded,
# for `docker info` to answer; if it never does within the window it exits 0
# (a no-op) rather than 1, so the transient is not recorded as a failure.


@_skip_if_real_docker
def test_runtime_not_ready_exits_zero_without_compiling(stub_env):
    """When `docker info` never succeeds (runtime still booting), the tick
    logs a clear "will retry next tick" line, exits 0, and does NOT attempt
    any compile or publish."""
    log = stub_env["tmp_path"] / "docker.log"
    # info_exit=1 -> the runtime never becomes ready within the window.
    _make_fake_docker(stub_env["stub_dir"], info_exit=1, log_path=log)

    result = _run_wrapper(
        {
            "OSTLER_DIR": str(stub_env["ostler_dir"]),
            # Keep the test fast: 2 attempts, 1s apart (~2s total).
            "WIKI_RUNTIME_WAIT_TRIES": "2",
            "WIKI_RUNTIME_WAIT_INTERVAL": "1",
        },
        stub_env["stub_dir"],
    )

    # Exit 0 (NOT the compile's failure code) so launchd records no failure.
    assert result.returncode == 0, (
        f"a not-ready runtime must exit 0, got {result.returncode}: "
        f"stdout={result.stdout!r} stderr={result.stderr!r}"
    )
    assert "will retry next tick" in result.stdout, result.stdout
    # It must NOT have run the compile or the publish -- only info probes.
    invocations = log.read_text().splitlines() if log.exists() else []
    assert not any("compose" in line for line in invocations), (
        f"no compose command must run before the runtime is ready: {invocations}"
    )
    # It DID probe the runtime with `docker info`.
    assert any(line.strip() == "info" for line in invocations), invocations
    # And it never acquired the tick mutex (exits before `cd`/lock).
    assert not (stub_env["ostler_dir"] / ".wiki-recompile.lock").exists()


@_skip_if_real_docker
def test_runtime_becomes_ready_then_compiles(stub_env):
    """A ready runtime (docker info -> 0) proceeds straight into the baseline
    compile -- the readiness gate is transparent on the happy path."""
    log = stub_env["tmp_path"] / "docker.log"
    _make_fake_docker(stub_env["stub_dir"], info_exit=0, log_path=log)

    result = _run_wrapper(
        {
            "OSTLER_DIR": str(stub_env["ostler_dir"]),
            "WIKI_RUNTIME_WAIT_TRIES": "3",
            "WIKI_RUNTIME_WAIT_INTERVAL": "1",
        },
        stub_env["stub_dir"],
    )
    assert result.returncode == 0, (
        f"ready runtime must proceed: stdout={result.stdout!r} stderr={result.stderr!r}"
    )
    invocations = log.read_text().splitlines()
    assert any(
        "compose --profile compile run --rm -T -e OSTLER_WIKI_SKIP_LLM=1 wiki-compiler" in line
        for line in invocations
    ), f"a ready runtime must reach the baseline compile: {invocations}"


def test_script_carries_runtime_readiness_gate():
    """Always-runs guard (no docker dependency): the shipped script must carry
    the #196 readiness gate -- poll `docker info`, and on a persistently
    not-ready runtime exit 0 (not 1) so launchd records no failure."""
    tick = WRAPPER.read_text()
    assert "docker info" in tick, "readiness gate must probe `docker info`"
    assert "will retry next tick" in tick, (
        "not-ready path must log a clear retry line"
    )
    # The not-ready branch must exit 0, never propagate a failure. Assert the
    # readiness block ends in `exit 0` (before the `cd`/compile).
    gate = tick.split("Container-runtime readiness gate", 1)
    assert len(gate) == 2, "readiness gate block missing"
    after = gate[1].split('cd "$OSTLER_DIR"', 1)[0]
    assert "exit 0" in after, "not-ready runtime must exit 0, not fail the tick"
    assert "WIKI_RUNTIME_WAIT_TRIES" in tick and "WIKI_RUNTIME_WAIT_INTERVAL" in tick, (
        "the wait window must be bounded + configurable"
    )


def test_missing_compose_file_fails_loudly(stub_env):
    """If $OSTLER_DIR has no docker-compose.yml, the install was
    never run -- exit with a clear message."""
    # Wipe the compose file we staged in the fixture.
    (stub_env["ostler_dir"] / "docker-compose.yml").unlink()
    _make_fake_docker(stub_env["stub_dir"])

    result = _run_wrapper(
        {"OSTLER_DIR": str(stub_env["ostler_dir"])},
        stub_env["stub_dir"],
    )
    assert result.returncode == 1
    assert "docker-compose.yml not found" in result.stdout
    assert "Re-run install.sh" in result.stdout


@_skip_if_real_docker
def test_missing_docker_fails_loudly(stub_env):
    """If `docker` is not on PATH, exit 127 with a clear message
    rather than running compose blind."""
    # Sterile PATH: a fresh directory holding ONLY symlinks to bash + date
    # (see _minimal_path_without_docker) -- so the script's own interpreter
    # and its log() helper stay findable but docker is genuinely unreachable,
    # on any platform's real directory layout. We also don't install a
    # docker stub in stub_dir. NB: the wrapper ADDITIONALLY hard-prepends
    # /usr/local/bin + /opt/homebrew/bin regardless of our PATH, so on a dev
    # box with Docker Desktop installed at one of those two this "no docker"
    # premise is unsatisfiable no matter how the sterile PATH is built --
    # hence the skip guard, which is a separate concern from (and is not
    # fixed by) the PATH construction here.
    sterile_path = _minimal_path_without_docker(stub_env["tmp_path"] / "sterile-no-docker")
    full_env = {
        "HOME": os.environ.get("HOME", str(stub_env["tmp_path"])),
        "OSTLER_DIR": str(stub_env["ostler_dir"]),
        "PATH": sterile_path,
    }

    result = subprocess.run(
        ["bash", str(WRAPPER)],
        env=full_env,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 127, (
        f"expected 127, got {result.returncode}: "
        f"stdout={result.stdout!r} stderr={result.stderr!r}"
    )
    assert "docker is not on PATH" in result.stdout


# ---------------------------------------------------------------------------
# Plist + install snippet sanity
# ---------------------------------------------------------------------------


def test_plist_is_well_formed_xml():
    import plistlib
    plist = REPO_ROOT / "wiki-recompile" / "launchd" / "com.creativemachines.ostler.wiki-recompile.plist"
    with plist.open("rb") as fh:
        data = plistlib.load(fh)
    assert data["Label"] == "com.creativemachines.ostler.wiki-recompile"
    assert data["StartInterval"] == 86400  # daily; open question in PR body
    assert data["RunAtLoad"] is True

    args_str = " ".join(data["ProgramArguments"])
    assert "OSTLER_BIN" in args_str
    assert "wiki-recompile-tick.sh" in args_str
    assert "OSTLER_LOGS" in data["StandardOutPath"]
    assert "OSTLER_LOGS" in data["StandardErrorPath"]


def test_install_snippet_substitutes_placeholders(tmp_path):
    install_root = REPO_ROOT / "wiki-recompile"
    fake_home = tmp_path / "home"
    fake_home.mkdir()
    fake_ostler = tmp_path / "fake-ostler"
    fake_logs = tmp_path / "fake-logs"

    stub_bin = tmp_path / "stubbin"
    stub_bin.mkdir()
    launchctl_stub = stub_bin / "launchctl"
    launchctl_stub.write_text(
        "#!/usr/bin/env bash\n"
        "echo \"launchctl stub called: $@\"\n"
        "exit 0\n"
    )
    launchctl_stub.chmod(launchctl_stub.stat().st_mode | stat.S_IXUSR)

    env = {
        "HOME": str(fake_home),
        "OSTLER_INSTALL_ROOT": str(install_root),
        "OSTLER_DIR": str(fake_ostler),
        "LOGS_DIR": str(fake_logs),
        "PATH": f"{stub_bin}:/usr/bin:/bin",
    }
    result = subprocess.run(
        ["bash", str(install_root / "INSTALL_SNIPPET.sh")],
        env=env,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, (
        f"install snippet failed: stdout={result.stdout!r} stderr={result.stderr!r}"
    )

    rendered = (
        fake_home / "Library" / "LaunchAgents"
        / "com.creativemachines.ostler.wiki-recompile.plist"
    )
    assert rendered.exists()
    body = rendered.read_text()

    assert "OSTLER_BIN" not in body
    assert "OSTLER_HOME" not in body
    assert "OSTLER_LOGS" not in body
    assert str(fake_ostler / "bin") in body
    assert str(fake_home) in body
    assert str(fake_logs) in body

    staged_wrapper = fake_ostler / "bin" / "wiki-recompile-tick.sh"
    assert staged_wrapper.exists()
    assert staged_wrapper.stat().st_mode & 0o111


# ---------------------------------------------------------------------------
# Static-serve: both publish paths use a plain `up -d` (NO force-recreate)
# ---------------------------------------------------------------------------


def test_both_publish_paths_use_plain_up_no_force_recreate():
    """The wiki-site container now runs a static server (CM044
    docker/wiki-site-serve.py) that builds the HTML off the serving path and
    picks up a finished compile by POLLING the compiler's .compile-complete
    marker, then atomically swaps the new build in. So neither publish path
    needs to restart the container: a plain `up -d wiki-site` is correct, and
    the old `--force-recreate` (#598) -- which WAS the recompile-window 000 --
    must be gone from BOTH the recompile-tick and the install-time publish so
    they never diverge."""
    tick = WRAPPER.read_text()
    assert "up -d wiki-site" in tick, (
        "wiki-recompile-tick.sh publish must use a plain `up -d wiki-site`"
    )
    assert "--force-recreate wiki-site" not in tick, (
        "wiki-recompile-tick.sh must NOT force-recreate (it was the 000)"
    )

    install_sh = (REPO_ROOT / "install.sh").read_text()
    assert "up -d wiki-site" in install_sh, (
        "install.sh publish must use the identical plain `up -d wiki-site`; "
        "install-time and recompile-time publish must not diverge"
    )
    assert "--force-recreate wiki-site" not in install_sh, (
        "install.sh must NOT force-recreate wiki-site any more"
    )


# ---------------------------------------------------------------------------
# Single-tick mutex (concurrency guard) -- the first-day catch-up storm
# ---------------------------------------------------------------------------
#
# On a fresh install the catch-up runner fires many ticks in quick
# succession; with no lock they spawned competing wiki-compiler containers
# that contended for Ollama and raced on the wiki_docs volume, so no
# baseline ever survived to publish and the wiki never came up. These guard
# the mkdir-based mutex (macOS has no flock).


def test_mutex_skips_when_another_tick_holds_the_lock(stub_env):
    """A tick that finds the lock held by a LIVE pid exits 0 WITHOUT
    compiling -- the in-flight tick will publish. The skip happens before
    docker is invoked, so this runs everywhere (no stub dependency)."""
    _make_fake_docker(stub_env["stub_dir"], log_path=stub_env["tmp_path"] / "docker.log")
    ostler_dir = stub_env["ostler_dir"]
    lock_dir = ostler_dir / ".wiki-recompile.lock"
    lock_dir.mkdir()
    # This test process is guaranteed alive -> a live holder.
    (lock_dir / "pid").write_text(f"{os.getpid()}\n")

    result = _run_wrapper({"OSTLER_DIR": str(ostler_dir)}, stub_env["stub_dir"])

    assert result.returncode == 0, (
        f"a tick blocked by a live holder must exit 0: {result.stderr!r}"
    )
    assert "already running; skipping" in result.stdout, result.stdout
    # The holder's lock must be left intact (not stolen mid-run).
    assert lock_dir.exists(), "must not delete a live holder's lock"


@_skip_if_real_docker
def test_mutex_reclaims_stale_lock_from_dead_holder(stub_env):
    """A lock left by a tick that was killed mid-run (holder pid gone) is
    reclaimed and the tick proceeds into the baseline compile."""
    log = stub_env["tmp_path"] / "docker.log"
    _make_fake_docker(stub_env["stub_dir"], log_path=log)
    ostler_dir = stub_env["ostler_dir"]
    lock_dir = ostler_dir / ".wiki-recompile.lock"
    lock_dir.mkdir()
    (lock_dir / "pid").write_text("999999\n")  # almost-certainly-dead pid

    result = _run_wrapper({"OSTLER_DIR": str(ostler_dir)}, stub_env["stub_dir"])

    assert result.returncode == 0, result.stderr
    assert "reclaiming stale wiki-recompile lock" in result.stdout, result.stdout
    invocations = log.read_text().splitlines() if log.exists() else []
    assert any(
        "OSTLER_WIKI_SKIP_LLM=1 wiki-compiler" in line for line in invocations
    ), f"must proceed into the baseline compile after reclaim: {invocations}"


@_skip_if_real_docker
def test_mutex_releases_lock_on_normal_exit(stub_env):
    """After a clean tick the lock dir is gone so the next tick can run."""
    _make_fake_docker(stub_env["stub_dir"], log_path=stub_env["tmp_path"] / "docker.log")
    ostler_dir = stub_env["ostler_dir"]
    result = _run_wrapper({"OSTLER_DIR": str(ostler_dir)}, stub_env["stub_dir"])
    assert result.returncode == 0, result.stderr
    assert not (ostler_dir / ".wiki-recompile.lock").exists(), (
        "the mutex must be released on a normal exit"
    )


def test_phase2_backfill_does_not_stack(stub_env):
    """The detached Phase-2 full compile must not be launched if a previous
    backfill is still running -- otherwise the catch-up fires N stacked
    multi-hour compiles. Guard is keyed on a live pidfile, so this runs
    everywhere (the skip happens before docker is invoked for Phase 2)."""
    _make_fake_docker(stub_env["stub_dir"], log_path=stub_env["tmp_path"] / "docker.log")
    ostler_dir = stub_env["ostler_dir"]
    # Pretend a backfill from a previous tick is still alive (this process).
    (ostler_dir / ".wiki-recompile-summaries.pid").write_text(f"{os.getpid()}\n")
    # Also hold the main lock (live) so the tick short-circuits at the mutex
    # and we are asserting purely on the guard's existence in the script.
    assert "wiki summary backfill already running" in WRAPPER.read_text(), (
        "tick script must carry the no-stack backfill guard"
    )


# ---------------------------------------------------------------------------
# CM051 walk #5 follow-up (Archie review on #2633): editor-frontpage-tick.sh
# now kickstarts this whole tick on every front_page.json change. Phase 1 is
# cheap, but the anti-STACKING guard above only stops two backfills
# overlapping -- it does nothing to stop a new one starting the moment the
# previous one finishes. On a thin graph (Phase 2 finishes in minutes) an
# hourly trigger would restart the LLM backfill on every tick, turning the
# deliberate daily cost (#20's "daily vs hourly" decision) into a
# near-continuous one. This floor is independent of the no-stack guard and
# of who triggered the tick.
# ---------------------------------------------------------------------------


@_skip_if_real_docker
def test_phase2_backfill_debounced_when_started_recently(stub_env):
    """A Phase-2 backfill that already STARTED inside the cost floor must not
    be relaunched just because it has since finished (no live pidfile)."""
    log = stub_env["tmp_path"] / "docker.log"
    _make_fake_docker(stub_env["stub_dir"], log_path=log)
    ostler_dir = stub_env["ostler_dir"]
    state_dir = ostler_dir / "state" / "wiki-recompile"
    state_dir.mkdir(parents=True)
    (state_dir / "last-phase2-start-epoch").write_text(str(int(time.time())))

    result = _run_wrapper({"OSTLER_DIR": str(ostler_dir)}, stub_env["stub_dir"])
    assert result.returncode == 0, result.stderr
    assert "not launching another yet" in result.stdout, result.stdout

    # Give a would-be detached launch a moment to appear, then confirm it
    # never does -- same poll primitive as the happy-path test, inverted.
    lines = _wait_for_line(log, "run --rm -T wiki-compiler", timeout=2.0)
    full_lines = [
        line for line in lines
        if "run --rm -T wiki-compiler" in line and "OSTLER_WIKI_SKIP_LLM" not in line
    ]
    assert not full_lines, f"Phase 2 launched despite the cost floor: {lines}"


@_skip_if_real_docker
def test_phase2_backfill_runs_once_the_floor_has_elapsed(stub_env):
    """The same box, once WIKI_PHASE2_MIN_INTERVAL_SECONDS has actually
    elapsed since the last Phase-2 start, must launch again -- the floor
    delays, it does not permanently disable, the backfill."""
    log = stub_env["tmp_path"] / "docker.log"
    _make_fake_docker(stub_env["stub_dir"], log_path=log)
    ostler_dir = stub_env["ostler_dir"]
    state_dir = ostler_dir / "state" / "wiki-recompile"
    state_dir.mkdir(parents=True)
    (state_dir / "last-phase2-start-epoch").write_text(str(int(time.time()) - 100))

    result = _run_wrapper(
        {"OSTLER_DIR": str(ostler_dir), "WIKI_PHASE2_MIN_INTERVAL_SECONDS": "10"},
        stub_env["stub_dir"],
    )
    assert result.returncode == 0, result.stderr

    lines = _wait_for_line(log, "run --rm -T wiki-compiler", timeout=10.0)
    full_lines = [
        line for line in lines
        if "run --rm -T wiki-compiler" in line and "OSTLER_WIKI_SKIP_LLM" not in line
    ]
    assert full_lines, f"Phase 2 did not launch once the floor elapsed: {lines}"


@_skip_if_real_docker
def test_phase2_debounce_state_file_written_on_launch(stub_env):
    """A Phase 2 launch must record the start time, or the floor above
    never has anything to measure against on the NEXT tick."""
    _make_fake_docker(stub_env["stub_dir"], log_path=stub_env["tmp_path"] / "docker.log")
    ostler_dir = stub_env["ostler_dir"]
    state_file = ostler_dir / "state" / "wiki-recompile" / "last-phase2-start-epoch"
    assert not state_file.exists()

    before = int(time.time())
    result = _run_wrapper({"OSTLER_DIR": str(ostler_dir)}, stub_env["stub_dir"])
    after = int(time.time())
    assert result.returncode == 0, result.stderr

    # The state-file write happens synchronously, before the detached nohup
    # launch, so it must exist the moment the wrapper returns -- no polling.
    assert state_file.exists(), "Phase 2 launch must record its start epoch"
    recorded = int(state_file.read_text().strip())
    assert before <= recorded <= after + 2, f"recorded epoch {recorded} not in [{before}, {after}]"


@_skip_if_real_docker
def test_phase2_debounce_control_the_floor_actually_fires(stub_env):
    """Negative control for the three tests above: WITHOUT any state file
    (the common case -- first tick ever, or an upgrade from a build that
    predates this guard), Phase 2 must still launch. Otherwise the floor's
    absence-handling, not the floor itself, would be what the other tests
    measure."""
    log = stub_env["tmp_path"] / "docker.log"
    _make_fake_docker(stub_env["stub_dir"], log_path=log)
    ostler_dir = stub_env["ostler_dir"]
    # Deliberately no state/wiki-recompile/last-phase2-start-epoch file.

    result = _run_wrapper({"OSTLER_DIR": str(ostler_dir)}, stub_env["stub_dir"])
    assert result.returncode == 0, result.stderr
    lines = _wait_for_line(log, "run --rm -T wiki-compiler", timeout=10.0)
    full_lines = [
        line for line in lines
        if "run --rm -T wiki-compiler" in line and "OSTLER_WIKI_SKIP_LLM" not in line
    ]
    assert full_lines, f"absent state file must not itself block Phase 2: {lines}"


# ---------------------------------------------------------------------------
# v1.0.107: the stall watchdog cannot see a containerised payload, so the
# full (summaries) compile was being killed before it could ever flip
# hydration to complete.
# ---------------------------------------------------------------------------
#
# The shared ingest-slot library's stall check (_ostler_slot_tree_cpu, in
# lib/ostler-ingest-slot.sh) measures cumulative HOST cpu of the process
# tree under the watched pid via `ps`/`pgrep`. That is the right read for
# the conversation feeds, whose watched pid IS the real work (a host Python
# process). For `docker compose run wiki-compiler` the watched pid is the
# docker CLIENT: the actual compile runs inside the container runtime's own
# VM, a tree this Mac's `ps` cannot see. The client reads back as burning
# ZERO cpu for its whole life, which is exactly the shape the watchdog is
# built to call HUNG -- so every full compile was being TERM'd then KILL'd
# mid-run, every time, and hydration.complete() (only reached by a full
# compile that finishes) was never written.
#
# This test drives the REAL wiki-recompile-tick.sh against the REAL shared
# slot library (not a mock of either), with a stub `docker` whose "full
# compile" arm sleeps -- burning no host cpu of its own, exactly like the
# real client -- then touches a marker file. The stall window is forced low
# so the test does not need to wait out the production default (2100s). On
# the pre-fix script this reliably fails: reverting the
# `OSTLER_SLOT_STALL_SECS=0` line in the tick script (restoring the bare
# `. "$_lib"`) makes the watchdog apply the test's low stall window to the
# sleeping stub exactly as it would the production default to a real
# multi-hour compile, and the marker is never written.
_SLOT_LIB = REPO_ROOT / "lib" / "ostler-ingest-slot.sh"


def _make_slow_container_docker(stub_dir: Path, *, log_path: Path,
                                 done_marker: Path,
                                 full_compile_seconds: int) -> Path:
    """A docker stub whose FULL (non-SKIP_LLM) compile arm models a real
    `docker compose run` client: it does nothing but sleep (no host cpu),
    while the container "does its work" invisibly, then touches
    ``done_marker`` to prove it ran to completion rather than being killed
    partway through."""
    stub = stub_dir / "docker"
    stub.write_text(f"""#!/usr/bin/env bash
echo "$@" >> "{log_path}"
if [ "$1" = "info" ]; then
    exit 0
fi
if [ "$1" = "compose" ] && [ "$2" = "--profile" ] && [ "$3" = "compile" ] && [ "$4" = "run" ]; then
    for a in "$@"; do
        case "$a" in
            *OSTLER_WIKI_SKIP_LLM*) exit 0 ;;   # baseline: instant
        esac
    done
    # Full compile: the client burns no cpu of its own while the
    # (unmodelled) container does its work.
    sleep {full_compile_seconds}
    : > "{done_marker}"
    exit 0
fi
if [ "$1" = "compose" ] && [ "$2" = "up" ]; then
    exit 0
fi
exit 0
""")
    stub.chmod(stub.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return stub


@_skip_if_real_docker
def test_full_compile_survives_past_the_stall_window(stub_env, tmp_path):
    """The detached full compile must not be killed by the cpu-stall
    watchdog just because the docker client (correctly) shows no host cpu
    activity of its own. Regression for v1.0.107 (hydration never
    reaching complete: true)."""
    assert _SLOT_LIB.exists(), f"shared slot lib missing at {_SLOT_LIB}"

    log = stub_env["tmp_path"] / "docker.log"
    done_marker = tmp_path / "full-compile-done"
    # The stub's full-compile arm sleeps longer than the forced-low stall
    # window below, so an armed watchdog would kill it before the marker
    # is written.
    _make_slow_container_docker(
        stub_env["stub_dir"], log_path=log, done_marker=done_marker,
        full_compile_seconds=6,
    )
    slot_state = tmp_path / "slot-state"

    result = _run_wrapper(
        {
            "OSTLER_DIR": str(stub_env["ostler_dir"]),
            "OSTLER_INGEST_SLOT_LIB": str(_SLOT_LIB),
            "OSTLER_STATE_DIR": str(slot_state),
            # Forced low so a RE-ARMED watchdog (i.e. this fix reverted)
            # would fire well within this test's patience.
            "OSTLER_SLOT_STALL_SECS": "2",
            "OSTLER_SLOT_POLL_SECS": "1",
        },
        stub_env["stub_dir"],
    )
    assert result.returncode == 0, (
        f"wrapper failed: stdout={result.stdout!r} stderr={result.stderr!r}"
    )

    deadline = time.monotonic() + 15.0
    while time.monotonic() < deadline and not done_marker.exists():
        time.sleep(0.1)

    assert done_marker.exists(), (
        "the full compile never ran to completion -- the stall watchdog "
        "killed it mid-run even though it was not hung (v1.0.107)"
    )


# ---------------------------------------------------------------------------
# v1.0.107 walk #4: the stall-watchdog fix above was not enough. launchd
# tracks a LaunchAgent job by PROCESS GROUP and, by default, SIGKILLs every
# process still in that group the instant the job's main process exits.
# `nohup ... & disown` does not move the detached compile out of that group --
# disown only stops THIS shell sending it SIGHUP on exit -- so the detached
# Phase-2 compile was being killed by launchd itself, often before it could
# write a single byte, independently of (and before) the stall watchdog ever
# got a chance to matter. Measured on a walk: wiki-recompile-tick.sh on disk
# already carried the stall-watchdog fix (OSTLER_SLOT_STALL_SECS=0 present),
# and hydration STILL never completed -- phase 4, 0/0, a 0-byte summaries
# log, no compile process or container anywhere.
# ---------------------------------------------------------------------------


@_skip_if_real_docker
def test_detached_compile_survives_a_launchd_process_group_kill(stub_env, tmp_path):
    """Starts the real wiki-recompile-tick.sh as the leader of a FRESH
    process group -- exactly how launchd starts each job it runs -- waits for
    it to exit (it does, once the baseline publishes and Phase 2 is
    launched), then sends SIGKILL to that WHOLE process group, mirroring
    launchd's default behaviour for a job with no AbandonProcessGroup. The
    detached compile must not be a member of that group by then (see the
    `set -m` comment at the Phase-2 launch site) and so must survive and run
    to completion untouched.

    RED without that `set -m`: the detached compile shares the wrapper's
    process group (the default), the simulated kill reaches it exactly as a
    real launchd kill would, and it dies before writing its done marker.
    """
    log = stub_env["tmp_path"] / "docker.log"
    done_marker = tmp_path / "full-compile-done"
    # Long enough that the simulated kill (sent moments after the wrapper
    # exits) lands well before a correctly-escaped compile would finish on
    # its own -- so survival here is evidence of process-group escape, not
    # of the kill simply arriving too late to matter.
    _make_slow_container_docker(
        stub_env["stub_dir"], log_path=log, done_marker=done_marker,
        full_compile_seconds=4,
    )

    env = os.environ.copy()
    env["OSTLER_DIR"] = str(stub_env["ostler_dir"])
    env["PATH"] = f"{stub_env['stub_dir']}:{env.get('PATH', '')}"

    proc = subprocess.Popen(
        ["bash", str(WRAPPER)],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        # The leader of a brand-new process group (pgid == its own pid),
        # which is exactly how launchd starts every job it runs.
        preexec_fn=os.setpgrp,
    )
    wrapper_pgid = proc.pid
    try:
        out, _ = proc.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        proc.kill()
        raise AssertionError("the wrapper (simulated launchd job) never returned")
    assert proc.returncode == 0, (
        f"wrapper (the simulated launchd job) failed: {out!r}"
    )

    # THE SIMULATED LAUNCHD KILL. A real launchd, with AbandonProcessGroup
    # unset, sends SIGKILL to every process still in the job's process group
    # the instant the job's main process exits -- which just happened above.
    # A ProcessLookupError here means the group was ALREADY empty (every
    # member had already escaped it), which is itself a PASS signal, not an
    # error: it is what a correctly-escaped detached compile looks like by
    # the time Popen.communicate() has reaped the parent.
    try:
        os.killpg(wrapper_pgid, signal.SIGKILL)
    except ProcessLookupError:
        pass

    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline and not done_marker.exists():
        time.sleep(0.1)

    assert done_marker.exists(), (
        "the detached compile did not survive a simulated launchd "
        "process-group kill sent the instant the wrapper exited -- it is "
        "still a member of the wrapper's process group (v1.0.107 walk #4)"
    )
