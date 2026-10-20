"""Plaintext staging copies under ~/.ostler/imports live only as long as a re-run needs them.

Red team 2026-10-19 (EDGE_CASE_MATRIX, staging rows): every conversation route
in universal_import wrote its CM048 payloads (message bodies, plaintext) to
``~/.ostler/imports/fda/*_conversations.json`` and kept them forever, L3
included. ``_stage_then_persist`` is the one shared path now:

* removed after ``persist_status == "ok"``;
* kept on ``no_pipeline`` / ``partial`` / ``error`` (the re-run input);
* an L3 payload, or one with no explicit level, is never staged; it still
  reaches CM048, which owns L3 (Archie ruling 1);
* written 0600.

Synthetic payloads only; pwg-convo is a stub script on disk.
"""
from __future__ import annotations

import json
import stat
import sys
from pathlib import Path

# Ported from HR015 ostler_fda/tests/test_staging_cleanup.py at a3242193 (#1171), grafted
# into vendor/ostler_fda for v1.0.111: runs against the VENDORED copy.
REPO_ROOT = Path(__file__).resolve().parents[1] / "vendor"
sys.path.insert(0, str(REPO_ROOT))

from ostler_fda import universal_import as ui  # noqa: E402

FNAME = "example_conversations.json"


def _payload(cid: str, level="L2", body="BODY-" ):
    md = {"conversation_id": cid, "channel": "im", "participants": []}
    if level is not None:
        md["privacy_level"] = level
    return {"conversation_id": cid, "transcript": body + cid, "metadata": md}


def _stub(tmp_path: Path, exit_code: int = 0, fail_ids=()):
    log = tmp_path / "calls.log"
    b = tmp_path / "pwg-convo"
    fails = " ".join(fail_ids)
    b.write_text(
        "#!/usr/bin/env bash\n"
        'cid=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[\'conversation_id\'])" "$3")\n'
        f'echo "$cid $(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(\'privacy_level\',\'-\'))" "$3")" >> "{log}"\n'
        f'for f in {fails}; do [ "$cid" = "$f" ] && exit 1; done\n'
        f"exit {exit_code}\n"
    )
    b.chmod(0o755)
    return b, log


def test_removed_after_a_successful_persist(tmp_path, monkeypatch):
    b, log = _stub(tmp_path)
    monkeypatch.setenv("OSTLER_PWG_CONVO_CMD", str(b))
    r = ui._stage_then_persist([_payload("a"), _payload("b")], FNAME, "example", output_dir=tmp_path / "out")
    assert r["persist_status"] == "ok" and r["persisted"] == 2
    assert r["staging_kept"] is False
    assert not (tmp_path / "out" / FNAME).exists()


def test_kept_when_no_pipeline(tmp_path, monkeypatch):
    monkeypatch.setattr(ui, "_pwg_convo_cmd", lambda: None)
    r = ui._stage_then_persist([_payload("a")], FNAME, "example", output_dir=tmp_path / "out")
    assert r["persist_status"] == "no_pipeline" and r["staging_kept"] is True
    staged = tmp_path / "out" / FNAME
    assert [p["conversation_id"] for p in json.loads(staged.read_text())] == ["a"]


def test_kept_when_partial(tmp_path, monkeypatch):
    b, _ = _stub(tmp_path, fail_ids=("b",))
    monkeypatch.setenv("OSTLER_PWG_CONVO_CMD", str(b))
    r = ui._stage_then_persist([_payload("a"), _payload("b")], FNAME, "example", output_dir=tmp_path / "out")
    assert r["persist_status"] == "partial" and r["staging_kept"] is True
    assert (tmp_path / "out" / FNAME).exists()


def test_kept_when_every_send_failed(tmp_path, monkeypatch):
    b, _ = _stub(tmp_path, exit_code=1)
    monkeypatch.setenv("OSTLER_PWG_CONVO_CMD", str(b))
    r = ui._stage_then_persist([_payload("a")], FNAME, "example", output_dir=tmp_path / "out")
    assert r["persist_status"] == "error" and r["staging_kept"] is True


def test_l3_and_unlevelled_payloads_are_never_staged_but_still_reach_cm048(tmp_path, monkeypatch):
    monkeypatch.setattr(ui, "_pwg_convo_cmd", lambda: None)  # keep the file so we can read it
    payloads = [_payload("open"), _payload("secret", level="L3"), _payload("bare", level=None)]
    r = ui._stage_then_persist(payloads, FNAME, "example", output_dir=tmp_path / "out")
    staged = json.loads((tmp_path / "out" / FNAME).read_text())
    assert [p["conversation_id"] for p in staged] == ["open"]
    assert r["staging_l3_withheld"] == 2
    assert "BODY-secret" not in (tmp_path / "out" / FNAME).read_text()
    # With a pipeline, L3 is still handed to CM048 (no pre-CM048 short-circuit).
    b, log = _stub(tmp_path)
    monkeypatch.setattr(ui, "_pwg_convo_cmd", lambda: [str(b)])
    ui._stage_then_persist(payloads, FNAME, "example", output_dir=tmp_path / "out2")
    sent = dict(l.split() for l in log.read_text().splitlines())
    assert sent["secret"] == "L3" and set(sent) == {"open", "secret", "bare"}


def test_only_l3_payloads_leave_no_file_and_clear_a_stale_one(tmp_path, monkeypatch):
    monkeypatch.setattr(ui, "_pwg_convo_cmd", lambda: None)
    out = tmp_path / "out"
    out.mkdir()
    (out / FNAME).write_text("[stale]")
    r = ui._stage_then_persist([_payload("s", level="L3")], FNAME, "example", output_dir=out)
    assert not (out / FNAME).exists()
    assert r["staging_kept"] is False


def test_staging_file_is_owner_only(tmp_path, monkeypatch):
    monkeypatch.setattr(ui, "_pwg_convo_cmd", lambda: None)
    ui._stage_then_persist([_payload("a")], FNAME, "example", output_dir=tmp_path / "out")
    mode = stat.S_IMODE((tmp_path / "out" / FNAME).stat().st_mode)
    assert mode == 0o600


def test_every_conversation_route_uses_the_shared_helper():
    # Enumerate every staging write of a *_conversations.json that is followed
    # by a pwg-convo persist: they must all go through _stage_then_persist.
    src = (REPO_ROOT / "ostler_fda" / "universal_import.py").read_text()
    assert src.count("= _persist_conversations(") == 1  # the only caller is the helper
    # VENDORED DIFFERENCE: the Instagram DM route (igd.OUTPUT_FILENAME) arrived
    # upstream with f60b97ea (#1164), a feature HELD for v1.0.111, so the vendored
    # tree has no Instagram dispatcher and the #1171 Instagram hunk was not grafted.
    # Assert that absence too, so the graft cannot half-arrive.
    assert "_dispatch_instagram" not in src and "igd.OUTPUT_FILENAME" not in src
    for name in ('"facebook_messenger_conversations.json"', '"email_conversations.json"'):
        assert name in src
    assert '"facebook_messenger_conversations.json").write_text' not in src
    assert '"email_conversations.json").write_text' not in src
