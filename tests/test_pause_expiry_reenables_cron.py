"""A timed Pause that has expired must give the brief and wrap back.

set_pause() switches the daemon cron off; before this fix nothing switched it
back on when the window elapsed, so read_state() said "not paused" while the
09:00 brief and 18:00 wrap never fired again. Synthetic data only.
"""
import os
import sys
import time
from pathlib import Path

import pytest

AGENT = Path(__file__).resolve().parent.parent / "vendor" / "doctor" / "agent"
sys.path.insert(0, str(AGENT))

import pause_control as pc  # noqa: E402

CONFIG_CRON_OFF = """[agent]
name = "x"

[cron]
enabled = false

[[cron.jobs]]
name = "brief"
schedule = "0 9 * * *"
"""


@pytest.fixture
def box(tmp_path, monkeypatch):
    gov = tmp_path / "governor.env"
    cfg = tmp_path / "config.toml"
    cfg.write_text(CONFIG_CRON_OFF, encoding="utf-8")
    sentinel = tmp_path / "restarted"
    monkeypatch.setenv("OSTLER_GOVERNOR_ENV_FILE", str(gov))
    monkeypatch.setenv("OSTLER_CONFIG_FILE", str(tmp_path / "config.yaml"))
    monkeypatch.setenv("OSTLER_ASSISTANT_CONFIG_FILE", str(cfg))
    monkeypatch.setenv("OSTLER_ASSISTANT_RESTART_CMD", f"/usr/bin/touch {sentinel}")
    monkeypatch.delenv("OSTLER_SKIP_DAEMON_RESTART", raising=False)
    monkeypatch.delenv("OSTLER_PAUSE_SKIP_MIRROR", raising=False)
    pc._LAST_RECONCILE_ERROR = None
    return gov, cfg, sentinel


def _expired(gov):
    gov.write_text(
        "export OSTLER_PAUSED=1\nexport OSTLER_PAUSE_UNTIL=%d\n" % (int(time.time()) - 5),
        encoding="utf-8",
    )


def test_expired_pause_turns_the_cron_back_on(box):
    gov, cfg, sentinel = box
    _expired(gov)
    state = pc.read_state(gov)
    assert state["paused"] is False
    assert "enabled = true" in cfg.read_text(encoding="utf-8")
    assert sentinel.exists(), "daemon was not restarted to re-read the cron"
    assert "cron_resume_error" not in state
    assert "OSTLER_PAUSED=0" in gov.read_text(encoding="utf-8")


def test_a_live_pause_leaves_the_cron_off(box):
    gov, cfg, sentinel = box
    gov.write_text(
        "export OSTLER_PAUSED=1\nexport OSTLER_PAUSE_UNTIL=%d\n" % (int(time.time()) + 600),
        encoding="utf-8",
    )
    assert pc.read_state(gov)["paused"] is True
    assert "enabled = false" in cfg.read_text(encoding="utf-8")
    assert not sentinel.exists()


def test_a_failed_cron_resume_is_reported_and_retried(box, monkeypatch):
    gov, cfg, sentinel = box
    cfg.write_text("[cron\nbroken", encoding="utf-8")  # invalid TOML: apply refuses
    _expired(gov)
    state = pc.read_state(gov)
    assert state["paused"] is False
    assert "daemon cron not updated" in state["cron_resume_error"]
    # governor.env is left alone so the next poll retries
    assert "OSTLER_PAUSE_UNTIL" in gov.read_text(encoding="utf-8")
    cfg.write_text(CONFIG_CRON_OFF, encoding="utf-8")
    state2 = pc.read_state(gov)
    assert "cron_resume_error" not in state2
    assert "enabled = true" in cfg.read_text(encoding="utf-8")
