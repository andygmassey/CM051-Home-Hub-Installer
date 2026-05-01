"""Tests for the wiki-recompile LaunchAgent wrapper script.

Drives ``wiki-recompile-tick.sh`` end-to-end with a stubbed
``docker`` binary so we can exercise the success / failure paths
without a live Docker daemon. Asserts:

- Calls ``docker compose --profile compile run --rm wiki-compiler``.
- Then calls ``docker compose up -d wiki-site``.
- Surfaces compose run failures with a clear message and skips the
  wiki-site refresh.
- Surfaces ``docker compose up`` failures with a clear message.
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
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[2]
WRAPPER = REPO_ROOT / "wiki-recompile" / "bin" / "wiki-recompile-tick.sh"


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
# `docker compose --profile compile run --rm wiki-compiler`
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


def test_wrapper_runs_compile_then_up(stub_env):
    log = stub_env["tmp_path"] / "docker.log"
    _make_fake_docker(stub_env["stub_dir"], log_path=log)

    result = _run_wrapper(
        {"OSTLER_DIR": str(stub_env["ostler_dir"])},
        stub_env["stub_dir"],
    )
    assert result.returncode == 0, (
        f"wrapper failed: stdout={result.stdout!r} stderr={result.stderr!r}"
    )

    invocations = log.read_text().splitlines()
    # Two docker invocations expected, in order.
    assert any("compose --profile compile run --rm wiki-compiler" in line
               for line in invocations), invocations
    assert any("compose up -d wiki-site" in line for line in invocations), invocations

    # Order: run before up.
    run_idx = next(i for i, line in enumerate(invocations)
                   if "compose --profile compile run --rm wiki-compiler" in line)
    up_idx = next(i for i, line in enumerate(invocations)
                  if "compose up -d wiki-site" in line)
    assert run_idx < up_idx


# ---------------------------------------------------------------------------
# Failure surfaces
# ---------------------------------------------------------------------------


def test_compile_failure_skips_up_and_surfaces_exit(stub_env):
    """When wiki-compiler fails, wrapper must NOT proceed to bring
    up wiki-site; the compile-failure exit code propagates."""
    log = stub_env["tmp_path"] / "docker.log"
    _make_fake_docker(stub_env["stub_dir"], run_exit=42, log_path=log)

    result = _run_wrapper(
        {"OSTLER_DIR": str(stub_env["ostler_dir"])},
        stub_env["stub_dir"],
    )
    assert result.returncode == 42
    assert "wiki-compiler failed" in result.stdout
    assert "Manual retry" in result.stdout

    # Only the run invocation, no up invocation.
    invocations = log.read_text().splitlines()
    assert not any("compose up -d wiki-site" in line for line in invocations)


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
    # Both invocations happened.
    invocations = log.read_text().splitlines()
    assert any("run --rm wiki-compiler" in line for line in invocations)
    assert any("up -d wiki-site" in line for line in invocations)


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


def test_missing_docker_fails_loudly(stub_env):
    """If `docker` is not on PATH, exit 127 with a clear message
    rather than running compose blind."""
    # Sterile PATH that contains /usr/bin + /bin (so `bash`, `date`,
    # and so on are findable) but NOT a docker binary. We also
    # don't install a docker stub in stub_dir, so docker is truly
    # unreachable.
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
