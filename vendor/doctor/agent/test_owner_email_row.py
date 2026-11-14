"""Doctor row: "Ostler doesn't know which email address is yours" (RED first).

Arms: no accounts (status none) gives the row; a missing file after setup gives
the row; a control with addresses gives no row; unreadable gives a DISTINCT
"couldn't check" row; the setter writes the file at 0600 and round-trips.
Synthetic data only.
"""
from __future__ import annotations

import json
import os
import stat
from types import SimpleNamespace

import pytest

import owner_email
import diagnostic_rules as dr

ADDR = "owner" + "@" + "example" + ".com"


def _snap(state, *, installed=True):
    ps = SimpleNamespace(install_completed_ts=1700000000 if installed else None,
                         mail_has_fetched=True, first_ingest_complete_ts=None)
    return SimpleNamespace(owner_addresses_state=state, pipeline_signals=ps,
                           backfill_checkpoint=None)


def _titles(findings):
    return [f.get("title") for f in findings]


def test_no_accounts_gives_the_doesnt_know_row():
    rows = dr.check_owner_email(_snap({"status": "none", "addresses": []}))
    assert len(rows) == 1
    assert rows[0]["title"] == "Ostler doesn't know which email address is yours"


def test_missing_file_after_setup_gives_the_doesnt_know_row():
    rows = dr.check_owner_email(_snap(None, installed=True))
    assert _titles(rows) == ["Ostler doesn't know which email address is yours"]


def test_missing_file_before_setup_gives_no_row():
    assert dr.check_owner_email(_snap(None, installed=False)) == []


def test_control_with_addresses_gives_no_row():
    assert dr.check_owner_email(_snap({"status": "ok", "addresses": [ADDR]})) == []


def test_unreadable_gives_a_distinct_couldnt_check_row():
    rows = dr.check_owner_email(_snap({"status": "unreadable", "addresses": []}))
    assert len(rows) == 1
    assert rows[0]["title"] == "Ostler couldn't check which email address is yours"
    assert rows[0]["title"] != "Ostler doesn't know which email address is yours"


def test_copy_asks_nothing_technical():
    for row in dr.check_owner_email(_snap({"status": "none", "addresses": []})):
        text = " ".join(str(v) for v in row.values()).lower()
        for banned in ("terminal", "command", "config", "yaml", "json", "file", "plist"):
            assert banned not in text, banned
        assert row.get("fix_command") in (None, "")


def test_setter_writes_0600_and_round_trips(tmp_path):
    path = tmp_path / "owner_addresses.json"
    owner_email.write_owner_addresses([ADDR], path=path)
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    assert owner_email.read_owner_state(path)["addresses"] == [ADDR]


def test_setter_refuses_junk(tmp_path):
    path = tmp_path / "owner_addresses.json"
    with pytest.raises(ValueError):
        owner_email.write_owner_addresses(["not an address"], path=path)
    assert not path.exists()


def test_reader_reports_corrupt_file_as_unreadable(tmp_path):
    path = tmp_path / "owner_addresses.json"
    path.write_text("{not json")
    assert owner_email.read_owner_state(path)["status"] == "unreadable"


LOOPBACK = ("127.0.0.1", 50000)


def _as_owner(monkeypatch, web_ui):
    """The vendored Doctor gates every non-public route to the owner. The positive
    arms run as the owner; the unauthenticated arm does NOT patch the gate."""
    async def _owner(request):
        return None
    monkeypatch.setattr(web_ui, "_owner_refusal", _owner)


def test_setter_route_writes_the_file_and_refuses_cross_site(tmp_path, monkeypatch):
    fastapi_testclient = pytest.importorskip("fastapi.testclient")
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path))
    import web_ui
    _as_owner(monkeypatch, web_ui)
    client = fastapi_testclient.TestClient(web_ui.app, client=LOOPBACK)
    ok = client.post("/api/v1/owner-email", json={"addresses": [ADDR]})
    assert ok.status_code == 200 and ok.json() == {"status": "ok", "count": 1}
    assert owner_email.read_owner_state(tmp_path / "state" / "owner_addresses.json")["addresses"] == [ADDR]
    assert ADDR not in ok.text
    refused = client.post("/api/v1/owner-email", json={"addresses": [ADDR]},
                          headers={"Sec-Fetch-Site": "cross-site"})
    assert refused.status_code == 403
    bad = client.post("/api/v1/owner-email", json={"addresses": ["nope"]})
    assert bad.status_code == 400


def test_unauthenticated_caller_is_refused_and_writes_nothing(tmp_path, monkeypatch):
    # The owner gate: a caller that is not on this Mac gets 403 and no file.
    fastapi_testclient = pytest.importorskip("fastapi.testclient")
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path))
    import web_ui
    client = fastapi_testclient.TestClient(web_ui.app, client=("203.0.113.7", 50000))
    r = client.post("/api/v1/owner-email", json={"addresses": [ADDR]})
    assert r.status_code == 403
    assert not (tmp_path / "state" / "owner_addresses.json").exists()


def test_rendered_row_submit_writes_file_and_row_clears(tmp_path, monkeypatch):
    """Rendered-page arm: the row shows the input; submitting writes 0600; the row clears."""
    fastapi_testclient = pytest.importorskip("fastapi.testclient")
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path))
    import web_ui
    from status_collector import SystemSnapshot
    _as_owner(monkeypatch, web_ui)

    snap = SystemSnapshot(services=[], docker_containers=[], ollama_models=[],
                          disk_usage=[], hostname="testhost", os_version="Darwin 25.0",
                          owner_addresses_state={"status": "none", "addresses": []})
    findings = dr.check_owner_email(snap)
    html = web_ui.render_dashboard(snap, findings)
    assert "Ostler doesn't know which email address is yours" in html
    assert 'type="email"' in html and 'name="owner-email"' in html
    assert "Your email address" in html and "Save" in html
    assert "That does not look like an email address." in html
    assert "window.ownerEmailSave" in html and "/api/v1/owner-email" in html
    # The live refresh path re-renders findings in the page script; the form must be on it too.
    assert "if (f.form === 'owner_email') {" in html
    assert "fixHtml += OWNER_EMAIL_FORM_HTML_JS;" in html

    client = fastapi_testclient.TestClient(web_ui.app, client=LOOPBACK)
    saved = client.post("/api/v1/owner-email", json={"addresses": [ADDR]})
    assert saved.status_code == 200
    path = tmp_path / "state" / "owner_addresses.json"
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600

    snap2 = SystemSnapshot(services=[], docker_containers=[], ollama_models=[],
                           disk_usage=[], hostname="testhost", os_version="Darwin 25.0",
                           owner_addresses_state=owner_email.read_owner_state(path))
    findings2 = dr.check_owner_email(snap2)
    assert findings2 == []
    html2 = web_ui.render_dashboard(snap2, findings2)
    assert "Ostler doesn't know which email address is yours" not in html2
    assert 'name="owner-email"' not in html2
