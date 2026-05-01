"""Tests for the ostler-assistant LaunchAgent install assets.

The LaunchAgent runs the upstream `ostler-assistant daemon`
subcommand on login, with `ZEROCLAW_WORKSPACE` pointing at the
config directory Phase D's installer wizard wrote. This test
module verifies the static assets the installer ships:

- The plist parses as well-formed XML.
- The plist references the placeholders the INSTALL_SNIPPET
  substitutes at install time.
- The plist invokes the daemon subcommand, sets KeepAlive on
  abnormal exit only, and points logs at OSTLER_LOGS.
- The INSTALL_SNIPPET refuses to register the LaunchAgent if
  the binary is missing -- a misregistered agent that thrashes
  ThrottleInterval forever is worse than a clear "binary not
  staged" error.
- The INSTALL_SNIPPET stages the rendered plist and substitutes
  every placeholder.

Mirrors the wiki-recompile test shape so the LaunchAgent
coverage looks symmetric across the three CM051 agents.
"""
from __future__ import annotations

import os
import plistlib
import stat
import subprocess
import textwrap
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[2]
PLIST = REPO_ROOT / "assistant-agent" / "launchd" / "com.creativemachines.ostler.assistant.plist"
SNIPPET = REPO_ROOT / "assistant-agent" / "INSTALL_SNIPPET.sh"


# ---------------------------------------------------------------------------
# Plist shape
# ---------------------------------------------------------------------------


def test_plist_is_well_formed_xml():
    data = plistlib.loads(PLIST.read_bytes())
    assert isinstance(data, dict)


def test_plist_label_matches_uninstaller_expectations():
    data = plistlib.loads(PLIST.read_bytes())
    assert data["Label"] == "com.creativemachines.ostler.assistant"


def test_plist_invokes_daemon_subcommand():
    data = plistlib.loads(PLIST.read_bytes())
    args = data["ProgramArguments"]
    # The wrapper-less plist points at the binary directly so we
    # don't pay tick-script overhead per restart.
    assert args[0].endswith("/ostler-assistant"), args
    assert args[1] == "daemon", args


def test_plist_keepalive_only_on_abnormal_exit():
    data = plistlib.loads(PLIST.read_bytes())
    keepalive = data["KeepAlive"]
    # Bool-True would respawn even on intentional shutdown
    # (uninstall, fatal config error). Dict form with
    # SuccessfulExit=false is the launchd idiom for "respawn on
    # crash, leave alone on clean exit".
    assert isinstance(keepalive, dict), keepalive
    assert keepalive.get("SuccessfulExit") is False


def test_plist_runs_at_load():
    data = plistlib.loads(PLIST.read_bytes())
    assert data["RunAtLoad"] is True


def test_plist_throttle_interval_present():
    # An unbounded crash loop on a misconfigured channel would
    # burn battery and saturate the log rotator. Explicit value
    # documents the policy in the file.
    data = plistlib.loads(PLIST.read_bytes())
    assert isinstance(data["ThrottleInterval"], int)
    assert data["ThrottleInterval"] >= 1


def test_plist_environment_points_at_assistant_config():
    data = plistlib.loads(PLIST.read_bytes())
    env = data["EnvironmentVariables"]
    # ZEROCLAW_WORKSPACE is the documented top-level entry point
    # for config resolution (resolve_runtime_config_dirs in
    # crates/zeroclaw-config/src/schema.rs). The placeholder
    # below is replaced by INSTALL_SNIPPET with the path Phase D
    # wrote config.toml at.
    assert env["ZEROCLAW_WORKSPACE"] == "OSTLER_ASSISTANT_CONFIG"


def test_plist_logs_use_placeholder():
    data = plistlib.loads(PLIST.read_bytes())
    assert data["StandardOutPath"] == "OSTLER_LOGS/ostler-assistant.log"
    assert data["StandardErrorPath"] == "OSTLER_LOGS/ostler-assistant.err"


def test_plist_program_arguments_use_placeholder():
    data = plistlib.loads(PLIST.read_bytes())
    assert data["ProgramArguments"][0] == "OSTLER_BIN/ostler-assistant"


def test_plist_working_directory_is_home_placeholder():
    data = plistlib.loads(PLIST.read_bytes())
    assert data["WorkingDirectory"] == "OSTLER_HOME"


# ---------------------------------------------------------------------------
# INSTALL_SNIPPET behaviour
# ---------------------------------------------------------------------------


