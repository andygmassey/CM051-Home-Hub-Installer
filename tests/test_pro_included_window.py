"""The Hub's included Ostler Pro window: 180 days founding, 90 days standard.

Decided pricing: Hub $99 includes Pro for 6 months (founding customers) or
3 months (standard). The Hub used to grant 30 DAYS. These tests drive the
real gate module (the cm041 copy install.sh imports) through the real writer
(``activate_included_pro``), the real receipt writer and the real reader, with
synthetic state only (OSTLER_SUBSCRIPTION_STATE). No keychain, no TCC.

Limbs:
  A  window length   founding 180d, standard 90d, measured from activation
  B  tier selection  explicit plan wins; no signal or junk -> founding default
  C  receipt truth   a valid Apple receipt wins; reinstall never overwrites it
  D  upgrade         a running 30-day window is extended once, from its
                     original activation date, and a second pass changes nothing
  E  install.sh      calls the renamed writer, no "first month" wording left
"""
from __future__ import annotations

import importlib.util
import json
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
GATE = REPO / "vendor" / "cm041" / "assistant_api" / "subscription_gate.py"
T0 = datetime(2026, 11, 1, 12, 0, 0, tzinfo=timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.isoformat().replace("+00:00", "Z")


@pytest.fixture()
def gate(tmp_path, monkeypatch):
    state = tmp_path / "subscription_state.json"
    monkeypatch.setenv("OSTLER_SUBSCRIPTION_STATE", str(state))
    spec = importlib.util.spec_from_file_location("sg_under_test", GATE)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["sg_under_test"] = mod
    spec.loader.exec_module(mod)
    mod._test_state_path = state
    return mod


def _activate(gate, plan=None, at=T0, **kw):
    fn = getattr(gate, "activate_included_pro")
    if plan is not None:
        kw["included_plan"] = plan
    fn(_iso(at), **kw)
    return json.loads(gate._test_state_path.read_text())


def _expires(state) -> datetime:
    return datetime.fromisoformat(state["expires_at"].replace("Z", "+00:00"))


def _at(gate, monkeypatch, when: datetime):
    monkeypatch.setattr(gate, "_now", lambda: when)


# ---- A: window length ------------------------------------------------------

def test_a_default_window_is_180_days(gate):
    st = _activate(gate)
    assert _expires(st) == T0 + timedelta(days=180)


def test_a_founding_window_is_180_days(gate):
    st = _activate(gate, "founding")
    assert _expires(st) == T0 + timedelta(days=180)


def test_a_standard_window_is_90_days(gate):
    st = _activate(gate, "standard")
    assert _expires(st) == T0 + timedelta(days=90)


def test_a_window_is_a_customer_outcome_not_a_field(gate, monkeypatch):
    _activate(gate, "standard")
    _at(gate, monkeypatch, T0 + timedelta(days=89))
    assert gate.is_active_or_grace() is True
    _at(gate, monkeypatch, T0 + timedelta(days=91))
    assert gate.is_active_or_grace() is False  # never paid: no grace

    gate._test_state_path.unlink()
    _activate(gate, "founding")
    _at(gate, monkeypatch, T0 + timedelta(days=179))
    assert gate.is_active_or_grace() is True
    _at(gate, monkeypatch, T0 + timedelta(days=181))
    assert gate.is_active_or_grace() is False


# ---- B: tier selection -----------------------------------------------------

def test_b_plan_is_recorded(gate):
    assert _activate(gate, "standard")["included_plan"] == "standard"


def test_b_no_signal_defaults_to_founding_and_says_so(gate):
    st = _activate(gate)
    assert st["included_plan"] == "founding"
    assert gate.DEFAULT_INCLUDED_PLAN == "founding"


@pytest.mark.parametrize("junk", ["", "FOUNDING ", "gold", "0", "180"])
def test_b_unrecognised_plan_falls_back_to_default_not_crash(gate, junk):
    st = _activate(gate, junk)
    assert st["included_plan"] == gate.DEFAULT_INCLUDED_PLAN
    assert _expires(st) == T0 + timedelta(days=180)


def test_b_beta_licence_window_still_wins_over_included_plan(gate):
    lic = T0 + timedelta(days=45)
    st = _activate(
        gate, "founding", licence_tier="beta", licence_tier_state="known",
        licence_expires_at=_iso(lic),
    )
    assert _expires(st) == lic


# ---- C: the receipt is the truth ------------------------------------------

def test_c_receipt_replaces_included_window(gate, monkeypatch):
    _activate(gate, "founding")
    rx_exp = T0 + timedelta(days=30)
    gate.refresh_from_companion("cmVjZWlwdA==", _iso(rx_exp))
    st = json.loads(gate._test_state_path.read_text())
    assert st["source"] == "companion" and _expires(st) == rx_exp
    # Past the receipt's own expiry + grace the owner is paused, even though
    # the 180-day included window would still have been running.
    _at(gate, monkeypatch, T0 + timedelta(days=30 + 14 + 1))
    assert gate.is_active_or_grace() is False


def test_c_reinstall_does_not_overwrite_a_receipt(gate):
    _activate(gate, "founding")
    rx_exp = T0 + timedelta(days=400)
    gate.refresh_from_companion("cmVjZWlwdA==", _iso(rx_exp))
    before = json.loads(gate._test_state_path.read_text())
    st = _activate(gate, "founding", at=T0 + timedelta(days=5))
    assert st["source"] == "companion"
    assert st["receipt"] == before["receipt"]
    assert st["expires_at"] == before["expires_at"]


def test_c_upgrade_never_touches_a_receipt_state(gate, monkeypatch):
    gate.refresh_from_companion("cmVjZWlwdA==", _iso(T0 + timedelta(days=10)))
    before = json.loads(gate._test_state_path.read_text())
    _at(gate, monkeypatch, T0 + timedelta(days=1))
    gate.expire_check()
    after = json.loads(gate._test_state_path.read_text())
    assert after["expires_at"] == before["expires_at"]
    assert "included_days" not in after


# ---- D: upgraders ----------------------------------------------------------

def _legacy_30_day_state(gate, activated: datetime, status="active", **extra):
    exp = activated + timedelta(days=30)
    st = {
        "status": status,
        "last_validated_at": _iso(activated),
        "expires_at": _iso(exp),
        "grace_period_end": _iso(exp + timedelta(days=14)),
        "source": "first_month_free",
        "has_ever_paid": False,
        "licence_tier": "hub",
        "licence_tier_state": "known",
    }
    st.update(extra)
    gate._test_state_path.parent.mkdir(parents=True, exist_ok=True)
    gate._test_state_path.write_text(json.dumps(st))
    return st


def test_d_running_30_day_window_is_extended_from_original_activation(gate, monkeypatch):
    _legacy_30_day_state(gate, T0)
    _at(gate, monkeypatch, T0 + timedelta(days=10))
    gate.expire_check()
    st = json.loads(gate._test_state_path.read_text())
    assert _expires(st) == T0 + timedelta(days=180)  # NOT now+180
    assert st["included_days"] == 180


def test_d_reader_alone_extends_without_the_ticker(gate, monkeypatch):
    _legacy_30_day_state(gate, T0)
    _at(gate, monkeypatch, T0 + timedelta(days=45))  # past the old 30d end
    assert gate.is_active_or_grace() is True


def test_d_extension_is_idempotent(gate, monkeypatch):
    _legacy_30_day_state(gate, T0)
    _at(gate, monkeypatch, T0 + timedelta(days=10))
    gate.expire_check()
    first = gate._test_state_path.read_text()
    _at(gate, monkeypatch, T0 + timedelta(days=60))
    gate.expire_check()
    gate.expire_check()
    assert gate._test_state_path.read_text() == first


def test_d_already_lapsed_legacy_window_inside_new_one_is_restored(gate, monkeypatch):
    _legacy_30_day_state(gate, T0, status="inactive")
    _at(gate, monkeypatch, T0 + timedelta(days=45))
    assert gate.is_active_or_grace() is True


def test_d_legacy_window_past_even_the_new_end_stays_ended(gate, monkeypatch):
    _legacy_30_day_state(gate, T0, status="inactive")
    _at(gate, monkeypatch, T0 + timedelta(days=200))
    assert gate.is_active_or_grace() is False


def test_d_beta_window_is_not_extended(gate, monkeypatch):
    lic = T0 + timedelta(days=45)
    _legacy_30_day_state(gate, T0, licence_tier="beta")
    st = json.loads(gate._test_state_path.read_text())
    st["expires_at"] = _iso(lic)
    gate._test_state_path.write_text(json.dumps(st))
    _at(gate, monkeypatch, T0 + timedelta(days=10))
    gate.expire_check()
    assert _expires(json.loads(gate._test_state_path.read_text())) == lic


def test_d_reinstall_keeps_the_original_activation_date(gate, monkeypatch):
    _activate(gate, "founding", at=T0)
    st = _activate(gate, "founding", at=T0 + timedelta(days=100))
    assert _expires(st) == T0 + timedelta(days=180)


def test_d_standard_upgrader_is_extended_to_90(gate, monkeypatch):
    _legacy_30_day_state(gate, T0, included_plan="standard")
    _at(gate, monkeypatch, T0 + timedelta(days=10))
    gate.expire_check()
    assert _expires(json.loads(gate._test_state_path.read_text())) == T0 + timedelta(days=90)


# ---- E: install.sh and strings --------------------------------------------

def test_e_install_calls_the_renamed_writer_and_no_first_month_wording():
    text = (REPO / "install.sh").read_text()
    strings = (REPO / "install.sh.strings.en-GB.sh").read_text()
    assert "activate_included_pro" in text
    for blob, name in ((text, "install.sh"), (strings, "strings")):
        assert "activate_first_month_free" not in blob, name
        assert "FIRST_MONTH_FREE" not in blob, name
        assert not re.search(r"first (30 days|month)", blob, re.I), name
    assert "MSG_INFO_INCLUDED_PRO_ACTIVATING" in strings


def test_e_every_msg_key_install_uses_for_this_exists():
    text = (REPO / "install.sh").read_text()
    strings = (REPO / "install.sh.strings.en-GB.sh").read_text()
    for key in re.findall(r"\$\{?(MSG_[A-Z_]*INCLUDED_PRO[A-Z_]*)", text):
        assert re.search(rf"^{key}=", strings, re.M), key


def test_e_three_vendored_copies_are_one():
    paths = [
        REPO / "vendor/cm041/assistant_api/subscription_gate.py",
        REPO / "vendor/cm052_ai_conversations/src/cm052/subscription_gate.py",
        REPO / "vendor/ostler_fda/subscription_gate.py",
    ]
    assert len({p.read_bytes() for p in paths}) == 1
