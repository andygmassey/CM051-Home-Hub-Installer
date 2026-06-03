"""Tests for the wiki-recompile LaunchAgent wrapper script.

Drives ``wiki-recompile-tick.sh`` end-to-end with a stubbed
``docker`` binary so we can exercise the success / failure paths
without a live Docker daemon. Asserts:

- Phase 1: runs a FAST BASELINE compile with
  ``-e OSTLER_WIKI_SKIP_LLM=1`` (skips the multi-hour LLM summary
  pass so people appear in seconds).
- Then publishes via ``docker compose up -d wiki-site``.
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
import stat
import subprocess
import time
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[2]
WRAPPER = REPO_ROOT / "wiki-recompile" / "bin" / "wiki-recompile-tick.sh"


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
                      log_path: Path | None = None) -> Path:
    """Build a docker stub that records every invocation and
    returns configurable exit codes for ``compose run`` and
    ``compose up``."""
    stub = stub_dir / "docker"
    log = log_path or (stub_dir / "docker.log")
    body = f"""#!/usr/bin/env bash
echo "$@" >> "{log}"
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

    # Publish: wiki-site brought up.
    assert any("compose up -d wiki-site" in line for line in invocations), invocations

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
    # Sterile PATH that contains /usr/bin + /bin (so `bash`, `date`,
    # and so on are findable) but NOT a docker binary. We also
    # don't install a docker stub in stub_dir, so docker is truly
    # unreachable. NB: the wrapper hard-prepends /usr/local/bin +
    # /opt/homebrew/bin, so on a dev box with Docker Desktop this
    # "no docker" premise is unsatisfiable -- hence the skip guard.
    sterile_path = "/usr/bin:/bin"
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