def _stage_inputs(tmp_path: Path, *, with_binary: bool = True) -> dict:
    """Build a sandbox install root + ostler dir + a stub
    launchctl, then return the env block the snippet expects."""
    install_root = tmp_path / "assistant-agent"
    install_root.mkdir()
    (install_root / "launchd").mkdir()
    (install_root / "launchd" / "com.creativemachines.ostler.assistant.plist").write_bytes(
        PLIST.read_bytes()
    )

    ostler_dir = tmp_path / "ostler"
    bin_dir = ostler_dir / "bin"
    bin_dir.mkdir(parents=True)
    if with_binary:
        binary = bin_dir / "ostler-assistant"
        binary.write_text("#!/bin/sh\nexit 0\n")
        binary.chmod(binary.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    home_dir = tmp_path / "home"
    home_dir.mkdir()
    (home_dir / "Library" / "LaunchAgents").mkdir(parents=True)

    logs_dir = ostler_dir / "logs"
    config_dir = ostler_dir / "assistant-config"
    config_dir.mkdir()

    # Stub launchctl: record args, succeed.
    stub_dir = tmp_path / "stubs"
    stub_dir.mkdir()
    launchctl_log = stub_dir / "launchctl.log"
    launchctl = stub_dir / "launchctl"
    launchctl.write_text(
        textwrap.dedent(
            f"""\
            #!/usr/bin/env bash
            echo "$@" >> {launchctl_log}
            exit 0
            """
        )
    )
    launchctl.chmod(launchctl.stat().st_mode | stat.S_IXUSR)

    return {
        "tmp_path": tmp_path,
        "install_root": install_root,
        "ostler_dir": ostler_dir,
        "home_dir": home_dir,
        "logs_dir": logs_dir,
        "config_dir": config_dir,
        "stub_dir": stub_dir,
        "launchctl_log": launchctl_log,
    }


def _run_snippet(setup: dict) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env.update(
        {
            "HOME": str(setup["home_dir"]),
            "OSTLER_INSTALL_ROOT": str(setup["install_root"]),
            "OSTLER_DIR": str(setup["ostler_dir"]),
            "LOGS_DIR": str(setup["logs_dir"]),
            "ASSISTANT_CONFIG_DIR": str(setup["config_dir"]),
            "PATH": f"{setup['stub_dir']}:{env.get('PATH','')}",
        }
    )
    return subprocess.run(
        ["bash", str(SNIPPET)],
        env=env,
        capture_output=True,
        text=True,
    )


def test_snippet_renders_plist_and_substitutes_every_placeholder(tmp_path):
    setup = _stage_inputs(tmp_path)
    result = _run_snippet(setup)
    assert result.returncode == 0, result.stderr

    rendered = setup["home_dir"] / "Library" / "LaunchAgents" / "com.creativemachines.ostler.assistant.plist"
    text = rendered.read_text()
    # Every placeholder must be substituted -- a stray OSTLER_BIN
    # in the rendered plist would leave the LaunchAgent pointed at
    # a nonexistent path and respawn forever.
    assert "OSTLER_BIN" not in text
    assert "OSTLER_HOME" not in text
    assert "OSTLER_LOGS" not in text
    assert "OSTLER_ASSISTANT_CONFIG" not in text

    data = plistlib.loads(rendered.read_bytes())
    assert data["ProgramArguments"][0] == str(setup["ostler_dir"] / "bin" / "ostler-assistant")
    assert data["EnvironmentVariables"]["ZEROCLAW_WORKSPACE"] == str(setup["config_dir"])
    assert data["StandardOutPath"] == str(setup["logs_dir"] / "ostler-assistant.log")
    assert data["StandardErrorPath"] == str(setup["logs_dir"] / "ostler-assistant.err")
    assert data["WorkingDirectory"] == str(setup["home_dir"])


def test_snippet_calls_launchctl_bootstrap(tmp_path):
    setup = _stage_inputs(tmp_path)
    result = _run_snippet(setup)
    assert result.returncode == 0, result.stderr

    log = setup["launchctl_log"].read_text()
    assert "bootstrap" in log
    assert "com.creativemachines.ostler.assistant.plist" in log


def test_snippet_aborts_when_binary_not_staged(tmp_path):
    setup = _stage_inputs(tmp_path, with_binary=False)
    result = _run_snippet(setup)
    # Binary missing must surface as a clear non-zero exit so the
    # outer installer can warn the operator. A silent skip would
    # leave them with a configured wizard, no daemon, and no
    # signal that the gap exists.
    assert result.returncode != 0, result.stdout
    assert "binary not staged" in result.stderr


def test_snippet_creates_logs_dir_if_absent(tmp_path):
    setup = _stage_inputs(tmp_path)
    # Don't pre-create logs dir.
    assert not setup["logs_dir"].exists()
    result = _run_snippet(setup)
    assert result.returncode == 0, result.stderr
    assert setup["logs_dir"].is_dir()
