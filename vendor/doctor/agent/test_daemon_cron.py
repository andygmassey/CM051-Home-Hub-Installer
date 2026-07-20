#!/usr/bin/env python3
"""Tests for the daemon cron pause bridge (Batch-2 review #6 F1).

Proves the Doctor "Pause" reaches the ASSISTANT DAEMON'S cron scheduler,
not just the shell governor: on Pause we set ``[cron].enabled = false`` in
the daemon ``config.toml`` (the exact field the daemon reads at
``daemon/mod.rs`` ``if config.cron.enabled { spawn scheduler }`` -- so a
false value means the scheduler supervisor never starts and the 09:00
brief never fires) and restart the daemon in place. On resume we set it
back to ``true``.

Everything is synthetic (PRODUCTISATION_CHECKLIST Rule 0): tmp config
files, a captured restart command, no real daemon.

Run: ``python3 vendor/doctor/agent/test_daemon_cron.py`` (bare, no deps)
or under pytest.
"""

import os
import sys
import tempfile
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import daemon_cron as dc  # noqa: E402


# Two-job config as install.sh emits it: [[cron.jobs]] with NO [cron]
# table, so cron.enabled defaults true.
CONFIG_JOBS_NO_CRON_TABLE = '''\
model = "qwen3.5:9b"

[providers]
fallback = "ollama"

[[cron.jobs]]
id = "morning-brief"
name = "Morning brief"
job_type = "agent"
schedule = { kind = "cron", expr = "0 9 * * *", tz = "Europe/London" }
prompt = "brief"
delivery = { mode = "announce", channel = "imessage", to = "+447700900111", best_effort = false }

[[cron.jobs]]
id = "evening-wrap"
name = "Evening wrap"
job_type = "agent"
schedule = { kind = "cron", expr = "0 18 * * *", tz = "Europe/London" }
prompt = "wrap"
delivery = { mode = "announce", channel = "imessage", to = "+447700900111", best_effort = false }
'''

# A config that already carries a [cron] table with enabled = true.
CONFIG_CRON_TABLE_ENABLED = '''\
[cron]
enabled = true
catch_up_on_startup = true

[[cron.jobs]]
id = "morning-brief"
job_type = "agent"
schedule = { kind = "cron", expr = "0 9 * * *", tz = "Europe/London" }
prompt = "brief"
'''

# A config with a [cron] table but no explicit enabled key (defaults true).
CONFIG_CRON_TABLE_NO_ENABLED = '''\
[cron]
catch_up_on_startup = true

[[cron.jobs]]
id = "morning-brief"
job_type = "agent"
schedule = { kind = "cron", expr = "0 9 * * *", tz = "Europe/London" }
prompt = "brief"
'''

# No cron at all.
CONFIG_NO_CRON = '''\
model = "qwen3.5:9b"

[providers]
fallback = "ollama"
'''

FAILURES = []


def check(cond, msg):
    if cond:
        print(f"ok: {msg}")
    else:
        print(f"FAIL: {msg}", file=sys.stderr)
        FAILURES.append(msg)


def _write(tmp, text):
    p = Path(tmp) / "config.toml"
    p.write_text(text, encoding="utf-8")
    return p


def _apply(p, paused, sentinel):
    """Run apply_pause_to_cron with a captured restart command."""
    old = dict(os.environ)
    try:
        # Restart writes a sentinel so we can prove it was invoked.
        os.environ["OSTLER_ASSISTANT_RESTART_CMD"] = f"/usr/bin/touch {sentinel}"
        os.environ.pop("OSTLER_SKIP_DAEMON_RESTART", None)
        return dc.apply_pause_to_cron(paused, config_path=p)
    finally:
        os.environ.clear()
        os.environ.update(old)


def test_pause_disables_cron_and_restarts():
    for label, text in (
        ("jobs-no-cron-table", CONFIG_JOBS_NO_CRON_TABLE),
        ("cron-table-enabled", CONFIG_CRON_TABLE_ENABLED),
        ("cron-table-no-enabled", CONFIG_CRON_TABLE_NO_ENABLED),
    ):
        with tempfile.TemporaryDirectory() as tmp:
            p = _write(tmp, text)
            sentinel = Path(tmp) / "restarted"
            before_jobs = len(tomllib.loads(text).get("cron", {}).get("jobs", []))

            res = _apply(p, True, sentinel)
            data = tomllib.loads(p.read_text(encoding="utf-8"))

            # The daemon-side gate: cron.enabled is the field
            # daemon/mod.rs reads to decide whether to spawn the
            # scheduler. false => scheduler never starts => no fire.
            check(
                data.get("cron", {}).get("enabled") is False,
                f"[{label}] pause sets cron.enabled = false (daemon spawn gate)",
            )
            check(res.get("changed") is True, f"[{label}] pause reports changed")
            check(
                sentinel.exists(),
                f"[{label}] pause restarts the daemon so it re-reads config",
            )
            # Jobs preserved -- we never dropped the operator's briefs.
            after_jobs = len(data.get("cron", {}).get("jobs", []))
            check(
                after_jobs == before_jobs,
                f"[{label}] cron jobs preserved ({after_jobs} == {before_jobs})",
            )
            # Result still parses as valid TOML (implicit above) and the
            # file is not reformatted beyond the enabled line.
            check(
                data.get("cron", {}).get("jobs", [{}])[0].get("id")
                == "morning-brief",
                f"[{label}] first job identity intact after edit",
            )


