"""The G7 subscription gate ships as several byte-identical copies. They are ONE gate.

Rule 0.5 keeps each package from importing another repo's code, so the gate
is copied rather than shared. Copies in this repo:

* vendor/cm041/assistant_api/subscription_gate.py   (staged to
  services/ical-server/, read by the shell tick wrappers)
* vendor/cm052_ai_conversations/src/cm052/subscription_gate.py
* vendor/ostler_fda/subscription_gate.py             (the helper for Pro-gated
  ostler_fda sources: the Google Takeout Chat export, Notion, Linear, GitHub)

This test fails if any copy drifts from the others, or from the pinned digest
(CM052 main 1ec0578, 2026-10-19; HR015 ostler_fda/tests/
test_subscription_gate_parity.py pins the same digest). To change the gate,
change the CM052 source, re-copy it byte for byte to every path below, and
re-pin in the same change.

The CONTRACT ostler_fda callers rely on (same as
vendor/imessage_source/bin/imessage-bundle-tick.sh):
in-process ``ostler_fda.subscription_gate.is_active_or_grace() -> bool``;
or ``python subscription_gate.py --check``: exit 0 = active, 3 = paused (not
Pro: send nothing, leave the ledger untouched), anything else = the check
failed, so FAIL OPEN with a log line.

Synthetic state only, through OSTLER_SUBSCRIPTION_STATE; no Keychain, no TCC.
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
COPIES = (
    REPO / "vendor" / "cm041" / "assistant_api" / "subscription_gate.py",
    REPO / "vendor" / "cm052_ai_conversations" / "src" / "cm052" / "subscription_gate.py",
    REPO / "vendor" / "ostler_fda" / "subscription_gate.py",
)
FDA_GATE = COPIES[2]
PINNED_SHA256 = "cc5b8989c9e5d8cd8af5b0ef2ff589e8276dd36c51b85635cf76f9923b3ac14d"


def _env(state: Path) -> dict:
    env = {k: v for k, v in os.environ.items() if k != "OSTLER_SUBSCRIPTION_STATE"}
    env["OSTLER_SUBSCRIPTION_STATE"] = str(state)
    return env


def _check(state: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(FDA_GATE), *(args or ("--check",))],
                          capture_output=True, text=True, env=_env(state), timeout=60)


def _activate(state: Path, purchase: datetime) -> None:
    code = ("import sys, importlib.util as u; s=u.spec_from_file_location('g', sys.argv[1]); "
            "m=u.module_from_spec(s); s.loader.exec_module(m); m.activate_first_month_free(sys.argv[2])")
    subprocess.run([sys.executable, "-c", code, str(FDA_GATE), purchase.isoformat()],
                   check=True, env=_env(state), timeout=60)


def test_every_copy_exists():
    missing = [str(p.relative_to(REPO)) for p in COPIES if not p.is_file()]
    assert not missing, f"gate copies missing: {missing}"


def test_every_copy_is_byte_identical_and_pinned():
    digests = {str(p.relative_to(REPO)): hashlib.sha256(p.read_bytes()).hexdigest() for p in COPIES}
    drifted = {k: v for k, v in digests.items() if v != PINNED_SHA256}
    assert not drifted, f"gate copies drifted from the pinned digest: {drifted}"


def test_check_exits_0_when_active(tmp_path):
    state = tmp_path / "s.json"
    _activate(state, datetime.now(timezone.utc))
    r = _check(state)
    assert r.returncode == 0, r.stderr


def test_check_exits_3_when_inactive(tmp_path):
    state = tmp_path / "s.json"
    state.write_text(json.dumps({"status": "inactive", "source": "default"}))
    r = _check(state)
    assert r.returncode == 3
    assert "Ostler Pro is not active" in r.stdout


def test_check_exits_3_when_the_free_month_lapsed(tmp_path):
    state = tmp_path / "s.json"
    _activate(state, datetime.now(timezone.utc) - timedelta(days=400))
    assert _check(state).returncode == 3


def test_usage_error_is_neither_0_nor_3(tmp_path):
    # The caller's fail-open branch: a broken call must never read as paused.
    assert _check(tmp_path / "s.json", "--no-such-flag").returncode not in (0, 3)
