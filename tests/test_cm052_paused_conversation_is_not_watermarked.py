"""A conversation the wire refuses as paused (subscription inactive) must stay
unprocessed: counted as paused, never posted, and its watermark NOT advanced.

CM052 781e5643 (#18) fixed this upstream ("paused chats no longer marked done");
v1.0.111 backports only that watermark half into vendor/cm052_ai_conversations
(Archie). Before it, cli.run() counted a "paused" outcome as posted and wrote the
watermark, so every conversation seen while unpaid was marked done for ever and
never captured after the customer subscribed. Synthetic data only.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm052_ai_conversations" / "src"))

from cm052 import cli  # noqa: E402


def _conv(cid: str):
    return SimpleNamespace(conversation_id=cid, last_activity="2026-10-19T09:00:00+00:00",
                           provenance=SimpleNamespace(source_subtype="chatgpt_export"))


def _run(tmp_path, monkeypatch, capsys, wire_result):
    monkeypatch.setenv("CM052_USER_EMAIL", "owner@example.com")
    monkeypatch.setattr(cli, "_discover", lambda *_a, **_k: [_conv("c-paused-1"), _conv("c-paused-2")])
    monkeypatch.setattr(cli.wire, "post", lambda conv, *a, **k: wire_result)
    state = tmp_path / "state.json"
    args = cli._build_arg_parser().parse_args(["--state-file", str(state), "--json"])
    rc = cli.run(args)
    counts = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    return rc, counts, json.loads(state.read_text())


def test_a_paused_conversation_stays_unprocessed(tmp_path, monkeypatch, capsys):
    rc, counts, state = _run(tmp_path, monkeypatch, capsys, {"reason": "subscription_inactive"})
    assert rc == 0
    assert state["processed"] == {}, ("a paused conversation was watermarked as done", state)
    assert counts.get("written") == 0 and counts.get("paused") == 2, counts


def test_control_a_posted_conversation_is_watermarked(tmp_path, monkeypatch, capsys):
    rc, counts, state = _run(tmp_path, monkeypatch, capsys, {"status": "ok"})
    assert rc == 0
    assert set(state["processed"]) == {"c-paused-1", "c-paused-2"}, state
    assert counts.get("written") == 2 and counts.get("paused", 0) == 0, counts
