"""R02: the Doctor's enrichment on/off switch writes the consent store the enricher reads.

Four layers, each one a different question:

  U  the switch's own file logic: last line wins, quotes, other lines kept, mode 600,
     CRLF never matches, missing file created, bad input refused
  R  the CM019 reader (services/enrich/src/consent.py, the file the enricher imports)
     returns the answer the switch just wrote, both ways
  W  the Doctor routes (web_ui.py GET/POST /api/v1/enrichment) reach the same store,
     and the cross-site guard refuses a POST from another site
  E  consumer side: the REAL enricher's own consent gate, with the network clients
     replaced by a recorder, makes no look-up after a switch-off and makes look-ups
     after a switch-on. The per-client line carries the counts and the refusal is logged.

Synthetic values only. Every test runs with OSTLER_DIR pointing at a temp dir and
HOME pointed at a temp dir, so nothing touches a real ~/.ostler or ~/Library.
"""
from __future__ import annotations

import asyncio
import logging
import os
import stat
import sys
from pathlib import Path
from unittest import mock

import pytest

TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parent
AGENT = ROOT / "vendor" / "doctor" / "agent"
CM019 = ROOT / "vendor" / "cm019_preferences" / "services"
sys.path.insert(0, str(AGENT))

import enrichment_switch as sw  # noqa: E402


