#!/usr/bin/env python3
"""Tests for the (B-lite) upgrade audit-trail Doctor row.

Proves ``check_last_upgrade`` reads the durable, reboot-surviving
upgrade result the Hub records at ``~/.ostler/preferences.json`` and
turns it into exactly one Doctor row (or none, quietly, on a legacy
or malformed install). The rule is READ-ONLY: these tests also assert
a malformed preferences.json is left byte-for-byte untouched.

Everything is synthetic (PRODUCTISATION_CHECKLIST Rule 0): a tmp dir
stood in for HOME, a fabricated preferences.json, no real Hub.

Run: ``python3 vendor/doctor/agent/test_diagnostic_rules.py`` (bare,
no deps) or under pytest.
"""

import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import diagnostic_copy as dc  # noqa: E402
import diagnostic_rules as dr  # noqa: E402


# Sentinel distinguishing "omit the last_upgrade_result key entirely"
# from "write an explicit null".
_OMIT = object()


def _write_prefs(home, result):
    """Write ~/.ostler/preferences.json under a fake HOME.

    ``result`` is the value for ``last_upgrade_result``; pass ``_OMIT``
    to leave the key out altogether. Returns the file path.
    """
    ostler = Path(home) / ".ostler"
    ostler.mkdir(parents=True, exist_ok=True)
    prefs = {"auto_apply_updates": False}
    if result is not _OMIT:
        prefs["last_upgrade_result"] = result
    path = ostler / "preferences.json"
    path.write_text(json.dumps(prefs, indent=2), encoding="utf-8")
    return path


def _run_with_home(home):
    """Run check_last_upgrade with HOME pointed at ``home``.

    The snapshot arg is unused (the rule reads from disk), so we pass
    None. HOME is restored afterwards.
    """
    old = dict(os.environ)
    try:
        os.environ["HOME"] = str(home)
        return dr.check_last_upgrade(None)
    finally:
        os.environ.clear()
        os.environ.update(old)


def test_success_emits_one_info_finding_with_formatted_time():
    with tempfile.TemporaryDirectory() as home:
        _write_prefs(home, {
            "version": "1.0.12",
            "timestamp": "2026-07-27T14:23:11Z",
            "status": "success",
        })
        findings = _run_with_home(home)

        assert len(findings) == 1, "success emits exactly one finding"
        f = findings[0]
        assert f["severity"] == "info", "success is info severity"
        assert f["category"] == "upgrade", "category is upgrade"
        assert f["risk"] == "low", "risk is low"
        assert f["fix"] is None, "success carries no fix guidance"
        assert f["fix_command"] is None, "success carries no fix command"
        assert "1.0.12" in f["title"], "title contains the version"

        detail = f["detail"]
        # The applied clause is rendered, and the raw ISO markers never
        # leak: no "T" separator and no "Z" zulu suffix in the detail.
        assert "2026-07-27 14:23" in detail, "applied time is formatted"
        assert "T" not in detail, "no raw 'T' ISO separator in detail"
        assert "Z" not in detail, "no raw 'Z' zulu suffix in detail"


def test_failed_emits_one_warning_finding():
    with tempfile.TemporaryDirectory() as home:
        _write_prefs(home, {
            "version": "1.0.12",
            "timestamp": "2026-07-27T14:23:11Z",
            "status": "failed",
        })
        findings = _run_with_home(home)

        assert len(findings) == 1, "failed emits exactly one finding"
        f = findings[0]
        assert f["severity"] == "warning", "failed is warning severity"
        assert f["category"] == "upgrade", "category is upgrade"
        assert f["fix"] is not None, "failed offers guidance text"
        assert f["fix_command"] is None, "failed offers no destructive command"


def test_rolled_back_emits_one_warning_mentioning_previous_version():
    with tempfile.TemporaryDirectory() as home:
        _write_prefs(home, {
            "version": "1.0.12",
            "timestamp": "2026-07-27T14:23:11Z",
            "status": "rolled-back",
        })
        findings = _run_with_home(home)

        assert len(findings) == 1, "rolled-back emits exactly one finding"
        f = findings[0]
        assert f["severity"] == "warning", "rolled-back is warning severity"
        assert f["category"] == "upgrade", "category is upgrade"
        assert f["fix_command"] is None, "rolled-back offers no command"

        detail = f["detail"]
        assert "previous" in detail.lower(), "detail mentions the previous version"
        assert "running" in detail.lower(), "detail says it is running"
        assert "1.0.12" in detail, "detail names the version that did not install"


def test_missing_file_is_quiet():
    with tempfile.TemporaryDirectory() as home:
        # No preferences.json written at all.
        findings = _run_with_home(home)
        assert findings == [], "missing file returns no findings, no exception"


def test_malformed_json_is_quiet_and_leaves_file_untouched():
    with tempfile.TemporaryDirectory() as home:
        ostler = Path(home) / ".ostler"
        ostler.mkdir(parents=True, exist_ok=True)
        path = ostler / "preferences.json"
        bad = '{ "auto_apply_updates": false, "last_upgrade_result": {{{ '
        path.write_text(bad, encoding="utf-8")

        findings = _run_with_home(home)
        assert findings == [], "malformed JSON returns no findings, no exception"
        assert path.read_text(encoding="utf-8") == bad, (
            "malformed preferences.json is left byte-for-byte untouched "
            "(read-only rule)"
        )


def test_missing_last_upgrade_result_key_is_quiet():
    with tempfile.TemporaryDirectory() as home:
        _write_prefs(home, _OMIT)  # valid file, no last_upgrade_result key
        findings = _run_with_home(home)
        assert findings == [], "absent last_upgrade_result returns no findings"


def test_unknown_status_is_quiet():
    with tempfile.TemporaryDirectory() as home:
        _write_prefs(home, {
            "version": "1.0.12",
            "timestamp": "2026-07-27T14:23:11Z",
            "status": "in-progress",  # not one of success/failed/rolled-back
        })
        findings = _run_with_home(home)
        assert findings == [], "unknown status is not guessed; no findings"


def test_malformed_timestamp_still_emits_without_crash_and_omits_time():
    with tempfile.TemporaryDirectory() as home:
        _write_prefs(home, {
            "version": "1.0.12",
            "timestamp": "not-a-timestamp",
            "status": "success",
        })
        findings = _run_with_home(home)

        assert len(findings) == 1, "malformed timestamp still emits the finding"
        detail = findings[0]["detail"]
        # The applied clause is omitted; the no-time copy is used and the
        # raw timestamp never appears.
        assert detail == dc.LAST_UPGRADE_SUCCESS_DETAIL_NO_TIME, (
            "applied-time clause is omitted on an unparseable timestamp"
        )
        assert "not-a-timestamp" not in detail, "raw timestamp is not shown"
        assert "T" not in detail and "Z" not in detail, "no ISO markers leak"


def main():
    failures = []
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"ok: {name}")
            except AssertionError as exc:
                print(f"FAIL: {name}: {exc}", file=sys.stderr)
                failures.append(name)
    if failures:
        print(f"\n{len(failures)} FAILURE(S)", file=sys.stderr)
        sys.exit(1)
    print("\nALL UPGRADE AUDIT-TRAIL ROW TESTS PASSED")


if __name__ == "__main__":
    main()
