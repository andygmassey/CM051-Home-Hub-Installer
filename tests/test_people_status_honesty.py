"""People ingest says what happened (status-honesty sweep E1, E2, V3).

V3: Oxigraph down used to return status ok with 0 created, so the fda-rerun
stamped last_success_at. E2: pwg_ingest.main() exited 0 whatever the results
said and install.sh ended the WhatsApp graph write in `|| true`. E1: install.sh
never read ingest_people_to_qdrant's status=error and printed "No people to
index yet". Synthetic data only (reserved phone numbers).
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor"))

from ostler_fda import pwg_ingest  # noqa: E402

INSTALL = (ROOT / "install.sh").read_text(encoding="utf-8")
PHONE = "+44" + "7700900456"


@pytest.fixture()
def dead_store(tmp_path, monkeypatch):
    # Nothing listens on port 1: every lookup is "could not look".
    monkeypatch.setattr(pwg_ingest, "OXIGRAPH_URL", "http://127.0.0.1:1")
    (tmp_path / "imessage_conversations.json").write_text(json.dumps([
        {"participants": [PHONE], "message_count": 3,
         "last_message": "2026-10-01T10:00:00Z", "display_name": ""}]))
    return tmp_path


def test_v3_store_down_is_not_ok(dead_store):
    res = pwg_ingest.ingest_imessage(dead_store)
    assert res["people_lookup_failed"] == 1
    assert res["people_created"] == 0
    assert res["status"] == "error", res


def test_v3_healthy_empty_run_is_still_ok(tmp_path):
    (tmp_path / "imessage_conversations.json").write_text("[]")
    assert pwg_ingest.ingest_imessage(tmp_path)["status"] == "ok"


def test_v3_lookup_status_partial_is_not_ok():
    assert pwg_ingest._lookup_status(0, 0) == "ok"
    assert pwg_ingest._lookup_status(2, 0) == "error"
    assert pwg_ingest._lookup_status(2, 5) == "partial"


def test_e2_cli_exits_nonzero_when_a_source_errored(dead_store, monkeypatch):
    monkeypatch.setattr(sys, "argv", ["pwg_ingest", "--fda-dir", str(dead_store)])
    monkeypatch.setattr(
        pwg_ingest, "_INGEST_DISPATCH", (("imessage", "ingest_imessage"),)
    )
    with pytest.raises(SystemExit) as e:
        pwg_ingest.main()
    assert e.value.code == 1


def test_e2_whatsapp_graph_write_is_not_swallowed():
    i = INSTALL.index("-m ostler_fda.pwg_ingest \\\n            --fda-dir")
    tail = INSTALL[i:i + 400]
    assert "|| true" not in tail.split("\n", 3)[2], tail
    assert "_wa_ingest_rc=$?" in INSTALL
    assert "MSG_HYDRATE_WHATSAPP_GRAPH_WRITE_FAILED" in INSTALL


def test_e1_people_hydrate_reads_status_error():
    m = re.search(r"_HYDRATE_PEOPLE_STATUS=.*?MSG_HYDRATE_PEOPLE_FAILED", INSTALL, re.S)
    assert m, "install.sh never reads the people index status"
    assert 'get("status"' in m.group(0)
    assert "_HYDRATE_PEOPLE_RC=1" in m.group(0)


def test_e1_message_exists_in_strings():
    s = (ROOT / "install.sh.strings.en-GB.sh").read_text(encoding="utf-8")
    assert "MSG_HYDRATE_PEOPLE_FAILED=" in s
    assert "MSG_HYDRATE_WHATSAPP_GRAPH_WRITE_FAILED=" in s