def test_resume_reenables_cron_and_restarts():
    with tempfile.TemporaryDirectory() as tmp:
        # Start paused (cron disabled), then resume.
        p = _write(tmp, CONFIG_JOBS_NO_CRON_TABLE)
        s1 = Path(tmp) / "r1"
        _apply(p, True, s1)
        assert tomllib.loads(p.read_text())["cron"]["enabled"] is False

        s2 = Path(tmp) / "r2"
        res = _apply(p, False, s2)
        data = tomllib.loads(p.read_text(encoding="utf-8"))
        check(
            data.get("cron", {}).get("enabled") is True,
            "resume sets cron.enabled = true (scheduler starts again)",
        )
        check(res.get("changed") is True, "resume reports changed")
        check(s2.exists(), "resume restarts the daemon")


def test_idempotent_no_restart_when_already_in_state():
    with tempfile.TemporaryDirectory() as tmp:
        # Config already has cron enabled; resuming (unpause) is a no-op.
        p = _write(tmp, CONFIG_CRON_TABLE_ENABLED)
        sentinel = Path(tmp) / "restarted"
        res = _apply(p, False, sentinel)
        check(
            res.get("changed") is False,
            "resume on an already-enabled config is a no-op (changed False)",
        )
        check(
            not sentinel.exists(),
            "no-op does not restart the daemon",
        )


def test_no_cron_is_noop():
    with tempfile.TemporaryDirectory() as tmp:
        p = _write(tmp, CONFIG_NO_CRON)
        sentinel = Path(tmp) / "restarted"
        res = _apply(p, True, sentinel)
        check(
            res.get("changed") is False,
            "a config with no cron jobs is a no-op on pause",
        )
        check(not sentinel.exists(), "no-cron pause does not restart the daemon")
        # And the file is untouched.
        check(
            p.read_text(encoding="utf-8") == CONFIG_NO_CRON,
            "no-cron config.toml is left byte-for-byte untouched",
        )


def test_missing_config_is_noop():
    with tempfile.TemporaryDirectory() as tmp:
        p = Path(tmp) / "config.toml"  # not written
        res = dc.apply_pause_to_cron(True, config_path=p)
        check(
            res.get("changed") is False and res.get("reason") == "no daemon config",
            "absent daemon config is a graceful no-op",
        )


def test_malformed_toml_fails_closed():
    with tempfile.TemporaryDirectory() as tmp:
        bad = "this is = = not valid toml [[["
        p = _write(tmp, bad)
        sentinel = Path(tmp) / "restarted"
        raised = False
        try:
            _apply(p, True, sentinel)
        except dc.DaemonCronError:
            raised = True
        check(raised, "malformed daemon config.toml raises rather than being edited")
        check(
            p.read_text(encoding="utf-8") == bad,
            "malformed config.toml is left untouched (fail-closed)",
        )
        check(not sentinel.exists(), "no restart on a fail-closed refusal")


def test_skip_restart_env():
    with tempfile.TemporaryDirectory() as tmp:
        p = _write(tmp, CONFIG_JOBS_NO_CRON_TABLE)
        old = dict(os.environ)
        try:
            os.environ["OSTLER_SKIP_DAEMON_RESTART"] = "1"
            os.environ.pop("OSTLER_ASSISTANT_RESTART_CMD", None)
            res = dc.apply_pause_to_cron(True, config_path=p)
        finally:
            os.environ.clear()
            os.environ.update(old)
        check(res.get("changed") is True, "skip-restart still edits config")
        check(
            res.get("restart", {}).get("restarted") is False
            and res.get("restart", {}).get("reason") == "skipped",
            "OSTLER_SKIP_DAEMON_RESTART=1 skips the restart",
        )


def main():
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    if FAILURES:
        print(f"\n{len(FAILURES)} FAILURE(S)", file=sys.stderr)
        sys.exit(1)
    print("\nALL DAEMON-CRON BRIDGE TESTS PASSED")


if __name__ == "__main__":
    main()