@pytest.fixture(autouse=True)
def sandbox(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    ostler = tmp_path / "ostler"
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("OSTLER_DIR", str(ostler))
    monkeypatch.delenv("OSTLER_CONSENT_ENRICHMENT_DECISION", raising=False)
    return ostler


def _env(ostler: Path) -> Path:
    return ostler / "config" / ".env"


# -- U: the switch's own file logic -----------------------------------------

def test_U1_missing_file_reads_as_not_enabled_and_set_creates_it(sandbox):
    assert sw.status()["enabled"] is False
    assert sw.status()["reason"] == "no_recorded_answer"
    sw.set_enabled(True)
    assert _env(sandbox).read_text().count("OSTLER_CONSENT_ENRICHMENT_DECISION=") == 1
    assert sw.status()["enabled"] is True


def test_U2_writes_quoted_value_and_keeps_every_other_line(sandbox):
    _env(sandbox).parent.mkdir(parents=True)
    _env(sandbox).write_text('USER_ID=alice\nREDIS_URL=redis://x\nOSTLER_CONSENT_ENRICHMENT_DECISION="accepted"\nCITY=Lisbon\n')
    sw.set_enabled(False)
    text = _env(sandbox).read_text()
    assert 'OSTLER_CONSENT_ENRICHMENT_DECISION="declined"' in text
    assert "OSTLER_CONSENT_ENRICHMENT_DECISION=\"accepted\"" not in text
    for keep in ("USER_ID=alice", "REDIS_URL=redis://x", "CITY=Lisbon"):
        assert keep in text.split("\n"), keep


def test_U3_last_matching_line_wins_and_duplicates_are_collapsed(sandbox):
    _env(sandbox).parent.mkdir(parents=True)
    _env(sandbox).write_text('OSTLER_CONSENT_ENRICHMENT_DECISION="declined"\nX=1\nOSTLER_CONSENT_ENRICHMENT_DECISION="accepted"\n')
    assert sw.read_file_decision() == "accepted"
    sw.set_enabled(False)
    assert sw.read_file_decision() == "declined"
    assert _env(sandbox).read_text().count("OSTLER_CONSENT_ENRICHMENT_DECISION=") == 1


def test_U4_mode_600_after_write(sandbox):
    sw.set_enabled(True)
    mode = stat.S_IMODE(os.stat(_env(sandbox)).st_mode)
    assert mode == 0o600, oct(mode)


def test_U5_crlf_line_does_not_read_as_accepted_like_sed_does(sandbox):
    # sed keeps the CR, so the value is '"accepted"\r' and the exact match fails.
    _env(sandbox).parent.mkdir(parents=True)
    _env(sandbox).write_bytes(b'OSTLER_CONSENT_ENRICHMENT_DECISION="accepted"\r\n')
    assert sw.read_file_decision() != "accepted"
    assert sw.status()["enabled"] is False
    sw.set_enabled(True)
    assert sw.status()["enabled"] is True


def test_U6_bad_input_is_refused_and_writes_nothing(sandbox):
    with pytest.raises(sw.EnrichmentSwitchError) as exc:
        sw.set_enabled("yes")  # type: ignore[arg-type]
    assert exc.value.status == 400
    assert not _env(sandbox).exists()


def test_U7_env_override_declined_wins_over_file_accepted(sandbox, monkeypatch):
    sw.set_enabled(True)
    monkeypatch.setenv("OSTLER_CONSENT_ENRICHMENT_DECISION", "declined")
    st = sw.status()
    assert st["enabled"] is False
    assert st["reason"] == "env_override"
    assert st["env_override"] is True


# -- R: the CM019 reader the enricher imports ---------------------------------

def _cm019_consent():
    src = str(CM019 / "enrich" / "src")
    common = str(CM019 / "common")
    for p in (src, common):
        if p not in sys.path:
            sys.path.insert(0, p)
    import importlib
    try:
        return importlib.import_module("consent")
    except ModuleNotFoundError as exc:  # click missing: a CANNOT-RUN, not a pass
        pytest.fail(f"CANNOT-RUN: cm019 consent reader did not import ({exc}); install click")


def test_R1_reader_agrees_with_the_switch_both_ways():
    consent = _cm019_consent()
    sw.set_enabled(False)
    assert consent.public_lookup_allowed() is False
    sw.set_enabled(True)
    assert consent.public_lookup_allowed() is True
    sw.set_enabled(False)
    assert consent.public_lookup_allowed() is False


# -- W: the Doctor routes -----------------------------------------------------

@pytest.fixture()
def client():
    """The Doctor app with the owner gate standing in as the Mac's owner.

    The global owner middleware (web_ui._owner_gate) reads the kernel's view of the
    connecting process, which a test client cannot have. test_health_gate.py stands
    the verdict in the same way. test_W4 turns the owner check back on.
    """
    try:
        from fastapi.testclient import TestClient
        import owner_peer
        import web_ui
    except Exception as exc:  # noqa: BLE001
        pytest.fail(f"CANNOT-RUN: Doctor web_ui did not import ({exc!r})")
    with mock.patch.object(owner_peer, "verdict", lambda client, server: None):
        yield TestClient(web_ui.app, base_url="http://127.0.0.1:8089")


def test_W1_post_then_get_round_trip_through_the_real_routes(client, sandbox):
    r = client.post("/api/v1/enrichment", json={"enabled": False})
    assert r.status_code == 200, r.text
    assert r.json()["enabled"] is False
    assert 'OSTLER_CONSENT_ENRICHMENT_DECISION="declined"' in _env(sandbox).read_text()
    g = client.get("/api/v1/enrichment")
    assert g.status_code == 200 and g.json()["enabled"] is False
    client.post("/api/v1/enrichment", json={"enabled": True})
    assert client.get("/api/v1/enrichment").json()["enabled"] is True


def test_W2_cross_site_post_is_refused_and_writes_nothing(client, sandbox):
    r = client.post("/api/v1/enrichment", json={"enabled": True},
                    headers={"Sec-Fetch-Site": "cross-site"})
    assert r.status_code == 403
    assert not _env(sandbox).exists()


def test_W4_a_non_owner_caller_is_refused_and_nothing_is_written(sandbox):
    import owner_peer
    import web_ui
    from fastapi.testclient import TestClient
    with mock.patch.object(owner_peer, "verdict", lambda client, server: "not-loopback"):
        c = TestClient(web_ui.app, base_url="http://127.0.0.1:8089")
        assert c.get("/api/v1/enrichment").status_code == 403
        assert c.post("/api/v1/enrichment", json={"enabled": True}).status_code == 403
    assert not _env(sandbox).exists()


def test_W3_non_boolean_body_is_400(client, sandbox):
    r = client.post("/api/v1/enrichment", json={"enabled": "true"})
    assert r.status_code == 400
    assert not _env(sandbox).exists()


# -- E: consumer side, the real enricher's consent gate -----------------------

PREFIX = "enrichment looked up per client:"
STAMP = {"privacy_level": "L0", "privacyScale": "canonical-2026-11",
         "extra": {"category_inferred": False}}
SEED = [
    {"id": "e-01", "category": "music", "subject": "seed-subject-01", **STAMP},
    {"id": "e-02", "category": "book", "subject": "seed-subject-03", **STAMP, "author": "seed author"},
    {"id": "e-03", "category": "movie", "subject": "seed-subject-04", **STAMP},
    {"id": "e-04", "category": "podcast", "subject": "seed-subject-05", **STAMP},
    {"id": "e-05", "category": "place", "subject": "seed venue harbour", **STAMP},
    {"id": "e-06", "category": "food", "subject": "seed-subject-07", **STAMP},
    {"id": "e-07", "category": "interest", "subject": "seed-subject-08", **STAMP},
]


class _Capture(logging.Handler):
    def __init__(self):
        super().__init__(logging.DEBUG)
        self.lines = []

    def emit(self, record):
        self.lines.append(record.getMessage())


def _run_real_gate_batch():
    """One real enrich_batch with the REAL consent gate; network clients are recorders."""
    for p in (CM019 / "enrich", CM019 / "common", TESTS):
        if str(p) not in sys.path:
            sys.path.insert(0, str(p))
    import test_vendored_enrich_seed_lookups as base  # recorder + store mock (synthetic)
    from src.enricher import EnrichmentService as Enricher, EnrichmentStats
    import httpx

    base._RealAsyncClient = httpx.AsyncClient  # the store mock delegates to the real client
    rec = base.Recorder([])
    cap = _Capture()
    lg = logging.getLogger("src.enricher")
    lg.addHandler(cap)
    lg.setLevel(logging.DEBUG)
    try:
        with mock.patch.object(Enricher, "__init__", lambda self: base._init(self, rec)), \
             mock.patch.object(Enricher, "_osm_cuisine", property(lambda self: rec), create=True), \
             mock.patch.object(Enricher, "_foursquare", property(lambda self: rec), create=True), \
             mock.patch.object(Enricher, "_google_places", property(lambda self: rec), create=True), \
             mock.patch.object(Enricher, "_check_already_enriched", mock.AsyncMock(return_value=False)), \
             mock.patch.object(Enricher, "_store_enrichment", mock.AsyncMock(return_value=True)), \
             mock.patch.object(httpx, "AsyncClient", base._StoreClient):
            e = Enricher()
            asyncio.run(e.enrich_batch([dict(p) for p in SEED], EnrichmentStats()))
    finally:
        lg.removeHandler(cap)
    return cap.lines


def _per_client(lines):
    out = [ln for ln in lines if ln.startswith(PREFIX)]
    assert len(out) == 1, out
    counts = dict(kv.split("=") for kv in out[0][len(PREFIX):].split())
    return {k: int(v) for k, v in counts.items()}


def test_E1_switch_off_means_no_lookups_and_a_logged_reason(sandbox):
    sw.set_enabled(False)
    lines = _run_real_gate_batch()
    counts = _per_client(lines)
    assert set(counts) == {"music", "books", "films", "podcasts", "places", "food", "interests"}
    assert all(v == 0 for v in counts.values()), counts
    refusals = [ln for ln in lines if "has not accepted enrichment" in ln]
    assert refusals, "no refusal reason logged"


def test_E2_switch_on_means_lookups_above_zero(sandbox):
    sw.set_enabled(True)
    counts = _per_client(_run_real_gate_batch())
    assert all(v > 0 for v in counts.values()), counts


# -- J: the walk probe's judge for the switch-off case -------------------------

def _judge():
    sys.path.insert(0, str(ROOT / "scripts" / "box_walk_probes" / "lib"))
    import walk134_judges
    return walk134_judges


ZERO = ("2026-11-20 INFO enrichment looked up per client: music=0 books=0 films=0 "
        "podcasts=0 places=0 food=0 interests=0\n")
REFUSED = ("2026-11-20 WARNING enrich_batch refused: owner has not accepted enrichment "
           "(no outbound request made)\n")


def test_J1_all_zero_with_the_refusal_reason_passes():
    v, _, _, _ = _judge().judge_switch_off(ZERO + REFUSED)
    assert v == "PASS"


def test_J2_negative_control_a_look_up_while_off_fails():
    v, _, _, _ = _judge().judge_switch_off(ZERO.replace("music=0", "music=2") + REFUSED)
    assert v == "FAIL"


def test_J3_zeros_without_the_reason_are_not_a_pass():
    v, _, _, _ = _judge().judge_switch_off(ZERO)
    assert v == "FAIL"


def test_J4_no_per_client_line_is_cannot_run_not_pass():
    v, _, _, _ = _judge().judge_switch_off(REFUSED)
    assert v == "CANNOT"


# -- E3/E4/W5: the declined install (option b: the job is installed and idle) ---

def test_E4_declined_makes_no_socket_connection(sandbox):
    """WEAK, NOT PROOF OF ZERO EGRESS. The recorder clients cannot connect even when
    the consent gate is removed, so the zero-connect count here is not an independent
    instrument. It is kept only as a regression check. The real instrument is the walk
    probe enrichment_switch_off_reaches_clients, which reads the enricher's per-client
    line on the box (enricher.py, the logger.info call near line 1142)."""
    import socket
    attempts = []
    real = socket.socket

    class RecordingSocket(real):
        def connect(self, *a, **k):
            attempts.append(("connect", a))
            raise OSError("blocked by test: connect while declined")

        def connect_ex(self, *a, **k):
            attempts.append(("connect_ex", a))
            return 111

    def no_create_connection(*a, **k):
        attempts.append(("create_connection", a))
        raise OSError("blocked by test: create_connection while declined")

    sw.set_enabled(False)
    with mock.patch("socket.socket", RecordingSocket), \
         mock.patch("socket.create_connection", no_create_connection):
        counts = _per_client(_run_real_gate_batch())
    assert all(v == 0 for v in counts.values()), counts
    assert attempts == [], f"outbound connection attempts while declined: {attempts}"


def test_W5_declined_install_then_toggle_on_installs_nothing_new_and_looks_up(client, sandbox, monkeypatch):
    """A declined install leaves the job installed and idle. Toggling on needs no
    re-install: agent_installed is already true, and the next batch looks up."""
    home = Path(os.environ["HOME"])
    plist = home / "Library" / "LaunchAgents" / "com.ostler.enrich.plist"
    plist.parent.mkdir(parents=True)
    plist.write_text("<plist/>\n")
    _env(sandbox).parent.mkdir(parents=True)
    _env(sandbox).write_text('OSTLER_CONSENT_ENRICHMENT_DECISION="declined"\n')
    before = client.get("/api/v1/enrichment").json()
    assert before["enabled"] is False and before["agent_installed"] is True, before
    r = client.post("/api/v1/enrichment", json={"enabled": True})
    assert r.status_code == 200 and r.json()["enabled"] is True, r.text
    after = client.get("/api/v1/enrichment").json()
    assert after["agent_installed"] is True and after["enabled"] is True, after
    counts = _per_client(_run_real_gate_batch())
    assert all(v > 0 for v in counts.values()), counts


def test_J5_a_tick_stand_down_alone_is_cannot_not_a_pass():
    v, _, _, _ = _judge().judge_switch_off("2026-11-20 INFO [x] declined; standing down, nothing sent\n")
    assert v == "CANNOT"


def test_J6_a_stand_down_with_a_look_up_above_zero_is_a_fail():
    v, _, _, _ = _judge().judge_switch_off("standing down, nothing sent\n" + ZERO.replace("music=0", "music=2"))
    assert v == "FAIL"


def test_J7_nothing_in_the_log_is_cannot_run():
    v, _, _, _ = _judge().judge_switch_off("2026-11-20 INFO unrelated line\n")
    assert v == "CANNOT"


def test_J8_the_real_enricher_line_with_the_switch_off_passes():
    """The walk instrument on the REAL enricher's own output (enricher.py per-client
    line + its refusal), with the switch off. Under a consent choke-point mutant this
    log carries look-ups above zero and the judge must FAIL it."""
    sw.set_enabled(False)
    lines = _run_real_gate_batch()
    v, reason, _, _ = _judge().judge_switch_off("\n".join("2026-11-20 INFO " + ln for ln in lines) + "\n")
    assert v == "PASS", (v, reason)


# -- L: the decline copy is in every locale catalogue, and install.sh uses it ------

def test_L1_decline_copy_keys_exist_in_all_fifteen_catalogues_and_install_uses_them():
    import re
    keys = ("MSG_ENRICH_DECLINED_L1", "MSG_ENRICH_DECLINED_L2", "MSG_ENRICH_DECLINED_L3")
    files = sorted(ROOT.glob("install.sh.strings.*.sh"))
    assert len(files) == 15, [f.name for f in files]
    missing = [f.name for f in files
               if not all(re.search(r'^%s="[^"]+"' % k, f.read_text(encoding="utf-8"), re.M) for k in keys)]
    assert not missing, f"decline copy missing in: {missing}"
    install = (ROOT / "install.sh").read_text(encoding="utf-8")
    for k in keys:
        assert "${%s}" % k in install, f"install.sh does not print {k}"
    assert "You said no to public look-ups" not in install, "the hardcoded English decline copy is back"
