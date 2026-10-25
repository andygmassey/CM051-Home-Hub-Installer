"""VENDORED copy of HR015 ostler_fda/tests/test_subscription_gate_parity.py at fd10f28 (#1169);
runs against vendor/ostler_fda. Extra pin: the vendored gate must also equal the CM041 vendored copy.

The ONE G7 subscription gate for ostler_fda sources, and its parity pin.

WHY A COPY
==========
Rule 0.5: ostler_fda never imports another repo's package. The gate already
ships as two byte-identical copies, CM052 ``src/cm052/subscription_gate.py``
and CM041 ``assistant_api/subscription_gate.py`` (both vendored in CM051).
``ostler_fda/subscription_gate.py`` is a third byte-identical copy, not a
second implementation. This test pins its sha256 so the copies cannot drift
silently: when CM052's gate changes, re-copy it byte for byte and re-pin in
the SAME change.

Pinned from CM052 main 1ec0578 (2026-10-19). CM041's vendored copy in CM051
main had the same digest on the same day.

THE CONTRACT the Pro-gated sources (Notion, Linear, GitHub, the Chat export
from Google Takeout) depend on, unchanged from the shell tick wrappers
(CM051 vendor/imessage_source/bin/imessage-bundle-tick.sh):

* in-process: ``ostler_fda.subscription_gate.is_active_or_grace() -> bool``
* subprocess: ``python -m ostler_fda.subscription_gate --check``
  exit 0 = active, keep going; exit 3 = paused (not Pro), stop before
  touching new data; anything else = the check itself failed, so the caller
  FAILS OPEN and logs a line. A customer is never paused because we could
  not ask.

Gate placement (Archie ruling 3): at the ENTRY POINT of a Pro source only,
never inside CM048 processor.process, and never on a free source
(Messenger, Instagram, Telegram).

No real Keychain or TCC is touched: the gate reads one JSON file, pointed
at a tmp path through OSTLER_SUBSCRIPTION_STATE.
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1] / "vendor"
GATE = REPO_ROOT / "ostler_fda" / "subscription_gate.py"

PINNED_SHA256 = "cc5b8989c9e5d8cd8af5b0ef2ff589e8276dd36c51b85635cf76f9923b3ac14d"


def _check(state_path: Path, *args: str) -> subprocess.CompletedProcess:
    env = {k: v for k, v in os.environ.items() if k != "OSTLER_SUBSCRIPTION_STATE"}
    env["OSTLER_SUBSCRIPTION_STATE"] = str(state_path)
    env["PYTHONPATH"] = str(REPO_ROOT)
    return subprocess.run(
        [sys.executable, "-m", "ostler_fda.subscription_gate", *(args or ("--check",))],
        capture_output=True, text=True, env=env, cwd=str(REPO_ROOT), timeout=60,
    )


def _activate(state_path: Path, purchase: datetime) -> None:
    env = {**os.environ, "OSTLER_SUBSCRIPTION_STATE": str(state_path),
           "PYTHONPATH": str(REPO_ROOT)}
    code = ("import sys; from ostler_fda import subscription_gate as g; "
            "g.activate_first_month_free(sys.argv[1])")
    subprocess.run([sys.executable, "-c", code, purchase.isoformat()],
                   check=True, env=env, cwd=str(REPO_ROOT), timeout=60)


def test_gate_is_byte_identical_to_the_pinned_cm052_copy():
    digest = hashlib.sha256(GATE.read_bytes()).hexdigest()
    assert digest == PINNED_SHA256, (
        "ostler_fda/subscription_gate.py drifted from the pinned CM052 copy. "
        "Re-copy CM052 src/cm052/subscription_gate.py byte for byte and "
        "re-pin here in the same change; never edit this copy alone."
    )


def test_gate_has_no_cross_repo_import():
    src = GATE.read_text(encoding="utf-8")
    assert "import cm052" not in src and "from cm052" not in src
    assert "from ." not in src  # stdlib only, so the module runs standalone


def test_check_exits_0_when_active(tmp_path):
    state = tmp_path / "subscription_state.json"
    _activate(state, datetime.now(timezone.utc))
    assert json.loads(state.read_text())["status"] == "active"
    r = _check(state)
    assert r.returncode == 0, r.stderr


def test_check_exits_3_when_inactive_and_names_the_pause(tmp_path):
    state = tmp_path / "subscription_state.json"
    state.write_text(json.dumps({"status": "inactive", "source": "default"}))
    r = _check(state)
    assert r.returncode == 3
    assert "Ostler Pro is not active" in r.stdout


def test_check_exits_3_when_the_trial_has_lapsed(tmp_path):
    # The reader walks the state forward itself: an "active" file whose free
    # month ended long ago must pause, with no ticker involved.
    state = tmp_path / "subscription_state.json"
    _activate(state, datetime.now(timezone.utc) - timedelta(days=400))
    r = _check(state)
    assert r.returncode == 3


def test_missing_state_file_reads_inactive(tmp_path):
    # The gate's own documented default. Callers that must fail OPEN do so on
    # a non-0/3 exit (the check could not run), not on a missing file.
    r = _check(tmp_path / "absent.json")
    assert r.returncode == 3


def test_usage_error_is_neither_0_nor_3(tmp_path):
    # The fail-open branch for callers: a broken invocation must not read as
    # "paused", or a typo would stop a paying customer.
    r = _check(tmp_path / "s.json", "--no-such-flag")
    assert r.returncode not in (0, 3)


def test_in_process_reader_agrees_with_the_cli(tmp_path, monkeypatch):
    sys.path.insert(0, str(REPO_ROOT))
    from ostler_fda import subscription_gate as g

    state = tmp_path / "subscription_state.json"
    monkeypatch.setenv("OSTLER_SUBSCRIPTION_STATE", str(state))
    state.write_text(json.dumps({"status": "inactive", "source": "default"}))
    assert g.is_active_or_grace() is False
    _activate(state, datetime.now(timezone.utc))
    assert g.is_active_or_grace() is True


def test_gate_equals_the_vendored_cm041_copy():
    cm041 = REPO_ROOT / "cm041" / "assistant_api" / "subscription_gate.py"
    assert hashlib.sha256(cm041.read_bytes()).hexdigest() == PINNED_SHA256
